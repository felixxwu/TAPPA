# Level streaming: drive a 5 km lab level in the game

**Status:** direction agreed with the user (2026-11-19). The settled decisions are recorded in
*Decisions* and, for the follow-up questions, *Settled with the user* at the bottom.

**Goal:** `tools/levels/hafren_5km.json` (`size` 5000, 210 road chains / 1553 nodes / ~89 km of road,
185,196 trees, 3 m height grid, 1 m cover) is drivable in `level_view.tscn` at a steady frame rate on
desktop, web and phone, with everything the 600 m Hafren level has today (gravel road and junctions,
felling, cover, weather, effects, recovery). The level is headed for real play, not just a dev view.

**Depends on:** the save-format work: lossless WebP height/cover (`heightWebp` / `coverWebp`, landed)
and binary trees (`treesBin`, 7 bytes per tree, in flight). Land both first; nothing below touches the
save format.

## Core principle

**Per frame, ideally only terrain is built; everything else is precomputed.** Road flattening,
junction pinning, road frames, tree transforms and tree visibility are worked out once by an offline
bake step in the level pipeline (rerun after edits). At runtime a frame picks tiles, copies baked grids
into meshes and LODs, assigns baked tree buffers and toggles nearby collision. Once GPU terrain lands
(Phase 6), even the mesh copy goes away and the CPU's per-frame work is roughly collision only.

## Why the current build can't scale

`LevelView` (`scripts/level_view.gd`) builds the whole square at load, and is still hard-wired to 600 m
(`const SIZE := 600.0`, `const LAB_N := 200`; `_natural` returns 0 when the grid isn't
`(LAB_N+1)²`, so the 5 km save loads flat today). At 5 km each part breaks:

| Part | Today | At 5 km |
|---|---|---|
| Ground (`_build_ground`) | one 1.5 m mesh + `create_trimesh_shape()` | (5000/1.5)² ≈ 11 M vertices, ~22 M collision triangles |
| Cover (`GroundCover.build`) | `placements` over the whole square, binned in `TILE` 32 m | ~150 k tufts at 600 m → ~10 M at 5 km; `bush_spots` → one `BushField` per layer over the whole square |
| Trees (`_build_trees`) | one MultiMesh per species, AABB = whole level; one `ObstacleBody` with a shape per tree | 185 k instances drawn every frame unless baked; 185 k box shapes in one body |
| Visibility bake (`show_from`) | rows from the lab | the lab disables Bake at `big()`; no 5 km bake exists |
| Road build (`_build_road`) | junction blend loops `_junctions × samples` | ~44 k samples × ~100+ junctions in GDScript, seconds |

## What `TerrainStreamer` depends on from the island

`scripts/free_roam/terrain_streamer.gd` (2175 lines) splits cleanly in two.

**Island-agnostic, worth reusing (~900 lines):** the scheduler (`_process`, `budget_us`, `_run_queue`,
`_step`, `_atomic`, `_peak_us`), the planner (`_plan`, mid squash, near tiles, `_cut_holes`), mesh
packing (`_arrays` skirts, `_indices_for`), per-tile `HeightMapShape3D` collision (`_collide_tile`),
the collision safety net (`_guard_collision` / `_rush_collision`), `prefill_async` / `prefill_at`, the
loaded-grid `height_at` / `_mesh_height`, and the HUD stats `benchmark_runner.gd` reads.

**Island-specific, the seam:**

- `_ready` builds `RoadNetwork`, `RoadTerrain`, `RoadSites`, barriers, poles, crowds and one material
  per biome ring (`_material_for`, `_pair_material`).
- `_prep`: the open-sea shortcut (`LabNoise.hyp` vs `island_radius_m`) and `_cands_of` →
  `network.candidates_for`.
- `_heights`: each sample is `terrain.height(x, z, cands, true)` plus `terrain.last_road_d/_sd/_s/_mark`
  written into `job.road_d` / `job.road_info`.
