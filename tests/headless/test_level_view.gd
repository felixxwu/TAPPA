extends GutTest
# The level-editor save that is the game world (Scenes.WORLD, features/level-editor.md): unpacking the
# lab's save format, the ground built around the road, the trees, and the legacy-island dev redirect.
# Every level here is synthetic; nothing reads the shipped Hafren save.

var _toggle: bool
var _handling: Array
const _HANDLING := ["deep_snow_drag", "deep_snow_depth_m", "grass_grip", "gravel_grip", "tarmac_grip"]


func before_each() -> void:
	_toggle = Config.data.legacy_free_roam_island
	_handling = _HANDLING.map(func(k: String) -> Variant: return Config.data.get(k))


func after_each() -> void:
	Config.data.legacy_free_roam_island = _toggle
	for i in _HANDLING.size():
		Config.data.set(_HANDLING[i], _handling[i])


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


func test_a_building_footprint_is_its_rotated_rectangle() -> void:
	var fp := LevelMap.footprint({"x": 5.0, "z": -3.0, "rot": 0.7, "L": 10.0, "W": 4.0})
	assert_almost_eq((fp[0] + fp[2]) / 2.0, Vector2(5.0, -3.0), Vector2.ONE * 1e-4, "centred on the building")
	assert_almost_eq(fp[0].distance_to(fp[3]), 10.0, 1e-4, "long side")
	assert_almost_eq(fp[0].distance_to(fp[1]), 4.0, 1e-4, "short side")


func test_teleport_names_sit_beside_their_diamonds_and_thin_out_when_crowded() -> void:
	var screen := Rect2(0, 0, 400, 300)
	var spread := LevelMap.place_names(PackedVector2Array([Vector2(50, 50), Vector2(50, 200)]), PackedFloat32Array([80, 80]), 18.0, screen, -1)
	assert_gt(spread[0].position.x, 50.0, "a name goes right of its diamond when there's room")
	assert_false(spread[0].intersects(spread[1]), "names far apart both show")
	var edge := LevelMap.place_names(PackedVector2Array([Vector2(380, 150)]), PackedFloat32Array([80]), 18.0, screen, -1)
	assert_lt(edge[0].end.x, 380.0, "a name that would run off the right edge goes left instead")
	var crowd := PackedVector2Array([Vector2(150, 150), Vector2(150, 150), Vector2(150, 150)])
	var piled := LevelMap.place_names(crowd, PackedFloat32Array([80, 80, 80]), 18.0, screen, -1)
	assert_eq(piled[2].size, Vector2.ZERO, "three names on one spot: the one with no free side is dropped, not piled on")
	for i in 2:
		for j in range(i + 1, 3):
			if piled[i].size != Vector2.ZERO and piled[j].size != Vector2.ZERO:
				assert_false(piled[i].intersects(piled[j]), "shown names never overlap")
	var aimed := LevelMap.place_names(crowd, PackedFloat32Array([80, 80, 80]), 18.0, screen, 2)
	assert_ne(aimed[2].size, Vector2.ZERO, "the aimed-at teleport's name always shows")
	var unnamed := LevelMap.place_names(PackedVector2Array([Vector2(100, 100)]), PackedFloat32Array([0]), 18.0, screen, -1)
	assert_eq(unnamed[0].size, Vector2.ZERO, "a teleport with no name draws no box")


func test_the_map_ground_leans_toward_the_cover_colour() -> void:
	var lv := _level()
	var rle := PackedByteArray([1])
	var n := 600 * 600
	while n >= 128:
		rle.append(n & 127 | 128)
		n >>= 7
	rle.append(n)
	lv["coverRle"] = Marshalls.raw_to_base64(rle)
	lv["coverKinds"] = {"1": [[{"base": "#ff0000", "tip": "#ff0000"}, 1.0]]}
	var map := LevelMap.new()
	autofree(map)
	map.view = _built(lv)
	var c := map._cover_image().get_pixel(LevelMap.IMAGE_PX / 2, LevelMap.IMAGE_PX / 2)
	assert_gt(c.r - c.g, LevelMap.GROUND.r - LevelMap.GROUND.g + 0.05, "tinted toward the red cover")


