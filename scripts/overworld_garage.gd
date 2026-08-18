class_name OverworldGarage
extends Node3D
# THE DRIVE-IN GARAGE. A real building standing on the overworld terrain that the player
# DRIVES INTO, after which the car is seated on a lift, raised, and the tune / upgrade pages
# open — all without leaving `overworld.tscn`.
#
# This replaces the old "park on the garage zone for N seconds, then change_scene_to_file to
# hq.tscn" loop. Nothing here touches `RallySession.return_to_garage`, `Scenes.HQ` or any
# `hq_*` node: the HQ map-table hub still exists and still works, it is simply no longer where
# the garage lives.
#
# WHAT IS BORROWED FROM hq.gd, AND WHAT IS NOT. The CONTRACTS are copied verbatim in spirit:
#   * the three pages (`Page.HUB` / `TUNE` / `UPGRADES`) and their back edges;
#   * `TuningPanel.setup(owned, Callable(), on_wheels)` with a no-op on_change, exactly as the
#     HQ lift passes it (a tune edit lands on the next fielding, it does not re-field the car);
#   * `UpgradesGrid.setup(owned, on_change, on_swap, UpgradesGrid.NO_LIMIT)` — NO_LIMIT is
#     deliberate and explicit: the garage is not a commitment point, so no power-to-weight
#     ceiling belongs here (that gate lives at the start line / car park);
#   * the on_change job — re-read `Save.selected_car()` and refresh the CAR so a freshly
#     fitted part is visible on the model (hq.gd `_on_lift_upgrade_changed` respawns its
#     display PROP; we have the player's real car, so we `apply_owned` it in place).
# What is NOT borrowed: the camera-station machinery, the hub cursor, the prize-car props and
# the whole `_unhandled_input` spatial-nav rig. Those exist because the HQ's stations are a 3D
# carousel driven by left/right; these pages are flat widget lists, which is precisely what
# `MenuNav.attach` is for (features/menus.md → "Menu navigation").
#
# THE CAR IS THE PLAYER'S OWN CAR. It drove in. Nothing here instantiates a car, and every
# repositioning goes through `Car.reset_to` (the only teleport the physics server honours);
# `settle_wheels_to_ground` is called only while the body is FROZEN, which is its documented
# precondition (`ghost_car.gd` violates it and gets wheels in the arches). The car is frozen for
# the raise and the parked dwell only — THE DESCENT IS LIVE, so the wheels catch the ground
# themselves on the way down instead of being teleported into it (see `_hand_car_to_physics`).
#
# HEADLESS: `visuals: false` builds no meshes and no model at all, while `update_with` still
# drives the whole enter → raise → pages → lower → exit path, and the pages themselves still
# build (a Control tree needs no renderer), so the menu is testable without a scene.

# Raised once the car is parked on the lift and the pages are up.
signal entered()
# Raised once the lift is back down and the car has its controls again.
signal exited()

# The lift pages, mirroring hq.gd's `LiftPage`.
enum Page { HUB, TUNE, UPGRADES }

# Where the garage is in its own lifecycle. `RAISING`/`LOWERING` are the animated halves; the
# car is frozen and locked for all three non-OUTSIDE states, so there is no window in which
# the player can drive a half-lifted car.
enum State { OUTSIDE, RAISING, PARKED, LOWERING }

# How far PAST the door plane (toward the back wall) the car's centre must be before the bay
# claims it. Not a tunable: it is "far enough in that the nose alone doesn't count", derived
# from the shape of the building rather than from taste.
const ENTRY_INSET_M := 3.0
# Wall thickness for the colliders. Matches the visual walls garage.gd builds.
const WALL_T := 0.4
# How far up the walls the colliders reach. Anything over the car's roof is the same wall.
const WALL_H := 5.0
# Slack left between the building's outermost corner and the edge of the flat pad, metres. The
# corner sitting exactly ON the pad edge is the corner sitting on the feather ramp.
const PAD_MARGIN_M := 0.5
# The gap between the two bays (and to each side wall) that garage.gd builds. Restated here for
# the same reason `_total_w` is: the footprint maths must work with no model built.
const BAY_GAP_M := 0.5

var _visuals := true
var _ground_at := Callable()
# Variant, not Node3D: `controls_locked`, `freeze`, `linear_velocity`, `apply_owned` and
# `reset_to` are car.gd members reached dynamically, the same discipline overworld_zones.gd
# and CarProp use, so this file never depends on the analyser resolving car.tscn's script.
var _car: Variant = null

