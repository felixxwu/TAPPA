extends GutTest
# In-run pause menu (features/menus.md): the top-right Pause button freezes the game
# and opens Resume + the shared Settings page (camera angle + mobile controls);
# Resume unfreezes; and picking a camera in Settings switches the live CameraManager.
#
# main.tscn is built ONCE for the whole script (minimal_world trims the heavy
# terrain/track generation). Every test resumes + closes the overlay at the end so
# the shared instance is order-safe, and after_all guarantees the tree is unpaused.

const TEST_PATH := "user://test_pause_profile.json"

var _scene: Node3D
var _pause: PauseMenu
var _mgr: CameraManager
var _mobile: MobileControls
var _save: Node


func before_all() -> void:
	_save = get_node("/root/Save")
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.load_or_new()
	SceneTestHelpers.minimal_world()
	_scene = load("res://main.tscn").instantiate()
	add_child(_scene)
	await get_tree().physics_frame  # let world._ready() build the scene
	_pause = _scene.get_node("PauseMenu")
	_mgr = _scene.get_node("CameraManager")
	_mobile = _scene.get_node("MobileControls")


func after_all() -> void:
	get_tree().paused = false
	_scene.free()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


func after_each() -> void:
	# Never leak a paused tree / open overlay / live session into the next test (or file).
	_pause.resume()
	if RallySession.is_active():
		RallySession.abandon()
	RallySession.auto_load_scenes = true


# The menu is default-inert (fail-closed) until the world is generated: a fresh,
# un-armed PauseMenu must NOT open or freeze the tree. This is the guard against
# pausing mid-world-generation (the loading window) and quitting/resuming into a
# half-built world.
func test_unarmed_pause_menu_is_inert() -> void:
	var fresh := PauseMenu.new()
	add_child_autofree(fresh)
	assert_false(get_tree().paused, "precondition: tree not paused")
	fresh.open()
	assert_false(get_tree().paused, "an un-armed pause menu does not freeze the tree")
	assert_false(fresh.is_open(), "an un-armed pause menu does not open")
	# Arming it makes open() work as normal.
	fresh.set_input_enabled(true)
	fresh.open()
	assert_true(fresh.is_open(), "once armed, the menu opens")
	fresh.resume()  # don't leak a paused tree


# world.gd arms the pause menu once the world has finished generating, so pause
# is live for the actual run but was inert during loading.
func test_world_boot_arms_the_pause_menu() -> void:
	assert_true(_pause._input_enabled,
		"world.gd enables the pause menu after generation completes")


func test_pause_freezes_game_and_opens_menu() -> void:
	assert_false(get_tree().paused, "the game runs before pausing")
	assert_false(_pause.is_open(), "the overlay starts hidden")
	_pause.open()
	assert_true(get_tree().paused, "opening the pause menu freezes the game")
	assert_true(_pause.is_open(), "the pause overlay is shown")


func test_resume_unfreezes_and_closes() -> void:
	_pause.open()
	_pause.resume()
	assert_false(get_tree().paused, "Resume unfreezes the game")
	assert_false(_pause.is_open(), "Resume hides the overlay")


# The Pause button shows a proper drawn pause glyph (PauseIcon), not a text stand-in.
func test_pause_button_uses_a_drawn_icon() -> void:
	assert_eq(_pause._pause_button.text, "", "the Pause button carries no text stand-in")
	assert_eq(_pause._pause_button.find_children("*", "PauseIcon", true, false).size(), 1,
		"the Pause button shows a drawn PauseIcon glyph")


# Opening the menu lands the keyboard/gamepad cursor on Resume, and the buttons are
# focusable so ui_up/ui_down + ui_accept work the menu without a pointer. The whole
# layer is PROCESS_MODE_ALWAYS, so focus works even though the tree is paused.
func test_pause_menu_is_keyboard_navigable() -> void:
	_pause.open()
	await get_tree().process_frame  # let the deferred grab_focus run
	assert_eq(_pause._resume_button.focus_mode, Control.FOCUS_ALL, "menu buttons are focusable")
	assert_eq(_pause._quit_button.focus_mode, Control.FOCUS_ALL, "Quit is focusable too")
	assert_eq(_pause._reset_button.focus_mode, Control.FOCUS_ALL, "Reset to track is focusable too")
	assert_eq(_pause.get_viewport().gui_get_focus_owner(), _pause._resume_button,
		"opening the menu focuses Resume")
	_pause.resume()


# "Reset to track" delegates the reset upward (the menu owns no car) via a signal,
# then unfreezes and closes the overlay so the player drops back into the run.
func test_reset_to_track_emits_and_resumes() -> void:
	assert_not_null(_pause._reset_button, "the pause menu has a Reset to track button")
	watch_signals(_pause)
	_pause.open()
	_pause._on_reset_to_track_pressed()
	assert_signal_emitted(_pause, "reset_to_track_requested",
		"pressing Reset to track requests the reset")
	assert_false(get_tree().paused, "Reset to track unfreezes the game")
	assert_false(_pause.is_open(), "Reset to track closes the overlay")


# world.gd's handler snaps the live car onto the centerline beside its CURRENT
# position (TrackProgress.manual_reset_pose), not back to the start line and not to
# the frozen furthest progress. Firing the request lands the car exactly on that pose.
func test_reset_to_track_snaps_car_onto_manual_reset_pose() -> void:
	var car: Node3D = _scene.get_node("Car")
	var track_progress = _scene._track_progress
	assert_not_null(track_progress, "the run has a live TrackProgress")
	# Shove the car off the road; the manual reset pose is computed from where it is now.
	car.global_transform = car.global_transform.translated(Vector3(30, 5, 0))
	var target: Transform3D = track_progress.manual_reset_pose()
	_scene._on_reset_to_track_requested()
	assert_almost_eq(car.global_transform.origin.distance_to(target.origin), 0.0, 0.01,
		"Reset to track puts the car on the centerline beside its current position")


