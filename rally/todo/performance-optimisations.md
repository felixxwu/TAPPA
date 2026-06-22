# Performance Optimisation Spec — mobile / low-end devices

> Status: **planned, not yet implemented.** This document is the implementation
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

- [ ] **Create low-poly 3D models of the trees and foliage** (Blender → `.glb`,
      like `blender/mx5.glb`) so the alpha-cutout billboards can ultimately be
      **swapped for solid opaque meshes** in the game. This is a prerequisite for
      the "opaque low-poly meshes" direction under item 2 — the code can't be
      verified in-engine until the models exist. Owner: Felix. See
      [item 2 → Alternative direction](#alternative-direction-opaque-low-poly-meshes-instead-of-cutout-billboards).

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

The five items below are ordered by expected impact on old phones:
**(2) and (3) — foliage draw + collision — are the biggest wins; (1) and (4)
are cheap and safe; (5) is mostly an advisory "probably don't".**

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
- `textures/bush.webp.import`: verify (expected same as tree — mipmaps off).

### Plan
1. Set `mipmaps/generate=true` in `textures/tree.png.import` and
   `textures/bush.webp.import`. Re-import (delete `.godot/imported/` entries or
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
`textures/tree.png.import`, `textures/bush.webp.import`,
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

> **⚠️ REMINDER — ASSET WORK NEEDED (Felix):** before this can land, I need to
> **create low-poly 3D models of the trees and foliage** (e.g. a faceted
> pyramid/cone canopy + trunk for trees, a small opaque blob for bushes) in
> Blender and export them as `.glb`, the same way the MX-5 body already lives in
> `blender/mx5.glb`. The eventual goal is to **swap the alpha-cutout billboards
> out for these solid meshes** in the game. None of the code work below can be
> verified in-engine until those models exist.

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

## Suggested implementation order

1. **Item 4** (frame cap) — one line, immediate thermal win, zero risk.
2. **Item 1** (mipmaps + LOD bias) — cheap, safe bandwidth win.
3. **Item 2** (foliage CPU cull + visible cap) — biggest GPU win.
4. **Item 3** (collision box cull) — biggest physics win; shares item 2's bins.
5. **Item 5** — only after profiling with the `P` overlay shows residual physics
   cost; most likely skipped.

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
