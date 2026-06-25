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


func test_hq_grants_starter_and_parks_the_focused_car_and_rallies() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_eq(_save.profile["cars"].size(), 1, "the immortal starter is granted on the first HQ visit")
	assert_true(_save.profile["cars"][0]["immortal"], "the starter is immortal")
	assert_true(_save.profile["starter_picked"], "starter_picked recorded")
	# The car park spawns one parked 3D prop per owned car (here just the starter).
	assert_eq(hq._cars.size(), 1, "one parked car per owned instance")
	assert_eq(hq._cars[0].current_car_name(), "Mazda MX-5", "the starter is parked + focused")
	assert_true(hq._cars[0].freeze, "parked cars are physics-frozen props")
	assert_eq(hq._selected_instance_id, int(_save.profile["cars"][0]["instance_id"]),
		"the focused car is the selected car")
	assert_not_null(hq._camera, "a menu camera frames the lot")
	assert_gt(hq._rallies_box.get_child_count(), 0, "rallies the focused car can enter are listed")


func test_hq_parks_the_whole_lineup_with_per_car_meshes() -> void:
	# Two box-bodied cars of different sizes must keep their OWN body meshes — the
	# car scene shares mesh sub-resources across instances, so without per-instance
	# duplication both would render at whichever was applied last.
	_save.grant_car("rs3", false)       # body 1.55 x 0.60 x 4.00
	_save.grant_car("mustang", false)   # body 1.92 x 0.55 x 4.78
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_eq(hq._cars.size(), 3, "starter + the two granted cars are all parked")
	var size_by_name := {}
	for car in hq._cars:
		var chassis := car.get_node("Chassis") as MeshInstance3D
		size_by_name[car.current_car_name()] = (chassis.mesh as BoxMesh).size
	assert_eq(size_by_name["Audi RS3"], Vector3(1.55, 0.6, 4.0), "the RS3 keeps its own body size")
	assert_eq(size_by_name["Ford Mustang GT"], Vector3(1.92, 0.55, 4.78), "the Mustang keeps its own body size")
	assert_ne(size_by_name["Audi RS3"], size_by_name["Ford Mustang GT"],
		"parked cars do NOT share one mesh (per-instance duplication)")


func test_hq_cycling_focus_changes_the_focused_and_selected_car() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	# Own a second car, then focus it: the lot rebuilds and selection follows.
	var rs3: Dictionary = _save.grant_car("rs3", false)
	hq.focus_instance(int(rs3["instance_id"]))
	await get_tree().process_frame
	assert_eq(hq._cars.size(), 2, "the newly granted car is parked when focused")
	assert_eq(hq._cars[hq._focus].current_car_name(), "Audi RS3", "the focused slot is the RS3")
	assert_eq(hq._selected_instance_id, int(rs3["instance_id"]), "focusing a car selects it")
	# Wrap left from the first car returns to the last in the 2-car lot.
	hq._focus = 0
	hq._cycle_focus(-1)
	await get_tree().process_frame
	assert_eq(hq._focus, 1, "cycling left from the first car wraps to the last")


func test_hq_start_button_launches_a_session() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	# Select the starter + the shakedown, then press Start (auto_load_scenes is off,
	# so no scene change; start_rally derives targets from the seeded tracks).
	hq._selected_instance_id = int(_save.profile["cars"][0]["instance_id"])
	hq._selected_rally_id = "shakedown"
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


func test_hq_shows_locked_rallies_with_their_restriction() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	# Field the AWD RS3 (German hatch): RWD Masters + the JP-only Rising Sun should
	# both show as locked with a reason, so the unlock path is visible.
	var rs3: Dictionary = _save.grant_car("rs3", false)
	hq.focus_instance(int(rs3["instance_id"]))
	await get_tree().process_frame
	var locked: Array[String] = []
	for btn in hq._rallies_box.find_children("*", "Button", true, false):
		if (btn as Button).disabled:
			locked.append((btn as Button).text)
	var blob := "\n".join(locked)
	assert_string_contains(blob, "RWD Masters", "the RWD-only rally is shown locked, not hidden")
	assert_string_contains(blob, "RWD cars", "the lock spells out the drivetrain restriction")
	assert_string_contains(blob, "Showdown", "the showdown is shown locked until all rallies are done")
	# And the progress meter is present.
	assert_string_contains(_label_texts(hq._rallies_box), "Progress to the Showdown",
		"the showdown progress meter is shown")


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
