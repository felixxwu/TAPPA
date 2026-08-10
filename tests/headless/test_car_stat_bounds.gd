extends GutTest
# CarStatBounds — the roster-wide min/max behind the Simple page's stat bars, and the
# StatBar widget that draws against them. See todo/simplified-upgrade-menu.md §3a.
#
# The values themselves are catalogue-dependent and deliberately NOT asserted; what is
# tested is the CONTRACT: the range brackets every car, the fraction maps into 0..1, a
# degenerate range doesn't divide by zero, and the cache follows the catalogue seams.


func before_each() -> void:
	CarFixtures.install()
	UpgradeFixtures.install()


func after_each() -> void:
	UpgradeFixtures.restore()
	CarFixtures.restore()


func test_bounds_bracket_every_car_on_the_roster() -> void:
	var bounds := CarStatBounds.all()
	assert_true(bounds.has("pw") and bounds.has("grip") and bounds.has("mass"),
		"every comparable stat has a range")
	for entry in CarLibrary.all():
		var meta := UpgradeLibrary.effective_meta({}, entry)
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
	UpgradeLibrary.override_for_test([] as Array[Dictionary])
	var frac := CarStatBounds.fraction("pw", CarLibrary.power_to_weight_hp_tonne(
		UpgradeLibrary.effective_meta({}, single[0])))
	assert_true(is_finite(frac), "the fraction is a real number")
	assert_between(frac, 0.0, 1.0, "and still inside the unit range")


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

func _lit_blocks(bar: StatBar) -> int:
	# Count the blocks painted at full alpha — what the player reads off the bar.
	var n := 0
	for child in bar.get_children():
		if not (child is HBoxContainer):
			continue
		for block in child.get_children():
			if block is ColorRect and (block as ColorRect).color.a >= 0.99:
				n += 1
	return n


func _colours(bar: StatBar) -> Dictionary:
	var counts := {}
	for child in bar.get_children():
		if not (child is HBoxContainer):
			continue
		for block in child.get_children():
			if block is ColorRect:
				var c: Color = (block as ColorRect).color
				var key := "gold" if c.is_equal_approx(UITheme.GOLD) else (
					"green" if c.is_equal_approx(UITheme.GREEN) else (
					"red" if c.is_equal_approx(UITheme.RED) else "empty"))
				counts[key] = int(counts.get(key, 0)) + 1
	return counts


func test_upgrades_above_stock_are_painted_gold() -> void:
	# The colour split is the whole point: green is the car as it shipped, gold is what the
	# player's stars bought on top. A bar with no stock baseline stays entirely green.
	var upgraded := StatBar.build("Speed", 0.8, "fast", 0.4)
	autofree(upgraded)
	var counts := _colours(upgraded)
	assert_gt(int(counts.get("green", 0)), 0, "the stock part of the run is green")
	assert_gt(int(counts.get("gold", 0)), 0, "and what upgrades added is gold")

	var plain := StatBar.build("Speed", 0.8, "fast")
	autofree(plain)
	assert_eq(int(_colours(plain).get("gold", 0)), 0,
		"a row with no stock baseline has nothing to attribute to upgrades")


func test_a_car_below_its_stock_reading_shows_no_gold() -> void:
	# Detuned or ballasted, the player has given performance away rather than gained it —
	# painting that gold would credit them for a downgrade.
	var detuned := StatBar.build("Speed", 0.3, "slow", 0.7)
	autofree(detuned)
	assert_eq(int(_colours(detuned).get("gold", 0)), 0, "nothing is credited as a gain")
	assert_gt(int(_colours(detuned).get("green", 0)), 0, "the run is all stock-coloured")


func test_stat_bar_lights_blocks_in_proportion() -> void:
	var empty := StatBar.build("Speed", 0.0, "0")
	var half := StatBar.build("Speed", 0.5, "half")
	var full := StatBar.build("Speed", 1.0, "full")
	autofree(empty)
	autofree(half)
	autofree(full)
	assert_eq(_lit_blocks(empty), 0, "a zero stat lights nothing")
	assert_eq(_lit_blocks(full), StatBar.SEGMENTS, "a maxed stat fills the bar")
	assert_between(_lit_blocks(half), 1, StatBar.SEGMENTS - 1, "half sits in between")


func test_a_small_but_nonzero_stat_still_lights_one_block() -> void:
	# An entirely empty bar reads as broken rather than as slow.
	var bar := StatBar.build("Speed", 0.001, "tiny")
	autofree(bar)
	assert_eq(_lit_blocks(bar), 1, "any real value lights at least one block")


func test_the_over_limit_red_outranks_the_upgrade_colour() -> void:
	# Which side of a class limit the car sits on matters more than where its power came
	# from, so red wins over gold on the blocks past the cap.
	var bar := StatBar.build("Speed", 1.0, "over", 0.2, 0.5)
	autofree(bar)
	var counts := _colours(bar)
	assert_gt(int(counts.get("red", 0)), 0, "blocks past the cap are red")
	# Gold survives only between the stock reading and the cap; everything past the cap is
	# red. Derived from SEGMENTS rather than hardcoded so the bar can be re-lengthened.
	var base := ceili(0.2 * StatBar.SEGMENTS)
	var cap := ceili(0.5 * StatBar.SEGMENTS)
	assert_eq(int(counts.get("gold", 0)), cap - base,
		"only the blocks between stock and the cap stay gold")
	assert_eq(int(counts.get("red", 0)), StatBar.SEGMENTS - cap,
		"and every block past the cap is red")


func test_blocks_past_a_limit_are_painted_red() -> void:
	var bar := StatBar.build("Speed", 1.0, "over", -1.0, 0.5)
	autofree(bar)
	var reds := 0
	for child in bar.get_children():
		if not (child is HBoxContainer):
			continue
		for block in child.get_children():
			if block is ColorRect and (block as ColorRect).color.is_equal_approx(UITheme.RED):
				reds += 1
	assert_gt(reds, 0, "a build over the cap shows red blocks past the line")


func test_blocks_have_an_intrinsic_width() -> void:
	# Regression: the blocks used to rely on their expand flag alone. The pages hosting a
	# bar shrink-wrap to content, so a zero minimum width contributed nothing to the row's
	# minimum and the entire bar rendered invisible next to its labels.
	var bar := StatBar.build("Speed", 0.5, "half")
	autofree(bar)
	var checked := 0
	for child in bar.get_children():
		if not (child is HBoxContainer):
			continue
		for block in child.get_children():
			if block is ColorRect:
				checked += 1
				assert_gt((block as ColorRect).custom_minimum_size.x, 0.0,
					"a block takes up width even when nothing expands it")
				assert_gt((block as ColorRect).custom_minimum_size.y, 0.0,
					"and has height")
	assert_eq(checked, StatBar.SEGMENTS, "every block was checked")
