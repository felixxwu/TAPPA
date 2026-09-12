# Region stage library

**Source:** `scripts/region_stage_library.gd` (`RegionStageLibrary`), `scripts/region_stage_pool.gd` (`RegionStagePool`), `scripts/stage_fields.gd` (`StageFields`)
**Tests:** `tests/headless/test_region_stage_library.gd`, `tests/headless/test_region_stage_pool.gd`, `tests/headless/test_stage_fields.gd` (fixture: `tests/headless/region_stage_fixtures.gd`)

**Design record:** `todo/region-stage-slots-redesign.md` — supersedes decisions 3, 7
and 32 of `todo/roguelike-pivot.md`. Replaces the old `RallyLibrary.RALLIES`
pool-and-draw model (44 named rallies, difficulty-sorted, runtime hilliness/curviness
scaling) with a fixed authored grid.

## The shape

Every region authors a **fixed 8×3 grid**: 8 stage SLOTS (one per position in an
8-stage run — slot 0 is the run's opener, slot 7 its finale), each slot exactly 3
CANDIDATE stages. That's 24 stages per region, 120 across the 5 regions
(`home`, `greece`, `taiga`, `home_coast`, `snow`).

A candidate's shape is authored FINAL for its slot — no runtime scaling — so slot 0's
candidates are hand-tuned gentle/straight and slot 7's twisty/hilly, per region
character (see `RegionStageLibrary`'s header comment for the per-region amplitude/
waterline bands). Every candidate's `(seed, turn_count, straightness,
terrain_layer*_amplitude)` combination was hand-verified to complete a real DFS
track generation before being committed — see `tools/probe_track_event.gd` for how
to re-verify one after an edit.

## Picking a run's 8 stages

`RegionStagePool.draw(region_id, stage_count, run_seed)` picks **one candidate per
slot, uniformly at random off the run seed, in slot order**. There is no pool, no
difficulty sort, and no "region too thin" fallback — see `features/region-runs.md`
→ *The stage draw* for the exact code shape and the rules this replaces.

## Field accessors

`StageFields` (`scripts/stage_fields.gd`) is what survived the deleted
`rally_library.gd`: pure `(Dictionary) -> value` lookups-with-defaults
(`event_width`, `event_forestiness`, `event_tarmac_fraction`, `event_straightness`,
`event_cliffiness`, `event_weather`, `event_is_wet`) plus the `WEATHER_*` authoring
constants, over whatever stage dict a caller hands them — a `RegionStageLibrary`
candidate, a `ChallengeLibrary`-rolled stage, or a Seed Lab preview dict. They have
nothing to do with the deleted rally wrapper and never did.

## Catalogue seam

`RegionStageLibrary.override_for_test(regions: Dictionary)` / `.reset()` / `.all()`
follow the same override/reset/all shape `CarLibrary`/`EngineLibrary` use, but the
override is `{region_id: [8 slots of 3 candidates]}`, not a flat
`Array[Dictionary]` — so it does NOT share `Registry.Seam`'s generic helper.
`tests/headless/region_stage_fixtures.gd` (`RegionStageFixtures`) is the synthetic
roster tests install: one region ("home"), 8 slots × 3 candidates, fast-generating
(low water, small turn_count).

## What this deleted

`todo/region-stage-slots-redesign.md` §7 has the full list, verified against the
tree at time of writing: the `{id, name, difficulty, restriction, special, map_pos,
events}` rally wrapper and all 44 authored rallies; the eligibility predicates
(`ineligibility_reason`, `is_eligible`, `incomplete_rallies_enterable_by`,
`eligible_car_indices`) and the tools that only existed to report on them
(`tools/report_eligibility.gd`, `tools/export_eligibility.gd`, `tools/fit_map_pins.py`,
`data/eligibility.json`); the map/reveal geometry (`map_pos`, `rally_revealed`,
`position_revealed`, `lit_sources`, `reveal_depths`, `suggest_map_pos`,
`hq_map_pos`, `MIN_PIN_SEPARATION`); and the prize/reward residue
(`prize_car_id`, `opening_rally_id_for`, `podium_count`). All of it was already
unreachable from any live screen before this redesign — see
`todo/region-stage-slots-redesign.md` §7 for the verification.

Also deleted with it: `StageConfig.stage_scale` and the whole per-stage-index
hilliness/curviness interpolation (`GameConfig.stage_hilliness_scale_min/_max`,
`stage_curviness_scale_min/_max`) — escalation is authored directly per slot now,
not computed at runtime. See `features/region-runs.md` → *The stage draw*.
