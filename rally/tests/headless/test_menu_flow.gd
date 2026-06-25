extends GutTest
# Menus vertical slice (todo/menus.md): the placeholder HQ → run → podium loop and
# the run-scene fielding that wires it to RallySession (todo/rally-event-flow.md).
# Runs against a throwaway Save profile.

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


func _map_pins(hq: Node3D) -> Array:
	return hq._map_area.find_children("*", "Button", true, false)


func test_hq_boots_to_the_world_map() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_eq(_save.profile["cars"].size(), 1, "the immortal starter is granted on the first HQ visit")
	assert_true(_save.profile["cars"][0]["immortal"], "the starter is immortal")
	# The first screen is the world map: pins are shown, the car screen is hidden,
	# and no cars are parked until a rally is chosen.
	assert_eq(hq._screen, hq.Screen.MAP, "HQ boots to the world-map screen")
	assert_true(hq._map_layer.visible, "the map overlay is shown")
	assert_false(hq._car_layer.visible, "the car-select overlay is hidden on the map")
	assert_eq(_map_pins(hq).size(), RallyLibrary.RALLIES.size(), "one pin per rally")
	assert_eq(hq._cars.size(), 0, "no cars are parked until a rally is chosen")


func test_hq_map_locks_the_showdown_until_all_others_complete() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var showdown_locked := false
	for pin in _map_pins(hq):
		if (pin as Button).text.contains("Showdown"):
			showdown_locked = (pin as Button).disabled
	assert_true(showdown_locked, "the showdown pin is locked until every other rally is completed")
	assert_string_contains(hq._map_meter.text, "Progress to the Showdown", "the progress meter is shown")


func test_hq_choosing_a_rally_filters_to_eligible_cars() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	# Own an AWD RS3 alongside the RWD starter, then pick the RWD-only rally: only the
	# eligible (RWD) car is parked on the car screen, and the AWD car is filtered out.
	_save.grant_car("rs3", false)
	hq._on_rally_pin("rwd_masters")
	await get_tree().process_frame
	assert_eq(hq._screen, hq.Screen.CARS, "picking a rally moves to the car-select screen")
	assert_false(hq._map_layer.visible, "the map overlay is hidden on the car screen")
	assert_true(hq._car_layer.visible, "the car-select overlay is shown")
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


func test_hq_cycling_focus_changes_the_focused_and_selected_car() -> void:
	_save.grant_car("rs3", false)
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_rally_pin("shakedown")  # open-class: both cars eligible
	await get_tree().process_frame
	assert_eq(hq._cars.size(), 2, "both eligible cars are parked")
	assert_eq(hq._selected_instance_id, int(hq._eligible[0]["instance_id"]), "the first car is selected on entry")
	hq._cycle_focus(1)
	assert_eq(hq._focus, 1, "cycling right advances the focus")
	assert_eq(hq._selected_instance_id, int(hq._eligible[1]["instance_id"]), "the newly focused car is selected")
	hq._focus = 0
	hq._cycle_focus(-1)
	assert_eq(hq._focus, 1, "cycling left from the first car wraps to the last")


func test_hq_back_returns_to_the_map() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_rally_pin("shakedown")
	await get_tree().process_frame
	assert_eq(hq._screen, hq.Screen.CARS, "on the car screen after picking a rally")
	hq._show_map()
	assert_eq(hq._screen, hq.Screen.MAP, "Back returns to the world map")
	assert_true(hq._map_layer.visible, "the map is shown again")
	assert_eq(hq._cars.size(), 0, "the parked lineup is cleared when returning to the map")


func test_hq_choose_rally_then_car_then_start_launches_a_session() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	# Pick a rally on the map, then Start with the focused (auto-selected) car.
	# auto_load_scenes is off, so no scene change; start_rally derives targets.
	hq._on_rally_pin("shakedown")
	await get_tree().process_frame
	assert_false(hq._start_button.disabled, "Start is enabled once a rally + eligible car are chosen")
	hq._on_start_pressed()
	assert_true(RallySession.is_active(), "Start hands off to an active RallySession")
	assert_eq(RallySession.rally_id(), "shakedown", "the chosen rally is running")


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
	assert_string_contains(text, "Stage 1 Engine Kit ×2", "duplicate upgrades are aggregated with a count")
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
