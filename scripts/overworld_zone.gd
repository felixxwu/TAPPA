class_name OverworldZone
extends Node3D
# ONE trigger zone on the drivable overworld map — the life-size replacement for clicking a
# pin on the HQ map table (docs/superpowers/specs/2026-08-17-overworld-hq-design.md, slice 2).
#
# The contract: park inside the circle and stay parked, and after `overworld_zone_dwell_s`
# the zone activates once. ANY movement resets the accumulator to zero, so driving off is
# always the cancel gesture — there is no confirm prompt to fight with, and no way to be
# dragged into a rally you were only passing through.
#
# Two things live here and nowhere else:
#
#   * the dwell state machine (`tick`), which is deliberately PURE of scene state — it takes
#     an injected delta, car position and speed, so a headless test drives activation without
#     a physics server, a viewport or a car;
#   * the LIGHT TUBE that shows how far into the dwell you are, and doubles as the "this is
#     a place" landmark at distance.
#
# What does NOT live here: the marker/icon/ghost above the zone (`overworld_marker.gd`), the
# map_pos -> world conversion (owned by `overworld.gd` — the world position arrives as an
# argument), and the decision of which zones are live at all (`overworld_zones.gd`).

# Fired exactly once per completed dwell. Re-arms only after the dwell is broken (the player
# moved or left), so a car left parked on a zone does not machine-gun the signal.
signal activated(rally_id: String)


# --- Tube proportions, in UNIT space ----------------------------------------------------
# Not tunables: these are the SHAPE of the tube, not its size. The size is
# `Config.data.overworld_zone_radius_m` (radius) and `overworld_zone_tube_height_m` (height),
# both applied as a node scale, so a retune moves the tube without rebuilding its mesh.
const TUBE_SIDES := 24           # radial segments: enough that the silhouette reads round
const TUBE_RINGS := 10           # vertical steps the alpha gradient is baked across
const TUBE_FADE_POW := 1.8       # gradient shape: >1 keeps the base solid and dumps most of
                                 # the fade into the upper half, so the column has a foot
const TUBE_LIFT_M := 0.05        # how far the base floats above the sampled ground, so the
                                 # first ring does not z-fight the terrain it stands on
const TUBE_BAND_FRACTION := 0.06 # the sweeping fill line's height, as a fraction of the tube
const TUBE_BAND_SWELL := 1.06    # ...and how much wider than the tube it sits, so it pops
# How fast a broken dwell drains back to zero, as a multiple of the fill rate. Draining
# rather than snapping is what makes "driving cancels it" legible instead of just sudden.
const DRAIN_RATE := 2.5

var rally: Dictionary = {}
var rally_id := ""
# The zone centre in world space. Supplied by the overworld (which owns the coordinate
# conversion); the zone never derives it.
var centre := Vector3.ZERO

# 0..1 progress through the dwell. Public for the HUD/tests; written only by `tick`.
var progress := 0.0

# Exempt this zone from the fog gate. Set for the GARAGE, which is a destination rather than
# a rally: it carries no `map_pos` in the roster, so `rally_revealed` would answer false for
# it forever and the player could never reach their own garage. Rally zones leave this false
# and are gated normally — this must never be used to open a dark rally.
var always_revealed := false

var _revealed := false
# The profile `refresh_revealed` last gated on — defaults to the live one. See that function.
var _gate_profile: Dictionary = {}
# Already completed (a podium finish, persisted) — dims the idle tube. See `refresh_completed`.
var _completed := false
# Has the car been seen OUTSIDE this zone since it was built? Until it has, the zone cannot
# fire — see the arm-on-exit note in `tick`.
var _armed := false
var _fired := false
var _area: Area3D = null
var _shape: SphereShape3D = null
var _tube_root: Node3D = null
var _tube_body: MeshInstance3D = null
var _tube_fill: MeshInstance3D = null
var _tube_band: MeshInstance3D = null
var _body_mat: StandardMaterial3D = null
var _fill_mat: StandardMaterial3D = null
var _band_mat: StandardMaterial3D = null
var _applied_radius := -1.0

