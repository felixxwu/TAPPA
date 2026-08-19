class_name OverworldMap
extends CanvasLayer
# THE OVERWORLD'S MAP — one script, two presentations, one drawing routine.
#
# THREE SURFACES RENDER RALLY PINS — do not conclude a pin feature exists (or is missing)
# from the wrong one:
#   * THIS FILE — the 2D MAP SCREEN: the top-left minimap and the M-key full map.
#   * scripts/overworld_marker.gd + overworld_zones.gd — the floating 3D signs above zones
#     in the drivable world. These carry a star-row readout; this map screen's pins do NOT.
#   * scripts/hq.gd — the HQ's diegetic map table, with its own StarRow readout.
# A readout on one surface does not exist on the others; check the surface the request
# actually names before adding — or before reporting it already done.
#
#   * MINIMAP — a small always-on panel in the TOP-LEFT corner, showing the player's
#     neighbourhood. Heading-up by default.
#   * FULL MAP — a full-screen overlay on `toggle_map` (M / gamepad Back), showing the whole
#     1 km² at once with names on the pins.
#
# WHY BOTH, AND WHY NOW. This REPLACED a compass strip (since deleted) that answered "which way
# do I turn for X, and how far is it" — a bearing and a distance. That cannot answer "where do the
# roads go", "what is behind me", "am I near the coast". That is LAYOUT, and layout needs a
# picture. The play report was "it's pretty hard to find your way around here".
#
# WHERE THE MINIMAP SITS. The panel is anchored TOP CENTRE (see the `_minimap` setup below for
# why, now that the compass strip that used to own the middle of the top band is gone). The rest
# of the overworld view's furniture is already spoken for: `pause_menu.gd` parks its pause button
# at PRESET_TOP_RIGHT; `mobile_controls.gd` lays its gas/brake/steer furniture along the BOTTOM
# band on touch devices.
#
# WHY THE MINIMAP IS HEADING-UP (and why that is a flag). A bearing relative to where the car
# is FACING is directly actionable — "the road bends left" reads as left. A north-up minimap
# forces the player to mentally rotate every frame. So `overworld_minimap_rotate_with_heading`
# ships true, and a NORTH INDICATOR ("N" on a stalk) is drawn regardless, so the rotating panel
# can still be correlated with the full map (which is always north-up). Flip the flag for a
# north-up minimap if the rotation ever reads as motion sickness rather than as guidance.
#
# ==========================================================================================
# DO NOT DRAW `textures/map_world.jpg` UNDER THIS. IT WOULD LIE.
# ==========================================================================================
# The HQ map table draws that photographic world map, and reusing it here is tempting. It is
# WRONG. The overworld's ground is procedural Perlin noise from `TerrainManager` — it is NOT
# derived from that image (deriving land/sea from its palette was a slice-4 aspiration that was
# never implemented). Its coastline, forests and mountains therefore do not correspond to the
# ground the player is driving on, and a map that disagrees with the world is worse than no map.
#
# So everything drawn here comes from GROUND TRUTH:
#   roads      `OverworldRoads.edges()` polylines, already in world XZ.
#   pins       revealed rally zones by kind, plus the garage.
#   the player position + heading, passed in per frame.
#   fog        `MapFog.build(profile)` — the SAME 64×64 mask the terrain shader multiplies in.
#   the edge   `Overworld.bounds_for(size_m)` — the coastline.
#
# IF the terrain is ever actually derived from `textures/map_world.jpg` (or from any authored
# heightmap), then a photographic underlay becomes correct and is very welcome: draw it in
# `_paint_ground` under the roads, in the same world-space transform everything else uses. Until
# then, schematic only.
#
# ==========================================================================================
# INPUT — the full map is A MENU, so CLAUDE.md's nav rule applies in full.
# ==========================================================================================
#   OPEN / CLOSE   `toggle_map`  — M (keyboard) and gamepad Back/Select (button 4).
#   CLOSE          `ui_cancel` / `menu_back` — Esc, gamepad B.
#   SELECT         left / right / up / down on `ui_*` (arrows, D-pad, left stick) AND `menu_*`
#                  (WASD, D-pad) cycle the SELECTED destination, wrapping in both directions;
#                  the selected pin is ringed and its name + distance shown in the footer.
#   POINT          mouse move / touch drag HOVERS the nearest pin within
#                  `overworld_map_pick_px`; a click or tap SELECTS it and sets the route.
#   ROUTE          `ui_accept` (Enter / gamepad A) or a click/tap on a pin sets the SAT-NAV
#                  route to it; `ui_accept` on the pin that already owns the route clears it.
#
# ONLY ONE NAME IS DRAWN. Every pin used to carry its name, which on a revealed roster turned the
# full map into a wall of overlapping capitals with the roads invisible underneath — the map
# stopped answering "where do the roads go", which is the only reason it exists. The name now
# belongs to the pin the player is ASKING about: the hovered one, or the selected one when nothing
# is hovered. The other pins still say what they are by their glyph and colour.
# There are no focusable widgets, so this uses the `hq.gd::_unhandled_input` pattern rather than
# `MenuNav.attach` (which drives focus between flat widgets). It still asks
# `MenuNav.input_blocked(self)`, so a ConfirmPopup or another screen-claiming overlay makes it
# deaf, and its root joins `MenuNav.SCREEN_CLAIMER_GROUP` so the rest of the UI goes deaf while
# the map is up.
#
# DRIVING WHILE THE MAP IS OPEN: we LOCK THE CAR'S CONTROLS (`Car.controls_locked`), we do NOT
# pause the tree. Two reasons. (1) `get_tree().paused` is owned by `pause_menu.gd`, which flips
# it on open and clears it on resume — a second owner means one of them clears the other's
# pause, which is exactly the "menu floating over live gameplay" bug pause_menu's own header
# warns about. (2) The overworld STREAMS: `Overworld._process` builds chunks, streams foliage,
# evicts the chunk cache and re-checks the region look. Pausing it mid-drive freezes the world
# builder, and the terrain the player is reading the map to drive onto stops arriving. Locked
# controls is the same gate the start-line staging uses (`controls_locked` during the build and
# the countdown), so the car simply coasts to a halt with no throttle or steering input.
#
# It also cannot fight the pause menu: the host supplies `can_toggle`, which is false while
# `PauseMenu.is_open()`, and Esc reaches this layer first (added to the tree after PauseMenu)
# where it closes the map and marks the event handled, so Esc never opens a pause screen over
# an open map.
#
# ==========================================================================================
# COST
# ==========================================================================================
# The minimap redraws while driving, so:
#   * road polylines are captured ONCE in `setup` (world XZ, straight off `OverworldRoads`),
#     together with a per-edge AABB for culling; nothing is rebuilt or converted per frame;
#   * drawing uses `draw_set_transform` so the world->screen map is ONE transform and the raw
#     world-space point arrays are handed to `draw_polyline` unmodified — no per-frame allocation;
#   * `queue_redraw` is gated: the minimap only repaints when the car has actually moved
#     `_MOVE_EPSILON_M` or turned `_TURN_EPSILON_RAD`;
#   * the pin GLYPHS are authored once as shared unit-space point arrays and positioned by a
#     single `draw_set_transform` per pin, so no polygon is built per pin per frame; a PART pin's
#     icon texture is resolved once in `setup` (a catalogue walk) and cached on the entry;
#   * the fog texture is rebuilt only on `refresh()` (open, and on the refresh timer), never
#     per frame;
#   * the revealed destination set is recomputed on the same timer, so the expensive half of the
#     work is split off from the cheap half rather than both running per frame.
#
# HEADLESS. `setup({"visuals": false})` (and any `--headless` run) builds no Control and no fog
# texture, while the MODEL — `destinations()`, `selected()`, `select_step()`, `is_open()` and the
# static projection helpers — is fully live. That is what makes every assertion in
# `tests/headless/test_overworld_map.gd` possible with no renderer.

# What kind of thing a destination is. Mirrors `OverworldMarker.Kind`, so a map pin and the 3D
# marker above the zone can never disagree about what a rally promises.
enum Kind {RALLY, CAR, PART, SPECIAL, GARAGE}

## The garage's destination id. Must match `Overworld.GARAGE_ZONE_ID`; a literal rather than a
## reference deliberately: a literal keeps this file free of any compile-time
## dependency on the 1,300-line scene script that loads it.
const GARAGE_ID := "garage"
const GARAGE_LABEL := "Garage"

## The ROAD GRAPH's name for the garage node (`OverworldRoads._build_nodes`), which is NOT
## `GARAGE_ID` — the road network keys its nodes by rally id and needs a name no roster entry can
## collide with. Duplicated as a literal for the same reason `GARAGE_ID` is: no compile-time
## dependency, and this file must not be the one that breaks if the road builder is swapped out.
## `_road_end_open` is the only reader.
const _HQ_NODE_ID := "__hq__"

## The input action that opens and closes the full map. Declared in `project.godot` bound to M
## and to gamepad Back. NOTE: deliberately NOT in `InputRemap.ACTIONS` — that list is the
## driving controls, and adding a row there is a change to a file this work does not own. If the
## map ever wants to be rebindable, add `{"action": "toggle_map", "name": "Map"}` there.
const TOGGLE_ACTION := "toggle_map"

## Canvas layer. Above the compass strip and the HUD, below `ConfirmPopup`'s modal layer (101)
## and below the pause overlay's own furniture, so a modal is never drawn under the map.
const LAYER := 40

# How often the revealed set and the fog mask are recomputed. Nothing here changes faster than
# a rally completion, so this is generous; the DRAWING still follows the car every frame.
const REFRESH_INTERVAL_S := 0.5

# Redraw gates for the minimap: below these the picture would be identical to the last one.
const _MOVE_EPSILON_M := 0.35
const _TURN_EPSILON_RAD := 0.01

# Geometry the drawing needs but no designer would ever retune — shapes, not sizes. Every
# SIZE, ZOOM, WIDTH and ALPHA is a GameConfig field (see `_cfg_*` below).
const _ARROW_LONG := 1.15       # player arrow nose length, in pin radii
const _ARROW_WIDE := 0.72       # player arrow half-width, in pin radii
const _NORTH_STALK := 0.62      # north indicator distance from the panel centre, as a fraction
                                # of the panel's half-extent
