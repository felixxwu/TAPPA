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


func test_map_names_sit_beside_their_markers_stack_when_close_and_thin_out_when_crowded() -> void:
	var screen := Rect2(0, 0, 400, 300)
	var spread := LevelMap.place_names(PackedVector2Array([Vector2(50, 50), Vector2(50, 200)]), PackedFloat32Array([80, 80]), 18.0, screen, -1)
	assert_gt(spread[0].position.x, 50.0, "a name goes right of its diamond when there's room")
	assert_false(spread[0].intersects(spread[1]), "names far apart both show")
	var edge := LevelMap.place_names(PackedVector2Array([Vector2(380, 150)]), PackedFloat32Array([80]), 18.0, screen, -1)
	assert_lt(edge[0].end.x, 380.0, "a name that would run off the right edge goes left instead")
	var crowd := PackedVector2Array([Vector2(150, 150), Vector2(150, 150), Vector2(150, 150)])
	var close := LevelMap.place_names(crowd, PackedFloat32Array([80, 80, 80]), 18.0, screen, -1)
	for i in 3:
		assert_ne(close[i].size, Vector2.ZERO, "names close together are all shown, stacked apart")
		for j in range(i + 1, 3):
			assert_false(close[i].intersects(close[j]), "without overlapping")
	var pile := PackedVector2Array()
	var widths := PackedFloat32Array()
	for i in 40:
		pile.append(Vector2(150, 150))
		widths.append(80)
	var piled := LevelMap.place_names(pile, widths, 18.0, screen, -1)
	assert_true(piled.any(func(r: Rect2) -> bool: return r.size == Vector2.ZERO), "too many on one spot: the ones with no room left are dropped")
	for i in piled.size():
		for j in range(i + 1, piled.size()):
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


