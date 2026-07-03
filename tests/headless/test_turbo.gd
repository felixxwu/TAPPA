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
