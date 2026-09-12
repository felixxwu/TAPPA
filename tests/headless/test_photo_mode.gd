extends GutTest
# PHOTO MODE (features/camera.md, features/menus.md): the pause menu hands the frozen
# screen to a free-fly PhotoModeCamera. The camera flies while the tree is PAUSED, WASD
# moves it laterally, Ctrl/Shift change altitude, the mouse looks around, and Esc gives
# the pause menu back with the world still frozen.
#
# main.tscn is built ONCE for the whole file (minimal_world trims the heavy
# terrain/track generation); every test leaves photo mode and unpauses so the shared
# instance is order-safe.

const TEST_PATH := "user://test_photo_mode_profile.json"

var _scene: Node3D
var _pause: PauseMenu
var _save: Node


func before_all() -> void:
	_save = get_node("/root/Save")
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.load_or_new()
	RegionStageFixtures.install()
	SceneTestHelpers.minimal_world()
	_scene = load("res://main.tscn").instantiate()
	add_child(_scene)
	await get_tree().physics_frame  # let world._ready() build the scene
	_pause = _scene.get_node("PauseMenu")
	_scene.scene_change_hook = func(_path: String) -> void: pass


func after_all() -> void:
	get_tree().paused = false
	_scene.free()
	RegionStageFixtures.restore()
	Config.reset()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


func after_each() -> void:
	# Never leak an open photo camera, a paused tree or a captured mouse into the next
	# test: photo mode deliberately leaves the tree frozen, so this has to undo both.
	var cam := _scene.get_node_or_null("PhotoModeCamera") as PhotoModeCamera
	if cam != null:
		cam.exit()
		await get_tree().process_frame  # let the queue_free land before the next test
	_pause.resume()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


# --- The camera itself (no scene needed) -------------------------------------

# A fresh camera, entered from a stand-in "gameplay camera", for the pure-behaviour
# tests below.
func _lone_camera(from_xform := Transform3D.IDENTITY) -> PhotoModeCamera:
	var src := Camera3D.new()
	add_child_autofree(src)
	src.global_transform = from_xform
	var cam := PhotoModeCamera.new()
	add_child_autofree(cam)
	cam.enter(src)
	return cam


# The whole feature is "fly around while everything is frozen", which only works if
# the camera keeps processing across a paused tree.
func test_camera_processes_while_paused() -> void:
	var cam := PhotoModeCamera.new()
	add_child_autofree(cam)
	assert_eq(cam.process_mode, Node.PROCESS_MODE_ALWAYS,
		"the photo camera runs while the tree is paused")


# Photo mode opens on the shot the player was already looking at, rather than jumping
# somewhere else, and takes over the viewport.
func test_enter_adopts_the_previous_camera_shot() -> void:
	var xform := Transform3D(Basis(Vector3.UP, 0.7), Vector3(12.0, 3.0, -4.0))
	var cam := _lone_camera(xform)
	assert_almost_eq(cam.global_position, xform.origin, Vector3.ONE * 0.001,
		"photo mode starts where the gameplay camera was")
	assert_almost_eq(cam.yaw(), 0.7, 0.01, "and facing the same way")
	assert_true(cam.current, "the photo camera takes over the viewport")
	assert_true(cam.is_active(), "and reports itself active")
	cam.exit()


# W flies the camera along the direction it is looking, S back the other way — the
# defining check that the lateral keys mean what they say.
func test_w_and_s_fly_forward_and_back() -> void:
	var cam := _lone_camera()  # identity basis: looking down -Z
	cam.apply_move(Vector3(0.0, 0.0, 1.0), 0.5)
	assert_lt(cam.global_position.z, -0.01, "W moves the camera forward (-Z)")
	var after_w := cam.global_position
	cam.apply_move(Vector3(0.0, 0.0, -1.0), 0.5)
	assert_almost_eq(cam.global_position, Vector3.ZERO, Vector3.ONE * 0.001,
		"S moves it back the same distance")
	assert_ne(after_w, cam.global_position, "the two are not the same move")
	cam.exit()


# A/D strafe sideways, not forward.
func test_a_and_d_strafe_sideways() -> void:
	var cam := _lone_camera()
	cam.apply_move(Vector3(1.0, 0.0, 0.0), 0.5)
	assert_gt(cam.global_position.x, 0.01, "D strafes right (+X when looking down -Z)")
	assert_almost_eq(cam.global_position.z, 0.0, 0.001, "and does not move forward")
	cam.exit()


# Ctrl/Shift are ALTITUDE on world up — and stay so however the camera is pitched,
# which is the reason they exist separately from WASD.
func test_shift_and_ctrl_change_altitude_on_world_up() -> void:
	var cam := _lone_camera()
	cam.look_by(0.0, -deg_to_rad(60.0))  # pitch steeply down
	cam.apply_move(Vector3(0.0, 1.0, 0.0), 0.5)
	assert_gt(cam.global_position.y, 0.01, "Shift raises the camera")
	assert_almost_eq(Vector2(cam.global_position.x, cam.global_position.z), Vector2.ZERO,
		Vector2.ONE * 0.001, "altitude is pure world-Y, with no lateral drift")
	var high := cam.global_position.y
	cam.apply_move(Vector3(0.0, -1.0, 0.0), 0.5)
	assert_lt(cam.global_position.y, high, "Ctrl lowers it again")
	cam.exit()


