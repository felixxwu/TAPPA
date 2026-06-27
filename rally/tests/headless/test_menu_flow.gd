extends GutTest
# Menus vertical slice (todo/menus.md, todo/diegetic-hq.md): the diegetic 3D HQ
# (camera stations: exterior title → garage → map table → car park) → run → podium
# loop, and the run-scene fielding that wires it to RallySession
# (todo/rally-event-flow.md). Runs against a throwaway Save profile.

const SceneHelpers = preload("res://tests/headless/scene_helpers.gd")
const TEST_PATH := "user://test_menu_flow_profile.json"

var _save: Node


func before_each() -> void:
	Config.reset()
	_save = get_node("/root/Save")
	_clean()
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.load_or_new()
	RallySession.auto_load_scenes = false
	if RallySession.is_active():
		RallySession.abandon()


func after_each() -> void:
	if RallySession.is_active():
		RallySession.abandon()
	RallySession.auto_load_scenes = true
	_clean()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	Config.reset()


func _clean() -> void:
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


func _label_texts(root: Node) -> String:
	var parts: Array[String] = []
	for label in root.find_children("*", "Label", true, false):
		parts.append((label as Label).text)
	return "\n".join(parts)


# --- HQ (diegetic 3D hub) ----------------------------------------------------

# The 3D map pin for a rally (each pin Node3D carries a "rally_id" meta).
func _pin_for(hq: Node3D, rally_id: String) -> Node3D:
	for pin in hq._pins:
		if String((pin as Node3D).get_meta("rally_id", "")) == rally_id:
			return pin
	return null


func test_hq_boots_to_the_exterior_title() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_eq(_save.profile["cars"].size(), 1, "the immortal starter is granted on the first HQ visit")
	assert_true(_save.profile["cars"][0]["immortal"], "the starter is immortal")
	# Boots to the exterior/title station: the title overlay is up, and the player's
	# whole collection is parked in the car park (just the starter so far).
	assert_eq(hq._view, hq.View.EXTERIOR, "HQ boots to the exterior title station")
	assert_true(hq._title_layer.visible, "the title overlay is shown")
	assert_false(hq._car_layer.visible, "the car-park overlay is hidden at the title")
	assert_eq(hq._cars.size(), 1, "the player's whole collection is parked on the title (the starter so far)")
	# The 3D map table is populated with one pin per rally.
	assert_eq(hq._pins.size(), RallyLibrary.RALLIES.size(), "one map pin per rally")


func test_hq_title_parks_all_owned_cars() -> void:
	# The title shows the whole collection, regardless of rally eligibility — grant
	# an AWD RS3 (which an RWD rally would exclude) and it's still parked.
	_save.grant_car("rs3", false)
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_eq(hq._cars.size(), 2, "the title parks every owned car (starter + RS3)")


func test_hq_start_flies_into_the_garage() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	assert_eq(hq._view, hq.View.GARAGE, "Start flies the camera into the garage")
	assert_true(hq._garage_layer.visible, "the garage overlay is shown")
	assert_false(hq._title_layer.visible, "the title overlay is hidden in the garage")


func test_hq_opening_the_table_shows_the_map() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	hq._enter_table()
	assert_eq(hq._view, hq.View.TABLE, "tapping the table drops the camera to the map view")
	assert_true(hq._table_layer.visible, "the map HUD is shown")
	assert_string_contains(hq._map_meter.text, "Progress to the Showdown", "the progress meter is shown")


func test_hq_map_locks_the_showdown_until_all_others_complete() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var showdown := _pin_for(hq, "the_showdown")
	assert_true(bool(showdown.get_meta("locked")),
		"the showdown pin is locked until every other rally is completed")
	assert_eq(showdown.find_children("*", "Area3D", true, false).size(), 0,
		"a locked pin is not pickable (no hit area)")
	var normal := _pin_for(hq, "shakedown")
	assert_false(bool(normal.get_meta("locked")), "a normal rally pin is unlocked")
	assert_gt(normal.find_children("*", "Area3D", true, false).size(), 0, "an unlocked pin is pickable")


