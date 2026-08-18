extends GutTest
# OverworldGarage — the DRIVE-IN garage on the overworld: a building you drive into, a lift
# the car is raised on, and the tune / upgrade pages hosted in place (no scene change, no
# hq.tscn). See features/overworld.md → "The garage".
#
# Everything here runs headless with `visuals: false` and a STUB car: the whole enter → raise
# → pages → lower → exit path is driven through `update_with`, which takes the car's position
# and speed as arguments, so no physics server, renderer or car.tscn is involved.
#
# Nothing tunable is pinned. The lift height, the entry speed and the bay size are all
# GameConfig values and are only ever read back from Config, never asserted against a number.

const SaveTestHelpers = preload("res://tests/headless/save_test_helpers.gd")
const TEST_PATH := "user://test_overworld_garage.json"

var _save: Node
var _garage: OverworldGarage
var _car: StubCar


# The car, reduced to exactly the members OverworldGarage touches. A Node3D because the
# garage moves it in world space; everything else is the car.gd contract it depends on.
class StubCar:
	extends Node3D
	var controls_locked := false
	var freeze := false
	var linear_velocity := Vector3.ZERO
	var reset_calls := 0
	var applied: Array[Dictionary] = []
	# The settle/ride-height half of the contract. `ride_height` defaults to 0 so the seating
	# geometry the other tests assert is unchanged; the descent tests raise it deliberately.
	var ride_height := 0.0
	var settle_calls := 0
	var clear_calls := 0
	var last_deck := NAN

	func reset_to(xform: Transform3D) -> void:
		reset_calls += 1
		global_transform = xform

	func settled_ride_height() -> float:
		return ride_height

	func settle_wheels_to_ground(ground_at: Callable) -> void:
		settle_calls += 1
		last_deck = float(ground_at.call(global_position))

	func clear_wheel_visual_droop() -> void:
		clear_calls += 1

	func apply_owned(owned: Dictionary) -> String:
		applied.append(owned)
		return ""


func before_each() -> void:
	_save = SaveTestHelpers.redirect(TEST_PATH)
	CarFixtures.install()
	UpgradeFixtures.install()
	_save.grant_car(String(CarFixtures.cars()[0]["id"]))
	_car = StubCar.new()
	add_child_autofree(_car)
	_garage = OverworldGarage.new()
	add_child_autofree(_garage)
	_garage.setup({"world_pos": Vector3.ZERO, "car": _car, "visuals": false})


func after_each() -> void:
	# The upgrade picker parents at the scene root to escape a WorldPanel viewport, so it
	# does not die with this test's autofreed nodes; a survivor holds the one-modal slot.
	for node in get_tree().get_nodes_in_group(ConfirmPopup.MODAL_GROUP):
		if is_instance_valid(node) and not (node as Node).is_queued_for_deletion():
			(node as Node).free()
	UpgradeFixtures.restore()
	CarFixtures.restore()
	SaveTestHelpers.cleanup(TEST_PATH)


# --- Helpers ------------------------------------------------------------------------------


# A world point well inside the bay, and one well outside it. Derived from the garage's own
# `inside_bay` predicate rather than from the configured bay size, so retuning the building
# cannot break these tests.
func _inside_point() -> Vector3:
	var p := Vector3(0.0, 0.0, -0.1)
	for _i in range(400):
		if _garage.inside_bay(p):
			return p
		p.z -= 0.25
	return p


func _outside_point() -> Vector3:
	return Vector3(0.0, 0.0, 50.0)


# Park the car in the bay at a standstill and let the lift finish travelling.
func _drive_in() -> void:
	_garage.update_with(0.1, _outside_point(), 0.0)     # arm the entry latch
	_car.global_position = _inside_point()
	_garage.update_with(0.1, _inside_point(), 0.0)
	_settle_lift()


# Run the lift animation to completion (raise or lower).
func _settle_lift() -> void:
	for _i in range(200):
		_garage.update_with(0.1, _car.global_position, 0.0)


