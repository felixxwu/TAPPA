extends "res://tests/headless/sim_test.gd"
# Engine + gearbox + clutch behavior that needs the real car/driveline on the
# flat test-track fixture. Pure flywheel/gearbox LOGIC that does not need a
# physics scene (limiter bounce, shift-speed table, auto-shift decisions, step
# bookkeeping) lives in test_engine_logic.gd, which builds a bare EngineSim and
# pays no settle cost at all.
#
# `_scene`, `_car`, `_wait_physics()` and the settle machinery come from
# sim_test.gd — before_each restores a cached settled car instead of re-dropping.

var _engine: EngineSim


func before_each() -> void:
	await setup_settled_car()
	_engine = _car.drivetrain.engine
	# Most engine tests exercise the manual box; the auto-mode tests opt back in.
	# (The shipped config boots in auto, so pin it here for a controlled baseline.)
	_engine.auto = false


func after_each() -> void:
	for action in ["accelerate", "brake_reverse", "shift_up", "shift_down"]:
		Input.action_release(action)


func test_idles_at_rest() -> void:
	var cfg: GameConfig = Config.data
	assert_almost_eq(_engine.rpm(), cfg.idle_rpm, 100.0, "engine idles at rest")
	assert_lt(_car.linear_velocity.length(), 0.3, "idling engine does not creep the car")


func test_revs_to_redline_in_first_and_limiter_holds() -> void:
	var cfg: GameConfig = Config.data
	assert_eq(_engine.gear, 1, "starts in 1st")
	Input.action_press("accelerate")
	await _wait_physics(240)
	Input.action_release("accelerate")
	assert_gt(_engine.rpm(), cfg.redline_rpm * 0.85, "full throttle in 1st reaches redline")
	assert_lt(_engine.rpm(), cfg.redline_rpm * 1.05, "rev limiter holds at redline")


func test_never_drops_below_idle() -> void:
	var cfg: GameConfig = Config.data
	Input.action_press("accelerate")
	for i in 60:
		await get_tree().physics_frame
		assert_gte(_engine.rpm(), cfg.idle_rpm * 0.95, "no stalling during launch")
	Input.action_release("accelerate")


func test_shift_up_changes_gear_and_drops_rpm() -> void:
	Input.action_press("accelerate")
	await _wait_physics(180)  # rev out 1st
	var rpm_before := _engine.rpm()
	Input.action_press("shift_up")
	await _wait_physics(2)
	Input.action_release("shift_up")
	Input.action_release("accelerate")  # lift, or wheelspin revs 2nd right back out
	await _wait_physics(45)  # shift completes, clutch re-engages
	assert_eq(_engine.gear, 2, "shift_up selects 2nd")
	assert_lt(_engine.rpm(), rpm_before - 500.0,
		"after the shift the longer gear holds the revs down at this road speed")


func test_shift_down_returns_to_first() -> void:
	_engine.gear = 2
	Input.action_press("shift_down")
	await _wait_physics(2)
	Input.action_release("shift_down")
	assert_eq(_engine.gear, 1, "shift_down selects 1st")


func test_high_gear_launch_bogs_without_wheelspin() -> void:
	# In 5th from a standstill the wheel torque sits below the grip limit and
	# the clutch can only transmit what the crank sustains at idle — the car
	# must bog (engine near idle, no wheelspin), not light up the tires.
	var cfg: GameConfig = Config.data
	_engine.gear = cfg.gear_ratios.size()
	Input.action_press("accelerate")
	await _wait_physics(60)
	Input.action_release("accelerate")
	var surface: float = _car.drivetrain.rear_omega * cfg.wheel_radius
	var speed := _car.linear_velocity.length()
	assert_lt(surface - speed, 1.5, "no wheelspin launching in top gear")
	assert_lt(_engine.rpm(), cfg.idle_rpm * 2.0, "engine bogs near idle in top gear")


func test_reverse_engages_at_standstill_and_drives_backwards() -> void:
	# Automatic reverse selection is an auto-gearbox feature.
	_engine.auto = true
	var start := _car.global_position
	var forward := -_car.global_transform.basis.z
	Input.action_press("brake_reverse")
	await _wait_physics(120)
	Input.action_release("brake_reverse")
	assert_eq(_engine.gear, -1, "S at standstill selects reverse")
	assert_lt((_car.global_position - start).dot(forward), -0.5, "car drives backwards")


func test_accelerating_from_reverse_returns_to_first() -> void:
	_engine.auto = true
	_engine.gear = -1
	Input.action_press("accelerate")
	await _wait_physics(30)
	Input.action_release("accelerate")
	assert_eq(_engine.gear, 1, "W at a near-stop leaves reverse for 1st")


func test_manual_sequential_reaches_neutral_then_reverse() -> void:
	# Manual box is sequential R - N - 1 - 2 ... Shifting down from 1st must
	# pass through neutral before reverse.
	assert_false(_engine.auto, "manual by default")
	assert_eq(_engine.gear, 1, "starts in 1st")
	Input.action_press("shift_down")
	await _wait_physics(2)
	Input.action_release("shift_down")
	assert_eq(_engine.gear, 0, "1st down selects neutral")
	await _wait_physics(20)  # let the shift cooldown clear
	Input.action_press("shift_down")
	await _wait_physics(2)
	Input.action_release("shift_down")
	assert_eq(_engine.gear, -1, "neutral down selects reverse")


func test_neutral_revs_engine_without_driving() -> void:
	# In neutral the clutch is open: W spins the engine up but sends no torque
	# to the wheels, so the car must not accelerate.
	_engine.gear = 0
	var start_speed := _car.linear_velocity.length()
	Input.action_press("accelerate")
	await _wait_physics(60)
	Input.action_release("accelerate")
	assert_gt(_engine.rpm(), Config.data.idle_rpm * 2.0, "throttle revs the engine in neutral")
	assert_lt(_car.linear_velocity.length(), start_speed + 0.5, "neutral sends no drive to the wheels")


func test_auto_upshifts_through_the_gears() -> void:
	# End-to-end through car.gd: above the 1st->2nd shift speed, sustained
	# throttle must make the auto box upshift. (Seed the airspeed directly so the
	# assertion doesn't depend on the standstill acceleration time.)
	_engine.auto = true
	_engine.gear = 1
	var fwd := -_car.global_transform.basis.z
	var v: float = _engine.shift_up_speeds[0] + 2.0
	_car.linear_velocity = fwd * v
	_car.drivetrain.rear_omega = v / Config.data.wheel_radius
	Input.action_press("accelerate")
	await _wait_physics(30)
	Input.action_release("accelerate")
	assert_gt(_engine.gear, 1, "automatic upshifts past 1st once airspeed clears the shift point")


func test_auto_climbs_from_a_standstill_under_power() -> void:
	# The real gameplay case: full throttle from a dead stop. Even fighting
	# wheelspin in 1st, the car must reach the 1st->2nd shift speed and climb
	# out of 1st within a few seconds (regression: shift point pinned at the rev
	# limiter left the car stuck in 1st forever).
	_engine.auto = true
	_engine.gear = 1
	Input.action_press("accelerate")
	await _wait_physics(420)
	Input.action_release("accelerate")
	assert_gt(_engine.gear, 1, "auto box climbs out of 1st from a standstill launch")