const _SELECT_RING := 1.7       # selection ring radius, in ICON half-extents
const _LABEL_GAP_PX := 6.0      # gap between a full-map pin and its name

# ==========================================================================================
# PIN GLYPHS — shape carries WHAT, colour carries STATE
# ==========================================================================================
# The pins used to be flat coloured circles, which meant the map could only say "there is
# something here, and it is gold" — the player still had to open the full map and read the name to
# learn whether gold meant a car or a part. So each kind now draws an ICON:
#
#   PART     the PART'S OWN texture (`OverworldMarker.part_texture`) — the very same
#            `UpgradeIcons` art the upgrades grid tiles and the floating 3D marker wear, so the
#            three can never disagree. This is the one kind real art exists for.
#   RALLY    a pennant on a pole, mirroring `RallyFlag` (the 3D marker for the same kind).
#   CAR      THAT car's own side profile, traced from its body model (`CarSilhouettes`, baked by
#            tools/bake_car_silhouettes.gd), so the pin says which car is on offer. A car with
#            nothing baked — one added since the last bake — falls back to the generic
#            hatchback body + two wheel bumps below (`_G_CAR_BODY`), which is also what a
#            plain rectangle cannot do: read as a car.
#   SPECIAL  a trophy cup, mirroring `RallyTrophy`.
#   GARAGE   a house: a box under a pitched roof. Unmistakably not a rally.
#   player   still an arrow (heading is half the answer to "where am I"), now with an ink
#            outline so it stays the most salient thing on a busy full map.
#
# GEOMETRY IS AUTHORED ONCE, IN UNIT LOCAL SPACE (roughly -1..1 on both axes, +y DOWN like the
# screen), as `static var` packed arrays shared by every instance. Drawing a pin pushes ONE
# `draw_set_transform(p, 0, icon_px)` and hands these arrays to `draw_colored_polygon` /
# `draw_polyline` UNMODIFIED — so a minimap frame with a dozen pins allocates no polygon at all,
# the same discipline the road polylines already follow.
#
# THE UNIT IS SCREEN PIXELS, NOT METRES, and it does not pass through `scale_px`: the same painter
# serves a ~176 px panel and a full-screen overlay, so a world-space icon would either vanish on
# the minimap or bloat on the full map. `overworld_map_icon_px` sizes the minimap's glyphs and
# `overworld_map_icon_full_px` the full map's (bigger — there is room, and names are drawn beside
# them).

# Ordinary rally: pennant on a pole.
static var _G_FLAG_POLE := PackedVector2Array([Vector2(-0.42, -1.0), Vector2(-0.42, 0.95)])
static var _G_FLAG_PENNANT := PackedVector2Array([
	Vector2(-0.42, -1.0), Vector2(0.85, -0.58), Vector2(-0.42, -0.16),
])

# Car unlock: a hatchback body; the two wheels are drawn as circles below it (see `_draw_glyph`),
# which is what makes the silhouette read as a car rather than as a blob at 14 px.
static var _G_CAR_BODY := PackedVector2Array([
	Vector2(-1.0, 0.18), Vector2(-0.92, -0.2), Vector2(-0.3, -0.28), Vector2(0.02, -0.72),
	Vector2(0.6, -0.72), Vector2(0.78, -0.26), Vector2(1.0, -0.18), Vector2(1.0, 0.18),
])
static var _G_CAR_WHEELS := PackedVector2Array([Vector2(-0.52, 0.24), Vector2(0.56, 0.24)])
const _G_CAR_WHEEL_R := 0.3

# Special: a trophy cup, as three convex pieces (bowl, stem, base) rather than one concave
# outline — `draw_colored_polygon` is happiest with convex input.
static var _G_TROPHY_BOWL := PackedVector2Array([
	Vector2(-0.58, -0.9), Vector2(0.58, -0.9), Vector2(0.4, -0.08), Vector2(-0.4, -0.08),
])
static var _G_TROPHY_STEM := PackedVector2Array([
	Vector2(-0.14, -0.08), Vector2(0.14, -0.08), Vector2(0.14, 0.52), Vector2(-0.14, 0.52),
])
static var _G_TROPHY_BASE := PackedVector2Array([
	Vector2(-0.62, 0.52), Vector2(0.62, 0.52), Vector2(0.62, 0.88), Vector2(-0.62, 0.88),
])

# Garage: pitched roof over a box.
static var _G_GARAGE_ROOF := PackedVector2Array([
	Vector2(-1.0, -0.12), Vector2(0.0, -0.92), Vector2(1.0, -0.12),
])
static var _G_GARAGE_BODY := PackedVector2Array([
	Vector2(-0.76, -0.12), Vector2(0.76, -0.12), Vector2(0.76, 0.88), Vector2(-0.76, 0.88),
])

# --- Model --------------------------------------------------------------------------------

# Every candidate destination, built ONCE in `setup`; `_shown` holds references to these, so
# neither array allocates while driving. Entry:
#   {id, name, kind, world_pos: Vector3, zone: OverworldZone, rally: Dictionary, distance_m,
#    icon: Texture2D|null}
# `icon` is resolved ONCE here (a PART pin's own upgrade texture) rather than per draw: it costs a
# reverse walk of the upgrade catalogue, which has no business running every frame.
var _candidates: Array[Dictionary] = []
var _shown: Array[Dictionary] = []
var _selected_id := ""
var _since_refresh := INF
var _open := false

var _size_m := 0.0
var _profile_override: Dictionary = {}
var _zone_source := Callable()
var _can_toggle := Callable()

# THE SAT-NAV. The destination the player has committed to (`""` for none), the planned road
# polyline in world XZ, and its length along the road. Re-planned on the refresh timer so the line
# FOLLOWS the car — see `overworld_route.gd` for why re-planning beats trimming a stale path.
var _route_id := ""
var _route_points := PackedVector2Array()
var _route_length_m := 0.0
var _roads: Object = null

# The pin under the pointer, and the full map's last drawn rect. The rect is captured by the
# painter because picking has to invert exactly the projection that DREW the pins — recomputing it
# in the input handler is how a hit test drifts a few pixels away from the picture.
var _hover_id := ""
var _full_rect := Rect2()

# THE SYNTHETIC CURSOR — the controller's and the arrow keys' "mouse". A screen-space point inside
# `_full_rect` that the stick glides and a directional tap teleports, fed through the SAME
# `_pick_at` / `_set_hover` / `select_id` path the real pointer uses. `_cursor_active` is what makes
# it appear: it is armed by pad/key input and disarmed by real mouse motion, so a mouse user never
# gets a second crosshair fighting their OS one.
var _cursor := Vector2.ZERO
var _cursor_active := false
# The view size the full map lays itself out in when there is no Control to ask (headless tests).
var _view_size := Vector2(1000.0, 1000.0)

var _car_pos := Vector3.ZERO
var _car_forward := Vector2(0.0, -1.0)
# WHICH WAY THE MINIMAP POINTS. The heading-up panel follows the ACTIVE CAMERA's yaw, not the
# car's. The player reads the minimap against the picture on screen, and that picture is the
# camera's: with a drifting car the chase camera lags the body, so a car-up minimap swung away
# from the view every time the back stepped out and "the road bends left" stopped reading as left
# — the exact failure heading-up exists to prevent. The car's own facing is still drawn, by the
# ARROW, which is now meaningfully different from straight up.
var _view_forward := Vector2(0.0, -1.0)
var _drawn_pos := Vector3(INF, INF, INF)
var _drawn_heading := INF

# Road geometry, captured once: world-XZ polylines plus a per-edge AABB for culling, and a
# parallel "is this stretch tarmac" flag so the map can show surface the way the ground does.
var _road_paths: Array[PackedVector2Array] = []
var _road_boxes: Array[Rect2] = []
var _road_tarmac: Array[bool] = []
var _road_width_m := 0.0
# The two GRAPH NODE IDS each captured edge runs between (a rally id, or `_HQ_NODE_ID` for the
# garage), captured once alongside the geometry, and the per-edge "may this be painted" flag
# derived from them on every `refresh()`. See `_refresh_road_visibility`.
var _road_a_id := PackedStringArray()
var _road_b_id := PackedStringArray()
var _road_shown: Array[bool] = []

# --- Drawing ------------------------------------------------------------------------------

var _visuals := true
var _minimap: Control = null
var _full_root: Control = null
var _full_canvas: Control = null
var _footer: Label = null
var _title: Label = null
var _fog_tex: ImageTexture = null
# What the live `_fog_tex` was built FROM. The fog changes when a rally is completed and at no
# other time, so this stamp is what stops the refresh timer rasterising an identical mask twice a
# second — see `_rebuild_fog` for the flicker that caused.
var _fog_stamp := ""

## Emitted when the full map opens (true) or closes (false). The host uses it to lock the car's
## controls — see the header on why this is not a tree pause.
signal map_toggled(opened: bool)


# ==========================================================================================
# Projection — static, so a test can round-trip it with no scene and no viewport.
# ==========================================================================================

## World XZ -> screen, for a map view centred on `centre` (world XZ) showing `span_m` metres
## across the SHORTER side of `rect`, rotated by `rot` radians. `Overworld.world_xz` already
## turns a normalised map position into world XZ, so map->screen is this composed with that.
static func project(world_xz_pos: Vector2, centre: Vector2, span_m: float, rot: float,
		rect: Rect2) -> Vector2:
	return rect.get_center() + ((world_xz_pos - centre) * scale_px(span_m, rect)).rotated(rot)


## The exact inverse of `project`.
static func unproject(screen: Vector2, centre: Vector2, span_m: float, rot: float,
		rect: Rect2) -> Vector2:
	var s := scale_px(span_m, rect)
	if s <= 0.0:
		return centre
	return centre + (screen - rect.get_center()).rotated(-rot) / s


## Screen pixels per world metre for a view of `span_m` metres across `rect`. Driven by the
## SHORTER side so a wide rect still shows at least `span_m` in both axes.
static func scale_px(span_m: float, rect: Rect2) -> float:
	var span := maxf(span_m, 0.001)
	return minf(rect.size.x, rect.size.y) / span


## The rotation (radians) that puts `forward` (a world XZ direction) at the top of the view.
## Zero for a north-up view — world +x is screen right and world +z is screen down, the same
## convention `Overworld.world_xz` uses, so north-up needs no rotation at all.
static func heading_rotation(forward: Vector2, rotate: bool) -> float:
	if not rotate or forward.length_squared() <= 0.0:
		return 0.0
	return -PI * 0.5 - forward.angle()


