extends GutTest
# RegionStagePool (scripts/region_stage_pool.gd) — the region's authored event pool
# and the seeded 8-stage draw a roguelike run takes out of it
# (todo/roguelike-pivot.md → "Stage draw"). Pure logic, no scene, no Save.
#
# Runs against a SYNTHETIC rally catalogue throughout: the shipped RALLIES table is
# content and is always subject to change, so nothing here may depend on a
# particular authored rally, a particular event count, or a particular region's
# pool size (CLAUDE.md's testing rules). What IS asserted is the pool's CONTRACT —
# it flattens, it annotates, the draw is deterministic, it draws only real pool
# members, it never repeats while the pool lasts, and it comes back easiest-first.

const REGION := "fx_pool_region"
const OTHER_REGION := "fx_other_region"


func before_each() -> void:
	RallyLibrary.override_for_test(_rallies())


func after_each() -> void:
	RallyLibrary.reset()


# A synthetic region of 4 rallies / 10 events, spanning three difficulty tiers and
# including a ONE-event rally — the pool must be counted, never assumed to be
# 3 x rallies (`shakedown` and friends carry one event apiece in the real table).
# Plus one rally in a DIFFERENT region, which must never appear in this pool.
func _rallies() -> Array[Dictionary]:
	var out: Array[Dictionary] = [
		_rally("fx_a", REGION, 1, [101, 102, 103]),
		_rally("fx_b", REGION, 3, [201, 202, 203]),
		_rally("fx_c", REGION, 2, [301, 302, 303]),
		_rally("fx_d", REGION, 2, [401]),
		_rally("fx_elsewhere", OTHER_REGION, 1, [901, 902, 903]),
	]
	return out


func _rally(id: String, region: String, difficulty: int, seeds: Array) -> Dictionary:
	var events: Array = []
	for s in seeds:
		events.append({
			"seed": int(s), "turn_count": 8, "forestiness": 0.4, "surface_mix": 0.5,
			"straightness": 0.6, "cliffiness": 0.3, "water_level": -50.0,
			"terrain_layer1_amplitude": 12.0,
		})
	return {
		"id": id, "name": id, "region": region, "difficulty": difficulty,
		"special": false, "restriction": {}, "map_pos": Vector2(0.5, 0.5),
		"events": events,
	}


func _seeds_of(stages: Array) -> Array:
	var out: Array = []
	for s in stages:
		out.append(int(s.get("seed", 0)))
	return out


# --- The pool ------------------------------------------------------------------

func test_the_pool_is_every_event_of_every_rally_tagged_with_the_region() -> void:
	var pool := RegionStagePool.events_in(REGION)
	var expected := 0
	for rally in RallyLibrary.all():
		if String(rally["region"]) == REGION:
			expected += (rally["events"] as Array).size()
	assert_eq(pool.size(), expected,
		"the pool is COUNTED from the events arrays, never rallies x 3")
	assert_eq(RegionStagePool.pool_size(REGION), expected, "pool_size agrees with events_in")


func test_the_pool_excludes_every_other_regions_events() -> void:
	var seeds := _seeds_of(RegionStagePool.events_in(REGION))
	for s in _seeds_of(RegionStagePool.events_in(OTHER_REGION)):
		assert_false(seeds.has(s), "an event tagged to another region is not in this pool")


func test_every_pooled_stage_carries_its_region_and_its_parents_difficulty() -> void:
	# The region tag is load-bearing, not decoration: StageConfig.apply_event_config
	# resolves the waterline and the per-region grip/deep-snow overrides off it, so a
	# stage that lost it would generate as the wrong corner of the world.
	for stage in RegionStagePool.events_in(REGION):
		assert_eq(String(stage["region"]), REGION, "the stage knows its region")
		assert_true(stage.has("rally_id"), "and which rally it came from")
		var parent := RallyLibrary.by_id(String(stage["rally_id"]))
		assert_eq(int(stage["difficulty"]), int(parent["difficulty"]),
			"and carries its parent rally's authored difficulty")


func test_pooling_never_mutates_the_catalogue() -> void:
	@warning_ignore("return_value_discarded")
	RegionStagePool.events_in(REGION)
	for rally in RallyLibrary.all():
		for event in (rally["events"] as Array):
			assert_false((event as Dictionary).has("difficulty"),
				"the pool's annotations land on a COPY — the authored event is untouched")


func test_an_unknown_region_has_an_empty_pool_and_draws_nothing() -> void:
	assert_eq(RegionStagePool.events_in("no_such_region"), [])
	assert_eq(RegionStagePool.draw("no_such_region", 8, 1234), [])


# --- The draw ------------------------------------------------------------------

func test_the_draw_returns_exactly_the_requested_number_of_stages() -> void:
	assert_eq(RegionStagePool.draw(REGION, 8, 7777).size(), 8)
	assert_eq(RegionStagePool.draw(REGION, 3, 7777).size(), 3)
	assert_eq(RegionStagePool.draw(REGION, 0, 7777), [],
		"a zero-stage run draws nothing rather than erroring")


func test_the_draw_is_deterministic_in_its_seed() -> void:
	# The run seed is persisted, so a RESUMED run re-derives its stage list from
	# nothing else. If the draw were not stable in the seed a paused run would come
	# back as a different run.
	var a := RegionStagePool.draw(REGION, 8, 4242)
	var b := RegionStagePool.draw(REGION, 8, 4242)
	assert_eq(_seeds_of(a), _seeds_of(b), "the same run seed draws the same stages")


func test_every_drawn_stage_is_a_real_pooled_event() -> void:
	var pool_seeds := _seeds_of(RegionStagePool.events_in(REGION))
	for stage in RegionStagePool.draw(REGION, 8, 31337):
		assert_true(pool_seeds.has(int(stage["seed"])),
			"a drawn stage is authored content, never a fabricated one")
		assert_eq(String(stage["region"]), REGION, "and keeps its region tag through the draw")


func test_the_draw_never_repeats_a_stage_while_the_pool_lasts() -> void:
	var seeds := _seeds_of(RegionStagePool.draw(REGION, 8, 555))
	var seen := {}
	for s in seeds:
		assert_false(seen.has(s), "no stage is drawn twice when the pool can cover the run")
		seen[s] = true


func test_a_pool_smaller_than_the_run_refills_rather_than_returning_a_short_run() -> void:
	# `greece_coast` ships 3 events against an 8-stage run until stage 4's authoring
	# pass. A repeated stage is a thin region; a 3-stage "8-stage run" is a broken one.
	var tiny: Array[Dictionary] = [_rally("fx_tiny", "fx_tiny_region", 1, [1, 2])]
	RallyLibrary.override_for_test(tiny)
	var drawn := RegionStagePool.draw("fx_tiny_region", 8, 99)
	assert_eq(drawn.size(), 8, "the run is still full length")
	for stage in drawn:
		assert_true([1, 2].has(int(stage["seed"])), "…filled only from the region's own pool")


func test_the_drawn_run_escalates_by_the_parent_rallys_difficulty() -> void:
	# Ordering, not values: whatever the authored tiers are, the run must never get
	# EASIER as it goes, so the last stage is the hardest of the drawn set.
	var previous := -1
	for stage in RegionStagePool.draw(REGION, 8, 8080):
		var d := int(stage["difficulty"])
		assert_true(d >= previous, "stage difficulty never drops as the run progresses")
		previous = d