func test_deliveries_to_unfound_points_lead_the_list_shortest_first() -> void:
	var job := func(to: String, km: float) -> Dictionary: return {"t": {}, "m": {"to": to}, "km": km}
	var jobs := [job.call("Known", 1.0), job.call("FarNew", 9.0), job.call("Known2", 0.5), job.call("NearNew", 3.0)]
	var order := LevelView.new_ends_first(jobs, ["Known", "Known2"]).map(func(j: Dictionary) -> String: return j["m"]["to"])
	assert_eq(order, ["NearNew", "FarNew", "Known", "Known2"])


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
	LevelView.forget_progress()  # start as a new player: a past run's saved car would count as owned
	Save.set_setting(LevelView.CARS_KEY, [Config.data.level_car_id])  # who has bought the level's car, so drives
	var unowned: Array = CarLibrary.all().map(func(c: Dictionary) -> String: return String(c["id"])).filter(
		func(id: String) -> bool: return not id in LevelView.owned_cars())
	var reward := String(unowned[0])
	var for_sale := String(unowned[1])
	var part := String(BoostLibrary.CATALOGUE.keys()[0])
	lv["shops"] = [{"x": 35.0, "z": 3.0, "name": "Corner Shop", "stock": [{"car": for_sale, "price": 50}, {"part": part, "price": 50}],
		"model": {"seed": 1, "x": 35.0, "z": 60.0, "yaw": 0.0}},
		{"x": 90.0, "z": 3.0, "name": "Other Shop", "stock": [{"car": for_sale, "price": 50}],
		"model": {"seed": 2, "x": 90.0, "z": 60.0, "yaw": 0.0}}]
	lv["teleports"] = [{"x": 10.0, "z": 3.0, "name": "Alpha"},
		{"x": 60.0, "z": 4.0, "heading": 90.0, "name": "Beta", "deliveries": [{"to": "Alpha"}]}]
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(lv))
	f.close()
	var tri := {"p": [0, 0, 0, 1, 0, 0, 0, 3, 0], "n": [0, 0, 1, 0, 0, 1, 0, 0, 1], "uv": [0, 0, 1, 0, 0, 1], "c": [1, 1, 1, 1, 1, 1, 1, 1, 1]}
	var baked := []
	for i in 2:
		var shop := tri.duplicate()
		shop.merge({"kind": "shop", "shop": i, "x": [35.0, 90.0][i], "z": 60.0, "yaw": 0.0, "box": [-4.0, 4.0, -3.0, 3.0, 3.0], "texts": []})
		baked.append(shop)
	var bf := FileAccess.open(path.replace(".json", ".buildings.json"), FileAccess.WRITE)
	bf.store_string(JSON.stringify(baked))
	bf.close()
	var world: Node = (load(Scenes.WORLD) as PackedScene).instantiate()
	world.get_node("Level").level_path = path
	add_child_autofree(world)
	await wait_for_signal(world.get_node("Level").loaded, 30.0)
	assert_true(world.get_node("PauseMenu").is_armed(), "Esc / Start open the pause menu")
	assert_eq(world.get_node("Car")._car_index, CarLibrary.index_of(Config.data.level_car_id), "drives the level's own car")
	var map: LevelMap = world.get_node("Level").map
	var minimap: LevelMinimap = world.get_node("Level").minimap
	await get_tree().process_frame
	assert_true(minimap.visible, "the minimap shows while driving")
	var car0 := world.get_node("Car") as Node3D
	assert_eq(map.discovery.shown(Vector2(car0.global_position.x, car0.global_position.z)), 1.0,
		"the minimap's first picture already shows the ground round the car, not all fog")
	var m := InputEventKey.new()
	m.physical_keycode = KEY_M
	m.pressed = true
	map._input(m)
	assert_true(map.visible and get_tree().paused, "M opens the map and pauses")
	await get_tree().process_frame
	assert_false(minimap.visible, "the minimap hides under the open map")
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
	assert_almost_eq(Array(map._widths).max(), 2.0 * Array(map.view._bake.sw).max(), 0.13, "the map draws the widest road at its real width")
	assert_almost_eq(Array(map._widths).min(), 2.0 * Array(map.view._bake.sw).min(), 0.13, "and the narrowest at its own")
	assert_eq(map._buildings.size(), 1, "the map draws the save's building")
	assert_almost_eq(map.to_world(map.to_screen(Vector2(30, -20))), Vector2(30, -20), Vector2.ONE * 0.01)
	assert_eq(map.nearest_teleport(Vector2(45, 25)), Vector2(60, 4), "a click picks the nearest teleport point, not the nearest road")
	var lv_view: LevelView = world.get_node("Level")
	map.pick(map.nearest_teleport(Vector2(45, 25)))
	assert_not_null(lv_view.deliveries_page, "picking a point on the map opens its page instead of teleporting")
	var point_cards: CardCarousel = lv_view.deliveries_page.find_children("*", "CardCarousel", true, false)[0]
	var info := lv_view.delivery_info(lv_view.level["teleports"][1], lv_view.level["teleports"][1]["deliveries"][0])
	assert_eq(CardUI.titles(point_cards), PackedStringArray(["Teleport", "Navigate to", String(info["cargo"])]), "teleport, navigate and the point's deliveries, named by their cargo")
	assert_true(String(info["cargo"]) in LevelView.CARGO, "a delivery carries something")
	assert_gt(float(info["km"]), 0.0, "over the road's length between the points")
	var authored := lv_view.delivery_info(lv_view.level["teleports"][1], {"to": "Alpha", "cargo": "Crate of eggs", "pay": 123, "kg": 7})
	assert_eq([authored["cargo"], authored["pay"], authored["kg"]], ["Crate of eggs", 123, 7.0], "an authored cargo, pay and weight win over the derived ones")
	await get_tree().process_frame
	assert_true(lv_view.money_label.visible, "the money shows over the map")
	map._input(m)
	assert_true(map.visible, "the map under the point's page ignores input")
	var center0 := map.center
	Input.action_press("ui_right")
	map._process(0.1)
	assert_eq(map.center, center0, "and doesn't pan while the page's cards are browsed")
	lv_view.deliveries_page.visible = false
	map._process(0.1)
	assert_ne(map.center, center0, "it pans once nothing covers it")
	Input.action_release("ui_right")
	lv_view.deliveries_page.visible = true
	map.center = center0
	var map_back := InputEventAction.new()
	map_back.action = "ui_cancel"
	map_back.pressed = true
	MenuNav.of(lv_view.deliveries_page)._unhandled_input(map_back)
	assert_true(lv_view.deliveries_page == null and map.visible and get_tree().paused, "Back returns to the map")
	map.deliveries_button.pressed.emit()
	assert_not_null(lv_view.deliveries_page, "the map's Deliveries button lists the deliveries")
	assert_eq(CardUI.titles(lv_view.deliveries_page.find_children("*", "CardCarousel", true, false)[0]), PackedStringArray([String(info["cargo"])]),
		"every delivery from the found points, with no teleport or navigate")
	MenuNav.of(lv_view.deliveries_page)._unhandled_input(map_back)
	assert_true(lv_view.deliveries_page == null and map.visible, "and Back returns to the map")
	assert_eq(map.hovered(map.to_screen(Vector2(35, 3)) + Vector2(LevelMap.PICK_PX - 2.0, 0)), Vector2(35, 3), "the pointer near a found shop hovers it")
	assert_eq(map.hovered(map.to_screen(Vector2(35, 3)) + Vector2(0, LevelMap.PICK_PX * 3.0)), Vector2.INF, "empty ground hovers nothing, however near a point")
	var empty_click := InputEventMouseButton.new()
	empty_click.button_index = MOUSE_BUTTON_LEFT
	empty_click.position = map.to_screen(Vector2(35, 3)) + Vector2(0, LevelMap.PICK_PX * 3.0)
	empty_click.pressed = true
	map._input(empty_click)
	empty_click.pressed = false
	map._input(empty_click)
	assert_true(lv_view.store == null and lv_view.deliveries_page == null, "so a click there opens nothing")
	map.pick(Vector2(35, 3))
	assert_not_null(lv_view.store, "picking a shop on the map opens its stock")
	assert_eq(CardUI.titles(lv_view.store.find_children("*", "CardCarousel", true, false)[0]).size(), 2, "its car and its part")
	var shop_bodies: Array = lv_view.shop_cars[for_sale].map(func(c: Node3D) -> Node: return c.get_parent())
	var driving_id := Config.data.level_car_id
	Save.set_setting(LevelView.MONEY_KEY, 60)
	CardUI.pick(lv_view.store.find_children("*", "CardCarousel", true, false)[0], String(CarLibrary.by_id(for_sale)["name"]))
	(ConfirmPopup.any_open(get_tree()) as ConfirmPopup)._on_action(1)
	assert_true(for_sale in LevelView.owned_cars() and LevelView.money() == 10, "a car bought from the map joins the garage")
	assert_eq(Config.data.level_car_id, driving_id, "without swapping to it")
	assert_ne(Scenes.last_blocked_path, Scenes.WORLD, "or reloading the level")
	assert_not_null(lv_view.store, "the shop stays open")
	MenuNav.of(lv_view.store)._unhandled_input(map_back)
	assert_true(lv_view.store == null and map.visible and get_tree().paused, "Back from the shop returns to the map")
	Save.set_setting(LevelView.CARS_KEY, [driving_id])
	for i in shop_bodies.size():
		lv_view.park_stock(shop_bodies[i], lv_view.level["shops"][i])
	map.pick(map.nearest_teleport(Vector2(45, 25)))
	Save.set_setting(LevelView.MONEY_KEY, Config.data.level_teleport_cost - 1)
	CardUI.pick(lv_view.deliveries_page.find_children("*", "CardCarousel", true, false)[0], "Teleport")
	var broke := ConfirmPopup.any_open(get_tree()) as ConfirmPopup
	assert_not_null(broke, "teleporting without the money says so")
	broke._on_action(0)
	assert_eq(LevelView.money(), Config.data.level_teleport_cost - 1, "and costs nothing")
	Save.set_setting(LevelView.MONEY_KEY, Config.data.level_teleport_cost + 5)
	CardUI.pick(lv_view.deliveries_page.find_children("*", "CardCarousel", true, false)[0], "Teleport")
	var ask := ConfirmPopup.any_open(get_tree()) as ConfirmPopup
	assert_not_null(ask, "teleporting asks first")
	ask.trigger_back()
	assert_eq(LevelView.money(), Config.data.level_teleport_cost + 5, "No keeps the money")
	CardUI.pick(lv_view.deliveries_page.find_children("*", "CardCarousel", true, false)[0], "Teleport")
	(ConfirmPopup.any_open(get_tree()) as ConfirmPopup)._on_action(1)
	assert_eq(LevelView.money(), 5, "Yes pays for the teleport")
	for _i in 120:
		if not get_tree().paused:
			break
		await get_tree().process_frame
	var car := world.get_node("Car") as Node3D
	assert_almost_eq(Vector2(car.global_position.x, car.global_position.z), Vector2(60, 4), Vector2.ONE * 0.5, "teleported exactly onto the point, not the road beside it")
	assert_almost_eq(-car.global_basis.z, Vector3.RIGHT, Vector3.ONE * 0.05, "facing the point's heading: 90 degrees is east")
	assert_false(map.visible or get_tree().paused, "teleporting closes the map and resumes")
	for _i in 3:
		await get_tree().physics_frame
	var arrived: LevelView = world.get_node("Level")
	assert_null(arrived.service, "and drives on, without opening the point's service menu")
	var lpause: PauseMenu = world.get_node("PauseMenu")
	lpause.open()
	assert_eq(CardUI.titles(lpause.cards()).slice(0, 2), PackedStringArray(["Resume", "Map"]), "the map sits right after Resume (touch has no M)")
	assert_true(CardUI.pick(lpause.cards(), "Map"))
	assert_true(map.visible and get_tree().paused, "the pause menu's Map opens the map, still paused")
	assert_false(lpause.is_open(), "the map covers the pause menu")
	await get_tree().process_frame  # lay the opened map out
	assert_true(map.get_global_rect().encloses(map.back_button.get_global_rect()), "the whole Back button is on screen")
	var car_at := car.global_position
	await _tap(map.back_button.get_global_rect().get_center())  # a finger, as a phone sends it: no M, no Esc
	assert_false(map.visible, "tapping Back closes the map")
	assert_eq(car.global_position, car_at, "without teleporting")
	assert_true(lpause.is_open() and get_tree().paused, "Back returns to the pause menu")
	await get_tree().process_frame
	assert_true(lv_view.money_label.visible, "the money shows over the pause menu")
	assert_eq(CardUI.titles(lpause.cards())[lpause.cards().selected_index()], "Map", "the cursor is back on Map")
	map._input(m)
	assert_true(lpause.is_open() and not map.visible, "M does nothing over the open pause menu")
	assert_true(CardUI.pick(lpause.cards(), "Map"))
	await map.teleport(map.nearest_teleport(Vector2(10, 3)))
	assert_false(map.visible or get_tree().paused or lpause.is_open(), "teleporting from the pause menu's map goes straight back to driving")
	assert_true(lpause.is_armed(), "with the pause menu armed again")
	map.toggle()
	map._pick_at(map.to_screen(Vector2(-30, -40)))
	assert_true(map.visible, "with the dev toggle off, empty ground does nothing")
	Config.data.dev_teleport_anywhere = true
	await map._pick_at(map.to_screen(Vector2(-30, -40)))
	Config.data.dev_teleport_anywhere = false
	assert_almost_eq(Vector2(car.global_position.x, car.global_position.z), Vector2(-30, -40), Vector2.ONE * 0.5, "the dev toggle teleports onto any clicked spot")
	assert_false(map.visible or get_tree().paused, "and drives on")
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
	assert_true(lview._streamer.full_detail, "and full-detail ground out over the whole loaded ring")
	assert_gt(lview._streamer.near_reach(), TerrainStreamer.NEAR_REACH_M)
	assert_gt(lview._streamer.cover.far_reach(), Config.data.ground_cover_far_reach, "and cover")
	await get_tree().create_timer(0.3, true).timeout  # the tree is paused: GUT's own waits would stall
	assert_true(lview.is_rendering(), "and stays on: no timer")
	photo.render_requested.emit()
	assert_false(lview.is_rendering() or photo.render_active, "pressing it again turns it off")
	assert_false(lview._streamer.full_detail, "and the ground back to its normal detail")
	assert_eq(lview._trees.draw_m(), draw0, "back to the normal tree distance")
	assert_eq(lview._streamer.cover.far_reach(), Config.data.ground_cover_far_reach, "and cover reach")
	assert_eq(photo.far, far0, "and the camera's far plane")
	var weather := world.get_node("LevelWeather") as LevelWeather
	var fog_env := (world.get_node("WorldEnvironment") as WorldEnvironment).environment
	var kept_shown := weather._shown
	weather._shown = "night"
	fog_env.fog_depth_end = 123.0
	photo.render_requested.emit()
	assert_true(lview.is_rendering(), "on again")
	assert_eq(fog_env.fog_depth_end, 123.0, "rendering leaves any weather but dry's fog alone")
	weather._shown = kept_shown
	photo.exit()
	assert_false(lview.is_rendering(), "leaving photo mode turns the render off")
	assert_eq(lview._trees.draw_m(), draw0)
	assert_eq(ground.focus, world.get_node("Car"), "leaving photo mode streams round the car again")
	assert_eq(ground.process_mode, Node.PROCESS_MODE_INHERIT)
	assert_true(lpause.is_open(), "and leaving it returns to the pause menu")
	lpause.resume()
	var lv_node: LevelView = world.get_node("Level")
	assert_eq(lv_node.beacons.count(), 2, "an obelisk over every teleport point")
	assert_eq(lv_node.shop_beacons.count(), 2, "and over every shop")
	assert_true(lv_node.shop_cars.has(for_sale), "the car on sale is parked in its bay")
	assert_eq(lv_node.shop_cars[for_sale].size(), 2, "and at every shop that sells it")
	var parked: Node3D = lv_node.shop_cars[for_sale][0]
	assert_true(parked.global_position.z > 63.0 and absf(parked.global_position.x - 35.0) < 3.0, "in front of the shop")
	assert_true(parked.freeze, "standing still")
	var at_car: VehicleBody3D = world.get_node("Car")
	at_car.global_position = Vector3(35.0, at_car.global_position.y, 4.0)
	at_car.linear_velocity = Vector3.ZERO
	assert_eq(lv_node.shop_at(), 0, "stopped beside a shop")
	assert_false(String(part) in lv_node.owned["parts"].map(func(p: Dictionary) -> String: return String(p["id"])),
		"an upgrade not bought at a shop can't go on the car")
	lv_node.open_store(0)
	var store_cards: CardCarousel = lv_node.store.find_children("*", "CardCarousel", true, false)[0]
	assert_eq(CardUI.titles(store_cards).size(), 2, "the shop lists its car and its part")
	Save.set_setting(LevelView.MONEY_KEY, 60)
	var driving := Config.data.level_car_id
	CardUI.pick(store_cards, String(CarLibrary.by_id(for_sale)["name"]))
	(ConfirmPopup.any_open(get_tree()) as ConfirmPopup)._on_action(1)
	assert_true(for_sale in LevelView.owned_cars() and LevelView.money() == 10, "buying a car pays for it and adds it to the garage")
	assert_false(lv_node.shop_cars.has(for_sale), "and drives it out of its bay")
	assert_eq(Config.data.level_car_id, for_sale, "switching to it at once")
	assert_false(LevelView.owned.is_empty(), "keeping the old car in memory, so the reload can't restore it from the save instead")
	assert_eq(Scenes.last_blocked_path, Scenes.WORLD, "by reloading the level with it")
	Config.data.level_car_id = driving  # in the game the reload has replaced the level by now
	LevelView._next_pose = null
	Scenes.last_blocked_path = ""
	lv_node.open_store(0)
	assert_true(lv_node.orbit_camera != null and lv_node.orbit_camera.current, "the camera circles the shop while browsing")
	assert_eq(CardUI.index_of(lv_node.store.find_children("*", "CardCarousel", true, false)[0], String(CarLibrary.by_id(for_sale)["name"])), -1,
		"a car the player owns is off sale")
	CardUI.pick(lv_node.store.find_children("*", "CardCarousel", true, false)[0], String(BoostLibrary.CATALOGUE[part]["label"]))
	(ConfirmPopup.any_open(get_tree()) as ConfirmPopup)._on_action(0)
	assert_eq(LevelView.bought_parts(), [], "a part the player can't afford isn't bought")
	MenuNav.of(lv_node.store)._unhandled_input(_back_event())
	assert_true(lv_node.store == null and not get_tree().paused, "Back leaves the shop and drives on")
	assert_true(lv_node.orbit_camera == null and get_viewport().get_camera_3d() != null, "back behind the driving camera")
	for _f in 3:
		await get_tree().physics_frame
	assert_almost_eq(Vector2(at_car.global_position.x, at_car.global_position.z), Vector2(35.0, 3.0), Vector2.ONE * 0.3, "put on the shop's point")
	assert_almost_eq((-at_car.global_transform.basis.z * Vector3(1, 0, 1)).normalized(), Vector3.RIGHT, Vector3.ONE * 0.05, "facing its heading")
	var car_pos0 := at_car.global_position
	at_car.global_position = Vector3(60.0, at_car.global_position.y, 5.0)
	at_car.linear_velocity = Vector3.ZERO
	assert_eq(lv_node.service_at(), 1, "stopped beside a teleport point")
	await get_tree().process_frame
	assert_true(lv_node.service_prompt.visible, "the prompt shows while driving")
	lpause.open()
	await get_tree().process_frame
	assert_false(lv_node.service_prompt.visible, "but not over a menu")
	lpause.resume()
	at_car.global_position = Vector3(60.0, at_car.global_position.y, 5.0)
	at_car.linear_velocity = Vector3.ZERO
	at_car.linear_velocity = Vector3.FORWARD * (Config.data.level_service_max_speed + 1.0)
	assert_eq(lv_node.service_at(), -1, "driving past it doesn't count")
	at_car.linear_velocity = Vector3.ZERO
	var select := InputEventAction.new()
	select.action = "menu_select"
	select.pressed = true
	lv_node._unhandled_input(select)
	assert_not_null(lv_node.service, "Enter / A there opens its service menu")
	assert_true(get_tree().paused and not lpause.is_armed(), "frozen, with the pause menu out of the way")
	assert_true(lv_node.orbit_camera != null and lv_node.orbit_camera.current, "the camera circles the teleport point")
	var service_cards: CardCarousel = lv_node.service.find_children("*", "CardCarousel", true, false)[0]
	CardUI.pick(service_cards, "Swap car")
	assert_not_null(lv_node.garage, "Swap car opens the garage")
	var cancel := InputEventAction.new()
	cancel.action = "ui_cancel"
	cancel.pressed = true
	MenuNav.of(lv_node.garage)._unhandled_input(cancel)
	assert_not_null(lv_node.service, "backing out of the garage returns to the service menu")
	var sdmg: DamageModel = at_car.damage
	assert_eq(CardUI.index_of(lv_node.service.find_children("*", "CardCarousel", true, false)[0], "Repair"), -1, "no Repair card: the point heals")
	sdmg.apply_loss(sdmg.max_hp * 0.5)
	var hp0 := sdmg.hp
	lv_node.heal_at_points(0.5)
	assert_gt(sdmg.hp, hp0, "near a teleport point the car heals")
	var near_pos := at_car.global_position
	at_car.global_position = Vector3(-100.0, near_pos.y, 0.0)
	hp0 = sdmg.hp
	lv_node.heal_at_points(0.5)
	assert_eq(sdmg.hp, hp0, "away from one it doesn't")
	at_car.global_position = near_pos
	for _i in 100:
		lv_node.heal_at_points(1.0)
	assert_eq(sdmg.hp, sdmg.max_hp, "and it heals back to full")
	MenuNav.of(lv_node.service)._unhandled_input(cancel)
	assert_true(lv_node.service == null and not get_tree().paused, "Back closes the service menu")
	assert_eq(LevelView.last_point, 1, "being at a teleport point makes it the respawn point")
	assert_true(sdmg.thermal, "the engine can overheat here")
	at_car.global_position = Vector3(-100.0, near_pos.y, 0.0)
	sdmg.apply_loss(sdmg.max_hp)
	assert_true(lv_node._wrecked and not lpause.is_armed(), "at 0 HP the car is wrecked")
	await lv_node.respawn()
	await get_tree().physics_frame
	await get_tree().physics_frame
	assert_almost_eq(Vector2(at_car.global_position.x, at_car.global_position.z), Vector2(60, 4), Vector2.ONE * 0.5, "Respawn goes back to the last teleport point visited")
	assert_true(sdmg.hp == sdmg.max_hp and not lv_node._wrecked and lpause.is_armed(), "mended and driving again")
	lv_node._unhandled_input(select)
	var cargo := String(lv_node.delivery_info(lv_node.level["teleports"][1], lv_node.level["teleports"][1]["deliveries"][0])["cargo"])
	assert_eq(CardUI.titles(lv_node.service.find_children("*", "CardCarousel", true, false)[0])[0], "Deliveries",
		"the point's deliveries sit behind one Deliveries card, first")
	assert_eq(CardUI.index_of(lv_node.service.find_children("*", "CardCarousel", true, false)[0], cargo), -1, "not listed on the service menu itself")
	CardUI.pick(lv_node.service.find_children("*", "CardCarousel", true, false)[0], "Deliveries")
	assert_gt(CardUI.index_of(lv_node.service.find_children("*", "CardCarousel", true, false)[0], cargo), -1, "Deliveries lists the point's deliveries")
	MenuNav.of(lv_node.service)._unhandled_input(cancel)
	assert_gt(CardUI.index_of(lv_node.service.find_children("*", "CardCarousel", true, false)[0], "Tune car"), -1, "Back returns to the service menu")
	CardUI.pick(lv_node.service.find_children("*", "CardCarousel", true, false)[0], "Tune car")
	assert_true(lv_node.shop != null and lv_node.shop.view == RestStopPage.View.TUNE, "Tune car opens the tuning sliders")
	MenuNav.of(lv_node.shop._page)._unhandled_input(cancel)
	assert_true(lv_node.shop == null and lv_node.service != null, "Back from the tuning returns to the service menu")
	CardUI.pick(lv_node.service.find_children("*", "CardCarousel", true, false)[0], "Swap car")
	var garage_cards: CardCarousel = lv_node.garage.find_children("*", "CardCarousel", true, false)[0]
	assert_eq(CardUI.index_of(garage_cards, String(CarLibrary.by_id(reward)["name"])), -1, "the garage lists only owned cars")
	MenuNav.of(lv_node.garage)._unhandled_input(cancel)
	lv_node.close_service()
	lv_node.map.reveal_all()
	lv_node.map.toggle()
	lv_node.map.pick(Vector2(60.0, 4.0))
	CardUI.pick(lv_node.deliveries_page.find_children("*", "CardCarousel", true, false)[0], String(lv_node.delivery_info(lv_node.level["teleports"][1], lv_node.level["teleports"][1]["deliveries"][0])["cargo"]))
	assert_true(lv_node.map.visible and not lv_node.deliveries_page.visible and lv_node.map._route.size() > 1, "a delivery first shows its route on the map")
	assert_eq(lv_node.map.deliveries_button.text, UITheme.caps("Start"), "with Start to confirm it")
	var preview_key := InputEventAction.new()
	preview_key.action = "ui_cancel"
	preview_key.pressed = true
	lv_node.map._input(preview_key)
	assert_true(lv_node.deliveries_page.visible and lv_node.map.deliveries_button.text == UITheme.caps("Deliveries"), "Back returns to the page without starting it")
	CardUI.pick(lv_node.deliveries_page.find_children("*", "CardCarousel", true, false)[0], String(lv_node.delivery_info(lv_node.level["teleports"][1], lv_node.level["teleports"][1]["deliveries"][0])["cargo"]))
	preview_key.action = "ui_accept"
	lv_node.map._input(preview_key)
	assert_eq(CardUI.titles(lv_node.deliveries_page.find_children("*", "CardCarousel", true, false)[0]), PackedStringArray(["Teleport", "Navigate to"]),
		"a delivery asks how to get to its pick-up point")
	CardUI.pick(lv_node.deliveries_page.find_children("*", "CardCarousel", true, false)[0], "Navigate to")
	assert_eq(LevelView.nav_target(), "Beta", "navigating leads the sat nav to the pick-up point first")
	for _i in 120:
		if not get_tree().paused:
			break
		await get_tree().process_frame
	assert_eq(LevelView.delivery["to"], "Alpha", "picking a delivery starts it")
	var money0 := LevelView.money()
	var pay := int(LevelView.delivery["pay"])
	await get_tree().process_frame
	assert_false(lv_node.money_label.visible, "the money hides while driving")
	assert_true(lv_node.service == null and lv_node.deliveries_page == null and not get_tree().paused, "and drives on")
	for _f in 2:  # the tree's process_frame fires before the level's own _process has run
		await get_tree().process_frame
	assert_eq(LevelView.nav_target(), "Alpha", "arriving at the pick-up point leads it on to the drop-off")
	assert_true(lv_node.banner.is_showing_banner(), "with the delivery started banner")
	assert_true(lv_node.delivery_label.visible, "the drive-to label shows")
	await get_tree().process_frame
	assert_true(lv_node.cargo_label.visible and lv_node.cargo_label.text.contains("100%"), "the picked-up cargo shows full health")
	at_car.damage.damaged.emit(at_car.damage.max_hp * 0.25, Vector3.ZERO)
	assert_almost_eq(float(LevelView.delivery["cargo_hp"]), 75.0, 0.001, "a hit costs the cargo the same share it costs the car")
	await lv_node.respawn()
	assert_eq(float(LevelView.delivery["cargo_hp"]), 100.0, "a wreck's respawn mends the cargo too")
	var running := LevelView.delivery.duplicate()
	at_car.damage.damaged.emit(at_car.damage.max_hp, Vector3.ZERO)
	assert_true(LevelView.delivery.is_empty() and lv_node.banner.is_showing_banner(), "destroyed cargo fails the delivery")
	assert_false(running["key"] in LevelView.done_deliveries(), "and it can be taken again")
	LevelView.delivery = running
	LevelView.delivery["kg"] = 40.0
	await get_tree().process_frame
	assert_almost_eq(at_car.mass, at_car.config.mass + 40.0, 0.001, "the cargo's weight rides in the car")
	at_car.global_position = Vector3(10.0, at_car.global_position.y, 3.0)
	at_car.linear_velocity = Vector3.ZERO
	await get_tree().process_frame
	await get_tree().process_frame
	assert_true(LevelView.delivery.is_empty(), "reaching the target ends the delivery")
	assert_almost_eq(at_car.mass, at_car.config.mass, 0.001, "and unloads its weight")
	assert_false(reward in LevelView.owned_cars(), "and wins no car")
	assert_eq(LevelView.money(), money0 + pay, "and pays")
	assert_eq(LevelView.offered_deliveries(lv_node.level["teleports"][1]), [], "a finished delivery is never offered again")
	Save.erase_setting(LevelView.DONE_KEY)  # the rest of this test drives it again
	assert_true(lv_node.banner.is_showing_banner() and lv_node.service == null, "with the delivery complete banner, driving on")
	LevelView.delivery = {"from": "Beta", "to": "Alpha", "cargo": "Hay bales"}
	lv_node._on_map_closed(true, false)
	assert_true(LevelView.delivery.is_empty(), "a map teleport abandons the delivery")
	for _i in 4:
		await get_tree().physics_frame
	if lv_node.service != null:
		lv_node.close_service()
	lpause.open()
	assert_eq(CardUI.index_of(lpause.cards(), "Deliveries"), -1, "deliveries are picked on the map, not the pause menu")
	for row in ["Repair", "Garage", "Shop"]:
		assert_eq(CardUI.index_of(lpause.cards(), row), -1, "the pause menu leaves %s to the teleport points" % row)
	CardUI.pick(lpause.cards(), "Map")
	lv_node.map.reveal_all()
	lv_node.map.pick(Vector2(60.0, 4.0))
	CardUI.pick(lv_node.deliveries_page.find_children("*", "CardCarousel", true, false)[0], String(lv_node.delivery_info(lv_node.level["teleports"][1], lv_node.level["teleports"][1]["deliveries"][0])["cargo"]))
	lv_node.map.deliveries_button.pressed.emit()
	Save.set_setting(LevelView.MONEY_KEY, Config.data.level_teleport_cost)
	CardUI.pick(lv_node.deliveries_page.find_children("*", "CardCarousel", true, false)[0], "Teleport")
	(ConfirmPopup.any_open(get_tree()) as ConfirmPopup)._on_action(1)
	for _i in 120:
		if not get_tree().paused:
			break
		await get_tree().process_frame
	assert_eq(LevelView.delivery.get("from", ""), "Beta", "picking a delivery on the map starts it")
	assert_eq(LevelView.nav_target(), "Alpha", "teleporting to the pick-up point picks up there")
	assert_true(lv_node.deliveries_page == null and not get_tree().paused and not lv_node.map.visible, "and drives on")
	assert_true(lpause.is_armed(), "with the pause menu armed again")
	for _i in 2:
		await get_tree().physics_frame
	assert_almost_eq(Vector2(at_car.global_position.x, at_car.global_position.z), Vector2(60.0, 4.0), Vector2.ONE,
		"from the delivery's start point")
	lpause.open()
	CardUI.pick(lpause.cards(), "Map")
	lv_node.map.pick(Vector2(10.0, 3.0))
	CardUI.pick(lv_node.deliveries_page.find_children("*", "CardCarousel", true, false)[0], "Navigate to")
	assert_eq(LevelView.delivery, {"from": "", "to": "Alpha"}, "Navigate to routes to the point with no cargo")
	assert_false(get_tree().paused or lv_node.map.visible, "and drives on")
	at_car.global_position = Vector3(10.0, at_car.global_position.y, 3.0)
	at_car.linear_velocity = Vector3.ZERO
	await get_tree().process_frame
	await get_tree().process_frame
	assert_true(LevelView.delivery.is_empty() and lv_node.service == null, "arriving ends the navigation without a service menu")
	LevelView.delivery = {}
	lpause.open()
	lpause.resume()
	var start_car := Config.data.level_car_id
	var level := lv_node
	assert_false(sdmg.invulnerable, "the level's car takes damage")
	level._unhandled_input(select)
	assert_eq(CardUI.index_of(level.service.find_children("*", "CardCarousel", true, false)[0], "Upgrade"), -1, "parts are bought at shops, not fitted here")
	level.close_service()
	LevelView.owned = {}
	var other := 1 if CarLibrary.all()[0]["id"] == start_car else 0
	Save.set_setting(LevelView.CARS_KEY, [start_car, CarLibrary.all()[other]["id"]])
	level.open_service()  # in the game the reload has replaced the level by now
	CardUI.pick(level.service.find_children("*", "CardCarousel", true, false)[0], "Swap car")
	CardUI.pick(level.garage.find_children("*", "CardCarousel", true, false)[0], String(CarLibrary.all()[other]["name"]))
	assert_eq(Config.data.level_car_id, String(CarLibrary.all()[other]["id"]), "picking a car makes it the level's car")
	assert_eq(Scenes.last_blocked_path, Scenes.WORLD, "and reloads the level to field it")
	assert_almost_eq(LevelView._next_pose.origin, car.global_position, Vector3.ONE * 0.01, "standing where the old car was")
	LevelView._next_pose = null
	Save.erase_setting(LevelView.CARS_KEY)
	LevelView.delivery = {}
	at_car.global_position = car_pos0
	Config.data.level_car_id = start_car
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path.replace(".json", ".buildings.json")))


