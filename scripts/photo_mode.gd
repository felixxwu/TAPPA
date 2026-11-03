class_name PhotoModeCamera
extends Camera3D
# Docs: features/camera.md, features/menus.md — update in the same change as this file.
# Tests: tests/headless/test_photo_mode.gd, tests/headless/test_pause_menu.gd — extend in the same change.
# Free-fly PHOTO MODE camera. Opened from the in-run pause menu, it takes over the
# viewport while the tree stays PAUSED (`get_tree().paused` is left exactly as the
# pause menu set it), so the whole world — car, physics, particles, timers — is frozen
# in place and only the viewpoint moves.
#
# Gamepad: left stick moves, right stick looks, triggers lower and raise.
# Keyboard (deliberately RAW physical keys, not InputMap actions): WASD moves laterally
# in the camera's horizontal plane, Ctrl/Shift drop and raise altitude on the WORLD Y
# axis, the mouse looks around (captured pointer), Esc leaves. Raw keys because every
# gameplay action here is rebindable (`InputRemap`) and W/A/S/D are the DRIVING binds —
# routing photo movement through them would make photo mode follow a rebind of the
# throttle, and there is no action for Ctrl/Shift to begin with. `ui_cancel` IS an
# action (Esc / gamepad B) because backing out of a mode is a menu gesture.
#
# Lifetime is owned by PhotoModeHost: it creates one, calls enter(), and frees it on
# `exited`. See features/camera.md.

# Emitted when the player presses Esc. The host frees this camera, restores the
# gameplay camera and re-opens the pause menu.
signal exited

const PITCH_LIMIT_DEG := 89.0
const STICK_DEADZONE := 0.2

# How far the camera may fly from where it entered, in metres; 0 means no limit. Set by a host whose
# world only exists around the car, so the player can't fly out past the end of it.
var max_range_m := 0.0
var _origin := Vector3.ZERO

var _yaw := 0.0    # radians, world Y
var _pitch := 0.0  # radians, clamped to +/- PITCH_LIMIT_DEG
var _entered := false
# Mouse mode to put back on exit (whatever the game was using before capture).
var _prev_mouse_mode := Input.MOUSE_MODE_VISIBLE
# Whether this camera has ASKED for the pointer. Tracked as our own intent rather than
# read back off Input.mouse_mode, because a headless display server silently refuses the
# capture — so the request, not the platform's answer, is what mouse look gates on and
# what the suite can assert.
var _wants_capture := false

# Movement axis pushed by PhotoModeControls (touch thumbstick + up/down buttons), in the
# same x=right/y=up/z=forward camera-local convention as input_axis(). Added to the
# keyboard axis each frame (see _process) so touch and keyboard can't be driven at once
# on a device that somehow has both — apply_move already normalises the summed
# direction, so holding the stick fully over AND a key can't exceed photo_move_speed.
# Reset on exit() so a stale value can't survive into the next time photo mode opens.
var touch_axis := Vector3.ZERO


func _init() -> void:
	# The whole point: run while the tree is paused. Without this the camera would be
	# as frozen as the world it is flying through.
	process_mode = Node.PROCESS_MODE_ALWAYS


# Seat the camera where the gameplay camera was looking from and capture the mouse.
# `from` is the camera being taken over from (chase or bonnet), so photo mode opens on
# exactly the shot the player was already seeing rather than jumping somewhere new.
func enter(from: Camera3D) -> void:
	if from != null:
		global_transform = from.global_transform
		fov = from.fov
		near = from.near
		far = from.far
	# Re-derive yaw/pitch from that transform so the first mouse move continues the
	# shot instead of snapping to level. Roll (the chase camera's g-force lean) is
	# deliberately dropped — a free camera that starts tilted is disorienting.
	var basis_z := global_transform.basis.z
	_yaw = atan2(basis_z.x, basis_z.z)
	_pitch = clampf(asin(clampf(basis_z.y, -1.0, 1.0)),
		-deg_to_rad(PITCH_LIMIT_DEG), deg_to_rad(PITCH_LIMIT_DEG))
	_apply_look()
	_origin = global_position
	current = true
	_prev_mouse_mode = Input.mouse_mode
	_wants_capture = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_entered = true


# Give the pointer back. Called on the way out (and defensively from _exit_tree, so a
# host that frees the camera without going through Esc can't strand a captured mouse).
func release_mouse() -> void:
	if not _wants_capture:
		return
	_wants_capture = false
	Input.mouse_mode = _prev_mouse_mode


# Whether the camera currently holds (or has asked for) the pointer.
func mouse_captured() -> bool:
	return _wants_capture


func _exit_tree() -> void:
	release_mouse()


func _process(delta: float) -> void:
	if not _entered:
		return
	# `delta` is the UNSCALED frame time here: the tree is paused, so a paused-tree
	# node's delta is still real seconds — the camera flies at the same speed however
	# long the frame took.
	apply_move(input_axis() + touch_axis + pad_move(_pad(JOY_AXIS_LEFT_X), _pad(JOY_AXIS_LEFT_Y),
			_pad(JOY_AXIS_TRIGGER_LEFT), _pad(JOY_AXIS_TRIGGER_RIGHT)), delta)
	var look: float = Config.data.chase_look_stick_speed * delta
	look_by(-_pad(JOY_AXIS_RIGHT_X) * look, -_pad(JOY_AXIS_RIGHT_Y) * look)


