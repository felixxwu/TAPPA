extends GutTest
# RegionStageLibrary (scripts/region_stage_library.gd) — the authored stage catalogue
# (todo/region-stage-slots-redesign.md). STRUCTURAL invariants only, per CLAUDE.md:
# never assert a specific seed, straightness, amplitude or authored ordering — a
# designer retuning any candidate's fields must never break this file.

func after_each() -> void:
	RegionStageLibrary.reset()


func test_every_region_has_exactly_eight_slots() -> void:
	for region_id in RegionStageLibrary.region_ids():
		var slots := RegionStageLibrary.slots_in(String(region_id))
		assert_eq(slots.size(), RegionRunMode.STAGE_COUNT,
			"region '%s' has %d slots, expected %d (RegionRunMode.STAGE_COUNT)" % [
				region_id, slots.size(), RegionRunMode.STAGE_COUNT])


func test_every_slot_has_exactly_three_candidates() -> void:
	for region_id in RegionStageLibrary.region_ids():
		var slots := RegionStageLibrary.slots_in(String(region_id))
		for slot_index in slots.size():
			var candidates: Array = slots[slot_index]
			assert_eq(candidates.size(), 3,
				"region '%s' slot %d has %d candidates, expected 3" % [
					region_id, slot_index, candidates.size()])


func test_every_candidate_has_a_seed_and_turn_count() -> void:
	for stage in RegionStageLibrary.all_stages():
		assert_true(stage.has("seed"), "every candidate authors a seed")
		assert_true(stage.has("turn_count"), "every candidate authors a turn_count")
		assert_gt(int(stage.get("turn_count", 0)), 0, "turn_count is positive")


func test_every_candidate_has_required_shape_fields() -> void:
	for stage in RegionStageLibrary.all_stages():
		assert_true(stage.has("straightness"), "every candidate authors straightness")
		assert_true(stage.has("terrain_layer1_amplitude"),
			"every candidate authors terrain_layer1_amplitude")


func test_seeds_are_unique_across_the_whole_catalogue() -> void:
	var seen := {}
	for stage in RegionStageLibrary.all_stages():
		var seed_value := int(stage.get("seed", 0))
		assert_false(seen.has(seed_value),
			"seed %d is authored more than once" % seed_value)
		seen[seed_value] = true


func test_all_stages_in_stamps_region_slot_and_candidate() -> void:
	for region_id in RegionStageLibrary.region_ids():
		var stages := RegionStageLibrary.all_stages_in(String(region_id))
		assert_eq(stages.size(), RegionRunMode.STAGE_COUNT * 3,
			"region '%s' yields slots x candidates stamped stages" % region_id)
		for stage in stages:
			assert_eq(String(stage["region"]), String(region_id))
			assert_true(int(stage["slot"]) >= 0 and int(stage["slot"]) < RegionRunMode.STAGE_COUNT)
			assert_true(int(stage["candidate"]) >= 0 and int(stage["candidate"]) < 3)


func test_all_stages_covers_every_region() -> void:
	var region_ids := RegionStageLibrary.region_ids()
	assert_gt(region_ids.size(), 0, "the catalogue authors at least one region")
	var seen_regions := {}
	for stage in RegionStageLibrary.all_stages():
		seen_regions[String(stage["region"])] = true
	for region_id in region_ids:
		assert_true(seen_regions.has(String(region_id)),
			"region '%s' contributes no stages to all_stages()" % region_id)


func test_an_unknown_region_has_no_slots() -> void:
	assert_eq(RegionStageLibrary.slots_in("no_such_region"), [])
	assert_eq(RegionStageLibrary.all_stages_in("no_such_region"), [])


# --- Catalogue seam ----------------------------------------------------------------

func test_override_for_test_replaces_the_table() -> void:
	RegionStageLibrary.override_for_test({"fx_region": [[{"seed": 1, "turn_count": 1}]]})
	assert_eq(RegionStageLibrary.region_ids(), ["fx_region"])
	assert_eq(RegionStageLibrary.slots_in("fx_region").size(), 1)


func test_reset_restores_the_shipped_table() -> void:
	var real_regions := RegionStageLibrary.region_ids()
	RegionStageLibrary.override_for_test({"fx_region": [[{"seed": 1, "turn_count": 1}]]})
	RegionStageLibrary.reset()
	assert_eq(RegionStageLibrary.region_ids(), real_regions, "reset restores the shipped STAGES")