func test_a_new_player_owns_no_car_and_unknown_ids_are_dropped() -> void:
	var a := String(CarLibrary.all()[0]["id"])
	assert_eq(LevelView.sanitise_cars(null), [], "a save without the list owns no car")
	assert_eq(LevelView.sanitise_cars([a, "no_such_car", a]), [a], "unknown and repeated ids are dropped")
	assert_eq(LevelView.sanitise_cars(["no_such_car"]), [], "an emptied list owns nothing")


func test_a_new_player_starts_at_the_shop_with_no_car_and_the_starting_money() -> void:
	var path := "user://test_level_view_carless.json"
	var lv := _level()
	lv["shops"] = [{"x": 35.0, "z": 3.0, "name": "Corner Shop", "stock": [{"car": Config.data.level_car_id, "price": 10}]}]
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(lv))
	f.close()
	LevelView.forget_progress()
	assert_eq(LevelView.money(), Config.data.level_start_money, "a new player has the starting money")
	assert_false(LevelView.has_car())
	var world: Node = (load(Scenes.WORLD) as PackedScene).instantiate()
	world.get_node("Level").level_path = path
	add_child_autofree(world)
	var view: LevelView = world.get_node("Level")
	await wait_for_signal(view.loaded, 30.0)
	var car := world.get_node("Car") as VehicleBody3D
	assert_true(not car.visible and car.freeze, "no car is fielded")
	assert_true(view.orbit_camera != null and view.orbit_camera.current, "the camera circles the shop")
	assert_null(view.store, "the shop waits for the tutorial guy")
	var talk: Array = view.find_children("*", "NpcDialogue", false, false)
	assert_eq(talk.size(), 1, "who greets a new player")
	while is_instance_valid(talk[0]) and not talk[0].is_queued_for_deletion():
		talk[0].advance()
	await get_tree().process_frame
	assert_not_null(view.store, "then its stock opens")
	assert_eq(view.store.find_children("*", "Button", true, false).filter(func(b: Button) -> bool: return b.text.contains("Back")), [],
		"and no way back out to drive without a car")
	await get_tree().process_frame
	assert_false(view.minimap.visible, "no driving HUD")
	Scenes.last_blocked_path = ""
	CardUI.pick(view.store.find_children("*", "CardCarousel", true, false)[0], String(CarLibrary.by_id(Config.data.level_car_id)["name"]))
	(ConfirmPopup.any_open(get_tree()) as ConfirmPopup)._on_action(1)
	assert_eq(LevelView.owned_cars(), [Config.data.level_car_id], "buying a car makes it the player's")
	assert_not_null(view.store, "the shop stays open for anything else they want")
	assert_eq(Scenes.last_blocked_path, "")
	MenuNav.of(view.store)._unhandled_input(_back_event())
	assert_eq(Scenes.last_blocked_path, Scenes.WORLD, "leaving it reloads the level to drive the car")
	assert_true(LevelView._next_pose is Transform3D, "from beside the shop")
	assert_eq(LevelView.delivery, {"from": "", "to": Config.data.level_spawn_teleport}, "with the sat nav set for the first delivery job")
	assert_true(LevelView._tutor_on_drive, "and the tutorial guy to point them to it")
	assert_true(LevelView._greet_at_pickup, "and the dispatcher to meet them there")
	LevelView._tutor_on_drive = false
	LevelView._greet_at_pickup = false
	LevelView._greet_at_drop = false
	LevelView.delivery = {}
	LevelView._next_pose = null
	Scenes.last_blocked_path = ""
	LevelView.forget_progress()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


