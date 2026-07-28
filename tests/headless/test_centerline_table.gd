extends GutTest
# The resampled centerline point table (TrackProgress.baked_points / point_on) that
# replaced the per-tick Curve2D.sample_baked storm in TrackProgress + TireMarks.
# The contract: a table lookup must agree with sample_baked, and must INTERPOLATE
# (not quantise to the table's cell size), because progress, split timing and
# tyre-mark placement all read positions off it.


# A smoothly wiggling synthetic curve — built here, never a catalogue track. Control
# points make it a real bezier (a road-like curve), not a polyline of hard corners.
func _wiggly_curve() -> Curve2D:
	var c := Curve2D.new()
	for i in 24:
		var t := float(i) * 0.7
		var p := Vector2(sin(t) * 30.0, float(i) * 40.0)
		var tangent := Vector2(cos(t) * 30.0 * 0.7, 40.0) * 0.35
		c.add_point(p, -tangent, tangent)
	return c


# A polyline of hard corners — the worst case for any resampled table, since the
# corner sits between two samples.
func _sharp_corner_curve() -> Curve2D:
	var c := Curve2D.new()
	c.add_point(Vector2(0, 0))
	c.add_point(Vector2(0, 40))
	c.add_point(Vector2(40, 40))
	c.add_point(Vector2(40, 0))
	return c


func _straight_curve() -> Curve2D:
	var c := Curve2D.new()
	c.add_point(Vector2(0, 0))
	c.add_point(Vector2(0, 100))
	return c


func test_table_lookup_agrees_with_sample_baked_along_the_whole_curve() -> void:
	var curve := _wiggly_curve()
	var length := curve.get_baked_length()
	var pts := TrackProgress.baked_points(curve)
	assert_gt(pts.size(), 1, "the table has points")
	var worst := 0.0
	var o := 0.0
	while o <= length:
		var d := TrackProgress.point_on(pts, length, o).distance_to(curve.sample_baked(o))
		worst = maxf(worst, d)
		o += 0.37  # deliberately not a multiple of the table spacing
	assert_lt(worst, 0.05, "table lookup tracks sample_baked to within 5 cm (worst %f)" % worst)


func test_lookup_stays_close_even_on_a_hard_cornered_curve() -> void:
	# The worst case: a corner between two table samples gets chorded off. The error
	# must still be small next to the metre-scale gates the lookup feeds (the road
	# half-width, the off-track leash, the nearest-point scan's own resolution).
	var curve := _sharp_corner_curve()
	var length := curve.get_baked_length()
	var pts := TrackProgress.baked_points(curve)
	var worst := 0.0
	var o := 0.0
	while o <= length:
		worst = maxf(worst, TrackProgress.point_on(pts, length, o).distance_to(curve.sample_baked(o)))
		o += 0.37
	assert_lt(worst, 0.25, "even a hard corner is chorded by well under a metre (worst %f)" % worst)


func test_lookup_interpolates_rather_than_snapping_to_the_table() -> void:
	# On a straight run the exact answer is linear in the offset. A truncating lookup
	# would return the same point for a whole cell; an interpolating one moves smoothly.
	var curve := _straight_curve()
	var length := curve.get_baked_length()
	var pts := TrackProgress.baked_points(curve)
	var a := TrackProgress.point_on(pts, length, 40.1)
	var b := TrackProgress.point_on(pts, length, 40.6)
	assert_gt(absf(a.y - b.y), 0.1, "two offsets inside one cell give different points")
	assert_almost_eq(TrackProgress.point_on(pts, length, 40.25).y, 40.25, 0.01,
		"a mid-cell offset lands at the true arc position, not the cell corner")


func test_endpoints_and_out_of_range_offsets_clamp_to_the_curve() -> void:
	var curve := _wiggly_curve()
	var length := curve.get_baked_length()
	var pts := TrackProgress.baked_points(curve)
	assert_almost_eq(TrackProgress.point_on(pts, length, 0.0),
		curve.sample_baked(0.0), Vector2(0.02, 0.02), "offset 0 is the curve start")
	assert_almost_eq(TrackProgress.point_on(pts, length, length),
		curve.sample_baked(length), Vector2(0.02, 0.02), "the far edge is the curve end")
	assert_eq(TrackProgress.point_on(pts, length, length + 500.0),
		TrackProgress.point_on(pts, length, length), "past the end clamps to the end")
	assert_eq(TrackProgress.point_on(pts, length, -500.0),
		TrackProgress.point_on(pts, length, 0.0), "before the start clamps to the start")


func test_repeated_and_interleaved_requests_return_equivalent_tables() -> void:
	# TrackProgress owns the table and TireMarks consumes the same one, via a cache
	# keyed on the curve — so asking twice (and asking about another curve in between)
	# must never hand back a table belonging to the wrong curve.
	var curve := _wiggly_curve()
	var a := TrackProgress.baked_points(curve)
	assert_eq(TrackProgress.baked_points(curve), a, "the same curve yields the same table")
	var other := _straight_curve()
	var s := TrackProgress.baked_points(other)
	assert_almost_eq(TrackProgress.point_on(s, other.get_baked_length(), 50.0),
		other.sample_baked(50.0), Vector2(0.02, 0.02), "the second curve gets its own table")
	assert_eq(TrackProgress.baked_points(curve), a, "asking again re-derives the first table")


func test_degenerate_curve_does_not_crash() -> void:
	var c := Curve2D.new()
	c.add_point(Vector2(5, 5))
	var pts := TrackProgress.baked_points(c)
	assert_gt(pts.size(), 0, "a single-point curve still yields a usable table")
	assert_almost_eq(TrackProgress.point_on(pts, c.get_baked_length(), 10.0),
		Vector2(5, 5), Vector2(0.01, 0.01), "every offset resolves to the only point")
	assert_eq(TrackProgress.baked_points(null), PackedVector2Array(),
		"a null curve yields an empty table")
	assert_eq(TrackProgress.point_on(PackedVector2Array(), 0.0, 3.0), Vector2.ZERO,
		"an empty table resolves to the origin instead of crashing")