- `_arrays`: `terrain.ring_coord` → `_tint_at_ring`, `ground_light` (`TerrainManager.light_for_normal`),
  `terrain.tarmac_weight`, and the vertex contract for `ps1_models.gdshader` (UV = road distances,
  UV2 = tarmac + arc length, COLOR.a = lane marking, a **constant** half-width uniform `road_paint_mid_m`).
- `surface_at` → `terrain.road_weight` / `tarmac_weight`; the `height_at` fallback and `seat_exact` →
  `terrain.height`.
- All of planting (`_plant*`, `_queue_spawns`, site markers, cabins, coins, crowds, barriers, poles):
  hashed island scatter, living with the **mid** mesh (`mid_radius` 1.5 chunks ≈ 96 m), drawn to
  `tree_render_distance_m` (120 m). Too short for 22 m spruce on valley sides, and nothing in it fits
  authored trees, so level trees and cover are their own tile layers, not streamer planting.
- Outside consumers reach into `streamer.network / sites / terrain / settings`: `free_roam.gd`,
  `rest_stops.gd`, `loot_director.gd`, `mini_map.gd`, `biome_director.gd`, `cold_open.gd`,
  `auto_driver.gd`, `parked_cars.gd`, `world_pages.gd`. None of them run in the level scene.
  `RoadRecovery` already takes any node with `height_at` + its own `road_pose`.

## Decisions

1. **Option A: ground through a `LevelStreamer extends TerrainStreamer`.** It overrides `_ready`
   (Godot 4 doesn't chain it, so no island gets built), `_ground_material`, `surface_at`,
   `_after_collide` (→ `Stage.DONE`: no planting) and adds `road_pose`. The streamer gets small
   extractions with no behaviour change for free roam: `_prep_samples(job)`, `_sample(job, x, z, vi)`
   (the `_heights` body), `_pack_vertex(job, i, px, pz, normal)` (the `_arrays` body) and
   `_exact_height(x, z)` (the `height_at` fallback and `seat_exact`).
   *Rejected: B, chunking LevelView itself.* It would reinvent budget, collision rush and prefill,
   and with no LOD a 400 m view is ~284 k vertices and ~3.5 ms per frame of building at 30 m/s.
2. **The level gets its own 1.5 m settings.** It has its own `FreeRoamSettings` instance with
   `chunk_m` 48, `near_tile_m` 24, `near_stride_m` 1.5 and mid/far 6 / 12 m. That meets the rule in
   `free_roam_settings.gd`: the tile divides the chunk and is a multiple of the mid and far strides.
   2 m would coarsen the 2 m flat margin (`level_road_flat_margin`) and the 1 m `FALLOFF` shoulder.
3. **Visibility is baked offline, per tile, with far-tree simplification as a fallback.** Dropping
   the bake loses occlusion (hills, spruce walls cutting sight to ~30 m), not just distance, and
   ~23 k trees in range at a 1 km draw is doubtful on phones. The browser can't bake 5 km, so the
   bake moves to the pipeline (see *Bake*).
4. **Lab ↔ game parity is pinned by a fixture.** Both the lab's JS and the game's `LevelData` are
   checked against one shared fixture holding a synthetic save and its expected road samples,
   junctions and heights at fixed points. If either side drifts, its check fails.
5. **Load time is budgeted, not just frames.** Each phase reports load cost (parse, decode, bake load,
   `prefill_async`, tree tiles, warm-up) on desktop and web behind the `LoadingScreen`.
6. **Trees are drawn to 500 m (`GameConfig.level_tree_draw_m` = 500), with fog hiding the edge.** The
   level scene therefore needs its own fog. `LevelView._ready` copies the shared
   `GameConfig.fog_density` (0.0025) into its environment, and with exponential fog that is only ~71 %
   by 500 m (`1 − e^(−1.25)`). Near-full (~95 %) at 500 m needs a density of ~0.006, which would
   thicken free roam's fog too. So the level gets its own setting: either a new
   `GameConfig.level_fog_density`, so the level uses Godot 4.6's depth fog (`Environment.fog_mode` =
   depth, `fog_depth_end` = 500) in `level_view.tscn`, which puts the edge exactly where the trees end.
   Same distance on every platform; the far-tree simplification start is tuned in Phase 5.