var _state: int = State.OUTSIDE
# Is the car a LIVE physics body right now? True from the moment `leave()` starts the descent
# until the descent ends — the lift lowers a car the solver is driving, not a frozen prop, so the
# wheels resolve their own ground contact on the way down. Everything that writes the car's
# transform or its wheel visuals is gated on this being false.
var _car_live := false
var _page: int = Page.HUB
# Has the car been seen OUTSIDE the bay since the last visit? Until it has, driving in cannot
# fire — the same arm-on-exit latch OverworldZone uses, and what makes "reverse back out" a
# clean exit rather than an instant re-entry.
var _armed := false
var _lift_t := 0.0            # 0..1 through the raise
var _model: Node3D = null
var _pad: Node3D = null       # the lift platform (visuals only)
var _bay_w := 0.0
var _bay_d := 0.0
var _total_w := 0.0
var _pad_local := Vector3.ZERO   # the lift pose, in this node's local space

# The owned-car dictionary the pages are bound to. Re-read from Save on every change.
var _owned: Dictionary = {}

var _layer: CanvasLayer = null
var _ui_root: Control = null
var _hub_page: VBoxContainer = null
var _tune_page: VBoxContainer = null
var _upg_page: VBoxContainer = null
var _tune_panel: TuningPanel = null
var _upgrades: UpgradesGrid = null
var _repair_button: Button = null
var _hub_title: Label = null
var _tune_actions: HBoxContainer = null   # holds "< Back" plus TuningPanel's own buttons
var _upg_back: Button = null              # bound through UpgradesGrid.bind_close_button


# `opts`:
#   world_pos    Vector3                          the garage's world point. Optional if
#                                                 `to_world` is given.
#   to_world     Callable(Vector2 map_pos) -> Vector3   used with `map_pos` when `world_pos`
#                                                 is absent. The overworld owns the
#                                                 conversion; this file never reimplements it.
#   map_pos      Vector2                          defaults to RallyLibrary.HQ_MAP_POS.
#   ground_at    Callable(Vector3) -> float       optional. Ground height — seats the building
#                                                 on the terrain and settles the wheels.
#   offset_xz    Vector2                          world-XZ side-step from that point, applied
#                                                 before the ground probe. Comes from
#                                                 `placement_from_config` — see "WHERE THE
#                                                 BUILDING STANDS" below.
#   yaw          float (radians)                  which way the opening faces. 0 = opens +Z.
#   car          the player car node              optional (only `update` needs it).
#   visuals      bool                             false = no meshes (headless).
func setup(opts: Dictionary) -> void:
	_visuals = bool(opts.get("visuals", true))
	_ground_at = opts.get("ground_at", Callable())
	_car = opts.get("car", null)
	var pos: Vector3 = opts.get("world_pos", Vector3.ZERO)
	if not opts.has("world_pos"):
		var to_world: Callable = opts.get("to_world", Callable())
		if not to_world.is_valid():
			push_error("OverworldGarage.setup: needs `world_pos` or `to_world` — no way to place it.")
			return
		var map_pos: Vector2 = opts.get("map_pos", RallyLibrary.HQ_MAP_POS)
		pos = to_world.call(map_pos)
	# The side-step off the road, applied BEFORE the ground probe so the building is seated on
	# the terrain where it actually stands rather than where the pin is.
	var offset_xz: Vector2 = opts.get("offset_xz", Vector2.ZERO)
	pos += Vector3(offset_xz.x, 0.0, offset_xz.y)
	if _ground_at.is_valid():
		var y: float = _ground_at.call(pos)
		if is_finite(y):
			pos.y = y
	position = pos
	rotation = Vector3(0.0, float(opts.get("yaw", 0.0)), 0.0)

	_bay_w = maxf(Config.data.overworld_garage_bay_width_m, 3.0)
	_bay_d = maxf(Config.data.overworld_garage_bay_depth_m, 6.0)
	_total_w = total_width_m(_bay_w)
	# The lift sits in bay 0 (the left / −X bay), centred a little back from the door so the
	# car is fully under the roof once it is up.
	_pad_local = Vector3(_bay_center_x(0), 0.0, -_bay_d * 0.55)

	_build_walls()
	if _visuals:
		_build_model()
	_build_ui()
	_armed = true


# Per-frame entry point, reading the live car. All the logic is in `update_with`, so a test
# never needs a car.
func update(delta: float) -> void:
	if _car == null or not is_instance_valid(_car):
		return
	var node: Node3D = _car
	var vel: Vector3 = _car.linear_velocity
	update_with(delta, node.global_position, vel.length() * 3.6)


# The whole per-frame job with the car's state INJECTED: run the lift animation, then decide
# whether driving in (or back out) changes anything.
func update_with(delta: float, car_pos: Vector3, speed_kmh: float) -> void:
	_advance_lift(delta)
	if _state == State.OUTSIDE:
		var inside := inside_bay(car_pos)
		if not inside:
			_armed = true
			return
		# Entering AT SPEED does not seat the car: you are still moving, and snapping a
		# 90 km/h car onto a lift reads as a crash. The back wall is solid, so a fast entry
		# simply stops — and the moment it has stopped, this fires. There is no way to end up
		# inside and stuck.
		if _armed and speed_kmh <= maxf(Config.data.overworld_garage_enter_max_kmh, 0.0):
			enter()
		return
	# Already parked: the car is frozen and locked, so nothing it does can change the state.