func test_hq_pins_stars_reflect_best_placement() -> void:
	# A 1st-place best earns 3 stars; a 3rd-place best earns 1.
	_save.complete_rally("shakedown", 60000, 1)
	_save.complete_rally("coastal_sprint", 90000, 3)
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_eq(hq._stars_for("shakedown"), 3, "1st place earns 3 stars")
	assert_eq(hq._stars_for("coastal_sprint"), 1, "3rd place earns 1 star")
	assert_eq(hq._stars_for("rwd_masters"), 0, "an unplayed rally earns 0 stars")


func test_hq_tapping_a_pin_opens_its_detail() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	hq._enter_table()
	hq._on_rally_pin("rwd_masters")
	assert_true(hq._detail_open, "tapping a pin opens the rally detail")
	assert_true(hq._detail_layer.visible, "the detail overlay is shown")
	assert_false(hq._table_layer.visible, "the map HUD is hidden behind the detail")
	assert_string_contains(hq._detail_title.text, "RWD Masters", "the detail names the rally")
	assert_string_contains(hq._detail_body.text, "RWD cars", "the detail spells out the eligibility")


func test_hq_table_drag_pans_and_clamps() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_table()
	assert_eq(hq._table_pan, Vector3.ZERO, "the map re-centres when opened")
	hq._pan_table(Vector2(-100, -50))
	assert_gt(hq._table_pan.x, 0.0, "dragging pans the map view")
	# A huge drag clamps to the map extents (half the plane each way).
	hq._pan_table(Vector2(-100000, -100000))
	var cfg: GameConfig = Config.data
	assert_almost_eq(hq._table_pan.x, cfg.hq_map_plane_size.x * 0.5, 0.001, "pan clamps to the map's far X edge")
	assert_almost_eq(hq._table_pan.z, cfg.hq_map_plane_size.y * 0.5, 0.001, "pan clamps to the map's far Z edge")


func test_hq_dragging_the_map_does_not_open_a_rally() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_table()
	# Press → move → the press becomes a pan-drag, not a tap.
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	hq._table_pan_input(press)
	var move := InputEventMouseMotion.new()
	move.relative = Vector2(40, 0)
	hq._table_pan_input(move)
	assert_true(hq._table_dragged, "a drag past the threshold is detected")
	# A release over a pin while dragging must NOT open that rally.
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	hq._on_pin_input(null, release, Vector3.ZERO, Vector3.ZERO, 0, "shakedown")
	assert_false(hq._detail_open, "dragging the map does not open the pin under the finger")
	# A clean tap (no drag) on a pin DOES open it (selection fires on release).
	hq._table_dragged = false
	hq._on_pin_input(null, release, Vector3.ZERO, Vector3.ZERO, 0, "shakedown")
	assert_true(hq._detail_open, "a tap with no drag opens the rally detail")


func test_hq_choosing_a_rally_filters_to_eligible_cars() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	# Own an AWD RS3 alongside the RWD starter, pick the RWD-only rally and enter: only
	# the eligible (RWD) car is parked, the AWD car is filtered out.
	_save.grant_car("rs3", false)
	hq._on_rally_pin("rwd_masters")
	hq._enter_car_screen()
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.CARPARK, "Enter Rally flies out to the car park")
	assert_true(hq._car_layer.visible, "the car-park overlay is shown")
	assert_false(hq._detail_layer.visible, "the detail overlay is hidden in the car park")
	assert_eq(hq._cars.size(), 1, "only the eligible (RWD) car is parked")
	assert_eq(hq._cars[0].current_car_name(), "Mazda MX-5", "the AWD RS3 is filtered out of an RWD-only rally")
	assert_string_contains(hq._rally_banner.text, "RWD cars", "the banner spells out the rally restriction")


