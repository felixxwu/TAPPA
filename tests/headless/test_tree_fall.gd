extends GutTest
# Pure, scene-free maths for felling trees on a fast crash (TreeFall). Per CLAUDE.md
# these tests assert the LOGIC that must hold for ANY reasonable tuning — they never
# pin the chosen tree_fell_speed_kmh / duration. The threshold is fed in via a
# synthetic GameConfig so the boundary is asserted relative to THAT value.


func _cfg(threshold_kmh: float) -> GameConfig:
	var c := GameConfig.new()
	c.tree_fell_speed_kmh = threshold_kmh
	return c


func test_should_fell_boundary_is_relative_to_threshold() -> void:
	var threshold := 50.0
	var cfg := _cfg(threshold)
	var thr_mps := threshold / DamageModel.MPS_TO_KMH
	assert_false(TreeFall.should_fell(thr_mps - 1.0, cfg), "below threshold: no fell")
	assert_true(TreeFall.should_fell(thr_mps, cfg), "at threshold: fell")
	assert_true(TreeFall.should_fell(thr_mps + 5.0, cfg), "above threshold: fell")


func test_should_fell_disabled_when_threshold_non_positive() -> void:
	assert_false(TreeFall.should_fell(1000.0, _cfg(0.0)),
		"zero threshold disables felling at any speed")


func test_fall_angle_starts_upright_is_monotonic_and_clamps_flat() -> void:
	var dur := 0.6
	assert_almost_eq(TreeFall.fall_angle(0.0, dur), 0.0, 1e-6, "upright at t=0")
	var prev := -1.0
	for step in 20:
		var a := TreeFall.fall_angle(dur * float(step) / 19.0, dur)
		assert_true(a >= prev - 1e-6, "angle is non-decreasing")
		prev = a
	var flat := TreeFall.fall_angle(dur, dur)
	assert_almost_eq(flat, TreeFall.FLAT_ANGLE, 1e-6, "reaches flat by duration")
	assert_almost_eq(TreeFall.fall_angle(dur * 10.0, dur), TreeFall.FLAT_ANGLE, 1e-6,
		"clamps to flat past duration, no overshoot")


func test_fall_angle_zero_duration_is_immediately_flat() -> void:
	assert_almost_eq(TreeFall.fall_angle(0.0, 0.0), TreeFall.FLAT_ANGLE, 1e-6,
		"degenerate duration snaps flat")


func test_topple_axis_is_horizontal_and_perpendicular() -> void:
	var dir := Vector3(1.0, 0.0, 0.0)
	var axis := TreeFall.topple_axis(dir)
	assert_almost_eq(axis.length(), 1.0, 1e-6, "unit axis")
	assert_almost_eq(axis.y, 0.0, 1e-6, "axis is level with the ground")
	assert_almost_eq(axis.dot(dir), 0.0, 1e-6, "axis perpendicular to travel dir")


func test_topple_axis_degenerate_input_yields_valid_unit_axis() -> void:
	assert_almost_eq(TreeFall.topple_axis(Vector3.ZERO).length(), 1.0, 1e-6,
		"zero dir still gives a unit axis")
	assert_almost_eq(TreeFall.topple_axis(Vector3.UP).length(), 1.0, 1e-6,
		"vertical dir still gives a unit axis")
