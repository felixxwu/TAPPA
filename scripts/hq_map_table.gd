class_name HqMapTable
extends RefCounted
# Docs: features/hq.md, features/map-exploration.md, features/prize-rallies.md — update in the
# same change as this file.
# Tests: tests/headless/test_hq_map_table.gd, tests/headless/test_menu_flow.gd — extend in the
# same change. These are the PRIMARY ones, not all of them: before you change behaviour here,
# `grep -rn 'HqMapTable\|_refresh_map_pins' tests/headless/` and read the assertions that pin
# what you are about to change.
# The PIN LAYER of the HQ map table: everything that is DRAWN on the map plane and rebuilt as
# the profile changes — the rally pins (flag / trophy / prize-car marker), their floating
# readout boxes, the dotted reveal graph under them, and the exploration fog the whole map is
# shaded by. Cut out of hq.gd (todo/hq-split.md) to shrink it; nothing about the behaviour
# changed, this is a code move plus the `_hq.` wiring.
#
# The split against HqTable (scripts/hq_table.gd) is DRAWING vs. NAVIGATING: this file builds
# the pins, HqTable walks them (focus cursor, panning, the reveal parade, opening the detail
# panel). The two meet at exactly two calls — HqTable asks for a rebuild
# (`_hq._refresh_map_pins`) and paints one pin's readout (`_hq._paint_pin_readout`) — both of
# which are thin forwarders on HqController so hq_table.gd and the tests keep resolving them by
# the names they already use.
#
# Holds a back-reference to the HqController and reaches into it for the pin PARENT and the
# table STATE (_pins, _pins_root, _map_plane, _pins_stamp, _table_focus_node,
# _table_targets_cache) — the same shape as HqOverlays / HqChallenge / HqMultiplayer /
# HQEnvironment. That state stays on the controller because HqTable and hq.gd both read it.
#
# The prize-car prop CACHE lives here (below), because nothing outside these functions touches
# it.

var _hq: HqController


func _init(hq: HqController) -> void:
	_hq = hq


# --- 3D map pins -------------------------------------------------------------

# (Re)build the rally pins on the table's map plane: a state-coloured flag marker
# (RallyFlag) at each rally's normalised map_pos, with a billboarded house-style black
# box above it holding the rally name and a row of five-pointed stars (1st-place best →
# 3 gold, 2nd → 2, 3rd → 1, else dim). The flag colour encodes the medal tier; the
# special pin is locked (grey/disabled, non-pickable) until it falls inside a lit circle
# from a completed or opening rally; see RallyLibrary.rally_revealed.
#
# `hold_locked` forces the pins with those rally ids to render in their LOCKED look even
# though they are open — the new-rally reveal needs the "before" state on screen so the
# flip to unlocked is something the player actually watches happen (see
# _table_ui._run_reveal_sequence). Empty everywhere else.
func _refresh_map_pins(hold_locked: Array = []) -> void:
	# NOTHING CHANGED SINCE THE LAST BUILD -> keep the pins we have.
	#
	# _build_hq already builds the full pin set at boot, behind the loading cover, and then
	# _enter_table calls this AGAIN on every single table entry (it is the hook the reveal
	# parade needs for `hold_locked`, and where fresh stars land). That second pass freed and
	# rebuilt all ~32 pins — ~20 ms of pure CPU with no GPU work counted, plus 32 fresh
	# SubViewport render targets — in the exact frame the camera starts its glide to the
	# table, which is where a hitch is most visible. Skipping it is what makes "tap the
	# table" cheap; see features/menus.md -> "What a map-table entry costs".
	#
	# The two trailing side effects still run below: the camera has usually MOVED (a table
	# entry re-centres _table_pan), so selection has to be re-seated even when the pins are
	# identical, and the meter is a one-line string write.
	var stamp := _map_pins_stamp(hold_locked)
	if stamp == _hq._pins_stamp and not _hq._pins.is_empty() and _pins_all_valid():
		_hq._table_ui._select_target_under_center()
		_hq._refresh_meter()
		return
	_hq._pins_stamp = stamp
	_detach_prize_car_props()
	_hq._table_targets_cache = null  # pins are being rebuilt — force a fresh target set
	# The pin this pointed at is about to be freed; clearing it states the invariant the
	# focus-repaint guard relies on instead of leaning on a freed-object comparison.
	_hq._table_focus_node = null
	for c in _hq._pins_root.get_children():
		c.queue_free()
	_hq._pins = []
	var cfg: GameConfig = Config.data
	# One world map, loaded once — there is no per-region map any more — shaded by the
	# exploration fog so only what the player has reached is lit.
	_apply_map_fog()
	var p: Vector3 = cfg.hq_table_pos
	var size: Vector2 = cfg.hq_map_plane_size
	var top_y := p.y + cfg.hq_table_size.y + 0.02
	# Hoisted OUT of the pin loop: both answers are the same for every pin in this refresh,
	# and both are expensive — nearest_locked_special_id walks every special through
	# distance_beyond_frontier (which rebuilds lit_sources), so asking it per pin was ~32×
	# the work for one answer. This refresh runs on every table entry AND on every step of
	# the reveal parade, so it sat directly under the map's responsiveness.
	var next_special := RallyLibrary.nearest_locked_special_id(Save.profile)
	for rally in RallyLibrary.all():
		# EVERY rally is pinned, reached or not. The fog dims what the player cannot get to
		# rather than deleting it: the map is a map, and a world that only exists where you
		# have already driven gives you nothing to steer by. What the dark withholds is the
		# ROUTE and the ability to enter — not the knowledge that something is there.
		var pin := _make_pin(rally, p, size, top_y,
			hold_locked.has(String(rally["id"])), next_special)
		_hq._pins_root.add_child(pin)
		# AFTER the pin is in the tree: a prize car's 3D model is a real car.tscn instance,
		# whose _ready has to have run before CarProp.spawn's apply_car touches it.
		if pin.has_meta("prize_car_model"):
			_attach_prize_car_marker(pin)
		_hq._pins.append(pin)
	# The reveal graph, under the pins: a faint dotted line wherever completing one REVEALED
	# rally would light another one that is also already revealed.
	_build_reveal_links(p, size, top_y)

	# NO HQ LANDMARK. A house used to stand at the middle of the map, marking the point
	# every reveal circle grew out of. HQ lights nothing now — the player's OPENING RALLY
	# is where exploration starts (todo/opening-rally.md, RallyLibrary.lit_sources) — so
	# the middle is ordinary fogged ground, and a building sitting in it would advertise a
	# centre the map no longer has.

	# Re-seat the cursor on whatever pin sits nearest the view centre (no camera
	# pan) so it never sits at -1 while the table actually has pins to focus —
	# every entry point into the table (fresh open, test harness) goes through here.
	_hq._table_ui._select_target_under_center()
	_hq._refresh_meter()


