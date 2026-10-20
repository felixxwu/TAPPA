extends GutTest
# The persistent free-roam world (features/world-session.md): WorldSession's state and its round
# trips through the profile, free roam resuming from it, and the world pages (map + stats) with
# their keyboard/gamepad navigation.

const TEST_PATH := "user://test_world_session_profile.json"

var _save: Node


func before_each() -> void:
	_save = get_node("/root/Save")
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.reset_new_game() if _save.has_method("reset_new_game") else _save.load_or_new()
	_save.profile = _save._default_profile()
	CarFixtures.install()


func after_each() -> void:
	get_tree().paused = false
	CarFixtures.restore()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


func _any_car() -> String:
	return String(CarLibrary.all()[0]["id"])


func test_a_fresh_profile_has_no_world() -> void:
	assert_false(WorldSession.has_world())


func test_a_new_world_owns_its_starter_car_and_starts_at_spawn() -> void:
	WorldSession.new_world(42, _any_car())
	assert_true(WorldSession.has_world())
	assert_eq(WorldSession.world_seed(), 42)
	assert_eq(String(WorldSession.active_car().get("model_id", "")), _any_car())
	assert_eq(WorldSession.lit_sites(), [0])
	assert_eq(WorldSession.last_site(), 0)
	assert_eq(WorldSession.pose(), [])


func test_a_new_world_replaces_the_old_one_and_its_cars() -> void:
	WorldSession.new_world(1, _any_car())
	WorldSession.light(5)
	var second := String(CarLibrary.all()[1]["id"])
	WorldSession.new_world(2, second)
	assert_eq(WorldSession.world_seed(), 2)
	assert_eq(WorldSession.lit_sites(), [0])
	assert_eq((_save.profile[_save.KEY_CARS] as Array).size(), 1)
	assert_eq(String(WorldSession.active_car()["model_id"]), second)


func test_the_cars_pose_round_trips_facing_the_same_way() -> void:
	WorldSession.new_world(1, _any_car())
	var fwd := Vector3(1, 0, 1).normalized()
	var xform := Transform3D(Basis.looking_at(fwd, Vector3.UP), Vector3(10, 2, -30))
	WorldSession.save_pose(xform)
	var back: Transform3D = WorldSession.pose_transform()
	assert_almost_eq(back.origin, xform.origin, Vector3.ONE * 1e-4)
	assert_almost_eq(-back.basis.z, fwd, Vector3.ONE * 1e-4)


func test_the_cars_condition_round_trips() -> void:
	WorldSession.new_world(1, _any_car())
	var d := DamageModel.new()
	d.field(1000.0, 400.0)
	d.cooling_broken = true
	d.engine_temp = 117.0
	d.wheel_toe["WheelRR"] = 0.02
	WorldSession.save_car_state(d)
	var e := DamageModel.new()
	e.field(1000.0, 1000.0)
	WorldSession.restore_car_state(e)
	assert_eq(e.hp, 400.0)
	assert_true(e.cooling_broken)
	assert_eq(e.engine_temp, 117.0)
	assert_almost_eq(float(e.wheel_toe["WheelRR"]), 0.02, 1e-6)


func test_lighting_a_rest_stop_is_remembered_once_and_counted_once() -> void:
	WorldSession.new_world(1, _any_car())
	WorldSession.light(3)
	WorldSession.light(3)
	assert_eq(WorldSession.lit_sites(), [0, 3])
	assert_eq(_save.lifetime_stat(LifetimeStats.REST_STOPS_LIT), 1)


func test_the_map_remembers_driven_cells_and_the_furthest_ring() -> void:
	WorldSession.new_world(1, _any_car())
	assert_true(WorldSession.mark_driven(5.0, 5.0))
	assert_false(WorldSession.mark_driven(6.0, 6.0), "same cell")
	assert_true(WorldSession.has_driven(1.0, 1.0))
	assert_false(WorldSession.has_driven(500.0, 500.0))
	WorldSession.reach_ring(2)
	WorldSession.reach_ring(1)
	assert_eq(WorldSession.max_ring(), 2, "a high-water mark")


func test_the_world_survives_a_save_and_reload() -> void:
	WorldSession.new_world(77, _any_car())
	WorldSession.light(9)
	_save.save_now()
	_save.profile = {}
	_save.load_or_new()
	assert_true(WorldSession.has_world())
	assert_eq(WorldSession.world_seed(), 77)
	assert_eq(WorldSession.lit_sites(), [0, 9])


