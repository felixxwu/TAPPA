extends GutTest
# Per-car tuning (TuningLibrary): the pure effect-application of pipeline step 3
# (baseline → upgrades → TUNING → damage), and the per-axis unlock gating. The
# brake-split drivetrain change this drives is covered in test_drivetrain.gd; the
# lift UI that sets these sliders is in test_menu_flow.gd. See features/tuning.md.


func _cfg() -> GameConfig:
	var cfg := GameConfig.new()
	cfg.wheel_friction_slip_front = 0.8
	cfg.wheel_friction_slip_rear = 0.6
	cfg.downforce_front = 0.5
	cfg.downforce_rear = 0.5
	cfg.brake_bias = 0.4
	cfg.tuning_grip_authority = 0.15
	cfg.tuning_brake_authority = 0.3
	cfg.tuning_aero_authority = 0.5
	return cfg


func test_neutral_tuning_is_a_no_op() -> void:
	var cfg := _cfg()
	# All axes at 0 (or absent) leave grip / aero / brake bias at the baseline.
	TuningLibrary.apply({"installed_upgrades": ["aero_kit", "brake_kit"], "tuning": {}}, cfg)
	assert_almost_eq(cfg.wheel_friction_slip_front, 0.8, 0.0001, "neutral leaves front grip")
	assert_almost_eq(cfg.wheel_friction_slip_rear, 0.6, 0.0001, "neutral leaves rear grip")
	assert_almost_eq(cfg.downforce_front, 0.5, 0.0001, "neutral leaves front downforce")
	assert_almost_eq(cfg.downforce_rear, 0.5, 0.0001, "neutral leaves rear downforce")
	assert_almost_eq(cfg.brake_bias, 0.4, 0.0001, "neutral leaves brake bias at the 40/60 default")


func test_grip_balance_shifts_grip_rearward_and_is_monotonic() -> void:
	# +1 shifts grip toward oversteer (rear up, front down) by tuning_grip_authority.
	var cfg := _cfg()
	TuningLibrary.apply({"tuning": {"grip_balance": 1.0}}, cfg)
	assert_almost_eq(cfg.wheel_friction_slip_front, 0.8 * 0.85, 0.0001, "+1 drops front grip 15%")
	assert_almost_eq(cfg.wheel_friction_slip_rear, 0.6 * 1.15, 0.0001, "+1 raises rear grip 15%")
	# −1 is the mirror image (understeer: front up, rear down).
	var cfg2 := _cfg()
	TuningLibrary.apply({"tuning": {"grip_balance": -1.0}}, cfg2)
	assert_almost_eq(cfg2.wheel_friction_slip_front, 0.8 * 1.15, 0.0001, "−1 raises front grip")
	assert_almost_eq(cfg2.wheel_friction_slip_rear, 0.6 * 0.85, 0.0001, "−1 drops rear grip")
	# Monotonic: a half-step sits between neutral and full.
	var cfg3 := _cfg()
	TuningLibrary.apply({"tuning": {"grip_balance": 0.5}}, cfg3)
	assert_lt(cfg3.wheel_friction_slip_front, 0.8, "half-step front grip below baseline")
	assert_gt(cfg3.wheel_friction_slip_front, cfg.wheel_friction_slip_front, "and above the full-step")


func test_grip_balance_needs_no_upgrade() -> void:
	var cfg := _cfg()
	TuningLibrary.apply({"installed_upgrades": [], "tuning": {"grip_balance": 1.0}}, cfg)
	assert_lt(cfg.wheel_friction_slip_front, 0.8, "grip balance applies with no upgrades")


func test_aero_balance_is_gated_by_the_aero_upgrade() -> void:
	# No aero kit → aero_balance is a no-op even at full slider.
	var locked := _cfg()
	TuningLibrary.apply({"installed_upgrades": [], "tuning": {"aero_balance": 1.0}}, locked)
	assert_almost_eq(locked.downforce_front, 0.5, 0.0001, "no aero kit: front downforce unchanged")
	assert_almost_eq(locked.downforce_rear, 0.5, 0.0001, "no aero kit: rear downforce unchanged")
	# With the aero kit, +1 shifts downforce rearward by tuning_aero_authority.
	var unlocked := _cfg()
	TuningLibrary.apply({"installed_upgrades": ["aero_kit"], "tuning": {"aero_balance": 1.0}}, unlocked)
	assert_almost_eq(unlocked.downforce_front, 0.5 * 0.5, 0.0001, "aero kit: +1 drops front downforce")
	assert_almost_eq(unlocked.downforce_rear, 0.5 * 1.5, 0.0001, "aero kit: +1 raises rear downforce")