# EVERY input the pin set is rendered from, in one comparable value — the rebuild-skip
# predicate for _refresh_map_pins.
#
# Deliberately CONSERVATIVE and deliberately COARSE: it hashes the whole profile and the
# whole of each authored table rather than picking out the fields the pins happen to read
# today. A stamp that misses an input leaves a STALE MAP (a pin that stays grey after the
# rally that lights it, a star row a win behind), which is a far worse failure than an
# occasional needless rebuild — so anything that could plausibly move a pin goes in.
#
# **If you make the pins read something new, add it here.** The Config entries are the map
# geometry + the fog/reveal values (they are authored, so they only move in the inspector or
# in a test), and the table hashes cover both the shipped catalogues and a test's
# `override_for_test` / fixture roster.
func _map_pins_stamp(hold_locked: Array) -> Array:
	var cfg: GameConfig = Config.data
	return [
		Save.profile.hash(),          # completions, best placements, stars, cars, upgrades
		hold_locked.duplicate(),      # the reveal parade's held-back set (changes per step)
		RallyLibrary.all().hash(),    # roster: names, map_pos, restrictions, prizes
		CarLibrary.all().hash(),      # _has_eligible_car / prize-car models
		UpgradeLibrary.all().hash(),  # _entry_plan's effective stats, _special_unlock_line
		cfg.hq_table_pos, cfg.hq_table_size, cfg.hq_map_plane_size,
		cfg.map_fog_unlit_brightness, cfg.map_fog_edge_softness,
		cfg.map_reveal_radius, cfg.map_hq_reveal_radius,
		cfg.map_link_alpha, cfg.map_link_dash_m, cfg.map_link_gap_m,
		cfg.map_link_width_m, cfg.map_link_color,
		cfg.map_link_outline_width_m, cfg.map_link_outline_color,
	]


# Are the pins we are holding still real nodes? A freed pin means something outside this
# function tore the map down, so the stamp must not be trusted to stand in for it.
func _pins_all_valid() -> bool:
	for pin in _hq._pins:
		if not is_instance_valid(pin):
			return false
	return true


# How far the link lines float above the map plane. Coplanar geometry z-fights, and at this
# camera distance the flicker is far more noticeable than the offset.
const MAP_LINK_LIFT := 0.004


# Prize-car props, cached per CarLibrary model id so the map's rebuilds do not re-instantiate
# them. See _attach_prize_car_marker for why this matters.
var _prize_car_props: Dictionary = {}


# Unparent every cached prize car so the imminent queue_free() of the pins cannot take them
# with it. They are re-parented onto the new pins by _attach_prize_car_marker.
func _detach_prize_car_props() -> void:
	for model_id in _prize_car_props:
		var prop: Node3D = _prize_car_props[model_id]
		if is_instance_valid(prop) and prop.get_parent() != null:
			prop.get_parent().remove_child(prop)


