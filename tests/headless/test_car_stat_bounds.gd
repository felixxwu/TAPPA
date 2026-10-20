extends GutTest
# CarStatBounds — the roster-wide min/max behind the Simple page's stat bars, and the
# StatBar widget that draws against them. See todo/simplified-upgrade-menu.md §3a.
#
# The values themselves are catalogue-dependent and deliberately NOT asserted; what is
# tested is the CONTRACT: the range brackets every car, the fraction maps into 0..1, a
# degenerate range doesn't divide by zero, and the cache follows the catalogue seams.


func before_each() -> void:
	CarFixtures.install()


func after_each() -> void:
	CarFixtures.restore()


func test_bounds_bracket_every_car_on_the_roster() -> void:
	var bounds := CarStatBounds.all()
	assert_true(bounds.has("rating") and bounds.has("pw") and bounds.has("grip")
		and bounds.has("mass"), "every comparable stat has a range")
	for entry in CarLibrary.all():
		var meta := UpgradeLibrary.effective_meta({}, entry)
		var rating := CarPerformance.rating(CarPerformance.merged_meta({}, entry))
		assert_between(float(rating), float(bounds["rating"][0]), float(bounds["rating"][1]),
			"%s's stock rating is inside the roster range" % entry.get("id", "?"))
		var pw := CarLibrary.power_to_weight_hp_tonne(meta)
		assert_between(pw, float(bounds["pw"][0]), float(bounds["pw"][1]),
			"%s's stock power-to-weight is inside the roster range" % entry.get("id", "?"))
		var mass := float(meta.get("mass", 0.0))
		assert_between(mass, float(bounds["mass"][0]), float(bounds["mass"][1]),
			"%s's stock mass is inside the roster range" % entry.get("id", "?"))


func test_the_scale_spans_the_stock_roster() -> void:
	# The top of the scale is the best car AS IT SHIPS, not that car fully upgraded —
	# stretching to the upgrade ceiling collapses every early car into one lit block.
	var bounds := CarStatBounds.all()
	var best := -INF
	var worst := INF
	for entry in CarLibrary.all():
		var pw := CarLibrary.power_to_weight_hp_tonne(UpgradeLibrary.effective_meta({}, entry))
		best = maxf(best, pw)
		worst = minf(worst, pw)
	assert_almost_eq(float(bounds["pw"][1]), best, 0.01, "the top is the best stock car")
	assert_true(float(bounds["pw"][0]) <= worst,
		"the bottom sits at or just below the worst stock car, so it still lights a block")
	assert_gt(CarStatBounds.fraction("pw", worst), 0.0,
		"the slowest car in the game is not drawn as an empty bar")


func test_fraction_maps_into_the_unit_range() -> void:
	var bounds := CarStatBounds.all()
	assert_almost_eq(CarStatBounds.fraction("pw", float(bounds["pw"][0])), 0.0, 0.0001,
		"the very bottom of the scale is an empty bar")
	assert_almost_eq(CarStatBounds.fraction("pw", float(bounds["pw"][1])), 1.0, 0.0001,
		"the ceiling is a full bar")
	assert_eq(CarStatBounds.fraction("pw", -99999.0), 0.0, "below the floor clamps to empty")
	assert_eq(CarStatBounds.fraction("pw", 99999.0), 1.0, "above the ceiling clamps to full")
	assert_eq(CarStatBounds.fraction("nonexistent_stat", 1.0), 0.0,
		"an unknown stat is empty, not an error")


func test_a_degenerate_range_does_not_divide_by_zero() -> void:
	# A one-car roster (or a synthetic one where every car is identical) leaves nothing to
	# compare against; "this is the whole range" is the only honest answer.
	var single: Array[Dictionary] = [CarLibrary.all()[0].duplicate(true)]
	CarLibrary.override_for_test(single)
	var frac := CarStatBounds.fraction("pw", CarLibrary.power_to_weight_hp_tonne(
		UpgradeLibrary.effective_meta({}, single[0])))
	assert_true(is_finite(frac), "the fraction is a real number")
	assert_between(frac, 0.0, 1.0, "and still inside the unit range")


func test_the_cache_follows_the_config_fingerprint() -> void:
	# The rating bound is a benchmark-lap solve whose geometry lives in GameConfig, so a
	# config edit must re-scale the bar — the rating cache already refreshes on exactly
	# this signal, and a bounds cache that didn't would draw fresh figures on a stale scale.
	var cfg: GameConfig = Config.data
	var before_len := cfg.benchmark_straight_m
	var before: Array = (CarStatBounds.all()["rating"] as Array).duplicate()
	cfg.benchmark_straight_m = before_len * 3.0
	var after: Array = CarStatBounds.all()["rating"] as Array
	cfg.benchmark_straight_m = before_len
	assert_false(is_equal_approx(float(after[1]), float(before[1])),
		"moving the benchmark geometry re-derives the rating scale")


func test_the_cache_follows_the_catalogue_seam() -> void:
	var before: Array = (CarStatBounds.all()["mass"] as Array).duplicate()
	var heavier: Array[Dictionary] = []
	for entry in CarLibrary.all():
		var copy := entry.duplicate(true)
		copy["mass"] = float(copy.get("mass", 1000.0)) * 4.0
		heavier.append(copy)
	CarLibrary.override_for_test(heavier)
	var after: Array = CarStatBounds.all()["mass"] as Array
	assert_true(float(after[1]) > float(before[1]),
		"swapping the roster re-derives the scale instead of serving a stale one")


# --- The widget ---------------------------------------------------------------