func test_hq_open_rally_parks_the_whole_lineup_with_per_car_meshes() -> void:
	# Two box-bodied cars of different sizes must keep their OWN body meshes — the
	# car scene shares mesh sub-resources across instances, so without per-instance
	# duplication both would render at whichever was applied last.
	_save.grant_car("rs3", false)       # body 1.55 x 0.60 x 4.00
	_save.grant_car("mustang", false)   # body 1.92 x 0.55 x 4.78
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_rally_pin("shakedown")  # open-class: all three are eligible
	hq._enter_car_screen()
	await get_tree().process_frame
	assert_eq(hq._cars.size(), 3, "starter + the two granted cars are all eligible + parked")
	var size_by_name := {}
	for car in hq._cars:
		var chassis := car.get_node("Chassis") as MeshInstance3D
		size_by_name[car.current_car_name()] = (chassis.mesh as BoxMesh).size
	assert_eq(size_by_name["Audi RS3"], Vector3(1.55, 0.6, 4.0), "the RS3 keeps its own body size")
	assert_eq(size_by_name["Ford Mustang GT"], Vector3(1.92, 0.55, 4.78), "the Mustang keeps its own body size")
	assert_ne(size_by_name["Audi RS3"], size_by_name["Ford Mustang GT"],
		"parked cars do NOT share one mesh (per-instance duplication)")


func test_hq_parked_cars_settle_live_then_freeze() -> void:
	# Parked cars drop in LIVE (so they settle onto their suspension), then freeze at
	# the settled pose so a full car park costs nothing to keep parked.
	_save.grant_car("rs3", false)
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_rally_pin("shakedown")
	hq._enter_car_screen()
	await get_tree().process_frame
	assert_gt(hq._cars.size(), 0, "the lineup is parked")
	for car in hq._cars:
		assert_false(car.freeze, "parked cars start live so they settle on their suspension")
	# The settle timer freezes them; drive that directly (deterministic, no waiting).
	hq._freeze_lineup(hq._settle_generation)
	for car in hq._cars:
		assert_true(car.freeze, "settled cars are frozen at their pose")
	# A stale freeze (old generation) must not touch a freshly-rebuilt lineup.
	hq._enter_car_screen()
	await get_tree().process_frame
	hq._freeze_lineup(hq._settle_generation - 1)
	for car in hq._cars:
		assert_false(car.freeze, "a superseded freeze leaves the new lineup live")


func test_hq_cycling_focus_changes_the_focused_and_selected_car() -> void:
	_save.grant_car("rs3", false)
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_rally_pin("shakedown")  # open-class: both cars eligible
	hq._enter_car_screen()
	await get_tree().process_frame
	assert_eq(hq._cars.size(), 2, "both eligible cars are parked")
	assert_eq(hq._selected_instance_id, int(hq._eligible[0]["instance_id"]), "the first car is selected on entry")
	hq._cycle_focus(1)
	assert_eq(hq._focus, 1, "cycling right advances the focus")
	assert_eq(hq._selected_instance_id, int(hq._eligible[1]["instance_id"]), "the newly focused car is selected")
	hq._focus = 0
	hq._cycle_focus(-1)
	assert_eq(hq._focus, 1, "cycling left from the first car wraps to the last")


func test_hq_back_steps_carpark_to_table_to_garage() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	hq._enter_table()
	hq._on_rally_pin("shakedown")
	hq._enter_car_screen()
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.CARPARK, "in the car park after entering")
	# Back from the car park returns to the map table, clearing the lineup.
	hq._car_back()
	assert_eq(hq._view, hq.View.TABLE, "Back from the car park returns to the map table")
	assert_eq(hq._cars.size(), 0, "the parked lineup is cleared when leaving the car park")
	assert_true(hq._table_layer.visible, "the map HUD is shown again")
	# Back from the table returns to the garage.
	hq._go_to(hq.View.GARAGE)
	assert_eq(hq._view, hq.View.GARAGE, "Back from the table returns to the garage")


func test_hq_choose_rally_then_car_then_start_launches_a_session() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	# Pick a rally → enter, then Start with the focused car. auto_load_scenes is off,
	# so no scene change; start_rally derives targets.
	hq._on_rally_pin("shakedown")
	hq._enter_car_screen()
	await get_tree().process_frame
	assert_false(hq._start_button.disabled, "Start is enabled once a rally + eligible car are chosen")
	# Start shows the loading overlay first, then hands off after a frame (so the
	# overlay paints before the heavy target derivation) — await the whole thing.
	await hq._on_start_pressed()
	assert_gt(hq.find_children("*", "LoadingScreen", true, false).size(), 0,
		"a loading overlay is shown immediately on Start")
	assert_true(RallySession.is_active(), "Start hands off to an active RallySession")
	assert_eq(RallySession.rally_id(), "shakedown", "the chosen rally is running")


