extends GutTest
# RWD / AWD / FWD drivetrain layouts: torque routing and the mode cycle.

var _scene: Node3D
var _car: VehicleBody3D


func before_each() -> void:
	# Pin the frozen test car: another scene's car selection mutates the shared
	# Config singleton, and these assertions are calibrated to the stable test
	# baseline (fixtures/test_config.tres), not the shipped gameplay tuning.
	SceneTestHelpers.use_test_config()
	_scene = load("res://tests/fixtures/test_track.tscn").instantiate()
	add_child_autofree(_scene)
	_car = _scene.get_node("Car")
	_car.drivetrain.engine.auto = false  # deterministic gear during launch tests
	await _wait_physics(150)


func after_each() -> void:
	Input.action_release("accelerate")


func _wait_physics(frames: int):
	for i in frames:
		await get_tree().physics_frame


func _front_avg_surface() -> float:
	var dt: Drivetrain = _car.drivetrain
	var total := 0.0
	for w in dt.front_omega:
		total += dt.front_omega[w]
	return total / dt.front_omega.size() * Config.data.wheel_radius


func test_default_mode_is_rwd() -> void:
	assert_eq(_car.drivetrain.drive_mode, Drivetrain.DriveMode.RWD, "ships in RWD")


func test_routing_helpers_per_mode() -> void:
	var dt: Drivetrain = _car.drivetrain
	dt.rear_omega = 10.0
	for w in dt.front_omega:
		dt.front_omega[w] = 20.0
	dt.drive_mode = Drivetrain.DriveMode.RWD
	assert_almost_eq(dt.driveline_omega(), 10.0, 0.01, "RWD geared to the rear axle")
	dt.drive_mode = Drivetrain.DriveMode.FWD
	assert_almost_eq(dt.driveline_omega(), 20.0, 0.01, "FWD geared to the front spool")
	dt.drive_mode = Drivetrain.DriveMode.AWD
	assert_almost_eq(dt.driveline_omega(), 10.0, 0.01,
		"AWD locked centre diff geared to the shared driveline (rear) speed")


func test_cycle_wraps_rwd_awd_fwd() -> void:
	var dt: Drivetrain = _car.drivetrain
	dt.drive_mode = Drivetrain.DriveMode.RWD
	dt.cycle_drive_mode()
	assert_eq(dt.drive_mode, Drivetrain.DriveMode.AWD, "RWD -> AWD")
	dt.cycle_drive_mode()
	assert_eq(dt.drive_mode, Drivetrain.DriveMode.FWD, "AWD -> FWD")
	dt.cycle_drive_mode()
	assert_eq(dt.drive_mode, Drivetrain.DriveMode.RWD, "FWD -> RWD")


func test_fwd_spins_fronts_and_leaves_rear_rolling() -> void:
	# Full throttle launch in FWD: the front wheels must spin (surface speed
	# well past the grip peak) while the undriven rear axle just free-rolls
	# at ground speed.
	_car.drivetrain.drive_mode = Drivetrain.DriveMode.FWD
	Input.action_press("accelerate")
	await _wait_physics(20)
	Input.action_release("accelerate")
	var cfg: GameConfig = Config.data
	var speed := _car.linear_velocity.length()
	var rear_surface: float = _car.drivetrain.rear_omega * cfg.wheel_radius
	assert_gt(_front_avg_surface() - speed, cfg.tire_slip_peak + 0.5,
		"front wheels spin under power in FWD")
	assert_lt(absf(rear_surface - speed), 1.5, "undriven rear free-rolls at ground speed in FWD")


func test_awd_locks_front_to_rear() -> void:
	# Locked centre diff: under power in AWD the front spool is rigidly tied to
	# the rear, so every front wheel turns at exactly the rear axle speed (an
	# open diff would let the gripping fronts roll nearer ground speed).
	var dt: Drivetrain = _car.drivetrain
	dt.drive_mode = Drivetrain.DriveMode.AWD
	Input.action_press("accelerate")
	await _wait_physics(20)
	Input.action_release("accelerate")
	for w in dt.front_omega:
		assert_almost_eq(dt.front_omega[w], dt.rear_omega, 0.001,
			"AWD locks the front spool to the rear axle")
	var cfg: GameConfig = Config.data
	# AWD drives all four wheels, so it grips harder and spins less than RWD;
	# the launch still slips past the grip peak (genuine wheelspin). Margin
	# trimmed 0.3 -> 0.1 when the RPM-dependent engine-friction model cut WOT
	# torque ~13%, then 0.1 -> 0.05 when the roll/pitch tuning change
	# (wheel_roll_influence 1.0 -> 0.5, longitudinal force applied at the
	# roll-scaled height) further reduced launch wheelspin (slip ~1.56 vs peak
	# 1.5) — still a clear margin past peak, just smaller. Calibrated against the
	# frozen test car (fixtures/test_config.tres), not the shipped tuning.
	var slip: float = dt.rear_omega * cfg.wheel_radius - _car.linear_velocity.length()
	assert_gt(slip, cfg.tire_slip_peak + 0.05, "the locked driveline spins under power")


func test_fwd_locks_front_axle_into_spool() -> void:
	# Locked front diff in FWD: two front wheels seeded at different speeds must
	# converge to a single spool speed (an open diff integrates them apart).
	var dt: Drivetrain = _car.drivetrain
	dt.drive_mode = Drivetrain.DriveMode.FWD
	var ws: Array = dt.front_omega.keys()
	dt.front_omega[ws[0]] = 30.0
	dt.front_omega[ws[1]] = 10.0
	Input.action_press("accelerate")
	await _wait_physics(5)
	Input.action_release("accelerate")
	assert_almost_eq(dt.front_omega[ws[0]], dt.front_omega[ws[1]], 0.001,
		"FWD front wheels share one locked spool speed")
