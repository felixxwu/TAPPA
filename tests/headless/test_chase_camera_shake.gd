extends GutTest
# Chase-camera shake (features/camera.md → "Camera shake").
#
# One amplitude fed by four sources: an IMPULSIVE g-force term that covers every impact in the
# game, and continuous speed / wheelspin / nitrous terms. Behaviour contract only — the shake
# fields are set to synthetic values per test so nothing here pins the authored tuning
# (shake_max_deg and the gains all live in GameConfig and are free to change).

var _cam: Camera3D
var _target: RigidBody3D


func before_each() -> void:
	_target = RigidBody3D.new()
	_target.gravity_scale = 0.0
	add_child(_target)
	_cam = load("res://scripts/chase_camera.gd").new()
	_cam.target = _target
	add_child(_cam)  # _ready() caches config into the _* fields
	_cam._distance = 6.0
	_cam._height = 2.0
	_cam._base_fov = 80.0
	_cam._fov_speed_boost = 0.0   # keep the FOV still; this file is about rotation
	_cam._fov_speed = 50.0
	_cam._fov_smoothing = 8.0
	_cam._fov_nitrous_boost = 0.0
	# The g-force LEAN is a separate effect that also rotates the camera — zero it so every
	# rotation measured here is shake and nothing else.
	_cam._tilt_roll_gain = 0.0
	_cam._tilt_pitch_gain = 0.0
	# Synthetic shake tuning: one degree of amplitude, one source at a time.
	_cam._shake_max = deg_to_rad(1.0)
	_cam._shake_frequency = 13.0
	_cam._shake_decay = 7.0
	_cam._shake_g_threshold = 2.0
	_cam._shake_g_gain = 0.5
	_cam._shake_speed_gain = 0.0
	_cam._shake_wheelspin_gain = 0.0
	_cam._shake_nitrous_gain = 0.0
	_cam.fov = _cam._base_fov
	_cam.set_physics_process(false)


func after_each() -> void:
	_cam.free()
	_target.free()


# How far the camera's forward axis is off the aim direction, in radians. Shake is the only
# thing rotating the camera in this fixture (the lean gains are zeroed), so this IS the shake.
func _aim_error() -> float:
	var to_target := _target.global_position - _cam.global_position
	if to_target.length() <= 0.001:
		return 0.0
	return absf((-_cam.global_transform.basis.z).angle_to(to_target.normalized()))


# Step the camera `frames` times at a constant velocity, returning the WORST aim error seen —
# the shake oscillates through zero, so a single sample says nothing.
func _worst_error_over(frames: int, speed: float) -> float:
	var worst := 0.0
	for _i in frames:
		_target.linear_velocity = Vector3(0.0, 0.0, -speed)
		_cam._physics_process(1.0 / 60.0)
		worst = maxf(worst, _aim_error())
	return worst


func test_a_calm_car_does_not_shake() -> void:
	# Cruising at a steady speed with every gain off must leave the shot dead still, or the
	# effect is a permanent wobble rather than a reaction to anything.
	var worst := _worst_error_over(120, 20.0)
	assert_almost_eq(worst, 0.0, 1e-4, "no source active leaves the aim untouched (%.5f rad)" % worst)


func test_a_g_force_spike_shakes_the_camera() -> void:
	# THE impact source: a crash, a hard landing and a clipped bush are all one acceleration
	# spike, so this single term covers them with no per-event wiring.
	_worst_error_over(30, 20.0)  # settle
	# A violent change of velocity in one tick — tens of g, as an arrest would be.
	_target.linear_velocity = Vector3(0.0, 0.0, -20.0)
	_cam._physics_process(1.0 / 60.0)
	_target.linear_velocity = Vector3(0.0, 0.0, 0.0)
	_cam._physics_process(1.0 / 60.0)
	assert_gt(_cam._shake_impulse, 0.0, "the impact charged the shake envelope")
	var worst := 0.0
	for _i in 10:
		_cam._physics_process(1.0 / 60.0)
		worst = maxf(worst, _aim_error())
	assert_gt(worst, 1e-4, "the impact visibly disturbs the aim (%.5f rad)" % worst)


