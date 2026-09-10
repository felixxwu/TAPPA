extends GutTest
# PHOTO MODE TOUCH CONTROLS (features/camera.md, features/mobile-controls.md):
# PhotoModeControls is the on-screen control set photo mode gets on a phone — a
# thumbstick for lateral movement, Up/Down for altitude, Back to leave, Hide for a
# clean shot, plus a drag-to-look and a pinch-to-zoom gesture over the whole screen.
#
# Most of this is asserted through the overlay's PURE seams (stick_output_for, is_tap,
# pinch_zoom_factor, hit_test) rather than by synthesising touch streams: the touch
# plumbing is the same InputEventScreenTouch/ScreenDrag path mobile_controls.gd already
# uses, and what is actually new — and what would silently rot — is the geometry and
# the state machine around it.

const VIEWPORT := Vector2(1280.0, 720.0)

var _camera: PhotoModeCamera
var _controls: PhotoModeControls


func before_each() -> void:
	_camera = PhotoModeCamera.new()
	add_child_autofree(_camera)
	_camera.enter(null)
	_controls = PhotoModeControls.new()
	add_child_autofree(_controls)
	_controls.setup(_camera)
	# The suite's viewport is not a phone's, and every region is laid out against it, so
	# pin a known size rather than asserting against whatever the harness happens to be.
	_controls._compute_rects(VIEWPORT)


func after_each() -> void:
	if is_instance_valid(_camera) and _camera.is_active():
		_camera.exit()


# --- The thumbstick (the WASD equivalent) ------------------------------------

# Stick UP is FORWARD and stick RIGHT is strafe right. Screen Y grows downward, so the
# forward axis is the one that has to be inverted — get this wrong and the stick is
# upside down, which is the single most likely way this widget breaks.
func test_stick_up_is_forward_and_right_is_right() -> void:
	var centre := Vector2(200.0, 600.0)
	var radius := 80.0
	var up: Vector2 = PhotoModeControls.stick_output_for(
		centre + Vector2(0.0, -radius), centre, radius)["output"]
	assert_gt(up.y, 0.9, "pushing the stick UP the screen means forward")
	assert_almost_eq(up.x, 0.0, 0.001, "and adds no sideways component")
	var right: Vector2 = PhotoModeControls.stick_output_for(
		centre + Vector2(radius, 0.0), centre, radius)["output"]
	assert_gt(right.x, 0.9, "pushing it RIGHT strafes right")
	assert_almost_eq(right.y, 0.0, 0.001, "with no forward component")


# The stick is ANALOGUE — that is the whole reason it is a stick and not four buttons.
# Half-deflection has to give roughly half the output so slow, precise framing is
# possible.
func test_stick_output_is_analogue() -> void:
	var centre := Vector2(200.0, 600.0)
	var radius := 80.0
	var half: Vector2 = PhotoModeControls.stick_output_for(
		centre + Vector2(0.0, -radius * 0.5), centre, radius)["output"]
	assert_almost_eq(half.y, 0.5, 0.02, "half a deflection is half the output")
	assert_between(half.length(), 0.4, 0.6, "and well short of full travel")


# A finger dragged outside the base clamps to the rim rather than running away with an
# ever-growing output — the knob has to stay drawn inside its base, and the movement
# has to cap at full speed.
func test_stick_clamps_outside_the_base() -> void:
	var centre := Vector2(200.0, 600.0)
	var radius := 80.0
	var far: Dictionary = PhotoModeControls.stick_output_for(
		centre + Vector2(1000.0, 0.0), centre, radius)
	assert_almost_eq((far["knob_offset"] as Vector2).length(), radius, 0.001,
		"the knob stays on the rim of its base")
	assert_almost_eq((far["output"] as Vector2).length(), 1.0, 0.001,
		"and the output saturates at full deflection")


# Degenerate geometry (a zero-radius base — a layout that never ran) must not divide by
# zero or emit a NaN axis into the camera.
func test_stick_with_no_geometry_is_inert() -> void:
	var out: Vector2 = PhotoModeControls.stick_output_for(
		Vector2(10.0, 10.0), Vector2.ZERO, 0.0)["output"]
	assert_eq(out, Vector2.ZERO, "a stick with no radius reports no movement")


# Untouched, the stick reports nothing — so an overlay sitting there does not creep the
# camera across the frozen scene.
func test_unheld_stick_reports_no_movement() -> void:
	assert_eq(_controls.stick_output(), Vector2.ZERO, "an unheld stick is centred")


# --- Regions -----------------------------------------------------------------

