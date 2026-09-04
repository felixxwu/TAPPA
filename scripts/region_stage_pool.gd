class_name RegionStagePool
extends RefCounted
# Docs: features/region-runs.md — update in the same change as this file.
# Tests: tests/headless/test_region_stage_pool.gd — extend in the same change.
#
# A REGION'S STAGE POOL, and the seeded draw a run takes out of it
# (todo/roguelike-pivot.md → "Stage draw"). A roguelike run is 8 stages, and a
# stage is ONE point-to-point event drawn from AUTHORED content rather than
# generated from scratch (decisions 3 and 7).
#
# The pool is `RallyLibrary.RALLIES` flattened: every rally tagged with this region
# contributes its `events` array. A rally is NOT a unit here — the 3-event rally
# wrapper is exactly what the pivot deletes — so the pool is COUNTED, never
# multiplied by 3: `shakedown`, `hm_timber_trophy` and `hm_forest_gt` carry one
# event apiece.
#
# WHY DRAWN EVENTS AND NOT FRESH PROCGEN. Every authored event's (seed, turn_count)
# pair is hand-verified to route and is baked into the committed track lockfile
# (`data/track_cache.json`), so a drawn stage is a stage some human has actually
# driven. That is also why the draw NEVER touches an event's fields: nudging
# `turn_count` or re-rolling `water_level` / `terrain_layer1_amplitude` would miss
# the lockfile and hand the player a combination no shipped content has exercised
# (ChallengeLibrary.stages_for has to roll those two TOGETHER for precisely this
# reason). Escalation across the 8 stages comes from ORDERING the drawn set by the
# parent rally's authored `difficulty`, and from the timer tightening with stage
# index — never from mutating the events.


# Every authored event in `region_id`, in rally order, as stage dicts. Each carries
# three annotations on top of the authored event's own fields:
#   * "region"     — StageConfig.apply_event_config resolves the waterline and the
#                    per-region grip/deep-snow/frozen-water overrides off this, so a
#                    drawn stage MUST carry it or a snow stage generates as home;
#   * "rally_id"   — provenance, for debugging a drawn run;
#   * "difficulty" — the parent rally's authored tier, which is what `draw` orders by.
# Extra keys are harmless: every reader (TrackGenParams.for_event,
# StageConfig.apply_event_config) reads named fields and ignores the rest.
static func events_in(region_id: String) -> Array:
	var out: Array = []
	for rally in RegionLibrary.rallies_in(region_id):
		var difficulty := int(rally.get("difficulty", 0))
		var rally_id := String(rally.get("id", ""))
		for event in (rally.get("events", []) as Array):
			var stage: Dictionary = (event as Dictionary).duplicate(true)
			stage["region"] = region_id
			stage["rally_id"] = rally_id
			stage["difficulty"] = difficulty
			out.append(stage)
	return out


# How many stages `region_id` can offer before the draw has to repeat one.
static func pool_size(region_id: String) -> int:
	return events_in(region_id).size()


# `stage_count` stages drawn from `region_id`'s pool by `run_seed`, ordered EASIEST
# FIRST by the parent rally's authored `difficulty` so the last stage of the run is
# the hardest of the drawn set.
#
# Deterministic in (region_id, stage_count, run_seed): the run seed is persisted, so
# a resumed run re-derives byte-identical stages, and a bug report carrying the seed
# is reproducible.
#
# NO REPEATS while the pool lasts. Decision 32 sets the authored floor at 16 events
# per region — two 8-stage runs with no repeats — and three regions are still under
# it (`taiga` 15, `home_coast` 12, `greece_coast` 3); the authoring pass that fixes
# that is stage 4's. Until then `greece_coast` cannot even fill ONE run, so the bag
# REFILLS rather than the draw returning a short run: a repeated stage is a thin
# region, an 8-stage run that is only 3 stages long is a broken one. The refill is a
# stopgap for unauthored content, not a design — once every region clears 16 events
# it can never fire.
static func draw(region_id: String, stage_count: int, run_seed: int) -> Array:
	var pool := events_in(region_id)
	if pool.is_empty() or stage_count <= 0:
		return []
	var rng := RandomNumberGenerator.new()
	rng.seed = run_seed
	var picked: Array = []
	var bag: Array = pool.duplicate()
	while picked.size() < stage_count:
		if bag.is_empty():
			bag = pool.duplicate()
		var i := rng.randi_range(0, bag.size() - 1)
		picked.append(bag[i])
		bag.remove_at(i)
	picked.sort_custom(_easier_first)
	return picked


# Ascending parent difficulty, with the authored seed as a deterministic tie-break —
# Array.sort_custom is NOT a stable sort, so without the second key two stages of the
# same tier could come back in a different order for the same run seed and a resumed
# run would not match the run it resumed.
static func _easier_first(a: Dictionary, b: Dictionary) -> bool:
	var da := int(a.get("difficulty", 0))
	var db := int(b.get("difficulty", 0))
	if da != db:
		return da < db
	return int(a.get("seed", 0)) < int(b.get("seed", 0))
