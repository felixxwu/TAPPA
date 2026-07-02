extends "res://tests/headless/sim_test.gd"
# Car behavior tests. These run on the flat test-track fixture
# (tests/fixtures/test_track.tscn) rather than main.tscn so that terrain
# generation settings cannot change where/how the car lands — the assertions
# here are about the CAR, not the terrain. Car-meets-terrain coverage lives
# in test_car_terrain.gd.
#
# `_scene`, `_car`, `_wait_physics()` and the settle machinery come from
# sim_test.gd — before_each restores a cached settled car instead of re-dropping.

const ACTIONS := ["accelerate", "brake_reverse", "steer_left", "steer_right", "reset_car", "handbrake"]


func before_each() -> void:
	await setup_settled_car()
	# Pin manual + RWD so these car-dynamics tests don't depend on the shipped
	# default gearbox/drive mode. (No drive request acts on a resting car, so
	# setting these after the settle does not disturb the cached pose.)
	_car.drivetrain.engine.auto = false
	_car.drivetrain.drive_mode = Drivetrain.DriveMode.RWD


func after_each() -> void:
	for action in ACTIONS:
		Input.action_release(action)


func test_car_settles_on_ground() -> void:
	# Flat plane at y=0: the car must come to a genuine rest at suspension
	# height — no slope to excuse drift, so the velocity bound is tight.
	assert_between(_car.global_position.y, 0.1, 1.5,
		"car rides on the ground at suspension height, not sunk/launched")
	assert_lt(_car.linear_velocity.length(), 0.3, "car at rest after settling on flat ground")


func test_handbrake_holds_against_slope_force() -> void:
	# A stopped car holding the handbrake gets a static-friction hold so it doesn't
	# creep — but it stays a LIVE rigid body (not frozen), unlike the old freeze hack.
	# The flat fixture has no slope, so we stand in a slope's downhill gravity pull with
	# a steady sub-cap horizontal force and check the held car resists it. The magnitude
	# (2·m N ≈ an ~12° grade) sits well under the μ·m·g hold cap for any sane grip.
	assert_lt(_car.linear_velocity.length(), 0.5, "precondition: the car is at rest")
	Input.action_press("handbrake")
	await _wait_physics(2)
	assert_false(_car.freeze, "a handbraked car stays a live rigid body, not frozen")
	var pinned := _car.global_position
	var pull := -_car.global_transform.basis.z * (_car.mass * 2.0)
	for _i in range(60):
		_car.apply_central_force(pull)
		await _wait_physics(1)
	assert_lt((_car.global_position - pinned).length(), 0.25,
		"the held car resists a steady sub-cap slope force instead of creeping")
	Input.action_release("handbrake")
	await _wait_physics(2)
	assert_false(_car.freeze, "still live after releasing the handbrake")


func test_accelerate_moves_car_forward() -> void:
	var start_pos := _car.global_position
	var forward := -_car.global_transform.basis.z
	Input.action_press("accelerate")
	await _wait_physics(90)
	Input.action_release("accelerate")
	var displacement := _car.global_position - start_pos
	assert_gt(displacement.dot(forward), 2.0,
		"W must move the car along its -Z forward (regression: reversed controls)")


func test_reset_returns_to_start() -> void:
	# Reset returns to the spawn transform captured in car._ready(). On the
	# flat fixture the car does not slide during settling, so the spawn and
	# the settled position coincide and the check can wait for a full settle.
	var spawn: Vector3 = _car._start_transform.origin
	var start_pos := _car.global_position
	Input.action_press("accelerate")
	await _wait_physics(90)
	Input.action_release("accelerate")
	assert_gt((_car.global_position - start_pos).length(), 1.0, "car drove away first")
	Input.action_press("reset_car")
	await _wait_physics(5)
	Input.action_release("reset_car")
	await _wait_physics(120)  # re-drop from the spawn clearance and settle
	var settled := _car.global_position
	assert_lt(Vector2(settled.x - spawn.x, settled.z - spawn.z).length(), 0.3,
		"reset returns to spawn (horizontal)")
	assert_lt(_car.linear_velocity.length(), 0.5, "reset zeroes velocity")


