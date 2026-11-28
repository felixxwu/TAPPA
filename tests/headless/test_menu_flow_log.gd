extends GutTest
# The menu-flow replay's log line (benchmark/menu_flow.gd → MenuFlow.line), on a hand-built page.

var _layer: CanvasLayer


func before_each() -> void:
	_layer = CanvasLayer.new()
	add_child_autofree(_layer)


func test_page_id_is_the_title_and_script_class() -> void:
	var page := MenuPage.new({"title": "Settings"})
	page.name = "SecretPageNode"
	_layer.add_child(page)
	assert_eq(MenuFlow.page_id(page), "%s (MenuPage)" % page.title_label().text)


func test_page_id_without_a_menu_page_falls_back_to_the_first_label() -> void:
	var root := Control.new()
	_layer.add_child(root)
	var title := UITheme.label("Wrecked")
	root.add_child(title)
	assert_eq(MenuFlow.page_id(root), "%s (Control)" % title.text)


func test_focus_label_is_the_focused_text_or_the_selected_card() -> void:
	var button := Button.new()
	button.text = "Resume"
	_layer.add_child(button)
	assert_eq(MenuFlow.focus_label(button), "Resume")
	var carousel := CardCarousel.new()
	carousel.set_meta("entries", [{"title": "Map"}, {"title": "Garage"}])
	assert_eq(MenuFlow.focus_label(carousel), "Map", "a card list reports its selected card's title")
	carousel.free()
	assert_eq(MenuFlow.focus_label(null), "")


func test_boxes_round_to_whole_pixels_and_skip_hidden_widgets() -> void:
	var root := Control.new()
	_layer.add_child(root)
	var label := Label.new()
	label.text = "Volume"
	root.add_child(label)
	label.position = Vector2(10.4, 20.6)
	label.size = Vector2(30.5, 36.2)
	var hidden := Button.new()
	hidden.text = "Hidden"
	hidden.visible = false
	root.add_child(hidden)
	await get_tree().process_frame
	var by_label := {}
	for b: Array in MenuFlow.boxes(root):
		by_label[b[0]] = b[1]
	assert_true(by_label.has("Volume"))
	var r: Array = by_label.get("Volume", [])
	for v in r:
		assert_eq(v, roundf(v), "every box edge is a whole pixel")
	assert_eq(r.slice(0, 2), [10, 21])
	assert_false(by_label.has("Hidden"), "a hidden widget has no box")


func test_a_log_line_names_no_node_paths() -> void:
	var page := MenuPage.new({"title": "Pause"})
	page.name = "SecretPageNode"
	_layer.add_child(page)
	var button := Button.new()
	button.name = "SecretButtonNode"
	button.text = "Quit"
	page.body().add_child(button)
	await get_tree().process_frame
	var row := MenuFlow.line(page, button, MenuFlow.diff({"paused": false}, {"paused": true}))
	assert_eq(row["focus"], "Quit")
	assert_eq(row["changed"], {"paused": [false, true]})
	var text := JSON.stringify(row)
	assert_false(text.contains("Secret"), "node names would make the log break on a rename")
	assert_false(text.contains("/root"), "no node paths in the log")


func test_diff_reports_added_removed_and_changed_keys_only() -> void:
	var d := MenuFlow.diff({"a": 1, "b": 2, "c": 3}, {"a": 1, "b": 5, "d": 4})
	assert_eq(d, {"b": [2, 5], "c": [3, null], "d": [null, 4]})


func test_gamepad_binding_falls_back_to_the_keyboard() -> void:
	InputMap.add_action("menu_flow_test_only")
	var key := InputEventKey.new()
	key.keycode = KEY_F9
	InputMap.action_add_event("menu_flow_test_only", key)
	assert_true(MenuFlow.binding("menu_flow_test_only", "pad") is InputEventKey, "no pad binding: use the key")
	var pad := InputEventJoypadButton.new()
	pad.button_index = JOY_BUTTON_X
	InputMap.action_add_event("menu_flow_test_only", pad)
	assert_true(MenuFlow.binding("menu_flow_test_only", "pad") is InputEventJoypadButton)
	assert_true(MenuFlow.binding("menu_flow_test_only", "key") is InputEventKey)
	InputMap.erase_action("menu_flow_test_only")
