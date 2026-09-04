extends GutTest

# TuningPanel is the reusable per-car tuning-slider UI. Its only host today is the
# start line (the HQ lift, its other one, is deleted with the diegetic hub). These tests
# use synthetic owned-car dicts (no catalogue dependency) and check the panel's
# LOGIC/behaviour, not any tuned value.

const TuningPanelScript = preload("res://scripts/tuning_panel.gd")

# A synthetic owned car. Every axis is tunable: decision 24 ungated all three.
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

# EVERY axis is editable, on every car. This asserted the opposite — that aero_balance was
# locked "without the aero kit" — until todo/roguelike-pivot.md decision 24 ungated tuning
# outright and took TuningLibrary.axis_unlocked with the parts model that fed it. The
# behaviour changed deliberately, so the test follows it.
func test_every_axis_is_editable_on_every_car() -> void:
	var p = _panel(_owned())
	for axis in TuningLibrary.AXES:
		assert_true(p._sliders[axis].editable,
			"%s is tunable with no gate — decision 24" % axis)


# SALVAGED from the deleted test_menu_flow.gd, which drove this through the HQ lift's TUNE
# page. It never needed a host: the rows are built by the panel, and the fixed label column
# is what guarantees the alignment.
func test_the_sliders_are_all_the_same_length() -> void:
	var p = _panel(_owned())
	await get_tree().process_frame
	await get_tree().process_frame
	var widths: Array = []
	for axis in TuningLibrary.AXES:
		widths.append((p._sliders[axis] as HSlider).size.x)
	for w in widths:
		assert_almost_eq(float(w), float(widths[0]), 0.5,
			"every handling-axis slider lines up to the same width, however long its "
			+ "value label is")

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

func test_wheels_button_hidden_without_an_on_wheels_callback() -> void:
	# The start-line's copy of this panel passes no on_wheels — a button that fires
	# nothing would be confusing, so it stays hidden there.
	var p = TuningPanelScript.new()
	add_child_autofree(p)
	p.setup(_owned())
	p.refresh()
	assert_not_null(p._wheels_button, "the Wheels button always exists")
	assert_false(p._wheels_button.visible, "Wheels is hidden when the host wires no on_wheels")

func test_wheels_button_shown_and_fires_on_wheels() -> void:
	var fired := [0]
	var p = TuningPanelScript.new()
	add_child_autofree(p)
	p.setup(_owned(), Callable(), func(): fired[0] += 1)
	p.refresh()
	assert_true(p._wheels_button.visible, "Wheels is shown once the host wires on_wheels")
	assert_eq(p._wheels_button.focus_mode, Control.FOCUS_ALL,
		"Wheels is keyboard/gamepad focusable, matching the panel's sliders")
	p._on_wheels_pressed()
	assert_eq(fired[0], 1, "pressing Wheels fires the host's on_wheels callback")


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
