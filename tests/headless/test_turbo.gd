extends GutTest
# Pure turbo maths + (Task 2) shaft integration on a bare EngineSim. No physics
# scene: builds its OWN synthetic GameConfig, so it pins turbo LOGIC, never the
# authored catalogue or tuned values.


func test_boost_fraction_zero_at_rest_and_rises_with_speed() -> void:
	assert_eq(EngineSim.boost_fraction(0.0, 12000.0), 0.0, "no shaft speed -> no boost")
	var half := EngineSim.boost_fraction(6000.0, 12000.0)
	var full := EngineSim.boost_fraction(12000.0, 12000.0)
	assert_gt(full, half, "boost rises with shaft speed")
	assert_almost_eq(full, 1.0, 0.0001, "boost saturates at 1.0 at omega_ref")
	assert_lte(EngineSim.boost_fraction(24000.0, 12000.0), 1.0, "boost clamps at 1.0")


func test_exhaust_drive_scales_with_flow_and_antilag_floor() -> void:
	# Drive rises with rpm*throttle (mass flow); zero at zero throttle without anti-lag.
	assert_eq(EngineSim.turbo_exhaust_drive(6000.0, 0.0, 0.02, false, 0.0), 0.0,
		"no throttle, no anti-lag -> no exhaust drive")
	var low := EngineSim.turbo_exhaust_drive(3000.0, 1.0, 0.02, false, 0.0)
	var high := EngineSim.turbo_exhaust_drive(6000.0, 1.0, 0.02, false, 0.0)
	assert_gt(high, low, "more flow (higher rpm) drives the shaft harder")
	# Anti-lag injects a positive drive floor off-throttle.
	var al := EngineSim.turbo_exhaust_drive(3000.0, 0.0, 0.02, true, 5.0)
	assert_almost_eq(al, 5.0, 0.0001, "anti-lag holds a drive floor off-throttle")


func test_boost_torque_factor_shape() -> void:
	var gain := 0.8
	# Endpoints are fixed for ANY response: no boost -> 1 (NA), full boost -> 1 + gain.
	for r in [0.5, 1.0, 2.0, 3.0]:
		assert_almost_eq(EngineSim.boost_torque_factor(0.0, gain, r), 1.0, 0.0001,
			"no boost -> NA torque regardless of response")
		assert_almost_eq(EngineSim.boost_torque_factor(1.0, gain, r), 1.0 + gain, 0.0001,
			"full boost -> full gain regardless of response")
	# response 1.0 reproduces the old linear gain (1 + boost*gain).
	assert_almost_eq(EngineSim.boost_torque_factor(0.5, gain, 1.0), 1.0 + 0.5 * gain, 0.0001,
		"response 1.0 is the linear baseline")
	# response > 1 delivers LESS than linear at part spool (lag felt more), and stays
	# monotonic in boost.
	var linear_mid := 1.0 + 0.5 * gain
	var lagged_mid := EngineSim.boost_torque_factor(0.5, gain, 2.0)
	assert_lt(lagged_mid, linear_mid, "response > 1 gives less power at half spool")
	assert_gt(EngineSim.boost_torque_factor(0.75, gain, 2.0), lagged_mid,
		"factor increases with boost")
	# boost is clamped, so out-of-range input can't exceed the full-boost factor.
	assert_almost_eq(EngineSim.boost_torque_factor(2.0, gain, 2.0), 1.0 + gain, 0.0001,
		"boost clamps at 1.0")


func test_shaft_accel_inverse_with_inertia() -> void:
	# Same net torque, more inertia -> less angular acceleration (laggier spool).
	var light := EngineSim.turbo_shaft_accel(10.0, 0.0, 1.0e-6, 5.0e-6)
	var heavy := EngineSim.turbo_shaft_accel(10.0, 0.0, 1.0e-6, 2.0e-5)
	assert_gt(light, heavy, "a lower-inertia turbo accelerates faster")
	# Drag (omega^2 term) opposes drive.
	var no_drag := EngineSim.turbo_shaft_accel(10.0, 0.0, 1.0e-6, 5.0e-6)
	var with_drag := EngineSim.turbo_shaft_accel(10.0, 5000.0, 1.0e-6, 5.0e-6)
	assert_lt(with_drag, no_drag, "shaft drag reduces net acceleration")


# --- Shaft integration on a bare EngineSim (synthetic turbo config) ----------

