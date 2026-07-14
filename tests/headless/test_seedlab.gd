extends GutTest
# The dev seed-lab page is reachable, renders a preview for a (seed, water level)
# combination, and is keyboard/gamepad navigable (a control takes focus).

var _menu

func before_each() -> void:
	Config.reset()
	_menu = load("res://scripts/settings_menu.gd").new()
	add_child_autofree(_menu)
	await get_tree().process_frame

func after_each() -> void:
	Config.reset()

func test_seedlab_reachable_and_renders() -> void:
	assert_true(_menu.has_method("show_seedlab"), "seed lab page reachable")
	_menu.show_seedlab()
	# show_seedlab kicks off an async regenerate; let it complete.
	await get_tree().process_frame
	await get_tree().process_frame
	assert_true(_menu._seedlab_preview != null, "seed lab has a preview widget")

func test_seedlab_is_navigable() -> void:
	_menu.show_seedlab()
	await get_tree().process_frame
	_menu.focus_current_page()
	await get_tree().process_frame
	var focused: Control = _menu.get_viewport().gui_get_focus_owner()
	assert_not_null(focused, "a control is focused on the seed-lab page")
