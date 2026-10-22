# Region stage library

**Source:** `scripts/region_stage_library.gd` (`RegionStageLibrary`), `scripts/stage_fields.gd`, `scripts/stage_config.gd`
**Tests:** `tests/headless/test_region_stage_library.gd`, `tests/headless/test_stage_fields.gd` (fixture: `tests/headless/region_stage_fixtures.gd`)

Nothing in the free-roam game draws stages. The grid survives for the dev stage
(`main.tscn`), the benchmark, the settings page's seed lab (`settings_menu.gd`) and
`tools/probe_track_event.gd`, and as the authored stage content its tests generate.

## The shape

Every region authors a **fixed 8×3 grid**: 8 stage SLOTS (slot 0 the gentlest, slot 7 the
hardest), each slot exactly 3 CANDIDATE stages. That's 24 stages per region, 120 across the 5 regions
(`home`, `greece`, `taiga`, `home_coast`, `snow`).

A candidate's shape is authored FINAL for its slot — no runtime scaling — so slot 0's
candidates are hand-tuned gentle/straight and slot 7's twisty/hilly. The 3 candidates
within a slot no longer vary at all except by `seed` — same turn_count/straightness/
terrain/forestiness/surface_mix/cliffiness/water_level/weather, so a slot is one
authored stage with 3 track-generation rolls (see `RegionStageLibrary`'s header
comment for the per-region waterline/character notes). Each candidate authors its own
`terrain_layer1_amplitude`, rising with the slot; region character comes from
forestiness/cliffiness/surface_mix/water_level/weather, not amplitude. Every candidate's `(seed, turn_count, straightness,
terrain_layer*_amplitude)` combination was hand-verified to complete a real DFS
track generation before being committed — see `tools/probe_track_event.gd` for how
to re-verify one after an edit.

## Field accessors

`StageFields` (`scripts/stage_fields.gd`) is what survived the deleted
`rally_library.gd`: pure `(Dictionary) -> value` lookups-with-defaults
(`event_width`, `event_forestiness`, `event_tarmac_fraction`, `event_straightness`,
`event_cliffiness`, `event_weather`, `event_is_wet`) plus the `WEATHER_*` authoring
constants, over whatever stage dict a caller hands them — a `RegionStageLibrary`
candidate or a Seed Lab preview dict.

## Catalogue seam

`RegionStageLibrary.override_for_test(regions: Dictionary)` / `.reset()` / `.all()`
follow the same override/reset/all shape `CarLibrary`/`EngineLibrary` use, but the
override is `{region_id: [8 slots of 3 candidates]}`, not a flat
`Array[Dictionary]` — so it does NOT share `Registry.Seam`'s generic helper.
`tests/headless/region_stage_fixtures.gd` (`RegionStageFixtures`) is the synthetic
roster tests install: one region ("home"), 8 slots × 3 candidates, fast-generating
(low water, small turn_count).