# ONE unit-space tube mesh for every zone in the game. Every tube is the same shape — the
# radius and height are node scale — so building it per zone would be 38 copies of one
# resource. Built lazily on the first zone that has visuals, so a headless run never makes it.
static var _unit_tube: ArrayMesh = null


# Build the zone. `world_pos` is the ground point for the rally's map_pos, already converted
# by the caller. `visuals` off skips every mesh — headless tests want the state machine only.
func setup(p_rally: Dictionary, world_pos: Vector3, visuals := true) -> void:
	rally = p_rally
	rally_id = String(p_rally.get("id", ""))
	centre = world_pos
	position = world_pos
	refresh_revealed()
	refresh_completed()
	_build_area()
	if visuals:
		_build_tube()
	_apply_radius(radius())


# The live trigger radius. Read per call rather than cached at build time so retuning
# `overworld_zone_radius_m` in the inspector takes effect on the next frame.
func radius() -> float:
	return maxf(Config.data.overworld_zone_radius_m, 0.01)


# The live tube height. Same live-read discipline as `radius()`.
func tube_height() -> float:
	return maxf(Config.data.overworld_zone_tube_height_m, 0.0)


# The radius the TUBE is currently drawn at, in metres — i.e. what the player sees they must
# park inside. It is deliberately derived from the same `radius()` the trigger test uses, so
# a test can assert the two AGREE without pinning either. -1.0 with visuals off.
func tube_radius() -> float:
	if _tube_root == null:
		return -1.0
	return _tube_root.scale.x


# The normalised height of the LIT portion of the tube, 0..1 — the fill line's position, and
# the one number every colour/alpha/geometry decision in `_push_progress` is derived from.
# Exposed so a headless test can assert that progress drives the visual state without needing
# a renderer (or asserting a colour, which would pin a palette value).
func fill_fraction() -> float:
	return clampf(progress, 0.0, 1.0)


# The tube's root node, or null when the zone was built with `visuals: false`. The headless
# guard, asserted directly by the tests.
func tube_node() -> Node3D:
	return _tube_root


func dwell_seconds() -> float:
	return maxf(Config.data.overworld_zone_dwell_s, 0.0)


func stop_kmh() -> float:
	return maxf(Config.data.overworld_zone_stop_kmh, 0.0)


# Re-evaluate the fog gate. Uses RallyLibrary.rally_revealed — THE predicate that gates
# entry everywhere else (hq.gd's pins, the eligibility query, the reward walk) — never a
# lookalike distance test that could drift from it. Called on build and whenever the manager
# rebuilds after a completion; the activation path re-checks it too, so a stale cache can
# never open a dark zone.
func refresh_revealed(profile: Dictionary = Save.profile) -> void:
	# Remember WHICH profile gated this zone, so the activation re-check in `tick` asks the same
	# question this answered. Without it a caller that deliberately gates on a non-live profile
	# (the manager's `setup`/`refresh` both accept one) would be silently overruled by
	# Save.profile at the moment of firing — the two would disagree about the same zone.
	_gate_profile = profile
	if always_revealed:
		_revealed = true
		return
	_revealed = not rally.is_empty() and RallyLibrary.rally_revealed(rally, profile)
	# Push the new gate onto the tube immediately. A FAR zone is never ticked (OverworldZones
	# only ticks what is near), so without this a zone that lit while the player was elsewhere
	# would keep its hidden tube until he drove up to it — the reveal would arrive silently.
	_push_progress()


func revealed() -> bool:
	return _revealed


# Re-evaluate the persisted completion flag — a podium finish from a PREVIOUS visit
# (`RallyLibrary.rally_completed`), never this visit's live `fill_fraction()`/`done`, which
# `_push_progress` already tracks on its own. Same calling convention and same call sites as
# `refresh_revealed` (build, and whenever the manager rebuilds after a completion), so the two
# stay in lockstep rather than one silently lagging the other.
func refresh_completed(profile: Dictionary = Save.profile) -> void:
	_completed = not rally.is_empty() and RallyLibrary.rally_completed(rally, profile)
	_push_progress()