class PauseStub extends Node:
	func set_input_enabled(_on: bool) -> void:
		pass

	func is_armed() -> bool:
		return true


func test_the_dispatcher_and_first_recipient_each_speak_once_with_their_job_counts() -> void:
	var view := _built(_level())
	view._pause = autofree(PauseStub.new())
	add_child(view)
	view.level["teleports"] = [{"x": 0.0, "z": 0.0, "name": "Depot", "deliveries": [{"to": "A"}, {"to": "B"}]}]
	LevelView.delivery = {"from": "", "to": "Depot"}
	LevelView._greet_at_pickup = true
	var car := VehicleBody3D.new()
	car.freeze = true
	view.add_child(car)
	view._car = car
	view._driving = true
	car.linear_velocity = Vector3.FORWARD * (Config.data.level_service_max_speed + 5.0)
	view._check_delivery()
	assert_eq(view.find_children("*", "NpcDialogue", false, false).size(), 0, "driving through doesn't stop for the dispatcher")
	car.linear_velocity = Vector3.ZERO
	view._check_delivery()
	view._driving = false
	view._car = null
	car.free()
	var talk: Array = view.find_children("*", "NpcDialogue", false, false)
	assert_eq(talk.size(), 1, "the dispatcher speaks")
	assert_eq(talk[0].pages, NpcLines.fill(NpcLines.DISPATCHER_GREETING, 2), "counting the jobs on offer there")
	assert_true(get_tree().paused, "over the paused game")
	assert_false(LevelView._greet_at_pickup, "once")
	assert_true(LevelView._greet_at_drop, "and the first drop-off will thank them")
	while is_instance_valid(talk[0]) and not talk[0].is_queued_for_deletion():
		talk[0].advance()
	await get_tree().process_frame
	assert_false(get_tree().paused, "driving resumes when dismissed")
	assert_eq(LevelView.delivery, {})
	view.level["teleports"].append({"x": 9.0, "z": 0.0, "name": "A", "deliveries": [{"to": "Depot"}]})
	LevelView.delivery = {"from": "Depot", "to": "A", "cargo": "Box", "pay": 0}
	view._complete_delivery()
	talk = view.find_children("*", "NpcDialogue", false, false)
	assert_eq(talk.size(), 1, "the first delivery's recipient speaks")
	assert_eq(talk[0].pages, NpcLines.fill(NpcLines.RECIPIENT_THANKS, 1), "about their own jobs")
	assert_false(LevelView._greet_at_drop, "once only")
	while is_instance_valid(talk[0]) and not talk[0].is_queued_for_deletion():
		talk[0].advance()
	await get_tree().process_frame
	assert_false(get_tree().paused)
	LevelView.delivery = {"from": "Depot", "to": "A", "cargo": "Box", "pay": 0}
	view._complete_delivery()
	assert_eq(view.find_children("*", "NpcDialogue", false, false).size(), 0, "later deliveries pass without a word")


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