func test_an_impulse_decays_back_to_stillness() -> void:
	# An impact must be felt for a moment and then be over — a shake that never settles reads
	# as a broken camera.
	_target.linear_velocity = Vector3(0.0, 0.0, -30.0)
	_cam._physics_process(1.0 / 60.0)
	_target.linear_velocity = Vector3.ZERO
	_cam._physics_process(1.0 / 60.0)
	var charged: float = _cam._shake_impulse
	for _i in 180:
		_cam._physics_process(1.0 / 60.0)
	assert_gt(charged, 0.0, "precondition: the impulse charged")
	assert_lt(_cam._shake_impulse, charged * 0.05,
		"the impulse decays away (%.4f from %.4f)" % [_cam._shake_impulse, charged])


func test_a_gentle_acceleration_below_the_threshold_does_not_shake() -> void:
	# The threshold is what keeps ordinary cornering, braking and a steady fall quiet. 1 g of
	# acceleration with the threshold at 2 g must produce nothing.
	var one_g_per_tick := 9.8 / 60.0
	var worst := 0.0
	for i in 120:
		_target.linear_velocity = Vector3(0.0, 0.0, -(one_g_per_tick * float(i)))
		_cam._physics_process(1.0 / 60.0)
		worst = maxf(worst, _aim_error())
	assert_almost_eq(worst, 0.0, 1e-4,
		"a 1 g pull under a 2 g threshold leaves the shot still (%.5f rad)" % worst)


func test_speed_alone_adds_a_continuous_shake() -> void:
	# The speed term is a constant buzz, not an event: fast must shake more than slow, with no
	# impact involved at all.
	_cam._shake_speed_gain = 1.0
	var slow := _worst_error_over(120, 1.0)
	var fast := _worst_error_over(120, 50.0)
	assert_gt(fast, slow, "more speed shakes more (%.5f vs %.5f rad)" % [fast, slow])


func test_the_shake_stops_when_a_continuous_source_stops() -> void:
	# Continuous sources are re-read every tick and never latch, so removing the cause removes
	# the shake immediately rather than leaving it ringing.
	_cam._shake_speed_gain = 1.0
	# The g-force source off: stopping dead from 50 m/s in one tick is itself a violent impact,
	# and its (correct) impulse shake would mask the thing under test.
	_cam._shake_g_gain = 0.0
	var moving := _worst_error_over(120, 50.0)
	var stopped := _worst_error_over(120, 0.0)
	assert_gt(moving, 1e-4, "precondition: speed was shaking the camera")
	assert_almost_eq(stopped, 0.0, 1e-4, "the buzz ends with the speed (%.5f rad)" % stopped)


# A target that looks enough like a car for the shake's wheelspin and nitrous probes.
class _FakeCar extends RigidBody3D:
	var drivetrain: RefCounted


class _FakeDrivetrain extends RefCounted:
	var engine: EngineSim
	var spin := 0.0
	func drive_wheelspin_excess() -> float:
		return spin


func _fake_car() -> _FakeCar:
	var car := _FakeCar.new()
	car.gravity_scale = 0.0
	var dt := _FakeDrivetrain.new()
	dt.engine = EngineSim.new(GameConfig.new())
	car.drivetrain = dt
	add_child(car)
	_cam.target = car
	_target.free()
	_target = car
	return car


func test_wheelspin_shakes_the_camera() -> void:
	var car := _fake_car()
	_cam._shake_wheelspin_gain = 1.0
	var gripping := _worst_error_over(120, 20.0)
	car.drivetrain.spin = 0.8  # the worst driven tire is well past fore/aft breakaway
	var spinning := _worst_error_over(120, 20.0)
	assert_almost_eq(gripping, 0.0, 1e-4, "a gripping car does not shake from wheelspin")
	assert_gt(spinning, 1e-4, "breaking traction shakes the camera (%.5f rad)" % spinning)