func completed() -> bool:
	return _completed


# The tube BODY's current alpha, or -1.0 with visuals off — same headless-guard convention as
# `tube_radius()`. Exposed so a test can assert the completed-dimming RELATIONSHIP (dimmer than
# an otherwise-identical incomplete zone, by the configured scale) without reaching into the
# material directly or pinning an alpha value.
func tube_body_alpha() -> float:
	if _body_mat == null:
		return -1.0
	return _body_mat.albedo_color.a


# The tube BODY's current colour (RGB, alpha aside), or transparent black with visuals off.
# Exposed alongside `tube_body_alpha()` for the same reason: a headless test can assert the
# incomplete/completed/locked/completion-snap tint without reaching into the material.
func tube_body_color() -> Color:
	if _body_mat == null:
		return Color(0.0, 0.0, 0.0, 0.0)
	var c := _body_mat.albedo_color
	return Color(c.r, c.g, c.b, 1.0)


# Horizontal containment. The Area3D exists (and carries the same radius) so the zone is a
# real physics volume for anything that wants to detect it, but the dwell gate uses this
# instead: a flat-plane distance test is independent of how deep in a dip the car sits, and
# it works with no physics server at all, which is what makes `tick` unit-testable.
func contains(point: Vector3) -> bool:
	var r := radius()
	var dx := point.x - centre.x
	var dz := point.z - centre.z
	return dx * dx + dz * dz <= r * r


# Distance from the zone centre on the ground plane — the manager's sort key for draw
# distance and the ghost-car cap.
func plane_distance_to(point: Vector3) -> float:
	return sqrt(plane_distance_sq_to(point))


# The same measure SQUARED, for the per-frame threshold tests. OverworldZones asks every zone
# every frame whether the car is within reach; doing that through plane_distance_to allocated a
# Vector2 and took a sqrt per zone per frame (38 zones x 60 Hz = ~2,280 of each per second)
# purely to compare against a constant. Compare against `reach * reach` instead and neither
# happens. The sqrt is still right for the marker sort key, which runs a few times a second.
func plane_distance_sq_to(point: Vector3) -> float:
	var dx := point.x - centre.x
	var dz := point.z - centre.z
	return dx * dx + dz * dz


# THE state machine. Advance the dwell by `delta` given where the car is and how fast it is
# going, and emit `activated` if this tick completes it.
#
# Everything it needs is an argument, so a test calls it in a loop with synthetic values.
# Returns true on the tick that activated, for callers that would rather poll than connect.
func tick(delta: float, car_pos: Vector3, speed_kmh: float) -> bool:
	_apply_radius(radius())
	# ARM ON EXIT. A zone will not fire until it has seen the car OUTSIDE it at least once, so
	# merely STARTING inside one can never activate it. Two ways that happens and both are real:
	# the garage sits at RallyLibrary.HQ_MAP_POS, which is also the default spawn for a profile
	# with no completed rally — so a new player would be parked in the garage zone from frame one
	# and teleported into the garage a few seconds after arriving, having done nothing. And a
	# player returning from a rally is parked beside the zone they just entered, which would
	# otherwise re-fire it and bounce them straight back out.
	#
	# Deliberately not "wait for movement": a player who arrives, stops, and never touches the
	# controls should not be dragged anywhere.
	if not contains(car_pos):
		_armed = true
	var parked := _armed and contains(car_pos) and speed_kmh <= stop_kmh()
	if not parked:
		# ANY movement (or leaving) resets to zero and re-arms. The drain is only what the
		# ring SHOWS; the logical accumulator is gone the instant the car moves, which is the
		# product requirement — the player can always cancel by driving.
		_fired = false
		progress = maxf(progress - delta * DRAIN_RATE / maxf(dwell_seconds(), 0.001), 0.0)
		_push_progress()
		return false
	if not _revealed:
		# An unrevealed zone refuses to accumulate at all, so it can neither activate nor
		# advertise a countdown it would never honour.
		progress = 0.0
		_push_progress()
		return false
	var dwell := dwell_seconds()
	progress = 1.0 if dwell <= 0.0 else minf(progress + delta / dwell, 1.0)
	_push_progress()
	if progress < 1.0 or _fired:
		return false
	# Authoritative re-check at the moment of truth, against the shared predicate. Skipped for
	# an always-revealed destination (the garage), which no roster predicate describes.
	if not always_revealed and not RallyLibrary.rally_revealed(rally, _gate_profile):
		_revealed = false
		progress = 0.0
		_push_progress()
		return false
	_fired = true
	activated.emit(rally_id)
	return true


