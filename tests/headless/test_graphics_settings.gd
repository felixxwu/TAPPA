extends GutTest
# GraphicsSettings (features/settings.md): the Settings → Graphics choices, saved in the profile and
# laid over GameConfig when the level loads. Runs against a throwaway Save profile.

const TEST_PATH := "user://test_graphics_settings_profile.json"

var _save: Node


class FakeLevel extends Node:
	var reloads := 0

	func reload_for_graphics() -> void:
		reloads += 1


func before_each() -> void:
	Config.reset()
	_save = get_node("/root/Save")
	_clean()
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.load_or_new()


func after_each() -> void:
	GraphicsSettings.reset()
	GraphicsSettings.apply(Config.data)
	_clean()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	Config.reset()


func _clean() -> void:
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


func _snapshot() -> Dictionary:
	var out := {}
	for o in GraphicsSettings.OPTIONS:
		for f in o["fields"]:
			out[f] = Config.data.get(f)
	return out


func test_untouched_options_keep_game_config_values() -> void:
	var before := _snapshot()
	GraphicsSettings.apply(Config.data)
	assert_eq(_snapshot(), before)


func test_every_choice_applies_without_compounding_and_reset_restores() -> void:
	var authored := _snapshot()
	for o in GraphicsSettings.OPTIONS:
		var key := String(o["key"])
		for _i in o["choices"].size():
			GraphicsSettings.cycle(key)
			GraphicsSettings.apply(Config.data)
			GraphicsSettings.apply(Config.data)  # a second load must not scale the value again
			var v: Variant = o["choices"][GraphicsSettings.choice_index(key)][1]
			for f in o["fields"]:
				var want: Variant = v if v is bool else authored[f] * float(v)
				assert_almost_eq(float(Config.data.get(f)), float(want), 1.0, "%s → %s" % [key, f])
	GraphicsSettings.reset()
	GraphicsSettings.apply(Config.data)
	assert_eq(_snapshot(), authored, "reset puts every field back to GameConfig")


func test_default_choice_matches_game_config() -> void:
	for o in GraphicsSettings.OPTIONS:
		var v: Variant = o["choices"][GraphicsSettings.choice_index(o["key"])][1]
		if v is bool:
			assert_eq(v, bool(Config.data.get(o["fields"][0])), o["key"])
		else:
			assert_almost_eq(float(v), 1.0, 0.001, o["key"])


func test_menu_rows_cycle_save_and_reload_the_level_on_leaving() -> void:
	var level := FakeLevel.new()
	level.add_to_group(LevelView.GROUP)
	add_child_autofree(level)
	var menu := SettingsMenu.new()
	add_child_autofree(menu)
	menu.show_page("graphics")
	await get_tree().process_frame
	assert_eq(menu.graphics_rows.size(), GraphicsSettings.OPTIONS.size(), "a row per option")
	assert_true(menu.get_viewport().gui_get_focus_owner() in menu.graphics_rows.values(),
		"keyboard/gamepad focus lands on the first row")
	var key := String(GraphicsSettings.OPTIONS[0]["key"])
	var button: Button = menu.graphics_rows[key]
	var label := button.text
	button.pressed.emit()
	assert_ne(button.text, label, "the row shows the new choice")
	assert_true(Save.get_setting(GraphicsSettings.SETTING_KEY, {}).has(key), "and it is saved")
	assert_eq(level.reloads, 0, "nothing reloads while still on the page")
	menu.go_back()
	assert_eq(level.reloads, 0, "the reload waits until the Back press has been handled")
	await get_tree().process_frame
	assert_eq(level.reloads, 1, "leaving the page rebuilds the live level")
	menu.show_page("graphics")
	menu.reset_graphics()
	assert_eq(button.text, label, "reset shows the default again")
	assert_true(Save.get_setting(GraphicsSettings.SETTING_KEY, {}).is_empty())
