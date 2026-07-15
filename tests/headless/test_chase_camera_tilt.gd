extends GutTest
# Chase camera g-force lean. Behaviour contract only: the tilt fields are set to
# synthetic values per test so the assertions test the LOGIC (which way a given
# acceleration leans the view, that it clamps, that it decays back to level) and
# never pin the authored gains/max/smoothing (which live in GameConfig).

var _cam: Camera3D
var _target: RigidBody3D


func before_each() -> void:
	_target = RigidBody3D.new()
	_target.gravity_scale = 0.0
	add_child(_target)
	_cam = load("res://scripts/chase_camera.gd").new()
	_cam.target = _target
	add_child(_cam)  # _ready() caches config into the _* fields
	# Sane synthetic follow values (as in test_chase_camera_fov).
	_cam._distance = 6.0
	_cam._height = 2.0
	_cam._base_fov = 80.0
	_cam._fov_speed_boost = 30.0
	_cam._fov_speed = 50.0
	_cam._fov_smoothing = 8.0
	_cam.fov = _cam._base_fov
	# Synthetic tilt tuning so the test is independent of the authored values.
	_cam._tilt_roll_gain = 1.0
	_cam._tilt_pitch_gain = 1.0
	_cam._tilt_max = deg_to_rad(10.0)
	_cam._tilt_smoothing = 8.0
	# Drive _physics_process by hand so we control the velocity read each step.
	_cam.set_physics_process(false)


func after_each() -> void:
	_cam.free()
	_target.free()


# Tear down and rebuild the rig within a test (for driving a second, opposite
# acceleration from a clean, un-leaned state) without leaking the first rig.
func _reset() -> void:
	after_each()
	before_each()


# Feed a constant world-space acceleration for `frames` steps by ramping the
# body's velocity, so (v - prev_v)/dt reads back as `accel` each frame.
func _drive_accel(accel: Vector3, frames: int) -> void:
	var dt := 1.0 / 60.0
	for _i in frames:
		_target.linear_velocity += accel * dt
		_cam._physics_process(dt)


# Hold the velocity constant (zero acceleration) so the eased tilt relaxes.
func _coast(frames: int) -> void:
	var dt := 1.0 / 60.0
	for _i in frames:
		_cam._physics_process(dt)


func test_rightward_accel_rolls_one_way() -> void:
	# Target at identity basis: +X is the car's local right. A positive roll gain
	# plus rightward acceleration must produce a definite, consistent roll sign.
	_drive_accel(Vector3(30.0, 0.0, 0.0), 120)
	var right_roll: float = _cam._roll
	assert_ne(right_roll, 0.0, "lateral acceleration leans the view (nonzero roll)")

	# Reverse the acceleration: the roll must flip to the opposite sign.
	_reset()
	_drive_accel(Vector3(-30.0, 0.0, 0.0), 120)
	assert_lt(_cam._roll * right_roll, 0.0, "opposite lateral g rolls the other way")


func test_throttle_and_brake_pitch_opposite_ways() -> void:
	# Forward is -Z at identity. Accelerating forward (velocity growing along -Z)
	# and decelerating (growing along +Z) must pitch the view opposite ways.
	_drive_accel(Vector3(0.0, 0.0, -30.0), 120)
	var throttle_pitch: float = _cam._pitch
	assert_ne(throttle_pitch, 0.0, "forward acceleration pitches the view (nonzero pitch)")

	_reset()
	_drive_accel(Vector3(0.0, 0.0, 30.0), 120)
	assert_lt(_cam._pitch * throttle_pitch, 0.0, "braking pitches opposite to throttle")


func test_tilt_is_clamped_to_max() -> void:
	# A huge sustained acceleration must not tilt past the configured max.
	_drive_accel(Vector3(500.0, 0.0, -500.0), 200)
	assert_lte(absf(_cam._roll), _cam._tilt_max + 1e-4, "roll never exceeds the max tilt")
	assert_lte(absf(_cam._pitch), _cam._tilt_max + 1e-4, "pitch never exceeds the max tilt")


func test_tilt_decays_to_level_when_g_forces_drop() -> void:
	# Build up a lean, then coast (zero acceleration): the tilt eases back to level.
	_drive_accel(Vector3(30.0, 0.0, -30.0), 120)
	assert_gt(absf(_cam._roll) + absf(_cam._pitch), 0.001, "there is a lean to decay from")
	_coast(600)
	assert_almost_eq(_cam._roll, 0.0, 0.001, "roll relaxes back to level")
	assert_almost_eq(_cam._pitch, 0.0, 0.001, "pitch relaxes back to level")