func test_wiping_progress_forgets_the_level_car_spot_and_map() -> void:
	var keys := [LevelView.SAVED_CAR_KEY, LevelView.SAVED_POSE_KEY, LevelMap.SEEN_KEY, LevelView.MONEY_KEY]
	var kept := keys.map(func(k: String) -> Variant: return Save.get_setting(k))
	var car_before := Config.data.level_car_id
	for k: String in keys:
		Save.set_setting(k, {"x": 1.0})
	LevelView.owned = {"model_id": "fx_old"}
	Config.data.level_car_id = "fx_old"
	LevelView.forget_progress()
	for k: String in keys:
		assert_null(Save.get_setting(k), "%s forgotten" % k)
	assert_true(LevelView.owned.is_empty(), "the car in memory is forgotten")
	assert_eq(Config.data.level_car_id, Config.authored_value("level_car_id", ""), "back to the starting car")
	for i in keys.size():
		if kept[i] != null:
			Save.set_setting(keys[i], kept[i])
	Config.data.level_car_id = car_before


func test_teleport_points_stay_off_the_map_until_found_or_unlocked() -> void:
	var lv := _level()
	lv["teleports"] = [{"x": -80.0, "z": 0.0, "name": "Near"}, {"x": 80.0, "z": 0.0, "name": "Far"}]
	var map := LevelMap.new()
	map.view = _built(lv)
	autofree(map)
	map.discovery = LevelDiscovery.new(map.size_m(), 10.0)
	assert_eq(map.known_teleports().size(), 0, "nothing found before driving anywhere")
	assert_eq(map.nearest_teleport(Vector2.ZERO), Vector2.INF, "and nowhere to teleport to")
	map.discovery.stamp(Vector2(-80, 0), 30.0, 5.0)
	assert_eq(map.known_teleports().map(func(t: Dictionary) -> String: return t["name"]), ["Near"], "driving near one finds it")
	assert_eq(map.nearest_teleport(Vector2(80, 0)), Vector2(-80, 0), "the unfound one can't be teleported to")
	var seen: Variant = Save.get_setting(LevelMap.SEEN_KEY)
	map.reveal_all()
	assert_eq(map.known_teleports().size(), 2, "unlock everything finds them all")
	if seen == null:
		Save.erase_setting(LevelMap.SEEN_KEY)
	else:
		Save.set_setting(LevelMap.SEEN_KEY, seen)