# --- WHERE THE BUILDING STANDS -------------------------------------------------------------
#
# The HQ pin is a road JUNCTION: the overworld road network treats it as a node like any other,
# so edges arrive at it from several bearings at once. Dropping the building ON the pin therefore
# puts it in the middle of a crossroads — every road runs into a wall, and the bays are reachable
# only from whichever direction happens to face the opening.
#
# So the garage stands OFF TO THE SIDE, exactly as a real one does: offset PERPENDICULAR to the
# road that passes the pin, and yawed to face back at it. Then the road runs across the front of
# the bays, and a driver arriving on ANY of its approaches turns once and drives straight in.
#
# The side is derived from the road geometry, never from a compass direction:
#   * a road is a LINE, not an arrow — two edges leaving the pin in opposite directions are the
#     same road — so the bearings are averaged as DOUBLED angles (the standard axial mean), which
#     is invariant to each edge's arbitrary sign. A plain vector mean of a straight through-road
#     cancels to zero and yields no axis at all;
#   * of the two perpendiculars, the one pointing AWAY from where the roads actually lean (the
#     plain vector sum) is chosen, so the building goes on the emptier side of the junction;
#   * ties — a perfectly balanced junction, or no roads at all — resolve by a fixed rule, not by
#     chance, because the terrain chunk cache is keyed on a stamp that includes this placement.
#
# Everything here is a pure static function of its arguments: same network, same placement.


# Full outside width of the two-bay building, metres — garage.gd's own formula, restated so the
# footprint maths does not need a model to exist (headless builds none).
static func total_width_m(bay_width_m: float) -> float:
	return 2.0 * maxf(bay_width_m, 3.0) + 3.0 * BAY_GAP_M


# The furthest the door plane may stand from the pad's centre before a BACK corner of the
# building leaves the pad, metres. The pad is a circle of `pad_radius_m` centred on the pin
# (overworld_pads.gd), the building extends `depth_m` straight back from the door plane, and its
# widest points are the back corners at ±half-width. Note the offset and the depth SHARE an axis
# (the building is stepped sideways off the road and then turned to face back at it), so the
# offset adds to the depth, not to the width — and the half-width is half the WHOLE two-bay
# building, not half a bay.
#
# Negative-safe: a footprint that already overruns the pad with the door plane ON the pin answers
# 0, i.e. "stay on the pin". No offset could rescue such a footprint — every offset pushes the
# back corners further out — so 0 is the best available answer rather than a fudge.
static func max_offset_m(pad_radius_m: float, bay_width_m: float, depth_m: float) -> float:
	var half_w := total_width_m(bay_width_m) * 0.5
	var reach := maxf(pad_radius_m - PAD_MARGIN_M, 0.0)
	var span := reach * reach - half_w * half_w
	if span <= 0.0:
		return 0.0
	return maxf(sqrt(span) - maxf(depth_m, 0.0), 0.0)


# The unit direction to offset the building in, given the directions the roads LEAVE the pin in
# (`OverworldRoads.approach_dirs`). See the block comment above for why the mean is axial.
static func road_side_dir(dirs: Array) -> Vector2:
	var sx := 0.0
	var sy := 0.0
	var lean := Vector2.ZERO
	for d in dirs:
		var v: Vector2 = d
		if v.length_squared() <= 0.0:
			continue
		v = v.normalized()
		var a := atan2(v.y, v.x)
		sx += cos(2.0 * a)
		sy += sin(2.0 * a)
		lean += v
	# No roads (or a junction whose bearings cancel even as axes, e.g. a perfect X): fall back to
	# a FIXED axis rather than to nothing, so the placement stays a function of its inputs.
	var axis_angle := 0.0
	if absf(sx) > 1e-6 or absf(sy) > 1e-6:
		axis_angle = 0.5 * atan2(sy, sx)
	var axis := Vector2(cos(axis_angle), sin(axis_angle))
	var n := Vector2(-axis.y, axis.x)
	# Prefer the emptier side; on a balanced junction fall through to the fixed tie-break so the
	# answer never depends on floating-point noise.
	var bias := n.dot(lean)
	if bias > 1e-4:
		n = -n
	elif absf(bias) <= 1e-4 and (n.y < 0.0 or (absf(n.y) <= 1e-6 and n.x < 0.0)):
		n = -n
	return n


