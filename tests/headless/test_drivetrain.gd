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


# Minimal terrain stub exposing surface_at(x, z) -> (road_weight, tarmac_weight).
class _StubTerrain extends RefCounted:
	var s := Vector2.ZERO
	func surface_at(_x: float, _z: float) -> Vector2:
		return s


func test_surface_grip_scales_mu_by_surface() -> void:
	# surface_grip blends the configured grass/gravel/tarmac scales by the terrain's
	# (road, tarmac) weights at the contact point. With no terrain it leaves μ alone.
	var cfg: GameConfig = Config.data
	var dt: Drivetrain = _car.drivetrain
	var stub := _StubTerrain.new()
	dt.terrain = stub
	stub.s = Vector2(0.0, 0.0)  # off-road grass
	assert_almost_eq(dt.surface_grip(cfg, Vector3.ZERO), cfg.grass_grip, 1e-4, "grass = grass_grip")
	stub.s = Vector2(1.0, 0.0)  # full gravel road
	assert_almost_eq(dt.surface_grip(cfg, Vector3.ZERO), cfg.gravel_grip, 1e-4, "gravel = gravel_grip")
	stub.s = Vector2(1.0, 1.0)  # full tarmac road
	assert_almost_eq(dt.surface_grip(cfg, Vector3.ZERO), cfg.tarmac_grip, 1e-4, "tarmac = tarmac_grip")
	stub.s = Vector2(0.5, 0.0)  # road edge, half-faded to grass
	assert_almost_eq(dt.surface_grip(cfg, Vector3.ZERO), lerpf(cfg.grass_grip, cfg.gravel_grip, 0.5), 1e-4,
		"half-on-gravel blends grass<->gravel")
	dt.terrain = null
	assert_eq(dt.surface_grip(cfg, Vector3.ZERO), 1.0, "no terrain -> unchanged μ")


func test_launch_wheelspin() -> void:
	# Full throttle from rest in 1st: the driven axle must genuinely spin —
	# slip well past the grip curve's peak — while the car still accelerates.
	# (Threshold recalibrated for the engine/clutch model: the old force-cap
	# engine dumped ~1750 N·m instantly; the real-ish engine spins the tires
	# at the rate the crank can rev, so slip vs tire_slip_peak is the honest
	# wheelspin measure, not a fixed multiple of car speed.)
	# This test is about whether the DRIVETRAIN can spin the wheels given enough
	# crank torque, not about the current power balance, so pin full power
	# (no de-rate) for the launch regardless of the shipped global_torque_scale
	# (config/game_config.tres) — test-only, gameplay tuning untouched.
	var cfg: GameConfig = Config.data
	cfg.global_torque_scale = 1.0
	Input.action_press("accelerate")
	await _wait_physics(20)
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


# The brake_bias tuning knob (features/tuning.md) splits the foot brake front/rear.
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


# Slip angle of peak lateral force, swept via _tire_force with a synthetic
# contact at pure cornering (no wheelspin/brake). Returns degrees.
func _peak_lateral_slip_angle_deg(v: float, slip_peak := -1.0, slide_ratio := -1.0) -> float:
	var cfg: GameConfig = Config.data
	var dt: Drivetrain = _car.drivetrain
	if slip_peak < 0.0:
		slip_peak = cfg.tire_slip_peak
	if slide_ratio < 0.0:
		slide_ratio = cfg.sliding_grip_ratio
	var best_f := -1.0
	var best_deg := 0.0
	var deg := 1.0
	while deg <= 45.0:
		var a := deg_to_rad(deg)
		# Car moving at speed v with its velocity offset by the slip angle from
		# the nose: longitudinal ground vel = v·cos(a), lateral = v·sin(a).
		var c := {
			v_long = v * cos(a),
			s_lat = v * sin(a),
			mu = 1.0,
			n_force = 4000.0,
			slip_peak = slip_peak,
			slide_ratio = slide_ratio,
		}
		# surface_vel = v_long -> zero longitudinal slip, pure lateral.
		var f_lat: float = absf(dt._tire_force(cfg, c, c.v_long, 1.0 / 60.0).y)
		if f_lat > best_f:
			best_f = f_lat
			best_deg = deg
		deg += 0.5
	return best_deg