func test_aero_drag_decelerates_at_speed() -> void:
	# Quadratic aero drag (F = -c * v * |v|) is what creates a terminal velocity.
	# Self-calibrating: coast 1s from 70 m/s with drag disabled to measure wheel
	# losses alone, then coast with drag on — drag must shed well beyond the
	# wheel-loss baseline (analytically ~10 m/s at default mass/coefficient).
	assert_eq(_car.linear_damp, 0.0, "car must not rely on generic linear damping")
	var cfg: GameConfig = Config.data
	var saved := cfg.drag_coefficient
	cfg.drag_coefficient = 0.0
	_car.linear_velocity = -_car.global_transform.basis.z * 70.0
	await _wait_physics(60)
	var baseline := _car.linear_velocity.dot(-_car.global_transform.basis.z)
	cfg.drag_coefficient = saved
	_car.linear_velocity = -_car.global_transform.basis.z * 70.0
	await _wait_physics(60)
	var speed := _car.linear_velocity.dot(-_car.global_transform.basis.z)
	assert_lt(speed, baseline - 5.0, "aero drag must shed far more than wheel losses alone")


func test_redline_gearing_caps_top_speed() -> void:
	# Top speed is redline in top gear. Above it the gearbox input over-revs,
	# the clutch opens (money-shift forgiveness) and no drive torque reaches
	# the wheels, so full throttle must still let drag slow the car.
	var cfg: GameConfig = Config.data
	var engine: EngineSim = _car.drivetrain.engine
	engine.gear = cfg.gear_ratios.size()
	var top_speed: float = engine.redline_omega() / engine.ratio() * cfg.wheel_radius
	var start_speed := top_speed * 1.2
	var forward := -_car.global_transform.basis.z
	_car.linear_velocity = forward * start_speed
	_car.drivetrain.rear_omega = start_speed / cfg.wheel_radius
	Input.action_press("accelerate")
	await _wait_physics(60)
	Input.action_release("accelerate")
	var speed := _car.linear_velocity.dot(forward)
	assert_lt(speed, start_speed - 1.0,
		"full throttle above redline-limited top speed must decelerate")


func test_roll_influence_scales_longitudinal_pitch() -> void:
	# The longitudinal (braking/throttle) force's vertical lever is scaled by
	# wheel_roll_influence, so at 0 it acts at CoM height (no pitch) and at 1 at
	# the contact patch (the chassis dives/squats). Brake from a fixed cruising
	# speed at both settings and compare the immediate pitch rate (angular
	# velocity about the car's lateral axis) — measured over a few frames so it
	# reads the direct torque response, not later chaotic grip dynamics.
	var pitch_at_com := await _brake_pitch_rate(0.0)
	var pitch_at_patch := await _brake_pitch_rate(1.0)
	assert_almost_eq(pitch_at_com, 0.0, 0.05,
		"at roll_influence 0 the braking force acts at CoM height -> negligible pitch")
	assert_gt(pitch_at_patch, pitch_at_com + 0.1,
		"raising roll_influence applies the braking force higher -> the chassis pitches (dives)")


# Peak pitch rate (|angular velocity| about the car's lateral axis) while braking
# from a steady 20 m/s cruise at the given wheel_roll_influence. Wheel spin is
# pre-synced to road speed so there is no launch/lockup transient to muddy it.
func _brake_pitch_rate(influence: float) -> float:
	var cfg: GameConfig = Config.data
	var saved := cfg.wheel_roll_influence
	cfg.wheel_roll_influence = influence
	var r: float = cfg.wheel_radius
	var forward := -_car.global_transform.basis.z
	_car.linear_velocity = forward * 20.0
	_car.angular_velocity = Vector3.ZERO
	_car.drivetrain.rear_omega = 20.0 / r
	for w in _car.drivetrain.front_omega:
		_car.drivetrain.front_omega[w] = 20.0 / r
	Input.action_press("brake_reverse")
	var peak := 0.0
	for i in 8:
		await _wait_physics(1)
		peak = maxf(peak, absf(_car.angular_velocity.dot(_car.global_transform.basis.x)))
	Input.action_release("brake_reverse")
	cfg.wheel_roll_influence = saved
	return peak


func test_front_wheels_caster_toward_travel_direction() -> void:
	# With no steering input, the front wheels should swing toward the
	# direction of travel: sliding forward-left, steering must go positive
	# (left); driving straight, it must stay near zero.
	var forward := -_car.global_transform.basis.z
	var left := -_car.global_transform.basis.x
	_car.linear_velocity = (forward + left).normalized() * 15.0
	await _wait_physics(15)
	assert_gt(_car.steering, 0.05, "fronts steer toward a forward-left slide")
	# The slide yawed the car, so "straight" must use the CURRENT heading —
	# the pre-slide forward vector is stale. Snapping from a hard-left caster
	# (steering ~+0.77) to a straight-ahead target sets off a single damped yaw
	# oscillation: steering overshoots to ~-0.11 around frame 30, crosses back
	# through zero near frame 70 and is fully settled (|steering| < 0.01) by
	# ~frame 85. We assert the STEADY state the caster converges to, so wait out
	# that transient instead of sampling on the overshoot peak.
	_car.angular_velocity = Vector3.ZERO
	_car.linear_velocity = -_car.global_transform.basis.z * 15.0
	await _wait_physics(90)
	assert_almost_eq(_car.steering, 0.0, 0.1, "fronts straight when travel matches heading")