func test_brake_bias_is_gated_by_the_brakes_upgrade() -> void:
	# No brake kit → brake_bias forced to the 0.4 (40/60) stock default, ignoring the slider.
	var locked := _cfg()
	TuningLibrary.apply({"installed_upgrades": [], "tuning": {"brake_bias": 1.0}}, locked)
	assert_almost_eq(locked.brake_bias, 0.4, 0.0001, "no brake kit: bias pinned at the 40/60 default")
	# With the brake kit, the slider moves the split ±tuning_brake_authority around the
	# 0.4 default: +1 -> 0.7 forward, −1 -> 0.1 rearward.
	var unlocked := _cfg()
	TuningLibrary.apply({"installed_upgrades": ["brake_kit"], "tuning": {"brake_bias": 1.0}}, unlocked)
	assert_almost_eq(unlocked.brake_bias, 0.7, 0.0001, "brake kit: +1 sends 70% to the front")
	var rearward := _cfg()
	TuningLibrary.apply({"installed_upgrades": ["brake_kit"], "tuning": {"brake_bias": -1.0}}, rearward)
	assert_almost_eq(rearward.brake_bias, 0.1, 0.0001, "brake kit: −1 sends 90% to the rear")


func test_out_of_range_sliders_clamp() -> void:
	# A slider value beyond [-1, 1] clamps; authority bounds never invert/zero a value.
	var cfg := _cfg()
	TuningLibrary.apply({
		"installed_upgrades": ["aero_kit", "brake_kit"],
		"tuning": {"grip_balance": 5.0, "aero_balance": -9.0, "brake_bias": 3.0},
	}, cfg)
	assert_almost_eq(cfg.wheel_friction_slip_front, 0.8 * 0.85, 0.0001, "grip clamps at +1")
	assert_almost_eq(cfg.downforce_front, 0.5 * 1.5, 0.0001, "aero clamps at −1 (front up)")
	assert_almost_eq(cfg.brake_bias, 0.7, 0.0001, "brake bias clamps at +1")
	assert_gt(cfg.wheel_friction_slip_front, 0.0, "grip never zeroes")
	assert_gt(cfg.brake_bias, 0.0, "brake bias never inverts")
	assert_lt(cfg.brake_bias, 1.0, "brake bias never saturates past the split")


func test_axis_unlocked_reports_gating() -> void:
	var bare := {"installed_upgrades": []}
	assert_true(TuningLibrary.axis_unlocked(bare, "grip_balance"), "grip always tunable")
	assert_false(TuningLibrary.axis_unlocked(bare, "brake_bias"), "brake bias locked without the kit")
	assert_false(TuningLibrary.axis_unlocked(bare, "aero_balance"), "aero locked without the kit")
	var kitted := {"installed_upgrades": ["aero_kit", "brake_kit"]}
	assert_true(TuningLibrary.axis_unlocked(kitted, "brake_bias"), "brake kit unlocks brake bias")
	assert_true(TuningLibrary.axis_unlocked(kitted, "aero_balance"), "aero kit unlocks aero balance")


func test_engine_detune_scales_torque() -> void:
	var cfg := _cfg()
	cfg.peak_torque = 300.0
	# Neutral / absent leaves torque alone.
	TuningLibrary.apply({"tuning": {}}, cfg)
	assert_almost_eq(cfg.peak_torque, 300.0, 0.0001, "no detune -> full torque")
	# Half detune halves torque.
	var cfg2 := _cfg()
	cfg2.peak_torque = 300.0
	TuningLibrary.apply({"tuning": {"engine_detune": 0.5}}, cfg2)
	assert_almost_eq(cfg2.peak_torque, 150.0, 0.0001, "0.5 detune halves torque")
	# Out-of-range clamps.
	var cfg3 := _cfg()
	cfg3.peak_torque = 300.0
	TuningLibrary.apply({"tuning": {"engine_detune": 2.0}}, cfg3)
	assert_almost_eq(cfg3.peak_torque, 300.0, 0.0001, "detune clamps at 1.0")


func test_engine_detune_is_a_known_axis() -> void:
	assert_true(TuningLibrary.AXES.has("engine_detune"), "detune is an axis (drives reset + slider refresh)")
	assert_true(TuningLibrary.axis_unlocked({}, "engine_detune"), "detune is always available")
