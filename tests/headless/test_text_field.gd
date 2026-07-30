extends GutTest
# TextField + the MenuNav support it needed (see features/menus.md › "Text input").
#
# This is the project's first text input, and it lands in a menu system driven by
# bare letter keys (WASD) and Esc/B. These tests pin the two things that make
# those coexist: a text field is reachable by keyboard/gamepad at all, and the
# rest of the game can tell when the player is typing.

var _root: Control


func before_each() -> void:
	_root = Control.new()
	add_child_autofree(_root)


func after_each() -> void:
	# Never leave a focused field behind: is_text_editing() is global state, and a
	# leaked focus would silently disable menu input for every later test.
	var focused := get_tree().root.get_viewport().gui_get_focus_owner()
	if focused != null:
		focused.release_focus()


func test_menu_nav_makes_a_text_field_focusable() -> void:
	# MenuNav's walk originally covered only buttons and sliders, so a LineEdit
	# would have been unreachable without a mouse.
	var field := TextField.new("Email")
	_root.add_child(field)
	field.line.focus_mode = Control.FOCUS_NONE  # pretend it was never set up
	MenuNav.attach(_root)
	assert_eq(field.line.focus_mode, Control.FOCUS_ALL,
		"a form must be fillable with a keyboard or gamepad alone")


func test_is_text_editing_is_false_with_nothing_focused() -> void:
	assert_false(MenuNav.is_text_editing())


func test_is_text_editing_is_true_only_while_a_field_has_focus() -> void:
	var field := TextField.new("Email")
	_root.add_child(field)
	var button := Button.new()
	button.focus_mode = Control.FOCUS_ALL
	_root.add_child(button)

	field.line.grab_focus()
	assert_true(MenuNav.is_text_editing(), "typing into a field must suppress menu keys")

	button.grab_focus()
	assert_false(MenuNav.is_text_editing(), "a focused button is not text entry")


func test_wire_column_links_neighbours_top_to_bottom() -> void:
	# Up/down must LEAVE a text field (left/right belong to the caret), so the
	# vertical neighbours are wired explicitly rather than left to Godot's search.
	var first := TextField.new("Email")
	var second := TextField.new("Password", "", true)
	var submit := Button.new()
	submit.focus_mode = Control.FOCUS_ALL
	_root.add_child(first)
	_root.add_child(second)
	_root.add_child(submit)

	TextField.wire_column([first, second, submit])

	assert_eq(first.line.get_node(first.line.focus_neighbor_bottom), second.line)
	assert_eq(second.line.get_node(second.line.focus_neighbor_top), first.line)
	assert_eq(second.line.get_node(second.line.focus_neighbor_bottom), submit)


func test_the_ends_of_a_column_do_not_wrap() -> void:
	# Wrapping would make "down" at the bottom jump back to the top, which reads
	# as the cursor teleporting.
	var first := TextField.new("Email")
	var second := TextField.new("Password", "", true)
	_root.add_child(first)
	_root.add_child(second)
	TextField.wire_column([first, second])
	assert_eq(first.line.get_node(first.line.focus_neighbor_top), first.line)
	assert_eq(second.line.get_node(second.line.focus_neighbor_bottom), second.line)


func test_a_password_field_is_masked() -> void:
	var field := TextField.new("Password", "", true)
	_root.add_child(field)
	assert_true(field.line.secret)
	field.set_secret(false)
	assert_false(field.line.secret, "the show/hide toggle must actually unmask")


func test_text_is_trimmed() -> void:
	# Copy-pasted email addresses routinely carry a trailing space, which the
	# server rejects with an unhelpful error.
	var field := TextField.new("Email")
	_root.add_child(field)
	field.set_text("  player@example.com  ")
	assert_eq(field.text(), "player@example.com")


func test_submitting_a_field_emits_submitted() -> void:
	var field := TextField.new("Email")
	_root.add_child(field)
	watch_signals(field)
	field.line.text_submitted.emit("anything")
	assert_signal_emitted(field, "submitted", "Enter must submit the form")
