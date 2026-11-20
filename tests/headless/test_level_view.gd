extends GutTest
# The level-editor save driven in place of free roam (features/level-editor.md): unpacking the lab's
# save format, the ground built around the road, the trees, and the dev toggle's redirect.
# Every level here is synthetic; nothing reads the shipped Hafren save.

var _toggle: bool


func before_each() -> void:
	_toggle = Config.data.dev_level_instead_of_free_roam


func after_each() -> void:
	Config.data.dev_level_instead_of_free_roam = _toggle


# A straight road along x through the middle of a flat square, with a hill grid that's flat at `ground`.
func _level(ground := 0.0) -> Dictionary:
	var hm: Array = []
	hm.resize(201 * 201)
	hm.fill(ground)
	return {"road": [{"x": -100.0, "z": 0.0, "w": 3.0, "m": null, "tension": 1.0},
			{"x": 100.0, "z": 0.0, "w": 3.0, "m": null, "tension": 1.0}],
		"trees": [{"x": 0.0, "z": 50.0, "rot": 0.0, "sx": 1.0, "sy": 1.0, "kind": "tree.png"},
			{"x": 10.0, "z": 50.0, "rot": 90.0, "sx": 1.0, "sy": 2.0, "kind": "tree.png"}],
		"heightmap": hm}


func _built(level: Dictionary) -> LevelView:
	var view := LevelView.new()
	view.load_level(level)
	autofree(view)
	return view


func test_the_toggle_sends_world_entry_to_the_level() -> void:
	Config.data.dev_level_instead_of_free_roam = true
	Scenes.change_to(get_tree(), Scenes.FREE_ROAM)
	assert_eq(Scenes.last_blocked_path, Scenes.LEVEL_VIEW)
	Config.data.dev_level_instead_of_free_roam = false
	Scenes.change_to(get_tree(), Scenes.FREE_ROAM)
	assert_eq(Scenes.last_blocked_path, Scenes.FREE_ROAM)


func test_the_level_scene_arms_its_pause_menu() -> void:
	var path := "user://test_level_view_level.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(_level()))
	f.close()
	var world: Node = (load(Scenes.LEVEL_VIEW) as PackedScene).instantiate()
	world.get_node("Level").level_path = path
	add_child_autofree(world)
	await wait_for_signal(world.get_node("Level").loaded, 30.0)
	assert_true(world.get_node("PauseMenu").is_armed(), "Esc / Start open the pause menu")
	assert_eq(world.get_node("Car")._car_index, CarLibrary.index_of(Config.data.dev_level_car_id), "drives the level's own car")
	var map: LevelMap = world.get_node("Level").map
	var m := InputEventKey.new()
	m.physical_keycode = KEY_M
	m.pressed = true
	map._input(m)
	assert_true(map.visible and get_tree().paused, "M opens the map and pauses")
	assert_almost_eq(map.to_world(map.to_screen(Vector2(30, -20))), Vector2(30, -20), Vector2.ONE * 0.01)
	assert_almost_eq(map.snap_to_road(Vector2(40, 25)).y, 0.0, 0.5, "a spot snaps onto the road")
	await map.teleport(map.snap_to_road(Vector2(60, 25)))
	var car := world.get_node("Car") as Node3D
	assert_almost_eq(Vector2(car.global_position.x, car.global_position.z), Vector2(60, 0), Vector2.ONE * 1.0, "teleported onto the road")
	assert_false(map.visible or get_tree().paused, "teleporting closes the map and resumes")
	var start_car := Config.data.dev_level_car_id
	var pause: PauseMenu = world.get_node("PauseMenu")
	var level: LevelView = world.get_node("Level")
	var dmg: DamageModel = world.get_node("Car").damage
	assert_false(dmg.invulnerable, "the level's car takes damage")
	dmg.apply_loss(dmg.max_hp * 0.5)
	pause.open()
	CardUI.pick(pause.cards(), "Repair")
	assert_eq(dmg.hp, dmg.max_hp, "the pause menu's Repair fixes the car")
	assert_true(pause.is_open(), "and returns to the pause menu")
	CardUI.pick(pause.cards(), "Shop")
	assert_not_null(level.shop, "the pause menu's Shop opens the shop")
	assert_true(level.shop.pick("Upgrades"))
	var parts: Array = LevelView.owned["parts"]
	var i := parts.find_custom(LootRules.is_upgrade)
	assert_true(level.shop.pick(LootRules.card_text(parts[i])[0]), "every part is unlocked and free to switch on")
	assert_true(LootRules.is_on(LevelView.owned["parts"][i]))
	var back := InputEventAction.new()
	back.action = "ui_cancel"
	back.pressed = true
	MenuNav.of(level.shop._page)._unhandled_input(back)
	assert_eq(level.shop.view, RestStopPage.View.SHOP, "Back steps out to the shop's cards")
	MenuNav.of(level.shop._page)._unhandled_input(back)
	assert_null(level.shop, "and then closes the shop")
	assert_eq(Scenes.last_blocked_path, Scenes.LEVEL_VIEW, "reloading the level to fit the parts")
	LevelView._next_pose = null
	LevelView.owned = {}
	Scenes.last_blocked_path = ""
	pause.return_from_extra()
	CardUI.pick(pause.cards(), "Garage")
	assert_not_null(level.garage, "the pause menu's Garage opens the car cards")
	var other := 1 if CarLibrary.all()[0]["id"] == start_car else 0
	CardUI.pick(level.garage.find_children("*", "CardCarousel", true, false)[0], String(CarLibrary.all()[other]["name"]))
	assert_eq(Config.data.dev_level_car_id, String(CarLibrary.all()[other]["id"]), "picking a car makes it the level's car")
	assert_eq(Scenes.last_blocked_path, Scenes.LEVEL_VIEW, "and reloads the level to field it")
	assert_almost_eq(LevelView._next_pose.origin, car.global_position, Vector3.ONE * 0.01, "standing where the old car was")
	LevelView._next_pose = null
	Config.data.dev_level_car_id = start_car
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_apply_weather_spawns_and_clears_particles() -> void:
	var view := _built(_level())
	var cam := Camera3D.new()
	cam.name = "ChaseCamera"
	var host := Node3D.new()
	host.add_child(cam)
	host.add_child(view)
	add_child_autofree(host)
	var before := Config.data.weather
	for entry in WeatherLibrary.CONDITIONS:
		view.apply_weather(String(entry["id"]))
		assert_eq(Config.data.weather, String(entry["id"]))
		await get_tree().process_frame
		assert_eq(cam.get_children().any(func(n: Node) -> bool: return n is WeatherField),
			String(entry.get("particles", "")) != "")
	view.apply_weather(WeatherLibrary.DEFAULT_ID)
	WindSway.reset()
	Config.data.weather = before