func _press(action: String) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = action
	e.pressed = true
	return e


# A real gamepad event bound to `action`, taken from the live InputMap rather than assuming
# a button index (which is a platform convention, not a contract).
func _gamepad_press(action: String) -> InputEvent:
	for e in InputMap.action_get_events(action):
		if e is InputEventJoypadButton:
			var press := (e as InputEventJoypadButton).duplicate() as InputEventJoypadButton
			press.pressed = true
			return press
	return null


func _nav_of(root: Control) -> MenuNav:
	for child in root.get_children():
		if child is MenuNav:
			return child as MenuNav
	return null


func _page_root(page: int) -> Control:
	var names := {
		OverworldGarage.Page.HUB: "Hub",
		OverworldGarage.Page.TUNE: "Tune",
		OverworldGarage.Page.UPGRADES: "Upgrades",
	}
	return _garage.ui_root().find_child(String(names[page]), true, false) as Control


# --- Driving in and out --------------------------------------------------------------------


# The core of the feature: driving into the bay puts the car on the lift, takes its controls
# away and raises it — with no scene change.
func test_driving_in_seats_the_car_and_locks_controls() -> void:
	var fired := [0]
	_garage.entered.connect(func() -> void: fired[0] += 1)
	assert_false(_garage.is_inside(), "not in the garage before driving in")
	_drive_in()
	assert_true(_garage.is_inside(), "driving into the bay puts the car in the garage")
	assert_true(_car.controls_locked, "the car's controls are locked on the lift")
	assert_true(_car.freeze, "the car is frozen on the lift")
	assert_gt(_car.reset_calls, 0, "the car was repositioned through reset_to, not a raw write")
	assert_gt(_garage.lift_height(), 0.0, "the lift raised the car off the floor")
	assert_eq(fired[0], 1, "entered fired exactly once")


# Arriving at speed must NOT snap the car onto the lift mid-slide. It waits for the car to
# stop — which it will, because the back wall is solid — so this can only delay entry.
func test_entering_at_speed_waits_until_the_car_has_stopped() -> void:
	_garage.update_with(0.1, _outside_point(), 0.0)
	var fast := Config.data.overworld_garage_enter_max_kmh + 30.0
	_garage.update_with(0.1, _inside_point(), fast)
	assert_false(_garage.is_inside(), "still driving — the lift does not grab a moving car")
	_garage.update_with(0.1, _inside_point(), 0.0)
	assert_true(_garage.is_inside(), "once stopped inside the bay, the car goes on the lift")


# Leaving lowers the lift and hands the car back. The player must never be left frozen.
func test_leaving_unfreezes_and_unlocks_the_car() -> void:
	var left := [0]
	_garage.exited.connect(func() -> void: left[0] += 1)
	_drive_in()
	_garage.leave()
	_settle_lift()
	assert_false(_garage.is_inside(), "leaving returns the garage to its outside state")
	assert_eq(_garage.lift_height(), 0.0, "the lift is all the way down")
	assert_false(_car.controls_locked, "the player has the controls back")
	assert_false(_car.freeze, "the car is unfrozen and drivable")
	assert_eq(left[0], 1, "exited fired exactly once")


# After leaving, sitting in the doorway must not immediately re-trigger — you have to leave
# and come back. Reversing out is what re-arms it (the same arm-on-exit latch zones use).
func test_reversing_out_is_what_rearms_the_entry() -> void:
	_drive_in()
	_garage.leave()
	_settle_lift()
	# Still parked in the bay: nothing happens, however long you sit there.
	for _i in range(20):
		_garage.update_with(0.1, _inside_point(), 0.0)
	assert_false(_garage.is_inside(), "sitting in the bay after leaving does not re-trigger")
	# Reverse out, then drive back in.
	_garage.update_with(0.1, _outside_point(), 0.0)
	_garage.update_with(0.1, _inside_point(), 0.0)
	assert_true(_garage.is_inside(), "leaving the bay and driving back in enters again")