func test_world_entry_is_the_level_unless_the_legacy_island_is_on() -> void:
	Config.data.legacy_free_roam_island = false
	Scenes.change_to(get_tree(), Scenes.WORLD)
	assert_eq(Scenes.last_blocked_path, Scenes.WORLD, "the level is the world by default")
	Config.data.legacy_free_roam_island = true
	Scenes.change_to(get_tree(), Scenes.WORLD)
	assert_eq(Scenes.last_blocked_path, Scenes.LEGACY_FREE_ROAM, "the dev toggle swaps in the legacy island")
	Config.data.legacy_free_roam_island = false
	Scenes.change_to(get_tree(), Scenes.LEGACY_FREE_ROAM)
	assert_eq(Scenes.last_blocked_path, Scenes.LEGACY_FREE_ROAM, "the legacy island reloads itself, never the level")


func test_the_shipped_config_makes_the_level_the_default_world() -> void:
	assert_false(GameConfig.new().legacy_free_roam_island, "the legacy island is off out of the box")


func test_the_level_scene_arms_its_pause_menu() -> void:
	var path := "user://test_level_view_level.json"
	var lv := _level()
	lv["road"][0]["tarmac"] = true
	lv["buildings"] = [{"x": 20.0, "z": 30.0, "rot": 0.0, "L": 10.0, "W": 6.0}]
	lv["teleports"] = [{"x": 10.0, "z": 3.0}, {"x": 60.0, "z": 4.0}]
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(lv))
	f.close()
	var world: Node = (load(Scenes.WORLD) as PackedScene).instantiate()
	world.get_node("Level").level_path = path
	add_child_autofree(world)
	await wait_for_signal(world.get_node("Level").loaded, 30.0)
	assert_true(world.get_node("PauseMenu").is_armed(), "Esc / Start open the pause menu")
	assert_eq(world.get_node("Car")._car_index, CarLibrary.index_of(Config.data.level_car_id), "drives the level's own car")
	var map: LevelMap = world.get_node("Level").map
	var m := InputEventKey.new()
	m.physical_keycode = KEY_M
	m.pressed = true
	map._input(m)
	assert_true(map.visible and get_tree().paused, "M opens the map and pauses")
	map.zoom = map.fit_zoom() * 2.0
	var zoom0 := map.zoom
	var under := map.to_world(Vector2(500, 300))  # the ground between the two fingers
	var press := InputEventMouseButton.new()  # the first finger's emulated mouse, as a touch screen sends it
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = Vector2(400, 300)
	map._input(press)
	map._input(_touch(0, Vector2(400, 300), true))
	map._input(_touch(1, Vector2(600, 300), true))
	var drag := InputEventScreenDrag.new()
	drag.index = 1
	drag.position = Vector2(800, 300)
	map._input(drag)
	assert_almost_eq(map.zoom, zoom0 * 2.0, zoom0 * 0.01, "spreading two fingers to twice as far apart zooms in twice as far")
	assert_almost_eq(map.to_screen(under), Vector2(600, 300), Vector2.ONE, "the ground under the fingers follows their midpoint")
	map._input(_touch(0, Vector2(400, 300), false))
	map._input(_touch(1, Vector2(800, 300), false))
	press.pressed = false
	map._input(press)
	assert_true(map.visible, "lifting the fingers after a pinch doesn't teleport")
	var here := Vector2((world.get_node("Car") as Node3D).global_position.x, (world.get_node("Car") as Node3D).global_position.z)
	assert_eq(map.discovery.shown(here), 1.0, "the ground round the car is discovered")
	assert_not_null(map._fog, "the rest of the map is drawn under fog")
	assert_true(true in map._tarmac and false in map._tarmac, "the map splits the road where it turns from tarmac to gravel")
	assert_eq(map._buildings.size(), 1, "the map draws the save's building")
	assert_almost_eq(map.to_world(map.to_screen(Vector2(30, -20))), Vector2(30, -20), Vector2.ONE * 0.01)
	assert_eq(map.nearest_teleport(Vector2(45, 25)), Vector2(60, 4), "a click picks the nearest teleport point, not the nearest road")
	await map.teleport(map.nearest_teleport(Vector2(45, 25)))
	var car := world.get_node("Car") as Node3D
	assert_almost_eq(Vector2(car.global_position.x, car.global_position.z), Vector2(60, 0), Vector2.ONE * 1.0, "teleported onto the road beside the point")
	assert_false(map.visible or get_tree().paused, "teleporting closes the map and resumes")
	var lpause: PauseMenu = world.get_node("PauseMenu")
	lpause.open()
	assert_eq(CardUI.titles(lpause.cards()).slice(0, 2), PackedStringArray(["Resume", "Map"]), "the map sits right after Resume (touch has no M)")
	assert_true(CardUI.pick(lpause.cards(), "Map"))
	assert_true(map.visible and get_tree().paused, "the pause menu's Map opens the map, still paused")
	assert_false(lpause.is_open(), "the map covers the pause menu")
	map.back_button.pressed.emit()
	assert_false(map.visible)
	assert_true(lpause.is_open() and get_tree().paused, "Back returns to the pause menu")
	assert_eq(CardUI.titles(lpause.cards())[lpause.cards().selected_index()], "Map", "the cursor is back on Map")
	map._input(m)
	assert_true(lpause.is_open() and not map.visible, "M does nothing over the open pause menu")
	assert_true(CardUI.pick(lpause.cards(), "Map"))
	await map.teleport(map.nearest_teleport(Vector2(10, 3)))
	assert_false(map.visible or get_tree().paused or lpause.is_open(), "teleporting from the pause menu's map goes straight back to driving")
	assert_true(lpause.is_armed(), "with the pause menu armed again")
	# Photo Mode from the level's pause menu really opens the photo camera — it used to hide the
	# menu with nothing listening, stranding the player on a frozen frame — and leaving comes back.
	lpause.open()
	assert_true(CardUI.pick(lpause.cards(), "Photo Mode"))
	var photo := world.get_node_or_null("PhotoModeCamera") as PhotoModeCamera
	assert_true(photo != null and photo.is_active(), "Photo Mode opens the photo camera on a level")
	var ground: LevelStreamer = world.get_node("Level").get_node("Ground")
	assert_eq(ground.focus, photo, "the ground and cover stream round the photo camera")
	assert_eq(ground.process_mode, Node.PROCESS_MODE_ALWAYS, "and keep streaming while the world is frozen")
	# RENDER (R / Y / the touch button) toggles longer draw distances on and off.
	var lview: LevelView = world.get_node("Level")
	assert_true(photo.can_render, "the level offers photo mode's render")
	var draw0: float = lview._trees.draw_m()
	var far0 := photo.far
	photo.render_requested.emit()  # headless shows no loading screen, so the build runs at once
	assert_true(lview.is_rendering() and photo.render_active, "the render is on")
	assert_gt(lview._trees.draw_m(), draw0, "drawing trees further out")
	assert_gt(lview._streamer.cover.far_reach(), Config.data.ground_cover_far_reach, "and cover")
	await get_tree().create_timer(0.3, true).timeout  # the tree is paused: GUT's own waits would stall
	assert_true(lview.is_rendering(), "and stays on: no timer")
	photo.render_requested.emit()
	assert_false(lview.is_rendering() or photo.render_active, "pressing it again turns it off")
	assert_eq(lview._trees.draw_m(), draw0, "back to the normal tree distance")
	assert_eq(lview._streamer.cover.far_reach(), Config.data.ground_cover_far_reach, "and cover reach")
	assert_eq(photo.far, far0, "and the camera's far plane")
	photo.render_requested.emit()
	assert_true(lview.is_rendering(), "on again")
	photo.exit()
	assert_false(lview.is_rendering(), "leaving photo mode turns the render off")
	assert_eq(lview._trees.draw_m(), draw0)
	assert_eq(ground.focus, world.get_node("Car"), "leaving photo mode streams round the car again")
	assert_eq(ground.process_mode, Node.PROCESS_MODE_INHERIT)
	assert_true(lpause.is_open(), "and leaving it returns to the pause menu")
	lpause.resume()
	var start_car := Config.data.level_car_id
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
	assert_eq(Scenes.last_blocked_path, Scenes.WORLD, "reloading the level to fit the parts")
	LevelView._next_pose = null
	LevelView.owned = {}
	Scenes.last_blocked_path = ""
	pause.return_from_extra()
	CardUI.pick(pause.cards(), "Garage")
	assert_not_null(level.garage, "the pause menu's Garage opens the car cards")
	var other := 1 if CarLibrary.all()[0]["id"] == start_car else 0
	CardUI.pick(level.garage.find_children("*", "CardCarousel", true, false)[0], String(CarLibrary.all()[other]["name"]))
	assert_eq(Config.data.level_car_id, String(CarLibrary.all()[other]["id"]), "picking a car makes it the level's car")
	assert_eq(Scenes.last_blocked_path, Scenes.WORLD, "and reloads the level to field it")
	assert_almost_eq(LevelView._next_pose.origin, car.global_position, Vector3.ONE * 0.01, "standing where the old car was")
	LevelView._next_pose = null
	Config.data.level_car_id = start_car
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
	var lv := _level()
	lv["gravelPatches"] = [[{"x": 30.0, "z": 30.0}, {"x": 45.0, "z": 30.0}, {"x": 45.0, "z": 45.0}, {"x": 30.0, "z": 45.0}]]
	var view := _built(lv)
	assert_false(view.is_off_road(Vector2(0.0, 1.0)), "on the road")
	assert_true(view.is_off_road(Vector2(0.0, 40.0)), "well off it")
	assert_false(view.is_off_road(Vector2(38.0, 38.0)), "on a gravel patch")
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
	assert_eq(LevelView.spawn_override(roads, Vector3i(0, 1, -1)), [Vector2(10, 0), Vector2(20, 5)] as Array[Vector2])
	assert_eq(LevelView.spawn_override(roads, Vector3i(0, 2, -1)), [Vector2(20, 5), Vector2(10, 0)] as Array[Vector2], "the last node faces back")
	assert_eq(LevelView.spawn_override(roads, Vector3i(0, 1, 0)), [Vector2(10, 0), Vector2(0, 0)] as Array[Vector2], "faces the chosen node")
	assert_eq(LevelView.spawn_override(roads, Vector3i(-1, -1, -1)).size(), 0)
	assert_eq(LevelView.spawn_override(roads, Vector3i(3, 0, -1)).size(), 0, "out of range")
	assert_eq(LevelView.spawn_override(roads, Vector3i(0, 9, -1)).size(), 0)
	assert_eq(LevelView.spawn_override(roads, Vector3i(0, 1, 1)).size(), 0, "can't face itself")