7. **GPU terrain is a later phase,** after bake + `TerrainStreamer` work and gated on vertex texture
   fetch being verified on the web and phones (Phase 6).

## Bake

A **Godot tool script** (`tools/bake_level.gd`, run like `tools/level_view_capture.gd`) rather than
Python. It runs `LevelData`'s own code, so the bake can't drift from the game, and it writes a
compressed Godot resource that loads with `ResourceLoader` and needs no import step. `tools/*.gd` is
already in the Web preset's `exclude_filter`, so the tool never ships.

**Output:** `tools/levels/<name>.bake.res`, next to the save, written with `ResourceSaver`; each big array is a zstd blob (heights as 1 cm differences in byte planes), so 5 km is ~20 MB. It is exported by the Web preset's `all_resources` mode. It holds:

| Product | Form | Notes |
|---|---|---|
| Final ground heights | 1.5 m grid, 3334² uint16 (1 cm steps over a stored base, 655 m span), with road flattening and junction pinning applied | the streamer's `_sample` becomes a grid lookup; `_collide_tile` copies straight from it into `HeightMapShape3D` |
| Road frame | one RGBA8 texture at 2 m/px (landed, `LevelBake.frame_n`; 5 km is ~25 MB): across (signed), half-width, along, junction weight | read per pixel by `level_ground.gdshader` instead of today's per-vertex UV / UV2 / COLOR.a; `surface_at` reads the same data CPU-side; mostly constant off-road, so it compresses well |
| Road samples | `_sx/_sz/_sw/_sh/_sa/_sc` arrays | `road_pose` / `spawn_pose` without running `_build_road` at load |
| Tree tiles | per tile, per species, a ready MultiMesh buffer (12 floats per instance, seated on the baked heights), plus a local → global tree index map | assigned as-is; felling rewrites in place, as `knock_down` / `_step_falls` do now |
| Tree visibility | per viewpoint row along the road, the visible trees, stored as diffs against the previous row (a whole row every 64) and decoded per row at runtime | replaces the lab's `level.visibility` |

Ground cover stays the cover texture: ~10 M tuft positions don't ship. Tufts are placed per tile at
runtime from the hash (`GroundCover.placements(centre, reach)`), or in the vertex shader once GPU
terrain lands.

**Size:** measured 20.3 MB for 5 km (heights 9, trees 4.8, frame 2.7, visibility about 3), on top of the ~4.5 MB save. Heights stay at 1 cm: 0.1 m would put stair steps in the road collision.

**Staleness:** the bake stores `source_key`, a hash of the save file's bytes (`FileAccess.get_md5`)
plus a `BAKE_VERSION` const bumped whenever the bake's maths changes. `LevelView` compares it at
load. If the bake is stale or missing, the desktop build (editor) bakes in process with a printed
warning, since it's the same code. A web build refuses with a message on the loading screen. The lab
can show the same staleness by hashing its last saved file.

**Visibility method:** the lab's ID-colour render (`bake`, `bakedSight`) ported to a windowed
Godot run like `level_view_capture.tscn` (`--headless` has no renderer), viewpoints every 4 road
samples. It only considers trees within
`level_tree_draw_m` (500 m) of a viewpoint.

## Phases (each shippable alone)