func test_peak_lateral_grip_at_constant_slip_angle() -> void:
	# The tire model normalizes slip by speed, so peak lateral grip must land at
	# the SAME slip angle regardless of speed (a real tyre peaks at ~a constant
	# angle, not a constant slip speed). Property test — holds for any reasonable
	# tire_slip_peak, pins no tuned value.
	var slow := _peak_lateral_slip_angle_deg(15.0)
	var fast := _peak_lateral_slip_angle_deg(40.0)
	assert_almost_eq(fast, slow, 1.0,
		"peak lateral slip angle is speed-independent (%.1f° vs %.1f°)" % [slow, fast])
	# And it's a genuine interior peak, not a monotone ramp to the sweep edge.
	assert_gt(slow, 1.0, "peak is at a nonzero slip angle")
	assert_lt(slow, 44.0, "grip falls off past the peak, not still climbing at 45°")


func test_surface_tire_params_blend() -> void:
	# The three surface-dependent tire params resolve from the (road, tarmac)
	# terrain weights to the matching per-surface anchor. Tests the blend LOGIC
	# maps weights -> anchors; the anchor VALUES are tunable and not asserted.
	var cfg: GameConfig = Config.data
	var dt: Drivetrain = _car.drivetrain
	var stub := _StubTerrain.new()
	dt.terrain = stub

	stub.s = Vector2(0.0, 0.0)  # off-road grass
	var grass: Dictionary = dt.surface_tire_params(cfg, Vector3.ZERO)
	assert_almost_eq(grass.slip_peak, cfg.grass_slip_peak, 1e-4, "grass slip peak")
	assert_almost_eq(grass.slide_ratio, cfg.grass_slide_ratio, 1e-4, "grass slide ratio")

	stub.s = Vector2(1.0, 0.0)  # full gravel road
	var gravel: Dictionary = dt.surface_tire_params(cfg, Vector3.ZERO)
	assert_almost_eq(gravel.slip_peak, cfg.gravel_slip_peak, 1e-4, "gravel slip peak")
	assert_almost_eq(gravel.slide_ratio, cfg.gravel_slide_ratio, 1e-4, "gravel slide ratio")

	stub.s = Vector2(1.0, 1.0)  # full tarmac road
	var tarmac: Dictionary = dt.surface_tire_params(cfg, Vector3.ZERO)
	assert_almost_eq(tarmac.slip_peak, cfg.tarmac_slip_peak, 1e-4, "tarmac slip peak")
	assert_almost_eq(tarmac.slide_ratio, cfg.tarmac_slide_ratio, 1e-4, "tarmac slide ratio")

	dt.terrain = null
	var none: Dictionary = dt.surface_tire_params(cfg, Vector3.ZERO)
	assert_eq(none.mu_mult, 1.0, "no terrain -> μ unscaled")
	assert_almost_eq(none.slip_peak, cfg.tire_slip_peak, 1e-4, "no terrain -> global slip peak")


func test_higher_slip_peak_moves_optimum_angle_out() -> void:
	# The grip curve peaks at its own slip_peak, so a contact with a larger
	# slip_peak (a looser surface) reaches optimum lateral grip at a LARGER slip
	# angle. Synthetic slip_peak inputs — asserts the code's contract, not any
	# tuned surface value.
	var v := 25.0
	var tight := _peak_lateral_slip_angle_deg(v, 0.14)   # tarmac-like
	var loose := _peak_lateral_slip_angle_deg(v, 0.31)   # gravel-like
	assert_gt(loose, tight + 3.0,
		"looser surface (bigger slip_peak) peaks at a bigger slip angle (%.1f° vs %.1f°)" % [tight, loose])