func test_standings_interstitial_renders_the_leaderboard() -> void:
	# After a non-final event the rally pauses on the standings; the scene shows the
	# cumulative leaderboard so far. (auto_load_scenes is off, so no scene loads.)
	var owned: Dictionary = _save.grant_car("rs3", false)
	RallySession.start_rally(RallyLibrary.by_id("coastal_sprint"), owned, [60000, 60000, 60000])
	RallySession._opponent_field = [
		{"name": "Quick", "event_times_ms": [40000, 40000, 40000], "dnf": false, "combined_ms": 120000},
		{"name": "Slow", "event_times_ms": [80000, 80000, 80000], "dnf": false, "combined_ms": 240000},
	]
	RallySession.report_event_result(50000)  # complete event 1 -> STANDINGS
	var sc: Control = load("res://standings.tscn").instantiate()
	add_child_autofree(sc)
	await get_tree().process_frame
	var text := _label_texts(sc)
	assert_string_contains(text, "after event 1", "the interstitial headers the event just finished")
	assert_string_contains(text, "Coastal Sprint", "it names the rally")
	assert_string_contains(text, "Quick", "the opponent field is listed")
	assert_string_contains(text, "Slow", "the whole field is shown")


func test_podium_shows_the_finish_summary() -> void:
	RallySession._last_result = {"placed": 2, "completed": true, "combined_ms": 65000, "dnf": false}
	var pod: Control = load("res://podium.tscn").instantiate()
	add_child_autofree(pod)
	await get_tree().process_frame
	var text := _label_texts(pod)
	assert_string_contains(text, "P2", "podium shows the placement")
	assert_string_contains(text, "WON", "a top-3 finish reads as a win")


func test_podium_reveals_reward_and_standings() -> void:
	# A top-3 win that grants the Porsche 911 plus two upgrades, with a small field.
	RallySession._last_result = {
		"placed": 1, "completed": true, "combined_ms": 60000, "dnf": false,
		"rally_name": "Coastal Sprint", "showdown_won": false,
		"car_reward": "porsche911", "car_reward_is_new": true,
		"upgrades": ["engine_stage1", "engine_stage1", "aero_kit"],
		"standings": [
			{"name": "You", "combined_ms": 60000, "dnf": false, "is_player": true, "placed": 1},
			{"name": "Rival 1", "combined_ms": 70000, "dnf": false, "is_player": false, "placed": 2},
			{"name": "Rival 2", "combined_ms": -1, "dnf": true, "is_player": false, "placed": -1},
		],
	}
	var pod: Control = load("res://podium.tscn").instantiate()
	add_child_autofree(pod)
	await get_tree().process_frame
	var text := _label_texts(pod)
	assert_string_contains(text, "Porsche 911", "the won car is revealed by name")
	assert_string_contains(text, "NEW", "an un-owned car reward is flagged NEW")
	assert_string_contains(text, "Stage 1 Engine Kit x2", "duplicate upgrades are aggregated with a count")
	assert_string_contains(text, "Aero Kit", "the singular upgrade is listed too")
	assert_string_contains(text, "Rival 1", "the standings list the opponent field")
	assert_string_contains(text, "WRECKED", "a DNF opponent reads as WRECKED in the standings")


func test_run_scene_fields_the_bound_session_car() -> void:
	var owned: Dictionary = _save.grant_car("rs3", false)
	var id := int(owned["instance_id"])
	RallySession.start_rally(RallyLibrary.by_id("coastal_sprint"), owned, [60000, 60000, 60000])
	# Boot the run scene with a session active: world.gd fields the OwnedCar.
	SceneHelpers.minimal_world()
	var scene: Node3D = load("res://main.tscn").instantiate()
	add_child_autofree(scene)
	await get_tree().process_frame
	var car: VehicleBody3D = scene.get_node("Car")
	assert_eq(car.damage.instance_id, id, "the car's damage model is bound to the fielded instance")
	assert_false(car.damage.immortal, "a non-immortal owned car")
	assert_eq(car.current_car_name(), "Audi RS3", "the owned car's model is fielded, not the default")