0. **`LevelData` + parity fixture.** Move parsing and road/terrain queries out of LevelView into
   `scripts/level_data.gd` (RefCounted, no nodes): `unpack`, `_chains`, `_build_road`,
   `_find_junctions`, `_junction_at`, `_natural`, `_ground`, `_road_frame`, `_nearest`,
   `_nearest_sample`, `surface_at`, `road_pose`, `spawn_pose`. Size and grid N come from the save,
   not consts, and the junction blend is bucketed so `_build_road` is O(samples). Add the parity
   fixture and both checks: GUT on the game side, a node script on the lab side that extracts the
   lab's functions. LevelView keeps building everything from it, so the game is unchanged and 5 km
   now loads its real heights (slowly).
1. **Streamer hooks.** Add the extractions from decision 1 to `terrain_streamer.gd`, with no
   behaviour change. `test_free_roam*` stays green, and `benchmark_runner.gd` before/after shows no
   regression.
2. **Bake v1 + ground streams.** `tools/bake_level.gd` writes heights, road frame and road samples,
   with the staleness check. `LevelStreamer` with the 1.5 m settings replaces `_build_ground`:
   - `_sample` reads baked heights.
   - `_pack_vertex` carries height and LevelView's light × cover tint × grass multiplier.
   - `level_ground.gdshader` reads the road frame from textures.
   - Chunks wholly outside the square aren't planned, so leaving it still falls through to
     `RoadRecovery`.
   - At spawn, `prefill_async` runs behind the loading screen, then LevelView's `_warm_up`.

   Trees and cover are still built whole (fine at 600 m). Report the bake size, load time and a
   `level_replay.gd` run on `hafren.rec` against the Phase 0 numbers.
3. **Tree tiles + baked visibility.** The bake adds tree tile buffers and per-tile visibility rows.
   A `LevelTrees` node:
   - assigns the buffers;
   - on a viewpoint-row change, repacks the visible instances to the front with
     `visible_instance_count`, as `show_from` does now, spread over frames;
   - culls tiles by `visibility_range_end` (`GameConfig.level_tree_draw_m` = 500, no per-platform
     variant), with the level's own fog (decision 6) landing in
     the same change;
   - builds collision bodies only for tiles near the car, with hysteresis. Each tile node answers
     `size_factor` / `knock_down` by mapping the shape index to the tree index. `_fallen` stays
     global so a rebuilt tile stays felled.

   LevelView's whole-level tree build, `show_from` and the lab-format bake read are deleted. Fallback
   if phones still choke: a far LOD of one card per tree instead of the 6-card star
   (`Foliage._alpha_card_mesh`), handed over with `visibility_range_begin` / `_end`.
4. **Cover tiles.** Tiles of `GroundCover.TILE` are placed from the cover texture within
   `ground_cover_far_reach` plus a tile, and dropped beyond it. They're paid for from the frame budget
   the ground queue leaves (`LevelStreamer._process`), each tile with its own `BushField`s.
5. **5 km.** Bake `hafren_5km`, point `level_path` at it, and set load-time targets from
   measurement. Record `benchmark/runs/hafren_5km.rec` and run `level_replay.gd` on desktop, web
   (`?replay=1`) and phone. Tune radii, tree draw distance and tile sizes.
6. **GPU terrain (gated).** First a spike that verifies vertex texture fetch in the Compatibility
   renderer (`gl_compatibility` on web and mobile in `project.godot`) on WebGL2 and target phones. If
   it passes:
   - fixed per-LOD grid meshes are displaced in the vertex shader from the baked height texture;
   - the road frame stays per pixel from textures;
   - the streamer's planner and `_collide_tile` stay;
   - per frame the CPU only toggles collision tiles and moves the grids.

   **Throwaway when this lands, kept minimal on purpose:** the level's `_sample` / `_pack_vertex`
   overrides and its use of the streamer's mesh stages (`_arrays`, `_upload`, `_cut_holes`). The road
   frame is a texture from Phase 2 onward, so `level_ground.gdshader`'s road maths, the bake, the
   1.5 m collision and the tree and cover layers all carry over unchanged. Phase 1's hooks stay
   harmless for free roam.

## Tests

