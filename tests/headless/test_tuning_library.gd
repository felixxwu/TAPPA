extends GutTest
# Per-car tuning (TuningLibrary): the pure effect-application of pipeline step 3
# (baseline → upgrades → TUNING → damage), and the per-axis unlock gating. The
# brake-split drivetrain change this drives is covered in test_drivetrain.gd; the
# UI that sets these sliders is TuningPanel (test_tuning_panel.gd). See features/tuning.md.

const UpgradeFixtures = preload("res://tests/headless/upgrade_fixtures.gd")






func _cfg() -> GameConfig:
	var cfg := GameConfig.new()
	cfg.wheel_friction_slip_front = 0.8
	cfg.wheel_friction_slip_rear = 0.6
	cfg.downforce_front = 0.5
	cfg.downforce_rear = 0.5
	cfg.brake_bias = 0.55  # a car's per-car default baseline (NOT the old hardcoded 0.4)
	cfg.tuning_grip_authority = 0.15
	cfg.tuning_brake_authority = 0.3
	cfg.tuning_aero_authority = 0.5
	return cfg


func test_neutral_tuning_is_a_no_op() -> void:
	var cfg := _cfg()
	# All axes at 0 (or absent) leave grip / aero / brake bias at the baseline.
	TuningLibrary.apply({"installed_upgrades": ["fx_aero"], "tuning": {}}, cfg)
	assert_almost_eq(cfg.wheel_friction_slip_front, 0.8, 0.0001, "neutral leaves front grip")
	assert_almost_eq(cfg.wheel_friction_slip_rear, 0.6, 0.0001, "neutral leaves rear grip")
	assert_almost_eq(cfg.downforce_front, 0.5, 0.0001, "neutral leaves front downforce")
	assert_almost_eq(cfg.downforce_rear, 0.5, 0.0001, "neutral leaves rear downforce")
	assert_almost_eq(cfg.brake_bias, 0.55, 0.0001, "neutral leaves brake bias at the car's baseline")


func test_grip_balance_shifts_grip_forward_and_is_monotonic() -> void:
	# +1 shifts grip toward oversteer (front up, rear down) by tuning_grip_authority.
	var cfg := _cfg()
	TuningLibrary.apply({"tuning": {"grip_balance": 1.0}}, cfg)
	assert_almost_eq(cfg.wheel_friction_slip_front, 0.8 * 1.15, 0.0001, "+1 raises front grip 15%")
	assert_almost_eq(cfg.wheel_friction_slip_rear, 0.6 * 0.85, 0.0001, "+1 drops rear grip 15%")
	# −1 is the mirror image (understeer: front down, rear up).
	var cfg2 := _cfg()
	TuningLibrary.apply({"tuning": {"grip_balance": -1.0}}, cfg2)
	assert_almost_eq(cfg2.wheel_friction_slip_front, 0.8 * 0.85, 0.0001, "−1 drops front grip")
	assert_almost_eq(cfg2.wheel_friction_slip_rear, 0.6 * 1.15, 0.0001, "−1 raises rear grip")
	# Monotonic: a half-step sits between neutral and full.
	var cfg3 := _cfg()
	TuningLibrary.apply({"tuning": {"grip_balance": 0.5}}, cfg3)
	assert_gt(cfg3.wheel_friction_slip_front, 0.8, "half-step front grip above baseline")
	assert_lt(cfg3.wheel_friction_slip_front, cfg.wheel_friction_slip_front, "and below the full-step")


func test_grip_balance_needs_no_upgrade() -> void:
	var cfg := _cfg()
	TuningLibrary.apply({"installed_upgrades": [], "tuning": {"grip_balance": 1.0}}, cfg)
	assert_gt(cfg.wheel_friction_slip_front, 0.8, "grip balance applies with no upgrades")


# CHANGED DELIBERATELY: aero_balance used to be GATED on owning the aero kit. Tuning is
# ungated in the pivot (todo/roguelike-pivot.md decision 24) and the kit that gated it went
# with the parts model, so the axis now applies on any car. What is still worth pinning is
# the SHIFT ITSELF -- +1 moves downforce rearward -- not who is allowed to ask for it.
func test_aero_balance_shifts_downforce_rearward_on_any_car() -> void:
	var cfg := _cfg()
	TuningLibrary.apply({"tuning": {"aero_balance": 1.0}}, cfg)
	assert_lt(cfg.downforce_front, 0.5, "+1 drops front downforce")
	assert_gt(cfg.downforce_rear, 0.5, "and raises rear downforce")

	var neutral := _cfg()
	TuningLibrary.apply({"tuning": {"aero_balance": 0.0}}, neutral)
	assert_almost_eq(neutral.downforce_front, 0.5, 0.0001, "a centred slider changes nothing")
	assert_almost_eq(neutral.downforce_rear, 0.5, 0.0001)


