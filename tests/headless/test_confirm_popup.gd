# tests/headless/test_confirm_popup.gd
extends GutTest

var _host: Node

func before_each() -> void:
	_host = Node.new()
	add_child_autofree(_host)

func _actions_with_flag(flag: Array) -> Array:
	# flag is a shared 1-element array the callback writes into, so the test can
	# observe which callback fired.
	return [
		{"label": "Yes", "callback": func() -> void: flag[0] = "yes"},
		{"label": "No", "callback": func() -> void: flag[0] = "no"},
	]

func test_open_builds_one_button_per_action() -> void:
	var popup := ConfirmPopup.open(_host, "T", "B", _actions_with_flag([""]))
	var buttons := popup.find_children("*", "Button", true, false)
	assert_eq(buttons.size(), 2, "one button per action")

func test_pressing_action_fires_its_callback_and_dismisses() -> void:
	var flag := [""]
	var popup := ConfirmPopup.open(_host, "T", "B", _actions_with_flag(flag))
	var buttons := popup.find_children("*", "Button", true, false)
	(buttons[0] as Button).pressed.emit()
	assert_eq(flag[0], "yes", "action 0 callback fired")
	await get_tree().process_frame
	assert_false(is_instance_valid(popup), "popup dismissed after press")

func test_disabled_action_button_is_disabled() -> void:
	var actions := [
		{"label": "Go", "callback": Callable(), "disabled": true},
		{"label": "Cancel", "callback": Callable()},
	]
	var popup := ConfirmPopup.open(_host, "T", "B", actions)
	var buttons := popup.find_children("*", "Button", true, false)
	assert_true((buttons[0] as Button).disabled, "disabled flag honoured")

func test_back_index_defaults_to_last_action() -> void:
	var flag := [""]
	var popup := ConfirmPopup.open(_host, "T", "B", _actions_with_flag(flag))
	popup.trigger_back()
	assert_eq(flag[0], "no", "Back fires the last action by default")
