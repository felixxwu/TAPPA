class_name RegionStagePool
extends RefCounted
# Docs: features/region-runs.md — update in the same change as this file.
# Tests: tests/headless/test_region_stage_pool.gd — extend in the same change.
#
# THE SEEDED DRAW a run takes out of a region's authored stage slots
# (todo/region-stage-slots-redesign.md, superseding todo/roguelike-pivot.md → "Stage
# draw"). A roguelike run is 8 stages, and RegionStageLibrary authors exactly 8 SLOTS
# per region, one per stage position, each holding 3 CANDIDATES. `draw` below picks
# ONE candidate per slot, uniformly at random off the run seed, in slot order — so
# the run's escalation is the AUTHORED slot order, not a runtime sort.
#
# WHY DRAWN CANDIDATES AND NOT FRESH PROCGEN. Every authored candidate's
# (seed, turn_count, straightness, terrain amplitude, ...) combination is hand-verified
# to route and is baked into the committed track lockfile (data/track_cache.json), so a
# drawn stage is a stage some human has actually driven. That is also why the draw
# NEVER touches a candidate's fields: nudging `turn_count` or re-rolling `water_level` /
# `terrain_layer1_amplitude` would miss the lockfile and hand the player a combination
# no shipped content has exercised (ChallengeLibrary.stages_for has to roll those two
# TOGETHER for precisely this reason).


# `stage_count` stages drawn from `region_id`, one candidate per slot in slot order.
# Deterministic in (region_id, stage_count, run_seed): the run seed is persisted, so a
# resumed run re-derives byte-identical stages (RegionRunMode.stages()), and a bug
# report carrying the seed is reproducible.
#
# No sort, no bag, no refill: every slot always has exactly 3 candidates (a structural
# invariant RegionStageLibrary's own tests enforce), so a draw can never come up short
# or repeat within a run. `stage_count` beyond the region's slot count (8) is simply
# not drawable — the region does not author further positions.
static func draw(region_id: String, stage_count: int, run_seed: int) -> Array:
	var slots := RegionStageLibrary.slots_in(region_id)
	var rng := RandomNumberGenerator.new()
	rng.seed = run_seed
	var out: Array = []
	for slot_index in range(mini(stage_count, slots.size())):
		var candidates: Array = slots[slot_index]
		if candidates.is_empty():
			push_error("RegionStagePool: region '%s' slot %d has no authored candidates — a malformed region, not a valid short run" % [region_id, slot_index])
			continue
		var candidate_index := rng.randi_range(0, candidates.size() - 1)
		out.append(_stamp(candidates[candidate_index], region_id, slot_index, candidate_index))
	return out


# Stamp a drawn candidate with its provenance. "region" is load-bearing:
# StageConfig.apply_event_config resolves the waterline and the per-region
# grip/deep-snow/frozen-water overrides off it, so a drawn stage MUST carry it or a
# snow stage generates as home. "slot" is the stage's authored difficulty position;
# "candidate" is which of the slot's 3 seeds was drawn — provenance for debugging a
# drawn run, in place of the old "rally_id".
static func _stamp(candidate: Dictionary, region_id: String, slot_index: int,
		candidate_index: int) -> Dictionary:
	var stage: Dictionary = candidate.duplicate(true)
	stage["region"] = region_id
	stage["slot"] = slot_index
	stage["candidate"] = candidate_index
	return stage