# ==========================================================================================
# Setup
# ==========================================================================================

# Build the map. Options:
#   size_m      float — the world edge length (`Overworld.size_m()`). Sets the full map's span
#                       and the coastline rectangle.
#   to_world    Callable(Vector2) -> Vector3, normally `Overworld.world_xz` bound to size_m.
#   zones       Callable() -> Array[OverworldZone]. PREFERRED source of pins: the zones hold
#               the ground-dropped position and the shared reveal state.
#   garage_pos  Vector3 for the garage, if the zone layer owns none.
#   roads       OverworldRoads (or anything with `edges()` / `width_m()`).
#   rallies     Array[Dictionary] instead of `RallyLibrary.RALLIES` (tests).
#   profile     Dictionary to gate reveal against instead of the live `Save.profile` (tests).
#   can_toggle  Callable() -> bool. False vetoes opening AND closing (the host's pause guard).
#   visuals     false to build no Control at all (headless / logic-only).
func setup(opts: Dictionary = {}) -> void:
	_visuals = bool(opts.get("visuals", true)) and not Platform.is_headless()
	_size_m = float(opts.get("size_m", 0.0))
	_profile_override = opts.get("profile", {})
	_zone_source = opts.get("zones", Callable())
	_can_toggle = opts.get("can_toggle", Callable())
	layer = LAYER

	_candidates.clear()
	_shown.clear()
	_since_refresh = INF
	var to_world: Callable = opts.get("to_world", Callable())

	if _zone_source.is_valid():
		var zone_list: Array = _zone_source.call()
		for item in zone_list:
			var zone := item as OverworldZone
			if zone != null:
				_candidates.append(_entry_for_zone(zone))
	else:
		var rallies: Array = opts.get("rallies", RallyLibrary.RALLIES)
		for item in rallies:
			var rally: Dictionary = item
			if String(rally.get("id", "")) == "":
				continue
			var pos := Vector3.ZERO
			if to_world.is_valid():
				pos = to_world.call(RallyLibrary.map_pos_of(rally))
			_candidates.append(_entry_for_rally(rally, pos))

	# The garage is a DESTINATION, not a roster entry — no id, no map_pos, no reveal state — so
	# it is appended here and exempted from the fog gate below, exactly as
	# `OverworldZone.always_revealed` exists for. Without it the player could never find their
	# own garage.
	if not _has_garage():
		var garage_pos: Vector3 = opts.get("garage_pos", Vector3.ZERO)
		if not opts.has("garage_pos") and to_world.is_valid():
			garage_pos = to_world.call(RallyLibrary.HQ_MAP_POS)
		_candidates.append({
			"id": GARAGE_ID, "name": GARAGE_LABEL, "kind": Kind.GARAGE,
			"world_pos": garage_pos, "zone": null, "rally": {}, "distance_m": 0.0,
			"icon": null,
		})

	_roads = opts.get("roads", null)
	_route_id = ""
	_route_points = PackedVector2Array()
	_route_length_m = 0.0
	_hover_id = ""
	_cursor_active = false
	_view_size = opts.get("view_size", _view_size)
	_capture_roads(_roads)
	refresh()

	if _visuals:
		_build_ui()


# Capture the road network's polylines ONCE. They are already world XZ, so this keeps the
# arrays by reference and only derives the culling boxes — see the header's cost note.
#
# The endpoint NODE IDS are captured here too, because that is what makes the reveal gate below
# possible without re-reading the road graph every refresh: `edges()` gives node INDICES, and
# resolving them to ids needs `nodes()`, which is exactly the sort of lookup that has no business
# running while driving.
func _capture_roads(source: Object) -> void:
	_road_paths.clear()
	_road_boxes.clear()
	_road_tarmac.clear()
	_road_a_id.clear()
	_road_b_id.clear()
	_road_shown.clear()
	_road_width_m = 0.0
	if source == null or not source.has_method("edges"):
		return
	if source.has_method("width_m"):
		_road_width_m = float(source.call("width_m"))
	var node_ids := PackedStringArray()
	if source.has_method("nodes"):
		for item in source.call("nodes"):
			node_ids.append(String((item as Dictionary).get("id", "")))
	var edge_list: Array = source.call("edges")
	for item in edge_list:
		var edge: Dictionary = item
		var pts: PackedVector2Array = edge.get("points", PackedVector2Array())
		if pts.size() < 2:
			continue
		var box := Rect2(pts[0], Vector2.ZERO)
		for i in range(1, pts.size()):
			box = box.expand(pts[i])
		_road_paths.append(pts)
		_road_boxes.append(box)
		_road_tarmac.append(bool(edge.get("tarmac", false)))
		_road_a_id.append(_node_id_at(node_ids, int(edge.get("a", -1))))
		_road_b_id.append(_node_id_at(node_ids, int(edge.get("b", -1))))
		_road_shown.append(true)
	_refresh_road_visibility()


func _node_id_at(node_ids: PackedStringArray, index: int) -> String:
	return node_ids[index] if index >= 0 and index < node_ids.size() else ""


# ==========================================================================================
# Per-frame
# ==========================================================================================

## One frame of the readout. `car_pos` is the car's world position and `car_basis` its global
## basis — passed IN rather than looked up, so this drives headless from a test.
func update(delta: float, car_pos: Vector3, car_basis: Basis) -> void:
	_car_pos = car_pos
	# Godot's forward is -Z, flattened to XZ: pitch and roll must not swing the map.
	var flat := Vector2(-car_basis.z.x, -car_basis.z.z)
	if flat.length_squared() > 0.000001:
		_car_forward = flat.normalized()
	_view_forward = _camera_forward()

	_since_refresh += maxf(delta, 0.0)
	if _since_refresh >= REFRESH_INTERVAL_S:
		refresh()

	if not _visuals:
		return
	if _moved_enough():
		_drawn_pos = _car_pos
		_drawn_heading = _view_forward.angle()
		if _minimap != null:
			_minimap.queue_redraw()
		if _open and _full_canvas != null:
			_full_canvas.queue_redraw()
	if _open:
		_write_footer()


# The ACTIVE camera's flattened facing, or the car's when there is no camera (headless, and any
# frame before the camera manager has picked one). Asked of the viewport rather than of a node
# path, because the overworld swaps between chase and bonnet cameras and the minimap must follow
# whichever is current without knowing either exists.
func _camera_forward() -> Vector2:
	var vp := get_viewport()
	var cam := vp.get_camera_3d() if vp != null else null
	if cam == null:
		return _car_forward
	var basis := cam.global_transform.basis
	var flat := Vector2(-basis.z.x, -basis.z.z)
	if flat.length_squared() <= 0.000001:
		# Looking straight down: yaw is degenerate, so keep the last good heading rather than
		# snapping the panel to north for a frame.
		return _view_forward
	return flat.normalized()


func _moved_enough() -> bool:
	if not is_finite(_drawn_heading):
		return true
	# The heading gate watches the VIEW, since that is what rotates the panel; the car's own
	# heading only turns the arrow, which is redrawn in the same pass anyway.
	if absf(angle_difference(_drawn_heading, _view_forward.angle())) > _TURN_EPSILON_RAD:
		return true
	return _drawn_pos.distance_to(_car_pos) > _MOVE_EPSILON_M


## Recompute the REVEALED destination set (and, with visuals, the fog mask). Cheap enough to
## call on open; otherwise it runs on `REFRESH_INTERVAL_S`.
func refresh() -> void:
	_since_refresh = 0.0
	var profile := _profile()
	_shown.clear()
	for entry in _candidates:
		if not _is_revealed(entry, profile):
			continue
		_shown.append(entry)
	_write_distances()
	_refresh_road_visibility()
	_replan_route()
	if _selected_id != "" and _index_of(_selected_id) < 0:
		# The selection was withheld or removed underneath us; fall back to the first pin
		# rather than pointing at nothing.
		_selected_id = String(_shown[0].get("id", "")) if not _shown.is_empty() else ""
	if _visuals:
		_rebuild_fog()


# The reveal gate. The SHARED predicate in both directions — never a lookalike distance test,
# because the fog exists precisely to withhold the shape of an unexplored roster.
func _is_revealed(entry: Dictionary, profile: Dictionary) -> bool:
	if int(entry.get("kind", Kind.RALLY)) == Kind.GARAGE:
		return true   # the always_revealed exemption; see setup()
	var rally: Dictionary = entry.get("rally", {})
	var zone := entry.get("zone", null) as OverworldZone
	# READ-ONLY, like the compass: the zone's reveal state is owned by `OverworldZones.refresh`,
	# which gates on a caller-chosen profile, and calling `refresh_revealed` from here would
	# overwrite that choice as a side effect of drawing a map. An explicitly injected profile
	# (tests) asks the shared predicate directly instead, still without touching the zone.
	if zone != null and _profile_override.is_empty():
		return zone.revealed()
	if rally.is_empty():
		return false
	return RallyLibrary.rally_revealed(rally, profile)