# THE placement: where the garage node goes relative to the HQ pin, and which way it faces.
# Returns { "offset": Vector2 (world XZ, from the pin to the door-plane centre),
#           "yaw": float (radians, the `yaw` setup option),
#           "dir": Vector2 (the unit side direction), "distance_m": float (the CLAMPED offset) }.
# `offset_m` is a wish: it is clamped to `max_offset_m` so the building stays on its flat pad.
static func road_side_placement(dirs: Array, offset_m: float, pad_radius_m: float,
		bay_width_m: float, depth_m: float) -> Dictionary:
	var n := road_side_dir(dirs)
	var d := clampf(offset_m, 0.0, max_offset_m(pad_radius_m, bay_width_m, depth_m))
	# The opening is local +Z, so the yaw that points it back at the pin is the one that maps
	# +Z onto -n. Basis(UP, yaw) * +Z is (sin yaw, 0, cos yaw), hence atan2(-n.x, -n.y).
	return {
		"offset": n * d,
		"yaw": atan2(-n.x, -n.y),
		"dir": n,
		"distance_m": d,
	}


# The same placement with the CONFIGURED footprint and pad filled in — what the overworld calls.
static func placement_from_config(dirs: Array) -> Dictionary:
	return road_side_placement(dirs,
		Config.data.overworld_garage_road_offset_m,
		Config.data.overworld_pad_garage_radius_m,
		Config.data.overworld_garage_bay_width_m,
		Config.data.overworld_garage_bay_depth_m)


# --- Public state (for the overworld's HUD, and for tests) --------------------------------


func is_inside() -> bool:
	return _state != State.OUTSIDE


func state() -> int:
	return _state


func page() -> int:
	return _page


# Height of the lift above the bay floor, in metres. 0 while down.
func lift_height() -> float:
	return _lift_t * maxf(Config.data.overworld_garage_lift_height_m, 0.0)


# The menu root, so the host (and a test) can reach the pages.
func ui_root() -> Control:
	return _ui_root


# Is `world_pos` inside the bay footprint? Pure geometry against this node's local space —
# no physics, no Area3D — which is what lets the whole entry path run headless.
func inside_bay(world_pos: Vector3) -> bool:
	var local: Vector3 = to_local(world_pos)
	if absf(local.x) > _total_w * 0.5 - 0.5:
		return false
	return local.z <= -ENTRY_INSET_M and local.z >= -_bay_d


# --- Entering, and the lift ---------------------------------------------------------------


# Seat the car on the lift and open the pages. Public so the host (or a test) can drive the
# transition without simulating a drive-in.
func enter() -> void:
	if _state != State.OUTSIDE:
		return
	# Nothing to service without a car in the profile. Unreachable in practice (you drove
	# here), but the pages bind to an owned-car dictionary and must never be handed {}.
	if Save.selected_instance_id() < 0:
		return
	_state = State.RAISING
	_armed = false
	_lift_t = 0.0
	_seat_car_on_lift()
	_owned = Save.get_car(Save.selected_instance_id())
	# SHOW THE MENU BEFORE BUILDING THE PAGE, not after. `_open_page` resolves the page's
	# focus cursor (MenuNav's `first`, and the grab that puts the cursor on screen), and
	# `UITheme.is_focusable` — which every one of those decisions goes through — requires
	# `is_visible_in_tree()`. Opening a page while its CanvasLayer is still hidden therefore
	# resolves NOTHING focusable, leaves `first` null, and the menu comes up with a dead
	# cursor that not even a key press can revive (MenuNav's "nothing focused" fallback is
	# gated on the same predicate). This is the one ordering that has to be right.
	_show_ui(true)
	_open_page(Page.HUB)
	entered.emit()


# Lower the lift, hand the car back, and let the player drive out. Every page routes here
# eventually (see `_open_page`), so there is no page from which the player is stuck.
func leave() -> void:
	if _state == State.OUTSIDE or _state == State.LOWERING:
		return
	_state = State.LOWERING
	_show_ui(false)
	# Park the page state on the hub so the NEXT visit opens showing the hub rather than
	# whatever page was up when the player drove out, and drop the focus cursor with the
	# menu — a focus owner left on a hidden button would keep eating ui_accept out on the map.
	_page = Page.HUB
	_hub_page.visible = true
	_tune_page.visible = false
	_upg_page.visible = false
	var focused := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	if focused != null and _ui_root != null and _ui_root.is_ancestor_of(focused):
		focused.release_focus()
	# THE CAR GOES LIVE NOW, at the TOP of the descent — not at the bottom of it. See
	# `_hand_car_to_physics`.
	_hand_car_to_physics()


