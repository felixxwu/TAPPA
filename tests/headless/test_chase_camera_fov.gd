extends GutTest
# Chase camera speed-FOV + dolly zoom. Behaviour contract only: the camera fields
# are set to synthetic values per test so the assertions don't pin authored tuning
# (chase_fov / boost / dolly_mix live in GameConfig and are free to change).

var _cam: Camera3D
var _target: RigidBody3D
var _saved_water := 0.0


func before_each() -> void:
	_saved_water = Config.data.track_water_level_m
	_target = RigidBody3D.new()
	_target.gravity_scale = 0.0
	add_child(_target)
	_cam = load("res://scripts/chase_camera.gd").new()
	_cam.target = _target
	add_child(_cam)  # _ready() caches config into the _* fields
	# Override with sane synthetic values so the test is independent of tuning.
	_cam._distance = 6.0
	_cam._height = 2.0
	_cam._base_fov = 80.0
	_cam._fov_speed_boost = 30.0
	_cam._fov_speed = 50.0
	_cam._fov_smoothing = 8.0
	_cam.fov = _cam._base_fov
	# Drive _physics_process by hand so we control the velocity read each step
	# (and it doesn't fight the physics server integrating the body).
	_cam.set_physics_process(false)


func after_each() -> void:
	Config.data.track_water_level_m = _saved_water
	_cam.free()
	_target.free()


# Settle the camera by feeding a constant horizontal velocity (aligned with the
# camera's initial travel direction, -Z, to avoid a degenerate slerp) for enough
# frames that the eased FOV/distance converge.
func _settle(speed: float) -> void:
	for _i in 240:
		_target.linear_velocity = Vector3(0.0, 0.0, -speed)
		_cam._physics_process(1.0 / 60.0)


func test_faster_widens_fov() -> void:
	_settle(0.0)
	var slow := _cam.fov
	_settle(200.0)
	var fast := _cam.fov
	assert_gt(fast, slow, "higher speed gives a wider FOV")


func test_standstill_settles_to_base_fov() -> void:
	_settle(0.0)
	assert_almost_eq(_cam.fov, _cam._base_fov, 0.5, "stationary FOV settles to the base FOV")


func test_camera_stays_above_the_water_surface() -> void:
	# No terrain sibling here, so the ground reads 0. A water level well above that must
	# lift the camera so it never seats below the lake surface (over a submerged basin).
	_cam._height = 2.0
	# The waterline is read live from the config, not cached on the camera.
	Config.data.track_water_level_m = 50.0
	_settle(10.0)
	assert_gt(_cam.global_position.y, 50.0,
		"chase camera is lifted above the water surface, not seated under the lake")


# On-screen size of a fixed object is proportional to 1/(distance · tan(fov/2)).
func _apparent_size_metric() -> float:
	var dist := _cam.global_position.distance_to(_target.global_position)
	return dist * tan(deg_to_rad(_cam.fov) * 0.5)


func test_full_dolly_holds_apparent_size() -> void:
	_cam._dolly_mix = 1.0
	_settle(0.0)
	var slow_metric := _apparent_size_metric()
	_settle(200.0)
	var fast_metric := _apparent_size_metric()
	# Full dolly zoom: distance · tan(fov/2) stays ~constant, so the car keeps its size.
	assert_almost_eq(fast_metric, slow_metric, slow_metric * 0.02,
		"full mix holds the car's on-screen size across speeds")


func test_zero_mix_leaves_distance_unchanged() -> void:
	_cam._dolly_mix = 0.0
	_settle(0.0)
	var slow_dist := _cam.global_position.distance_to(_target.global_position)
	_settle(200.0)
	var fast_dist := _cam.global_position.distance_to(_target.global_position)
	# No dolly: the follow distance is untouched even as the FOV widens.
	assert_almost_eq(fast_dist, slow_dist, 0.01,
		"zero mix keeps the follow distance constant (pure FOV zoom)")


# A target exposing half_length() reports its body's half length; the camera adds
# it to the follow distance (see chase_camera.gd).
class _LongCar extends RigidBody3D:
	var _half := 0.0
	func half_length() -> float:
		return _half