# Regression: the teleport must SURVIVE the following physics steps. A bare
# global_transform write on the RigidBody is discarded by the physics server unless it
# happens inside the physics step, so a reset fired outside it (a menu signal) or on a
# stuck/sleeping body used to revert next frame — the car appeared not to move at all.
# Car.reset_to queues the pose for _integrate_forces, so it holds. Step physics and
# assert the car is still on the reset pose (only settling gently under gravity).
func test_reset_to_track_holds_across_physics_steps() -> void:
	var car: Node3D = _scene.get_node("Car")
	var track_progress = _scene._track_progress
	car.global_transform = car.global_transform.translated(Vector3(30, 5, 0))
	var target: Transform3D = track_progress.manual_reset_pose()
	_scene._on_reset_to_track_requested()
	for _i in 5:
		await get_tree().physics_frame
	# Horizontal position must not drift back toward where the car strayed; a little
	# vertical settle under gravity is fine, so compare on the XZ plane only.
	var d := Vector2(car.global_transform.origin.x, car.global_transform.origin.z) \
		.distance_to(Vector2(target.origin.x, target.origin.z))
	assert_almost_eq(d, 0.0, 1.0,
		"Reset holds after physics steps instead of the server reverting the teleport")


func test_settings_exposes_the_shared_menu() -> void:
	_pause.open()
	# The same SettingsMenu component as the title screen: camera + control rows.
	assert_not_null(_pause.settings_menu, "the pause menu embeds a SettingsMenu")
	assert_eq(_pause.settings_menu.camera_rows.size(), CameraManager.MODES.size(),
		"one row per camera angle")
	assert_eq(_pause.settings_menu.scheme_rows.size(), MobileControls.SCHEMES.size(),
		"one row per control scheme")


func test_settings_opens_on_the_category_list_and_drills_in() -> void:
	# Opening Settings shows the category list; each category opens its own sub-page.
	_pause._show_settings(true)
	assert_true(_pause.settings_menu.at_root(), "Settings opens on the category list")
	_pause.settings_menu.show_camera()
	assert_false(_pause.settings_menu.at_root(), "tapping Camera opens its own page")
	# Back steps out of the sub-page to the list, then out of Settings to the menu.
	_pause._on_settings_back()
	assert_true(_pause.settings_menu.at_root(), "Back returns to the category list")
	_pause._on_settings_back()
	assert_false(_pause._settings_panel.visible, "Back from the list closes Settings")


func test_quit_to_hq_abandons_the_rally_and_unfreezes() -> void:
	# The pause menu offers a "Quit to HQ" button that abandons the active rally.
	assert_not_null(_pause._quit_button, "the pause menu has a Quit to HQ button")
	# A live rally (driven directly, no scene loads) is abandoned by Quit to HQ:
	# the session ends and the tree unfreezes. world.gd handles the trip back to HQ.
	RallySession.auto_load_scenes = false
	var owned: Dictionary = _save.grant_car("mx5")
	RallySession.start_rally(RallyLibrary.by_id("shakedown"), owned, true)
	assert_true(RallySession.is_active(), "a rally is running")
	_pause.open()
	_pause.quit_to_hq()
	assert_false(RallySession.is_active(), "Quit to HQ abandons the rally")
	assert_false(get_tree().paused, "Quit to HQ unfreezes the game")


func test_picking_a_camera_in_settings_applies_live() -> void:
	_pause.open()
	# Start from chase, then pick bonnet in the settings menu: the live camera switches
	# and the choice persists.
	_mgr.set_mode(CameraManager.Mode.CHASE)
	_pause.settings_menu.select_camera(CameraManager.Mode.BONNET)
	assert_eq(_mgr.current_mode(), CameraManager.Mode.BONNET,
		"the live camera switches to the chosen angle")
	assert_true((_scene.get_node("Car/BonnetCamera") as Camera3D).current,
		"the bonnet camera is now current")
	assert_eq(int(_save.get_setting(CameraManager.SETTING_KEY, -1)),
		CameraManager.Mode.BONNET, "the chosen camera angle is saved")
	# Restore chase so the shared scene starts the next test from the default.
	_pause.settings_menu.select_camera(CameraManager.Mode.CHASE)


func test_quit_pressed_opens_confirm_popup() -> void:
	_pause.open()
	_pause._on_quit_pressed()
	await get_tree().process_frame
	var popups := _pause.find_children("*", "ConfirmPopup", true, false)
	assert_eq(popups.size(), 1, "quit shows a ConfirmPopup")


func test_picking_a_scheme_in_settings_applies_live() -> void:
	# The pause menu is wired to the live MobileControls, so picking a touch scheme in
	# Settings switches the on-screen controls immediately (not only on the next run).
	assert_eq(_pause.mobile_controls, _mobile, "the pause menu knows the live MobileControls")
	_pause.open()
	_pause.settings_menu.select_scheme(MobileControls.SCHEME_BUTTONS_GAS_BRAKE)
	assert_eq(_mobile._scheme, MobileControls.SCHEME_BUTTONS_GAS_BRAKE,
		"the live touch controls switch to the chosen scheme")
	assert_eq(int(_save.get_setting(MobileControls.SETTING_KEY, -1)),
		MobileControls.SCHEME_BUTTONS_GAS_BRAKE, "the chosen scheme is saved")
	# Restore the default so the shared scene starts the next test clean.
	_pause.settings_menu.select_scheme(MobileControls.DEFAULT_SCHEME)