# Snap the car onto the lift pad, facing OUT of the bay, then freeze it. Facing out is what
# makes leaving a matter of driving forward rather than a three-point turn in a closed room.
func _seat_car_on_lift() -> void:
	if _car == null or not is_instance_valid(_car):
		return
	_car.set("controls_locked", true)
	# Drop the pad onto the terrain under it once, and REMEMBER it: `_apply_lift_height` reads
	# `_pad_local.y` as the floor the lift travels from, so a pad computed and thrown away
	# would put the car back at y=0 on the next frame.
	if _ground_at.is_valid():
		var probe := to_global(_pad_local)
		var y: float = _ground_at.call(probe)
		if is_finite(y):
			_pad_local.y = to_local(Vector3(probe.x, y, probe.z)).y
	var pad := _pad_local
	# RIDE HEIGHT, not deck height. `settled_ride_height()` is how far a settled car's body origin
	# rests ABOVE the ground under it (car.gd → "Static rest pose"); seating the origin ON the deck
	# instead buries the wheels half a radius into it, which reads as a sunk car on the lift and —
	# worse — means the body is already interpenetrating the terrain the moment physics resumes.
	pad.y += _ride_height()
	# car.tscn faces −Z, so a half turn points it back out of the +Z opening.
	var pose := global_transform * Transform3D(Basis(Vector3.UP, PI), pad)
	# reset_to is the ONLY safe teleport: a bare global_transform write is discarded by the
	# physics server unless it lands inside the step, and it also wakes a sleeping body.
	_car.call("reset_to", pose)
	_car.set("freeze", true)
	_car_live = false


# Advance the raise / lower, and write the height onto the car and the platform.
func _advance_lift(delta: float) -> void:
	if _state == State.OUTSIDE or _state == State.PARKED:
		return
	var dur := maxf(Config.data.overworld_garage_lift_time_s, 0.01)
	var dir := 1.0 if _state == State.RAISING else -1.0
	_lift_t = clampf(_lift_t + dir * delta / dur, 0.0, 1.0)
	_apply_lift_height()
	if _state == State.RAISING and is_equal_approx(_lift_t, 1.0):
		_state = State.PARKED
		_settle_wheels()
	elif _state == State.LOWERING and is_zero_approx(_lift_t):
		_state = State.OUTSIDE
		_release_car()


# How far above the deck the car's body origin rides. Read from the car so it tracks the fitted
# wheels and suspension; 0 for a stub without the method (headless tests), which is exactly the
# old behaviour and keeps the geometry assertions simple.
func _ride_height() -> float:
	if _car == null or not is_instance_valid(_car) or not _car.has_method("settled_ride_height"):
		return 0.0
	var h: float = _car.call("settled_ride_height")
	return h if is_finite(h) else 0.0


# Write the current lift height onto the car body and the platform.
#
# The car half only runs while it is FROZEN (the raise, and the parked dwell), where a direct
# transform write is exactly right — a frozen body renders at its freeze pose. Once the descent
# has handed it back to physics it is a live body, and writing its transform per frame would be
# precisely the bug this is fixing: it would overrule the solver every step and the wheels would
# never get to resolve their own contact.
func _apply_lift_height() -> void:
	var h := lift_height()
	if not _car_live and _car != null and is_instance_valid(_car):
		var node: Node3D = _car
		var local := to_local(node.global_position)
		node.global_position = to_global(Vector3(local.x, _pad_local.y + h + _ride_height(),
			local.z))
	if _pad == null or not is_instance_valid(_pad):
		return
	var deck_y := _pad_local.y + h
	if _car_live and _car != null and is_instance_valid(_car):
		# The deck follows the CAR down rather than the clock, because a falling car beats a
		# linear platform: gravity clears the (short) lift travel in about half the time the lift
		# takes, so a clock-driven deck would visibly sink out from under the wheels. Tracking the
		# lower of the two keeps the platform under the tyres the whole way down, and it can only
		# ever descend faster than scheduled, never hang above the car.
		var node: Node3D = _car
		var under := to_local(node.global_position).y - _ride_height()
		deck_y = clampf(minf(deck_y, under), _pad_local.y, deck_y)
	_pad.position = Vector3(_pad_local.x, deck_y, _pad_local.z)


# Droop the wheel visuals onto the platform under them. Safe ONLY because the body is frozen
# by now — `Car.settle_wheels_to_ground`'s docstring says "frozen props ONLY (a live solver
# would fight it)", and this is the one call site in this file that could get that wrong.
func _settle_wheels() -> void:
	if _car_live or _car == null or not is_instance_valid(_car):
		return
	if not _car.has_method("settle_wheels_to_ground"):
		return
	var deck := to_global(Vector3(_pad_local.x, _pad_local.y + lift_height(), _pad_local.z)).y
	_car.call("settle_wheels_to_ground", func(_p: Vector3) -> float: return deck)


