extends GutTest

# TuningPanel is the reusable per-car tuning-slider UI shared by the HQ lift and the
# start-line grid. These tests use synthetic owned-car dicts (no catalogue dependency)
# and check the panel's LOGIC/behaviour, not any tuned value.

const TuningPanelScript = preload("res://scripts/tuning_panel.gd")

# A synthetic owned car — brake/aero locked (no upgrades), grip always tunable.
func _owned() -> Dictionary:
	return {"instance_id": 1, "model_id": "synthetic", "tuning": {}, "upgrades": {}}

func _panel(owned: Dictionary, cb := Callable()) -> Control:
	var p = TuningPanelScript.new()
	add_child_autofree(p)
	p.setup(owned, cb)
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

func test_reset_clears_handling_axes() -> void:
	var owned := _owned()
	owned["tuning"] = {"grip_balance": 0.7}
	var p = _panel(owned)
	p._reset()
	assert_false(owned["tuning"].has("grip_balance"), "reset clears the handling axes")

func test_reset_preserves_engine_detune() -> void:
	# engine_detune is a power knob owned by the upgrades menu, not a handling axis, so
	# the tuning panel's Reset must leave it alone (not silently restore full power).
	var owned := _owned()
	owned["tuning"] = {"grip_balance": 0.7, "engine_detune": 0.6}
	var p = _panel(owned)
	p._reset()
	assert_false(owned["tuning"].has("grip_balance"), "handling axis cleared")
	assert_almost_eq(float(owned["tuning"].get("engine_detune", 1.0)), 0.6, 0.0001,
		"detune preserved across a handling reset")

func test_no_detune_slider_on_the_tuning_panel() -> void:
	# Engine detune moved to the upgrades menu — the tuning panel only has handling axes.
	var p = _panel(_owned())
	assert_false(p._sliders.has("engine_detune"), "detune is no longer a tuning-panel axis")


# --- Task 3: a start-line-style tune bakes into the live config via TuningLibrary. ---
func test_grip_tuning_shifts_front_rear_grip_off_baseline() -> void:
	var cfg := GameConfig.new()
	cfg.wheel_friction_slip_front = 2.0
	cfg.wheel_friction_slip_rear = 2.0
	cfg.tuning_grip_authority = 0.2   # any reasonable non-zero authority
	var owned := {"instance_id": 1, "tuning": {"grip_balance": 1.0}, "upgrades": {}}
	TuningLibrary.apply(owned, cfg)
	assert_gt(cfg.wheel_friction_slip_front, 2.0, "oversteer moves grip onto the front")
	assert_lt(cfg.wheel_friction_slip_rear, 2.0, "oversteer moves grip off the rear")
