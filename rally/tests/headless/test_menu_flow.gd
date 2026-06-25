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


func test_hq_grants_starter_and_lists_cars_and_rallies() -> void:
	var hq: Control = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_eq(_save.profile["cars"].size(), 1, "the immortal starter is granted on the first HQ visit")
	assert_true(_save.profile["cars"][0]["immortal"], "the starter is immortal")
	assert_true(_save.profile["starter_picked"], "starter_picked recorded")
	assert_gt(hq._cars_box.get_child_count(), 0, "owned cars are listed")
	assert_gt(hq._rallies_box.get_child_count(), 0, "rallies the car can enter are listed")


func test_hq_start_button_launches_a_session() -> void:
	var hq: Control = load("res://hq.tscn").instantiate()
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
