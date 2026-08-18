class_name OverworldZones
extends Node3D
# THE OWNER of the whole overworld zone set — one `OverworldZone` per rally on the roster,
# their markers, their ghost cars, and the budget that keeps 38 of them affordable
# (docs/superpowers/specs/2026-08-17-overworld-hq-design.md, slice 2).
#
# `overworld.gd` constructs this, hands it the coordinate conversion and the player car, calls
# `update(delta)` once a frame, and listens to `zone_activated`. Everything else is internal.
#
# Why the budget is the interesting part. There are 38 rallies, and a car prop is expensive
# enough that the HQ caches its map-table props (`hq._prize_car_props`) and prewarms them off
# the critical path — instantiating car.tscn embeds nine car models, prunes eight, and then
# duplicates every surviving mesh resource. Building all 38 markers, three of which want a
# full-size car body, is not an option. So:
#
#   * Zones are cheap (an Area3D plus a light tube sharing one static mesh) and all exist.
#     Only the near ones tick.
#   * Markers are POOLED: at most as many marker nodes exist as there are zones inside
#     `overworld_marker_draw_distance_m`, and they are re-dressed (`OverworldMarker.configure`)
#     as the player drives rather than allocated per zone.
#   * Ghost car BODIES are cached per car model and capped at `overworld_ghost_car_max`,
#     granted to the nearest eligible zones first, and re-parented — never freed — when the
#     player drives away. Detaching before a marker is recycled is the same discipline
#     `hq._detach_prize_car_props` exists for.
#   * Rotation is ONE yaw, advanced here and written onto the live markers. No marker has a
#     `_process`.
#
# Headless: pass `visuals: false` (or omit `car_scene`) and nothing that needs a renderer or a
# physics server is built, while `update_with(delta, car_pos, speed_kmh)` still drives the full
# dwell/activation path — which is how the zone loop is tested without a scene.

# Re-emitted from whichever zone completed its dwell. `overworld.gd` opens the rally detail
# panel from here.
signal zone_activated(rally_id: String)

# How often the live-marker set is recomputed. The dwell ticks every frame; deciding WHICH
# markers exist is a sort over the roster and does not need to.
const REFRESH_INTERVAL_S := 0.35
# Zones further than this multiple of the zone radius are not even distance-checked for dwell.
# Purely a guard against ticking 38 state machines a frame; the dwell result is identical.
const TICK_MARGIN := 4.0

var _zones: Array[OverworldZone] = []
var _by_id: Dictionary = {}                 # rally_id -> OverworldZone
var _live_markers: Dictionary = {}          # rally_id -> OverworldMarker
var _marker_pool: Array[OverworldMarker] = []
# model_id -> the ghost body node. Built at most once per car model, ever.
var _ghost_bodies: Dictionary = {}
var _ghost_parking: Node3D = null           # holds cached ghost bodies nobody is showing

var _to_world := Callable()
var _ground_at := Callable()
var _car_scene: PackedScene = null
# Variant, not Node3D: the car-script members read below (`linear_velocity`) are resolved
# dynamically, the way CarProp and GhostCar deliberately do, so this file never depends on the
# analyser resolving car.tscn's root script.
var _car: Variant = null
var _visuals := true
var _yaw := 0.0
var _since_refresh := INF