func _turbo_config() -> GameConfig:
	# A synthetic, self-contained turbo engine — no catalogue dependency.
	var cfg := GameConfig.new()
	cfg.turbo_enabled = true
	cfg.turbo_inertia = 3.0e-3
	cfg.turbo_omega_ref = 12000.0
	cfg.turbo_boost_gain = 0.8
	cfg.turbo_drive_gain = 0.03
	cfg.turbo_drag_coef = 1.0e-6
	return cfg


# Free-rev a synthetic engine and report where the flywheel ended up: gear 0 (no
# driveline load) so crank torque vs friction is all that moves it. The comparative
# tests below all work by calling this twice with one field changed — never by pinning
# the rpm it returns.
func _climb(cfg: GameConfig, start_omega: float, steps: int) -> float:
	var eng := EngineSim.new(cfg)
	eng.gear = 0
	eng.omega = start_omega
	for _i in range(steps):
		eng.step(0.001, 1.0, 0.0)
	return eng.omega


func test_boost_spools_up_over_time_at_full_throttle() -> void:
	var cfg := _turbo_config()
	var eng := EngineSim.new(cfg)
	eng.gear = 0  # free flywheel: isolate the turbo from the driveline
	eng.omega = eng.redline_omega() * 0.8  # healthy rpm, plenty of flow
	var early := 0.0
	for i in range(400):
		eng.step(0.001, 1.0, 0.0)
		if i == 5:
			early = eng.boost
	assert_lt(early, eng.boost, "boost is still building right after tip-in (lag)")
	assert_gt(eng.boost, 0.1, "boost reaches a meaningful steady value under full flow")


func test_lag_scales_with_inertia() -> void:
	# Bigger turbo (more inertia) takes more steps to reach the same boost.
	var steps_to_half := func(inertia: float) -> int:
		var cfg := _turbo_config()
		cfg.turbo_inertia = inertia
		var eng := EngineSim.new(cfg)
		eng.gear = 0
		eng.omega = eng.redline_omega() * 0.8
		for i in range(5000):
			eng.step(0.001, 1.0, 0.0)
			if eng.boost >= 0.3:
				return i
		return 5000
	var small: int = steps_to_half.call(3.0e-6)
	var large: int = steps_to_half.call(3.0e-5)
	assert_gt(large, small, "a higher-inertia turbo lags more (more steps to a given boost)")


func test_parasitic_friction_bogs_low_rpm_climb() -> void:
	# A fitted turbo's constant parasitic friction is always-on drag: off boost it
	# eats crank torque, so more of it means the engine climbs the low range slower.
	# Compare an identical engine with/without the penalty from low revs at full
	# throttle (boost near zero here, so the penalty dominates). Comparative logic,
	# no pinned values.
	var rpm_after := func(parasitic: float) -> float:
		var cfg := _turbo_config()
		cfg.turbo_parasitic_friction = parasitic
		# Start low, where boost hasn't built yet, so the penalty dominates.
		return _climb(cfg, cfg.idle_rpm * TAU / 60.0, 300)
	var clean: float = rpm_after.call(0.0)
	var burdened: float = rpm_after.call(30.0)
	assert_gt(clean, eng_idle(), "with no penalty the engine climbs off idle")
	assert_lt(burdened, clean, "parasitic friction bogs the low-rpm climb")


func eng_idle() -> float:
	return _turbo_config().idle_rpm * TAU / 60.0


func test_boost_stays_zero_when_disabled() -> void:
	var cfg := _turbo_config()
	cfg.turbo_enabled = false
	var eng := EngineSim.new(cfg)
	eng.gear = 0
	eng.omega = eng.redline_omega() * 0.8
	for i in range(200):
		eng.step(0.001, 1.0, 0.0)
	assert_eq(eng.boost, 0.0, "NA engine (turbo disabled) never builds boost")
	assert_eq(eng.omega_turbo, 0.0, "NA engine leaves the turbo shaft at rest")


func test_antilag_holds_boost_off_throttle() -> void:
	# Spool up, then lift; with anti-lag the shaft settles to a non-zero residual.
	var with_al := func(antilag: bool) -> float:
		var cfg := _turbo_config()
		cfg.turbo_antilag = antilag
		cfg.turbo_antilag_drive = 8.0
		var eng := EngineSim.new(cfg)
		eng.gear = 0
		eng.omega = eng.redline_omega() * 0.8
		for i in range(400):
			eng.step(0.001, 1.0, 0.0)  # spool up
		for i in range(400):
			eng.step(0.001, 0.0, 0.0)  # lift off
		return eng.omega_turbo
	assert_gt(with_al.call(true), with_al.call(false),
		"anti-lag keeps the shaft spinning off-throttle vs decaying to rest")