func test_log_piles_sit_clear_of_the_road_with_ends_facing_it() -> void:
	var level := _level()
	level["logPiles"] = [{"x": 20.0, "z": 2.0}, {"x": -40.0, "z": -30.0}]
	var view := _built(level)
	var near := view.get_node("LogPile0") as Node3D
	var half_length: float = ((near.get_child(1) as CollisionShape3D).shape as BoxShape3D).size.z / 2.0
	assert_gt(absf(near.position.z) - half_length, 3.0, "a pile placed on the verge is pushed off the road, near end included")
	assert_almost_eq(absf(near.basis.z.z), 1.0, 0.01, "its logs point at the road, sawn ends facing it")
	assert_almost_eq((view.get_node("LogPile1") as Node3D).position.z, -30.0, 0.01, "a pile already clear stays put")


func test_snow_handling_follows_the_biome_under_the_car() -> void:
	var level := _level()
	level["biomeRle"] = "AYgOAIgO"  # north half (z < 0) snow, south half forest
	var view := _built(level)
	var car := VehicleBody3D.new()
	car.freeze = true
	add_child_autofree(car)
	view._car = car
	car.position = Vector3(0.0, 0.0, -200.0)
	view._physics_process(0.0)
	assert_almost_eq(Config.data.deep_snow_drag, Config.data.level_snow_drag, 0.001, "full drag in the snow")
	assert_almost_eq(Config.data.gravel_grip, Config.data.snow_gravel_grip, 0.001, "snow grip on the road")
	assert_true(Config.data.ground_is_snow(), "snow tyres count as on snow")
	car.position = Vector3(0.0, 0.0, 200.0)
	view._physics_process(0.0)
	var base := GameConfig.new()
	assert_almost_eq(Config.data.deep_snow_drag, 0.0, 0.001, "no drag in the forest")
	assert_almost_eq(Config.data.gravel_grip, base.gravel_grip, 0.001, "normal grip in the forest")
	assert_false(Config.data.ground_is_snow())