# `opts`:
#   to_world     Callable(Vector2 map_pos) -> Vector3   REQUIRED. The overworld owns the
#                                                       map_pos -> world conversion; this file
#                                                       never reimplements it.
#   ground_at    Callable(Vector3) -> float             optional. Ground height, used to drop
#                                                       each zone onto the terrain. (The ghost
#                                                       cars do NOT use it — they sit at their
#                                                       analytic ride height above the zone's
#                                                       flat pad; see `_ghost_body`.)
#   car          the player car node                    optional (only `update` needs it).
#   car_scene    PackedScene of car.tscn                optional; without it no ghost is built.
#   rallies      Array[Dictionary]                      defaults to the whole roster.
#   profile      Dictionary                             defaults to Save.profile.
#   visuals      bool                                   false = no meshes at all (headless).
func setup(opts: Dictionary) -> void:
	_to_world = opts.get("to_world", Callable())
	_ground_at = opts.get("ground_at", Callable())
	_car_scene = opts.get("car_scene", null)
	_car = opts.get("car", null)
	_visuals = bool(opts.get("visuals", true))
	var rallies: Array = opts.get("rallies", RallyLibrary.RALLIES)
	var profile: Dictionary = opts.get("profile", Save.profile)
	if not _to_world.is_valid():
		push_error("OverworldZones.setup: `to_world` is required — no way to place a zone.")
		return
	_ghost_parking = Node3D.new()
	_ghost_parking.name = "GhostCarCache"
	_ghost_parking.visible = false
	add_child(_ghost_parking)
	for entry in rallies:
		_add_zone(entry as Dictionary, profile)
	# Re-gate on any progress change, so a rally that lights mid-session grows its tube and its
	# marker there and then rather than on the next scene load. (`refresh` is one lit test per
	# zone; profile writes are rare, so this is nowhere near a per-frame cost.) Skipped when the
	# caller gated on a non-live profile — a test driving a synthetic profile must not be
	# overruled by Save.profile behind its back.
	if profile == Save.profile and Save.has_signal("profile_changed") \
			and not Save.profile_changed.is_connected(_on_profile_changed):
		Save.profile_changed.connect(_on_profile_changed)


# Re-evaluate the fog gate on every zone (a completed rally lights new ones) and force the
# marker set to be recomputed on the next update. Cheap enough to call on any progress change.
func refresh(profile: Dictionary = Save.profile) -> void:
	for zone in _zones:
		zone.refresh_revealed(profile)
	_since_refresh = INF


# Hide (or restore) EVERY zone's visuals in one flip — the light tubes, the pooled markers with their
# icons and star rows, and the parked ghost cars, all of which are descendants of this node.
#
# For the car picker: the player is parked ON a zone when it opens (that is how it opens), so its tube
# is a translucent column standing around the very car they are choosing, its marker floats directly
# above it, and a car-unlock zone parks a full-size ghost beside it.
#
# `visible` on THIS node, deliberately, rather than a walk that clears each tube and marker:
#
#   * it is O(1) instead of O(zones), and it cannot miss a thing added later (the star layer was
#     added after the tubes; a per-zone walk would have needed remembering);
#   * and it CANNOT FIGHT THE REVEAL GATING. Each tube's own `_tube_root.visible` carries whether its
#     rally is revealed (`OverworldZone._push_progress`), and hiding an ancestor leaves that flag
#     untouched — so restoring shows exactly the zones that were showing before, rather than lighting
#     up a dark one. A walk that wrote each tube's flag would have to remember and undo the gate.
#
# Visibility is not state: `update_with` goes on ticking while hidden, so the dwell latch on the zone
# that opened the picker is exactly where it was when the player comes back.
func set_visuals_hidden(hidden: bool) -> void:
	visible = not hidden


## Are the zone visuals hidden? The seam for the picker's test.
func visuals_hidden() -> bool:
	return not visible


# Cancel the dwell on ONE zone by rally id — the host's hook for "the player backed out of the
# rally panel this zone opened". See OverworldZone.cancel_dwell for why cancelling disarms.
func cancel_dwell(rally_id: String) -> bool:
	var zone := zone_for(rally_id)
	if zone == null:
		return false
	zone.cancel_dwell()
	return true


func _on_profile_changed() -> void:
	refresh(Save.profile)


# Per-frame entry point, reading the live car. Delegates to `update_with`, which is where all
# the logic is — so a test never needs a car.
func update(delta: float) -> void:
	if _car == null or not is_instance_valid(_car):
		return
	var node: Node3D = _car
	var vel: Vector3 = _car.linear_velocity
	update_with(delta, node.global_position, vel.length() * 3.6)


# The whole per-frame job, with the car's state INJECTED: advance the shared spin, refresh the
# live marker set on its interval, and tick the dwell on the zones near enough to matter.
func update_with(delta: float, car_pos: Vector3, speed_kmh: float) -> void:
	_advance_spin(delta)
	_since_refresh += delta
	if _since_refresh >= REFRESH_INTERVAL_S:
		_since_refresh = 0.0
		_refresh_markers(car_pos)
	var reach := Config.data.overworld_zone_radius_m * TICK_MARGIN
	# Squared, so the per-frame sweep over every zone neither allocates a Vector2 nor takes a
	# sqrt for what is only a threshold test. _refresh_markers still uses the real distance,
	# but it runs a few times a second rather than 60.
	var reach_sq := reach * reach
	for zone in _zones:
		if zone.plane_distance_sq_to(car_pos) > reach_sq:
			# Far away: make sure a part-accumulated dwell does not survive being left behind.
			if zone.progress > 0.0 or zone.has_fired():
				zone.reset_dwell()
			continue
		zone.tick(delta, car_pos, speed_kmh)


