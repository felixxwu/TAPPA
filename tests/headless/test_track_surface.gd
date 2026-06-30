extends GutTest
# TrackSurface: the pure gravel/tarmac split along a track — a single feathered
# switch, oriented deterministically from the seed, with the tarmac run covering
# the configured fraction. See features/track.md.


const TOTAL := 100.0
const FEATHER := 6.0


func test_full_one_surface_has_no_switch() -> void:
	# 0% / 100% tarmac is a flat constant everywhere, regardless of orientation.
	for first in [true, false]:
		for d in [0.0, 25.0, 50.0, 99.9, TOTAL]:
			assert_eq(TrackSurface.tarmac_weight(d, TOTAL, 0.0, first, FEATHER), 0.0,
				"all-gravel is 0 at d=%.1f (first=%s)" % [d, first])
			assert_eq(TrackSurface.tarmac_weight(d, TOTAL, 1.0, first, FEATHER), 1.0,
				"all-tarmac is 1 at d=%.1f (first=%s)" % [d, first])


func test_gravel_first_opens_gravel_then_tarmac() -> void:
	# 30% tarmac, gravel first: gravel for the first 70 m, tarmac after.
	var f := 0.3
	assert_eq(TrackSurface.tarmac_weight(0.0, TOTAL, f, false, FEATHER), 0.0, "opens on gravel")
	assert_eq(TrackSurface.tarmac_weight(60.0, TOTAL, f, false, FEATHER), 0.0, "still gravel before switch band")
	# Switch sits at (1-0.3)*100 = 70 m. Midpoint of the band -> 0.5.
	assert_almost_eq(TrackSurface.tarmac_weight(70.0, TOTAL, f, false, FEATHER), 0.5, 1e-4, "half tarmac at the switch")
	assert_eq(TrackSurface.tarmac_weight(85.0, TOTAL, f, false, FEATHER), 1.0, "full tarmac after the band")
	assert_eq(TrackSurface.tarmac_weight(TOTAL, TOTAL, f, false, FEATHER), 1.0, "ends on tarmac")


func test_tarmac_first_opens_tarmac_then_gravel() -> void:
	# 70% tarmac, tarmac first: tarmac for the first 70 m, gravel after. Same gravel
	# (30%) / tarmac (70%) split as the mirror case, just the opposite order.
	var f := 0.7
	assert_eq(TrackSurface.tarmac_weight(0.0, TOTAL, f, true, FEATHER), 1.0, "opens on tarmac")
	assert_almost_eq(TrackSurface.tarmac_weight(70.0, TOTAL, f, true, FEATHER), 0.5, 1e-4, "half at the switch (70 m)")
	assert_eq(TrackSurface.tarmac_weight(90.0, TOTAL, f, true, FEATHER), 0.0, "gravel after the band")


func test_weight_is_monotonic_across_the_band() -> void:
	# Across the feather band the weight changes monotonically and only ONCE: no
	# second switch back. Gravel-first 50/50 -> rises 0..1 across 50 m, flat either side.
	var prev := -1.0
	var d := 0.0
	while d <= TOTAL:
		var w := TrackSurface.tarmac_weight(d, TOTAL, 0.5, false, FEATHER)
		assert_true(w >= prev - 1e-6, "non-decreasing at d=%.1f (%.3f vs %.3f)" % [d, w, prev])
		assert_between(w, 0.0, 1.0, "weight in [0,1] at d=%.1f" % d)
		prev = w
		d += 1.0


func test_orientation_is_deterministic_and_varies() -> void:
	# Same seed -> same orientation; across seeds BOTH orientations appear.
	assert_eq(TrackSurface.orientation_tarmac_first(1234), TrackSurface.orientation_tarmac_first(1234),
		"orientation is deterministic for a seed")
	var saw_true := false
	var saw_false := false
	for s in range(2000, 2050):
		if TrackSurface.orientation_tarmac_first(s):
			saw_true = true
		else:
			saw_false = true
	assert_true(saw_true and saw_false, "both orientations occur across seeds")