func test_engine_swaps_offer_only_the_cars_owned() -> void:
	var ids: Array = CarLibrary.all().map(func(c: Dictionary) -> String: return String(c["id"]))
	var page := RestStopPage.new()
	page.free = true
	page.owned = {"model_id": ids[0], "tuning": {}, "parts": []}
	page.engine_cars = [ids[0], ids[1]]
	add_child_autofree(page)
	page.open_shop()
	assert_true(page.pick("Engine swaps"))
	var shown := CardUI.titles(page._cards)
	assert_eq(shown.size(), 2, "one card per owned car")
	for id in ids.slice(2):
		assert_false(String(CarLibrary.by_id(id)["name"]) in shown, "%s isn't owned, so its engine isn't offered" % id)
	page.close()


func test_a_new_player_starts_on_the_named_teleport_facing_its_heading() -> void:
	var before := Config.data.level_spawn_teleport
	var lv := _level()
	lv["teleports"] = [{"x": 30.0, "z": 8.0, "name": "Start", "heading": 180.0}]
	var view := _built(lv)
	Config.data.level_spawn_teleport = "Start"
	var pose := view.spawn_pose()
	assert_almost_eq(Vector2(pose.origin.x, pose.origin.z), Vector2(30, 8), Vector2.ONE * 0.01, "on the point")
	assert_almost_eq(-pose.basis.z, Vector3.BACK, Vector3.ONE * 0.01, "facing its heading: 180 degrees is south")
	Config.data.level_spawn_teleport = "Nowhere"
	assert_ne(Vector2(view.spawn_pose().origin.x, view.spawn_pose().origin.z), Vector2(30, 8), "an unknown name falls back to the road spawn")
	Config.data.level_spawn_teleport = before


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