# --- The pages -----------------------------------------------------------------------------


# The pages act on the player's SELECTED car, whichever that is.
func test_pages_bind_to_the_selected_car() -> void:
	var second: Dictionary = _save.grant_car(String(CarFixtures.cars()[1]["id"]))
	_save.set_selected_car(int(second["instance_id"]))
	_drive_in()
	_garage._open_page(OverworldGarage.Page.UPGRADES)
	assert_eq(_garage._owned.get("instance_id", -1), Save.selected_instance_id(),
		"the pages are bound to the selected car")


# An upgrade fitted from the garage persists through Save AND refreshes the car, so the part
# is on the model the player is looking at — the contract hq.gd's lift on_change keeps.
func test_an_upgrade_change_persists_and_refreshes_the_car() -> void:
	_drive_in()
	_garage._open_page(OverworldGarage.Page.UPGRADES)
	var id := Save.selected_instance_id()
	var item := String(UpgradeFixtures.upgrades()[0]["id"])
	assert_true(Save.install_upgrade(id, item, true), "the fixture part fitted")
	_garage._on_upgrade_changed()
	assert_true(_car.applied.size() > 0, "the live car was re-shaped so the part is visible")
	_save.save_now()
	_save.load_or_new()
	assert_true(Save.get_car(id).get("installed_upgrades", []).has(item),
		"the fitted part survived a save/load round trip")


# --- Navigation (keyboard AND gamepad) -----------------------------------------------------


# Every widget on every page is reachable by the native focus cursor — which is what carries
# the D-pad, the left stick and the arrow keys — and WASD moves it through MenuNav.
func test_keyboard_navigates_the_hub() -> void:
	_drive_in()
	var hub := _page_root(OverworldGarage.Page.HUB)
	await get_tree().process_frame
	for button in hub.find_children("*", "Button", true, false):
		assert_eq((button as Button).focus_mode, Control.FOCUS_ALL,
			"%s is reachable by the focus cursor" % (button as Button).name)
	var nav := _nav_of(hub)
	assert_not_null(nav, "the hub has a MenuNav")
	# FOCUS ON OPEN: the cursor is already on a row when the pages appear, so a gamepad player
	# is never shown a menu with no cursor and left to guess that a press will summon one.
	var first := hub.get_viewport().gui_get_focus_owner()
	assert_not_null(first, "the cursor is on screen the moment the garage pages open")
	nav._unhandled_input(_press("menu_down"))
	assert_ne(hub.get_viewport().gui_get_focus_owner(), first,
		"WASD moves the cursor down the hub")


# EXACTLY ONE MenuNav per page, however many times the player bounces between pages or
# re-enters the garage. A second nav on the same root would double-handle every press and
# leak a node per visit.
func test_pages_never_stack_a_second_menu_nav() -> void:
	for _visit in range(2):
		_drive_in()
		for page: int in [OverworldGarage.Page.TUNE, OverworldGarage.Page.UPGRADES,
				OverworldGarage.Page.HUB]:
			_garage._open_page(page)
		_garage.leave()
		_settle_lift()
		_garage.update_with(0.1, _outside_point(), 0.0)   # re-arm for the next visit
	for page: int in [OverworldGarage.Page.HUB, OverworldGarage.Page.TUNE,
			OverworldGarage.Page.UPGRADES]:
		var navs := 0
		for child in _page_root(page).get_children():
			if child is MenuNav:
				navs += 1
		assert_eq(navs, 1, "page %d carries exactly one MenuNav" % page)