# ==========================================================================================
# WHICH ROADS THE MAP IS ALLOWED TO PAINT
# ==========================================================================================
# A road is drawn only when BOTH of its endpoints are revealed. This is a MAP-ONLY rule: the road
# network is built and carved into the terrain progress-INDEPENDENTLY on purpose (see
# `overworld_roads.gd` / the terrain carve), so every road the player can see out of the windscreen
# is still there and still drivable. Only the PAINTED map withholds them.
#
# WHY. The map was already hiding unrevealed PINS — `_is_revealed`, whose whole justification is
# that the fog exists to withhold the shape of an unexplored roster — while drawing the roads that
# lead to them. A road running off into the dark is a signpost to the pin at its far end: it tells
# the player there is content there, roughly how far, and in which direction, which is exactly what
# the pin was being withheld to avoid. Worse, it invites them to drive it, and the reward for
# following it is a rally they cannot enter yet.
#
# BOTH ends, not either. A half-drawn edge still points at the hidden pin — it is the same leak
# with a shorter line — so an edge with one revealed end and one hidden end is dropped whole. This
# is deliberately the SAME rule as the HQ map table's dotted reveal links ("Both ends must already
# be REVEALED", features/map-exploration.md), so the two hubs withhold the same shape, and it makes
# the drawn network GROW with exploration: the roads the player has earned, not the ones they
# haven't.
#
# THE PREDICATE IS REVEAL, NOT ENTRY ELIGIBILITY. `_has_eligible_car` / `RallyLibrary.is_eligible`
# (a rating band and a car restriction) is a GARAGE question, and the answer changes when the
# player buys a car — a road does not become undrivable because nothing in the garage qualifies,
# and `overworld_zones.gd` already renders that state by GREYING the marker rather than by removing
# it. Reveal is the thing that genuinely means "not yet".
#
# Cost: one pass over the captured edges per `refresh()` (0.5 s), string set lookups only, and no
# geometry is rebuilt — the paint loop just reads the flag.
func _refresh_road_visibility() -> void:
	if _road_paths.is_empty():
		return
	# The ids the map is currently willing to show a pin for. Built from `_shown`, so the roads and
	# the pins can never disagree about what is revealed — one predicate, one source.
	var open_ids := {}
	for entry in _shown:
		open_ids[String(entry.get("id", ""))] = true
	for i in _road_paths.size():
		_road_shown[i] = _road_end_open(_road_a_id[i], open_ids) \
				and _road_end_open(_road_b_id[i], open_ids)


# Is one endpoint of an edge something the map may draw a road to?
func _road_end_open(node_id: String, open_ids: Dictionary) -> bool:
	if node_id == _HQ_NODE_ID:
		# The garage, under the road graph's own name for it. Always open, the same exemption its
		# PIN gets in `setup` — a player who cannot see the road home has been given a worse map,
		# not a more mysterious one.
		return true
	if node_id == "":
		# An endpoint we could not resolve (a road source with no `nodes()`, e.g. a stub in a test).
		# Fail OPEN: an unidentifiable network is the old, ungated behaviour, and silently blanking
		# every road would be a far more confusing failure than drawing one too many.
		return true
	return open_ids.has(node_id)


func _write_distances() -> void:
	for entry in _shown:
		var p: Vector3 = entry.get("world_pos", Vector3.ZERO)
		entry["distance_m"] = Vector2(p.x - _car_pos.x, p.z - _car_pos.z).length()


# ==========================================================================================
# The model, for tests and for the host
# ==========================================================================================

## The REVEALED destinations plus the garage, each `{id, name, kind, world_pos, distance_m}`.
## The array and its dictionaries are LIVE and reused; read them, do not keep or mutate them.
func destinations() -> Array[Dictionary]:
	return _shown


## How many road edges the map captured. Live under `visuals: false`, like the rest of the model —
## `_capture_roads` runs in `setup` before any Control exists.
func road_count() -> int:
	return _road_paths.size()


## Is road edge `i` currently PAINTED? False for a road the reveal gate is withholding. This is the
## map's own decision only: the road is still carved into the terrain and still drivable either way.
func road_is_shown(i: int) -> bool:
	return i >= 0 and i < _road_shown.size() and _road_shown[i]


## The two graph-node ids road edge `i` runs between, as `[a, b]` — a rally id, `"__hq__"` for the
## garage, or `""` for an endpoint that could not be resolved. Exposed so a test can name the edge
## it is asserting about instead of relying on an index.
func road_ends(i: int) -> PackedStringArray:
	if i < 0 or i >= _road_a_id.size():
		return PackedStringArray()
	return PackedStringArray([_road_a_id[i], _road_b_id[i]])


## The currently selected destination, or `{}` when there is none.
func selected() -> Dictionary:
	var i := _index_of(_selected_id)
	return _shown[i] if i >= 0 else {}


## Move the selection `step` places through `destinations()`, wrapping in both directions.
## Returns the newly selected id (`""` when there is nothing to select).
func select_step(step: int) -> String:
	if _shown.is_empty():
		_selected_id = ""
		return ""
	var i := _index_of(_selected_id)
	if i < 0:
		# Nothing selected yet: the first press lands on the nearest destination, which is the
		# one the player is most likely asking about.
		i = _nearest_index()
	else:
		i = wrapi(i + step, 0, _shown.size())
	_selected_id = String(_shown[i].get("id", ""))
	return _selected_id


## Select a destination by id. Returns false (a no-op) if it is not currently revealed.
func select_id(id: String) -> bool:
	if _index_of(id) < 0:
		return false
	_selected_id = id
	return true


# ==========================================================================================
# THE SAT-NAV
# ==========================================================================================
# Picking a pin on the full map is only half an answer: the player closes the map and is back to
# a junction with no idea which arm goes where. So a chosen destination sets a ROUTE — the road
# path to it (`OverworldRoute.plan`) — and the route is drawn on the MINIMAP, i.e. on the display
# that is still there while driving. That is the whole point: the full map is where you choose,
# the minimap is where you follow.
#
# The route is RE-PLANNED on the ordinary refresh timer rather than trimmed, so it always starts
# from the road the car is actually on and a missed turn re-routes by itself.

## Set the sat-nav destination. Returns false (a no-op) for a destination that is not currently
## revealed — the fog gates the route exactly as it gates the pin.
func set_route(id: String) -> bool:
	if _index_of(id) < 0:
		return false
	_route_id = id
	_replan_route()
	_redraw_all()
	return true


## Cancel the sat-nav.
func clear_route() -> void:
	_route_id = ""
	_route_points = PackedVector2Array()
	_route_length_m = 0.0
	_redraw_all()


## The destination the sat-nav is guiding to, or `""`.
func route_id() -> String:
	return _route_id


## The planned road route, world XZ, starting at the car and ending at the pin. Empty when there
## is no route (or when no road network was supplied).
func route_points() -> PackedVector2Array:
	return _route_points


## Route length ALONG THE ROADS, metres. Longer than the straight-line distance, and the honest
## number to quote to a player who has to drive it.
func route_length_m() -> float:
	return _route_length_m


func _replan_route() -> void:
	if _route_id == "":
		_route_points = PackedVector2Array()
		_route_length_m = 0.0
		return
	var i := _index_of(_route_id)
	if i < 0:
		# The destination stopped being revealed underneath us (a test swapping profiles, say).
		clear_route()
		return
	# NOTE on the road reveal gate: the route IS still drawn where the roads under it are not. It
	# only ever leads to a REVEALED destination the player explicitly picked, and a sat-nav that
	# went invisible for the middle third of the drive would be worse than none — a single guidance
	# line to a place they already know about withholds nothing the pin didn't already tell them.
	var dest: Vector3 = _shown[i].get("world_pos", Vector3.ZERO)
	_route_points = OverworldRoute.plan(_roads, Vector2(_car_pos.x, _car_pos.z),
			Vector2(dest.x, dest.z))
	_route_length_m = OverworldRoute.length_m(_route_points)


# ==========================================================================================
# THE SYNTHETIC CURSOR — one pointer, two ways to move it
# ==========================================================================================
# A controller has no pointer, and the map is a PICTURE rather than a list of widgets, so there was
# nothing for a pad player to aim with: the only way to choose a destination was to cycle blindly
# through `select_step` and read the footer. The cursor is that missing pointer.
#
# IT IS A SYNTHETIC POINTER, DELIBERATELY. Its position goes through the SAME `_pick_at` ->
# `_set_hover` -> `select_id` path as the mouse, so the pick radius, the one-name-drawn rule
# (`_named_id`) and route-on-select cannot drift apart between input methods. Any behaviour added to
# hovering is automatically true for the pad.
#
# HOW IT RELATES TO `select_step` — one cursor, two ways to move it, and they always end in the
# same state (cursor, hover and selection agreeing):
#
#   TAP a direction (arrows / WASD / D-pad)  ->  `select_step(+-1)` picks the next pin, and the
#       cursor TELEPORTS onto it (`_cursor_to_selection`). Discrete input gets discrete, guaranteed
#       progress: one press is always one pin, and the cursor never lies about what is selected.
#       Echoes are not consumed, so HOLDING an arrow does not machine-gun through the roster.
#   PUSH the stick (or hold a direction)     ->  the cursor GLIDES at `overworld_map_cursor_px_s`,
#       polled from `Input.get_vector` in `_process`. Analog input is continuous, so it gets
#       continuous motion; a held key reads as full deflection, which is why a tap jumps a pin and a
#       hold then glides on from it. Sane either way, and never a runaway.
#
# ASSIST / MAGNETISM. The cursor does NOT have to land on an icon: after every move it hovers the
# nearest pin within `overworld_map_pick_px` — the SAME radius the finger and the mouse use, not a
# second threshold to retune — and the selection follows the hover. So gliding past a pin picks it
# up, and `ui_accept` then routes to it exactly as it does for a click. A pin is never left
# unselectable because the cursor could not be aimed precisely enough.
#
# It cannot leave the drawn map (`_view_rect`), and it cannot leak into the car: the map claims the
# screen while open (`MenuNav.SCREEN_CLAIMER_GROUP`) and the host locks `Car.controls_locked`, while
# the polling below is gated on `_open` — so nothing moves a cursor, or reads a stick for one, once
# the map is shut.


## Is the pad/keyboard cursor currently armed (i.e. being drawn)? Real mouse motion disarms it.
func cursor_active() -> bool:
	return _cursor_active


## Where the cursor is, in screen pixels.
func cursor_pos() -> Vector2:
	return _cursor


## Move the cursor by `delta_px`, clamped to the drawn map, then re-hover and re-select under
## magnetism. THE one entry point for cursor motion — the input polling calls it, and so does a
## test, so what a test exercises is exactly what a stick does.
func move_cursor(delta_px: Vector2) -> void:
	var rect := _view_rect()
	if rect.size.x <= 0.0:
		return
	if not _cursor_active:
		# First movement arms it AT the current selection rather than at some corner, so the player
		# starts from the thing the footer is already talking about.
		_cursor_active = true
		_cursor_to_selection()
	_cursor = _clamp_to_rect(_cursor + delta_px, rect)
	_apply_cursor_hover()


## Put the cursor exactly on `screen_pos` (clamped). Used by the directional-tap path.
func place_cursor(screen_pos: Vector2) -> void:
	var rect := _view_rect()
	if rect.size.x <= 0.0:
		return
	_cursor_active = true
	_cursor = _clamp_to_rect(screen_pos, rect)
	_apply_cursor_hover()