func test_bov_event_fires_on_lift_while_boosted() -> void:
	var cfg := _turbo_config()
	var eng := EngineSim.new(cfg)
	eng.gear = 0
	eng.omega = eng.redline_omega() * 0.8
	for i in range(400):
		eng.step(0.001, 1.0, 0.0)  # spool up
	assert_gt(eng.boost, EngineSim.BOV_BOOST_THRESHOLD, "precondition: boosted")
	eng.step(0.001, 0.0, 0.0)  # snap the throttle shut
	assert_true(eng.bov_event, "blow-off fires on a lift while boosted")
	# The flag must LATCH across the following coasting substeps (the engine steps
	# 8x per physics tick but audio samples once per frame) — a per-substep reset
	# here is the bug that made the BOV inaudible. It's cleared by the consumer.
	for i in range(8):
		eng.step(0.001, 0.0, 0.0)
	assert_true(eng.bov_event, "blow-off event stays latched across later substeps until consumed")
	# A lift at low boost does not fire it.
	var cold := EngineSim.new(cfg)
	cold.gear = 0
	cold.step(0.001, 1.0, 0.0)  # one step: negligible boost
	cold.step(0.001, 0.0, 0.0)
	assert_false(cold.bov_event, "no blow-off when lifting off boost")


func test_bov_fires_on_gearshift_even_with_throttle_held() -> void:
	# A gearshift dumps boost too — the driver lifts to change gear — so the BOV
	# must fire on a shift START even when the throttle input is still held down.
	var cfg := _turbo_config()
	var eng := EngineSim.new(cfg)
	eng.gear = 0  # neutral: free flywheel, so boost builds unclutched
	eng.omega = eng.redline_omega() * 0.8
	for i in range(400):
		eng.step(0.001, 1.0, 0.0)  # spool on full throttle, no shift
	assert_gt(eng.boost, EngineSim.BOV_BOOST_THRESHOLD, "precondition: boosted")
	assert_false(eng.bov_event, "no blow-off yet: throttle held, no shift")
	eng.request_shift(1)  # driver shifts (still flat on the throttle)
	eng.step(0.001, 1.0, 0.0)
	assert_true(eng.bov_event, "a gearshift vents the blow-off even with throttle held")


# --- Supercharger belt drive (features/forced-induction.md) -------------------

func test_supercharger_boost_is_linear_in_rpm_and_saturates() -> void:
	assert_eq(EngineSim.supercharger_boost_fraction(0.0, 4000.0), 0.0, "stopped engine -> no belt boost")
	var half := EngineSim.supercharger_boost_fraction(2000.0, 4000.0)
	assert_almost_eq(half, 0.5, 0.0001, "belt boost is LINEAR in rpm (crank-driven), not squared")
	assert_almost_eq(EngineSim.supercharger_boost_fraction(4000.0, 4000.0), 1.0, 0.0001,
		"boost is full at rpm_ref")
	assert_almost_eq(EngineSim.supercharger_boost_fraction(9000.0, 4000.0), 1.0, 0.0001,
		"and clamps there above it")
	assert_eq(EngineSim.supercharger_boost_fraction(4000.0, 0.0), 0.0,
		"a zero rpm_ref degrades to no boost rather than dividing by zero")


func test_supercharger_parasitic_grows_with_rpm() -> void:
	# The mirror image of turbo backpressure: belt drag scales with revs, per 1000 rpm.
	assert_eq(EngineSim.supercharger_parasitic(6000.0, 0.0), 0.0, "no coefficient -> no belt drag")
	var low := EngineSim.supercharger_parasitic(2000.0, 9.0)
	var high := EngineSim.supercharger_parasitic(6000.0, 9.0)
	assert_gt(high, low, "the blower costs more the faster it is spun")
	assert_almost_eq(high, low * 3.0, 0.0001, "drag is affine in rpm (3x the revs, 3x the drag)")


func _blown_config() -> GameConfig:
	# Synthetic blown engine: NA baseline plus the belt fields the upgrade stamps on.
	var cfg := GameConfig.new()
	cfg.supercharger_enabled = true
	cfg.supercharger_boost_gain = 1.0
	cfg.supercharger_rpm_ref = 4000.0
	return cfg


