extends GutTest
# RegionStagePool (scripts/region_stage_pool.gd) — the seeded per-slot draw a
# roguelike run takes out of RegionStageLibrary (todo/region-stage-slots-redesign.md,
# superseding todo/roguelike-pivot.md → "Stage draw"). Pure logic, no scene, no Save.
#
# Runs against a SYNTHETIC region layout throughout: the shipped STAGES table is
# content and is always subject to change, so nothing here may depend on a
# particular authored candidate or a particular region's slot count (CLAUDE.md's
# testing rules). What IS asserted is the draw's CONTRACT — it is deterministic in
# the run seed, it draws only real authored candidates, it draws exactly one per
# slot in slot order, it stamps region/slot/candidate, and it never mutates the
# catalogue.

const REGION := "fx_pool_region"


func before_each() -> void:
	RegionStageLibrary.override_for_test(_regions())


func after_each() -> void:
	RegionStageLibrary.reset()


# A synthetic region of 8 slots x 3 candidates — the real shape — plus a second
# region, which must never leak into the first's draw.
func _regions() -> Dictionary:
	return {
		REGION: _slots(100),
		"fx_other_region": _slots(900),
	}


func _slots(seed_base: int) -> Array:
	var slots: Array = []
	for slot_index in 8:
		var candidates: Array = []
		for c in 3:
			var seed_value := seed_base + slot_index * 10 + c
			candidates.append({
				"seed": seed_value, "turn_count": 8, "forestiness": 0.4, "surface_mix": 0.5,
				"straightness": 0.6, "cliffiness": 0.3, "water_level": -50.0,
				"terrain_layer1_amplitude": 12.0,
			})
		slots.append(candidates)
	return slots


func _seeds_of(stages: Array) -> Array:
	var out: Array = []
	for s in stages:
		out.append(int(s.get("seed", 0)))
	return out


func _all_seeds_in(region_id: String) -> Array:
	var out: Array = []
	for slot in RegionStageLibrary.slots_in(region_id):
		for c in slot:
			out.append(int((c as Dictionary).get("seed", 0)))
	return out


# --- The draw --------------------------------------------------------------------

func test_the_draw_returns_one_stage_per_requested_slot() -> void:
	assert_eq(RegionStagePool.draw(REGION, 8, 7777).size(), 8)
	assert_eq(RegionStagePool.draw(REGION, 3, 7777).size(), 3,
		"a shorter run only draws its first N slots")
	assert_eq(RegionStagePool.draw(REGION, 0, 7777), [],
		"a zero-stage run draws nothing rather than erroring")


func test_the_draw_is_deterministic_in_its_seed() -> void:
	# The run seed is persisted, so a RESUMED run re-derives its stage list from
	# nothing else. If the draw were not stable in the seed a paused run would come
	# back as a different run.
	var a := RegionStagePool.draw(REGION, 8, 4242)
	var b := RegionStagePool.draw(REGION, 8, 4242)
	assert_eq(_seeds_of(a), _seeds_of(b), "the same run seed draws the same stages")


func test_every_drawn_stage_is_a_real_authored_candidate() -> void:
	var pool_seeds := _all_seeds_in(REGION)
	for stage in RegionStagePool.draw(REGION, 8, 31337):
		assert_true(pool_seeds.has(int(stage["seed"])),
			"a drawn stage is authored content, never a fabricated one")


func test_every_drawn_stage_carries_its_region_slot_and_candidate() -> void:
	# The region tag is load-bearing, not decoration: StageConfig.apply_event_config
	# resolves the waterline and the per-region grip/deep-snow overrides off it, so a
	# stage that lost it would generate as the wrong corner of the world.
	var drawn := RegionStagePool.draw(REGION, 8, 2024)
	for slot_index in drawn.size():
		var stage: Dictionary = drawn[slot_index]
		assert_eq(String(stage["region"]), REGION, "the stage knows its region")
		assert_eq(int(stage["slot"]), slot_index, "the stage knows its slot position")
		assert_true(int(stage["candidate"]) >= 0 and int(stage["candidate"]) < 3,
			"the stage knows which of the slot's 3 candidates was drawn")


func test_the_draw_visits_slots_in_order() -> void:
	# Each drawn stage's slot index must equal its position in the returned array —
	# the array order IS the escalation now, so nothing may reorder it.
	var drawn := RegionStagePool.draw(REGION, 8, 3131)
	for i in drawn.size():
		assert_eq(int(drawn[i]["slot"]), i, "slot %d landed at array position %d" % [int(drawn[i]["slot"]), i])


func test_drawing_never_mutates_the_catalogue() -> void:
	@warning_ignore("return_value_discarded")
	RegionStagePool.draw(REGION, 8, 55)
	for slot in RegionStageLibrary.slots_in(REGION):
		for c in slot:
			assert_false((c as Dictionary).has("region"),
				"the draw's stamping lands on a COPY — the authored candidate is untouched")


func test_an_unknown_region_draws_nothing() -> void:
	assert_eq(RegionStagePool.draw("no_such_region", 8, 1234), [])


func test_a_different_run_seed_can_draw_different_candidates() -> void:
	# Determinism (same seed -> same draw) is covered above; this is its converse — a
	# draw that ignored the RNG and always took candidate 0 would still pass every
	# other test in this file, so the actual randomness needs its own assertion.
	var seen_seed_sets := {}
	for run_seed in range(20):
		seen_seed_sets[str(_seeds_of(RegionStagePool.draw(REGION, 8, run_seed)))] = true
	assert_gt(seen_seed_sets.size(), 1,
		"20 different run seeds should not all draw the identical set of candidates")


# The shipped roster's own structural contract (enough slots per region, no shared
# seeds) is covered in tests/headless/test_region_stage_library.gd — no need to
# duplicate it here; this file's subject is the DRAW, not the catalogue.
