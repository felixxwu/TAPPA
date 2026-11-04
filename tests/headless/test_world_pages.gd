extends GutTest
# WorldPages' Stats page (scripts/free_roam/world_pages.gd): keyboard / gamepad navigation.
# Cheap setup — WorldPages with a bare (never-in-tree) TerrainStreamer carrying default
# FreeRoamSettings; show_stats only reads the ring count from it. The map flow is covered in
# test_world_session.gd.

var _pages: WorldPages
var _closed := [0]


func before_each() -> void:
	var streamer := TerrainStreamer.new()
	streamer.settings = FreeRoamSettings.new()
	autofree(streamer)
	_pages = WorldPages.new()
	_pages.streamer = streamer
	add_child_autofree(_pages)
	_closed[0] = 0


func _press(action: String) -> void:
	var e := InputEventAction.new()
	e.action = action
	e.pressed = true
	MenuNav.of(_pages._page)._unhandled_input(e)


func _open_stats() -> void:
	_pages.show_stats(func() -> void: _closed[0] += 1)
	await get_tree().process_frame
	await get_tree().process_frame


func test_stats_focus_starts_on_the_card_list() -> void:
	await _open_stats()
	assert_true(_pages.is_open())
	var owner := _pages.get_viewport().gui_get_focus_owner()
	assert_true(owner == _pages.cards() or _pages.cards().is_ancestor_of(owner),
		"the cursor starts on the stat cards")


func test_stats_down_reaches_back_and_enter_closes() -> void:
	await _open_stats()
	_press("menu_down")
	var back := _pages._back_button
	assert_eq(_pages.get_viewport().gui_get_focus_owner(), back, "down from the cards reaches Back")
	back.pressed.emit()
	assert_eq(_closed[0], 1, "Back calls on_close")


func test_stats_ui_cancel_closes_and_calls_on_close() -> void:
	await _open_stats()
	_press("ui_cancel")
	assert_false(_pages.is_open(), "cancel closes the page")
	assert_eq(_closed[0], 1, "and hands control back via on_close")


func test_the_map_key_leaves_an_open_confirm_alone() -> void:
	await _open_stats()
	_pages._canvas = autofree(WorldPages.MapCanvas.new())
	ConfirmPopup.open(_pages, "Leave your money?", "", [{"label": "Cancel", "callback": Callable()}], 0, 0)
	var e := InputEventAction.new()
	e.action = "toggle_map"
	e.pressed = true
	_pages._unhandled_input(e)
	assert_true(_pages.is_open(), "closing would unpause the game under the armed popup")
	assert_eq(_closed[0], 0)


# A travel refused because the car is wrecked must not read as a travel (the host would resume
# driving, or close the pause menu, under the wreck page).
func test_a_travel_while_wrecked_does_nothing() -> void:
	var rest: RestStops = autofree(RestStops.new())
	rest.is_wrecked = true
	_pages.rest_stops = rest
	_pages.travelled = false
	_pages._travel_to(0, false)
	assert_false(_pages.travelled)


# The map is sized to fill the page, so it must fit the body exactly rather than scroll.
func test_the_map_fits_without_scrolling() -> void:
	var rest: RestStops = autofree(RestStops.new())
	rest.streamer = _pages.streamer
	rest.car = add_child_autofree(VehicleBody3D.new())
	_pages.rest_stops = rest
	_pages.streamer.terrain.setup(_pages.streamer.settings, null)
	_pages.show_map(func() -> void: pass)
	await get_tree().process_frame
	await get_tree().process_frame
	var page: MenuPage = _pages._page
	assert_true(page._scroll.custom_minimum_size.y >= page._body.get_combined_minimum_size().y,
		"the map and its target line fit the body without a scrollbar")


# The map's terrain picture (MapTerrain.paint): the sea is left see-through, lakes are flat lake
# colour, and land is opaque and shaded.
func test_the_map_terrain_leaves_the_sea_clear_and_paints_lakes_flat() -> void:
	var heights := PackedFloat32Array([0.0, -3.0, 10.0, 40.0])
	var kind := PackedByteArray([0, 2, 1, 1])
	var ring := PackedByteArray([0, 0, 0, 1])
	var img := MapTerrain.paint(heights, kind, ring, 2, 2, 50.0)
	assert_eq(img.get_pixel(0, 0).a, 0.0, "the sea shows the map's background")
	assert_true(img.get_pixel(1, 0).is_equal_approx(Config.data.map_lake_color), "a lake is flat lake colour")
	assert_eq(img.get_pixel(0, 1).a, 1.0, "land is opaque")
	assert_ne(img.get_pixel(0, 1), img.get_pixel(1, 1), "land differs by ring and height")


# Drawn a tile at a time and cached: the tiles cover the view asked for, and asking again (or
# for the view a little moved) draws nothing new.
func test_the_map_terrain_is_drawn_in_tiles_and_kept() -> void:
	var s := FreeRoamSettings.new()
	s.island_radius_m = 3000.0
	var net := RoadNetwork.new()
	var terrain := RoadTerrain.new()
	terrain.setup(s, net)
	net.build(s, terrain)
	var mt := MapTerrain.new(terrain, s.island_radius_m)
	var view := Rect2(-1000, -1000, 2000, 2000)
	mt.request(view, 40)
	var steps := 1
	while not mt.step(0):
		steps += 1
	assert_gt(steps, 1, "a zero budget draws one tile per step")
	var covered := Rect2()
	for tile: Array in mt.drawn():
		covered = tile[0] if covered.size == Vector2.ZERO else covered.merge(tile[0])
	assert_true(covered.encloses(view), "the tiles cover the view")
	mt.request(Rect2(view.position + Vector2(10, 10), view.size), 40)
	assert_true(mt.done(), "a slightly moved view reuses the cached tiles")
