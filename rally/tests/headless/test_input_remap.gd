extends GutTest
# Key/controller rebinding (features/controls.md): InputRemap patches the global
# InputMap from saved overrides and is the model behind the settings "Key bindings"
# page. These tests cover the rebind/reset/persist API and the SettingsMenu UI flow.
#
# Every test restores the project.godot defaults in after_each (InputRemap mutates
# the GLOBAL InputMap, which would otherwise leak into the driving tests — e.g. W no
# longer accelerating), and the Save profile is redirected to a throwaway file so
# real progress is untouched.

const TEST_PATH := "user://test_input_remap_profile.json"

var _save: Node


func before_all() -> void:
	_save = get_node("/root/Save")
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.load_or_new()
	InputRemap.reset_defaults()


func after_each() -> void:
	# Never leak a rebinding into the next test or another script's driving tests.
	InputRemap.reset_defaults()


func after_all() -> void:
	InputRemap.reset_defaults()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	_save.load_or_new()
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


# --- InputRemap model --------------------------------------------------------

func test_actions_are_all_real_input_map_actions() -> void:
	for entry in InputRemap.ACTIONS:
		assert_true(InputMap.has_action(entry["action"]),
			"rebindable action '%s' exists in the input map" % entry["action"])


func test_rebind_keyboard_replaces_only_the_keyboard_slot() -> void:
	var key := InputEventKey.new()
	key.physical_keycode = KEY_K
	assert_true(InputRemap.rebind("accelerate", InputRemap.SLOT_KEYBOARD, key),
		"rebinding the keyboard slot succeeds")

	var bound := InputRemap.current_event("accelerate", InputRemap.SLOT_KEYBOARD) as InputEventKey
	assert_not_null(bound, "the keyboard slot is now a key")
	assert_eq(bound.physical_keycode, KEY_K, "accelerate is now on K")
	# The controller binding (RT) is untouched — only the keyboard slot changed.
	var pad := InputRemap.current_event("accelerate", InputRemap.SLOT_CONTROLLER)
	assert_true(pad is InputEventJoypadMotion, "the controller trigger is still bound")


func test_rebind_controller_replaces_only_the_controller_slot() -> void:
	var button := InputEventJoypadButton.new()
	button.button_index = JOY_BUTTON_Y
	assert_true(InputRemap.rebind("handbrake", InputRemap.SLOT_CONTROLLER, button),
		"rebinding the controller slot succeeds")

	var bound := InputRemap.current_event("handbrake", InputRemap.SLOT_CONTROLLER) as InputEventJoypadButton
	assert_not_null(bound, "the controller slot is now a button")
	assert_eq(bound.button_index, JOY_BUTTON_Y, "handbrake is now on Y")
	# Keyboard (Space) is untouched.
	var key := InputRemap.current_event("handbrake", InputRemap.SLOT_KEYBOARD) as InputEventKey
	assert_eq(key.physical_keycode, KEY_SPACE, "the handbrake key is still Space")


func test_rebind_rejects_a_slot_mismatch() -> void:
	var key := InputEventKey.new()
	key.physical_keycode = KEY_J
	assert_false(InputRemap.rebind("accelerate", InputRemap.SLOT_CONTROLLER, key),
		"a key can't be assigned to the controller slot")


func test_reset_restores_the_defaults() -> void:
	var key := InputEventKey.new()
	key.physical_keycode = KEY_K
	InputRemap.rebind("accelerate", InputRemap.SLOT_KEYBOARD, key)
	InputRemap.reset_defaults()

	var bound := InputRemap.current_event("accelerate", InputRemap.SLOT_KEYBOARD) as InputEventKey
	assert_eq(bound.physical_keycode, KEY_W, "reset puts accelerate back on W")


func test_overrides_persist_and_reapply() -> void:
	var key := InputEventKey.new()
	key.physical_keycode = KEY_K
	InputRemap.rebind("accelerate", InputRemap.SLOT_KEYBOARD, key)

	# The override is stored in the save bag...
	var bag: Dictionary = _save.get_setting(InputRemap.SETTING_KEY, {})
	assert_true(bag.has("accelerate"), "the override is persisted under the action")
	# ...and re-applying it (as on a reload) keeps the binding.
	InputRemap.apply_saved()
	var bound := InputRemap.current_event("accelerate", InputRemap.SLOT_KEYBOARD) as InputEventKey
	assert_eq(bound.physical_keycode, KEY_K, "the saved binding survives a re-apply")


func test_describe_produces_human_labels() -> void:
	var key := InputEventKey.new()
	key.physical_keycode = KEY_W
	assert_eq(InputRemap.describe(key), "W", "a key reads as its label")

	var button := InputEventJoypadButton.new()
	button.button_index = JOY_BUTTON_A
	assert_eq(InputRemap.describe(button), "A / Cross", "a face button reads with both glyphs")

	var motion := InputEventJoypadMotion.new()
	motion.axis = JOY_AXIS_TRIGGER_RIGHT
	motion.axis_value = 1.0
	assert_eq(InputRemap.describe(motion), "Right Trigger", "a trigger axis reads by name")

	assert_eq(InputRemap.describe(null), "Unbound", "an empty slot reads as Unbound")


# --- SettingsMenu "Key bindings" page ----------------------------------------

func test_settings_page_has_a_row_per_action() -> void:
	var menu := SettingsMenu.new()
	add_child(menu)
	await get_tree().process_frame
	assert_eq(menu.controls_rows.size(), InputRemap.ACTIONS.size(),
		"one key-binding row per rebindable action")
	menu.free()


func test_settings_page_captures_a_key_press() -> void:
	var menu := SettingsMenu.new()
	add_child(menu)
	await get_tree().process_frame
	menu.show_controls()

	# Start listening for accelerate's keyboard slot, then feed a key press.
	var row: Dictionary = menu.controls_rows[0]
	menu._begin_listen("accelerate", InputRemap.SLOT_KEYBOARD, row["keyboard_button"])
	var press := InputEventKey.new()
	press.physical_keycode = KEY_K
	press.pressed = true
	menu._input(press)

	assert_eq((InputRemap.current_event("accelerate", InputRemap.SLOT_KEYBOARD) as InputEventKey).physical_keycode,
		KEY_K, "the captured key is assigned to the action")
	assert_true(menu._listening.is_empty(), "capture ends the listening state")
	menu.free()


func test_settings_page_escape_cancels_the_capture() -> void:
	var menu := SettingsMenu.new()
	add_child(menu)
	await get_tree().process_frame
	menu.show_controls()

	var row: Dictionary = menu.controls_rows[0]
	menu._begin_listen("accelerate", InputRemap.SLOT_KEYBOARD, row["keyboard_button"])
	var esc := InputEventKey.new()
	esc.physical_keycode = KEY_ESCAPE
	esc.pressed = true
	menu._input(esc)

	assert_true(menu._listening.is_empty(), "Esc ends the listening state")
	assert_eq((InputRemap.current_event("accelerate", InputRemap.SLOT_KEYBOARD) as InputEventKey).physical_keycode,
		KEY_W, "Esc leaves accelerate on its default W")
	menu.free()