# Hover (and therefore select) whatever the cursor is now over. The selection only MOVES when the
# cursor is actually over something: gliding across empty map keeps the last pin selected rather
# than clearing the footer to nothing, which is what makes `ui_accept` safe to press mid-glide.
func _apply_cursor_hover() -> void:
	var hit := _pick_at(_cursor)
	_set_hover(hit)
	if hit != "":
		select_id(hit)
	if _full_canvas != null:
		_full_canvas.queue_redraw()
	_write_footer()


# Park the cursor on the selected pin's own screen position, so a directional tap and the cursor can
# never disagree about what is selected.
func _cursor_to_selection() -> void:
	var sel := selected()
	if sel.is_empty():
		_cursor = _view_rect().get_center()
		return
	var world: Vector3 = sel.get("world_pos", Vector3.ZERO)
	_cursor = project(Vector2(world.x, world.z), Vector2.ZERO, maxf(_size_m, 1.0), 0.0,
			_view_rect())


static func _clamp_to_rect(p: Vector2, rect: Rect2) -> Vector2:
	return Vector2(clampf(p.x, rect.position.x, rect.end.x),
			clampf(p.y, rect.position.y, rect.end.y))


# The directional axis, summed over BOTH action families so a stick, the arrows, the D-pad and WASD
# all drive the one cursor. `get_vector` applies the actions' own deadzones, which is what keeps a
# resting stick from creeping the cursor across the map.
func _cursor_axis() -> Vector2:
	var axis := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	axis += Input.get_vector("menu_left", "menu_right", "menu_up", "menu_down")
	return axis.limit_length(1.0)


## Is the full-screen map on screen?
func is_open() -> bool:
	return _open


## Open the full map. Vetoed by the host's `can_toggle` (e.g. the pause menu is open).
func open() -> void:
	if _open or not _toggle_allowed():
		return
	_open = true
	refresh()
	if _selected_id == "" and not _shown.is_empty():
		_selected_id = String(_shown[_nearest_index()].get("id", ""))
	_apply_open()
	map_toggled.emit(true)


## Close the full map. Also vetoed by `can_toggle`, so the host can hold it open if it ever
## needs to (nothing does today).
func close() -> void:
	if not _open or not _toggle_allowed():
		return
	_open = false
	# The pointer is gone with the map; leaving a hover behind would name a pin the player is no
	# longer pointing at the next time they open it. The synthetic cursor is disarmed for the same
	# reason, and because a cursor drawn over a map nobody is looking at is just furniture.
	_hover_id = ""
	_cursor_active = false
	_apply_open()
	map_toggled.emit(false)


## Flip it.
func toggle() -> void:
	if _open:
		close()
	else:
		open()


## Is some OTHER modal claiming the screen — the car picker, a rally card, a garage page? Excludes
## this map's own full-map root, whose case is `_open`. Guarded for a map built outside a tree.
func _other_claimer() -> bool:
	var tree := get_tree() if is_inside_tree() else null
	if tree == null:
		return false
	var claimer := MenuNav.screen_claimer(tree)
	return claimer != null and claimer != _full_root


## Is the game paused? Guarded, because a map built outside a tree (tests) has no `SceneTree`.
func _paused() -> bool:
	var tree := get_tree()
	return tree != null and tree.paused


func _toggle_allowed() -> bool:
	return not _can_toggle.is_valid() or bool(_can_toggle.call())


func _index_of(id: String) -> int:
	if id == "":
		return -1
	for i in _shown.size():
		if String(_shown[i].get("id", "")) == id:
			return i
	return -1


func _nearest_index() -> int:
	var best := 0
	var best_d := INF
	for i in _shown.size():
		var d := float(_shown[i].get("distance_m", 0.0))
		if d < best_d:
			best_d = d
			best = i
	return best


# ==========================================================================================
# Input — see the header for the full binding list
# ==========================================================================================

func _unhandled_input(event: InputEvent) -> void:
	# Ask the shared guard AS OUR OWN OVERLAY, not as this layer: `_full_root` is the node that
	# joins SCREEN_CLAIMER_GROUP, and `input_blocked` carves out only the claimer's own subtree —
	# asking as the parent CanvasLayer would make the map deaf to its own close button.
	if MenuNav.input_blocked(_full_root if _full_root != null else self):
		return
	if InputMap.has_action(TOGGLE_ACTION) and event.is_action_pressed(TOGGLE_ACTION):
		toggle()
		_consume()
		return
	if not _open:
		return
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("menu_back"):
		close()
		_consume()
		return
	# POINTER. Handled here rather than on `_full_root._gui_input` for the same reason the rest of
	# this screen is: there are no focusable widgets to route a GUI event to, and the map is one
	# picture, not a grid of buttons. A tap is a click on touch devices (Godot emits an emulated
	# mouse button unless the project disables it), and the drag path is handled too so a finger
	# can slide across the map and read names as it goes.
	if event is InputEventMouseMotion or event is InputEventScreenDrag:
		# A real pointer disarms the synthetic one: two crosshairs on one map, one of them the OS's,
		# is worse than either alone. The pad re-arms it the moment a direction is used again.
		_cursor_active = false
		_set_hover(_pick_at(event.position))
		return
	if _pointer_pressed(event):
		var hit := _pick_at(event.position)
		if hit != "":
			select_id(hit)
			set_route(hit)
			_set_hover(hit)
			_write_footer()
			_consume()
		return
	# COMMIT the keyboard/gamepad selection: the pointer path above is unavailable on a controller,
	# so `ui_accept` is what makes the sat-nav reachable without a pointer at all. Pressing it on
	# the destination that already owns the route cancels it — one button, both directions.
	if event.is_action_pressed("ui_accept") or event.is_action_pressed("menu_select"):
		var sel := String(selected().get("id", ""))
		if sel != "":
			if sel == _route_id:
				clear_route()
			else:
				set_route(sel)
			_write_footer()
		_consume()
		return
	# Directional input cycles the selection. Both families are handled: `ui_*` carries arrows,
	# the D-pad and the left stick, `menu_*` carries WASD (and the D-pad again) — a press only
	# ever matches one of them per family, and the event is consumed either way.
	var step := 0
	if event.is_action_pressed("ui_right") or event.is_action_pressed("menu_right") \
			or event.is_action_pressed("ui_down") or event.is_action_pressed("menu_down"):
		step = 1
	elif event.is_action_pressed("ui_left") or event.is_action_pressed("menu_left") \
			or event.is_action_pressed("ui_up") or event.is_action_pressed("menu_up"):
		step = -1
	if step == 0:
		return
	select_step(step)
	# The cursor follows the tap, so the two ways of moving it can never disagree about what is
	# selected — see the cursor header. This is also what ARMS the cursor for a player who never
	# touches the stick: arrows alone are enough to see it.
	_cursor_active = true
	_cursor_to_selection()
	_set_hover(String(selected().get("id", "")))
	if _visuals:
		if _full_canvas != null:
			_full_canvas.queue_redraw()
		_write_footer()
	_consume()


func _pointer_pressed(event: InputEvent) -> bool:
	if event is InputEventScreenTouch:
		return (event as InputEventScreenTouch).pressed
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		return mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT
	return false


## The destination in `entries` nearest to `screen_pos`, or `""` when none is within
## `radius_px`. STATIC and given its whole view explicitly, so a headless test hit-tests the exact
## geometry the pointer does with no Control, no viewport and no pointer — the same split that
## makes `project` testable.
static func nearest_pin_id(entries: Array[Dictionary], screen_pos: Vector2, centre: Vector2,
		span_m: float, rot: float, rect: Rect2, radius_px: float) -> String:
	var best := ""
	var best_d := radius_px * radius_px
	for entry in entries:
		var world: Vector3 = entry.get("world_pos", Vector3.ZERO)
		var p := project(Vector2(world.x, world.z), centre, span_m, rot, rect)
		var d := p.distance_squared_to(screen_pos)
		if d <= best_d:
			best_d = d
			best = String(entry.get("id", ""))
	return best


## The revealed destination under `screen_pos` on the full map, or `""`.
func pick_at(screen_pos: Vector2) -> String:
	return _pick_at(screen_pos)


# Hit-testing inverts the SAME projection the painter used, via `_full_rect` captured while
# drawing — the full map is always north-up and centred on the world origin, so the only variable
# is the square rect the layout chose.
func _pick_at(screen_pos: Vector2) -> String:
	var rect := _view_rect()
	if rect.size.x <= 0.0 or _shown.is_empty():
		return ""
	return nearest_pin_id(_shown, screen_pos, Vector2.ZERO, maxf(_size_m, 1.0), 0.0, rect,
			maxf(_cfg_float("overworld_map_pick_px", 28.0), 1.0))


# The rect to hit-test and bound the cursor against: whatever was last DRAWN, else the layout the
# painter would choose. Preferring the drawn one is deliberate (`_pick_at`'s note); the fallback is
# what keeps the model alive with no renderer.
func _view_rect() -> Rect2:
	return _full_rect if _full_rect.size.x > 0.0 else full_map_rect()


# The hovered pin owns the ONE name the map draws, so a change repaints.
func _set_hover(id: String) -> void:
	if id == _hover_id:
		return
	_hover_id = id
	if _full_canvas != null:
		_full_canvas.queue_redraw()
	_write_footer()


# Release the fog texture SAFELY. Order is load-bearing: force both hosts to re-record their
# draw commands, THEN drop the reference. Dropping first leaves a recorded command holding a
# freed RID, which the renderer substitutes with its 1x1 white fallback — the flicker this
# whole subsystem was rewritten to fix. Same reason _rebuild_fog updates in place rather than
# re-creating.
func _drop_fog() -> void:
	if _fog_tex == null and _fog_stamp == "":
		return
	_fog_tex = null
	_fog_stamp = ""
	_redraw_all()


func _redraw_all() -> void:
	if _minimap != null:
		_minimap.queue_redraw()
	if _full_canvas != null:
		_full_canvas.queue_redraw()


func _consume() -> void:
	var vp := get_viewport()
	if vp != null:
		vp.set_input_as_handled()


# ==========================================================================================
# Candidate entries
# ==========================================================================================