# Draw the map's REVEAL GRAPH over the ground the player has lit: a faint dotted line
# between every pair of REVEALED rallies where finishing one would light the other.
#
# The graph was always there — it is what map_pos means now — but it was invisible, so the
# map looked like a scatter of pins and the player had to infer the chain by driving it.
# Showing it makes the route they took readable off the table: you can see that this rally
# is what opened those two, and that the corner they reached hangs off a different thread
# entirely. Where it runs OUT into the dark it is not drawn — see reveal_link_pairs.
#
# It is drawn to be READ, not hinted at. It began as a near-transparent hairline on the
# theory that a bold graph would compete with the pins; in practice the opposite was true —
# 1-pixel PRIMITIVE_LINES at 22% alpha over a full-brightness map texture were invisible,
# so the table still looked like an unconnected scatter and the feature paid for itself in
# nothing. It is now a real-width ribbon with a dark outline under it (see
# _add_link_ribbons). Everything about that is authored: map_link_width_m, map_link_color,
# map_link_alpha and the map_link_outline_* pair, so it can be dialled back down without
# touching this code if it ever does start crowding the pins.
#
# Only edges with BOTH ends out of the fog are drawn — the pairing rule and its reasoning
# live in RallyLibrary.reveal_link_pairs, next to the reveal predicate they come from, so
# what the table draws and what the map actually opens can never drift apart. This function
# is purely the geometry: ids in, dashes on the table out.
func _build_reveal_links(table_pos: Vector3, plane_size: Vector2, top_y: float) -> void:
	var cfg: GameConfig = Config.data
	if cfg.map_link_alpha <= 0.0:
		return
	var pin_pos := {}
	for rally in RallyLibrary.all():
		pin_pos[String(rally["id"])] = RallyLibrary.map_pos_of(rally)
	# Collect the segments FIRST, then build the surface — ImmediateMesh errors on
	# surface_end() with nothing added, which is a real case here: a fresh profile with a
	# single lit pin, or a synthetic roster whose pins all sit further apart than any reveal
	# radius, produces no links at all.
	var segments: Array[Vector3] = []
	# HQ is NOT a link source. It used to be the one the whole graph grew out of, but it
	# lights nothing now — every reveal circle belongs to a rally (RallyLibrary.lit_sources),
	# so a spoke from the middle would draw an edge that no longer exists.
	for pair in RallyLibrary.reveal_link_pairs(Save.profile):
		_dash_line(segments,
			_map_to_table(pin_pos[pair[0]], table_pos, plane_size, top_y),
			_map_to_table(pin_pos[pair[1]], table_pos, plane_size, top_y))
	if segments.is_empty():
		return
	var mesh := ImmediateMesh.new()
	# OUTLINE FIRST, then the bright core on top of it. Two surfaces on one mesh rather
	# than two nodes, so the pair can never be separated or drawn out of order.
	var core: Color = cfg.map_link_color
	core.a = cfg.map_link_alpha
	if cfg.map_link_outline_width_m > 0.0:
		_add_link_ribbons(mesh, segments, cfg.map_link_outline_width_m,
			cfg.map_link_outline_color, 0.0)
	_add_link_ribbons(mesh, segments, cfg.map_link_width_m, core, MAP_LINK_CORE_LIFT)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	_hq._pins_root.add_child(mi)


# How far the bright core floats above its own outline. Both sit above the map plane by
# MAP_LINK_LIFT; this is the second, smaller separation that keeps the two coplanar ribbons
# from z-fighting with EACH OTHER.
const MAP_LINK_CORE_LIFT := 0.0015


# Turn a flat list of dash endpoint PAIRS into flat ribbons of the given width, as one
# unshaded surface on `mesh`.
#
# WHY RIBBONS AND NOT PRIMITIVE_LINES: a line primitive is one PIXEL wide whatever the
# camera does, and the game renders at a 400-px-tall target — so the graph came out as a
# hairline that aliased into a dashed shimmer and vanished against the lit map. A quad has
# a real width in metres, so it scales with the table like everything else on it.
#
# The ribbon is extruded in the table's PLANE (XZ) rather than toward the camera: the map
# is a flat surface viewed from roughly above, so an in-plane extrusion reads as a drawn
# line on the map, while a camera-facing one would lift off it as the view swung round.
func _add_link_ribbons(mesh: ImmediateMesh, segments: Array[Vector3], width: float,
		col: Color, lift: float) -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED  # the table is orbited; never cull a face
	mat.disable_receive_shadows = true
	mat.albedo_color = col
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, mat)
	var half: float = maxf(width, 0.001) * 0.5
	var up := Vector3(0.0, lift, 0.0)
	for i in range(0, segments.size() - 1, 2):
		var a: Vector3 = segments[i] + up
		var b: Vector3 = segments[i + 1] + up
		var span := a.distance_to(b)
		if span <= 0.00001:
			continue
		var dir := (b - a) / span
		# Perpendicular within the table plane. The dash is also extended by half a width
		# at each end, so the corners of consecutive dashes don't leave a visible notch and
		# a very short dash still renders as a square rather than a sliver.
		var perp := Vector3(-dir.z, 0.0, dir.x) * half
		var cap := dir * half
		var p0 := a - cap - perp
		var p1 := a - cap + perp
		var p2 := b + cap + perp
		var p3 := b + cap - perp
		mesh.surface_add_vertex(p0)
		mesh.surface_add_vertex(p1)
		mesh.surface_add_vertex(p2)
		mesh.surface_add_vertex(p0)
		mesh.surface_add_vertex(p2)
		mesh.surface_add_vertex(p3)
	mesh.surface_end()


# A rally's normalised map_pos as a world point on the table top. Mirrors _make_pin's
# placement so a link always lands on its pin's base rather than near it.
func _map_to_table(mp: Vector2, table_pos: Vector3, plane_size: Vector2, top_y: float) -> Vector3:
	return Vector3(table_pos.x, top_y + MAP_LINK_LIFT, table_pos.z) + Vector3(
		(mp.x - 0.5) * plane_size.x, 0.0, (mp.y - 0.5) * plane_size.y)