func test_half_length_pushes_camera_back() -> void:
	# Standstill + no dolly, so the camera sits at exactly the follow distance.
	_cam._dolly_mix = 0.0
	var long_car := _LongCar.new()
	long_car.gravity_scale = 0.0
	long_car._half = 3.0
	add_child(long_car)
	_cam.target = long_car
	for _i in 240:
		long_car.linear_velocity = Vector3.ZERO
		_cam._physics_process(1.0 / 60.0)
	var dist := _cam.global_position.distance_to(long_car.global_position)
	# 6.0 base follow distance + 3.0 half length.
	assert_almost_eq(dist, 9.0, 0.05, "half length is added to the follow distance")
	long_car.free()


# A target that looks enough like a car for the camera's nitrous probe: a `drivetrain`
# holding an EngineSim whose delivery flag the test drives by hand.
class _NitrousCar extends RigidBody3D:
	var drivetrain: RefCounted


class _FakeDrivetrain extends RefCounted:
	var engine: EngineSim


func _nitrous_car() -> _NitrousCar:
	var car := _NitrousCar.new()
	car.gravity_scale = 0.0
	var dt := _FakeDrivetrain.new()
	dt.engine = EngineSim.new(GameConfig.new())
	car.drivetrain = dt
	add_child(car)
	_cam.target = car
	# Take over as the fixture body so after_each frees this one (and not the plain body
	# from before_each, which nothing points at any more).
	_target.free()
	_target = car
	return car


func test_nitrous_widens_fov_while_delivering() -> void:
	var car := _nitrous_car()
	_cam._fov_nitrous_boost = 12.0
	for _i in 240:
		car.linear_velocity = Vector3(0.0, 0.0, -20.0)
		_cam._physics_process(1.0 / 60.0)
	var plain := _cam.fov
	car.drivetrain.engine.nitrous_delivering = true
	for _i in 240:
		car.linear_velocity = Vector3(0.0, 0.0, -20.0)
		_cam._physics_process(1.0 / 60.0)
	var boosted := _cam.fov
	assert_almost_eq(boosted - plain, 12.0, 0.5,
		"delivering nitrous adds the configured fixed FOV amount at the same speed")
	# And it eases back out when the boost stops — not a one-way ratchet.
	car.drivetrain.engine.nitrous_delivering = false
	for _i in 240:
		car.linear_velocity = Vector3(0.0, 0.0, -20.0)
		_cam._physics_process(1.0 / 60.0)
	assert_almost_eq(_cam.fov, plain, 0.5, "releasing nitrous returns the FOV to the speed ramp")


func test_held_nitrous_that_is_not_delivering_leaves_fov_alone() -> void:
	# nitrous_active (the button) is NOT the signal — an empty tank or a fuel cut makes no
	# torque, so it must make no FOV punch either.
	var car := _nitrous_car()
	_cam._fov_nitrous_boost = 12.0
	car.drivetrain.engine.nitrous_active = true
	car.drivetrain.engine.nitrous_delivering = false
	for _i in 240:
		car.linear_velocity = Vector3(0.0, 0.0, -20.0)
		_cam._physics_process(1.0 / 60.0)
	var held := _cam.fov
	_cam._fov_nitrous_boost = 0.0
	for _i in 240:
		car.linear_velocity = Vector3(0.0, 0.0, -20.0)
		_cam._physics_process(1.0 / 60.0)
	assert_almost_eq(held, _cam.fov, 0.5, "holding the button without delivery doesn't widen the FOV")


func test_target_without_a_drivetrain_is_safe() -> void:
	# The camera can be pointed at plain bodies (replay/ghost). The nitrous probe must not
	# assume a drivetrain.
	_cam._fov_nitrous_boost = 12.0
	_settle(20.0)
	assert_gt(_cam.fov, 0.0, "a target with no drivetrain still updates the FOV without erroring")


func test_more_mix_pulls_camera_closer() -> void:
	# A stronger mix should pull the camera in more at speed than a weaker one.
	_cam._dolly_mix = 0.25
	_settle(200.0)
	var weak_dist := _cam.global_position.distance_to(_target.global_position)
	_cam._dolly_mix = 1.0
	_settle(200.0)
	var strong_dist := _cam.global_position.distance_to(_target.global_position)
	assert_lt(strong_dist, weak_dist, "a higher dolly mix pulls the camera closer at speed")