func test_travel_alignment_zero_disables_castering() -> void:
	var cfg: GameConfig = Config.data
	var saved := cfg.steer_travel_alignment
	cfg.steer_travel_alignment = 0.0
	var forward := -_car.global_transform.basis.z
	var left := -_car.global_transform.basis.x
	_car.linear_velocity = (forward + left).normalized() * 15.0
	await _wait_physics(15)
	cfg.steer_travel_alignment = saved
	assert_almost_eq(_car.steering, 0.0, 0.02,
		"at alignment 0 a slide must not steer the fronts without input")


func test_travel_alignment_scales_down_at_low_speed() -> void:
	# The alignment is faded in linearly with speed up to steer_assist_min_speed
	# (≈30 km/h ≈ 8.333 m/s), so the same slide angle casters the fronts far less
	# when slow than when fast. Drive an identical 45° slide at 4 m/s (partial
	# scale) and at 15 m/s (scale clamped to 1.0); low-speed steering must be
	# clearly smaller.
	var slide := (-_car.global_transform.basis.z - _car.global_transform.basis.x).normalized()
	_car.linear_velocity = slide * 15.0
	await _wait_physics(15)
	var fast_steer := absf(_car.steering)

	# Reset to the spawn transform, then repeat the slide at low speed.
	Input.action_press("reset_car")
	await _wait_physics(5)
	Input.action_release("reset_car")
	await _wait_physics(120)
	slide = (-_car.global_transform.basis.z - _car.global_transform.basis.x).normalized()
	_car.linear_velocity = slide * 4.0
	await _wait_physics(15)
	var slow_steer := absf(_car.steering)

	assert_lt(slow_steer, fast_steer * 0.7,
		"low-speed alignment must be scaled down relative to high speed")


func test_steer_assist_suppressed_below_min_speed() -> void:
	# Below steer_assist_min_speed the assist is suppressed, so at a standstill
	# (where the front tires can generate no turn) a large assist torque must
	# leave the car's heading essentially unchanged.
	var cfg: GameConfig = Config.data
	var saved := cfg.steer_assist_torque
	cfg.steer_assist_torque = 5000.0
	_car.linear_velocity = Vector3.ZERO
	_car.angular_velocity = Vector3.ZERO
	var start_yaw := _car.rotation.y
	Input.action_press("steer_left")
	await _wait_physics(60)
	Input.action_release("steer_left")
	cfg.steer_assist_torque = saved
	var yaw_delta := absf(wrapf(_car.rotation.y - start_yaw, -PI, PI))
	assert_lt(yaw_delta, 0.02, "steer assist does not yaw a stationary car")


func test_steer_assist_tapers_with_slip_angle() -> void:
	# The assist fades linearly with how far the car has already rotated into the
	# turn: full at zero slip, nothing past steer_assist_max_angle. Steering left,
	# measure the yaw the assist adds (torque on minus off, over a short window)
	# when the car points along its travel vs. when it has slipped well past the
	# limit — the slipped contribution must taper to near nothing.
	var cfg: GameConfig = Config.data
	var saved_torque := cfg.steer_assist_torque
	var saved_angle := cfg.steer_assist_max_angle
	cfg.steer_assist_max_angle = deg_to_rad(15.0)

	var aligned := await _steer_assist_yaw_gain(0.0)
	var slipped := await _steer_assist_yaw_gain(deg_to_rad(45.0))

	cfg.steer_assist_torque = saved_torque
	cfg.steer_assist_max_angle = saved_angle

	assert_gt(aligned, 0.03,
		"aligned: the assist must add left yaw when the car points along its travel")
	assert_lt(absf(slipped), aligned * 0.3,
		"slipped past steer_assist_max_angle: the assist contribution must taper away")


# Left-steer yaw rate the assist adds (torque 8000 minus torque 0) over a short
# window, with the car driving at 20 m/s but already slipped the given angle INTO
# the turn (travel to the right of the nose). Differencing the two torque runs
# isolates the assist from the identical front-wheel/grip yaw in both.
func _steer_assist_yaw_gain(slip_into_turn: float) -> float:
	var off := await _left_steer_yaw_rate(slip_into_turn, 0.0)
	var on := await _left_steer_yaw_rate(slip_into_turn, 8000.0)
	return on - off


