# Hafren-only cleanup: delete everything that isn't the Hafren level

**Status:** planned 2026-11-27, not started. Rechecked against the code 2026-11-27. See "Progress"
below for what's done.

**Goal:** the game is now played only on the authored Hafren level (`Scenes.WORLD`,
`level_view.tscn`, `LevelView`). Delete the legacy procedural island, the `main.tscn` dev stage,
the island benchmark, the first-run intro, outlines and the old design docs, so that nothing left in the
repo is code or docs the game no longer uses.

**Settled decisions (user, 2026-11-25):**
- Drop the in-game island benchmark. The Hafren replay benchmark (`benchmark/level_replay.*`,
  `run_level_replay.sh`) replaces it.
- Retire the stage harness (`main.tscn` / `world.gd`).
- Retire the first-run intro (`ColdOpen`).
- Delete the old docs (`gameplay.md`, `PIVOT-CHANGES.md`, the island and stage files in `features/`).
- Drop outlines from the game (2026-11-27), here rather than in the migration, so the outline pass is
  deleted once along with the stage code it shares files with.

**Defaults (change them if you disagree):**
- Old saves still load. The ring, rest-stop and seen-site fields that get removed are ignored, so
  progress and cars carry over.
- Car-physics tests that use the stage harness move to a small flat-ground fixture. Only tests that
  check stage generation itself are deleted.
- `ref/`, `blender/` and `build/` are out of scope (art source and build output, not code).

**Relation to `todo/2026-11-27-rust-native-migration.md`:** this cleanup is that spec's prerequisite.
Its Phase 0 starts only once this is done, so everything the port sees is the live game.

## Progress

**How to mark progress.** When a step is done and its tests pass, tick its box in the commit that
finishes the step, with the date: `- [x] 2 Remove the first-run intro (2026-12-03)`. That commit is then what
`git blame` shows for the line, so no hash is needed. A step that's started but not finished stays
unticked, with `(in progress)` after it. Never delete a ticked step or the text under it: the spec
stays the record of how each step was done. The `CLAUDE.md` rule to ask before removing completed
spec items still applies.

- [ ] 0 Delete files nothing depends on
- [ ] 1 Remove the island benchmark
- [ ] 2 Remove the first-run intro
- [ ] 3 Make `LevelStreamer` stand alone
- [ ] 4 Delete the island
- [ ] 4b Remove outlines
- [ ] 5 Retire the stage harness
- [ ] 6 Docs and the final sweep, full test suite green

## Key structural facts (verified 2026-11-23)

- `LevelStreamer` (`scripts/level_streamer.gd`) **extends** `TerrainStreamer`
  (`scripts/free_roam/terrain_streamer.gd`, ~2.5k lines). The island's streamer is the level's
  base class, so it gets trimmed, not deleted.
- `LevelStreamer.level_settings()` builds a `FreeRoamSettings`.
- The only live call into the `TerrainManager` family (`scripts/terrain_manager.gd`, ~1.9k lines) is
  `TerrainStreamer` calling the static `TerrainManager.light_for_normal`. Other live files mention it
  in comments or untyped `_terrain` references (`tire_marks.gd`, `spectator_group.gd`,
  `billboard_field.gd`, `wheel_particles.gd`, `drivetrain.gd`, `world_runtime.gd`), and
  `perf_overlay.gd` declares a `TerrainManager`-typed variable, which must be retyped before the class
  is deleted.
