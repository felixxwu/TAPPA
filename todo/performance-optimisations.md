# Performance Optimisation Spec — mobile / low-end devices

> **2026-07 update: terrain generation is now precomputed at load, not
> streamed.** The bounded-corridor precompute (see `features/terrain.md` →
> Performance) superseded the chunk-crossing streaming/budgeting work
> described throughout this doc — `TerrainChunkBuilder` is no longer resumable
> (`is_streaming_chunks`, `MAX_BUILD_ROWS_PER_FRAME`, `force_main_thread_budget`
> and the whole budgeted-web queue were removed), `DistantTerrain` is a static
> backdrop built once (no `ROWS_PER_FRAME` deferred rebuild), and
> `_reconcile` is a cache lookup (`MAX_INTEGRATIONS_PER_FRAME` no longer
> applies — there's no per-crossing build to throttle). The narrative below
> (items 7 and the chunk-crossing follow-up) is kept for historical trace of
> the single-threaded-web decision; the mechanism it describes has since been
> replaced.
>
> Status: **PARTIALLY DONE.** The unblocked, decision-free, low-risk items are
> implemented: **item 4** (frame cap — split into `GameConfig.target_fps`=60 for
> desktop and `target_fps_mobile`=30 for mobile+web, selected via
> `target_fps_for(Platform.is_mobile_or_web())`, applied in
> `world._ready`, skipped under `--headless`), **item 1** (mipmaps on
> tree/bush `.import` + `lod_bias` uniform in `billboard.gdshader` driven by
> `GameConfig.texture_lod_bias`), **item 6** (engine-audio: per-harmonic `pow`
> hoisted out of the firing-phase loop in `_voice`; scratch `slice()` allocation
> dropped in `engine_audio.gd`; **6.3** shipped `engine_harmonics`=3; generator
> `BUFFER_SECONDS` raised 0.1→0.15 for underrun headroom on slow web frames),
> **item 11** (guard `downforce_readouts` behind `debug_wheel_forces`), and
> **item 10** (HUD label string-change caching). Docs: `features/rendering.md`,
> `features/engine-audio.md`.
>
> **Chunk-crossing smoothness follow-up (item 7 remainder): ADDRESSED.** Two
> per-crossing main-thread spikes were found and cut: (a) the per-vertex terrain
> **light bake** re-sampled the noise 4× per vertex — `compute_chunk_data` now
> samples a 1-cell pure-height **halo** once and reads neighbours from it
> (bit-identical; ~52% off the lit chunk build, the shipped path since
> `terrain_light_amount`=1.0); (b) **`DistantTerrain`** rebuilt its ~2,600-vertex
> light-baked backdrop synchronously *on the crossing frame*, stacking on the
> detail-ring stream — it now **defers** the rebuild to a frame when
> `TerrainManager.is_streaming_chunks()` is false. The perf benchmark
> (`perf_benchmark.gd`) now sets `light_amount=1.0` so it measures the real lit
> cost. Docs: `features/terrain.md`, `features/engine-audio.md`. **Still open:**
> (c) **detail-chunk generation is now time-sliced across frames** —
> `TerrainChunkBuilder` (`scripts/terrain_chunk_builder.gd`) is a resumable builder;
> the budgeted pump advances it `MAX_BUILD_ROWS_PER_FRAME` (16) grid rows per frame
> and spawns the chunk on completion, instead of building a whole chunk (which alone
> overruns a phone frame) in one tick. `compute_chunk_data` runs the same builder to
> completion, so the threaded/sync paths stay byte-identical (guarded by
> `test_incremental_build_matches_full_build`). (d) **The `DistantTerrain` backdrop
> rebuild is now both deferred AND sliced** — it starts only on a non-streaming
> frame and then fills `ROWS_PER_FRAME` (8) rows per frame, swapping the new mesh in
> on completion (`distant_terrain.gd` `_begin_rebuild`/`_step_rebuild`/`_finish_rebuild`;
> the synchronous `rebuild_around` runs them to completion for the initial build).
> So no per-crossing terrain work — detail chunks or backdrop — does a whole mesh
> build in one tick anymore. **Real-device check still wanted** to confirm the
> crossing is smooth end-to-end and to tune the row budgets (`MAX_BUILD_ROWS_PER_FRAME`,
> `DistantTerrain.ROWS_PER_FRAME`).
>
> **Item 7 (web-export threading): DECIDED — ship single-threaded.** Chose
> maximum device reach over threaded chunk-streaming smoothness, consistent with
> the inherently-low-end principle. `export_presets.cfg` now sets
> `variant/thread_support=false` (engine thread pools dropped); the build needs no
> `SharedArrayBuffer` / cross-origin isolation, so itch.io's SAB toggle is no
> longer required and `serve_web.sh` serves plain HTTP (no cert / COOP-COEP).
> Terrain gen already routed web through the frame-budgeted main-thread queue
> (`_use_budgeted_generation()` keys on `OS.has_feature("web")`, not the thread
> flag), so no terrain code changed. Docs: `features/terrain.md`, `build_web.sh` /
> `serve_web.sh` comments. **Remaining (not a code blocker):** confirm on a real
> mid/low-end phone — the two biggest per-crossing main-thread spikes (light-bake
> re-sampling and the synchronous `DistantTerrain` rebuild) are now cut/deferred
> (see the chunk-crossing follow-up note above), and BOTH detail-chunk generation
> (`TerrainChunkBuilder`) and the `DistantTerrain` backdrop rebuild are now time-sliced
> row-by-row across frames — no per-crossing terrain work does a whole mesh build in
> one tick. Remaining: a real-device pass to confirm smoothness and tune the row
> budgets.
>
> **Still open — BLOCKED ON YOUR DECISIONS / ASSETS:**
> - **Items 2 + 3** (foliage view-cone cull + visible cap, collision-box cull):
>   gated on the **billboard-vs-opaque-low-poly-mesh decision** (and the `.glb`
>   foliage models if mesh) — the spec says decide before building the field
>   class. The biggest GPU/physics wins, but need that call first.
>
> **Deferred (optional / advisory):** item 8 (physics-tick alloc refactor — a
> safe follow-up, guarded by existing tests), and items 5/9/12 (the spec's own
> recommendation is "measure first / probably skip").
>
> This document is the implementation
> brief. It references the code as it exists on this branch so the work can be
> picked up later. Follow the project's config-first convention
> (`CLAUDE.md`): every new tunable goes in `GameConfig`
> (`scripts/game_config.gd` + `config/game_config.tres`), never hardcoded in
> scripts/scenes. Update the relevant `features/*.md` doc and add/adjust tests
> in the same piece of work.
>
> **Design principle: the game is _inherently_ low-end.** There is no separate
> "low quality" profile or toggle — the aggressive values below are simply the
> defaults, the only mode the game ships. Every device gets the same lean
> pipeline. The `GameConfig` knobs exist for tuning the single shipped value (and
> for dev/debug), NOT to switch between a "high" and "low" path. Do not add a
> quality-tier switch.

## ⚠️ Open action items (asset / prerequisite work)

- [x] **Create low-poly 3D models of the trees and foliage** — **DONE for trees.**
      A procedural low-poly tree (`models/low_poly_tree.glb`, generated by
      `tools/lowpoly_tree.gd`; canopy textured with `textures/leaves.png` from
      `tools/gen_leaf_texture.py`) replaced the tree billboards. See
      `features/trees.md`. **Bushes still use billboards** (no bush mesh yet).
      This unblocked the "opaque low-poly meshes" direction under item 2 (trees)
      and the vegetation auto-LOD in
      [`todo/distant-terrain-and-sky.md`](distant-terrain-and-sky.md) §2.
- [x] **Web-export threading model** (item 7): **DECIDED — single-threaded**
      (`thread_support=false`) for maximum device reach. Terrain gen already uses
      the frame-budgeted main-thread queue on web, so no code change beyond the
      preset + script/doc updates. Remaining: a real on-device smoothness check
      across chunk boundaries (tune `MAX_BUILD_ROWS_PER_FRAME` if needed). Owner: Felix.

## Context / current state (measured from the code)

- Renderer: GL Compatibility, `rendering_method.mobile="gl_compatibility"`,
  `force_vertex_shading=true` (`project.godot [rendering]`). Internal viewport
  480×360 via viewport stretch. All materials `unshaded`. Good baseline.
- **Active config is `config/game_config.tres`, which overrides the code
  defaults.** The live values that matter here:
  `trees_per_turn = 200`, `track_turn_count = 30`, `tree_spawn_radius_m = 50`,
  `tree_min_tree_dist_m = 3`, `tree_collision_radius_m = 0.1`,
  `terrain_tile_per_meter = 0.5`, `fog_density = 0.03`. `tree_render_distance_m`
  is **not** overridden, so it uses the code default `80.0`
  (`scripts/game_config.gd:292`); `tree_render_fade_m` default `15.0`
  (`:294`); `tree_collision_height_m` default `4.0` (`:289`).
- Net result: `scripts/world.gd:80-95` scatters and builds **~30 turns × 200 =
  ~6,000 trees + ~6,000 bushes**, each an instance in one `MultiMesh` per field.
- Terrain: `CHUNK_M = 50`, `CELL_M = 1.0`, `SAMPLES = 51`, `RADIUS = 1` →
  **3×3 = 9 loaded chunks** (`scripts/terrain_manager.gd:10-13`). NB: a couple
  of `features/*.md` lines say "5×5"; the code is `RADIUS=1` → 3×3. Fix the docs
  while here.

Items 1–5 below are the **GPU / fill / render-side** work; items 6–12 (in the
**CPU & platform** section further down) are the pure-CPU and platform costs the
PS1 look can't touch. Of the GPU items, **(2) and (3) — foliage draw + collision
— are the biggest wins; (1) and (4) are cheap and safe; (5) is mostly an advisory
"probably don't".** Of the CPU items, **(6) audio and (7) the threaded-export
decision move the needle most.** See the consolidated implementation order at the
end.

---

## 1. Mipmaps + aggressive LOD on textures

### Why
Tile-based mobile GPUs are bandwidth- and texture-cache-bound. A minified
texture (ground tiling into the distance, far billboards) without mipmaps
thrashes the cache and aliases — costing fill rate and bandwidth, the exact
mobile bottleneck. The retro shimmer is partly intentional, but on a low-end
phone the bandwidth cost outweighs the aesthetic.

### Current state
- `textures/grass.jpg.import` / `textures/gravel.jpg.import`:
  `mipmaps/generate=true`, `compress/mode=2` (VRAM compressed). **Good already.**
- `textures/tree.png.import`: `mipmaps/generate=false`, `compress/mode=0`
  (lossless/uncompressed). **This is the one to fix** — it's the most-instanced
  texture (~6,000 billboards) and the most minified at distance.
- `textures/tree-greece.webp.import`: verify (expected same as tree — mipmaps off).

### Plan
1. Set `mipmaps/generate=true` in `textures/tree.png.import` and
   `textures/tree-greece.webp.import`. Re-import (delete `.godot/imported/` entries or
   let the editor regenerate).
2. "Aggressive LOD": bias sampling toward lower mip levels so distant
   foliage/ground resolves to a cheaper mip sooner. Two options:
   - **Per-texture import:** there is no direct LOD-bias field in the import
     dock for GL Compatibility; prefer the shader route.
   - **Shader (preferred, controllable):** in `shaders/billboard.gdshader`
     `fragment()`, replace `texture(albedo, UV)` with `texture(albedo, UV, lod_bias)`
     where `lod_bias` is a `uniform float` (default ~0.5–1.0). Same idea for the
     ground in `shaders/ps1_models.gdshader` if ground bandwidth shows up in the
     profiler (`P` overlay, render-gpu line). Expose `texture_lod_bias` in
     `GameConfig` as the single shipped value (default biased toward cheaper
     mips), tunable for dev.
3. Keep `filter_nearest` (PS1 look) — mipmapping is independent of the
   magnification filter; with nearest + mipmaps you still get crisp up-close
   texels but cheaper minified sampling.

### Files
`textures/tree.png.import`, `textures/tree-greece.webp.import`,
`shaders/billboard.gdshader`, `shaders/ps1_models.gdshader`,
`scripts/game_config.gd` (+ `config/game_config.tres`), `features/rendering.md`.

### Risk / notes
Mipmaps add ~33% texture memory per asset — negligible here (handful of small
textures). Watch that mip-bias doesn't blur the tree silhouette so much the
alpha-scissor cutout (`alpha_scissor = 0.5`) eats the edges; clamp bias modestly.

---

## 2. Spatial + view-cone culling of trees/bushes; max visible instance count

### Why
`scripts/billboard_field.gd:build()` creates a `MultiMesh` with
`mm.instance_count = positions.size()` and **never sets
`visible_instance_count`** (confirmed: no `visible_instance_count` /
`custom_aabb` / `VisibilityRange` anywhere in `scripts/`). So all ~6,000 tree +
~6,000 bush quads are vertex-processed and rasterized **every frame**. The
distance cull in `shaders/billboard.gdshader fragment()` is a per-fragment
`discard` past `render_distance` (~80 m) — it saves some fill but **not** the
vertex/setup cost, and does nothing for instances behind the camera.
Meanwhile the terrain only keeps ~150 m of ground loaded. This is the single
biggest GPU inefficiency.

### Plan
Make `BillboardField` cull on the CPU so only nearby, in-front instances are
submitted, with a hard cap on visible instances.

1. **Keep a master list of instance positions** on the field (it already builds
   them in `build()`; retain the `PackedVector2Array` + computed `y`).
2. **Spatial binning:** at build time, bucket instances into a uniform grid keyed
   by `floor(pos / BIN_M)` (e.g. `BIN_M = CHUNK_M = 50`, reusing the terrain grid
   notion). Store per-bin index lists.
3. **Per-frame (or every N frames) rebuild the MultiMesh's active set** from the
   camera transform:
   - Gather bins within `render_distance` of the camera XZ.
   - For each candidate instance, reject if beyond `render_distance` (matches the
     shader) **and** reject if outside the view cone: test the instance direction
     against the camera forward with a dot-product threshold derived from the
     camera FOV plus a margin (billboards are wide, so pad generously, e.g.
     `cos(fov*0.5 + 20°)`). Keep a small "behind but close" keep-radius so trees
     don't pop at the screen edge when turning.
   - Write survivors' transforms into the MultiMesh buffer and set
     `multimesh.visible_instance_count = survivor_count`.
4. **Max visible instance count (all objects):** add a `GameConfig` cap
   (e.g. `max_visible_billboards`, default ~800 trees / ~800 bushes — a single
   shipped cap, not a per-tier value). When survivors exceed the cap, keep the nearest N (the bins
   are already roughly distance-ordered; do a partial nearest selection, not a
   full sort — see draw-order note below). This bounds worst-case cost
   regardless of how dense a forest the track generates.
5. Apply the same `visible_instance_count` discipline to any future MultiMesh.
   Terrain chunks are already bounded (9 nodes).

### Implementation seams
- `BillboardField` becomes stateful: store `_positions`, `_world_y`, `_bins`,
  `_cam` (resolve the active `Camera3D` via `get_viewport().get_camera_3d()` in
  `_process`, or have `world.gd` pass the `ChaseCamera`).
- Add a `_process(delta)` to `BillboardField` that does the cull. Throttle to
  e.g. every 3–4 frames or on camera-moved-threshold to keep CPU low; the
  shader's `fade_band` dither already hides the coarse stepping.
- `build()` signature unchanged for callers in `world.gd:83` / `:93`; the cull
  is internal. The collision build (item 3) hangs off the same bins.

### Draw order (front-to-back) — advice requested
**Recommendation: do NOT depth-sort the MultiMesh every frame.** Reasoning:
- Front-to-back ordering reduces overdraw only via early-Z rejection. These
  billboards use **alpha-scissor `discard`** (`render_mode ... depth_draw_opaque`
  with a `discard` in `fragment`), which **defeats early-Z on tile GPUs** — the
  GPU can't reject a fragment before running the shader because the shader
  decides coverage. So the theoretical sorting win is largely unavailable here.
- Re-sorting ~6,000 instances by camera distance on the CPU every frame (or even
  the visible subset) is itself expensive in GDScript and would likely cost more
  than it saves — the opposite of the goal on a weak CPU.
- **What actually helps** is reducing the *number* of overlapping fragments:
  the distance cull, the view-cone cull, the visible cap, and keeping
  `trees_per_turn` / `tree_render_distance_m` lean by default. Spatial
  binning gives "roughly near-first" submission for free without a sort.
- If profiling later shows the foliage is genuinely overdraw-bound and CPU has
  headroom, a *coarse* bucket sort (by bin distance, not per-instance) is the
  most we'd consider — but treat it as a separate, measured follow-up.

### Files
`scripts/billboard_field.gd` (main work), `scripts/world.gd` (optional camera
hand-off), `scripts/game_config.gd` + `config/game_config.tres`
(`max_visible_billboards`, cull cadence), `features/trees.md`.

### Tests
`tests/headless/test_tree_scatter.gd` is pure placement — keep. Add
`tests/headless` coverage for the cull math: given a camera pose and a set of
positions, the survivor set is within `render_distance`, within the cone (+
margin), and capped at `max_visible_billboards`; `visible_instance_count`
matches. Keep it headless/pure by factoring the selection into a static function
that takes (positions, cam_basis, cam_pos, params) → indices, so no viewport is
needed (mirrors how `TreeScatter.scatter` is tested).

### Risk
Pop-in when turning fast if the cone margin is too tight — pad it and lean on the
`fade_band` dither. Throttling the cull too aggressively shows lag between camera
and visible set; tune cadence.

### Alternative direction: opaque low-poly meshes instead of cutout billboards

> **✅ DONE FOR TREES.** Trees now render as opaque low-poly meshes via
> `scripts/tree_mesh_field.gd` (`TreeMeshField`) using `models/low_poly_tree.glb`
> — see `features/trees.md`. Rather than the per-frame CPU view-cone cull + visible
> cap described below, trees are **spatially binned into per-cell MultiMeshes**
> (`tree_bin_size_m`), each with `visibility_range_end`/fade for the far cull and
> the importer-generated mesh LODs for distance decimation — no per-frame CPU.
> **Still open:** (a) a **bush mesh** (bushes remain billboards); (b) the
> per-frame **view-cone cull + `max_visible_billboards` cap** (items 2/3) if
> profiling shows the binned fields still over-submit; (c) **collision-box culling**
> (item 3) — `TreeMeshField` still adds all tree hitboxes up front.

On the target hardware the foliage is **fill-bound**, and alpha-cutout
billboards are the worst case for it: `discard` disables early-Z/HSR, and even a
lone billboard wastes ~half its shaded fragments on the transparent part of the
quad. Opaque low-poly meshes flip that — early-Z works, solids occlude each
other (bounded overdraw), no per-fragment discard tax, no alpha channel needed —
at the cost of more (cheap, abundant) vertices. Net: very likely faster here,
and the chunky faceted look suits the PS1/PS2 aesthetic.

Plan once the models exist:
1. Author the tree/bush meshes in `blender/`, export `.glb` (mirror `mx5.glb` /
   `mx5.glb.import`). Keep them genuinely low-poly (~tens of tris each) and small
   in screen coverage so they don't reintroduce overdraw.
2. Give them an **opaque** material on `shaders/ps1_models.gdshader` (already the
   project's unshaded mesh shader) — no `discard`, no alpha — so they go through
   the same quantize/dither/fog pipeline as everything else.
3. `BillboardField` becomes a generic instanced-mesh field (or add a sibling
   `FoliageField`): same `MultiMesh` + spatial/view-cone cull + visible cap +
   collision-box logic from items 2/3, but with `mm.mesh` set to the authored
   `.glb` mesh instead of a `QuadMesh`, and the billboard shader dropped. The
   per-instance transform path is unchanged.
4. Drop the camera-facing billboard yaw (real geometry doesn't need it) and the
   `alpha_scissor` / `bayer4x4` discard; keep the distance fade (it can move to a
   cheap per-instance `visible_instance_count` cut now that culling is CPU-side).
5. Update `features/trees.md` and `features/rendering.md`; re-point the
   `world.gd` build calls (`scripts/world.gd:81-95`) at the mesh field.

This supersedes the billboard-specific parts of item 1 (tree/bush mipmaps) and
item 2 (the fragment-discard discussion) **if** adopted — keep the spatial cull,
visible cap, and collision culling regardless. Decide billboard-vs-mesh before
implementing item 2 so the field class is built the right way once.

---

## 3. Spatially cull tree collision boxes

### Why
`scripts/billboard_field.gd build()` adds **one box shape per tree** to a single
`StaticBody3D` via `PhysicsServer3D.body_add_shape(...)` — all ~6,000 of them, up
front, permanently. Memory is cheap (one shared `BoxShape3D`), but every box is a
broadphase entry the physics engine tracks forever. The car only ever touches
trees within a few metres. This is the most likely *physics* bottleneck (more so
than terrain — see item 5).

### Plan
Mirror item 2's spatial bins for collision: only keep hitboxes near the car
present in the body.
1. At build time, store per-tree transforms in the same bins (don't add shapes to
   the body yet).
2. In `_process`/`_physics_process`, maintain the set of bins within a small
   `collision_radius_m` of the car (e.g. one bin ring around the car's bin —
   much smaller than the render distance; trees only matter when nearly touching).
3. Reconcile the body's shapes when the car changes bin (same pattern as
   `TerrainManager._reconcile`, `terrain_manager.gd:412`): remove shapes for bins
   that left, add shapes for bins that entered. Use
   `PhysicsServer3D.body_clear_shapes` + re-add for the small active set each
   transition (cheap because the active set is tiny), or track shape indices.
4. Add `GameConfig.tree_collision_radius_active_m` (the keep-radius around the
   car, e.g. 30–60 m), separate from the existing per-box
   `tree_collision_radius_m` (0.1) which is the box half-extent.

### Files
`scripts/billboard_field.gd`, `scripts/game_config.gd` +
`config/game_config.tres`, `features/trees.md`.

### Tests
Add a headless test: given a car position, only trees within the active radius
have shapes in the body (assert via `PhysicsServer3D.body_get_shape_count`), and
crossing into a new bin updates the set. Keep the existing collision smoke check
in `tests/headless/test_smoke.gd`.

### Risk
The car must never fall through / drive past a tree whose box was culled — keep
the active radius comfortably larger than the car + braking distance at top
speed within one cull tick. Reconcile on bin crossing (cheap, like terrain) so
there's no per-frame churn.

---

## 4. Frame cap to 30 FPS

### Why
Nothing sets `Engine.max_fps` or vsync anywhere (`project.godot` has no
`[application] run/max_fps`; no `Engine.max_fps` in `scripts/`). An uncapped loop
on a phone burns battery and generates heat → **thermal throttling**, which on
old phones turns a "fine" 60 fps into stuttering 20s within minutes. A steady 30
cap keeps the GPU/CPU cool and the frame pacing even.

### Plan
1. Add `GameConfig.target_fps` (default `30`; `0` = uncapped for desktop dev).
2. Apply once at startup in `scripts/world.gd._ready()`:
   `Engine.max_fps = cfg.target_fps` (only set when `> 0`).
3. Consider `DisplayServer.window_set_vsync_mode(VSYNC_ENABLED)` so the 30 cap is
   aligned to the display (avoids tearing + further smooths pacing). On web/mobile
   exports vsync behaviour differs; disable it if it causes issues there.
4. Decouple physics: physics already runs in `_physics_process` at the project
   physics tick (default 60). With a 30 fps render cap, leave physics at 60 for
   stable handling (`car.gd`/`drivetrain.gd` integrate there). If CPU-bound on the
   weakest devices, lower `physics/common/physics_ticks_per_second` to 30 as the
   shipped value — but test handling carefully (the tire model is tick-sensitive).

### Files
`scripts/world.gd`, `scripts/game_config.gd` + `config/game_config.tres`,
`features/rendering.md` or `features/configuration.md`.

### Tests
`tests/headless` can assert `world.gd` sets `Engine.max_fps` from config (or
factor the "apply settings" into a testable helper). Low-risk.

---

## 5. Heightmap-terrain collision culling — ADVICE (likely NOT worth it)

The request: spatially cull the heightmap collision to just the 1–2 chunks the
car is over, and/or shrink `CHUNK_M` while raising `RADIUS` to keep the same
rendered area but reduce the collision surface per body.

### Recommendation: **don't do this first; it's low/negative ROI.** Reasoning:

1. **Only 9 chunks have collision today** (`RADIUS=1`, 3×3). Each is a
   `HeightMapShape3D` of 51×51 (`terrain_chunk.gd:46-50`). Jolt builds a
   BVH/quadtree over each heightmap; **narrowphase only tests triangles under the
   car's AABB**, and broadphase only flags the 1–4 chunk AABBs the car overlaps.
   So the per-frame cost is already close to "the chunk under the car," regardless
   of how many chunks exist. Disabling collision on the other ~5–8 chunks saves
   mostly broadphase AABB entries — a handful — i.e. **negligible**.
2. **Correctness risk is real.** The car spans chunk seams; wheels (ray casts
   from `VehicleWheel3D`) and the chassis box can contact the neighbouring chunk
   when near an edge. Culling to "1–2 chunks" invites the car catching air or
   falling through at boundaries. Not worth the saving in (1).
3. **Shrinking `CHUNK_M` + raising `RADIUS` makes physics *worse*, not better.**
   Same total ground area, but **more bodies** = more broadphase entries, more
   nodes, **more draw calls** (each chunk is its own `MeshInstance3D` surface —
   `terrain_chunk.gd:14`), and more chunk integration churn on the main thread
   (`_integrate_ready`, `MAX_INTEGRATIONS_PER_FRAME=1`, so more boundary
   crossings = more frames spent integrating). The per-body collision surface
   drops but the **total** surface is unchanged and broadphase grows. Net
   neutral-to-worse for physics, clearly worse for rendering CPU.

### What to do instead
- **Do item 3 first** (tree collision boxes) — ~6,000 permanent broadphase
  entries is the actual physics pressure, not 9 heightmaps.
- **Measure before touching terrain collision.** Use the `P` overlay
  (`scripts/perf_overlay.gd`): the `cpu physics` line isolates physics cost, and
  `./run_benchmark.sh` reports `_spawn_chunk` (the heightmap build) cost. Only if
  `cpu physics` is high *after* item 3 is the terrain worth revisiting.
- **If terrain collision is genuinely hot** (unlikely), the safe lever is the
  opposite of shrinking chunks: keep `CHUNK_M=50` and, if anything, build
  collision only for the **inner** chunks of the ring while still *rendering* the
  outer ring — i.e. decouple the collision radius from the render radius
  (collision `RADIUS_COLLISION=1` for the centre + 8 neighbours stays, but you
  could in principle drop to the 4-neighbour plus centre). This keeps seams safe
  (car never leaves the collision set within a frame) while trimming a few bodies.
  Expected win is small; treat as last resort.

### If we still want the knob
Expose `terrain_collision_radius` in `GameConfig` (default = `RADIUS`, i.e. all
loaded chunks get collision) so it can be tuned/measured without code changes,
and have `TerrainChunk._build_collision` skip the `HeightMapShape3D` when the
chunk's ring distance exceeds it. Default OFF (collision on all loaded chunks).

---

# CPU & platform (non-GPU)

Items 1–5 are about the GPU / fill / render-side cost. The items below are
**pure CPU and platform** costs that run every frame regardless of the graphics
style — i.e. the PS1 look does nothing for them, which is the crux of the
original "looks retro ⇒ runs on old phones" theory: the aesthetic only addresses
the GPU side, and several of the real old-phone bottlenecks are here.
**Items 6 and 7 are the two that genuinely move the needle for old phones.**

## 6. Engine audio: per-sample DSP in GDScript on the main thread

### Why
`scripts/engine_audio.gd:31` pulls audio every `_process` frame and
`scripts/engine_audio_synth.gd fill()` (`:82`) runs a **per-sample loop at
22,050 Hz**. Each sample, `_voice()` (`:130`) loops `firing_phases × harmonics`
— for a 6-cylinder car at the default `engine_harmonics = 4` that's ~24 `sin()`
**plus 24 `pow()`** per sample, plus `exp()`, two `randf()`, a DC blocker and a
soft clipper. That is on the order of **~half a million transcendental calls per
second in interpreted GDScript, on the main thread, every frame.** This is a
classic old-phone / web-export CPU cost and is completely invisible to the PS1
look. It also couples audio to frame rate: the fill runs in `_process`, so a few
slow frames underrun the 0.1 s buffer → audible crackle (with a 30 fps cap
that's only ~3 frames of headroom).

### Plan
1. ✅ **DONE. Precompute the harmonic weights.** `_voice()` builds the
   `[harmonics]` weight table once per call and reuses it across firing phases.
2. ✅ **DONE. Avoid the per-frame allocation.** `engine_audio.gd` sizes the scratch
   to exactly `n` and pushes it directly — no per-frame `slice()`.
3. ✅ **DONE. Lower the shipped cost.** `config/game_config.tres` now sets
   `engine_harmonics = 3` (was the code default 4) — note still reads well; trims
   the inner loop ~25%. Also raised the generator `BUFFER_SECONDS` 0.1→0.15 so a
   slow web frame is less likely to underrun the buffer (the frame-coupling in the
   "Why" above). Single shipped values, per the inherently-low-end principle.
4. ✅ **DONE. Voice wavetable — the structural win.** The firing-pulse voice is a
   periodic function of crank phase parameterised only by load, so `_voice()`'s
   `firing_phases × harmonics` `sin`/`exp` sum is now baked over one crank cycle
   into a small bank of load-indexed tables **once at init** (`_build_voice_bank`),
   and the per-sample path reads it back with bilinear phase/load interpolation
   (`_read_voice`). Pitch tracks rpm for free (the crank phase still advances at
   the rpm rate; the table is sampled at that phase). Measured **3.4× (i4) → 8.1×
   (v12)** faster on the voice, cost now *constant* in cylinder count, worst-case
   approximation error ~`8e-5` (inaudible). Guarded by
   `test_wavetable_matches_direct_voice` plus the existing behavioural tests.
   **Measured dead-ends (do not retry in GDScript):** a `sin` lookup table and a
   harmonic-recurrence rewrite both benchmarked *slower* than direct `sin` — a
   GDScript builtin `sin` is a cheap dispatch into compiled engine math, so
   swapping one `sin` for several interpreted ops loses. The wavetable wins only
   because it replaces the *whole* harmonic sum (~16 transcendentals) with ~5
   array ops, not one `sin`.
5. **Optionally decouple from the render frame.** Consider filling the
   `AudioStreamGenerator` from a thread / on an audio cadence rather than
   `_process`, so a slow render frame can't underrun audio. **Note:** the shipped
   web build is single-threaded (item 7), so a true audio thread isn't available
   there — on web the levers are steps 1–3 plus keeping main-thread frames short
   (the chunk-crossing terrain work above). Heavier change; do only if 1–3 don't
   clear it on a real device.

### Files
`scripts/engine_audio_synth.gd`, `scripts/engine_audio.gd`,
`scripts/game_config.gd` + `config/game_config.tres`, `features/engine-audio.md`.

### Tests
`engine_audio_synth.gd` is pure/headless (`RefCounted`, `fill()` only) — add a
test asserting the precomputed-weight path produces the same samples as the
current per-sample `pow` (within float epsilon) for a few rpm/throttle/harmonic
cases, so the optimisation is provably behaviour-preserving.

### Risk
Low. The weight precompute is algebraically identical; keep an epsilon-compare
test. Threading the fill (step 4) is the only risky part — gate it separately.

## 7. Threaded web export vs. old-device compatibility — ✅ DECIDED: single-threaded

> **Resolved:** shipped single-threaded for maximum device reach.
> `export_presets.cfg` now has `variant/thread_support=false` and the engine
> thread pools removed; `build_web.sh` / `serve_web.sh` updated (no SAB toggle, no
> COOP/COEP, plain-HTTP serve); `features/terrain.md` documents the deliberate
> single-threaded web config. **No terrain code changed** — `terrain_manager.gd`
> already routes web through the frame-budgeted main-thread queue
> (`_use_budgeted_generation()` keys on `OS.has_feature("web")`, so it was in
> force regardless of the thread flag; the worker pool was never actually used on
> web). The only open follow-up is a real on-device smoothness check across chunk
> boundaries (tune `MAX_BUILDS_PER_FRAME` if it micro-hitches). The original
> analysis is kept below for trace.

### Why
`export_presets.cfg:30` (originally) set `variant/thread_support=true` with
`threads/emscripten_pool_size=8` / `godot_pool_size=4`, and `serve_web.sh` sent
the COOP/COEP headers. Threaded WASM requires `SharedArrayBuffer`, which:
- needs the **host** to send cross-origin-isolation headers (itch.io etc. must
  have "SharedArrayBuffer support" toggled on — see `build_web.sh:8-9`), and
- **isn't available on older / low-memory mobile browsers**, and the thread
  pools cost extra memory cheap phones may not have.

So the threaded build can **fail to start or OOM on exactly the old hardware the
project targets** — directly at odds with "runs on any device, even old phones."
Meanwhile the terrain generation relies on `WorkerThreadPool`
(`terrain_manager.gd:436`) to keep chunk loading off the main thread, so a
non-threaded export would **hitch on chunk loads** unless tuned.

### Plan / decision
Make this an explicit, tested choice rather than an accident of the preset:
1. **Decide the priority:** maximum device reach (single-threaded export) vs.
   smoother chunk loading (threaded export). For the stated goal, lean toward a
   **single-threaded export as the shipped web build**, accepting that terrain
   gen must then be smooth on the main thread.
2. **Make terrain gen survive single-threaded.** `terrain_manager.gd` already
   has `use_threaded_generation` and a synchronous path. When threads are
   unavailable, fall back to synchronous generation but **spread the work**: keep
   `MAX_INTEGRATIONS_PER_FRAME = 1` (`:14`) and consider time-slicing
   `compute_chunk_data` (it's the heavy CPU half) across frames so a boundary
   crossing doesn't stall. Detect thread availability at runtime
   (`OS.get_processor_count()` / whether `WorkerThreadPool` ran) rather than
   hardcoding.
3. **If keeping threads**, document the host header requirement and provide the
   single-threaded build as a fallback for devices/hosts that can't do SAB.
4. Confirm the chosen export actually boots on a low-end test device before
   shipping.

### Files
`export_presets.cfg`, `scripts/terrain_manager.gd`, `build_web.sh` /
`serve_web.sh` (docs), `features/terrain.md`, `features/architecture.md`.

### Risk
Single-threaded terrain gen reintroduces the startup/boundary hitch the threads
were added to hide; the fog masks far pop-in but not a frame stall. Time-slicing
`compute_chunk_data` is the mitigation and needs care (partial-chunk state).

## 8. Physics hot-path allocation churn — ✅ DONE

> **Resolved.** The `contacts`/`WheelContact` pooling described below was already
> in place (pooled `WheelContact` per wheel, refilled each tick). The remaining
> per-physics-tick allocations were then killed: (a) `drivetrain.surface_tire_params()`
> now fills and returns a reused `_surf_scratch` dict instead of allocating one per
> contact per tick; (b) `car._resolve_drive_inputs()` fills and returns a reused
> `_inputs_scratch` dict instead of a fresh `{drive,brake_input,handbrake,declutch}`
> each tick; (c) `WheelParticles._emit_from_wheels()` iterates a cached
> `Drivetrain.all_wheels` (built once in `_init`) instead of allocating
> `front_wheels + rear_wheels` every tick. Behaviour-preserving (each scratch is
> read immediately by its sole/immediate caller); guarded green by the existing
> drivetrain/car/wheel-particle/smoke tests.

### Why
`scripts/drivetrain.gd step()` rebuilds a `contacts` array of ~10-key
dictionaries **every physics tick**, plus a `front_reaction_each` dict inside the
`SPIN_SUBSTEPS = 8` loop. Allocating dictionaries/arrays 60×/s on the main thread
adds GC pressure on low-end devices. The substepping itself is fine — it's the
per-tick allocation that's the smell.

### Plan
Preallocate the per-wheel contact structures once (max 4 wheels) and refill them
in place each tick; replace the per-contact `Dictionary` with fixed fields /
parallel typed arrays (`PackedFloat32Array` etc.), and hoist `front_reaction_each`
out of the substep loop (reuse one dict, or index by wheel slot). Behaviour
unchanged; only the allocations go away.

### Files
`scripts/drivetrain.gd`. Covered by the existing drivetrain/physics tests
(`tests/headless/`); they must stay green unchanged (this is a pure refactor).

### Risk
Low, but it touches the tire model — rely on the existing physics tests as the
guard (per `CLAUDE.md`, a previously-green physics test failing means the
refactor changed behaviour).

## 9. Post-process back-buffer copy (awareness)

`shaders/ps1_post_process.gdshader` uses `hint_screen_texture`, forcing a
full-screen framebuffer grab every frame on GL Compatibility — one extra
full-screen bandwidth round-trip per frame. **Cheap at 480×360**, so this is
*awareness, not an action item*: if the post-process ever shows up on the `P`
overlay's render-gpu line, the alternative is rendering the scene to a
`SubViewport` and doing the dither as a single blit instead of a back-buffer
copy. Low priority; the current cost is small.

## 10. HUD per-frame string allocation (minor)

`scripts/hud.gd:_process` (`:39`) rebuilds ~6 label strings every frame
(`"%d km/h"`, `"%d rpm"`, etc.) even when the values are unchanged → small
per-frame GC. Cache the last numeric values and only re-format / re-assign
`.text` when they change. Minor; do it alongside other cleanup.

## 11. `downforce_readouts` allocated when debug is off (minor)

`scripts/car.gd:146-149` builds the nested `downforce_readouts` array **every
physics tick even when the wheel-force overlay is off** (it's only consumed by
`WheelForceDebug`, which already early-outs when hidden,
`wheel_force_debug.gd:64`). Guard the array build behind
`cfg.debug_wheel_forces` so the shipped game doesn't allocate it. Tiny win, near-
zero risk.

## 12. Scaled HeightMapShape3D collision (minor / awareness)

`scripts/terrain_chunk.gd:22` scales the `CollisionShape3D` node as the
cell-size workaround for `HeightMapShape3D`. Scaling collision shapes is
discouraged with Jolt (per-contact transform cost / precision). Acknowledged in
the code comment; only worth revisiting if `cpu physics` on the `P` overlay
points at terrain contacts after items 3 and 8. Low priority.

---

## Already done right (do not chase these)

- The wheel-force debug overlay early-outs when hidden
  (`wheel_force_debug.gd:64`) — no cost in the shipped game.
- Wheel lists are cached (`drivetrain.gd` `rear_wheels`/`front_wheels`,
  `car.gd` `_any_wheel_airborne`), not `find_children`'d per frame.
- Terrain generation is threaded with a per-frame integration cap
  (`MAX_INTEGRATIONS_PER_FRAME = 1`) and a synchronous fallback already exists.
- The web export's threading headers are correctly configured (`serve_web.sh`,
  `export_presets.cfg`) — the open question in item 7 is *whether to use threads
  at all* on the oldest devices, not whether they're set up right.

---

## Suggested implementation order

1. **Item 4** (frame cap) — one line, immediate thermal win, zero risk.
2. **Item 1** (mipmaps + LOD bias) — cheap, safe bandwidth win.
3. **Item 6** (engine-audio CPU) — biggest pure-CPU win; mostly the `pow`
   precompute, behaviour-preserving with a test.
4. **Item 7** (threaded-export decision) — gates whether the game boots at all on
   the oldest devices; decide early, it shapes the terrain-gen work.
5. **Item 2** (foliage CPU cull + visible cap) — biggest GPU win.
6. **Item 3** (collision box cull) — biggest physics win; shares item 2's bins.
7. **Item 8** (physics-tick allocations) — refactor, guarded by existing tests.
8. **Items 10–11** (minor allocations) — fold into the above cleanups.
9. **Items 5, 9, 12** — only after the `P` overlay shows residual cost in their
   area; most likely skipped.

## Cross-cutting: inherently low-end, no quality tiers
There is no quality-profile switch. Items 1–4 each add a `GameConfig` knob, but
each knob holds **one shipped value** — the lean one — that every device runs.
Set the aggressive defaults directly in `config/game_config.tres`
(`trees_per_turn`↓, `tree_render_distance_m`↓, `max_visible_billboards` capped,
`texture_lod_bias`↑, `target_fps=30`). The knobs exist for tuning that single
value and for dev/debug, not for branching between a "high" and "low" path. If a
future device proves too weak, lower the shipped defaults further — do not add a
tier system. This matches the config-first architecture
(`features/configuration.md`).