# Lateral movement is FLATTENED: looking at the sky and holding W travels across the
# world, it does not climb (that is what Shift is for).
func test_forward_movement_stays_horizontal_when_looking_up() -> void:
	var cam := _lone_camera()
	cam.look_by(0.0, deg_to_rad(70.0))  # pitch steeply up
	cam.apply_move(Vector3(0.0, 0.0, 1.0), 0.5)
	assert_almost_eq(cam.global_position.y, 0.0, 0.001,
		"W is horizontal travel regardless of pitch")
	assert_lt(cam.global_position.z, -0.01, "and still goes where the camera faces")
	cam.exit()


# Holding two keys must not be faster than one (a normalised direction).
func test_diagonal_movement_is_not_faster() -> void:
	var straight := _lone_camera()
	straight.apply_move(Vector3(0.0, 0.0, 1.0), 0.5)
	var one_key := straight.global_position.length()
	straight.exit()
	var diagonal := _lone_camera()
	diagonal.apply_move(Vector3(1.0, 0.0, 1.0), 0.5)
	assert_almost_eq(diagonal.global_position.length(), one_key, 0.001,
		"a diagonal covers the same distance as a single direction")
	diagonal.exit()


# Movement is frame-rate independent: twice the delta covers twice the ground.
func test_movement_scales_with_delta() -> void:
	var short := _lone_camera()
	short.apply_move(Vector3(0.0, 0.0, 1.0), 0.1)
	var near := short.global_position.length()
	short.exit()
	var long := _lone_camera()
	long.apply_move(Vector3(0.0, 0.0, 1.0), 0.2)
	assert_almost_eq(long.global_position.length(), near * 2.0, 0.001,
		"distance is speed * delta")
	long.exit()


# Mouse look turns the camera, keeps the horizon level (no roll), and cannot flip over
# the poles.
func test_look_turns_without_roll_and_clamps_pitch() -> void:
	var cam := _lone_camera()
	cam.look_by(1.2, 0.4)
	assert_almost_eq(cam.yaw(), 1.2, 0.001, "yaw follows the horizontal look")
	assert_almost_eq(cam.pitch(), 0.4, 0.001, "pitch follows the vertical look")
	assert_almost_eq(cam.global_transform.basis.x.y, 0.0, 0.001,
		"the horizon stays level — the free camera never rolls")
	cam.look_by(0.0, 99.0)
	assert_lt(cam.pitch(), deg_to_rad(90.0), "pitch stops short of straight up")
	cam.look_by(0.0, -999.0)
	assert_gt(cam.pitch(), -deg_to_rad(90.0), "and short of straight down")
	cam.exit()


# The pointer is captured while flying and handed back on the way out — including when
# the host frees the camera without an explicit exit (nothing may strand a captured
# mouse over a live menu).
# (Asserted on the camera's own capture INTENT, not on Input.mouse_mode: the headless
# display server the suite runs on silently refuses a real capture, so reading the mode
# back would test the platform rather than the camera.)
func test_mouse_is_captured_and_released() -> void:
	var cam := _lone_camera()
	assert_true(cam.mouse_captured(), "photo mode takes the pointer for mouse look")
	cam.exit()
	assert_false(cam.mouse_captured(), "and gives it back on exit")
	var freed := _lone_camera()
	assert_true(freed.mouse_captured(), "precondition: the second camera took it too")
	freed.free()
	assert_eq(Input.mouse_mode, Input.MOUSE_MODE_VISIBLE,
		"leaving the tree releases the pointer even without an explicit exit")


# Mouse motion turns the camera while it holds the pointer, and does nothing once it
# has let go — the pause menu behind it must not be steered by a stray mouse move.
func test_mouse_motion_turns_the_camera() -> void:
	var cam := _lone_camera()
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(40.0, 0.0)
	cam._input(motion)
	assert_ne(cam.yaw(), 0.0, "moving the mouse turns the camera")
	var turned := cam.yaw()
	cam.exit()
	cam._input(motion)
	assert_eq(cam.yaw(), turned, "once photo mode is over the mouse steers nothing")


# exit() is the single way out and is safe to call twice (after_each does exactly that
# on a camera the test already closed).
func test_exit_emits_once() -> void:
	var cam := _lone_camera()
	watch_signals(cam)
	cam.exit()
	cam.exit()
	assert_signal_emit_count(cam, "exited", 1, "exiting twice reports once")
	assert_false(cam.is_active(), "and the camera is no longer active")


# --- The pause-menu entry point ----------------------------------------------

