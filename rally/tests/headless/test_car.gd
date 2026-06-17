extends "res://tests/headless/sim_test.gd"
# Car behavior tests. These run on the flat test-track fixture
# (tests/fixtures/test_track.tscn) rather than main.tscn so that terrain
# generation settings cannot change where/how the car lands — the assertions
# here are about the CAR, not the terrain. Car-meets-terrain coverage lives
# in test_car_terrain.gd.
#
# `_scene`, `_car`, `_wait_physics()` and the settle machinery come from
# sim_test.gd — before_each restores a cached settled car instead of re-dropping.

const ACTIONS := ["accelerate", "brake_reverse", "steer_left", "steer_right", "reset_car"]


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


func test_accelerate_moves_car_forward() -> void:
	var start_pos := _car.global_position
	var forward := -_car.global_transform.basis.z
	Input.action_press("accelerate")
	await _wait_physics(90)
	Input.action_release("accelerate")
	var displacement := _car.global_position - start_pos
	assert_gt(displacement.dot(forward), 2.0,
		"W must move the car along its -Z forward (regression: reversed controls)")


func test_steer_left_turns_left() -> void:
	var start_yaw := _car.rotation.y
	Input.action_press("accelerate")
	Input.action_press("steer_left")
	await _wait_physics(90)
	Input.action_release("accelerate")
	Input.action_release("steer_left")
	var yaw_delta := wrapf(_car.rotation.y - start_yaw, -PI, PI)
	assert_gt(yaw_delta, 0.1, "steering left while driving forward increases yaw")


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


func test_steer_assist_torque_yaws_car() -> void:
	# Above the min-speed threshold the assist applies yaw torque directly, so
	# steering left rotates the car. Drive it forward fast enough to clear
	# steer_assist_min_speed, then isolate the assist's contribution by comparing
	# the yaw with the torque enabled vs disabled at the same speed.
	var cfg: GameConfig = Config.data
	var saved := cfg.steer_assist_torque
	var forward := -_car.global_transform.basis.z
	var v := (cfg.steer_assist_min_speed + 5.0) * forward

	cfg.steer_assist_torque = 0.0
	_car.global_transform.origin = Vector3.ZERO
	_car.linear_velocity = v
	_car.angular_velocity = Vector3.ZERO
	var base_yaw := _car.rotation.y
	Input.action_press("steer_left")
	await _wait_physics(30)
	Input.action_release("steer_left")
	var yaw_no_assist := wrapf(_car.rotation.y - base_yaw, -PI, PI)

	cfg.steer_assist_torque = 1000.0
	_car.global_transform.origin = Vector3.ZERO
	_car.linear_velocity = v
	_car.angular_velocity = Vector3.ZERO
	var start_yaw := _car.rotation.y
	Input.action_press("steer_left")
	await _wait_physics(30)
	Input.action_release("steer_left")
	var yaw_with_assist := wrapf(_car.rotation.y - start_yaw, -PI, PI)
	cfg.steer_assist_torque = saved

	assert_gt(yaw_with_assist, yaw_no_assist + 0.05,
		"steer assist torque adds left yaw above the min-speed threshold")


func test_steer_assist_torque_ramps_with_speed() -> void:
	# The assist torque is faded in linearly from 0 at standstill to full at
	# steer_assist_min_speed. Isolate the torque's contribution the same way as
	# above (yaw with it on minus off, at a fixed speed), and compare that
	# contribution at half the ramp speed (scale ≈ 0.5) against full ramp speed
	# (scale clamped to 1.0). The low-speed contribution must be clearly smaller.
	var cfg: GameConfig = Config.data
	var saved := cfg.steer_assist_torque
	var slow_contrib := await _assist_yaw_contribution(cfg.steer_assist_min_speed * 0.5)
	var fast_contrib := await _assist_yaw_contribution(cfg.steer_assist_min_speed + 5.0)
	cfg.steer_assist_torque = saved

	assert_gt(fast_contrib, 0.05, "assist still contributes yaw at full ramp speed")
	assert_lt(slow_contrib, fast_contrib * 0.7,
		"assist torque is ramped down at lower speed, contributing less yaw")


# Yaw added by steer_assist_torque alone at a fixed forward speed: yaw while
# steering left with the assist on minus the same run with it off, so wheel grip
# and travel alignment (which also yaw the car) cancel out.
func _assist_yaw_contribution(test_speed: float) -> float:
	var cfg: GameConfig = Config.data
	var forward := -_car.global_transform.basis.z
	var v := forward * test_speed

	cfg.steer_assist_torque = 0.0
	_car.global_transform.origin = Vector3.ZERO
	_car.linear_velocity = v
	_car.angular_velocity = Vector3.ZERO
	var off_base := _car.rotation.y
	Input.action_press("steer_left")
	await _wait_physics(30)
	Input.action_release("steer_left")
	var yaw_off := wrapf(_car.rotation.y - off_base, -PI, PI)

	cfg.steer_assist_torque = 1000.0
	_car.global_transform.origin = Vector3.ZERO
	_car.linear_velocity = v
	_car.angular_velocity = Vector3.ZERO
	var on_base := _car.rotation.y
	Input.action_press("steer_left")
	await _wait_physics(30)
	Input.action_release("steer_left")
	var yaw_on := wrapf(_car.rotation.y - on_base, -PI, PI)
	return yaw_on - yaw_off


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


func test_throttle_drives_during_powerslide() -> void:
	# Drive must survive a slide: the lateral demand is clamped to the friction
	# max BEFORE it competes with engine force, so throttle keeps accelerating
	# the car along its heading mid-drift (with the stock solver path the
	# unclamped lateral demand ate the whole grip budget and drive went to ~0).
	var forward := -_car.global_transform.basis.z
	var left := -_car.global_transform.basis.x
	_car.linear_velocity = forward * 5.0 + left * 10.0
	Input.action_press("accelerate")
	await _wait_physics(60)
	Input.action_release("accelerate")
	var fwd_speed := _car.linear_velocity.dot(-_car.global_transform.basis.z)
	# Threshold rebaselined from 6.5 -> 6.2 when the gross-curve + RPM-dependent
	# engine-friction model trimmed WOT torque ~13%; the car still clearly gains
	# speed from the 5.0 m/s start (failure mode is drive eaten to ~0 -> ~5.0).
	assert_gt(fwd_speed, 6.2, "throttle still accelerates along heading mid-slide")


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
