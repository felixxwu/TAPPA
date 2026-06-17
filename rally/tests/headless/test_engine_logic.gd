extends GutTest
# Pure flywheel/gearbox/clutch LOGIC — no physics scene, no car, no settle.
# These exercise EngineSim directly (it is a RefCounted that reads the Config
# singleton), so they cost only CPU instead of ~150 wall-clock physics frames
# per setup. Behaviour that genuinely needs the car/driveline (idle, redline
# under load, shifting through the real clutch, reverse, etc.) stays in
# test_engine.gd on the physics fixture.

var _engine: EngineSim


func before_each() -> void:
	# Same authored baseline the scene tests assume; EngineSim reads Config in
	# _init, so reset first.
	Config.reset()
	_engine = EngineSim.new()


func test_rev_limiter_bounces_within_a_band() -> void:
	# A real limiter cuts fuel at redline and restores it once the revs fall
	# back, so the engine bounces off the limit instead of pinning to it. In
	# neutral the flywheel is free of the driveline, isolating the bounce.
	var cfg: GameConfig = Config.data
	_engine.gear = 0
	_engine.omega = _engine.redline_omega() - 5.0
	var lo := INF
	var hi := -INF
	for i in range(3000):
		_engine.step(0.001, 1.0, 0.0)
		if i > 200:  # let it settle into the steady bounce
			lo = minf(lo, _engine.rpm())
			hi = maxf(hi, _engine.rpm())
	assert_lt(hi, cfg.redline_rpm * 1.03, "limiter never lets the revs blow past redline")
	assert_lt(lo, cfg.redline_rpm - 30.0, "revs bounce down off the limiter, not pinned to it")
	assert_gt(lo, cfg.redline_rpm - cfg.rev_limiter_band - 60.0, "the bounce stays within the limiter band")


func test_shift_up_speeds_are_increasing_and_reachable() -> void:
	# Precomputed per-gear upshift speeds: one entry per forward gear, strictly
	# increasing, and BELOW each gear's redline speed so the car can actually
	# reach the shift point (acceleration dies at the rev limiter).
	var cfg: GameConfig = Config.data
	var n: int = cfg.gear_ratios.size()
	assert_eq(_engine.shift_up_speeds.size(), n,
		"one upshift speed per gear (top gear's is unused/infinite)")
	for g in range(1, n):
		var v: float = _engine.shift_up_speeds[g - 1]
		assert_gt(v, 0.0, "gear %d upshift speed is positive" % g)
		if g >= 2:
			assert_gt(v, _engine.shift_up_speeds[g - 2], "upshift speeds increase with gear")
		var gr: float = cfg.gear_ratios[g - 1] * cfg.final_drive
		var redline_v := _engine.redline_omega() / gr * cfg.wheel_radius
		assert_lt(v, redline_v,
			"gear %d upshifts before its rev limiter, so the speed is reachable" % g)


func test_wheelspin_revs_do_not_upshift() -> void:
	# The bug: revving the engine to redline at a standstill (wheelspin) must NOT
	# climb the gears, because the car has no airspeed.
	_engine.auto = true
	_engine.gear = 1
	_engine.omega = _engine.redline_omega()
	_engine.update_auto(1.0, 0.0)
	assert_eq(_engine.gear, 1, "no airspeed keeps the box in 1st despite redline revs")


func test_airspeed_past_shift_point_upshifts() -> void:
	_engine.auto = true
	_engine.gear = 1
	_engine.update_auto(1.0, _engine.shift_up_speeds[0] + 1.0)
	assert_eq(_engine.gear, 2, "airspeed past the shift point upshifts to 2nd")


func test_engine_braking_grows_with_rpm() -> void:
	# Engine friction is affine in RPM (FMEP-style), so off-throttle braking must
	# drag the flywheel down FASTER at high revs than low. In neutral the clutch
	# is open, isolating the friction term. Both sample points sit well above idle
	# so the no-stall clamp never masks the decel.
	var cfg: GameConfig = Config.data
	assert_gt(cfg.engine_friction_slope, 0.0, "friction slope is positive, else it isn't RPM-dependent")
	var h := 0.001

	_engine.gear = 0
	_engine.omega = _engine.redline_omega() * 0.4
	var lo_before := _engine.omega
	_engine.step(h, 0.0, 0.0)
	var drop_lo := lo_before - _engine.omega

	_engine.omega = _engine.redline_omega() * 0.9
	var hi_before := _engine.omega
	_engine.step(h, 0.0, 0.0)
	var drop_hi := hi_before - _engine.omega

	assert_gt(drop_lo, 0.0, "off-throttle friction drags the revs down")
	assert_gt(drop_hi, drop_lo, "engine braking is stronger at high RPM than low")


func test_step_records_throttle() -> void:
	_engine.gear = 1
	_engine.step(0.016, 0.7, 0.0)
	assert_almost_eq(_engine.throttle, 0.7, 0.0001, "step() records its throttle arg")