# Drop the accumulator without emitting — used when the manager parks the zone (the player
# left the neighbourhood, or a panel opened over the top of it).
func reset_dwell() -> void:
	progress = 0.0
	_fired = false
	_push_progress()


# CANCEL. The player opened this zone's rally panel and backed out of it — so the zone must
# neither grab them again on the spot nor go dead.
#
# The dwell latch alone is not enough for this. `_fired` blocks a re-emit only while the car
# stays parked and stops the instant it moves, so a cancelled zone would re-fire the moment the
# player shifted a metre while still inside the circle — and dropping the latch instead would
# re-fire after `overworld_zone_dwell_s` without the player touching anything, which is the
# open-panel loop.
#
# So cancelling DISARMS the zone, reusing the arm-on-exit rule `tick` already runs on: the
# accumulator drains to zero (the tube visibly collapses, so the cancel reads), and nothing can
# re-arm it until the car has been seen OUTSIDE the circle again. "Drive out and come back" is
# then the only way in, which is exactly what backing out of the panel should mean — and it
# cannot be permanent, because leaving re-arms it like any other zone.
func cancel_dwell() -> void:
	progress = 0.0
	_fired = false
	_armed = false
	_push_progress()


# Is this zone armed — i.e. has the car been seen outside it since it was built or cancelled?
# The headless seam for the cancel behaviour above.
func armed() -> bool:
	return _armed


func has_fired() -> bool:
	return _fired


# --- Internals -------------------------------------------------------------------------


func _build_area() -> void:
	_area = Area3D.new()
	_area.name = "ZoneArea"
	_area.monitoring = false      # nothing subscribes; the dwell gate is the distance test
	_area.monitorable = true      # ...but the volume is there for anything that wants it
	var col := CollisionShape3D.new()
	_shape = SphereShape3D.new()
	col.shape = _shape
	_area.add_child(col)
	add_child(_area)


# The LIGHT TUBE: a transparent column standing on the zone, fading out towards the sky.
#
# It replaces the old flat ground annulus for two reasons. It is visible from far further away
# (the ring vanished to a line at a shallow camera angle, which is the angle you drive at), and
# its radius IS the trigger radius seen edge-on from any direction, so what you see is what you
# must park in rather than a foreshortened ellipse.
#
# Three instances of ONE shared unit mesh (`_unit_tube`), all in the root's unit space:
#
#   Body  the always-there landmark column, full height, dim.
#   Fill  the same column scaled down in Y to `fill_fraction()` — the lit portion, whose TOP
#         EDGE is a readable fill line rather than a brightness the player has to guess at.
#   Band  a thin bright ring riding that top edge, so the fill line is unmissable as it sweeps.
#
# No per-frame allocation and no mesh rebuild: `_push_progress` only writes scales and material
# colours.
func _build_tube() -> void:
	_tube_root = Node3D.new()
	_tube_root.name = "DwellTube"
	_tube_root.position = Vector3(0.0, TUBE_LIFT_M, 0.0)
	add_child(_tube_root)

	_body_mat = _tube_material(UITheme.MUTED)
	_tube_body = _tube_instance("TubeBody", _body_mat)
	_fill_mat = _tube_material(UITheme.GREEN)
	_tube_fill = _tube_instance("TubeFill", _fill_mat)
	_band_mat = _tube_material(UITheme.INK)
	_tube_band = _tube_instance("TubeBand", _band_mat)
	_push_progress()