# HAND THE CAR BACK TO PHYSICS — at the START of the descent, not at the end of it.
#
# The lift used to carry the car down as a frozen body and unfreeze it only once the platform had
# bottomed out. That drops a live car into the world in a single step with no history: the
# suspension solver has never run at this pose, and the wheels are handed a contact they have to
# resolve from nothing. The result was a wheel punching through the ground on the way out.
#
# Two things were wrong, and both are fixed here:
#   * THE VISUALS. `settle_wheels_to_ground` translates each wheel Visual DOWN by its droop, and
#     nothing on the live path ever translates it back (car.gd's `_update_visuals` only spins and
#     steers). A released car therefore rendered its wheels sunk by up to a full `wheel_rest_length`
#     below where the solver actually had them — a tyre through the floor with the physics
#     perfectly healthy. `clear_wheel_visual_droop` is the documented inverse.
#   * THE HANDOVER. Unfreezing at the TOP means the descent itself happens under the solver:
#     gravity brings the car down over the (short) lift travel with the wheel rays live the whole
#     way, so each wheel catches the ground as it arrives instead of being teleported into it.
#
# `controls_locked` stays ON until the descent finishes, so the player cannot drive a car that is
# still coming down — the state machine, not the freeze flag, is what owns that.
func _hand_car_to_physics() -> void:
	if _car == null or not is_instance_valid(_car):
		_car_live = true
		return
	if _car.has_method("clear_wheel_visual_droop"):
		_car.call("clear_wheel_visual_droop")
	_car.set("freeze", false)
	_car_live = true


# The descent has finished: give the controls back. The car has been a live physics body since
# `leave()`, so there is nothing to unfreeze here — but the set is kept (and is idempotent) so a
# caller that forces the state machine straight to OUTSIDE still ends with a driveable car. The
# arm latch stays DOWN until the car is seen outside the bay again, so this does not immediately
# re-trigger.
func _release_car() -> void:
	if _car != null and is_instance_valid(_car):
		_car.set("freeze", false)
		_car.set("controls_locked", false)
	_car_live = false
	exited.emit()


# --- The building ------------------------------------------------------------------------


func _bay_center_x(i: int) -> float:
	# garage.gd's `_bay_center_x`, restated for the two-bay case so the footprint maths works
	# with no model built.
	return -_total_w * 0.5 + BAY_GAP_M + float(i) * (_bay_w + BAY_GAP_M) + _bay_w * 0.5


func _build_model() -> void:
	# garage.gd carries no class_name (it is a model builder, not an API), so it is reached
	# through its script rather than by type.
	var builder: GDScript = preload("res://scripts/garage.gd")
	var model := builder.new() as Node3D
	if model == null:
		return
	model.name = "GarageModel"
	# The overworld supplies the sky, the sun and the terrain, so the model brings neither its
	# own environment nor its own ground — exactly how hq.gd hosts it.
	model.set("build_environment", false)
	model.set("build_ground", false)
	model.set("num_bays", 2)
	model.set("bay_width", _bay_w)
	model.set("bay_depth", _bay_d)
	add_child(model)
	_model = model
	_build_pad()


# The lift platform: a low deck the car sits on, raised with it.
func _build_pad() -> void:
	var pad := Node3D.new()
	pad.name = "LiftPad"
	add_child(pad)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.18, 0.19, 0.22)
	mat.roughness = 0.7
	pad.add_child(MeshUtil.box(Vector3(2.6, 0.18, 4.6), mat, Vector3(0.0, -0.09, 0.0)))
	pad.position = _pad_local
	_pad = pad


# The COLLIDERS: back wall, two side walls, and the pillar between the bays. Built whether or
# not visuals are on — being a solid obstacle is behaviour, not decoration — and deliberately
# leaving the front open, which is the opening the player drives in through.
func _build_walls() -> void:
	var body := StaticBody3D.new()
	body.name = "GarageWalls"
	add_child(body)
	var half_w := _total_w * 0.5
	_add_box(body, Vector3(0.0, WALL_H * 0.5, -_bay_d), Vector3(_total_w, WALL_H, WALL_T))
	_add_box(body, Vector3(-half_w, WALL_H * 0.5, -_bay_d * 0.5), Vector3(WALL_T, WALL_H, _bay_d))
	_add_box(body, Vector3(half_w, WALL_H * 0.5, -_bay_d * 0.5), Vector3(WALL_T, WALL_H, _bay_d))
	# The divider between the two bays, so the front reads as two openings rather than one
	# hole — and so you cannot cut the corner between them.
	_add_box(body, Vector3(0.0, WALL_H * 0.5, -_bay_d * 0.5), Vector3(0.5, WALL_H, _bay_d))


func _add_box(body: StaticBody3D, centre: Vector3, size: Vector3) -> void:
	var shape := BoxShape3D.new()
	shape.size = size
	var owner_shape := CollisionShape3D.new()
	owner_shape.shape = shape
	owner_shape.position = centre
	body.add_child(owner_shape)


# --- The pages ----------------------------------------------------------------------------


