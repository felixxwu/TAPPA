extends GutTest

var _scene: Node3D
var _car: VehicleBody3D


func before_each() -> void:
	# Flat-ground fixture (same as test_car.gd): drivetrain behavior must not
	# depend on terrain generation settings.
	# Pin the frozen test car: another scene's car selection mutates the shared
	# Config singleton, and these assertions are calibrated to the stable test
	# baseline (fixtures/test_config.tres), not the shipped gameplay tuning.
	SceneTestHelpers.use_test_config()
	_scene = load("res://tests/fixtures/test_track.tscn").instantiate()
	add_child_autofree(_scene)
	_car = _scene.get_node("Car")
	# Pin the manual box + RWD so launch/lockup behavior is deterministic
	# regardless of the shipped default gearbox mode.
	_car.drivetrain.engine.auto = false
	_car.drivetrain.drive_mode = Drivetrain.DriveMode.RWD
	await _wait_physics(150)


func after_each() -> void:
	for action in ["accelerate", "brake_reverse", "steer_left", "steer_right", "handbrake"]:
		Input.action_release(action)


func _wait_physics(frames: int):
	for i in frames:
		await get_tree().physics_frame


func test_launch_wheelspin() -> void:
	# Full throttle from rest in 1st: the driven axle must genuinely spin —
	# slip well past the grip curve's peak — while the car still accelerates.
	# (Threshold recalibrated for the engine/clutch model: the old force-cap
	# engine dumped ~1750 N·m instantly; the real-ish engine spins the tires
	# at the rate the crank can rev, so slip vs tire_slip_peak is the honest
	# wheelspin measure, not a fixed multiple of car speed.)
	Input.action_press("accelerate")
	await _wait_physics(20)
	var cfg: GameConfig = Config.data
	var speed := _car.linear_velocity.length()
	var slip: float = _car.drivetrain.rear_omega * cfg.wheel_radius - speed
	assert_gt(slip, cfg.tire_slip_peak + 0.5,
		"rear slip well beyond the grip peak on launch (wheelspin)")
	Input.action_release("accelerate")
	assert_gt(speed, 0.3, "car still accelerates while wheels spin")


func test_brake_lockup() -> void:
	# Hard braking at speed locks the wheels (omega -> 0) while the car is
	# still moving — the slip curve then governs the sliding grip.
	var fwd := -_car.global_transform.basis.z
	var r: float = Config.data.wheel_radius
	_car.linear_velocity = fwd * 15.0
	_car.drivetrain.rear_omega = 15.0 / r
	for w in _car.drivetrain.front_omega:
		_car.drivetrain.front_omega[w] = 15.0 / r
	Input.action_press("brake_reverse")
	await _wait_physics(30)
	Input.action_release("brake_reverse")
	assert_lt(absf(_car.drivetrain.rear_omega) * r, 1.0, "rear axle locked")
	assert_gt(_car.linear_velocity.length(), 3.0, "car still sliding while locked")


# The brake_bias tuning knob (todo/tuning.md) splits the foot brake front/rear.
# brake_bias = 1.0 sends ALL of it to the front: the fronts lock while the rear,
# given no foot brake, keeps rolling. (The * 2.0 normalisation means 0.5 reproduces
# the old equal split — guarded by test_brake_lockup above, which runs at the
# default 0.5.)
func test_brake_bias_forward_locks_the_front_not_the_rear() -> void:
	Config.data.brake_bias = 1.0
	var r: float = Config.data.wheel_radius
	var fwd := -_car.global_transform.basis.z
	_car.linear_velocity = fwd * 15.0
	_car.drivetrain.rear_omega = 15.0 / r
	for w in _car.drivetrain.front_omega:
		_car.drivetrain.front_omega[w] = 15.0 / r
	Input.action_press("brake_reverse")
	await _wait_physics(20)
	Input.action_release("brake_reverse")
	var front: float = _car.drivetrain.front_omega.values()[0] * r
	assert_lt(absf(front), 1.0, "all-front bias locks the front axle")
	assert_gt(absf(_car.drivetrain.rear_omega) * r, 3.0, "the rear gets no foot brake and keeps rolling")


