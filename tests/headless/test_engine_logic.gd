extends GutTest
# Pure flywheel/gearbox/clutch LOGIC — no physics scene, no car, no settle.
# These exercise EngineSim directly (it is a RefCounted that reads the Config
# singleton), so they cost only CPU instead of ~150 wall-clock physics frames
# per setup. Behaviour that genuinely needs the car/driveline (idle, redline
# under load, shifting through the real clutch, reverse, etc.) stays in
# test_engine.gd on the physics fixture.

var _engine: EngineSim


func before_each() -> void:
	# Same authored baseline the scene tests assume; EngineSim reads the config it
	# is handed in _init, so reset first and pass the live global config.
	Config.reset()
	_engine = EngineSim.new(Config.data)


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


# --- Damage misfire ----------------------------------------------------------

func test_misfire_rate_zero_when_healthy() -> void:
	# No damage -> never cuts, regardless of load or tuning.
	assert_eq(EngineSim.misfire_rate(0.0, 1.0, 9.0, 0.5), 0.0, "a healthy engine never misfires")


func test_misfire_rate_positive_and_rises_with_load() -> void:
	# Constants supplied by the test (not the authored config) so this pins logic,
	# not tuned values. bias 0.5 -> some cutting off-load, more under load.
	var idle := EngineSim.misfire_rate(1.0, 0.0, 10.0, 0.5)
	var loaded := EngineSim.misfire_rate(1.0, 1.0, 10.0, 0.5)
	assert_gt(idle, 0.0, "a damaged engine still stumbles off-load (bias > 0)")
	assert_gt(loaded, idle, "the misfire fires more often under load")


# Count misfires in isolation via _update_misfire (fuel_cut also folds in the rev
# limiter, which would fire whenever the revs sit at redline — nothing to do with
# damage). Under load (throttle set, mid revs) but well below redline.
func _count_misfires(steps: int) -> int:
	var cfg: GameConfig = Config.data
	_engine.throttle = 1.0
	_engine.omega = _engine.redline_omega() * 0.5  # mid revs -> load, no limiter
	var cuts := 0
	for i in range(steps):
		if _engine._update_misfire(cfg, 0.001):
			cuts += 1
	return cuts


func test_healthy_engine_never_cuts_over_many_steps() -> void:
	_engine.misfire_level = 0.0
	_engine._rng.seed = 1
	assert_eq(_count_misfires(3000), 0, "misfire_level 0 -> the engine never cuts fuel")


func test_misfire_count_advances_only_on_cuts() -> void:
	# misfire_count increments once per cut ONSET (EngineSmoke reads its delta to puff).
	_engine.misfire_level = 0.0
	_engine._rng.seed = 1
	_count_misfires(2000)
	assert_eq(_engine.misfire_count, 0, "a healthy engine never advances the misfire count")
	_engine.misfire_level = 1.0
	var cutting_substeps := _count_misfires(2000)
	assert_gt(_engine.misfire_count, 0, "a damaged engine advances the count")
	# Each onset is one of the cutting substeps (a cut spans several substeps), so the
	# onset count can't exceed the number of substeps spent cutting.
	assert_lte(_engine.misfire_count, cutting_substeps, "the count tracks cut onsets, not every substep")


func test_damaged_engine_cuts_fuel_intermittently() -> void:
	_engine.misfire_level = 1.0  # wrecked: worst-case misfire rate
	_engine._rng.seed = 1
	var cuts := _count_misfires(3000)
	assert_gt(cuts, 0, "a heavily damaged engine cuts fuel during the run")
	assert_lt(cuts, 3000, "but it is intermittent, not a permanent cut")


func test_misfire_kills_crank_torque() -> void:
	# During a cut, combustion stops: full throttle in neutral must NOT spin the
	# flywheel up the way it does when firing — only engine friction acts.
	_engine.gear = 0
	_engine.misfire_level = 1.0
	# Firing control: throttle raises the revs.
	_engine.omega = _engine.idle_omega() + 50.0
	_engine._misfire_timer = 0.0
	_engine.misfire_level = 0.0
	var before_fire := _engine.omega
	_engine.step(0.01, 1.0, 0.0)
	assert_gt(_engine.omega, before_fire, "firing on full throttle spins the flywheel up")
	# Now force a misfire: the same input must not add crank torque.
	_engine.misfire_level = 1.0
	_engine._misfire_timer = 1.0  # a cut is in progress
	var before_cut := _engine.omega
	_engine.step(0.01, 1.0, 0.0)
	assert_true(_engine.fuel_cut, "the forced misfire reports a fuel cut (for the audio)")
	assert_lt(_engine.omega, before_cut, "with fuel cut, full throttle no longer drives the flywheel")


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


func test_handbrake_declutches_so_the_engine_revs() -> void:
	# Holding the handbrake locks the driven axle near zero, but the clutch must
	# open so the engine still revs against the throttle (no wheel torque) instead
	# of being dragged down to the stationary driveline.
	_engine.gear = 1
	_engine.omega = _engine.idle_omega()
	var h := 0.001
	# Without declutch, the engaged clutch couples the engine to the near-stopped
	# driveline and the revs go nowhere.
	for i in range(500):
		_engine.step(h, 1.0, 0.0)
	var engaged_rpm := _engine.rpm()

	_engine.omega = _engine.idle_omega()
	var wheel_torque := 0.0
	for i in range(500):
		wheel_torque = _engine.step(h, 1.0, 0.0, true)  # handbrake declutch
	var declutched_rpm := _engine.rpm()

	assert_gt(declutched_rpm, engaged_rpm + 1000.0,
		"declutched, full throttle climbs the revs free of the locked driveline")
	assert_almost_eq(wheel_torque, 0.0, 0.0001,
		"an open clutch delivers no torque to the wheels")