func _left_steer_yaw_rate(slip_into_turn: float, torque: float) -> float:
	var cfg: GameConfig = Config.data
	cfg.steer_assist_torque = torque
	# Reset to the spawn pose so both torque runs start from an identical state.
	Input.action_press("reset_car")
	await _wait_physics(5)
	Input.action_release("reset_car")
	await _wait_physics(120)
	var forward := -_car.global_transform.basis.z
	var right := _car.global_transform.basis.x
	_car.linear_velocity = (forward * cos(slip_into_turn) + right * sin(slip_into_turn)) * 20.0
	_car.angular_velocity = Vector3.ZERO
	Input.action_press("steer_left")
	await _wait_physics(12)
	Input.action_release("steer_left")
	return _car.angular_velocity.y


# --- Spin protection assist ---------------------------------------------------
# Past spin_assist_angle of slip, a corrective yaw torque pulls the nose back
# toward the direction of travel (opposing the spin). Inactive below the
# threshold and while the handbrake is held. Each check differences an
# assist-on run against an assist-off run from an identical slide, so the
# tire/caster yaw common to both cancels out and only the assist remains.

func test_spin_assist_yaws_nose_back_toward_travel() -> void:
	# Sliding with travel well to the LEFT of the nose (the car has rotated
	# right, past the threshold): the assist must add LEFT (positive) yaw,
	# rotating the nose back toward the travel direction.
	var gain := await _spin_assist_yaw_gain(deg_to_rad(60.0), false)
	assert_gt(gain, 0.02,
		"beyond the slip threshold the assist yaws the nose back toward travel")


func test_spin_assist_inactive_below_threshold() -> void:
	# Travelling straight (zero slip) the assist must add essentially nothing —
	# it's spin protection, not a straight-line stabiliser.
	var gain := await _spin_assist_yaw_gain(0.0, false)
	assert_lt(absf(gain), 0.02, "no assist torque while slip is below the threshold")


func test_spin_assist_suppressed_by_handbrake() -> void:
	# The same over-threshold slide with the handbrake held: deliberate drifts
	# must not be fought, so the assist contribution must stay near zero.
	var gain := await _spin_assist_yaw_gain(deg_to_rad(60.0), true)
	assert_lt(absf(gain), 0.02, "handbrake suppresses the spin-protection torque")


# Yaw rate the spin assist adds (torque on minus torque off) over a short window,
# from a 20 m/s slide with the travel direction `slip` radians to the LEFT of the
# nose. Steering input stays neutral so the steer assist contributes nothing.
func _spin_assist_yaw_gain(slip: float, handbrake: bool) -> float:
	var off := await _spin_slide_yaw_rate(slip, 0.0, handbrake)
	var on := await _spin_slide_yaw_rate(slip, 12000.0, handbrake)
	return on - off


func _spin_slide_yaw_rate(slip: float, torque: float, handbrake: bool) -> float:
	var cfg: GameConfig = Config.data
	var saved_torque := cfg.spin_assist_torque
	var saved_angle := cfg.spin_assist_angle
	cfg.spin_assist_torque = torque
	cfg.spin_assist_angle = deg_to_rad(20.0)
	# Reset to the spawn pose so every run starts from an identical state.
	Input.action_press("reset_car")
	await _wait_physics(5)
	Input.action_release("reset_car")
	await _wait_physics(120)
	var forward := -_car.global_transform.basis.z
	var left := -_car.global_transform.basis.x
	_car.linear_velocity = (forward * cos(slip) + left * sin(slip)) * 20.0
	_car.angular_velocity = Vector3.ZERO
	if handbrake:
		Input.action_press("handbrake")
	await _wait_physics(12)
	if handbrake:
		Input.action_release("handbrake")
	cfg.spin_assist_torque = saved_torque
	cfg.spin_assist_angle = saved_angle
	return _car.angular_velocity.y


func _axle_normal_sum(rear: bool) -> float:
	var total := 0.0
	for wheel in _car.find_children("*", "VehicleWheel3D", false):
		if wheel.use_as_traction == rear:
			total += _car.drivetrain.wheel_normal_force(wheel)
	return total


# Measures the per-axle normal-force sums while coasting at the given speed
# with the given downforce coefficients, restoring config afterwards.
func _normals_at_speed(front_coef: float, rear_coef: float) -> Array[float]:
	var cfg: GameConfig = Config.data
	var saved_front := cfg.downforce_front
	var saved_rear := cfg.downforce_rear
	cfg.downforce_front = front_coef
	cfg.downforce_rear = rear_coef
	_car.linear_velocity = -_car.global_transform.basis.z * 30.0
	await _wait_physics(20)  # suspension reaches the new equilibrium
	var result: Array[float] = [_axle_normal_sum(false), _axle_normal_sum(true)]
	cfg.downforce_front = saved_front
	cfg.downforce_rear = saved_rear
	return result