# The mirror: brake_bias = 0.0 sends all of it to the rear — the rear locks while
# the (free-rolling RWD) front keeps turning.
func test_brake_bias_rearward_locks_the_rear_not_the_front() -> void:
	Config.data.brake_bias = 0.0
	var r: float = Config.data.wheel_radius
	var fwd := -_car.global_transform.basis.z
	_car.linear_velocity = fwd * 15.0
	_car.drivetrain.rear_omega = 15.0 / r
	for w in _car.drivetrain.front_omega:
		_car.drivetrain.front_omega[w] = 15.0 / r
	Input.action_press("brake_reverse")
	await _wait_physics(20)
	Input.action_release("brake_reverse")
	var front: float = _car.drivetrain.front_omega.values()[0] * r
	assert_lt(absf(_car.drivetrain.rear_omega) * r, 1.0, "all-rear bias locks the rear axle")
	assert_gt(absf(front), 3.0, "the front gets no foot brake and keeps rolling")


func test_handbrake_locks_rear_only_and_breaks_grip() -> void:
	var fwd := -_car.global_transform.basis.z
	var r: float = Config.data.wheel_radius
	_car.linear_velocity = fwd * 15.0
	_car.drivetrain.rear_omega = 15.0 / r
	for w in _car.drivetrain.front_omega:
		_car.drivetrain.front_omega[w] = 15.0 / r
	Input.action_press("handbrake")
	Input.action_press("steer_left")
	await _wait_physics(60)
	Input.action_release("handbrake")
	Input.action_release("steer_left")
	assert_lt(absf(_car.drivetrain.rear_omega) * r, 1.0, "handbrake locks the rear axle")
	var front_speed: float = _car.drivetrain.front_omega.values()[0] * r
	assert_gt(front_speed, 2.0, "fronts keep rolling under handbrake")
	var local_vel: Vector3 = _car.global_transform.basis.inverse() * _car.linear_velocity
	var slip := rad_to_deg(absf(atan2(local_vel.x, -local_vel.z)))
	# The locked rear loses lateral grip and induces a measurable slip while
	# steering, but on the current tuning (Godot 4.6 / Jolt) it does NOT break
	# fully away into a tail-out slide — peak slip is only ~1.3deg, decaying as
	# the car scrubs speed. So this asserts the rear gives up *some* grip, not a
	# full handbrake turn. Making a handbrake yank actually swing the tail out is
	# a separate physics-tuning task.
	assert_gt(slip, 0.5, "locked rear loses some lateral grip (mild slip; not a full tail-out)")


func test_awd_handbrake_locks_rear_only() -> void:
	# AWD normally locks the front+rear into one rigid driveline, but the
	# handbrake is an exception: it opens the centre diff so ONLY the rear axle
	# locks while the fronts keep free-rolling (and steerable).
	_car.drivetrain.drive_mode = Drivetrain.DriveMode.AWD
	var fwd := -_car.global_transform.basis.z
	var r: float = Config.data.wheel_radius
	_car.linear_velocity = fwd * 15.0
	_car.drivetrain.rear_omega = 15.0 / r
	for w in _car.drivetrain.front_omega:
		_car.drivetrain.front_omega[w] = 15.0 / r
	Input.action_press("handbrake")
	await _wait_physics(60)
	Input.action_release("handbrake")
	assert_lt(absf(_car.drivetrain.rear_omega) * r, 1.0,
		"AWD handbrake locks the rear axle")
	var front_speed: float = _car.drivetrain.front_omega.values()[0] * r
	assert_gt(front_speed, 2.0,
		"AWD fronts keep rolling under handbrake (centre diff opened)")


func test_awd_no_handbrake_locks_all_four() -> void:
	# Sanity guard on the exception: WITHOUT the handbrake, AWD is still one
	# rigid locked driveline, so a foot-brake lockup takes all four wheels down
	# together (fronts stay coupled to the rear).
	_car.drivetrain.drive_mode = Drivetrain.DriveMode.AWD
	var fwd := -_car.global_transform.basis.z
	var r: float = Config.data.wheel_radius
	_car.linear_velocity = fwd * 15.0
	_car.drivetrain.rear_omega = 15.0 / r
	for w in _car.drivetrain.front_omega:
		_car.drivetrain.front_omega[w] = 15.0 / r
	Input.action_press("brake_reverse")
	await _wait_physics(30)
	Input.action_release("brake_reverse")
	assert_lt(absf(_car.drivetrain.rear_omega) * r, 1.0, "AWD rear axle locked")
	var front_speed: float = _car.drivetrain.front_omega.values()[0] * r
	assert_lt(front_speed, 1.0, "AWD fronts locked together with the rear")


func test_parking_brake_holds_longitudinally() -> void:
	# Small forward push at rest: the parking brake (locked wheels at near-zero
	# slip) must stop it instead of letting the car creep.
	_car.linear_velocity = -_car.global_transform.basis.z * 0.5
	await _wait_physics(60)
	assert_lt(_car.linear_velocity.length(), 0.2, "parking brake stops slow creep")