func _entry_for_zone(zone: OverworldZone) -> Dictionary:
	var rally := zone.rally
	var is_garage := zone.rally_id == GARAGE_ID or (zone.always_revealed and rally.is_empty())
	return {
		"id": zone.rally_id, "name": _name_of(rally, is_garage),
		"kind": Kind.GARAGE if is_garage else _kind_of(rally),
		"world_pos": zone.centre, "zone": null if is_garage else zone, "rally": rally,
		"distance_m": 0.0, "icon": null if is_garage else _icon_of(rally),
		"car_id": RallyLibrary.prize_car_id(rally),
	}


func _entry_for_rally(rally: Dictionary, world_pos: Vector3) -> Dictionary:
	return {
		"id": String(rally.get("id", "")), "name": _name_of(rally, false),
		"kind": _kind_of(rally), "world_pos": world_pos, "zone": null, "rally": rally,
		"distance_m": 0.0, "icon": _icon_of(rally),
		"car_id": RallyLibrary.prize_car_id(rally),
	}


func _name_of(rally: Dictionary, is_garage: bool) -> String:
	if is_garage:
		return String(rally.get("name", GARAGE_LABEL))
	return String(rally.get("name", "Rally"))


# Borrowed whole from the 3D marker rather than re-derived, so a pin and the marker above the
# zone always agree.
func _kind_of(rally: Dictionary) -> int:
	if rally.is_empty():
		return Kind.RALLY
	match OverworldMarker.kind_of(rally):
		OverworldMarker.Kind.CAR:
			return Kind.CAR
		OverworldMarker.Kind.PART:
			return Kind.PART
		OverworldMarker.Kind.TROPHY:
			return Kind.SPECIAL
		_:
			return Kind.RALLY


# The REAL icon texture a pin draws, or null when the kind has no art and a code glyph is used
# instead. Borrowed whole from the 3D marker for the same reason `_kind_of` is: the pin, the marker
# above the zone and the upgrades grid tile must all show the same picture for the same part.
#
# NOTE the null: `OverworldMarker.part_slot_of` returns "" for a rally that unlocks nothing
# recognisable, and `part_texture` turns that into null rather than into `UpgradeIcons`' TUNE
# wrench fallback. Leaning on that fallback would make most of the roster read as a tuning event —
# so a rally with no part gets the FLAG glyph, exactly as the 3D marker does.
func _icon_of(rally: Dictionary) -> Texture2D:
	if rally.is_empty() or _kind_of(rally) != Kind.PART:
		return null
	return OverworldMarker.part_texture(rally)


func _has_garage() -> bool:
	for entry in _candidates:
		if int(entry.get("kind", Kind.RALLY)) == Kind.GARAGE:
			return true
	return false


func _profile() -> Dictionary:
	return _profile_override if not _profile_override.is_empty() else Save.profile


# ==========================================================================================
# Tunables — every size, zoom, width and alpha lives in GameConfig (CLAUDE.md)
# ==========================================================================================

func _cfg_float(field: String, fallback: float) -> float:
	return Config.get_float(field, fallback)


func _cfg_bool(field: String, fallback: bool) -> bool:
	return Config.get_bool(field, fallback)


# ==========================================================================================
# Drawing — ONE painter, two hosts
# ==========================================================================================

func _build_ui() -> void:
	# `setup` is idempotent: a second call rebuilds rather than stacking a second map.
	if _minimap != null:
		_minimap.queue_free()
	if _full_root != null:
		_full_root.queue_free()

	var side := _cfg_float("overworld_minimap_size_px", 176.0)
	var margin := _cfg_float("overworld_map_margin_px", float(UITheme.MARGIN))
	_minimap = Control.new()
	_minimap.name = "Minimap"
	# TOP CENTRE. It used to sit top-left to stay clear of the compass strip that owned the middle
	# of the top band; that strip is gone (the minimap replaced it — a map conveys layout, which a
	# bearing readout cannot), so the centre is both free and the better spot: it is where the eye
	# already is when looking down the road, so glancing at it costs no head movement.
	_minimap.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_minimap.offset_left = -side * 0.5
	_minimap.offset_top = margin
	_minimap.offset_right = side * 0.5
	_minimap.offset_bottom = margin + side
	_minimap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_minimap.clip_contents = true
	_minimap.draw.connect(_draw_minimap)
	add_child(_minimap)

	_full_root = Control.new()
	_full_root.name = "FullMap"
	_full_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_full_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_full_root.visible = false
	# While the map is up it owns the screen: everything else that asks
	# `MenuNav.input_blocked` / `screen_claimer` goes deaf, and hiding it releases the claim.
	_full_root.add_to_group(MenuNav.SCREEN_CLAIMER_GROUP)
	add_child(_full_root)

	var backdrop := ColorRect.new()
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	# FULLY OPAQUE BLACK, not `UITheme.MODAL_DIM` (a 0.96 black). The 4% that leaked through was
	# the LIVE overworld, which keeps streaming chunks and foliage while the map is up (the map
	# locks the car's controls rather than pausing the tree — see the header), so the backdrop
	# shimmered as the world built itself behind it. A map's background must be a constant.
	backdrop.color = UITheme.BLACK
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_full_root.add_child(backdrop)

	_full_canvas = Control.new()
	_full_canvas.name = "Canvas"
	_full_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_full_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_full_canvas.draw.connect(_draw_full)
	_full_root.add_child(_full_canvas)

	_title = UITheme.label(UITheme.caps("Map"), "ink")
	_title.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.offset_top = margin
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_full_root.add_child(_title)

	_footer = UITheme.label("", "dim")
	_footer.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_footer.offset_top = -margin - float(UITheme.MENU_ROW_H)
	_footer.offset_bottom = -margin
	_footer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_full_root.add_child(_footer)

	_apply_open()


# THE MINIMAP HIDES BEHIND ANY MODAL. It is a driving instrument, and over a pause menu — or the
# car picker, or a rally card — it is just furniture floating on top of a modal, the same reason it
# hides behind the full map.
#
# "A modal is up" is asked as "is some OTHER node claiming the screen" (`MenuNav.screen_claimer`,
# which already skips invisible claimers). Every modal in this game joins that group — MenuPage
# does it for every page, the picker does it, and this file does it for its own full map — so the
# minimap never has to learn about each one. `_other_claimer` excludes THIS map's own root, whose
# case is already `_open`.
#
# This layer watches `get_tree().paused` ITSELF rather than being told: the pause flag is owned by
# `pause_menu.gd`, and every extra caller that has to remember to toggle the minimap is another
# place the minimap can be left on screen (the pause menu is opened from more than one path). To
# see the flag at all the layer must keep processing while paused, hence PROCESS_MODE_ALWAYS —
# which changes nothing else, because everything that MOVES here is driven by `update()`, called by
# the host, which does stop when the host stops.
func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(delta: float) -> void:
	# ONLY the visibility flag — deliberately not `_apply_open()`, which also queues a full-map
	# redraw and rewrites the footer, and doing that every frame would undo the redraw gating the
	# whole cost model rests on.
	if _minimap != null:
		_minimap.visible = not _open and not _paused() and not _other_claimer()
	_poll_cursor(delta)


# The stick (and any held direction) glides the cursor. POLLED rather than event-driven because an
# analog axis has no "pressed" moment — and gated on `_open`, so no stick is read, and no cursor
# moves, once the map is shut. `_unhandled_input`'s discrete taps are the other half; see the cursor
# header for how the two relate.
func _poll_cursor(delta: float) -> void:
	if not _open or _shown.is_empty():
		return
	if MenuNav.input_blocked(_full_root if _full_root != null else self):
		return
	var axis := _cursor_axis()
	if axis.length_squared() <= 0.0:
		return
	var speed := maxf(_cfg_float("overworld_map_cursor_px_s", 520.0), 1.0)
	move_cursor(axis * speed * maxf(delta, 0.0))


func _apply_open() -> void:
	if _full_root != null:
		_full_root.visible = _open
	if _minimap != null:
		# The panel would only be a smaller, rotated copy of what is already on screen — and while
		# the tree is paused there is nothing to instrument.
		_minimap.visible = not _open and not _paused() and not _other_claimer()
	if _open and _full_canvas != null:
		_full_canvas.queue_redraw()
	if _open:
		_write_footer()


# The minimap: the player's neighbourhood, heading-up unless the flag says otherwise.
func _draw_minimap() -> void:
	if _minimap == null:
		return
	var rect := Rect2(Vector2.ZERO, _minimap.size)
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	var alpha := clampf(_cfg_float("overworld_minimap_alpha", 0.82), 0.0, 1.0)
	# NO PANEL FILL — the minimap floats transparently over the world. `overworld_minimap_alpha`
	# still fades the CONTENT (roads, pins, the player, the border), so 1.0 is a crisp overlay and
	# a lower value lets more of the drive through. A filled panel read as a hole punched in the
	# sky, which is why the fill is gone rather than merely faded.
	#
	# The fog overlay inside `_paint` is deliberately still drawn: unexplored ground has to read as
	# dark HERE too, or the minimap would show the player roads and pins the world is hiding.
	var rot := heading_rotation(_view_forward,
			_cfg_bool("overworld_minimap_rotate_with_heading", true))
	_paint(_minimap, rect, Vector2(_car_pos.x, _car_pos.z),
			maxf(_cfg_float("overworld_minimap_zoom_m", 400.0), 1.0), rot, false, alpha)
	_draw_north(_minimap, rect, rot, alpha)
	# NO BORDER. There used to be a hairline `draw_rect(rect, ..., filled = false)` here "so the
	# panel reads as an instrument". It could not: the stroke is centred on the rect's OWN edges and
	# `clip_contents` is on, so the outer half of every side was clipped away — and at x = 0 / y = 0
	# the *inner* half landed on the boundary too, leaving the left and top edges invisible while
	# the right and bottom survived as a stray 1 px line. A frame that only draws two of its four
	# sides is worse than no frame, and a border also contradicts the panel's whole design (no fill,
	# no fog — it FLOATS over the world; see `_paint_ground`). The north indicator and the roads
	# give it all the shape it needs.


# The full map: the WHOLE world at once, always north-up so it can be read as a map.
func _draw_full() -> void:
	if _full_canvas == null:
		return
	var rect := full_map_rect()
	if rect.size.x <= 1.0:
		return
	# Captured for hit-testing — see `_pick_at` on why picking must not recompute this.
	_full_rect = rect
	_paint(_full_canvas, rect, Vector2.ZERO, maxf(_size_m, 1.0), 0.0, true, 1.0)