func test_delivering_nitrous_shakes_the_camera() -> void:
	var car := _fake_car()
	_cam._shake_nitrous_gain = 1.0
	var off := _worst_error_over(120, 20.0)
	car.drivetrain.engine.nitrous_delivering = true
	var on := _worst_error_over(120, 20.0)
	assert_almost_eq(off, 0.0, 1e-4, "no shake with the bottle shut")
	assert_gt(on, 1e-4, "delivering nitrous shakes the camera (%.5f rad)" % on)
	# Same signal as the FOV punch: the button alone is not it.
	car.drivetrain.engine.nitrous_delivering = false
	car.drivetrain.engine.nitrous_active = true
	var held := _worst_error_over(120, 20.0)
	assert_almost_eq(held, 0.0, 1e-4, "holding the button without delivery shakes nothing")


func test_sources_stack_but_stay_bounded_by_the_amplitude() -> void:
	# Every source at once must not exceed the one amplitude dial — simultaneous events stack
	# into the cap, never through it. The bound is generous (three rotations compose, and the
	# aim error is their combined angle) but must not scale with how many sources fired.
	var car := _fake_car()
	_cam._shake_speed_gain = 1.0
	_cam._shake_wheelspin_gain = 1.0
	_cam._shake_nitrous_gain = 1.0
	_cam._shake_g_gain = 10.0
	car.drivetrain.spin = 5.0
	car.drivetrain.engine.nitrous_delivering = true
	var worst := 0.0
	for i in 240:
		# Keep hammering it with violent velocity changes on top of everything else.
		_target.linear_velocity = Vector3(0.0, 0.0, -50.0 if i % 2 == 0 else 0.0)
		_cam._physics_process(1.0 / 60.0)
		worst = maxf(worst, _aim_error())
	assert_gt(worst, 1e-4, "precondition: it is shaking")
	assert_lte(_cam._shake_impulse, 1.0 + 1e-6, "the impulse envelope cannot charge past full")
	assert_lt(worst, _cam._shake_max * 3.0,
		"stacked sources stay inside the amplitude cap (%.5f rad vs %.5f max)"
			% [worst, _cam._shake_max])


func test_zero_amplitude_disables_shake_entirely() -> void:
	# shake_max_deg is the master switch: at 0 no source may move the camera, and the whole
	# per-tick cost is skipped.
	var car := _fake_car()
	_cam._shake_max = 0.0
	_cam._shake_speed_gain = 1.0
	_cam._shake_wheelspin_gain = 1.0
	_cam._shake_nitrous_gain = 1.0
	car.drivetrain.spin = 5.0
	car.drivetrain.engine.nitrous_delivering = true
	var worst := _worst_error_over(120, 50.0)
	assert_almost_eq(worst, 0.0, 1e-6, "zero amplitude leaves the aim exact (%.6f rad)" % worst)
	assert_eq(_cam._shake_phase, 0.0, "and the shake does no per-tick work at all")


func test_the_shake_is_deterministic() -> void:
	# Layered sines on a phase accumulator, not randf: the same run must shake the same way, so
	# a replay matches and this suite can assert on it at all.
	_cam._shake_speed_gain = 1.0
	var first := _worst_error_over(60, 40.0)
	_cam._shake_phase = 0.0
	var second := _worst_error_over(60, 40.0)
	assert_almost_eq(first, second, 1e-9, "the same phase gives the same shake")


func test_a_target_without_a_drivetrain_is_safe() -> void:
	# The chase camera is also pointed at replay and ghost bodies, which have no drivetrain.
	_cam._shake_speed_gain = 1.0
	_cam._shake_wheelspin_gain = 1.0
	_cam._shake_nitrous_gain = 1.0
	var worst := _worst_error_over(60, 30.0)
	assert_gt(worst, 0.0, "a plain body still shakes from the sources that apply to it")