# One axis of the first connected gamepad, with the resting wobble removed.
func _pad(axis: JoyAxis) -> float:
	var pads := Input.get_connected_joypads()
	if pads.is_empty():
		return 0.0
	var value := Input.get_joy_axis(pads[0], axis)
	return value if absf(value) > STICK_DEADZONE else 0.0


# Gamepad axes as the camera-local axis triple input_axis() uses. A stick's up reads negative.
static func pad_move(stick_x: float, stick_y: float, trigger_left: float, trigger_right: float) -> Vector3:
	return Vector3(stick_x, maxf(trigger_right, 0.0) - maxf(trigger_left, 0.0), -stick_y)


# The held movement keys as a camera-LOCAL axis triple: x = right, y = up, z = forward.
# Split out of _process so the mapping (which raw key means which direction) and the
# motion it produces can each be tested without the other.
func input_axis() -> Vector3:
	var axis := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		axis.z += 1.0
	if Input.is_physical_key_pressed(KEY_S):
		axis.z -= 1.0
	if Input.is_physical_key_pressed(KEY_D):
		axis.x += 1.0
	if Input.is_physical_key_pressed(KEY_A):
		axis.x -= 1.0
	if Input.is_physical_key_pressed(KEY_SHIFT):
		axis.y += 1.0
	if Input.is_physical_key_pressed(KEY_CTRL):
		axis.y -= 1.0
	return axis


# Fly the camera for one frame along `axis` (see input_axis) at GameConfig.photo_move_speed.
# Forward/right are FLATTENED to horizontal, so looking at the sky doesn't turn W into
# "fly up" — that is what the y axis (Ctrl/Shift) is for, and it rides WORLD up
# regardless of where the camera is pointed. Diagonals are normalised, so holding two
# keys is not faster than one.
func apply_move(axis: Vector3, delta: float) -> void:
	if axis.length_squared() == 0.0:
		return
	var forward := -global_transform.basis.z
	forward = Vector3(forward.x, 0.0, forward.z)
	if forward.length_squared() < 0.0001:
		# Looking straight up or down: the flattened forward collapses, so fall back to
		# the direction the top of the frame points at, which is still horizontal there.
		# Looking UP (basis.z.y < 0), screen-up points BACKWARD, so forward is -up;
		# looking down it points forward, so forward is +up.
		var up := global_transform.basis.y
		forward = Vector3(up.x, 0.0, up.z) * (-1.0 if global_transform.basis.z.y < 0.0 else 1.0)
	forward = forward.normalized()
	var right := Vector3(-forward.z, 0.0, forward.x)
	var dir := (forward * axis.z + right * axis.x + Vector3.UP * axis.y).normalized()
	global_position += dir * Config.data.photo_move_speed * delta
	if max_range_m > 0.0:
		global_position = _origin + (global_position - _origin).limit_length(max_range_m)


func _input(event: InputEvent) -> void:
	if not _entered:
		return
	if event is InputEventMouseMotion and _wants_capture and event.device != InputEvent.DEVICE_ID_EMULATION:
		var motion := event as InputEventMouseMotion
		var sens: float = Config.data.photo_look_sensitivity
		look_by(-motion.relative.x * sens, -motion.relative.y * sens)
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if not _entered:
		return
	# Esc (ui_cancel) and gamepad Start (pause) both leave. The pause menu is DISARMED
	# while photo mode is up, so neither reaches it and stacks an overlay
	# over the frozen shot.
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("pause"):
		# Fetched first: exit() takes this camera out of the tree.
		var vp := get_viewport()
		exit()
		vp.set_input_as_handled()


# Turn the camera by a yaw/pitch DELTA in radians.
func look_by(yaw_delta: float, pitch_delta: float) -> void:
	_yaw = wrapf(_yaw + yaw_delta, -PI, PI)
	var limit := deg_to_rad(PITCH_LIMIT_DEG)
	_pitch = clampf(_pitch + pitch_delta, -limit, limit)
	_apply_look()


# Leave photo mode: hand the pointer back and tell the host. Safe to call twice.
func exit() -> void:
	if not _entered:
		return
	_entered = false
	touch_axis = Vector3.ZERO
	release_mouse()
	exited.emit()


# Scale the fov by `factor` (a pinch's separation ratio — >1 pinching apart, <1 pinching
# together) and clamp to the config's touch pinch-zoom range. Pinching apart zooms IN
# (narrower fov reads as "closer"), so factor multiplies the fov DOWN, not up.
func zoom_by(factor: float) -> void:
	if factor <= 0.0:
		return
	fov = clampf(fov / factor, Config.data.photo_fov_min, Config.data.photo_fov_max)


func is_active() -> bool:
	return _entered


func yaw() -> float:
	return _yaw


func pitch() -> float:
	return _pitch


# Rebuild the basis from yaw+pitch (no roll). Yaw first, then pitch about the new
# local right, so the horizon stays level however far the camera has spun.
func _apply_look() -> void:
	var b := Basis.IDENTITY
	b = b.rotated(Vector3.UP, _yaw)
	b = b.rotated(b.x, _pitch)
	global_transform = Transform3D(b, global_position)