## The square the full map draws itself into: the biggest square that fits the view once the title
## and footer bands are inset, so the map is never stretched.
##
## ONE SOURCE for the painter, the pointer hit test AND the synthetic cursor's bounds — three
## consumers that must agree to the pixel, since two of them decide what the third one drew. It
## falls back to the injected `view_size` when there is no Control to measure, which is what lets a
## headless test hit-test and drive the cursor over the real geometry.
func full_map_rect() -> Rect2:
	var view := _full_canvas.size if _full_canvas != null else _view_size
	if view.x <= 0.0 or view.y <= 0.0:
		return Rect2()
	var margin := _cfg_float("overworld_map_margin_px", float(UITheme.MARGIN))
	var inset := margin * 2.0 + float(UITheme.MENU_ROW_H) * 2.0
	var side := maxf(minf(view.x, view.y) - inset, 1.0)
	return Rect2((view - Vector2(side, side)) * 0.5, Vector2(side, side))


# THE SHARED PAINTER. Both presentations are the same picture at different spans, rotations and
# centres, so there is exactly one routine and the two hosts differ only in their arguments.
#   `named`  — draw pin names (the full map has room; the minimap does not).
func _paint(ci: CanvasItem, rect: Rect2, centre: Vector2, span_m: float, rot: float,
		named: bool, alpha: float) -> void:
	var s := scale_px(span_m, rect)
	if s <= 0.0:
		return
	# ONE transform for the whole world->screen map, so every world-space point array below is
	# handed to the draw calls unmodified — see the header's cost note.
	var origin := rect.get_center() - (centre * s).rotated(rot)
	ci.draw_set_transform(origin, rot, Vector2(s, s))
	_paint_ground(ci, s, alpha, named)
	_paint_roads(ci, centre, span_m, s, alpha)
	_paint_route(ci, s, alpha)
	ci.draw_set_transform_matrix(Transform2D.IDENTITY)
	# SCREEN pixels, and NOT divided by `s` — see the glyph header: one painter, two very
	# different rect sizes, so an icon measured in metres would vanish or bloat.
	var icon_px := maxf(_cfg_float(
			"overworld_map_icon_full_px" if named else "overworld_map_icon_px",
			11.0 if named else 7.0), 1.0)
	_paint_pins(ci, rect, centre, span_m, rot, named, alpha, icon_px)
	_paint_player(ci, rect, centre, span_m, rot, alpha, icon_px)
	# FULL MAP ONLY (`named` is the full map's flag): the minimap is a passive instrument with no
	# selection, so a cursor on it would point at nothing. Drawn LAST so it is never buried under a
	# pin it is sitting on — the one thing on screen the player is moving must stay visible.
	if named:
		_paint_cursor(ci, rect, icon_px)


# The coastline rectangle and the fog. NOTE (see the header): if the terrain is ever derived
# from `textures/map_world.jpg`, the photographic underlay belongs HERE, beneath the fog.
func _paint_ground(ci: CanvasItem, s: float, alpha: float, filled: bool) -> void:
	if _size_m <= 0.0:
		return
	var world := Overworld.bounds_for(_size_m)
	# The land fill is FULL-MAP ONLY. On the minimap it read as an opaque panel punched into the
	# sky and sat on top of the car, which is the opposite of what a heads-up instrument should do
	# — so the minimap draws only CONTENT (roads, pins, the coastline edge, the player) straight
	# over the world. The full map is a deliberate screen-covering overlay, so there a ground plane
	# is right.
	if filled:
		# BLACK, and opaque. The land plate is the map's background and it must never change
		# brightness: everything drawn on top of it (roads, the route, pins) carries the meaning,
		# and a shifting ground makes the whole picture read as flickering.
		ci.draw_rect(world, Color(UITheme.BLACK, alpha), true)
	# FOG IS FULL-MAP ONLY TOO. On the minimap it is a dark rectangle that slides around under the
	# player as they drive — it reads as a background flickering between colours rather than as
	# unexplored ground, which is precisely what it was reported as. The minimap is a heads-up
	# instrument: it shows roads, pins and where you are, and nothing else. Unexplored territory is
	# a thing you go and LOOK at on the full map, where the frame is static and the fog reads.
	if filled and _fog_tex != null:
		# The mask is in normalised map space with y -> world z, the same convention
		# `Overworld.world_xz` uses, so it lands exactly over the world rect. Pre-inverted to a
		# dark overlay in `_rebuild_fog`.
		ci.draw_texture_rect(_fog_tex, world, false, Color(1.0, 1.0, 1.0, alpha))
	var edge := _cfg_float("overworld_map_line_width_px", 2.0) / maxf(s, 0.0001)
	ci.draw_rect(world, Color(UITheme.INK_DIM, UITheme.INK_DIM.a * alpha), false, edge)


# Runs INSIDE the caller's world->screen transform, so the world-space point arrays go straight
# to `draw_polyline`. `centre` / `span_m` are still needed for the cull box.
func _paint_roads(ci: CanvasItem, centre: Vector2, span_m: float, s: float,
		alpha: float) -> void:
	if _road_paths.is_empty():
		return
	# The visible world region, as a world-space box, so an off-screen edge costs one Rect2
	# test rather than a polyline. Grown by the full span so rotation can never clip a road
	# that is actually on screen.
	var view := Rect2(centre - Vector2(span_m, span_m), Vector2(span_m, span_m) * 2.0)
	var width := maxf(_cfg_float("overworld_map_line_width_px", 2.0) / maxf(s, 0.0001),
			_road_width_m * 0.5)
	var gravel := Color(UITheme.MUTED, UITheme.MUTED.a * alpha)
	var tarmac := Color(UITheme.INK_DIM, UITheme.INK_DIM.a * alpha)
	for i in _road_paths.size():
		# The reveal gate first — it is a bool read, cheaper than the cull box, and it applies to
		# BOTH surfaces: the minimap and the full map must withhold the same roads, or the panel
		# leaks what the overlay is hiding. See `_refresh_road_visibility`.
		if not _road_shown[i]:
			continue
		if not view.intersects(_road_boxes[i]):
			continue
		ci.draw_polyline(_road_paths[i], tarmac if _road_tarmac[i] else gravel, width, false)


# THE SAT-NAV LINE. Drawn INSIDE the caller's world->screen transform, like the roads, so the same
# world-XZ array serves both maps unmodified. Two passes: a dark casing and a bright core, because
# the route has to be findable ON TOP of the road it is following — a single line the same width
# as the road underneath it just looks like a differently-coloured road.
func _paint_route(ci: CanvasItem, s: float, alpha: float) -> void:
	if _route_points.size() < 2:
		return
	var core := maxf(_cfg_float("overworld_map_route_width_px", 4.0) / maxf(s, 0.0001),
			_road_width_m * 0.45)
	ci.draw_polyline(_route_points, Color(UITheme.BLACK, alpha), core * 1.9, false)
	ci.draw_polyline(_route_points, Color(UITheme.GREEN, alpha), core, false)


func _paint_pins(ci: CanvasItem, rect: Rect2, centre: Vector2, span_m: float, rot: float,
		named: bool, alpha: float, icon_px: float) -> void:
	var font := UITheme.font()
	var stroke := _cfg_float("overworld_map_line_width_px", 2.0)
	for entry in _shown:
		var world: Vector3 = entry.get("world_pos", Vector3.ZERO)
		var p := project(Vector2(world.x, world.z), centre, span_m, rot, rect)
		if not rect.has_point(p):
			continue
		var kind := int(entry.get("kind", Kind.RALLY))
		var col := Color(_kind_color(kind), alpha)
		var tex := entry.get("icon", null) as Texture2D
		if tex != null:
			# A PART pin wears the part's OWN art, tinted to the reward colour so shape says
			# "which part" while colour keeps saying "reward" alongside the other pins.
			ci.draw_texture_rect(tex,
					Rect2(p - Vector2(icon_px, icon_px), Vector2(icon_px, icon_px) * 2.0),
					false, col)
		else:
			_draw_glyph(ci, p, icon_px, kind, col, stroke, String(entry.get("car_id", "")))
		var id := String(entry.get("id", ""))
		if id == _route_id:
			# The sat-nav destination keeps a marker of its own, so the route's far end is
			# identifiable even when the selection has moved on to another pin.
			ci.draw_arc(p, icon_px * _SELECT_RING * 1.25, 0.0, TAU, 24,
					Color(UITheme.GREEN, alpha), stroke)
		if id == _selected_id:
			ci.draw_arc(p, icon_px * _SELECT_RING, 0.0, TAU, 24, Color(UITheme.INK, alpha), stroke)
		# ONE NAME ONLY — see the header. The hovered pin wins; with nothing hovered the name falls
		# back to the selection, so the keyboard/gamepad player still gets a name on the picture
		# rather than only in the footer.
		if named and font != null and id == _named_id():
			ci.draw_string(font, p + Vector2(icon_px + _LABEL_GAP_PX, icon_px * 0.5),
					UITheme.caps(String(entry.get("name", ""))),
					HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_SIZE, col)


# The synthetic cursor: a crosshair with a gap in the middle, so the pin it is sitting on shows
# THROUGH it rather than being hidden by it — the reason it is a cross and not a filled arrow. It
# grows a ring when it is actually over a pin, which is the visible feedback that magnetism has
# caught something and `ui_accept` will now do what the player expects.
func _paint_cursor(ci: CanvasItem, rect: Rect2, icon_px: float) -> void:
	if not _cursor_active or not rect.has_point(_cursor):
		return
	var stroke := maxf(_cfg_float("overworld_map_line_width_px", 2.0), 1.0)
	var arm := icon_px * 1.9
	var gap := icon_px * 0.7
	var col := UITheme.INK
	for dir in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
		ci.draw_line(_cursor + dir * gap, _cursor + dir * arm, col, stroke)
	if _hover_id != "":
		ci.draw_arc(_cursor, icon_px * 1.15, 0.0, TAU, 20, Color(UITheme.GREEN), stroke)


