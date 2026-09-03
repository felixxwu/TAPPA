extends GutTest
# SettingsMenu (features/menus.md): the shared settings panel, exercised through the
# pause-menu / title-screen hosts. Runs against a throwaway Save profile.
#
# The dev "Complete rally" shortcut this file used to cover was RallySession-gated
# (win the active rally on the spot: 0 ms every event -> P1 -> podium). Deleted along
# with RallySession and the rival field it served (todo/roguelike-pivot.md decision 5).

const TEST_PATH := "user://test_settings_menu_profile.json"
const CarFixtures = preload("res://tests/headless/car_fixtures.gd")

var _save: Node


func before_each() -> void:
	Config.reset()
	CarFixtures.install()
	RallyFixtures.install()
	_save = get_node("/root/Save")
	_clean()
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.load_or_new()


func after_each() -> void:
	get_tree().paused = false
	_clean()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	Config.reset()
	CarFixtures.restore()
	RallyFixtures.restore()


func _clean() -> void:
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


# Build a SettingsMenu in the tree and return it (its _ready builds the pages).
func _make_menu() -> SettingsMenu:
	var menu := SettingsMenu.new()
	add_child_autofree(menu)
	return menu


# Find the button on the dev page whose text begins with `prefix` (case-insensitive).
func _dev_button(menu: SettingsMenu, prefix: String) -> Button:
	for child in menu._dev_page.get_children():
		if child is Button and String(child.text).to_lower().begins_with(prefix.to_lower()):
			return child
	return null


# Find the button on the Reset progress page whose text begins with `prefix`.
func _reset_button(menu: SettingsMenu, prefix: String) -> Button:
	for child in menu._reset_page.get_children():
		if child is Button and String(child.text).to_lower().begins_with(prefix.to_lower()):
			return child
	return null


# The CATEGORY buttons on the list page, joined for substring checks.
func _category_labels(menu: SettingsMenu) -> String:
	var labels: Array = []
	for node in menu._list_page.find_children("*", "Button", true, false):
		labels.append((node as Button).text)
	return "|".join(PackedStringArray(labels))


# Find the popup's action button by label (case-insensitive), so the tests press
# what the player presses rather than reaching for an index.
func _popup_button(popup: ConfirmPopup, label: String) -> Button:
	for node in popup.find_children("*", "Button", true, false):
		if String((node as Button).text).to_lower() == label.to_lower():
			return node
	return null


# Find the FPS row whose stored cap == `value`.
func _fps_row(menu: SettingsMenu, value: int) -> Dictionary:
	for row in menu.fps_rows:
		if int(row["key"]) == value:
			return row
	return {}


# The Display page offers exactly the three FpsSetting options (30 / 60 / uncapped),
# and nothing is persisted until the player picks — resolve() reports the platform
# default (headless is neither web nor touch, so 60).
func test_fps_rows_match_options_and_default_unset() -> void:
	var menu := _make_menu()
	assert_eq(menu.fps_rows.size(), FpsSetting.OPTIONS.size(),
		"one Display row per FpsSetting option")
	assert_null(_save.get_setting(FpsSetting.SETTING_KEY, null),
		"no cap saved until the player picks one")
	assert_eq(FpsSetting.resolve(), FpsSetting.default_cap(),
		"unset -> the platform default cap")


# Pressing an FPS row persists that cap under FpsSetting.SETTING_KEY, so resolve()
# (what world._ready reads) returns the chosen value — including uncapped (0).
func test_fps_row_press_persists_the_cap() -> void:
	var menu := _make_menu()
	var uncapped := _fps_row(menu, FpsSetting.UNCAPPED)
	assert_false(uncapped.is_empty(), "an uncapped row exists")
	uncapped["button"].pressed.emit()
	assert_eq(int(_save.get_setting(FpsSetting.SETTING_KEY, -1)), FpsSetting.UNCAPPED,
		"picking Uncapped saves 0")
	assert_eq(FpsSetting.resolve(), FpsSetting.UNCAPPED, "resolve() honours the saved choice")

	var thirty := _fps_row(menu, 30)
	thirty["button"].pressed.emit()
	assert_eq(int(_save.get_setting(FpsSetting.SETTING_KEY, -1)), 30, "re-picking 30 saves 30")
	assert_eq(FpsSetting.resolve(), 30, "resolve() follows the latest pick")


# Is there a focusable button anywhere on the category list whose label mentions `text`?
func _list_has_button(menu: SettingsMenu, text: String) -> bool:
	for node in menu._list_page.find_children("*", "Button", true, false):
		var button := node as Button
		if String(button.text).to_lower().contains(text.to_lower()) \
				and button.focus_mode == Control.FOCUS_ALL:
			return true
	return false


# Find the Gearbox row whose stored mode == `value`.
func _gearbox_row(menu: SettingsMenu, value: int) -> Dictionary:
	for row in menu.gearbox_rows:
		if int(row["key"]) == value:
			return row
	return {}


# The Gearbox page offers one row per mode, and nothing is persisted until the player
# picks — gearbox_auto() reports the authored GameConfig default while unset.
func test_gearbox_rows_match_options_and_default_unset() -> void:
	var menu := _make_menu()
	assert_eq(menu.gearbox_rows.size(), SettingsMenu.GEARBOX_OPTIONS.size(),
		"one Gearbox row per option")
	assert_null(_save.get_setting(SettingsMenu.GEARBOX_SETTING_KEY, null),
		"no mode saved until the player picks one")
	assert_eq(SettingsMenu.gearbox_auto(), Config.data.auto_gearbox,
		"unset -> the authored GameConfig default")