# Each widget claims its own corner and nothing claims the middle of the screen — the
# middle has to stay free for the look gesture, or framing a shot becomes impossible.
func test_regions_claim_their_corners_and_leave_the_middle_free() -> void:
	assert_eq(_controls.hit_test(VIEWPORT * 0.5), "",
		"the centre of the screen belongs to the look gesture, not a widget")
	for region in ["back", "hide", "up", "down"]:
		var rect: Rect2 = _controls._rects[region]
		assert_eq(_controls.hit_test(rect.get_center()), region,
			region + " is hit at its own centre")
	assert_eq(_controls.hit_test(_controls._stick_base_center), "stick",
		"the stick is hit at its base centre")


# --- Hide / restore ----------------------------------------------------------

# THE BUG THIS PINS: while hidden, nothing may hit-test. A player hides the chrome to
# frame a shot, taps near the top-left to bring it back — and if the invisible BACK
# button still answered, they would be thrown out of photo mode instead. While hidden a
# touch can only mean look, pinch, or the tap that restores the UI.
func test_hidden_widgets_stop_hit_testing_entirely() -> void:
	_controls.set_hidden(true)
	assert_true(_controls.is_hidden(), "precondition: the UI is hidden")
	for region in ["back", "hide", "up", "down"]:
		assert_eq(_controls.hit_test((_controls._rects[region] as Rect2).get_center()), "",
			"the invisible " + region + " button claims nothing")
	assert_eq(_controls.hit_test(_controls._stick_base_center), "",
		"nor does the invisible stick")
	_controls.set_hidden(false)
	assert_eq(_controls.hit_test((_controls._rects["back"] as Rect2).get_center()), "back",
		"and everything answers again once the UI is back")


# Hiding force-releases anything held, so the camera cannot keep flying after the
# controls that were driving it have gone.
func test_hiding_releases_held_input() -> void:
	_controls._press(0, _controls._stick_base_center)
	_controls._drag(0, _controls._stick_base_center + Vector2(0.0, -40.0))
	assert_ne(_controls.stick_output(), Vector2.ZERO, "precondition: the stick is held")
	_controls.set_hidden(true)
	assert_eq(_controls.stick_output(), Vector2.ZERO,
		"hiding the UI stops the movement it was driving")


# A tap restores the UI; a drag does not. Both halves matter: without the first there is
# no way back, and without the second you could not look around with the chrome hidden,
# which is the only reason to hide it.
func test_tap_restores_the_ui_but_a_drag_does_not() -> void:
	assert_true(PhotoModeControls.is_tap(2.0, 0.1),
		"a brief, barely-moved press is a tap")
	assert_false(PhotoModeControls.is_tap(400.0, 0.1),
		"a press that travelled across the screen is a drag, not a tap")
	assert_false(PhotoModeControls.is_tap(2.0, 5.0),
		"a press held for seconds is not a tap either")


# End to end through the real touch path: hidden + a quick tap anywhere = the UI is back.
func test_tapping_while_hidden_brings_the_ui_back() -> void:
	_controls.set_hidden(true)
	_controls._press(0, VIEWPORT * 0.5)
	_controls._release(0)
	assert_false(_controls.is_hidden(), "a tap on the frozen shot restores the controls")


# ...and a real drag while hidden looks around WITHOUT restoring the UI.
func test_dragging_while_hidden_looks_without_restoring() -> void:
	_controls.set_hidden(true)
	var before := _camera.yaw()
	_controls._press(0, VIEWPORT * 0.5)
	_controls._drag(0, VIEWPORT * 0.5 + Vector2(300.0, 0.0))
	_controls._release(0)
	assert_ne(_camera.yaw(), before, "the drag turned the camera")
	assert_true(_controls.is_hidden(), "and left the chrome hidden")


# --- Look and pinch ----------------------------------------------------------

# A one-finger drag turns the camera, with the same sign convention as the mouse:
# dragging right swings the view left, as though pushing the world.
func test_one_finger_drag_looks() -> void:
	var before := _camera.yaw()
	_controls._press(0, VIEWPORT * 0.5)
	_controls._drag(0, VIEWPORT * 0.5 + Vector2(200.0, 0.0))
	assert_lt(_camera.yaw(), before, "dragging right turns the view left")
	var pitched := _camera.pitch()
	_controls._drag(0, VIEWPORT * 0.5 + Vector2(200.0, -200.0))
	assert_gt(_camera.pitch(), pitched, "dragging up looks up")
	_controls._release(0)


# Pinching apart zooms IN (a narrower lens), pinching together zooms out.
func test_pinch_factor_direction() -> void:
	assert_gt(PhotoModeControls.pinch_zoom_factor(100.0, 200.0), 1.0,
		"fingers moving apart give a factor above 1")
	assert_lt(PhotoModeControls.pinch_zoom_factor(200.0, 100.0), 1.0,
		"fingers moving together give a factor below 1")
	assert_eq(PhotoModeControls.pinch_zoom_factor(0.0, 120.0), 1.0,
		"a first sample with no previous separation changes nothing")

	var wide := _camera.fov
	_camera.zoom_by(2.0)
	assert_lt(_camera.fov, wide, "pinching apart narrows the lens (zooms in)")
	_camera.zoom_by(0.5)
	assert_almost_eq(_camera.fov, wide, 0.01, "and pinching back in undoes it")