# Downforce coefficients are force terms (N per (m/s)²), so they live in the
# same real-unit scale as the rest of the sim — c ≈ 8.82 gives ~7900 N at 30 m/s.
const DOWNFORCE_C := 8.82

func test_rear_downforce_loads_rear_axle_at_speed() -> void:
	# F = c * v²: at 30 m/s the rear axle gains ~7900 N over the zero-downforce
	# baseline; the front axle must gain far less.
	var baseline: Array[float] = await _normals_at_speed(0.0, 0.0)
	var loaded: Array[float] = await _normals_at_speed(0.0, DOWNFORCE_C)
	assert_gt(loaded[1], baseline[1] + 2600.0, "rear downforce raises rear normal force at speed")
	assert_lt(loaded[0] - baseline[0], (loaded[1] - baseline[1]) * 0.5,
		"rear downforce must load the rear axle, not the front")


func test_front_downforce_loads_front_axle_at_speed() -> void:
	var baseline: Array[float] = await _normals_at_speed(0.0, 0.0)
	var loaded: Array[float] = await _normals_at_speed(DOWNFORCE_C, 0.0)
	assert_gt(loaded[0], baseline[0] + 2600.0, "front downforce raises front normal force at speed")
	assert_lt(loaded[1] - baseline[1], (loaded[0] - baseline[0]) * 0.5,
		"front downforce must load the front axle, not the rear")


func test_negative_rear_downforce_lifts_rear_axle_at_speed() -> void:
	# A negative coefficient is lift: at 30 m/s the rear axle must shed normal
	# force relative to the zero baseline, with the front largely unaffected.
	var baseline: Array[float] = await _normals_at_speed(0.0, 0.0)
	var lifted: Array[float] = await _normals_at_speed(0.0, -DOWNFORCE_C)
	assert_lt(lifted[1], baseline[1] - 2600.0, "rear lift lowers rear normal force at speed")
	assert_lt(absf(lifted[0] - baseline[0]), absf(lifted[1] - baseline[1]) * 0.5,
		"rear lift must unload the rear axle, not the front")


func test_negative_front_downforce_lifts_front_axle_at_speed() -> void:
	var baseline: Array[float] = await _normals_at_speed(0.0, 0.0)
	var lifted: Array[float] = await _normals_at_speed(-DOWNFORCE_C, 0.0)
	assert_lt(lifted[0], baseline[0] - 2600.0, "front lift lowers front normal force at speed")
	assert_lt(absf(lifted[1] - baseline[1]), absf(lifted[0] - baseline[0]) * 0.5,
		"front lift must unload the front axle, not the rear")


func test_downforce_inert_at_standstill() -> void:
	# v² scaling: at rest the coefficients must not change the suspension load.
	var baseline_rear := _axle_normal_sum(true)
	var cfg: GameConfig = Config.data
	cfg.downforce_front = 2.0
	cfg.downforce_rear = 2.0
	await _wait_physics(30)
	var loaded_rear := _axle_normal_sum(true)
	cfg.downforce_front = 0.0
	cfg.downforce_rear = 0.0
	assert_almost_eq(loaded_rear, baseline_rear, baseline_rear * 0.1,
		"downforce is speed-dependent: no effect at standstill")


func test_apply_car_sets_downforce_from_spec_overwriting_stale() -> void:
	# Downforce is a PER-CAR spec value: apply_car SETS (not adds) it, so a car with
	# 0 has none (no hidden global baseline) and re-fielding can't accumulate it.
	var cfg: GameConfig = Config.data
	cfg.downforce_front = 0.5  # pollute, as a prior fielding / aero_kit upgrade would
	cfg.downforce_rear = 0.5
	_car.apply_car(0)  # MX-5
	var spec: Dictionary = CarLibrary.CARS[0]
	assert_almost_eq(cfg.downforce_rear, float(spec.get("downforce_rear", 0.0)), 1e-6,
		"apply_car sets rear downforce from the spec, overwriting the stale value")
	assert_almost_eq(cfg.downforce_front, float(spec.get("downforce_front", 0.0)), 1e-6,
		"front downforce comes from the spec (0 when unspecified)")