func test_brake_bias_is_tunable_with_no_upgrades() -> void:
	# Brake bias is a FREE axis (no upgrade gate): the slider moves the split
	# ±tuning_brake_authority around the car's baseline (0.55) on a bare car —
	# +1 -> 0.85 forward, −1 -> 0.25 rearward.
	var forward := _cfg()
	TuningLibrary.apply({"installed_upgrades": [], "tuning": {"brake_bias": 1.0}}, forward)
	assert_almost_eq(forward.brake_bias, 0.85, 0.0001, "+1 shifts 0.3 forward of baseline")
	var rearward := _cfg()
	TuningLibrary.apply({"installed_upgrades": [], "tuning": {"brake_bias": -1.0}}, rearward)
	assert_almost_eq(rearward.brake_bias, 0.25, 0.0001, "−1 shifts 0.3 rearward of baseline")
	# Neutral (the default) leaves the car's authored baseline alone.
	var neutral := _cfg()
	TuningLibrary.apply({"installed_upgrades": [], "tuning": {}}, neutral)
	assert_almost_eq(neutral.brake_bias, 0.55, 0.0001, "no slider value leaves the baseline intact")


func test_brake_bias_slider_recenters_on_the_car_baseline() -> void:
	# The slider is baseline-relative, not pinned to any fixed centre: the SAME slider
	# value produces different results for cars with different default biases.
	var front_biased := _cfg()
	front_biased.brake_bias = 0.60
	TuningLibrary.apply({"installed_upgrades": [], "tuning": {"brake_bias": 1.0}}, front_biased)
	var rear_biased := _cfg()
	rear_biased.brake_bias = 0.45
	TuningLibrary.apply({"installed_upgrades": [], "tuning": {"brake_bias": 1.0}}, rear_biased)
	assert_almost_eq(front_biased.brake_bias - rear_biased.brake_bias, 0.15, 0.0001,
		"same slider preserves the gap between the two cars' baselines")


func test_out_of_range_sliders_clamp() -> void:
	# A slider value beyond [-1, 1] clamps; authority bounds never invert/zero a value.
	var cfg := _cfg()
	TuningLibrary.apply({
		"installed_upgrades": ["fx_aero"],
		"tuning": {"grip_balance": 5.0, "aero_balance": -9.0, "brake_bias": 3.0},
	}, cfg)
	assert_almost_eq(cfg.wheel_friction_slip_front, 0.8 * 1.15, 0.0001, "grip clamps at +1")
	assert_almost_eq(cfg.downforce_front, 0.5 * 1.5, 0.0001, "aero clamps at −1 (front up)")
	assert_almost_eq(cfg.brake_bias, 0.85, 0.0001, "brake bias clamps at +1 (baseline + authority)")
	assert_gt(cfg.wheel_friction_slip_front, 0.0, "grip never zeroes")
	assert_gt(cfg.brake_bias, 0.0, "brake bias never inverts")
	assert_lt(cfg.brake_bias, 1.0, "brake bias never saturates past the split")


# NOTE: the aero_balance tuning GATE and its test are deleted. Tuning is ungated in the
# pivot (todo/roguelike-pivot.md decision 24) and the aero kit that gated it went with the
# parts model, so TuningLibrary.axis_unlocked has nothing left to answer. The slider
# CLAMPING and application logic below is unaffected and still covered.


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


func test_engine_detune_is_not_a_handling_axis() -> void:
	# Detune is a power (p/w) knob, not one of the lift's handling axes: its slider
	# lives in the upgrades menu, so it must stay out of AXES (which drives the lift's
	# reset + slider refresh). apply() still honours the stored value regardless — see
	# test_engine_detune_scales_torque.
	assert_false(TuningLibrary.AXES.has("engine_detune"), "detune is a p/w knob, not a handling axis")