# The gamepad drives the same menu: its Back button is bound to ui_cancel, which MenuNav
# routes to the page's back action.
func test_gamepad_back_leaves_the_garage_from_the_hub() -> void:
	_drive_in()
	var hub := _page_root(OverworldGarage.Page.HUB)
	await get_tree().process_frame
	var pad := _gamepad_press("ui_cancel")
	assert_not_null(pad, "ui_cancel carries a gamepad button, or a controller cannot go back")
	_nav_of(hub)._unhandled_input(pad)
	_settle_lift()
	assert_false(_garage.is_inside(), "gamepad back from the hub drives the car out")


# THE NO-TRAP PROPERTY: every page has a way out, and following it always ends with the
# player back in control of an unfrozen car. Asserted from EVERY page, not just the hub.
func test_no_page_can_trap_the_player() -> void:
	for page: int in [OverworldGarage.Page.HUB, OverworldGarage.Page.TUNE,
			OverworldGarage.Page.UPGRADES]:
		_drive_in()
		_garage._open_page(page)
		assert_eq(_garage.page(), page, "the page opened")
		if page != OverworldGarage.Page.HUB:
			var nav := _nav_of(_page_root(page))
			assert_not_null(nav, "page %d has a MenuNav, so back is bound" % page)
			nav._unhandled_input(_press("menu_back"))
			assert_eq(_garage.page(), OverworldGarage.Page.HUB,
				"page %d backs out to the hub" % page)
		_garage.leave()
		_settle_lift()
		assert_false(_garage.is_inside(), "the player got out from page %d" % page)
		assert_false(_car.controls_locked, "and has the controls back")
		# Re-arm for the next iteration.
		_garage.update_with(0.1, _outside_point(), 0.0)


# --- Headless ------------------------------------------------------------------------------


# `visuals: false` builds no meshes at all — the flag the overworld's cheap/headless paths
# rely on. The COLLIDERS are still built: being a solid building is behaviour, not decoration.
func test_visuals_false_builds_no_meshes() -> void:
	assert_eq(_garage.find_children("*", "MeshInstance3D", true, false).size(), 0,
		"no meshes are built with visuals off")
	assert_gt(_garage.find_children("*", "CollisionShape3D", true, false).size(), 0,
		"the walls are still solid, so you cannot drive through the building")


# With visuals ON the building exists and stands where it was placed. Cheap enough to build
# here because garage.gd is autoload-free procedural geometry, not a scene instance.
func test_visuals_on_builds_the_building() -> void:
	var g := OverworldGarage.new()
	add_child_autofree(g)
	g.setup({"world_pos": Vector3(10.0, 2.0, -5.0), "visuals": true})
	assert_gt(g.find_children("*", "MeshInstance3D", true, false).size(), 0,
		"the garage model is built with visuals on")
	assert_eq(g.global_position, Vector3(10.0, 2.0, -5.0),
		"the building stands at the world point it was given")


# --- Standing off the road -------------------------------------------------------------------
#
# The HQ pin is a road JUNCTION, so a building centred on it takes every approach into a wall.
# These cover the PLACEMENT statics that step it aside and turn it to face the road. All are
# pure functions of their arguments, so no scene, no roads network and no config value is
# pinned — only the geometric properties that must hold for any tuning.


# The world direction the opening points in for a given yaw. The bay opens along local +Z, and
# `setup` applies the yaw as a rotation about UP, so this is exactly what the building does.
func _opening_dir(yaw: float) -> Vector2:
	var v := Basis(Vector3.UP, yaw) * Vector3(0.0, 0.0, 1.0)
	return Vector2(v.x, v.z)


# The offset is PERPENDICULAR to the road axis and the opening looks back down it at the pin —
# which together are the whole point: the road runs across the front of the bays.
func test_the_garage_steps_aside_and_faces_back_at_the_road() -> void:
	# A straight through-road: two edges leaving the pin in opposite directions.
	var dirs: Array[Vector2] = [Vector2(1.0, 0.0), Vector2(-1.0, 0.0)]
	var place := OverworldGarage.road_side_placement(dirs, 6.0, 400.0, 7.5, 12.0)
	var n: Vector2 = place["dir"]
	assert_almost_eq(n.length(), 1.0, 0.001, "the side direction is a unit vector")
	assert_almost_eq(absf(n.dot(Vector2(1.0, 0.0))), 0.0, 0.001,
		"the offset is perpendicular to the road, not along it")
	assert_almost_eq(_opening_dir(place["yaw"]).dot(-n), 1.0, 0.001,
		"the opening faces back at the road it was offset from")
	assert_almost_eq((place["offset"] as Vector2).dot(n), float(place["distance_m"]), 0.001,
		"the offset is the clamped distance along the side direction")