func test_aero_kit_upgrade_adds_downforce() -> void:
	# Downforce IS applied to the live config via the aero_kit upgrade, layered
	# ON TOP of whatever the car's spec baseline is (apply_owned, step 2). Asserts
	# the upgrade's DELTA, not a hardcoded per-car value, so it can't go stale when
	# the CarLibrary tuning data changes.
	var cfg: GameConfig = Config.data
	_car.apply_car(0)  # MX-5 — establishes the spec baseline (step 1)
	var baseline_front := cfg.downforce_front
	var baseline_rear := cfg.downforce_rear
	var aero: Dictionary = UpgradeLibrary.by_id("aero_kit")["effect"]
	UpgradeLibrary.apply({"installed_upgrades": ["aero_kit"]}, cfg)
	assert_almost_eq(cfg.downforce_front, baseline_front + float(aero["downforce_front"]), 1e-6,
		"aero_kit adds its front downforce on top of the spec baseline")
	assert_almost_eq(cfg.downforce_rear, baseline_rear + float(aero["downforce_rear"]), 1e-6,
		"aero_kit adds its rear downforce on top of the spec baseline")
	assert_gt(cfg.downforce_rear, 0.0, "a car fitted with the aero kit carries positive rear downforce")


# --- Self-righting (level) assist -------------------------------------------
# When any wheel is airborne, the car gets a roll+pitch torque back toward
# level, scaled by how far it is tilted. It must not yaw, and must not act when
# all four wheels are planted.

# Suspend the car in the air, rotated `tilt` radians about `axis`, and report
# how far its up vector has rotated toward world up after `frames` of physics.
# Returns [start_alignment, end_alignment, yaw_drift].
func _level_assist_run(axis: Vector3, tilt: float, frames: int) -> Array:
	var xform := Transform3D(Basis(axis.normalized(), tilt), Vector3(0.0, 50.0, 0.0))
	_car.global_transform = xform
	_car.linear_velocity = Vector3.ZERO
	_car.angular_velocity = Vector3.ZERO
	await _wait_physics(1)
	var start_align := _car.global_transform.basis.y.dot(Vector3.UP)
	var start_fwd := -_car.global_transform.basis.z
	await _wait_physics(frames)
	var end_align := _car.global_transform.basis.y.dot(Vector3.UP)
	# Yaw drift: how much the forward heading rotated in the ground plane.
	var end_fwd := -_car.global_transform.basis.z
	var s := Vector2(start_fwd.x, start_fwd.z).normalized()
	var e := Vector2(end_fwd.x, end_fwd.z).normalized()
	return [start_align, end_align, absf(wrapf(e.angle() - s.angle(), -PI, PI))]


func test_level_assist_rights_a_rolled_car() -> void:
	# Rolled ~40° about its own forward axis, airborne: up must climb toward UP.
	var r: Array = await _level_assist_run(Vector3.FORWARD, deg_to_rad(40.0), 60)
	assert_gt(r[1], r[0] + 0.05, "level assist rolls an airborne car back toward flat")


func test_level_assist_rights_a_pitched_car() -> void:
	# Pitched ~40° about its lateral axis, airborne: up must climb toward UP.
	var r: Array = await _level_assist_run(Vector3.RIGHT, deg_to_rad(40.0), 60)
	assert_gt(r[1], r[0] + 0.05, "level assist pitches an airborne car back toward flat")


func test_level_assist_does_not_yaw() -> void:
	# A pure roll correction must not rotate the car's heading (no yaw).
	var r: Array = await _level_assist_run(Vector3.FORWARD, deg_to_rad(40.0), 60)
	assert_lt(r[2], deg_to_rad(5.0), "level assist must not yaw the car")


func test_level_assist_scales_with_tilt() -> void:
	# Torque grows with tilt: a larger lean must recover more up-alignment in the
	# same time than a small lean (compared as alignment GAINED, not absolute).
	var small: Array = await _level_assist_run(Vector3.FORWARD, deg_to_rad(15.0), 30)
	var large: Array = await _level_assist_run(Vector3.FORWARD, deg_to_rad(60.0), 30)
	assert_gt(large[1] - large[0], small[1] - small[0],
		"a further-from-flat car gets a stronger righting torque")


func test_level_assist_quiet_when_planted() -> void:
	# All four wheels on the flat fixture: the settled car must stay put — the
	# assist must not fire and nudge a level, grounded car around.
	await setup_settled_car()
	var before := _car.global_transform.basis.y.dot(Vector3.UP)
	await _wait_physics(30)
	var after := _car.global_transform.basis.y.dot(Vector3.UP)
	assert_almost_eq(after, before, 0.02, "no level assist while all wheels are grounded")
	assert_lt(_car.angular_velocity.length(), 0.3, "grounded car is not spun by the assist")


# --- Damage model integration (features/damage.md) -------------------------
# The DamageModel maths are unit-tested in test_damage_model.gd; these check the
# car wires it in — contact monitoring is enabled and the per-tick power/steer
# effects read the model's current HP.

func test_car_has_damage_model_and_contact_monitor() -> void:
	assert_not_null(_car.damage, "car builds a DamageModel")
	assert_true(_car.contact_monitor, "contact monitoring is on so impacts can be read")
	assert_gt(_car.max_contacts_reported, 0, "the car reports contacts for the damage model")


