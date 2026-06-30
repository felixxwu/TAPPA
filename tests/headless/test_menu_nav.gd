extends GutTest
# Keyboard / gamepad menu navigation (features/menus.md → "Menu navigation"). Flat
# menus drive a cursor with Godot's native focus (focus_mode = FOCUS_ALL + the
# engine's ui_up/ui_down/ui_accept), so the theme's focus stylebox paints the cursor
# and arrow keys / D-pad / left-stick all work for free; the diegetic HQ stations keep
# their spatial menu_* handlers (covered in test_menu_flow.gd). This file checks the
# shared pieces: the input actions exist, and the shared SettingsMenu focuses its rows
# and steps back a level at a time.

const TEST_PATH := "user://test_menu_nav_profile.json"

var _save: Node


func before_each() -> void:
	_save = get_node("/root/Save")
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.load_or_new()


func after_each() -> void:
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


# The six directional menu actions are all mapped (up/down were added for the HQ
# hub + map-table cursors alongside the pre-existing left/right/select/back).
func test_menu_input_actions_exist() -> void:
	for action in ["menu_up", "menu_down", "menu_left", "menu_right", "menu_select", "menu_back"]:
		assert_true(InputMap.has_action(action), "the %s action is mapped" % action)


# The shared SettingsMenu rows are focusable, drilling into a category lands the
# cursor on that page's first row, and go_back() steps sub-page → list → (false).
func test_settings_menu_is_keyboard_navigable() -> void:
	var sm := SettingsMenu.new()
	add_child_autofree(sm)
	await get_tree().process_frame  # _ready builds the pages + shows the list

	assert_eq(sm.camera_rows[0]["button"].focus_mode, Control.FOCUS_ALL,
		"settings rows are focusable for keyboard/gamepad")

	# Drilling into a category focuses that page's first row (deferred grab).
	sm.show_camera()
	await get_tree().process_frame
	assert_eq(sm.get_viewport().gui_get_focus_owner(), sm.camera_rows[0]["button"],
		"opening the Camera page focuses its first row")

	# Back steps out one level: sub-page → list (consumed), then list → not consumed
	# (so the host closes Settings / runs its own bottom action).
	assert_true(sm.go_back(), "go_back from a sub-page is consumed")
	assert_true(sm.at_root(), "go_back returns to the category list")
	assert_false(sm.go_back(), "go_back at the root is left to the host")
