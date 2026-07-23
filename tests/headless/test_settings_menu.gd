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