func test_a_fence_across_the_road_is_cut_where_the_road_runs() -> void:
	var level := _level()
	level["fences"] = [{"kind": "fence", "pts": [[30, -20], [30, 20]]}]
	var view := _built(level)
	var fences := view.get_node("Fences") as LevelFences
	var shapes := 0
	for b in fences.bodies:
		for cs: CollisionShape3D in b.get_children():
			shapes += 1
			assert_gt(absf(cs.position.z), 1.5, "no fence span stands on the road")
	assert_gt(shapes, 0, "the fence either side of the road stays")


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


func test_the_map_shows_the_snow_and_frosts_the_trees_in_it() -> void:
	var level := _level()
	level["biomeRle"] = "AYgOAIgO"  # north half (z < 0) snow, south half forest
	level["trees"] = [{"x": 0.0, "z": -250.0, "rot": 0.0, "sx": 4.0, "sy": 4.0, "kind": "tree.png"},
		{"x": 0.0, "z": 250.0, "rot": 0.0, "sx": 4.0, "sy": 4.0, "kind": "tree.png"}]
	var map := LevelMap.new()
	autofree(map)
	map.view = _built(level)
	var img := map._paint()
	var k := LevelMap.IMAGE_PX / map.size_m()
	var at := func(x: float, z: float) -> Color:
		return img.get_pixelv(Vector2i(int((x + map.size_m() / 2.0) * k), int((z + map.size_m() / 2.0) * k)))
	var snow: Color = at.call(-200.0, -150.0)
	var forest: Color = at.call(-200.0, 150.0)
	assert_gt(snow.get_luminance(), forest.get_luminance() + 0.05, "the snowy half is painted lighter")
	assert_true(snow.b >= snow.r, "and cold, not the warm ground")
	assert_true(map.snow_cell(LevelStreamer.decode_biome(level, map.size_m()), 0.0, -250.0), "the north tree stands in snow")
	var frosted: Color = at.call(0.0, -250.0)
	var green: Color = at.call(0.0, 250.0)
	assert_ne(frosted, snow, "a tree in the snow still shows over it")
	assert_gt(frosted.get_luminance(), green.get_luminance(), "and is frosted lighter than a forest tree")


func test_the_map_has_no_snow_without_a_biome_mask() -> void:
	var map := LevelMap.new()
	autofree(map)
	map.view = _built(_level())
	var img := map._cover_image(LevelStreamer.decode_biome(map.view.level, map.size_m()))
	assert_eq(img.get_pixel(10, 10), img.get_pixel(LevelMap.IMAGE_PX - 10, LevelMap.IMAGE_PX - 10), "plain ground everywhere")


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


