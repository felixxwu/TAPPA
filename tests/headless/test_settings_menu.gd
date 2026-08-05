extends GutTest
# SettingsMenu (features/menus.md): the shared settings panel. Most of its rows are
# exercised through the pause-menu / title-screen hosts; this file covers the pieces
# that depend on RallySession state — specifically the DEV "Complete rally" shortcut,
# which is surfaced ONLY while a rally is active and, when pressed, wins the rally on
# the spot (0 ms every event → P1 → podium). Runs against a throwaway Save profile.

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
	RallySession.auto_load_scenes = false
	if RallySession.is_active():
		RallySession.abandon()


func after_each() -> void:
	if RallySession.is_active():
		RallySession.abandon()
	RallySession.auto_load_scenes = true
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


# Start a rally skipping track generation and return the fielded owned-car dict.
func _start_rally() -> void:
	var owned: Dictionary = _save.grant_car("fx_light_rwd")
	RallySession.start_rally(RallyLibrary.by_id("fx_open"), owned, true)
	RallySession._opponent_field = [
		{"name": "Rival", "event_times_ms": [], "dnf": false, "combined_ms": 50000},
	]


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


# The dev "Complete rally" button is hidden when no rally is active (HQ settings).
func test_complete_rally_button_absent_without_a_rally() -> void:
	assert_false(RallySession.is_active(), "no rally active")
	var menu := _make_menu()
	assert_null(_dev_button(menu, "Complete rally"),
		"the complete-rally shortcut is hidden outside a rally")


# While a rally is running, the dev page surfaces the shortcut, and pressing it wins
# the rally immediately: the session resolves to a P1 finish and returns to IDLE.
func test_complete_rally_button_wins_the_active_rally() -> void:
	_start_rally()
	assert_true(RallySession.is_active(), "a rally is running")
	var menu := _make_menu()
	var button := _dev_button(menu, "Complete rally")
	assert_not_null(button, "the complete-rally shortcut shows while a rally is active")

	var box: Array = [null]
	RallySession.rally_finished.connect(
		func(res: Dictionary) -> void: box[0] = res, CONNECT_ONE_SHOT)
	button.pressed.emit()

	var r: Dictionary = box[0]
	assert_not_null(r, "pressing the button resolves the rally to the podium")
	assert_eq(int(r["placed"]), 1, "a 0 ms combined out-runs the field -> P1")
	assert_true(bool(r["completed"]), "a P1 finish completes the rally")
	assert_eq(RallySession.phase(), RallySession.Phase.IDLE, "session returns to IDLE")
	assert_false(get_tree().paused, "the tree is unfrozen before the podium loads")


# The dev "Add 1 star" shortcut credits the ledger. Asserts the DELTA, never a resulting
# total — the ledger starts wherever the profile happens to sit.
func test_add_star_dev_button_credits_one_star() -> void:
	var save: Node = get_node("/root/Save")
	var before: int = save.stars_available()
	var menu := _make_menu()
	var button := _dev_button(menu, "Add 1 star")
	assert_not_null(button, "the dev page offers the add-star shortcut")
	button.pressed.emit()
	assert_eq(save.stars_available(), before + 1, "pressing it banks exactly one star")
	button.pressed.emit()
	assert_eq(save.stars_available(), before + 2, "and it is repeatable")
	assert_string_contains(menu._dev_status.text.to_lower(), "star",
		"the dev status line reports what happened")