func test_a_pre_free_roam_profile_is_refused() -> void:
	var old: Dictionary = _save._default_profile()
	old["schema_version"] = 7
	old[_save.KEY_WORLD] = {"seed": 5}
	assert_true(_save._migrate(old).is_empty())


# --- free roam resuming from the session, and the world pages ------------------------------------

func _boot_free_roam() -> Node3D:
	var scene: Node3D = load("res://free_roam.tscn").instantiate()
	var s := FreeRoamSettings.new()
	s.island_radius_m = 3000.0
	s.near_radius = 1
	s.far_radius = 3
	(scene.get_node("Terrain") as TerrainStreamer).settings = s
	add_child_autofree(scene)
	await get_tree().physics_frame
	return scene


func test_free_roam_resumes_the_saved_world() -> void:
	WorldSession.new_world(7, _any_car())
	WorldSession.light(1)
	WorldSession.set_last_site(1)
	WorldSession.save_pose(Transform3D(Basis.IDENTITY, Vector3(40, 0, 25)))
	var scene := await _boot_free_roam()
	var st: TerrainStreamer = scene.get_node("Terrain")
	var rest: RestStops = scene.get_node("RestStops")
	assert_eq(st.settings.world_seed, 7, "the island is the saved world's")
	assert_true(rest.is_lit(1))
	assert_eq(rest.last_site, 1)
	var car: Node3D = scene.get_node("Car")
	assert_lt(Vector2(car.global_position.x, car.global_position.z).distance_to(Vector2(40, 25)), 2.0, "the car is where it was left")


func test_the_map_is_the_travel_picker_at_a_rest_stop() -> void:
	WorldSession.new_world(7, _any_car())
	var scene := await _boot_free_roam()
	var rest: RestStops = scene.get_node("RestStops")
	var pages: WorldPages = scene.get_node("WorldPages")
	var rests := (scene.get_node("Terrain") as TerrainStreamer).sites.of_kind(RoadSites.Kind.REST)
	rest.lit_sites[rests[1]] = true
	rest.lit_sites[rests[2]] = true
	var closed := [false]
	pages.show_map(func() -> void: closed[0] = true, 0)
	await get_tree().process_frame
	await get_tree().process_frame
	var vp := pages.get_viewport()
	var b := pages.action_buttons()  # back, prev, next, travel
	assert_eq(vp.gui_get_focus_owner(), b[3], "Travel has the cursor")
	var nav := MenuNav.of(pages._page)
	var e := InputEventAction.new()
	e.action = "menu_left"
	e.pressed = true
	nav._unhandled_input(e)
	assert_eq(vp.gui_get_focus_owner(), b[2], "left walks along the action row")
	var first := pages.selected_target()
	b[2].pressed.emit()
	assert_ne(pages.selected_target(), first, "Next picks another lit rest stop")
	var target := pages.selected_target()
	b[3].pressed.emit()
	assert_true(closed[0])
	assert_eq(rest.last_site, target, "Travel went there")


func test_the_pause_menu_opens_the_map_and_stats_and_comes_back() -> void:
	WorldSession.new_world(7, _any_car())
	var scene := await _boot_free_roam()
	var pause: PauseMenu = scene.get_node("PauseMenu")
	var pages: WorldPages = scene.get_node("WorldPages")
	pause.open()
	assert_true(CardUI.pick(pause.cards(), "Map"))
	assert_true(pages.is_open())
	assert_false(pause.is_open(), "the map covers the pause menu")
	assert_true(get_tree().paused)
	var e := InputEventAction.new()
	e.action = "ui_cancel"
	e.pressed = true
	MenuNav.of(pages._page)._unhandled_input(e)
	assert_false(pages.is_open())
	assert_true(pause.is_open(), "back returns to the pause menu")
	assert_eq(CardUI.titles(pause.cards())[pause.cards().selected_index()], "Map", "the cursor is back on Map")
	assert_true(CardUI.pick(pause.cards(), "Stats"))
	assert_true(pages.is_open())
	assert_eq(pages.cards().card_count(), WorldPages.STATS_SHOWN.size() + 1, "a card per stat, and the rings reached")
	pages.close()
	pause.resume()