# A road is a LINE, not an arrow: which end of an edge the polyline happens to start at must not
# change where the building goes. This is why the mean is axial (doubled-angle) rather than a
# plain vector mean — a plain mean of a through-road cancels to zero and yields no axis at all.
func test_the_side_is_the_same_whichever_way_the_edges_point() -> void:
	var road: Array[Vector2] = [Vector2(0.7, 0.3).normalized(), Vector2(0.75, 0.25).normalized()]
	var flipped: Array[Vector2] = [road[0], -road[1]]
	var a := OverworldGarage.road_side_dir(road)
	var b := OverworldGarage.road_side_dir(flipped)
	assert_almost_eq(absf(a.dot(b)), 1.0, 0.01,
		"reversing an edge's stored direction picks the same road axis")


# Determinism, because the terrain chunk cache is keyed on a stamp that includes this placement:
# the same inputs must give the same pose, and a junction with no usable bearings at all must
# still answer a finite, unit direction rather than a NaN or a zero vector.
func test_the_placement_is_deterministic_and_always_defined() -> void:
	var dirs: Array[Vector2] = [Vector2(1.0, 0.0), Vector2(0.0, 1.0), Vector2(-1.0, 0.0),
		Vector2(0.0, -1.0)]
	var first := OverworldGarage.road_side_placement(dirs, 5.0, 400.0, 7.5, 12.0)
	var second := OverworldGarage.road_side_placement(dirs, 5.0, 400.0, 7.5, 12.0)
	assert_eq(first["offset"], second["offset"], "the same junction gives the same offset")
	assert_eq(first["yaw"], second["yaw"], "the same junction gives the same yaw")
	var none := OverworldGarage.road_side_placement([], 5.0, 400.0, 7.5, 12.0)
	var n: Vector2 = none["dir"]
	assert_almost_eq(n.length(), 1.0, 0.001, "a junction with no roads still resolves a side")
	assert_true(is_finite(float(none["yaw"])), "and a finite yaw")


# THE constraint the offset lives under: the building has to stand on its flat pad, and it
# extends its full depth BACK from the door plane ALONG THE OFFSET DIRECTION — the offset and
# the depth share an axis, because the building is stepped sideways off the road and then turned
# to face back at it — so the worst point is a BACK CORNER at (±half-width, offset + depth) and
# offset + depth is what has to fit alongside the half-width inside the pad circle.
#
# Two regimes, and the sweep covers both. A footprint that already overruns its pad with the door
# plane ON the pin cannot be rescued by any offset (the offset only ever pushes it further out),
# so there the contract is "stay put and make nothing worse"; where it does fit, the contract is
# the strong one, "still inside the pad". Checked as geometry against arbitrary footprints rather
# than against the shipped numbers, so retuning any of them cannot break it.
func test_the_offset_never_walks_the_building_off_its_flat_pad() -> void:
	for pad: float in [8.0, 16.0, 30.0, 60.0]:
		for bay: float in [4.0, 7.5, 11.0]:
			for depth: float in [8.0, 12.0, 20.0]:
				var place := OverworldGarage.road_side_placement(
					[Vector2(1.0, 0.0)], 1000.0, pad, bay, depth)
				var d := float(place["distance_m"])
				var where := "pad=%.1f bay=%.1f depth=%.1f" % [pad, bay, depth]
				assert_gte(d, 0.0, "the offset never goes negative (into the road): " + where)
				var half_w := OverworldGarage.total_width_m(bay) * 0.5
				var corner := sqrt(half_w * half_w + (d + depth) * (d + depth))
				# The building's reach with the door plane on the pin — the best any placement
				# can do, since the offset only ever adds to it.
				var unmoved := sqrt(half_w * half_w + depth * depth)
				if unmoved > pad:
					assert_eq(d, 0.0,
						"a footprint too big for its pad stays on the pin rather than making it worse: "
							+ where)
				else:
					assert_lte(corner, pad + 0.001,
						"the back corner stays inside the pad for " + where)