func _build_ui() -> void:
	_layer = CanvasLayer.new()
	_layer.name = "GarageUI"
	_layer.layer = 40
	_layer.visible = false
	add_child(_layer)

	_ui_root = Control.new()
	_ui_root.name = "GarageMenu"
	_ui_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(_ui_root)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, UITheme.MARGIN)
	_ui_root.add_child(margin)

	# The pages sit against the RIGHT edge, leaving the raised car in view on the left — the
	# same read the HQ lift composes. A MarginContainer stretches its child, so the offset is
	# an expanding spacer rather than a size flag.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.GAP)
	margin.add_child(row)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(spacer)

	var panel := UITheme.panel()
	panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", UITheme.GAP)
	panel.add_child(column)

	_hub_page = _build_hub()
	_tune_page = _build_tune()
	_upg_page = _build_upgrades()
	column.add_child(_hub_page)
	column.add_child(_tune_page)
	column.add_child(_upg_page)


func _build_hub() -> VBoxContainer:
	var box := VBoxContainer.new()
	box.name = "Hub"
	box.add_theme_constant_override("separation", UITheme.GAP_TIGHT)
	_hub_title = UITheme.title("Garage")
	box.add_child(_hub_title)
	box.add_child(UITheme.row_button("Tune Setup", _open_page.bind(Page.TUNE)))
	box.add_child(UITheme.row_button("Upgrades", _open_page.bind(Page.UPGRADES)))
	_repair_button = UITheme.row_button("Repair", _repair_selected_car)
	box.add_child(_repair_button)
	box.add_child(UITheme.row_button("Drive Out", leave))
	return box


func _build_tune() -> VBoxContainer:
	var box := VBoxContainer.new()
	box.name = "Tune"
	box.add_theme_constant_override("separation", UITheme.GAP_TIGHT)
	_tune_panel = TuningPanel.new()
	box.add_child(_tune_panel)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", UITheme.GAP_TIGHT)
	actions.add_child(UITheme.row_button("< Back", _to_hub))
	# TuningPanel BUILDS its Reset / Wheels buttons but deliberately does not parent them —
	# the host places them (hq_overlays.gd does the same re-parenting into its actions row).
	# The panel is built lazily inside setup(), so this runs after the first setup() below.
	box.add_child(actions)
	_tune_actions = actions
	return box


func _build_upgrades() -> VBoxContainer:
	var box := VBoxContainer.new()
	box.name = "Upgrades"
	box.add_theme_constant_override("separation", UITheme.GAP_TIGHT)
	_upgrades = UpgradesGrid.new()
	box.add_child(_upgrades)
	_upg_back = UITheme.row_button("< Back", Callable())
	box.add_child(_upg_back)
	return box


# Move TuningPanel's own Reset / Wheels buttons into the page's action row. They are built
# inside its first setup() and left UNPARENTED for the host to place, so this runs after
# setup and is idempotent (a second call finds them already parented).
func _adopt_tune_actions() -> void:
	if _tune_panel == null or _tune_actions == null:
		return
	for button in _tune_panel.action_buttons():
		if button == null or not is_instance_valid(button):
			continue
		if button.get_parent() == null:
			_tune_actions.add_child(button)


func _to_hub() -> void:
	_open_page(Page.HUB)


# Show one page and bind it to the SELECTED car. Every page's back edge is wired here, so the
# "no page is a dead end" property is a property of this one function: HUB backs out of the
# garage entirely, TUNE and UPGRADES back to HUB.
func _open_page(next: int) -> void:
	if _state == State.OUTSIDE:
		return
	_page = next
	_owned = Save.get_car(Save.selected_instance_id())
	_hub_page.visible = next == Page.HUB
	_tune_page.visible = next == Page.TUNE
	_upg_page.visible = next == Page.UPGRADES
	var opened: Control = _hub_page
	match next:
		Page.TUNE:
			# on_change is a no-op and on_wheels is unwired, matching the HQ lift's own
			# contract: a tune edit lands on the next fielding rather than re-fielding the
			# car, and wheel swapping is still an HQ-lift page (see features/garage.md).
			_tune_panel.setup(_owned, Callable(), Callable())
			_tune_panel.refresh()
			_adopt_tune_actions()
			opened = _tune_page
			_bind_nav(_tune_page, _to_hub)
		Page.UPGRADES:
			# NO_LIMIT deliberately: the garage is not a commitment point, so no
			# power-to-weight ceiling gate belongs here.
			_upgrades.setup(_owned, _on_upgrade_changed, Callable(), UpgradesGrid.NO_LIMIT)
			# The grid owns Esc / gamepad-B itself (set_back_action) and gates the close
			# button through `request_close`, so the host binds rather than connects.
			_upgrades.set_back_action(_to_hub)
			_upgrades.bind_close_button(_upg_back, _to_hub)
			opened = _upg_page
			_bind_nav(_upg_page, _to_hub)
		_:
			_refresh_hub()
			_bind_nav(_hub_page, leave)
	# The house rules (row heights, uppercasing) on the freshly-built rows — hq.gd runs the
	# same pass as `_normalize_menus` after every page build. It is not only cosmetic: rows
	# built by `UITheme.row_button` carry NO minimum height, and a column of zero-height rows
	# all resolve to the same rect, which is enough to stop `find_valid_focus_neighbor` from
	# finding the row below. The directional cursor depends on this pass having run.
	UITheme.enforce(_ui_root)
	_focus_page(opened)