# --- Queries (for the overworld's wayfinding, and for tests) ----------------------------


func zones() -> Array[OverworldZone]:
	return _zones


func zone_for(rally_id: String) -> OverworldZone:
	return _by_id.get(rally_id, null) as OverworldZone


func marker_for(rally_id: String) -> OverworldMarker:
	return _live_markers.get(rally_id, null) as OverworldMarker


func live_marker_count() -> int:
	return _live_markers.size()


func ghost_car_count() -> int:
	var n := 0
	for id in _live_markers:
		var marker: OverworldMarker = _live_markers[id]
		if marker.has_ghost():
			n += 1
	return n


# The shared marker yaw, in radians. Public so a test can assert one update moves it.
func spin_yaw() -> float:
	return _yaw


# --- Zones -------------------------------------------------------------------------------


func _add_zone(entry: Dictionary, profile: Dictionary) -> void:
	var rally_id := String(entry.get("id", ""))
	if rally_id == "" or _by_id.has(rally_id):
		return
	var zone := OverworldZone.new()
	zone.name = "Zone_%s" % rally_id
	add_child(zone)
	zone.setup(entry, _zone_world_pos(entry), _visuals)
	zone.refresh_revealed(profile)
	zone.activated.connect(_on_zone_activated)
	_zones.append(zone)
	_by_id[rally_id] = zone


# The zone's world point: the overworld's own conversion of the rally's map_pos, dropped onto
# the terrain if a ground sampler was supplied. A non-finite sample is ignored rather than
# writing NAN into a transform.
func _zone_world_pos(entry: Dictionary) -> Vector3:
	var pos: Vector3 = _to_world.call(RallyLibrary.map_pos_of(entry))
	if _ground_at.is_valid():
		var y: float = _ground_at.call(pos)
		if is_finite(y):
			pos.y = y
	return pos


func _on_zone_activated(rally_id: String) -> void:
	zone_activated.emit(rally_id)


# --- Markers ------------------------------------------------------------------------------


# The per-frame marker pass: turn the ghosts, POINT THE ICONS AT THE PLAYER, and re-read the
# float height so a retune is live.
#
# Two different angles now, and the distinction is the point:
#
#   * `_yaw` — ONE shared, advancing angle for the parked GHOST CARS. A prize car turning on the
#     spot is a showroom turntable and carries no information to read, so it keeps spinning.
#   * a PER-MARKER camera yaw for the ICONS and the star layer. Icons are information: a rally's
#     kind and the player's star count should never be something you wait for the far side of a
#     rotation to see. The 2D part card and the star row billboard in their MATERIAL (free); the
#     3D tokens (flag / trophy) can't — each of their sub-meshes would billboard about its own
#     origin and the token would come apart — so they are yawed here.
#
# Still no `_process` on any marker, which is the rule this file exists to enforce: the loop runs
# over the LIVE markers only (a pooled handful inside the draw distance), and it is one `atan2`
# each, from ONE camera lookup per frame.
#
# The ACTIVE camera, not a fixed path: the hub has a chase camera and a bonnet camera and the
# player switches between them — the minimap had to be fixed for exactly this. No camera (headless,
# or before the viewport has one) simply leaves the icons where they are.
func _advance_spin(delta: float) -> void:
	_yaw = fposmod(_yaw + deg_to_rad(Config.data.overworld_marker_spin_deg_s) * delta, TAU)
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var eye := cam.global_position if cam != null else Vector3.ZERO
	for id in _live_markers:
		var marker: OverworldMarker = _live_markers[id]
		marker.apply_spin(_yaw)
		if cam != null:
			marker.face_camera(facing_yaw(marker.global_position, eye))
		marker.apply_height()


