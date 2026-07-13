extends GutTest

# TuningPanel is the reusable per-car tuning-slider UI shared by the HQ lift and the
# start-line grid. These tests use synthetic owned-car dicts (no catalogue dependency)
# and check the panel's LOGIC/behaviour, not any tuned value.

const TuningPanelScript = preload("res://scripts/tuning_panel.gd")

# A synthetic owned car — brake/aero locked (no upgrades), grip/detune always tunable.
func _owned() -> Dictionary:
	return {"instance_id": 1, "model_id": "synthetic", "tuning": {}, "upgrades": {}}

func _panel(owned: Dictionary, cb := Callable(), detune_max := 1.0) -> Control:
	var p = TuningPanelScript.new()
	add_child_autofree(p)
	p.setup(owned, cb, detune_max)
	p.refresh()
	return p

func test_setup_builds_a_slider_per_axis() -> void:
	var p = _panel(_owned())
	for axis in TuningLibrary.AXES:
		assert_true(p._sliders.has(axis), "has a slider for %s" % axis)

func test_editing_grip_writes_axis_and_fires_callback() -> void:
	var owned := _owned()
	var fired := [0]
	var p = _panel(owned, func(): fired[0] += 1)
	p._sliders["grip_balance"].value = 0.5   # emits value_changed
	assert_almost_eq(float(owned["tuning"]["grip_balance"]), 0.5, 0.001)
	assert_gt(fired[0], 0, "on_change fired")

func test_locked_axis_slider_not_editable() -> void:
	var p = _panel(_owned())
	assert_false(p._sliders["brake_bias"].editable, "brake_bias locked without kit")
	assert_true(p._sliders["grip_balance"].editable, "grip always editable")

func test_reset_clears_tuning() -> void:
	var owned := _owned()
	owned["tuning"] = {"grip_balance": 0.7}
	var p = _panel(owned)
	p._reset()
	assert_eq(owned["tuning"], {}, "reset clears the tuning dict")

func test_detune_cap_limits_the_engine_detune_slider() -> void:
	# The start line passes a detune ceiling (the rally's qualifying detune) so the car
	# can't be tuned back above its power-to-weight cap. Default 1.0 leaves it at 100%.
	var uncapped = _panel(_owned())
	assert_eq(uncapped._sliders["engine_detune"].max_value, 100.0, "no cap → full 100% available")
	var capped = _panel(_owned(), Callable(), 0.8)
	assert_almost_eq(capped._sliders["engine_detune"].max_value, 80.0, 0.001,
		"the detune slider can't be pushed above the qualifying power")


# --- Task 3: a start-line-style tune bakes into the live config via TuningLibrary. ---
func test_grip_tuning_shifts_front_rear_grip_off_baseline() -> void:
	var cfg := GameConfig.new()
	cfg.wheel_friction_slip_front = 2.0
	cfg.wheel_friction_slip_rear = 2.0
	cfg.tuning_grip_authority = 0.2   # any reasonable non-zero authority
	var owned := {"instance_id": 1, "tuning": {"grip_balance": 1.0}, "upgrades": {}}
	TuningLibrary.apply(owned, cfg)
	assert_lt(cfg.wheel_friction_slip_front, 2.0, "oversteer moves grip off the front")
	assert_gt(cfg.wheel_friction_slip_rear, 2.0, "oversteer moves grip onto the rear")