# Emit `from`->`to` as a dashed run of line segments. Dashes are laid along the segment at a
# fixed metre pitch rather than as a fraction of its length, so a long link and a short one
# read as the same kind of line instead of one looking finely stippled and the other coarse.
func _dash_line(out: Array[Vector3], from: Vector3, to: Vector3) -> void:
	var cfg: GameConfig = Config.data
	var span := from.distance_to(to)
	if span <= 0.0001:
		return
	var dir := (to - from) / span
	var pitch: float = maxf(cfg.map_link_dash_m + cfg.map_link_gap_m, 0.001)
	var travelled := 0.0
	while travelled < span:
		var dash_end: float = minf(travelled + cfg.map_link_dash_m, span)
		out.append(from + dir * travelled)
		out.append(from + dir * dash_end)
		travelled += pitch


# Add a pickable sphere Area3D (radius `r`, at local `pos`) to `pin`, routing clicks to
# `handler`. The node setup lives here once so every hit target on the map is built the
# same way — the flag/trophy body and the floating readout box each get one.
# --- Exploration fog ---------------------------------------------------------
# The map is DARK except where the player has driven (features/map-exploration.md). The
# lit region is rasterised into a small mask texture and multiplied into the map plane by a
# shader, so the fog is one texture upload per reveal change and nothing per frame.
#
# The mask is deliberately COARSE and bilinear-filtered: the circles' edges come out soft
# for free, which reads as a frontier rather than a stencil, and a 64x64 image costs
# nothing to rebuild whenever a rally is completed.
# Re-exported from MapFog rather than duplicated, so the table and the overworld can never
# disagree about the mask's resolution (see the build_fog_mask note below).
const FOG_MASK_SIZE := MapFog.MASK_SIZE
# How dark the unreached map goes and how soft the frontier's rim is both live in
# GameConfig (map_fog_unlit_brightness / map_fog_edge_softness) — they are pure LOOK values,
# which is where this project keeps those so they can be retuned in the inspector.

