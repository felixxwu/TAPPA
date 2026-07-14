extends GutTest
# Pure, scene-free maths for felling trees on a fast crash (TreeFall). Per CLAUDE.md
# these tests assert the LOGIC that must hold for ANY reasonable tuning — they never
# pin the chosen tree_fell_speed_kmh / duration. The threshold is fed in via a
# synthetic GameConfig so the boundary is asserted relative to THAT value.


func _cfg(threshold_kmh: float) -> GameConfig:
	var c := GameConfig.new()
	c.tree_fell_speed_kmh = threshold_kmh
	return c


func _cfg_keep(threshold_kmh: float, keep_max: float) -> GameConfig:
	var c := GameConfig.new()
	c.tree_fell_speed_kmh = threshold_kmh
	c.tree_plough_keep_max = keep_max
	return c


func test_fell_speed_scales_linearly_with_size() -> void:
	var cfg := _cfg(60.0)
	# Full size preserves the configured threshold; the number is fed in, not pinned.
	assert_almost_eq(TreeFall.fell_speed_kmh(1.0, cfg), 60.0, 1e-6, "full size == threshold")
	assert_almost_eq(TreeFall.fell_speed_kmh(0.5, cfg), 30.0, 1e-6, "half size == half threshold")
	# Monotonic non-decreasing in size.
	var prev := -1.0
	for i in 11:
		var s := float(i) / 10.0
		var v := TreeFall.fell_speed_kmh(s, cfg)
		assert_true(v >= prev - 1e-6, "fell speed non-decreasing in size")
		prev = v


func test_should_fell_sized_smaller_tree_fells_at_lower_speed() -> void:
	var cfg := _cfg(60.0)
	var speed := 20.0 / DamageModel.MPS_TO_KMH  # 20 km/h
	# 20 km/h fells a small (30%) tree (threshold 18 km/h) but not a full one (60 km/h).
	assert_true(TreeFall.should_fell_sized(speed, 0.3, cfg), "small tree fells at low speed")
	assert_false(TreeFall.should_fell_sized(speed, 1.0, cfg), "full tree holds at that speed")


func test_should_fell_sized_disabled_when_threshold_non_positive() -> void:
	assert_false(TreeFall.should_fell_sized(1000.0, 0.3, _cfg(0.0)),
		"zero threshold disables felling at any size/speed")


func test_plough_keep_full_size_is_zero_and_monotonic_and_bounded() -> void:
	var cfg := _cfg_keep(60.0, 0.8)
	assert_almost_eq(TreeFall.plough_keep(1.0, cfg), 0.0, 1e-6, "full-size tree returns nothing")
	var prev := 2.0
	for i in 11:
		var s := float(i) / 10.0
		var k := TreeFall.plough_keep(s, cfg)
		assert_true(k >= 0.0 and k <= 1.0, "keep fraction in [0,1]")
		assert_true(k <= prev + 1e-6, "keep fraction non-increasing in size")
		prev = k


func test_plough_keep_off_switch() -> void:
	var cfg := _cfg_keep(60.0, 0.0)
	for i in 11:
		assert_almost_eq(TreeFall.plough_keep(float(i) / 10.0, cfg), 0.0, 1e-6,
			"keep_max 0 disables plough-through at every size")


func test_plough_restore_zero_keep_is_a_hard_stop() -> void:
	# keep == 0 (full-size felled tree, or plough-through disabled) leaves the solver's
	# post-solve velocity untouched — the car stops dead as it does today.
	var post := Vector3(0, -1, 0)
	assert_eq(TreeFall.plough_restore_velocity(Vector3(0, -1, -20), post, 0.0, 20.0), post,
		"keep 0 returns the arrested velocity unchanged")


func test_plough_restore_returns_forward_momentum_scaled_by_keep() -> void:
	# Head-on: solver arrested the car to ~0; a small tree (keep 0.7) hands back 70% of
	# the shed forward speed, along the original heading.
	var approach := Vector3(0, 0, -20)
	var v := TreeFall.plough_restore_velocity(approach, Vector3.ZERO, 0.7, 20.0)
	assert_almost_eq(v.z, -14.0, 1e-5, "keeps 70% of forward speed")
	assert_almost_eq(v.x, 0.0, 1e-5, "no lateral velocity introduced")
	# More keep => more retained speed (monotonic).
	var slow := TreeFall.plough_restore_velocity(approach, Vector3.ZERO, 0.3, 20.0)
	assert_lt(absf(slow.z), absf(v.z), "a larger tree (less keep) retains less speed")


func test_plough_restore_never_exceeds_approach_speed() -> void:
	# Glancing hit: solver barely slowed the car; the restore must not add free energy.
	var approach := Vector3(0, 0, -20)
	var post := Vector3(0, 0, -18)
	var v := TreeFall.plough_restore_velocity(approach, post, 1.0, 20.0)
	assert_true(Vector3(v.x, 0, v.z).length() <= 20.0 + 1e-5, "horizontal speed capped at approach speed")


func test_plough_restore_preserves_vertical_component() -> void:
	# The restore is horizontal-only; vertical (gravity/suspension) is left to physics.
	var v := TreeFall.plough_restore_velocity(Vector3(0, -5, -20), Vector3(0, -5, 0), 0.5, 20.0)
	assert_almost_eq(v.y, -5.0, 1e-6, "vertical velocity untouched")


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
