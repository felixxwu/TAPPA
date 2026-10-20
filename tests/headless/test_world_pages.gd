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