# ONE MenuNav per page, ever. `MenuNav.attach` is itself idempotent (it reuses a live nav
# already parented to the same root rather than stacking handlers), but that is its guarantee,
# not ours — routing every attach through here makes "one nav per page" a property of this
# file too, and gives the re-attach a single documented reason to exist:
#
#   the pages REBUILD their contents (UpgradesGrid.rebuild replaces every tile after an edit;
#   TuningPanel builds its sliders lazily inside its first setup()), and MenuNav captures
#   `first` at attach time. A nav attached once and never refreshed would keep pointing at a
#   freed or stale widget, and its "nothing focused" fallback — the thing that revives a lost
#   cursor on the first key press — would be dead. So we re-attach, with `grab: false`,
#   because the explicit `_focus_page` below owns the cursor placement.
func _bind_nav(page: Control, on_back: Callable) -> void:
	MenuNav.attach(page, {"on_back": on_back, "grab": false})


# FOCUS ON OPEN. The cursor is on the first row the moment a page appears, rather than only
# after the player presses something — a gamepad player must never be shown a menu with no
# cursor and have to guess that a press will summon one. Deferred as well as immediate: the
# immediate grab covers a page whose widgets are already settled (and is what makes this
# testable without waiting a frame), the deferred one covers a page still finishing a rebuild
# in the same frame. Both go through UITheme.focus_grab_first, which no-ops on anything
# invisible or dying, so a double call is harmless — and neither fights the mouse, since a
# click simply moves the focus somewhere else.
var _pending_focus: Control = null


func _focus_page(page: Control) -> void:
	if page == null or not is_instance_valid(page):
		return
	UITheme.focus_grab_first(page)
	# The deferred half CANNOT carry the page as a bound argument. A deferred call validates its
	# Object arguments when the queue drains, so if the page (or the whole garage) is freed in the
	# meantime — which is exactly what a test teardown does — Godot errors with "Cannot convert
	# argument 1 from Object to Object" before any body, and therefore before any is_instance_valid
	# guard inside the callee can help. Deferring a NO-ARG method on `self` avoids that entirely:
	# the engine drops a deferred call to a freed node, and the stored page is re-validated below.
	_pending_focus = page
	_focus_pending.call_deferred()


# The deferred half of _focus_page. Re-resolves the page rather than trusting the one captured a
# frame ago, because a rebuild (UpgradesGrid.rebuild replaces every tile) can free it in between.
func _focus_pending() -> void:
	var page := _pending_focus
	_pending_focus = null
	if page == null or not is_instance_valid(page) or not page.is_inside_tree():
		return
	UITheme.focus_grab_first(page)


func _show_ui(shown: bool) -> void:
	if _layer != null and is_instance_valid(_layer):
		_layer.visible = shown


# The UpgradesGrid on_change, the same job hq.gd's `_on_lift_upgrade_changed` does one host
# over: re-read the owned car and refresh the CAR so a freshly fitted part is on the model.
# The HQ respawns a display prop; ours is the player's real car, so it is reshaped in place
# through the supported `apply_owned` path and re-seated on the lift afterwards (apply_owned
# ends in a reset, which would otherwise drop the car back to its spawn pose).
func _on_upgrade_changed() -> void:
	_owned = Save.get_car(Save.selected_instance_id())
	if _car != null and is_instance_valid(_car) and _car.has_method("apply_owned"):
		_car.set("freeze", false)
		_car.call("apply_owned", _owned)
		_seat_car_on_lift()
		_apply_lift_height()
		_settle_wheels()
	_refresh_hub()


# The hub reads as "this car, in your garage": the heading names the car the pages will act
# on, so there is never a doubt about which car an upgrade lands on.
func _refresh_hub() -> void:
	if _hub_title != null and is_instance_valid(_hub_title):
		var entry := CarLibrary.for_owned(_owned)
		_hub_title.text = UITheme.caps(EngineSwap.display_name(entry, _owned))
	_refresh_repair_button()


# Repair, priced by Save so a quote and a charge can never disagree. Hidden entirely when the
# car needs nothing — a flat-priced button that would change nothing is the one thing it must
# never be.
func _refresh_repair_button() -> void:
	if _repair_button == null or not is_instance_valid(_repair_button):
		return
	var id := Save.selected_instance_id()
	var price := Save.repair_price(id)
	var needed := Save.car_needs_repair(id)
	_repair_button.visible = needed
	_repair_button.disabled = needed and Save.stars_available() < price
	_repair_button.text = "Repair (%d)" % price


func _repair_selected_car() -> void:
	var id := Save.selected_instance_id()
	if id >= 0 and Save.repair_car(id):
		_on_upgrade_changed()   # same refresh job: re-read the car, reshape, re-price