func test_engine_misfire_level_tracks_damage() -> void:
	# car.gd feeds damage.misfire_level() to the engine each tick; the engine turns
	# that into a stochastic fuel cut (tested in test_engine_logic.gd). The exact
	# ramp lives in test_damage_model.gd — here we just confirm the wiring: healthy
	# car -> 0, a badly damaged car -> some misfire.
	_car.damage.field(1000.0, 1000.0)
	await _wait_physics(2)
	assert_almost_eq(_car.drivetrain.engine.misfire_level, 0.0, 0.001, "full HP -> no misfire")
	_car.damage.hp = 0.0
	await _wait_physics(2)
	assert_gt(_car.drivetrain.engine.misfire_level, 0.0, "a wrecked engine misfires")


# Regression: a head-on collision must cost HP. Godot only reports a contact in
# _integrate_forces AFTER the solver has arrested the car, so reading the
# post-solve state.linear_velocity floored the impact speed to ~0 on exactly the
# hardest (head-on) hits and they dealt no damage. car.gd keys damage off the
# pre-solve _approach_speed cached in _physics_process instead. See features/damage.md.
func test_head_on_collision_costs_hp() -> void:
	_car.damage.field(1000.0, 1000.0)
	var impacts: Array = []
	_car.damage.damaged.connect(func(loss, _pt): impacts.append(loss))

	var fwd := -_car.global_transform.basis.z
	var obstacle_pos := _car.global_position + fwd * 12.0
	obstacle_pos.y = _car.global_position.y
	var body := StaticBody3D.new()
	body.add_to_group(DamageModel.OBSTACLE_GROUP)
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4, 4, 1)
	col.shape = box
	body.add_child(col)
	_scene.add_child(body)
	body.global_position = obstacle_pos

	# Launch the car straight at the obstacle (~30 m/s); re-assert velocity until
	# it's close so drag doesn't bleed off the approach speed before contact.
	for i in 120:
		if _car.global_position.distance_to(obstacle_pos) > 4.0:
			_car.linear_velocity = fwd * 30.0
		await get_tree().physics_frame

	assert_gt(impacts.size(), 0, "a head-on collision must register at least one impact")
	assert_lt(_car.damage.hp, 1000.0, "a head-on collision must cost HP")


# A car fielded with bent wheels must veer from the physics ALONE — the damage
# steer bias was removed, so if the toe weren't applied to the actual wheel nodes
# (and their steer axle re-captured on re-parent), the car would track straight.
func test_bent_front_wheels_veer_the_car_via_physics() -> void:
	var cfg: GameConfig = Config.data
	var t := cfg.damage_wheel_toe_max
	# Both front wheels toed the same way about the car-up axis = a physical steer.
	_car.apply_owned({"model_id": "mx5", "wheel_toe": [t, t, 0.0, 0.0]})
	await _wait_physics(4)
	# The toe rides on the per-wheel VehicleWheel3D.steering the drivetrain reads for
	# the force direction (front wheels carry the base steer plus their toe).
	var fl := _car.get_node("WheelFL") as VehicleWheel3D
	var rl := _car.get_node("WheelRL") as VehicleWheel3D
	assert_almost_eq(fl.steering, _car.steering + t, 0.02, "front wheel carries base steer + toe")
	assert_almost_eq(rl.steering, 0.0, 0.02, "an unbent rear wheel stays straight")
	var start_yaw := _car.global_transform.basis.get_euler().y
	Input.action_press("accelerate")
	await _wait_physics(150)
	Input.action_release("accelerate")
	var yaw_delta: float = angle_difference(start_yaw, _car.global_transform.basis.get_euler().y)
	assert_gt(absf(yaw_delta), 0.05, "bent front wheels veer the car with no synthetic steer bias")


func test_mx5_wheels_use_its_own_wheel_texture() -> void:
	_car.apply_car(CarLibrary.index_of("mx5"))
	var tire := _car.get_node("WheelFL/Visual/Tire") as MeshInstance3D
	var mat := tire.get_surface_override_material(0) as ShaderMaterial
	assert_not_null(mat, "tire has a ShaderMaterial override")
	var tex := mat.get_shader_parameter("albedo_texture") as Texture2D
	assert_not_null(tex, "mx5 wheel cap has a texture")
	assert_true(str(tex.resource_path).ends_with("mx5/wheel.png"),
		"mx5 uses its own wheel.png, got %s" % tex.resource_path)