# One kind's code-drawn glyph, centred on `p` and `icon_px` half-extents across.
#
# ZERO PER-FRAME ALLOCATION: the point arrays are the shared `static var` unit-space ones and are
# handed to the draw calls UNMODIFIED — the position and the size are carried entirely by a single
# `draw_set_transform`, which is also why every glyph is authored in the same -1..1 box. The
# transform is restored to identity on the way out so the caller's label and ring are unaffected.
#
# `car_id` names the prize car for a Kind.CAR pin, so the pin can wear THAT car's own baked
# silhouette; it is "" for every other kind and for a car with nothing baked, which is what
# selects the generic hatchback below.
func _draw_glyph(ci: CanvasItem, p: Vector2, icon_px: float, kind: int, col: Color,
		stroke: float, car_id: String = "") -> void:
	ci.draw_set_transform(p, 0.0, Vector2(icon_px, icon_px))
	# The pole/outline widths are in LOCAL units, so they are divided back out of the scale to
	# stay a constant number of screen pixels at either map size.
	var line := maxf(stroke, 1.0) / icon_px
	match kind:
		Kind.CAR:
			# THIS car's own side profile when one is baked (CarSilhouettes, generated from the
			# body model — see tools/bake_car_silhouettes.gd), so a prize-car pin says WHICH car:
			# a kei van, a long low coupe and a hot hatch are three different shapes here. The
			# convex pieces are cached inside CarSilhouettes and handed over unmodified, so this
			# allocates nothing per frame, exactly like the authored glyphs.
			var pieces := CarSilhouettes.convex_pieces(car_id)
			if pieces.is_empty():
				ci.draw_colored_polygon(_G_CAR_BODY, col)
				for i in _G_CAR_WHEELS.size():
					ci.draw_circle(_G_CAR_WHEELS[i], _G_CAR_WHEEL_R, col)
			else:
				for piece: PackedVector2Array in pieces:
					ci.draw_colored_polygon(piece, col)
				# The wheels are already inside the outline; the circles go on top because a
				# traced arch is a handful of jagged cells at 14 px and a drawn circle is not.
				var hubs := CarSilhouettes.wheels(car_id)
				var wheel_r := CarSilhouettes.wheel_radius(car_id)
				for i in hubs.size():
					ci.draw_circle(hubs[i], wheel_r, col)
		Kind.SPECIAL:
			ci.draw_colored_polygon(_G_TROPHY_BOWL, col)
			ci.draw_colored_polygon(_G_TROPHY_STEM, col)
			ci.draw_colored_polygon(_G_TROPHY_BASE, col)
		Kind.GARAGE:
			ci.draw_colored_polygon(_G_GARAGE_ROOF, col)
			ci.draw_colored_polygon(_G_GARAGE_BODY, col)
		_:
			# RALLY, and any PART whose texture failed to resolve — the flag is the fallback the
			# 3D marker uses for exactly the same case.
			ci.draw_polyline(_G_FLAG_POLE, col, line, false)
			ci.draw_colored_polygon(_G_FLAG_PENNANT, col)
	ci.draw_set_transform_matrix(Transform2D.IDENTITY)


# The player: position and HEADING. An arrow, not a dot — heading is half the answer to "where
# am I", and on a heading-up minimap the arrow is what proves the panel is rotating with you.
func _paint_player(ci: CanvasItem, rect: Rect2, centre: Vector2, span_m: float, rot: float,
		alpha: float, icon_px: float) -> void:
	var p := project(Vector2(_car_pos.x, _car_pos.z), centre, span_m, rot, rect)
	if not rect.has_point(p):
		return
	# Never SMALLER than a destination glyph, whichever map this is: the pins grew when they became
	# icons, and an arrow the player has to hunt for defeats the point of a minimap.
	var r := maxf(_cfg_float("overworld_map_pin_px", 5.0), icon_px)
	var dir := _car_forward.rotated(rot)
	var side := Vector2(-dir.y, dir.x)
	var pts := PackedVector2Array([
		p + dir * r * _ARROW_LONG,
		p - dir * r * 0.7 + side * r * _ARROW_WIDE,
		p - dir * r * 0.7 - side * r * _ARROW_WIDE,
	])
	ci.draw_colored_polygon(pts, Color(UITheme.GREEN, alpha))
	# An INK outline, so the arrow still separates itself from a gold car pin or a red trophy
	# sitting under it. The pins are icons now, i.e. busier than the old dots, and the player's own
	# position must remain the single most findable thing on the map. One arrow per frame, so the
	# small allocation above is not worth hoisting the way the pin glyphs are.
	ci.draw_polyline(PackedVector2Array([pts[0], pts[1], pts[2], pts[0]]),
			Color(UITheme.INK, alpha), _cfg_float("overworld_map_line_width_px", 2.0) * 0.5, false)


# The north indicator. Drawn even on the rotating minimap — WITHOUT it the panel cannot be
# correlated with the (always north-up) full map, which is the whole reason rotation is safe.
func _draw_north(ci: CanvasItem, rect: Rect2, rot: float, alpha: float) -> void:
	var font := UITheme.font()
	if font == null:
		return
	# World north is -z; the view transform is a rotation, so the same rotation applies.
	var dir := Vector2(0.0, -1.0).rotated(rot)
	var at := rect.get_center() + dir * (minf(rect.size.x, rect.size.y) * 0.5 * _NORTH_STALK)
	ci.draw_string(font, at - Vector2(float(UITheme.FONT_SIZE) * 0.3, 0.0), "N",
			HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_SIZE, Color(UITheme.INK, alpha))


func _kind_color(kind: int) -> Color:
	# The house palette's existing meanings rather than a new legend, matching the compass:
	# gold is reward, green is "your own thing", red is the showdown.
	match kind:
		Kind.CAR, Kind.PART:
			return UITheme.GOLD
		Kind.SPECIAL:
			return UITheme.RED
		Kind.GARAGE:
			return UITheme.GREEN
		_:
			return UITheme.INK


## Whose name the full map draws: the hovered pin, else the selected one. Exactly ONE id.
func _named_id() -> String:
	if _hover_id != "" and _index_of(_hover_id) >= 0:
		return _hover_id
	return _selected_id


func _write_footer() -> void:
	if _footer == null:
		return
	var sel := selected()
	var named := _named_id()
	var i := _index_of(named)
	if i >= 0:
		sel = _shown[i]
	if sel.is_empty():
		_footer.text = UITheme.caps("M / B closes  ·  nothing revealed yet")
		return
	# With a route set, quote the ROAD distance to the destination being guided to — that is the
	# number the player is actually driving. Otherwise it is the straight-line distance to whatever
	# pin is being pointed at.
	var right := UITheme.caps("aim + enter routes  ·  M / B closes")
	if _route_id != "" and String(sel.get("id", "")) == _route_id:
		right = "%s  ·  %s" % [
			UITheme.caps("%s by road" % _distance_text(_route_length_m)),
			UITheme.caps("enter cancels  ·  M / B closes"),
		]
	_footer.text = "%s  ·  %s   %s" % [
		UITheme.caps(String(sel.get("name", ""))),
		_distance_text(float(sel.get("distance_m", 0.0))),
		right,
	]


func _distance_text(m: float) -> String:
	if m >= 1000.0:
		return "%.1f km" % (m / 1000.0)
	return "%d m" % int(round(m))


# The fog, as a DARK overlay: the shared 64×64 lit mask inverted into alpha, so unexplored map
# is dark by exactly the amount the terrain shader darkens the ground.
#
# ==========================================================================================
# THIS IS THE BLACK/WHITE FLICKER BUG. Two rules here, and neither is an optimisation.
# ==========================================================================================
# It used to run unconditionally on every `refresh()` — twice a second, whether the map was open
# or not — and each run did `ImageTexture.create_from_image`, i.e. built a BRAND NEW texture and
# dropped the last reference to the old one.
#
# A `CanvasItem`'s recorded draw commands hold the texture by RID, and they are NOT re-recorded
# until something calls `queue_redraw`. Freeing the texture the last frame drew with therefore
# leaves the canvas item pointing at a dead RID, which the renderer substitutes with its 1x1 WHITE
# fallback — so the fog rectangle, i.e. the map's whole background, flashes WHITE until the next
# redraw paints it black again. And the redraw is deliberately GATED on the car having moved
# (`_moved_enough`), so with the car stopped — which is exactly what happens while the full map is
# open, since opening it locks the controls — the white state persists until the next rebuild.
# Hence "the background changes constantly between black and white", on a 0.5 s beat.
#
# The MINIMAP showed the same flicker for the same reason, and dropping the fog from the minimap
# only hid it there. Same texture, same shared painter, one bug.
#
#   1. REBUILD ONLY WHEN THE MASK ACTUALLY CHANGED. `_fog_stamp` is the lit set the live texture
#      was built from; an unchanged stamp is a no-op, so a parked car re-uploads nothing.
#   2. UPDATE IN PLACE. `ImageTexture.update` keeps the SAME RID, so an already-recorded draw
#      command stays valid across a rebuild and can never sample a freed texture.
# Both hosts are then explicitly re-drawn, because the movement gate cannot know the fog moved.
func _rebuild_fog() -> void:
	# NOTE both disable paths below drop the texture through _drop_fog rather than nulling the
	# field directly. Nulling it here was the ORIGINAL bug surviving next to its own fix: an
	# already-recorded draw command still holds the texture by RID, so releasing it without
	# forcing a redraw leaves that command sampling a freed RID — the 1x1 white flash again,
	# just reached by retuning overworld_map_fog_alpha to zero instead of by the refresh timer.
	if not _visuals or _size_m <= 0.0:
		_drop_fog()
		return
	var shroud := clampf(_cfg_float("overworld_map_fog_alpha", 0.86), 0.0, 1.0)
	if shroud <= 0.0:
		_drop_fog()
		return
	var stamp := "%.4f|%s" % [shroud, str(RallyLibrary.lit_sources(_profile()))]
	if stamp == _fog_stamp and _fog_tex != null:
		return
	var lit := MapFog.build(_profile())
	if lit == null:
		return
	var src := lit.get_image()
	if src == null:
		return
	var size := MapFog.MASK_SIZE
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var a := (1.0 - src.get_pixel(x, y).r) * shroud
			img.set_pixel(x, y, Color(0.0, 0.0, 0.0, a))
	if _fog_tex == null:
		_fog_tex = ImageTexture.create_from_image(img)
	else:
		_fog_tex.update(img)
	_fog_stamp = stamp
	if _minimap != null:
		_minimap.queue_redraw()
	if _full_canvas != null:
		_full_canvas.queue_redraw()