func _node(x: float, z: float, w := 3.0) -> Dictionary:
	return {"x": x, "z": z, "w": w, "m": null, "tension": 1.0}


func _network() -> Dictionary:
	return {"roads": [[_node(-100.0, 0.0), _node(0.0, 0.0), _node(100.0, 0.0)],
		[_node(0.0, 0.4, 2.0), _node(0.0, 60.0, 2.0)],
		[_node(-100.0, 200.0), _node(100.0, 200.0)]]}


func test_the_level_answers_road_queries_through_its_data() -> void:
	var view := _built(_network())
	assert_gt(view.surface_at(0.0, 30.0).x, 0.9, "on the side road")
	assert_almost_eq(view.spawn_pose().origin.x, -100.0, 0.01)
	var pose := view.road_pose(Vector2(20.0, 45.0), Vector3(0.0, 0.0, 1.0))
	assert_almost_eq(pose.origin.x, 0.0, 0.5, "recovery lands on the nearest road")


func test_off_the_road_for_the_timeout_resets_the_car() -> void:
	var view := _built(_level())
	assert_false(view.is_off_road(Vector2(0.0, 1.0)), "on the road")
	assert_true(view.is_off_road(Vector2(0.0, 40.0)), "well off it")
	var car := VehicleBody3D.new()
	add_child_autofree(car)
	car.global_position = Vector3(0.0, 0.0, 40.0)
	var rec := RoadRecovery.new()
	rec.car = car
	rec.streamer = view
	autofree(rec)
	var t: float = Config.data.off_road_reset_timeout_s
	assert_false(rec.off_road_step(t * 0.6), "not yet")
	assert_ne(LevelView.off_road_text(Config.data.off_road_warning_after_s), "", "a countdown warns of the coming reset")
	assert_eq(LevelView.off_road_text(0.0), "", "no warning on the road")
	assert_true(rec.off_road_step(t * 0.6), "off the road for the timeout")
	car.global_position = Vector3(0.0, 0.0, 1.0)
	assert_false(rec.off_road_step(t * 2.0), "back on the road stops the clock")


func test_the_spawn_override_picks_the_node_and_faces_along_the_road_or_falls_back() -> void:
	var roads := [[{"x": 0.0, "z": 0.0}, {"x": 10.0, "z": 0.0}, {"x": 20.0, "z": 5.0}]]
	assert_eq(LevelView.spawn_override(roads, Vector2i(0, 1)), [Vector2(10, 0), Vector2(20, 5)] as Array[Vector2])
	assert_eq(LevelView.spawn_override(roads, Vector2i(0, 2)), [Vector2(20, 5), Vector2(10, 0)] as Array[Vector2], "the last node faces back")
	assert_eq(LevelView.spawn_override(roads, Vector2i(-1, -1)).size(), 0)
	assert_eq(LevelView.spawn_override(roads, Vector2i(3, 0)).size(), 0, "out of range")
	assert_eq(LevelView.spawn_override(roads, Vector2i(0, 9)).size(), 0)


func test_log_piles_sit_clear_of_the_road_with_ends_facing_it() -> void:
	var level := _level()
	level["logPiles"] = [{"x": 20.0, "z": 2.0}, {"x": -40.0, "z": -30.0}]
	var view := _built(level)
	var near := view.get_node("LogPile0") as Node3D
	var half_length: float = ((near.get_child(1) as CollisionShape3D).shape as BoxShape3D).size.z / 2.0
	assert_gt(absf(near.position.z) - half_length, 3.0, "a pile placed on the verge is pushed off the road, near end included")
	assert_almost_eq(absf(near.basis.z.z), 1.0, 0.01, "its logs point at the road, sawn ends facing it")
	assert_almost_eq((view.get_node("LogPile1") as Node3D).position.z, -30.0, 0.01, "a pile already clear stays put")