# The yaw that turns a +Z-facing node at `from` to look at `eye`, flattened to the ground plane so
# an icon stays upright however high or low the camera is (the same yaw-only choice the star
# layer's BILLBOARD_FIXED_Y makes, so the two layers can never disagree). Static and pure — the
# headless test for "icons face the player" needs no camera and no viewport.
static func facing_yaw(from: Vector3, eye: Vector3) -> float:
	var to := Vector2(eye.x - from.x, eye.z - from.z)
	if to.is_zero_approx():
		return 0.0
	return atan2(to.x, to.y)


# Decide which zones deserve a marker this interval, then hand out the ghost-car budget.
#
# The rule from the spec: revealed AND inside `overworld_marker_draw_distance_m`. An unrevealed
# zone advertises nothing — the fog is meant to hide what exists, so a marker beyond the
# frontier would leak the map.
func _refresh_markers(car_pos: Vector3) -> void:
	if not _visuals:
		return
	var draw_dist: float = Config.data.overworld_marker_draw_distance_m
	# (distance, zone) pairs for everything eligible, nearest first — the same order the ghost
	# budget wants, so it is sorted once.
	var wanted: Array = []
	for zone in _zones:
		if not zone.revealed():
			continue
		var d := zone.plane_distance_to(car_pos)
		if d <= draw_dist:
			wanted.append([d, zone])
	wanted.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))

	var keep: Dictionary = {}
	for pair in wanted:
		keep[(pair[1] as OverworldZone).rally_id] = true
	# Recycle first, so the pool is stocked before anything asks for a marker.
	for id in _live_markers.keys():
		if not keep.has(id):
			_recycle_marker(String(id))
	for pair in wanted:
		var zone: OverworldZone = pair[1]
		if not _live_markers.has(zone.rally_id):
			_grant_marker(zone)
	_assign_ghosts(wanted)


func _grant_marker(zone: OverworldZone) -> void:
	var marker: OverworldMarker
	if _marker_pool.is_empty():
		marker = OverworldMarker.new()
		marker.name = "Marker"
	else:
		marker = _marker_pool.pop_back()
	if marker.get_parent() != null:
		marker.get_parent().remove_child(marker)
	zone.add_child(marker)
	marker.transform = Transform3D.IDENTITY
	# Same state axes the map table's pins wear, from the same sources — a marker must never
	# disagree with a pin about whether a rally is locked or podiumed.
	var stars := RallyDetail.stars_for(zone.rally_id)
	marker.configure(zone.rally, not zone.revealed(), stars, _has_eligible_car(zone.rally))
	marker.apply_spin(_yaw)
	# Point it at the player NOW rather than on the next frame's pass: a marker granted as the
	# player drives up would otherwise show for one frame at whatever yaw the pooled node was
	# recycled with, which reads as a flicker on the newest sign on screen.
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam != null:
		marker.face_camera(facing_yaw(marker.global_position, cam.global_position))
	_live_markers[zone.rally_id] = marker


func _recycle_marker(rally_id: String) -> void:
	var marker: OverworldMarker = _live_markers.get(rally_id, null)
	_live_markers.erase(rally_id)
	if marker == null or not is_instance_valid(marker):
		return
	_park_ghost(marker)
	if marker.get_parent() != null:
		marker.get_parent().remove_child(marker)
	_marker_pool.append(marker)


# Free the pooled markers when the manager goes away.
#
# A recycled marker is REMOVED from its parent and held in `_marker_pool`, so it is no longer
# anyone's child — freeing the manager would leave it orphaned in memory for the rest of the
# session, and GUT reports exactly that as an orphan. The parked ghost BODIES are left alone:
# they stay parented to `_ghost_parking` under this node, so the tree frees them with it (the
# same reason hq.gd keeps its prize-car props parented rather than detached).
func _exit_tree() -> void:
	for marker in _marker_pool:
		if is_instance_valid(marker):
			marker.queue_free()
	_marker_pool.clear()


# Whether the player owns anything that could enter this rally — the flag/trophy's "green vs
# grey" axis. Goes through RallyDetail.entry_plan, the shared decision the HQ's own
# `_has_eligible_car` uses, so the two can't drift.
func _has_eligible_car(rally: Dictionary) -> bool:
	for car in Save.profile.get(Save.KEY_CARS, []):
		if bool(RallyDetail.entry_plan(rally, car)["eligible"]):
			return true
	return false