# Pressing a Gearbox row persists the mode under GEARBOX_SETTING_KEY, and gearbox_auto()
# (what car.gd mirrors onto the live engine) follows the latest pick either way.
func test_gearbox_row_press_persists_the_mode() -> void:
	var menu := _make_menu()
	var manual := _gearbox_row(menu, SettingsMenu.GEARBOX_MANUAL)
	assert_false(manual.is_empty(), "a manual row exists")
	manual["button"].pressed.emit()
	assert_eq(int(_save.get_setting(SettingsMenu.GEARBOX_SETTING_KEY, -1)),
		SettingsMenu.GEARBOX_MANUAL, "picking Manual saves manual")
	assert_false(SettingsMenu.gearbox_auto(), "gearbox_auto() honours the saved choice")

	var auto := _gearbox_row(menu, SettingsMenu.GEARBOX_AUTO)
	assert_false(auto.is_empty(), "an automatic row exists")
	auto["button"].pressed.emit()
	assert_eq(int(_save.get_setting(SettingsMenu.GEARBOX_SETTING_KEY, -1)),
		SettingsMenu.GEARBOX_AUTO, "re-picking Automatic saves automatic")
	assert_true(SettingsMenu.gearbox_auto(), "gearbox_auto() follows the latest pick")


# The saved mode survives a reload of the profile — this is the ONLY way to select
# automatic now that the toggle_gearbox action is gone, so it must persist.
func test_gearbox_mode_survives_a_profile_reload() -> void:
	var menu := _make_menu()
	_gearbox_row(menu, SettingsMenu.GEARBOX_MANUAL)["button"].pressed.emit()
	_save.save_now()  # settings writes are debounced; flush before re-reading the file
	_save.load_or_new()
	assert_false(SettingsMenu.gearbox_auto(), "the mode is read back from the save file")


# Keyboard + gamepad reachability (CLAUDE.md / features/menus.md): the category list
# offers a Gearbox row, the page seats a focus cursor, and every mode row is focusable
# so ui_up/ui_down + ui_accept can pick one without a pointer.
func test_gearbox_page_is_keyboard_and_gamepad_navigable() -> void:
	var menu := _make_menu()
	assert_true(_list_has_button(menu, "gearbox"),
		"the category list has a focusable Gearbox row")
	for row in menu.gearbox_rows:
		assert_eq((row["button"] as Button).focus_mode, Control.FOCUS_ALL,
			"gearbox rows are focusable")
	menu.show_gearbox()
	await get_tree().process_frame
	menu.focus_current_page()
	await get_tree().process_frame
	var focused: Control = menu.get_viewport().gui_get_focus_owner()
	assert_not_null(focused, "a control is focused on the Gearbox page")
	assert_true(menu.gearbox_rows.any(func(r: Dictionary) -> bool: return r["button"] == focused),
		"the cursor lands on a gearbox mode row")
	# Back (gamepad B / Esc) returns to the category list.
	assert_true(menu.go_back(), "Back is consumed by the sub-page")
	assert_true(menu.at_root(), "Back returns to the category list")


# test_add_star_dev_button_credits_one_star DELETED: the "Add 1 star" dev shortcut and
# Save.stars_available/award_stars are gone with the star ledger
# (todo/roguelike-pivot.md decision 21).


# --- Reset progress ----------------------------------------------------------

# Starting over is a PLAYER setting, not dev tooling: the category is offered even
# with the dev pages forced off (the case the always-on default alone can't produce).
func test_reset_progress_category_is_offered_to_players() -> void:
	SettingsMenu.dev_tools_override = 0
	var menu := _make_menu()
	await get_tree().process_frame
	var joined := _category_labels(menu)
	SettingsMenu.dev_tools_override = -1

	assert_string_contains(joined, "RESET PROGRESS",
		"every player can reach the reset page")
	assert_false(joined.contains("DEV"), "while the dev page stays hidden from them")
	assert_not_null(_reset_button(menu, "Wipe all progress"),
		"and the wipe button lives on that page")


# The wipe is irreversible (and reaches the cloud copy), so the button must ASK.
# Pressing it opens the confirm modal and destroys nothing on its own.
func test_wipe_button_asks_before_destroying_anything() -> void:
	_save.grant_car("fx_light_rwd")
	var menu := _make_menu()
	_reset_button(menu, "Wipe all progress").pressed.emit()

	var popup := ConfirmPopup.any_open(get_tree()) as ConfirmPopup
	assert_not_null(popup, "pressing the button raises a confirm modal")
	assert_eq(int(_save.profile["cars"].size()), 1, "and wipes nothing yet")

	# Backing out (Esc / gamepad B routes to the same leftmost Cancel) leaves the save alone.
	popup.trigger_back()
	await get_tree().process_frame
	assert_eq(int(_save.profile["cars"].size()), 1, "cancelling keeps the career")
	assert_null(ConfirmPopup.any_open(get_tree()), "and closes the modal")


# Confirming does the wipe: a fresh new-game profile, and the page reports it.
func test_confirming_the_modal_wipes_the_save() -> void:
	_save.grant_car("fx_light_rwd")
	_save.add_item("fx_consumable")
	var menu := _make_menu()
	_reset_button(menu, "Wipe all progress").pressed.emit()
	var popup := ConfirmPopup.any_open(get_tree()) as ConfirmPopup
	assert_not_null(popup, "setup: the modal is up")

	var confirm := _popup_button(popup, "Wipe everything")
	assert_not_null(confirm, "the modal offers the confirming action")
	confirm.pressed.emit()
	await get_tree().process_frame

	assert_eq(int(_save.profile["cars"].size()), 0, "confirming clears all owned cars")
	assert_true((_save.profile["inventory"] as Dictionary).is_empty(),
		"and the inventory with them")
	assert_string_contains(menu._reset_status.text.to_lower(), "wiped",
		"the page reports what happened")