- Island files that kept code still reaches, so they are **not** safe to delete outright:
  - `RegionBanner`: `rest_stop_page.gd` (the level's shop) calls `RegionBanner.name_for`.
  - `LabNoise`: `terrain_streamer.gd` and `free_roam_settings.gd` call it.
  - `TreeScatter`: `terrain_streamer.gd` uses it for forest density, and `spectator_scatter.gd`
    uses it too.
- `ScatterMath` (`scripts/scatter_math.gd`) stays: live level code uses it (`tree_mesh_field`,
  `tree_fall`, `level_weather`, `level_spectators`, `spectator_group`, `spectator_scatter`,
  `billboard_field`).
- These stay because the level uses them: `LootRules`, `RestStopPage` (the level's shop),
  `RoadRecovery`, `RegionLibrary`, `WeatherLibrary`, `WorldRuntime`, `LogPile`,
  `SpectatorScatter`/`SpectatorGroup`, `BoostLibrary`/`UpgradeLibrary`/`TuningPanel`.
- The island benchmark is launched from `benchmark_mode.gd` (`Scenes.change_to(...,
  LEGACY_FREE_ROAM)`) and `benchmark/perf_benchmark.gd`.
- 31 test files in `tests/headless/` use `main.tscn` or `SceneTestHelpers.minimal_world()`.

## Phases

The phases run one after another, because several of them edit the same shared files
(`game_config.gd`, `settings_menu.gd`, `scenes.gd`). Each phase ends with a targeted test run;
the full suite runs once, at the end.

### 0. Delete files nothing depends on
- The dev scenes `corner_catalog.tscn` / `scripts/corner_catalog.gd` and `exhaust_lab.tscn` /
  `scripts/exhaust_lab.gd`.
- The legacy capture tools in `tools/`: `cold_open_capture`, `biome_fade_capture`,
  `minimap_capture`, `road_paint_capture`, `corner_capture`. Retarget `dust_capture`,
  `lamp_capture`, `snow_capture` and `photo_mode_capture` to Hafren, or delete them.
- `tools/road_network_lab.html` and `good-seeds.md`.
- Card icons no code names any more, in `icons/cards/` (some are `.svg`, not `.png`; delete each
  with its `.import`): `coin_magnet`, `rubber_body`, `lucky_coins`, `self_healing`, `iron_will`,
  `skills`, `rally_challenge`, `region_locked`, `road_scholar`, `trail_blazer`.
- Orphan assets: `models/cabin/log_cabin_0.png`,
  `models/vegetation/groundcover_opaque__albedo.png`, `fonts/SyneMono*`. Check their `.import`
  files first.
- The HQ screenshots `docs/garage/` and `docs/map_table/`.

### 1. Remove the island benchmark
- Delete `scripts/benchmark_runner.gd`, `scripts/benchmark_results.gd`, `benchmark/perf_benchmark.*`,
  `run_benchmark.sh`, `scripts/free_roam/auto_driver.gd`, the Settings benchmark page, and the
  `test_benchmark_*` tests.
- Rewrite `features/benchmark.md` to cover only the replay benchmark.
- Strip the `Benchmark` autoload (`scripts/benchmark_mode.gd`) down to whatever the title screen's
  web probes (`benchmark/vtf_probe.*`) still use, or delete it if nothing does.
- Keep `benchmark/level_replay.*` and `run_level_replay.sh`.

### 2. Remove the first-run intro
- Delete `scripts/free_roam/cold_open.gd` and `tests/headless/test_cold_open.gd`.
- Remove the `ColdOpen` calls from `scenes.gd` (the cover's story lines), `title_boot.gd`,
  `title_screen.gd` (the new-world seed path), `music_director.gd` (`ColdOpen.due()` mutes the
  music on a first run), `damage_model.gd` and `mobile_controls.gd` (the pulsing GAS hint), plus the `cold_open` flag in `world_session.gd`.
- A first launch goes to the title screen and then into Hafren, the same as any later launch.
  Update `test_title_screen.gd` to match.

### 3. Make `LevelStreamer` stand alone (Opus plans this before any code is written)
- Give `LevelStreamer` its own small settings object in place of `FreeRoamSettings`.
- Move `light_for_normal` out of `TerrainManager`, into the streamer or a small shared helper.
- Strip the island-only parts of `TerrainStreamer`: the `RoadNetwork` / `RoadSites` /
  `RoadBarriers` / `RoadPoles` / `RoadCrowds` job stages, the per-ring materials, the
  `BiomeDirector` / `ParkedCars` / `LootDirector` markers, and the `LabNoise` island edge and
  `TreeScatter` forest density. Alternatively, fold the shared chunk-job machinery into
  `LevelStreamer` and delete the base class.
- Keep everything the level relies on: the 1.5 m near ground mesh, collision, and the chunk
  scheduler with its budget.
- `test_level_streamer.gd` guards this phase, along with `test_level_view.gd` and the level's
  other `test_level_*` files.

### 4. Delete the island
- Delete `free_roam.tscn` and `scripts/free_roam/free_roam.gd`, `Scenes.LEGACY_FREE_ROAM` and its
  redirect in `scenes.gd`, and `GameConfig.legacy_free_roam_island` together with its Settings Dev
  button (`settings_menu.gd` `_legacy_island_button` / `_toggle_legacy_island` /
  `_refresh_legacy_island`).
- Delete the rest of `scripts/free_roam/` except `loot_rules.gd`, `rest_stop_page.gd` and
  `road_recovery.gd`, and the streamer if phase 3 kept it. The deleted files include
  `road_network`, `road_terrain`, `road_sites`, `road_*` decorations, `biome_director`,
  `rest_stops`, `parked_cars`, `loot_director`, `mini_map`, `world_pages`, `map_terrain`,
  `region_banner`, `checkpoint_banner`, `lab_noise` and `free_roam_settings`.
- Trim what the kept files still use from the island: `RegionBanner.name_for` in
  `rest_stop_page.gd`, the ring tables in `loot_rules.gd`, the ring and rest-stop-spacing fields
  in `region_library.gd`, and the `BiomeDirector` / `ParkedCars` debug rows in `settings_menu.gd`.
- In `world_session.gd`, remove the lit rest stops, `mark_driven` / `max_ring`, the seen sites,
  `adopt_old_stash` and the wreck loot. Keep the parts the title screen or the level still read.
  Old saves must still load (see the defaults above).
- Remove `GameConfig.free_roam` and the island-only `GameConfig` fields: `map_*`, `minimap_*`,
  `rest_stop_*`, `checkpoint_*`. Check each with `grep -w` before removing it.
- Delete the island tests: `test_free_roam`, `test_free_roam_biomes`, `test_free_roam_rest_stops`,
  `test_free_roam_shell`, `test_found_cars`, `test_mini_map` and `test_world_pages`. Trim
  `test_loot`, `test_world_session`, `test_settings_menu` and `test_level_view` (the toggle
  redirect tests).

### 4b. Remove outlines
- Delete the object-ID outline pass and its setting:
   `scripts/spike_id_pass.gd`, `scripts/outline_setting.gd`, `shaders/spike_id_pass.gdshader`,
   `spike_id_pass_2sided.gdshader` and `spike_id.gdshaderinc`, the edge detection in
   `ps1_post_process.gdshader`, the ID viewport in `post_process_view.gd`, the Settings → Outlines
   row (`settings_menu.gd`), and their uses in `game_config.gd` and `level_stats.gd`. Update
   `test_settings_menu.gd`, `test_lighting_coverage.gd`, `features/settings.md` and
   `features/rendering.md`. Leave the saved `outlines` key ignored rather than erroring on old saves.

### 5. Retire the stage harness
- Add a small flat-ground fixture for physics tests, a replacement for
  `SceneTestHelpers.minimal_world()`. Keep `sim_test.gd`'s cached settle.
- Move the car-physics tests among the 31 harness users onto the fixture. Delete the tests that
  check stage generation: `test_track_generator`, `test_track_profile`, `test_track_gen_*`,
  `test_barrier_*`, `test_tree_scatter` (if phase 3 removed its streamer use),
  `test_corner_library`, `test_road_markings`, `test_lakes_integration`, `test_stage_manager`,
  `test_countdown_hold`, and the `test_terrain*` / `test_track_surface` family.
- Then delete:
  - `main.tscn`, `scripts/world.gd` and `stage_manager.gd`.
  - The stage pipeline: `track_generator`, `track_profile`, `track_gen_params`,
    `corner_library`, `barrier_layout` / `_section` / `_field`, `road_markings`, `tree_scatter`
    (once `spectator_scatter.gd` no longer uses it), `terrain_noise`. Not `scatter_math` (see the
    structural facts). Check `lake_field` (`car.gd`'s water predicate) and `bush_field` (used
    through `ground_cover.gd`) before deleting them.
  - Before deleting anything here, grep every remaining user of each class, including comments and
    type hints, not just calls.
  - The `TerrainManager` family: `terrain_manager`, `terrain_chunk*`, `terrain_lod`,
    `distant_terrain`, `terrain_layer`, `track_surface`, `chunk_border_debug`, plus
    `GameConfig.apply_terrain_*`.
- Remove the stage-only paths through `TrackProgress` in `car.gd` (the sibling lookup and the
  stage-gust keying) and `tire_marks.gd` (its stage mode). Then delete `track_progress.gd` if
  nothing else uses it.
- Remove the stage `GameConfig` fields: `track_*`, `barrier_*`, `road_marking_*`,
  `stage_countdown_seconds`, `stage_complete_percent`.
- Update the cost model in `features/testing.md`.

### 6. Docs and the final sweep
- Delete `gameplay.md` and `PIVOT-CHANGES.md`.
- Delete the island and stage files in `features/`: `free-roam.md`, `minimap.md`, `stage.md`,
  `track.md`, `barriers.md`, `terrain.md`, `terrain-streaming.md` (or rewrite it for
  `LevelStreamer`), `terrain-chunk-modifiers.md`, and the stage pipeline in `loading.md`. Remove the
  stage half of `progress.md`, or the whole file once `TrackProgress` is gone.
- Fix the index in `features/README.md` and the `# Docs:` breadcrumbs, which
  `test_features_docs.gd` and `test_script_breadcrumbs.gd` enforce.
- Rewrite the opening of the project `CLAUDE.md` (the `PIVOT-CHANGES.md` / legacy-island paragraph
  and the `gameplay.md` bullet) so it describes only the Hafren level. Check the skills under
  `.claude/skills/` for references to deleted files.
- Run a search for assets that nothing loads any more (textures, models and sounds left with no
  users), and delete them.
- Run the full test suite once.

## Open questions
- Phase 3: trim `TerrainStreamer` in place, or fold it into `LevelStreamer` and delete the base
  class? The Opus plan decides.
- `exhaust_lab` and `log_pile_lab`: log piles are in the level, so `log_pile_lab` may still be worth
  keeping. Phase 0 deletes only `exhaust_lab` and `corner_catalog`.