# The lens stays inside the configured range however hard the player pinches — an
# unclamped fov goes to zero (or past 180) and the view degenerates.
func test_zoom_is_clamped_to_the_configured_range() -> void:
	for _i in range(20):
		_camera.zoom_by(4.0)
	assert_almost_eq(_camera.fov, Config.data.photo_fov_min, 0.01,
		"zooming in stops at the long end of the range")
	for _i in range(40):
		_camera.zoom_by(0.25)
	assert_almost_eq(_camera.fov, Config.data.photo_fov_max, 0.01,
		"and zooming out stops at the wide end")
	# A degenerate factor must be ignored rather than producing an infinite/NaN fov.
	var held := _camera.fov
	_camera.zoom_by(0.0)
	assert_eq(_camera.fov, held, "a zero pinch ratio changes nothing")


# A second finger promotes the gesture to a pinch and DROPS the one-finger look, so
# zooming can never also swing the camera off the shot being framed.
func test_a_second_finger_stops_the_look() -> void:
	_controls._press(0, Vector2(500.0, 360.0))
	_controls._press(1, Vector2(700.0, 360.0))
	var held := _camera.yaw()
	var lens := _camera.fov
	_controls._drag(0, Vector2(300.0, 360.0))  # would be a big yaw swing on its own
	assert_eq(_camera.yaw(), held, "while two fingers are down, dragging does not look")
	assert_ne(_camera.fov, lens, "and the pinch drove the lens instead")
	_controls._release(0)
	_controls._release(1)


# --- Camera hand-off ---------------------------------------------------------

# The stick and the Up/Down buttons reach the camera as its touch axis, in the same
# x=right / y=up / z=forward convention the keyboard uses.
func test_controls_feed_the_camera_touch_axis() -> void:
	_controls._press(0, _controls._stick_base_center)
	_controls._drag(0, _controls._stick_base_center + Vector2(0.0, -_controls._stick_radius))
	_controls._process(0.016)
	assert_gt(_camera.touch_axis.z, 0.9, "a forward stick reaches the camera as +z")
	_controls._release(0)

	_controls._press(1, (_controls._rects["up"] as Rect2).get_center())
	_controls._process(0.016)
	assert_gt(_camera.touch_axis.y, 0.9, "UP reaches it as +y (altitude on world up)")
	_controls._release(1)
	_controls._press(2, (_controls._rects["down"] as Rect2).get_center())
	_controls._process(0.016)
	assert_lt(_camera.touch_axis.y, -0.9, "and DOWN as -y")
	_controls._release(2)


# The touch axis actually flies the camera, and holding the stick AND a key at once is
# not faster than either alone (apply_move normalises the summed direction).
func test_touch_axis_moves_the_camera_at_the_same_speed_as_a_key() -> void:
	_camera.global_position = Vector3.ZERO
	_camera.touch_axis = Vector3(0.0, 0.0, 1.0)
	_camera.apply_move(_camera.input_axis() + _camera.touch_axis, 0.5)
	var by_stick := _camera.global_position.length()
	assert_gt(by_stick, 0.01, "the stick flies the camera")

	_camera.global_position = Vector3.ZERO
	_camera.apply_move(Vector3(0.0, 0.0, 2.0), 0.5)  # stick + key pushing the same way
	assert_almost_eq(_camera.global_position.length(), by_stick, 0.001,
		"a stick and a key together are no faster than one of them")


# Back leaves photo mode — the only way out on a phone, since there is no Esc key and
# the pause button is hidden while the camera is up.
func test_back_button_exits_photo_mode() -> void:
	watch_signals(_camera)
	_controls._press(0, (_controls._rects["back"] as Rect2).get_center())
	_controls._release(0)
	assert_signal_emitted(_camera, "exited", "BACK leaves photo mode")
	assert_false(_camera.is_active(), "and the camera stops flying")


# Leaving photo mode must not strand a movement axis that would still be pushing the
# camera the next time it opens.
func test_exit_clears_the_touch_axis() -> void:
	_camera.touch_axis = Vector3(1.0, 1.0, 1.0)
	_camera.exit()
	assert_eq(_camera.touch_axis, Vector3.ZERO, "exiting drops any held touch movement")


# The overlay is only useful if it keeps working while the tree is frozen — the same
# reason the camera it drives is PROCESS_MODE_ALWAYS.
func test_controls_run_while_paused() -> void:
	assert_eq(_controls.process_mode, Node.PROCESS_MODE_ALWAYS,
		"the touch controls run while the world is frozen")