const FOG_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled;
uniform sampler2D map_tex : source_color, filter_nearest_mipmap;
uniform sampler2D fog_mask : filter_linear;
uniform float unlit_brightness;
void fragment() {
	vec3 map = texture(map_tex, UV).rgb;
	// The mask is 1 inside the explored region and 0 outside; bilinear sampling across the
	// coarse grid is what gives the frontier its soft edge.
	float lit = texture(fog_mask, UV).r;
	ALBEDO = map * mix(unlit_brightness, 1.0, lit);
}
"""

static var _fog_shader: Shader


# Paint the map plane with the world map, darkened everywhere the player has not explored.
func _apply_map_fog() -> void:
	if _fog_shader == null:
		_fog_shader = Shader.new()
		_fog_shader.code = FOG_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = _fog_shader
	mat.set_shader_parameter("map_tex", load(RegionLibrary.DEFAULT_MAP_IMAGE))
	mat.set_shader_parameter("fog_mask", HqController.build_fog_mask(Save.profile))
	mat.set_shader_parameter("unlit_brightness", Config.data.map_fog_unlit_brightness)
	_hq._map_plane.material_override = mat


# ONE height for every floating readout on the table, whatever marker stands under it.
#
# Per-marker heights were tried and read worse, not better: a car's box sat low, a trophy's
# mid, a flag's high, so panning across the map made the menus bob up and down and the eye
# had to re-find the line on every pin. A single height turns them into one row the player
# reads along. Set to clear the TALLEST marker (the flag pole at 0.30) so no box covers the
# model it belongs to.
const PIN_LABEL_HEIGHT := 0.46
# Scale the car prop is shrunk to so it reads as a map token rather than a vehicle parked on
# the table. Derived from the largest car in the catalogue so the biggest body still sits
# inside a pin's footprint — a fixed metre size would clip the moment a longer car is added.
const PRIZE_CAR_PIN_LENGTH_M := 0.34
# Where a prize car's model tops out — only used to seat the car itself, not its readout,
# which hangs at the shared PIN_LABEL_HEIGHT like every other pin's.
const PRIZE_CAR_MARKER_TOP := 0.10


# The 3D car a CAR-UNLOCK rally stands on its pin: the actual model of the car you win,
# shrunk to map-token size. This is the map's whole incentive structure — you can SEE what
# is out there and go and take it — so it is the real model rather than an icon.
#
# `dim` (an unreached pin) renders it hazy and dark: a distant landmark you can make out but
# not reach yet. Ordinary rallies stay hidden entirely in the dark, so what the fog leaves
# visible is exactly the set of destinations worth choosing a direction for.
func _attach_prize_car_marker(pin: Node3D) -> void:
	var model_id := String(pin.get_meta("prize_car_model"))
	var index := CarLibrary.index_of(model_id)
	if index < 0:
		return  # a synthetic car roster that does not hold this model — no marker to stand
	var dim: bool = bool(pin.get_meta("locked"))
	# REUSE the prop if we have already built one for this car.
	#
	# _refresh_map_pins frees and rebuilds every pin, and it runs often — on entering the
	# table, and once PER RALLY inside the reveal parade. Rebuilding the car props each time
	# cost about a second: CarProp.spawn instantiates car.tscn (which embeds nine car meshes),
	# prunes eight of them, then duplicates every mesh resource that survives — ten times
	# over, for props that are identical between rebuilds.
	#
	# So they are built once per model and re-parented thereafter. The cache is detached
	# before the pins are freed (see _detach_prize_car_props), which is what stops
	# queue_free() taking the cached props down with their old pin.
	if _prize_car_props.has(model_id):
		var cached: Node3D = _prize_car_props[model_id]
		if is_instance_valid(cached):
			pin.add_child(cached)
			_set_marker_dim(cached, dim)
			return
		_prize_car_props.erase(model_id)
	var holder := Node3D.new()
	pin.add_child(holder)
	_prize_car_props[model_id] = holder
	# Shrink to a token. CarLibrary.max_car_bounds() is the longest body in the catalogue, so
	# every prize car lands at a consistent scale rather than the big ones dwarfing the small.
	var longest := maxf(CarLibrary.max_car_bounds().z, 0.001)
	var scale_f := PRIZE_CAR_PIN_LENGTH_M / longest
	# Seat it in the `configure` step, NOT after spawn: apply_car ends in _reset(), which
	# puts the car back at its spawn transform (metres above the table). Every other
	# CarProp caller positions its prop the same way for the same reason — do it here and
	# the reset undoes it.
	# Face the middle of the map. Left at a fixed heading the cars all point the same way
	# whichever corner they sit in, which reads as a row of parked models; aiming them
	# inward makes the table look like cars gathered around the garage.
	#
	# Derived in MAP space (the rally's map_pos toward HQ_MAP_POS) rather than from any node
	# transform. The holder sits at the pin's own origin, so its position is always zero —
	# reading a direction off it produced no rotation at all.
	#
	# map_pos x -> world X and y -> world Z (hq._make_pin), so the map-space vector is
	# already a world-space heading on the table plane.
	var mp := RallyLibrary.map_pos_of(RallyLibrary.by_id(String(pin.get_meta("rally_id"))))
	var to_hq := RallyLibrary.HQ_MAP_POS - mp
	var yaw := 0.0
	if not to_hq.is_zero_approx():
		# atan2(x, z) yaws a +Z-forward node onto the heading; car.tscn faces -Z (Godot's
		# convention), hence the half turn. Flip PRIZE_CAR_FACING_TURN if a future car model
		# is authored the other way round.
		yaw = atan2(to_hq.x, to_hq.y) + HqController.PRIZE_CAR_FACING_TURN
	# The spawned node is not kept: everything downstream (the dim pass below, the cache in
	# _prize_car_props, the detach before a rebuild) works through `holder`, the pin-local
	# parent it is spawned under.
	CarProp.spawn(holder, _hq._car_scene_res(), {
		"index": index,
		"stop_physics": true,
		"disable_process": true,
		"configure": func(c: Node3D) -> void:
			c.transform = Transform3D.IDENTITY
			c.rotation = Vector3(0.0, yaw, 0.0)
			c.scale = Vector3(scale_f, scale_f, scale_f),
	})
	if dim:
		# Hazy, and NON-pickable (the caller adds no hit sphere to a locked pin): a landmark,
		# not a target.
		_set_marker_dim(holder, true)


# How faded an unreached PRIZE pin reads — model and readout alike. Enough to sit clearly
# "behind the fog" without becoming invisible: the player is meant to see what is out there,
# but never to mistake it for something they can click yet.
#
# Transparency is the strongest available cue for "not yet", because it is the only one that
# survives the marker's own state colouring: a locked trophy is already grey, and a prize
# car keeps its paint on purpose (that paint is what makes the model recognisable), so
# neither can say "unavailable" through colour alone.
const FOGGED_PIN_DIM_ALPHA := 0.55


# Fade or un-fade a marker so it reads as behind the fog (or comes back out of it). Shared
# by both prize markers, so a car and a trophy sit at the same remove rather than each
# fading its own amount. GeometryInstance3D.transparency fades a prop without touching its
# materials — a tint override would have to replace them and would cost the car its paint.
#
# Takes a flag rather than only fading, because a CACHED prize car outlives the pin it was
# built for: the same prop can be locked on one refresh and open on the next, so the fade
# has to be re-applied BOTH ways or a car stays ghosted after the player has reached it.
func _set_marker_dim(node: Node, dim: bool) -> void:
	var alpha := FOGGED_PIN_DIM_ALPHA if dim else 0.0
	for mesh in node.find_children("*", "GeometryInstance3D", true, false):
		(mesh as GeometryInstance3D).transparency = alpha


func _add_pick_sphere(pin: Node3D, pos: Vector3, r: float, handler: Callable) -> void:
	var area := Area3D.new()
	var cs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = r
	cs.shape = sph
	area.add_child(cs)
	area.position = pos
	area.input_ray_pickable = true
	# Pure click target — overlap monitoring is unused (see hq_environment.gd).
	area.monitoring = false
	area.monitorable = false
	area.input_event.connect(handler)
	pin.add_child(area)


# `next_special` is the id nearest_locked_special_id returned for this whole refresh —
# passed in rather than asked per pin, because the answer is identical for every pin and
# the query is not cheap (see _refresh_map_pins).
func _make_pin(rally: Dictionary, table_pos: Vector3, plane_size: Vector2, top_y: float,
		hold_locked := false, next_special := "") -> Node3D:
	var rally_id := String(rally["id"])
	# Locked = not revealed yet: the pin is not inside any lit circle
	# (RallyLibrary.rally_revealed). A locked pin renders grey + non-pickable — a "coming
	# up" hint, not enterable. (There is no star gate and no reveal_after any more; reveal
	# is purely geometric — see features/map-exploration.md.)
	var locked: bool = hold_locked or not RallyLibrary.rally_revealed(rally, Save.profile)
	var mp: Vector2 = rally.get("map_pos", Vector2(0.5, 0.5))
	# map_pos is normalised 0..1; centre the map plane, x→world X, y→world Z.
	var local := Vector3((mp.x - 0.5) * plane_size.x, 0.0, (mp.y - 0.5) * plane_size.y)
	var pin := Node3D.new()
	pin.position = Vector3(table_pos.x, top_y, table_pos.z) + local
	pin.set_meta("rally_id", rally_id)
	pin.set_meta("locked", locked)

	# The marker. An ordinary rally plants a procedural FLAG whose look encodes its state —
	# a checkered pennant once podiumed, else green (an eligible car is owned) or grey (none
	# / locked), with a gold tip+base once won. A star-gated SPECIAL stands a TROPHY instead:
	# the prestige event on its corner shouldn't read as one more flag, and a cup can show
	# WHICH medal you took (gold / silver / bronze) where a pennant only says "podiumed".
	# Both markers share the same base footprint and the same two state axes, so the map
	# keeps one visual language. See RallyFlag / RallyTrophy / features/menus.md.
	var earned := _hq._stars_for(rally_id)
	var has_eligible := _hq._has_eligible_car(rally)
	# What the rally AWARDS picks the marker, because the marker's whole job on a dark map is
	# to advertise a destination (features/prize-rallies.md):
	#   * a CAR prize stands the actual 3D car — self-describing, so it needs no label;
	#   * a PART prize stands a TROPHY (we have no part models, and a trophy at least reads
	#     as "something is won here") — which is why a part pin keeps its box open, below;
	#   * everything else plants the ordinary FLAG whose look encodes medal state.
	var prize_car := RallyLibrary.prize_car_id(rally)
	var prize_part := RallyLibrary.prize_part_id(rally)
	var marker_top: float
	# Resolve the model HERE, not at attach time: a prize naming a car the current catalogue
	# does not hold (a synthetic test roster) must fall through to the ordinary marker, so
	# that every pin always stands SOMETHING. A pin with no marker is invisible on the map.
	if prize_car != "" and CarLibrary.index_of(prize_car) >= 0:
		# The car prop is attached LATER, once this pin is in the tree — car.tscn's _ready
		# builds the damage model, and CarProp.spawn's apply_car needs it. Building it here
		# would run apply_car against a node that has never entered the tree.
		pin.set_meta("prize_car_model", prize_car)
		marker_top = PRIZE_CAR_MARKER_TOP
	else:
		var trophy := prize_part != "" or RallyLibrary.is_special(rally)
		var marker := (RallyTrophy.build(locked, earned, has_eligible) if trophy
			else RallyFlag.build(locked, earned, has_eligible))
		pin.add_child(marker)
		# Everything unreached fades, flag or trophy alike — the fog treats all pins the same.
		if locked:
			_set_marker_dim(marker, true)
		# Where the floating readout box hangs — each marker reports its own top, since a
		# trophy is a different height from a flag pole.
		marker_top = RallyTrophy.HEIGHT if trophy else RallyFlag.POLE_HEIGHT

	# Readout: a single design-system black box floating above the flag, holding the
	# rally name and a row of proper five-pointed stars (gold earned / dim not). Built
	# as a 2D UITheme panel rendered to a billboarded sprite, so it gets the real house
	# look (pure-black panel, Syne Mono, uppercase) and always faces the camera.
	#
	# THE BOX IS ALL-OR-NOTHING, with ONE exception. An ordinary rally that can't be entered
	# yet — locked, or with no eligible car — gets NO box rather than a dimmed one: a menu is
	# either live and at full opacity, or absent. The 3D flag still stands at every pin, so
	# the map keeps showing where the unavailable rallies are (grey flag = "coming up").
	#
	# THE EXCEPTION: the NEXT locked SPECIAL — the one nearest the player's frontier, per
	# RallyLibrary.nearest_locked_special_id — gets a box, at FULL opacity but non-pickable,
	# naming what it unlocks. Locking must hide availability, never information — the player
	# should be able to see what exists and where to earn it long before they can have it.
	# Full opacity keeps the all-or-nothing rule intact (the box is live-looking, it just
	# isn't a target); the grey trophy beneath already says "not yet".
	#
	# ONLY the nearest one, though: a special further out is not something the player can
	# work on yet, and eight teasers at once buried
	# the map under menus that were all unreachable. The further specials still STAND THEIR
	# TROPHIES — the destination is still signposted, it just doesn't quote a number until it
	# is the one in front of you.
	var locked_special := locked and RallyLibrary.is_special(rally) \
		and rally_id == next_special
	var available := not locked and has_eligible
	# EVERY pin's readout is hover-only — prize pins included. A table of a dozen open menus
	# reads as a noticeboard rather than a map, and one rule for all pins means panning
	# across the table shows exactly one box at a time wherever the cursor is.
	#
	# A prize pin still needs its name readable BEFORE it is reachable, which is why the
	# cursor is allowed to hover an unreached prize (hq_table._unlocked_pins) even though it
	# refuses to open one.
	# ONE readout rule for every pin, whatever it stands and whatever state it is in: the box
	# is always built, always starts HIDDEN, and is shown only while the cursor is on it. That
	# is what keeps the table a map rather than a noticeboard, and it means a pin the player
	# cannot enter yet still ANSWERS when they point at it.
	#
	# FADED when the rally is not enterable — out in the fog, or reachable but with nothing in
	# the garage that fits. A full-opacity box over a ghosted marker would read as a live menu,
	# which is the opposite of what the fade says. The box is non-pickable either way (no hit
	# sphere is added below), so the fade is the honest visual for "look, don't touch".
	var pin_label := (_build_special_teaser_label(rally) if locked_special
		else _build_pin_label(String(rally["name"]), earned, rally))
	pin_label.position = Vector3(0.0, PIN_LABEL_HEIGHT, 0.0)
	pin.add_child(pin_label)
	pin_label.visible = false
	if not available:
		pin_label.modulate = Color(1.0, 1.0, 1.0, FOGGED_PIN_DIM_ALPHA)
	# The PANEL so the focus cursor can paint the hover-style selection look, and the SPRITE
	# so the focus pass can show/hide the whole box rather than only repainting its inside.
	pin.set_meta("label_panel", pin_label.get_meta("panel"))
	pin.set_meta("label_sprite", pin_label)

	# Pickable hit spheres (skipped for a locked pin so it can't be entered), both bound
	# to the same handler so a click on EITHER the flag/pole OR the floating readout box
	# enters the rally. The box target makes the menu itself tappable (a bigger, easier
	# target than the slim flag); its radius is kept under half the closest pin spacing
	# (~0.72 m) so neighbouring menus' targets don't overlap.
	if not locked:
		_add_pick_sphere(pin, Vector3(0.0, marker_top * 0.5, 0.0), 0.28,
			_hq._on_pin_input.bind(rally_id))
		# Only where a box actually hangs — an unavailable pin has none, and a hit sphere
		# floating in the empty air above its flag would be a target for nothing.
		if available:
			_add_pick_sphere(pin, Vector3(0.0, PIN_LABEL_HEIGHT, 0.0), 0.32,
				_hq._on_pin_input.bind(rally_id))
	return pin


# Build the floating readout box for a pin: a design-system black panel holding the
# rally name (Syne Mono, uppercase) above a row of proper StarRow stars, composited in
# an off-screen SubViewport and shown on a billboarded Sprite3D so it always faces the
# camera as one unit. The viewport owns the sprite as a child so it's freed with the pin.
# Build a billboarded floating readout sprite: a content-hugging house panel centred in
# a transparent SubViewport (so only the black box shows), with `build_body` filling the
# VBox. Dimmed when `dim` (reads as disabled), and hands its panel back via the "panel"
# meta so the focus cursor / selection can repaint it.
func _build_readout_sprite(build_body: Callable) -> Sprite3D:
	var vp := SubViewport.new()
	vp.size = HqController.PIN_LABEL_PX
	vp.transparent_bg = true
	vp.gui_disable_input = true
	# STARTS DISABLED, and only the HOVERED box ever renders — see _paint_pin_readout, which
	# drives this in lockstep with the sprite's visibility.
	#
	# This used to be UPDATE_ALWAYS, which meant every pin's off-screen 400x150 viewport
	# re-composited its panel EVERY FRAME from the moment HQ booted: ~32 of them (one per
	# rally) redrawing ~1.9 MP/frame of UI that was invisible — the sprites all start hidden,
	# and the player is usually standing in the garage or on the title shot with the table
	# nowhere near the camera. The content is static (a name, a star row, a focus underline),
	# so there is nothing for a per-frame update to catch.
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	vp.add_child(center)

	var panel := UITheme.panel(1.0, 14)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_child(box)

	build_body.call(box)

	UITheme.enforce(panel)  # house rules: uppercase + one font size
	# ...then override the SIZE for this one surface. A map readout is not a flat 2D menu:
	# it is composited in a SubViewport and then shown on a billboard out on the table, so it
	# loses resolution twice before the player sees it, and at the map's viewing distance the
	# house 16 is genuinely hard to read. Every OTHER menu in the game keeps UITheme.FONT_SIZE
	# — this is the one medium that needs its own, not a licence to grow type elsewhere.
	for lbl in panel.find_children("*", "Label", true, false):
		(lbl as Label).add_theme_font_size_override("font_size", HqController.PIN_LABEL_FONT_SIZE)
	# No drop shadow on a floating readout. The global theme gives every Label a hard black
	# shadow (build_ui_theme.gd), which is the terminal look elsewhere but is invisible on a
	# black panel. Cleared here rather than in the theme so the rest of the UI keeps the
	# house look. Runs AFTER enforce so nothing it does re-lightens the text.
	for node in panel.find_children("*", "Label", true, false):
		var lbl := node as Label
		lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0))
		lbl.add_theme_constant_override("shadow_offset_x", 0)
		lbl.add_theme_constant_override("shadow_offset_y", 0)

	var sprite := Sprite3D.new()
	sprite.add_child(vp)
	sprite.texture = vp.get_texture()
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sprite.shaded = false
	sprite.pixel_size = HqController.PIN_LABEL_PIXEL_SIZE
	sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	sprite.set_meta("panel", panel)
	sprite.set_meta("viewport", vp)  # _paint_pin_readout arms/disables it with the visibility
	return sprite


# Show or hide ONE pin's floating readout, and arm its off-screen viewport to match.
#
# THE SINGLE PLACE a readout's visibility changes, so the render target can never be left
# compositing a box nobody is looking at (the old UPDATE_ALWAYS bill — see
# _build_readout_sprite). Shown boxes take UPDATE_ALWAYS rather than a one-shot UPDATE_ONCE
# on purpose: it is ONE viewport at a time (readouts are hover-only), and a continuously
# updating target cannot be caught out by a Control that finishes its deferred container
# sort a frame after the box went up — a single render taken too early would bake a blank
# or mis-sized panel and never correct it. SubViewports draw before the main viewport in the
# same frame, so arming here also means no blank frame as the box appears.
#
# Also carries the focus repaint (the hover-style underline) so the two can't drift apart.
func _paint_pin_readout(pin: Node3D, shown: bool) -> void:
	if pin.has_meta("label_panel"):
		UITheme.mark_panel_focused(pin.get_meta("label_panel"), shown)
	if not pin.has_meta("label_sprite"):
		return
	var sprite: Node3D = pin.get_meta("label_sprite")
	if not is_instance_valid(sprite):
		return
	sprite.visible = shown
	var vp: SubViewport = sprite.get_meta("viewport", null) as SubViewport
	if is_instance_valid(vp):
		vp.render_target_update_mode = (SubViewport.UPDATE_ALWAYS if shown
			else SubViewport.UPDATE_DISABLED)


# ONE readout-box builder for every pin variant, so the box styling lives in a single
# place. `stars` < 0 omits the medal row (the locked-special teaser has no result to show);
# `unlock` == "" omits the unlock line. Always full opacity — see _make_pin on why a locked
# special's box is live-looking but non-pickable rather than dimmed. Hands its panel back so
# the pin can repaint it on selection.
func _build_readout_box(title: String, stars: int, unlock: String) -> Sprite3D:
	return _build_readout_sprite(func(box: VBoxContainer) -> void:
		box.add_theme_constant_override("separation", UITheme.GAP)
		box.add_child(UITheme.title(title))
		if stars >= 0:
			var row := StarRow.new()
			row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			box.add_child(row)
			row.setup(stars, HqController.MAX_STARS)
		if unlock != "":
			box.add_child(_hq.label(unlock, 13)))


# An enterable rally: name, medal row, and — for a special — what it unlocks, so the map
# answers "where do I get X?" whether the special is locked or not.
func _build_pin_label(rally_name: String, earned: int, rally: Dictionary = {}) -> Sprite3D:
	return _build_readout_box(rally_name, earned, _special_unlock_line(rally))


# The locked-special teaser box: the event's NAME over "unlocks Supercharger".
#
# It used to quote a progress fraction ("3/4 rallies") against the old global completion
# counter. There is no counter any more — a special opens when the player lights the map
# out to it — so there is no number to show, and inventing a distance readout ("0.08 map
# units away") would be noise. Naming the event is the honest teaser: it says WHAT is out
# there and WHAT it gives, and the dark map around it already says "not yet". Locking hides
# availability, never information.
func _build_special_teaser_label(rally: Dictionary) -> Sprite3D:
	# -1 stars: the star row is suppressed, since an unreached event has no result to show.
	return _build_readout_box(String(rally.get("name", "")), -1, _special_unlock_line(rally))


# The garage USED TO carry a permanent "next carrot" line — the map's locked-special
# teaser (_build_special_teaser_label) promoted onto the station the player lands on after
# every rally, first as "2 more rallies → The Woodland Trial", later as the event's bare
# name. It is GONE, panel and all. The specials it named are mostly part-unlock rallies
# titled after their own reward ("Upgrade: Supercharger"), so with no count left to quote
# and no unlock subtitle to add (_special_unlock_line is empty for exactly those), the line
# degenerated to a bare rally name standing over the garage saying nothing about why it was
# there. The map table still teases the same special ON the map, where its position IS the
# explanation — the one place that fact reads.


# What a special unlocks, as a display line ("unlocks Supercharger"), derived from the
# upgrade catalogue so the map can never drift from the actual gate. A special that gates
# no part (e.g. the engine-swap capability) names that instead.
func _special_unlock_line(rally: Dictionary) -> String:
	var rally_id := String(rally.get("id", ""))
	if rally_id == "":
		return ""
	# A part-unlock rally is NAMED after the part it awards ("Upgrade: Big Turbo"), so an
	# "unlocks Big Turbo" line under it just says the title again. The subtitle exists to add
	# something the name does not; where the name already carries the reward, it earns
	# nothing and is dropped.
	if not UpgradeLibrary.unlocked_by(rally_id).is_empty():
		return ""
	# A special may gate a CAPABILITY rather than a part, which is authored the other way
	# round (RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY) and so isn't in the catalogue index. That
	# one still needs the line — its name says nothing about engine swapping.
	if rally_id == RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY:
		return "unlocks engine swaps"
	return ""