func test_modelless_car_gets_blank_wheel_texture() -> void:
	# rs3 has no wheel_texture spec -> blank dark disc, NOT the mx5 photo.
	_car.apply_car(CarLibrary.index_of("rs3"))
	var tire := _car.get_node("WheelFL/Visual/Tire") as MeshInstance3D
	var mat := tire.get_surface_override_material(0) as ShaderMaterial
	var tex := mat.get_shader_parameter("albedo_texture") as Texture2D
	assert_false(str(tex.resource_path).ends_with("wheel.png"),
		"a model-less car must not borrow a car's wheel photo")


func test_mx5_model_node_shown_via_spec_fields() -> void:
	_car.apply_car(CarLibrary.index_of("mx5"))
	assert_true((_car.get_node("Mx5Body") as Node3D).visible, "Mx5Body shown for the mx5")
	assert_false((_car.get_node("Chassis") as MeshInstance3D).visible, "boxes hidden for a model car")
	var mi := _car.get_node("Mx5Body").find_children("*", "MeshInstance3D", true)[0] as MeshInstance3D
	var mat := mi.get_surface_override_material(0) as ShaderMaterial
	var tex := mat.get_shader_parameter("albedo_texture") as Texture2D
	assert_true(str(tex.resource_path).ends_with("mx5_texture.png"), "mx5 body uses its own texture")


func test_apply_car_sets_custom_center_of_mass_from_weight_front() -> void:
	# LOGIC test (not a pinned value): whatever a car's authored weight_front is,
	# apply_car must switch to a CUSTOM CoM and place it along the wheelbase per the
	# static-balance mapping z = wheelbase x (rear_frac - 0.5), +Z = rearward.
	for i in CarLibrary.CARS.size():
		var spec: Dictionary = CarLibrary.CARS[i]
		_car.apply_car(i)
		assert_eq(_car.center_of_mass_mode, RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM,
			"%s uses a custom centre of mass" % spec["name"])
		var front_frac: float = spec.get("weight_front", 0.5)
		var expected_z: float = spec["wheelbase"] * (1.0 - front_frac - 0.5)
		assert_almost_eq(_car.center_of_mass.z, expected_z, 0.0001,
			"%s CoM z follows wheelbase x (rear_frac - 0.5)" % spec["name"])
		assert_almost_eq(_car.center_of_mass.x, 0.0, 0.0001, "%s CoM stays centred laterally" % spec["name"])


func test_nose_heavy_car_sits_com_forward_of_tail_heavy() -> void:
	# Sign/direction check: a nose-heavy car's CoM is forward (-Z) of a tail-heavy
	# one's. Compares the sign of the mapping, not the specific figures.
	_car.apply_car(CarLibrary.index_of("focus"))  # nose-heavy FWD
	var nose_z := _car.center_of_mass.z
	_car.apply_car(CarLibrary.index_of("aventador"))  # tail-heavy mid-engine
	var tail_z := _car.center_of_mass.z
	assert_lt(nose_z, tail_z, "nose-heavy CoM sits forward (-Z) of a tail-heavy car's")


func test_nose_heavy_car_settles_level_not_drooping() -> void:
	# The front/rear spring-rate split (GameConfig.axle_stiffness) scales each axle's
	# rate with the load it carries, so static compression is equal front and rear and
	# a nose-heavy car sits LEVEL at rest instead of drooping onto its front. Settle a
	# strongly nose-biased car from the spawn clearance and check the chassis pitch is
	# ~flat (forward.y ~ 0), not pitched nose-down.
	_car.apply_car(CarLibrary.index_of("focus"))  # nose-heavy FWD
	await _wait_physics(150)
	assert_lt(_car.linear_velocity.length(), 0.6, "car has settled at rest")
	var forward := -_car.global_transform.basis.z
	assert_lt(absf(forward.y), 0.06,
		"nose-heavy car settles roughly level, not nose-down (pitch sin = %.3f)" % forward.y)


func test_axle_rate_splits_toward_the_heavier_axle() -> void:
	# LOGIC (not pinned values): axle_stiffness splits the overall rate by weight, so
	# for a nose-heavy car the front spring is stiffer than the rear, and the mean of
	# the two axle rates stays at the overall suspension_stiffness.
	var cfg: GameConfig = Config.data
	cfg.suspension_stiffness = 12.0
	cfg.weight_front = 0.62
	assert_gt(cfg.axle_stiffness(true), cfg.axle_stiffness(false),
		"nose-heavy: front spring stiffer than rear")
	assert_almost_eq((cfg.axle_stiffness(true) + cfg.axle_stiffness(false)) * 0.5, 12.0, 0.0001,
		"mean axle rate stays at the overall suspension_stiffness")
	cfg.weight_front = 0.5
	assert_almost_eq(cfg.axle_stiffness(true), cfg.axle_stiffness(false), 0.0001,
		"50/50: front and rear share the base rate")