# The configured distance is a WISH, not a command: a modest ask on a roomy pad is honoured
# exactly, so the clamp only ever bites when the pad genuinely cannot hold the building.
func test_a_modest_offset_on_a_roomy_pad_is_honoured_exactly() -> void:
	var place := OverworldGarage.road_side_placement([Vector2(0.0, 1.0)], 6.0, 400.0, 7.5, 12.0)
	assert_almost_eq(float(place["distance_m"]), 6.0, 0.001,
		"a pad with room to spare grants the asked-for side-step")


# --- The descent is live ---------------------------------------------------------------------
#
# The lift used to carry a FROZEN body all the way down and unfreeze it at the bottom, which
# dropped a live car into the world in one step with no solver history — a wheel would punch
# through the ground on the way out. These pin the two halves of the fix. All of it runs through
# the stub's freeze / settle contract, so nothing here needs a physics server.


# The car is handed back to physics at the TOP of the descent, and the CONTROLS — not the freeze
# flag — are what hold the player off until the platform is down. That is the whole point: the
# suspension solver runs for the length of the descent, so each wheel catches the ground as it
# arrives instead of being teleported into it.
func test_the_car_is_live_for_the_whole_descent() -> void:
	_drive_in()
	assert_true(_car.freeze, "frozen while parked on the raised lift")
	_garage.leave()
	assert_false(_car.freeze, "physics is handed back as the descent STARTS, not when it ends")
	assert_gt(_garage.lift_height(), 0.0, "and the lift has not come down yet")
	assert_true(_car.controls_locked, "the player cannot drive a car that is still coming down")
	_settle_lift()
	assert_false(_car.controls_locked, "the controls come back once the lift is down")
	assert_false(_car.freeze, "and the car is still live")


# Once the car is live the lift must STOP writing its transform: a per-frame position write would
# overrule the solver every step, which is exactly the bug — the wheels never get to resolve their
# own contact. Modelled by letting the stub "fall" and checking the garage leaves it where it is.
func test_the_lift_stops_driving_the_car_once_it_is_live() -> void:
	_drive_in()
	_garage.leave()
	var dropped := _car.global_position - Vector3(0.0, 0.35, 0.0)
	_car.global_position = dropped
	_garage.update_with(0.1, _car.global_position, 0.0)
	assert_almost_eq(_car.global_position.y, dropped.y, 0.0001,
		"the lift does not haul a live car back onto the deck")


# The stale-visual half of the bug: `settle_wheels_to_ground` translates each wheel Visual DOWN
# and nothing on the live path translates it back, so a released car renders its wheels sunk below
# where the solver has them — a tyre through the floor with the physics perfectly healthy. The
# droop must be cleared at the handover, and nothing may re-settle a live car afterwards.
func test_the_wheel_droop_is_cleared_when_the_car_goes_live() -> void:
	_drive_in()
	assert_gt(_car.settle_calls, 0, "the wheels are settled onto the deck while frozen")
	assert_eq(_car.clear_calls, 0, "and nothing has cleared them yet")
	_garage.leave()
	assert_eq(_car.clear_calls, 1, "the droop is cleared as the car goes live")
	var settled_at_handover := _car.settle_calls
	_settle_lift()
	assert_eq(_car.settle_calls, settled_at_handover,
		"a live car is never re-settled — settle_wheels_to_ground is for frozen props only")