func _tube_instance(node_name: String, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = _shared_tube_mesh()
	mi.material_override = mat
	# A light shaft casts no shadow — and 38 of them casting one would be a real cost.
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_tube_root.add_child(mi)
	return mi


# The tube material. UNSHADED so it does not go dark under the sky's lighting (it is meant to
# be its own light source), alpha-blended, DOUBLE-SIDED so it reads from inside as well as
# outside, and it does NOT write depth — the car parked in it, the terrain and the marker
# floating above must all stay visible through it.
#
# The vertical fade is baked into the MESH's vertex colours and multiplied in here via
# `vertex_color_use_as_albedo`, rather than being a shader. That is the cheapest route in this
# codebase's idiom: it keeps every tube on the one shared mesh, needs no extra material
# variant per zone, and leaves `albedo_color` free as the single per-zone dial that
# `_push_progress` writes (tint and overall alpha) without touching geometry.
func _tube_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = color
	return mat


# The shared unit tube, for the OTHER things in this hub that draw a light column — today the
# garage's stop tube (`OverworldGarage._build_stop_tube`). Public so nothing outside this file
# has to build a second copy of the same geometry: one mesh, one upload, one place to change
# the shape. The caller supplies its own material and its own node scale.
static func unit_tube_mesh() -> ArrayMesh:
	return _shared_tube_mesh()


# One unit tube for the whole game: radius 1 in XZ, height 1 in +Y from the origin, open at
# both ends, with the sky-fade baked into its vertex colours (white, alpha 1 at the base ->
# alpha 0 at the top, shaped by TUBE_FADE_POW).
static func _shared_tube_mesh() -> ArrayMesh:
	if _unit_tube != null:
		return _unit_tube
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	for ring in TUBE_RINGS + 1:
		var v := float(ring) / float(TUBE_RINGS)
		var a := 1.0 - pow(v, TUBE_FADE_POW)
		for i in TUBE_SIDES:
			var ang := TAU * float(i) / float(TUBE_SIDES)
			verts.append(Vector3(cos(ang), v, sin(ang)))
			colors.append(Color(1.0, 1.0, 1.0, a))
	for ring in TUBE_RINGS:
		for i in TUBE_SIDES:
			var i0 := ring * TUBE_SIDES + i
			var i1 := ring * TUBE_SIDES + (i + 1) % TUBE_SIDES
			var j0 := i0 + TUBE_SIDES
			var j1 := i1 + TUBE_SIDES
			indices.append_array(PackedInt32Array([i0, j0, j1, i0, j1, i1]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_unit_tube = mesh
	return _unit_tube


# Push the live radius onto the Area3D shape and the unit-space tube. Cheap and idempotent —
# it only touches anything when the config value actually changed. The HEIGHT is written by
# `_push_progress` instead (it runs every tick anyway), so both stay live-retunable.
func _apply_radius(r: float) -> void:
	if is_equal_approx(r, _applied_radius):
		return
	_applied_radius = r
	if _shape != null:
		_shape.radius = r
	if _tube_root != null:
		# Y is the tube HEIGHT (also written by `_push_progress`, which runs every tick) — take
		# it from config here too, or a radius retune would flatten the column for a frame.
		_tube_root.scale = Vector3(r, tube_height(), r)


# THE single place the dwell becomes something you can look at. Everything below is derived
# from `progress` and nothing else, so the state machine stays the only source of truth.
func _push_progress() -> void:
	if _tube_root == null:
		return
	# AN UNREVEALED ZONE SHOWS NO TUBE AT ALL. The column is the "this is a place you can go"
	# landmark — it is the one thing about a zone that is legible from kilometres away — so a
	# dark zone drawing a dim one advertised a destination the player cannot enter, and the
	# roads leading there are now barriered off (OverworldBlocks) precisely to say the opposite.
	# The markers already work this way (`OverworldZones._refresh_markers` skips unrevealed
	# zones), so this makes the tube agree with them instead of leaking the roster.
	#
	# The tube stays visible at EVERY range for a revealed zone: that one is a real destination,
	# and seeing it across the valley is how the player navigates to it.
	_tube_root.visible = _revealed
	var h := tube_height()
	_tube_root.scale = Vector3(_tube_root.scale.x, h, _tube_root.scale.z)
	var p := fill_fraction()
	var base_a := clampf(Config.data.overworld_zone_tube_alpha, 0.0, 1.0)
	var ready_a := clampf(Config.data.overworld_zone_tube_ready_alpha, 0.0, 1.0)
	# A rally already completed on a PREVIOUS visit dims to a quiet resting state — done-and-
	# quiet against the ones still worth driving to. Only the idle end of the range: parking
	# here again still ramps the fill/band up to `ready_a` exactly as an incomplete zone does,
	# via the `lerpf(base_a, ready_a, p)` below, so re-entering a completed rally still gives
	# full dwell feedback.
	if _completed:
		base_a *= clampf(Config.data.overworld_zone_tube_completed_alpha_scale, 0.0, 1.0)
	var done := p >= 1.0

	# The body keeps the locked/unlocked distinction the old ring carried, and now also the
	# incomplete/completed one: an unrevealed zone is an olive-grey column that never lights, a
	# revealed-but-not-yet-completed one is plain white (INK — the palette's off-white), and a
	# rally already completed on a previous visit is the positive green — so green means "done",
	# not merely "reachable", at a glance from across the map.
	var rest_tint := UITheme.GREEN if _completed else UITheme.INK
	var body_tint := UITheme.MUTED if not _revealed else rest_tint
	if done:
		# COMPLETION SNAP. The whole column goes gold at full strength on the tick that fires —
		# a punctuation mark the player cannot miss, and one that costs no timer (it is a pure
		# function of progress, so `tick` stays untouched).
		body_tint = UITheme.GOLD
	_body_mat.albedo_color = _tinted(body_tint, ready_a if done else base_a * body_tint.a)

	# The FILL is the same column squashed to the dwell fraction, so its top edge is a fill
	# line with a readable position — far stronger than a brightness ramp, which tells you
	# something is happening but not how far through you are. Ramps from the SAME resting tint
	# the body just used (white for an incomplete rally, green for a completed one) up to gold,
	# so the fill agrees with what the idle column was already showing.
	var lit := _revealed and p > 0.0
	_tube_fill.visible = lit
	_tube_fill.scale = Vector3(1.0, maxf(p, 0.0001), 1.0)
	_fill_mat.albedo_color = _tinted(rest_tint.lerp(UITheme.GOLD, p), lerpf(base_a, ready_a, p))

	# ...and the BAND rides that edge, sweeping up as it fills and collapsing back down at
	# DRAIN_RATE when the player drives off, which is what makes a broken dwell read instantly.
	# It is retired at completion so the gold snap above is the only thing left on screen.
	_tube_band.visible = lit and not done
	_tube_band.position = Vector3(0.0, p - TUBE_BAND_FRACTION * 0.5, 0.0)
	_tube_band.scale = Vector3(TUBE_BAND_SWELL, TUBE_BAND_FRACTION, TUBE_BAND_SWELL)
	_band_mat.albedo_color = _tinted(UITheme.INK.lerp(UITheme.GOLD, p), ready_a)


# A palette colour at an explicit alpha — the palette's own alpha is a UI convention and the
# tube needs its own.
func _tinted(color: Color, alpha: float) -> Color:
	return Color(color.r, color.g, color.b, clampf(alpha, 0.0, 1.0))