func test_snow_dust_is_lightened_like_the_road_and_untouched_off_the_snow() -> void:
	var base := Color(0.4, 0.35, 0.3, 0.8)
	assert_eq(LevelView.snow_dust(base, 0.0, 0.5), base, "no snow, no change")
	var c := LevelView.snow_dust(base, 1.0, 0.5)
	assert_gt(c.r, base.r, "lighter on snow")
	assert_almost_eq(c.a, base.a, 0.001, "same opacity")


func test_the_last_driven_car_and_parts_come_back_next_launch() -> void:
	var start_car := Config.data.level_car_id
	var start_setting: Variant = Save.get_setting(LevelView.SAVED_CAR_KEY)
	var id := String(CarLibrary.all()[0]["id"])
	var saved := {"model_id": id, "tuning": {}, "parts": [{"id": "x", "on": true}]}
	Save.set_setting(LevelView.SAVED_CAR_KEY, saved)
	LevelView.owned = {}
	LevelView.restore_saved_car()
	assert_eq(Config.data.level_car_id, id, "the saved car is the level's car")
	assert_eq(LevelView.owned, saved, "with its parts")
	LevelView.owned = {}
	Config.data.level_car_id = start_car
	Save.set_setting(LevelView.SAVED_CAR_KEY, {"model_id": "no_such_car"})
	LevelView.restore_saved_car()
	assert_eq(Config.data.level_car_id, start_car, "a car gone from the roster is ignored")
	assert_true(LevelView.owned.is_empty())
	Save.set_setting(LevelView.SAVED_CAR_KEY, start_setting)
	Config.data.level_car_id = start_car


func test_the_last_spot_on_this_level_comes_back_next_launch() -> void:
	var view := _built(_level(2.0))
	var fallback := Transform3D(Basis(), Vector3(1, 2, 3))
	var pose := view.saved_pose({"level": "a.json", "x": 30.0, "z": -10.0, "yaw": 1.0}, "a.json", fallback)
	assert_almost_eq(Vector2(pose.origin.x, pose.origin.z), Vector2(30, -10), Vector2.ONE * 0.01, "back where it was")
	assert_gt(pose.origin.y, view.height_at(30, -10), "standing above the ground")
	assert_almost_eq(pose.basis.get_euler().y, 1.0, 0.01, "facing the same way")
	assert_eq(view.saved_pose({"level": "b.json", "x": 30.0, "z": -10.0}, "a.json", fallback), fallback, "a spot from another level is ignored")
	assert_eq(view.saved_pose(null, "a.json", fallback), fallback, "nothing saved starts at the spawn")


func _touch(index: int, at: Vector2, down: bool) -> InputEventScreenTouch:
	var t := InputEventScreenTouch.new()
	t.index = index
	t.position = at
	t.pressed = down
	return t