# --- Ghost cars ---------------------------------------------------------------------------


# Hand the ghost-car budget to the nearest car-unlock zones. `wanted` is already sorted
# nearest-first, so this is a single pass: grant while the cap allows, park the rest.
func _assign_ghosts(wanted: Array) -> void:
	var cap: int = maxi(Config.data.overworld_ghost_car_max, 0)
	var granted := 0
	for pair in wanted:
		var zone: OverworldZone = pair[1]
		var marker: OverworldMarker = _live_markers.get(zone.rally_id, null)
		if marker == null:
			continue
		var model_id := RallyLibrary.prize_car_id(zone.rally)
		if model_id == "" or granted >= cap:
			_park_ghost(marker)
			continue
		if marker.has_ghost():
			granted += 1
			continue
		var body := _ghost_body(model_id, zone)
		if body == null:
			continue
		marker.adopt_ghost(body)
		# One body is cached per MODEL and shared by every zone unlocking it, so the facing
		# (which is per zone — cars look toward HQ) is written on adoption, not at build time.
		body.rotation.y = _ghost_yaw(zone)
		granted += 1


# Detach a marker's ghost back into the cache holder. NEVER frees it: the body is cached per
# model and reused for the rest of the session, and freeing it with its marker is precisely the
# bug `hq._detach_prize_car_props` guards against.
func _park_ghost(marker: OverworldMarker) -> void:
	var body := marker.release_ghost()
	if body != null and is_instance_valid(body) and _ghost_parking != null:
		_ghost_parking.add_child(body)


# Build (once) the translucent, FROZEN ghost body for a car model.
#
# The freeze is the load-bearing correction to `ghost_car.gd`, which spawns with
# `"freeze": false` (it must, because a frozen body renders at its freeze pose and the replay
# writes a new pose every frame) and yet calls `Car.settle_wheels_to_ground`, whose docstring
# says "Frozen props ONLY (a live solver would fight it)" — the predicted symptom being wheels
# tucked up into the arches. This ghost is pure decoration: nothing writes its pose, so it
# takes CarProp.spawn's DEFAULT freeze == true and the settle precondition is honoured.
#
# RIDE HEIGHT: car.tscn's body ORIGIN is not the wheel contact plane — it sits
# `settled_ride_height()` (wheel_radius + axle travel - mount offset - compression) ABOVE the
# ground a live car rests on. A ghost seated at Transform3D.IDENTITY under the marker (whose
# origin is the zone's ground point) therefore buries the car up to its arches. Lift it by that
# analytic ride height and droop the wheel visuals to their rest pose — exactly what
# `hq_carpark._seat_car_at_marker` does for the parked lineup, and correct here because every
# zone stands on a FLAT PAD (overworld_pads.gd), so a per-zone terrain contour would buy
# nothing. It also has to be analytic: the body is CACHED PER MODEL and re-parented between
# zones, so any ground-sampled droop baked in at build time would be a different zone's terrain.
func _ghost_body(model_id: String, zone: OverworldZone) -> Node3D:
	if _ghost_bodies.has(model_id):
		var cached: Node3D = _ghost_bodies[model_id]
		if is_instance_valid(cached):
			return cached
		_ghost_bodies.erase(model_id)
	if _car_scene == null or not _visuals:
		return null
	var index := CarLibrary.index_of(model_id)
	if index < 0:
		return null  # a synthetic roster without this model — the marker stands on its own
	var yaw := _ghost_yaw(zone)
	# Variant (not Node3D) so the dynamic `settle_wheels_to_ground` call below does not depend
	# on the analyser resolving car.tscn's root script type — the same reason CarProp.spawn
	# holds its own car as Variant.
	var body: Variant = CarProp.spawn(_ghost_parking, _car_scene, {
		"index": index,
		# freeze is left at its default TRUE — see the note above.
		"stop_physics": true,
		"disable_process": true,
		# `c` is Variant, not Node3D: collision_layer / collision_mask are RigidBody3D members
		# reached dynamically (as ghost_car.gd does), so typing it Node3D would not parse.
		"configure": func(c: Variant) -> void:
			# Seat it INSIDE configure: apply_car ends in _reset(), which puts the car back
			# at its spawn transform, so anything written after spawn is undone. configure
			# runs AFTER apply_car (CarProp.spawn), so the car's config — and with it
			# settled_ride_height() — is already this model's.
			c.transform = Transform3D.IDENTITY
			c.rotation = Vector3(0.0, yaw, 0.0)
			# Wheels ON the pad rather than sunk into it: the body ORIGIN rides this far
			# above the ground plane a live car rests on. See the note above the function.
			c.position = Vector3(0.0, c.settled_ride_height(), 0.0)
			# Intangible. FREEZE_MODE_STATIC deliberately keeps its collider (that is how a
			# wreck stays a solid obstacle), and car.tscn authors no layer/mask, so without
			# this the ghost would sit on the player's own layer and block him.
			c.collision_layer = 0
			c.collision_mask = 0
			_make_translucent(c),
	})
	# Droop the wheel visuals to their ANALYTIC rest pose (a frozen prop's solver never runs, so
	# without this the wheels stay tucked up in the arches). Deliberately NOT
	# settle_wheels_to_ground: that samples the terrain under each wheel's CURRENT global
	# position, and this body is built parked in `_ghost_parking` at the manager's origin and
	# then re-parented between zones — so a ground-sampled droop would bake in the wrong
	# terrain. The pads are flat, so the analytic rest plane is the right answer everywhere.
	if body.has_method("settle_wheel_visuals"):
		body.settle_wheel_visuals()
	var node := body as Node3D
	_ghost_bodies[model_id] = node
	return node