# Photo Mode is offered on the pause menu, as a real focusable row (so it is reachable
# on keyboard and gamepad, not just by pointer — see features/menu-navigation.md).
func test_pause_menu_offers_photo_mode() -> void:
	assert_not_null(_pause._photo_button, "the pause menu has a Photo Mode row")
	assert_eq(_pause._photo_button.focus_mode, Control.FOCUS_ALL,
		"the Photo Mode row is keyboard/gamepad focusable")
	# And it is genuinely REACHABLE without a pointer: walk down from the top row with
	# menu_down (the WASD / D-pad family) until the cursor lands on it.
	var nav := MenuNav.of(_pause._overlay)
	assert_not_null(nav, "the pause overlay is wired to the MenuNav framework")
	await get_tree().process_frame
	nav.forget()
	_pause.open()
	# TWO frames: one for the deferred opening focus grab, one for the container sort
	# that gives the rows real rects — focus-neighbour search is geometric, so a menu
	# that has never been laid out has nowhere to walk to.
	await get_tree().process_frame
	await get_tree().process_frame
	_pause._reset_button.grab_focus()  # the row above Photo Mode
	var reached := false
	var walked: Array[String] = []
	for _i in range(8):
		var owner_now := _pause._overlay.get_viewport().gui_get_focus_owner()
		walked.append("null" if owner_now == null else str(owner_now))
		if owner_now == _pause._photo_button:
			reached = true
			break
		nav._unhandled_input(_nav_press("menu_down"))
	assert_true(reached,
		"menu_down walks the cursor onto the Photo Mode row (walked: %s)" % str(walked))
	# Gamepad/keyboard confirm on that row asks for photo mode, same as a tap.
	watch_signals(_pause)
	_pause._photo_button.emit_signal("pressed")
	assert_signal_emitted(_pause, "photo_mode_requested",
		"confirming the focused row opens photo mode")


func _nav_press(action: String) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = action
	e.pressed = true
	return e


# Picking Photo Mode hides the menu and disarms it (so Esc belongs to the camera), but
# it must NOT unpause: the frozen world is the entire feature.
func test_photo_mode_keeps_the_world_frozen() -> void:
	_pause.open()
	watch_signals(_pause)
	_pause._on_photo_mode_pressed()
	assert_signal_emitted(_pause, "photo_mode_requested", "the host is asked for photo mode")
	assert_true(get_tree().paused, "the world stays frozen while flying the camera")
	assert_false(_pause.is_open(), "the pause overlay gets out of the shot")
	assert_false(_pause._input_enabled,
		"the menu disarms so Esc / the Pause button belong to the photo camera")


# Esc comes back to the pause menu, with the world still frozen — not to gameplay.
func test_returning_from_photo_mode_reopens_the_still_frozen_menu() -> void:
	_pause.open()
	_pause._on_photo_mode_pressed()
	_pause.return_from_photo_mode()
	assert_true(_pause.is_open(), "leaving photo mode gives the pause menu back")
	assert_true(get_tree().paused, "and the world is still frozen")
	assert_true(_pause._input_enabled, "the menu is armed again")


# --- world.gd wiring ----------------------------------------------------------

# The scene answers the menu: a camera appears, takes the viewport, and the in-run
# screen furniture gets out of the shot. The post-process mirror has to keep running
# while paused or the photo camera would move with nothing on screen changing.
func test_world_opens_and_closes_photo_mode() -> void:
	_pause.open()
	_pause._on_photo_mode_pressed()
	var cam := _scene.get_node_or_null("PhotoModeCamera") as PhotoModeCamera
	assert_not_null(cam, "world.gd creates the free-fly camera")
	assert_true(cam.current, "the photo camera takes over the viewport")
	for node_name in ["HUD", "MobileControls", "SpeedLines"]:
		assert_false((_scene.get_node(node_name) as CanvasLayer).visible,
			node_name + " is hidden so the shot is unobstructed")
	assert_eq((_scene.get_node("PostProcess") as Node).process_mode,
		Node.PROCESS_MODE_ALWAYS,
		"the post-process mirror keeps running so the frozen world still redraws")

	cam.exit()
	await get_tree().process_frame  # queue_free lands next frame
	assert_null(_scene.get_node_or_null("PhotoModeCamera"), "the camera is dropped on exit")
	for node_name in ["HUD", "MobileControls", "SpeedLines"]:
		assert_true((_scene.get_node(node_name) as CanvasLayer).visible,
			node_name + " comes back")
	assert_eq((_scene.get_node("PostProcess") as Node).process_mode,
		Node.PROCESS_MODE_INHERIT, "and the mirror goes back to pausing with the world")
	assert_true(_pause.is_open(), "the pause menu is back")


# A second request while already flying must not stack a second camera.
func test_double_request_makes_one_camera() -> void:
	_pause.open()
	_pause._on_photo_mode_pressed()
	_scene._on_photo_mode_requested()
	assert_eq(_scene.find_children("PhotoModeCamera", "", false, false).size(), 1,
		"only one photo camera at a time")
