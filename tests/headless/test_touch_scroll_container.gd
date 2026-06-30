extends GutTest
# TouchScrollContainer drag-scrolls even when the gesture starts on a child Button —
# the fix for "lists don't scroll if the first touch lands on a list item". We drive
# its `_input` directly with synthetic mouse events (touch arrives as mouse via
# emulate_mouse_from_touch), the same way the map-table pan test does.

const DEADZONE := 10.0  # TouchScrollContainer.DRAG_DEADZONE


func _make_scroll(rows: int) -> TouchScrollContainer:
	var scroll := TouchScrollContainer.new()
	scroll.position = Vector2.ZERO
	scroll.size = Vector2(200, 100)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(content)
	for i in rows:
		var b := Button.new()
		b.text = "Row %d" % i
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(0, 60)
		content.add_child(b)
	add_child_autofree(scroll)
	return scroll


func _press(pos: Vector2) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = true
	e.position = pos
	return e


func _release(pos: Vector2) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = false
	e.position = pos
	return e


func _move(pos: Vector2) -> InputEventMouseMotion:
	var e := InputEventMouseMotion.new()
	e.position = pos
	return e


func test_overflowing_list_drag_scrolls_starting_on_a_row() -> void:
	# Six 60px rows in a 100px viewport overflow, so a drag should scroll.
	var scroll := _make_scroll(6)
	await get_tree().process_frame
	assert_true(scroll._has_overflow(), "a list taller than its box can scroll")
	# Press on a row, drag up past the deadzone: the list scrolls down.
	scroll._input(_press(Vector2(100, 80)))
	scroll._input(_move(Vector2(100, 80 - (DEADZONE + 40))))
	assert_gt(scroll.scroll_vertical, 0, "dragging on a row scrolls the list")
	scroll._input(_release(Vector2(100, 30)))
	assert_false(scroll._dragging, "the gesture clears on release")


func test_small_press_is_left_alone_as_a_tap() -> void:
	# A press that barely moves stays a tap: the container does not claim it as a
	# drag, so the child Button's own click is free to fire.
	var scroll := _make_scroll(6)
	await get_tree().process_frame
	scroll._input(_press(Vector2(100, 80)))
	scroll._input(_move(Vector2(100, 80 - (DEADZONE - 4))))  # under the deadzone
	assert_false(scroll._dragging, "a sub-deadzone press is not a drag")
	assert_eq(scroll.scroll_vertical, 0, "a tap does not scroll the list")


func test_short_list_does_not_hijack_input() -> void:
	# One row fits well within the box: there is nothing to scroll, so the container
	# stays out of the way (the row behaves like a normal button).
	var scroll := _make_scroll(1)
	await get_tree().process_frame
	assert_false(scroll._has_overflow(), "a list that fits has no overflow")
	scroll._input(_press(Vector2(100, 30)))
	assert_false(scroll._pressing, "no gesture is armed when there is nothing to scroll")