# The car rides ABOVE the deck by its settled ride height. Seating the body origin ON the deck
# buries the wheels half a radius into it, and leaves the body interpenetrating the ground the
# instant physics resumes — which is what made the release pop. Measured as a difference between
# two ride heights, so no tuned value is pinned.
func test_the_car_is_seated_at_ride_height_above_the_deck() -> void:
	_drive_in()
	var on_the_deck := _car.global_position.y
	# Same car, same lift, one non-zero ride height: the body must sit exactly that much higher.
	_garage.leave()
	_settle_lift()
	_car.ride_height = 0.42
	_garage.update_with(0.1, _outside_point(), 0.0)
	_car.global_position = _inside_point()
	_garage.update_with(0.1, _inside_point(), 0.0)
	_settle_lift()
	assert_almost_eq(_car.global_position.y, on_the_deck + 0.42, 0.0001,
		"the body origin rides its settled ride height above the deck")


# --- The stop tube ------------------------------------------------------------------------
#
# The light column standing on the lift bay that says "park here". Its READY state is logic,
# not decoration — computed every frame whether or not visuals were built — so all of this
# runs headless. Nothing here pins the tube's authored radius, height or alpha.


# The tube marks the LIFT, not the middle of the building: the point the player is asked to
# park in and the point the car is actually seated on must be the same point, or the signal is
# a lie. Compared against the lift pose the garage seats the car at, not against a number.
func test_the_stop_tube_stands_on_the_lift_the_car_is_seated_on() -> void:
	_drive_in()
	var seated := _garage.to_local(_car.global_position)
	var tube := _garage.stop_tube_local_pos()
	assert_almost_eq(tube.x, seated.x, 0.01, "the tube is in the bay the lift is in")
	assert_almost_eq(tube.z, seated.z, 0.01, "the tube is at the lift's depth into the bay")


# The two states, and the transition that carries the meaning: outside the bay it waits, in
# the bay and slow enough to be taken it reads READY.
func test_the_stop_tube_reads_ready_only_in_the_spot_that_takes_the_car() -> void:
	_garage.update_with(0.1, _outside_point(), 0.0)
	assert_false(_garage.stop_tube_ready(), "parked outside the bay, the tube is still waiting")
	var fast := Config.data.overworld_garage_enter_max_kmh + 30.0
	_garage.update_with(0.1, _inside_point(), fast)
	assert_false(_garage.stop_tube_ready(),
		"sliding through the bay too fast to be taken is not the ready state")
	assert_false(_garage.is_inside(), "...and the garage has indeed not taken the car")
	_garage.update_with(0.1, _inside_point(), 0.0)
	assert_true(_garage.stop_tube_ready(), "stopped in the spot, the tube says so")


# Once the car is on the lift the column has done its job — leaving it lit would draw a
# "park here" marker through the car already parked there.
func test_the_stop_tube_retires_once_the_car_is_on_the_lift() -> void:
	_drive_in()
	assert_true(_garage.is_inside(), "the car is on the lift")
	assert_false(_garage.stop_tube_ready(), "the tube stops signalling once the lift has the car")


# Visuals off builds no column at all — the same discipline as the rest of the building — but
# the state above still runs, which is what makes those tests scene-free.
func test_the_stop_tube_is_visuals_only() -> void:
	assert_null(_garage.stop_tube_node(), "no tube node is built with visuals off")
	var g := OverworldGarage.new()
	add_child_autofree(g)
	g.setup({"world_pos": Vector3.ZERO, "visuals": true})
	var tube := g.stop_tube_node()
	assert_not_null(tube, "the column is built with visuals on")
	if tube != null:
		assert_almost_eq(tube.scale.x, g.stop_tube_radius(), 0.001,
			"the column is drawn at the radius it advertises, so what you see is where to park")
		assert_gt(tube.get_child_count(), 0, "the column has its mesh")