# Face the middle of the map, exactly as the table's prize-car props do (hq gathers them
# toward HQ so the map reads as cars parked around it rather than a row all pointing one way).
# Derived in MAP space, since map_pos x -> world X and y -> world Z.
func _ghost_yaw(zone: OverworldZone) -> float:
	var to_hq := RallyLibrary.HQ_MAP_POS - RallyLibrary.map_pos_of(zone.rally)
	if to_hq.is_zero_approx():
		return 0.0
	# atan2(x, z) yaws a +Z-forward node onto the heading; car.tscn faces -Z, hence the half
	# turn. HqController.PRIZE_CAR_FACING_TURN rather than an inlined PI: hq.gd created that
	# constant precisely so "the cars point the wrong way" is a ONE-value fix, and a literal
	# here would leave every overworld ghost facing backwards the day it is flipped.
	return atan2(to_hq.x, to_hq.y) + HqController.PRIZE_CAR_FACING_TURN


# The rival-ghost LOOK, reused rather than reinvented: a per-mesh unshaded StandardMaterial3D
# copying the source material's albedo texture and tint, at `rival_ghost_opacity`, writing
# depth so the body self-occludes instead of reading as an x-ray.
#
# Why it is re-expressed here instead of called: `GhostCar._ghost_material` / `_make_translucent`
# are private INSTANCE methods on a Node that also owns a replay, a pace solver and a dust
# system — there is no static seam to call, and instantiating a GhostCar for a parked
# decoration would drag all of that in. Keep this in step with `ghost_car.gd` (see
# features/rival-ghost.md); if that material ever becomes static, delete this and call it.
func _make_translucent(node: Node) -> void:
	var alpha := clampf(Config.data.rival_ghost_opacity, 0.0, 1.0)
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		var mesh := mi as MeshInstance3D
		mesh.material_override = _ghost_material(mesh.get_active_material(0), alpha)


func _ghost_material(source: Material, alpha: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Write depth even though this blends — otherwise the near side blends against the far
	# side and the car reads as an x-ray at any opacity.
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	mat.albedo_color = Color(1.0, 1.0, 1.0, alpha)
	if source is ShaderMaterial:
		var sm := source as ShaderMaterial
		var tex: Variant = sm.get_shader_parameter("albedo_texture")
		if tex != null:
			mat.albedo_texture = tex
		var tint: Variant = sm.get_shader_parameter("albedo_color")
		if tint != null:
			var c3: Color = tint
			mat.albedo_color = Color(c3.r, c3.g, c3.b, alpha)
	elif source is BaseMaterial3D:
		var bm := source as BaseMaterial3D
		mat.albedo_texture = bm.albedo_texture
		mat.albedo_color = Color(bm.albedo_color.r, bm.albedo_color.g, bm.albedo_color.b, alpha)
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	return mat