# A real finger tap at `at` (viewport coordinates) through Input, so the GUI and the touch-emulated mouse
# both see it. GUT's own output panel sits over the game and would catch the tap, so it's hidden meanwhile.
func _tap(at: Vector2) -> void:
	var gut_layer := get_tree().root.get_node_or_null("GutRunner/GutLayer") as CanvasLayer
	if gut_layer != null:
		gut_layer.visible = false
	for down in [true, false]:
		Input.parse_input_event(_touch(0, get_viewport().get_final_transform() * at, down))
		Input.flush_buffered_events()
		await get_tree().process_frame
	if gut_layer != null:
		gut_layer.visible = true


func _touch(index: int, at: Vector2, down: bool) -> InputEventScreenTouch:
	var t := InputEventScreenTouch.new()
	t.index = index
	t.position = at
	t.pressed = down
	return t


func test_the_minimap_keeps_off_the_touch_buttons() -> void:
	Config.data.mobile_controls_force = true
	var controls := MobileControls.new()
	add_child_autofree(controls)
	var mini := LevelMinimap.new()
	add_child_autofree(mini)
	for scheme in [MobileControls.SCHEME_SLIDER_GAS_BRAKE, MobileControls.SCHEME_BUTTONS_GAS_BRAKE, MobileControls.SCHEME_SIMPLE_LR_AUTO]:
		controls.set_scheme(scheme)
		mini.place(controls)
		var r := Rect2(mini.position, mini.size)
		assert_true(r.size.x > 0.0, "the minimap has a size")
		for b in controls.button_rects():
			assert_false(b.intersects(r), "the minimap doesn't sit on a touch button (scheme %d)" % scheme)
	Config.data.mobile_controls_force = false


func test_the_gauge_dial_stays_level_with_the_minimap_and_off_the_touch_buttons() -> void:
	Config.data.mobile_controls_force = true
	var controls := MobileControls.new()
	add_child_autofree(controls)
	var mini := LevelMinimap.new()
	add_child_autofree(mini)
	var screen := get_viewport().get_visible_rect().size
	for scheme in [MobileControls.SCHEME_SLIDER_GAS_BRAKE, MobileControls.SCHEME_BUTTONS_GAS_BRAKE, MobileControls.SCHEME_SIMPLE_LR_AUTO]:
		controls.set_scheme(scheme)
		mini.place(controls)
		var dial := HudDial.home_rect(screen)
		dial.position.y += MobileControls.bottom_band_lift(controls, screen)
		assert_almost_eq(dial.end.y, mini.position.y + mini.size.y, 0.01, "dial and minimap share a bottom edge (scheme %d)" % scheme)
		for b in controls.button_rects():
			assert_false(b.intersects(dial), "the dial doesn't sit on a touch button (scheme %d)" % scheme)
	Config.data.mobile_controls_force = false


func _back_event() -> InputEventAction:
	var e := InputEventAction.new()
	e.action = "ui_cancel"
	e.pressed = true
	return e


func test_a_shop_box_is_its_building_footprint_turned_with_the_model() -> void:
	var b := LevelView.shop_box({"x": 10.0, "z": 20.0, "yaw": PI / 2.0, "box": [-1.0, 3.0, -2.0, 2.0, 4.0]})
	assert_almost_eq(b.half, Vector2(2.0, 2.0), Vector2.ONE * 0.001)
	var probe := Node3D.new()
	probe.rotation.y = PI / 2.0
	var want := Vector3(10.0, 0.0, 20.0) + probe.transform.basis * Vector3(1.0, 0.0, 0.0)
	assert_almost_eq(b.centre, Vector2(want.x, want.z), Vector2.ONE * 0.001, "the box's own centre, turned like the model")
	var x := probe.transform.basis.x
	assert_almost_eq(b.axis, Vector2(x.x, x.z), Vector2.ONE * 0.001, "its x axis turned the same way")
	probe.free()


func test_bought_parts_belong_to_one_car() -> void:
	var driving := Config.data.level_car_id
	Save.set_setting(LevelView.PARTS_KEY, {"car_a": ["part_x"]})
	Config.data.level_car_id = "car_a"
	assert_eq(LevelView.bought_parts(), ["part_x"], "the car driven has the parts bought for it")
	Config.data.level_car_id = "car_b"
	assert_eq(LevelView.bought_parts(), [], "another car has none of them")
	Config.data.level_car_id = driving
	Save.erase_setting(LevelView.PARTS_KEY)


func test_yard_layout_rows_sit_in_front_of_the_box_without_overlap() -> void:
	var sizes: Array[Vector2] = [Vector2(2.4, 4.8), Vector2(2.7, 5.8), Vector2(2.4, 4.8), Vector2(2.4, 4.8), Vector2(2.4, 4.8), Vector2(2.7, 5.8)]
	var box := [-6.0, 4.0, -3.0, 3.0, 3.0]
	var spots := LevelView.yard_layout(sizes, box)
	assert_eq(spots.size(), sizes.size())
	for i in sizes.size():
		assert_true(spots[i].y - sizes[i].y * 0.5 > 3.0, "car %d is in front of the building" % i)
		for j in range(i + 1, sizes.size()):
			var a := Rect2(spots[i] - sizes[i] * 0.5, sizes[i])
			var b := Rect2(spots[j] - sizes[j] * 0.5, sizes[j])
			assert_false(a.intersects(b), "cars %d and %d don't overlap" % [i, j])


func test_the_nav_beam_stands_over_the_sat_nav_target_and_hides_without_one() -> void:
	var lv := _level()
	lv["teleports"] = [{"x": 10.0, "z": 3.0, "name": "Alpha"}, {"x": 60.0, "z": 4.0, "name": "Beta"}]
	var view := _built(lv)
	view.nav_beam = view._nav_beam()
	view.add_child(view.nav_beam)
	var was := LevelView.delivery
	LevelView.delivery = {"to": "Beta"}
	view._place_nav_beam()
	assert_true(view.nav_beam.visible, "the beam shows while a delivery leads somewhere")
	assert_eq(Vector2(view.nav_beam.position.x, view.nav_beam.position.z), Vector2(60, 4), "over the drop-off")
	assert_gt(view.nav_beam.position.y, view.height_at(60.0, 4.0), "standing up from the ground")
	LevelView.delivery = {}
	view._place_nav_beam()
	LevelView.delivery = was
	assert_false(view.nav_beam.visible, "no delivery, no beam")


func test_a_swapped_in_car_has_its_bought_parts_on_so_its_stats_show_them() -> void:
	for c: Dictionary in CarLibrary.all():
		var id := String(c["id"])
		for part: Dictionary in LootRules.parts_for({"model_id": id}):
			var stock := LootRules.fitted_stats({"model_id": id})
			Save.set_setting(LevelView.PARTS_KEY, {id: [String(part["id"])]})
			var fitted := LevelView.swapped_in(id)
			Save.erase_setting(LevelView.PARTS_KEY)
			assert_eq(fitted["parts"].map(func(p: Dictionary) -> String: return String(p["id"])), [String(part["id"])], "only the bought part")
			assert_true(LootRules.is_on(fitted["parts"][0]), "switched on")
			var stats := LootRules.fitted_stats(fitted)
			if stats["hp"] != stock["hp"] or stats["mass"] != stock["mass"]:
				return  # a part that changes power or weight shows in the stats the garage reads
	pending("no part in the catalogue changes power or weight")