Follow `features/testing.md`: no `level_view.tscn` per test; synthetic levels only, never the Hafren
files. The bake is a static function, so tests bake small synthetic levels in memory.

- **Parity fixture (Phase 0):** `tests/headless/fixtures/level_parity.json` (synthetic save plus
  expected samples, junctions and heights). `LevelData` matches it in GUT, and the lab's check matches
  it in node. `test_level_view.gd`'s road, junction and height asserts move to bare `LevelData` tests.
  Add one: a non-600 `size` reads its own grid.
- **Streamer hooks (Phase 1):** the existing `test_free_roam*.gd` files are the guard.
- **Bake (Phase 2):**
  - baked heights equal `LevelData._ground` at grid points;
  - the road frame texture agrees with `_road_frame` at sample points;
  - an edited save makes the bake stale; an unedited one doesn't.
- **`LevelStreamer` (Phase 2):** one shared `before_all` streamer on a ~200 m synthetic baked level.
  After `prefill`:
  - collision is under the spawn;
  - `height_at` matches the baked grid;
  - `surface_at` is road on the road and not in the field;
  - nothing is planned outside the square.
- **`LevelTrees` (Phase 3, written):**
  - only nearby tiles get collision;
  - a felled tree stays felled after its tile is dropped and rebuilt;
  - a row change shows exactly that row's trees;
  - a taller tree is harder to fell (existing test, ported).
- **Cover (Phase 4):** tiles appear within reach and go beyond it; bush fields follow.
- **Benchmark:** `level_replay.gd` isn't a test; phases 2, 3 and 5 report its frame and load numbers.

## Settled with the user (2026-11-19)

1. **Look:** the level uses its own Hafren look (LevelView's shaders, sun, cover, trees) as it is now.
   Nothing from the island carries over: no biome tint or ring materials, weather drift, rocks, lakes
   or island grass.
2. **The square's edge:** ground clamped out to the horizon (the edge heights repeated outwards) with
   an invisible wall at the square's edge, so the void never shows.
3. **Visibility bake:** a windowed Godot ID render (the lab's method, real alpha cut-outs), viewpoints
   every 4 road samples (~8 m) as in the lab, trees within 500 m.
4. **Road frame encoding:** nearest-sampled hi/lo byte pairs with a manual filter in the shader;
   `along` stored modulo a 64 m period, and the `gn(along * …)` noises in `gravel()` made periodic at
   64 m (both copies: the game shader and the lab's GRAVEL_GLSL).
5. **Stale bake:** auto-bakes in process on desktop; refused with a message on web. The user runs the
   bake (or the desktop game does it); the lab doesn't trigger it.
6. **Old paths:** LevelView's whole-level ground (Phase 2) and tree build (Phase 3) are deleted
   outright.
7. **The lab's in-browser Bake visibility** is deleted once the offline bake exists.
8. **Web shipping:** the save plus bake (~15–20 MB at 5 km) ships in every web build.
9. **No phone or touch-web exceptions:** the same 500 m draw distance everywhere. An exception is
   added later only if phones measurably struggle. Where far-tree simplification starts (try
   150–200 m) is tuned in the Phase 5 benchmark.
10. **Fog:** depth fog in `level_view.tscn` ending at 500 m, tied to `level_tree_draw_m`.

## Phase 3 notes: tree draw calls

- At 600 m on the dev level, 9 of the 140 tree MultiMeshes are visible at a mid-road spot (176 trees), so trees cost about 9 of the 216 draw calls. Empty tiles are `visible = false` (`LevelTrees._repack`).
- Draw calls follow the road-visible set, not the area. A 5 km level has the same visible set per row, so about 10 to 15 tree calls. The no-visibility worst case is about 78 tiles inside a 500 m radius times up to 2 species, around 150 calls.
- Fallback if tree calls matter on phones (Phase 5 tuning lever, next to the far-card LOD): merge the species of a tile into one MultiMesh.