func test_supercharger_boost_arrives_without_spooling() -> void:
	# The defining contrast with a turbo: boost is there on the FIRST substep, because
	# there's no shaft with inertia to bring up to speed.
	var cfg := _blown_config()
	var eng := EngineSim.new(cfg)
	eng.gear = 0
	eng.omega = eng.redline_omega() * 0.8
	eng.step(0.001, 1.0, 0.0)
	assert_almost_eq(eng.sc_boost, 1.0, 0.0001, "above rpm_ref, full belt boost on the first step")
	assert_eq(eng.boost, 0.0, "and the turbo path stays inert on a blown-only engine")


func test_supercharger_boost_tracks_rpm_both_ways() -> void:
	var cfg := _blown_config()
	var eng := EngineSim.new(cfg)
	eng.gear = 0
	eng.omega = cfg.supercharger_rpm_ref * 0.5 * TAU / 60.0  # half of rpm_ref
	eng.step(0.001, 1.0, 0.0)
	var mid := eng.sc_boost
	assert_gt(mid, 0.0, "part-rev engine makes part boost")
	assert_lt(mid, 1.0, "but not full boost below rpm_ref")
	# Drop the revs and the boost falls with them the same substep — no bleed-down lag.
	eng.omega = cfg.idle_rpm * TAU / 60.0
	eng.step(0.001, 1.0, 0.0)
	assert_lt(eng.sc_boost, mid, "belt boost falls with the revs immediately")


func test_supercharger_boost_gain_adds_torque() -> void:
	# Same engine, same rpm: the belt gain makes the crank climb faster. Comparative.
	var rpm_after := func(gain: float) -> float:
		var cfg := _blown_config()
		cfg.supercharger_boost_gain = gain
		cfg.supercharger_parasitic_coef = 0.0  # isolate the gain from the drag
		return _climb(cfg, cfg.redline_rpm * TAU / 60.0 * 0.5, 200)
	assert_gt(rpm_after.call(1.0), rpm_after.call(0.0), "belt boost delivers extra torque")


func test_supercharger_inert_without_a_gain() -> void:
	# A STOCK blown engine (flag on for the whine, gain 0 because the power is baked
	# into peak_torque) must be byte-identical to NA in the sim.
	var cfg := _blown_config()
	cfg.supercharger_boost_gain = 0.0
	var eng := EngineSim.new(cfg)
	eng.gear = 0
	eng.omega = eng.redline_omega() * 0.8
	for i in range(200):
		eng.step(0.001, 1.0, 0.0)
	assert_eq(eng.sc_boost, 0.0, "no authored gain -> the belt physics never engage")


func test_supercharger_belt_drag_bogs_the_climb() -> void:
	# Belt drag is real crank friction: a coefficient must slow the rev climb. Both runs
	# keep the SAME (fitted) boost gain so the torque they make is identical and only the
	# drag differs — the gain can't be zeroed to isolate it, because zero gain means "no
	# blower fitted" and skips the whole belt path, drag included. Held well clear of the
	# limiter so the comparison isn't decided by the rev clamp.
	var rpm_after := func(coef: float) -> float:
		var cfg := _blown_config()
		cfg.supercharger_parasitic_coef = coef
		return _climb(cfg, cfg.idle_rpm * TAU / 60.0, 200)
	var clean: float = rpm_after.call(0.0)
	assert_lt(clean, _blown_config().redline_rpm * TAU / 60.0, "precondition: nowhere near the limiter")
	assert_lt(rpm_after.call(60.0), clean, "belt drag slows the climb")


func test_belt_drag_is_skipped_with_no_blower_fitted() -> void:
	# The drag rides the same has_supercharger_physics() gate as the boost, so an engine
	# with no blower pays nothing for the feature — a stray parasitic_coef on an unfitted
	# config must not quietly bog it (and the per-substep call is skipped outright).
	var rpm_after := func(coef: float) -> float:
		var cfg := _blown_config()
		cfg.supercharger_boost_gain = 0.0  # no blower fitted: belt path off
		cfg.supercharger_parasitic_coef = coef
		return _climb(cfg, cfg.idle_rpm * TAU / 60.0, 200)
	assert_eq(rpm_after.call(60.0), rpm_after.call(0.0),
		"with no blower fitted the belt drag is not applied at all")


func test_reset_clears_belt_boost() -> void:
	var cfg := _blown_config()
	var eng := EngineSim.new(cfg)
	eng.gear = 0
	eng.omega = eng.redline_omega() * 0.8
	eng.step(0.001, 1.0, 0.0)
	assert_gt(eng.sc_boost, 0.0, "precondition: boosted")
	eng.reset()
	assert_eq(eng.sc_boost, 0.0, "reset returns the blower to no boost")
