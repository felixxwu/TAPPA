class_name PhotoModeCamera
extends Camera3D
# Docs: features/camera.md, features/menus.md — update in the same change as this file.
# Tests: tests/headless/test_photo_mode.gd, tests/headless/test_pause_menu.gd — extend in the same change.
# Free-fly PHOTO MODE camera. Opened from the in-run pause menu, it takes over the
# viewport while the tree stays PAUSED (`get_tree().paused` is left exactly as the
# pause menu set it), so the whole world — car, physics, particles, timers — is frozen
# in place and only the viewpoint moves.
#
# Controls (deliberately RAW physical keys, not InputMap actions): WASD moves laterally
# in the camera's horizontal plane, Ctrl/Shift drop and raise altitude on the WORLD Y
# axis, the mouse looks around (captured pointer), Esc leaves. Raw keys because every
# gameplay action here is rebindable (`InputRemap`) and W/A/S/D are the DRIVING binds —
# routing photo movement through them would make photo mode follow a rebind of the
# throttle, and there is no action for Ctrl/Shift to begin with. `ui_cancel` IS an
# action (Esc / gamepad B) because backing out of a mode is a menu gesture.
#
# Lifetime is owned by world.gd (`_on_photo_mode_requested`): it creates one, calls
# enter(), and frees it on `exited`. See features/camera.md.

# Emitted when the player presses Esc. The host frees this camera, restores the
# gameplay camera and re-opens the pause menu.
signal exited

const PITCH_LIMIT_DEG := 89.0

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
	apply_move(input_axis(), delta)


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


func _input(event: InputEvent) -> void:
	if not _entered:
		return
	if event is InputEventMouseMotion and _wants_capture:
		var motion := event as InputEventMouseMotion
		var sens: float = Config.data.photo_look_sensitivity
		look_by(-motion.relative.x * sens, -motion.relative.y * sens)
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if not _entered:
		return
	# Esc (ui_cancel) and gamepad Start (pause) both leave. The pause menu is DISARMED
	# while photo mode is up (world.gd), so neither reaches it and stacks an overlay
	# over the frozen shot.
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("pause"):
		exit()
		get_viewport().set_input_as_handled()


# Turn the camera by a yaw/pitch DELTA in radians. Public so the tests (and any future
# gamepad stick binding) can drive the look without synthesising mouse motion.
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
	release_mouse()
	exited.emit()


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
