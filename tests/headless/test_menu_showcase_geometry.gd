extends GutTest
# Pure-logic coverage for MenuShowcase's segment-slicing and border-safety maths —
# no terrain, no track generation, so this stays fast regardless of TURN_COUNT.
# See test_menu_showcase.gd for the full-build integration coverage.


func test_segment_bounds_splits_evenly_and_covers_the_whole_length() -> void:
	var bounds := MenuShowcase.segment_bounds(600.0, 6)
	assert_eq(bounds.size(), 7, "N segments need N+1 boundaries")
	assert_almost_eq(bounds[0], 0.0, 0.001)
	assert_almost_eq(bounds[6], 600.0, 0.001)
	for i in 6:
		assert_almost_eq(bounds[i + 1] - bounds[i], 100.0, 0.001, "segment %d is even" % i)


func test_safe_shot_arcs_stays_clear_of_both_boundaries() -> void:
	var arcs := MenuShowcase.safe_shot_arcs(0.0, 100.0, 20.0, 10.0, 2)
	assert_eq(arcs.size(), 2)
	for s in arcs:
		assert_gte(s, 20.0, "never closer than the margin to the low boundary")
		# The shot's OWN position must clear the margin from the high boundary too,
		# and its look-ahead point (s + ahead) must also stay inside the safe zone.
		assert_lte(s + 10.0, 100.0 - 20.0, "look-ahead point stays clear of the high boundary")


func test_safe_shot_arcs_is_empty_when_the_segment_is_too_short() -> void:
	# margin*2 + ahead (20+20+10=50) exceeds the segment length (40) -> no safe shots.
	var arcs := MenuShowcase.safe_shot_arcs(0.0, 40.0, 20.0, 10.0, 2)
	assert_eq(arcs.size(), 0, "a too-short segment gets no shots rather than an unsafe one")


func test_safe_shot_arcs_single_count_uses_the_midpoint_of_the_safe_range() -> void:
	var arcs := MenuShowcase.safe_shot_arcs(0.0, 100.0, 10.0, 0.0, 1)
	assert_eq(arcs.size(), 1)
	assert_almost_eq(arcs[0], 50.0, 0.001)


# Mirrors test_rally_library.gd::test_sandstorm_only_authored_on_greece_events'
# shape for the showcase's own per-region weather-eligibility table (decision 3,
# todo/menu-background-showcase.md): every region maps to a non-empty set of REAL
# WeatherLibrary ids, and the two "no nonsense combinations" exclusions the user
# asked for explicitly hold.
func test_every_region_has_a_non_empty_eligible_weather_set() -> void:
	for region in RegionLibrary.ordered():
		var eligible: Array = MenuShowcase.eligible_weather_ids(String(region["id"]))
		assert_gt(eligible.size(), 0, "region %s has at least one eligible condition" % region["id"])


func test_every_eligible_weather_id_is_a_real_weather_library_entry() -> void:
	var known := {}
	for entry in WeatherLibrary.all():
		known[String(entry["id"])] = true
	for region in RegionLibrary.ordered():
		for id in MenuShowcase.eligible_weather_ids(String(region["id"])):
			assert_true(known.has(id), "%s is a real WeatherLibrary id" % id)


func test_sandstorm_is_eligible_only_in_the_desert_regions() -> void:
	for region in RegionLibrary.ordered():
		var region_id := String(region["id"])
		var eligible: Array = MenuShowcase.eligible_weather_ids(region_id)
		var is_desert := region_id in ["greece", "greece_coast"]
		assert_eq(eligible.has("sandstorm"), is_desert,
			"sandstorm eligible iff %s is a desert region" % region_id)


func test_snow_is_eligible_only_in_the_snow_region() -> void:
	for region in RegionLibrary.ordered():
		var region_id := String(region["id"])
		var eligible: Array = MenuShowcase.eligible_weather_ids(region_id)
		assert_eq(eligible.has("snow"), region_id == "snow",
			"snow eligible iff %s is the snow region" % region_id)


func test_rain_is_never_eligible_in_the_desert_or_snow_regions() -> void:
	for region_id in ["greece", "greece_coast", "snow"]:
		var eligible: Array = MenuShowcase.eligible_weather_ids(region_id)
		assert_false(eligible.has("rain"), "%s never rolls rain" % region_id)
