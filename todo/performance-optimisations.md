# Performance Optimisation Spec — mobile / low-end devices

> **Status: mostly landed; this file is the remainder.**
> **`todo/mobile-web-performance.md` supersedes this document for prioritisation** —
> it holds the current measurements and the live queue. Everything below is what is
> still open here.
>
> Landed and removed from this spec: **item 1** (texture mipmaps everywhere +
> `GameConfig.texture_lod_bias`), **item 4** (three-way frame cap — `target_fps` 60
> desktop / `target_fps_mobile` 60 / `target_fps_web` 30), **item 6.1–6.4** (engine-audio
> DSP: hoisted per-harmonic `pow`, no per-frame scratch allocation, `engine_harmonics=3`,
> and the load-indexed **voice wavetable**, 3.4×–8.1× on the voice and constant in
> cylinder count), **item 7** (web export **DECIDED single-threaded**,
> `variant/thread_support=false`), **item 8** (physics hot-path allocation churn),
> **items 10/11** (HUD label string caching, `downforce_readouts` guarded behind the
> debug overlay), the **carve/cliff distance-field rewrite** (carve 11.0 s → ~4.6 s),
> the chunk-precompute trims, and the terrain **prebaked finest LOD**
> (`GameConfig.terrain_lazy_finest_lod = false`; frame p99 11.03 → 4.52 ms,
> `spikes>28ms` 1 → 0, for +25.6 MB VRAM). The measurement history for all of it lives
> in git and in `features/terrain.md` / `features/rendering.md` /
> `features/engine-audio.md`.
>
> **The foliage work (items 2 + 3) is the biggest remaining win**, and its
> billboard-vs-mesh question is now answered: the pipeline is a **split** — trees are
> opaque billboard cutouts (`BillboardField`, silhouette baked into geometry via
> `tree_silhouette.gd`), bushes are opaque low-poly meshes binned into per-cell
> MultiMeshes with `visibility_range_end` fade (`TreeMeshField`). Both are opaque, so
> early-Z/HSR stays on. What is still open is the **per-frame view-cone cull +
> `max_visible_billboards` cap** and the **collision-box cull**.
>
> **Design principle: the game is _inherently_ low-end.** There is no "low quality"
> profile or toggle — the aggressive values are simply the defaults, the only mode the
> game ships. `GameConfig` knobs exist for tuning that single shipped value (and for
> dev/debug), NOT to switch between a "high" and "low" path. Do not add a quality-tier
> switch. Follow the config-first convention: every new tunable goes in `GameConfig`
> (`scripts/game_config.gd` + `config/game_config.tres`), never hardcoded; update the
> relevant `features/*.md` doc and add tests in the same piece of work.


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
- Terrain: `CHUNK_M = 50`, `CELL_M = 1.0`, `SAMPLES = 51`, `RADIUS = 3` →
  **7×7 = 49 loaded chunks** (`scripts/terrain_manager.gd:14`), matching what
  `features/terrain.md:22` already correctly says. (An earlier version of this
  doc claimed `RADIUS=1`/3×3 and said the `features/*.md` "5×5"/49-chunk figure
  was wrong — that claim was itself stale; `RADIUS=3`/7×7/49 is correct.)

Items 2, 3 and 5 below are the **GPU / fill / render-side** work; items 6–12 (in the
**CPU & platform** section further down) are the pure-CPU and platform costs the PS1
look can't touch. Of the GPU items, **(2) and (3) — foliage draw + collision — are the
biggest wins; (5) is mostly an advisory "probably don't".** Item numbering is kept from
the original spec, so the gaps are the sections that have landed. See the order at the
end.

---
---

## 2. Spatial + view-cone culling of trees/bushes; max visible instance count

### Why
`scripts/billboard_field.gd:build()` creates a `MultiMesh` with
`mm.instance_count = positions.size()` and **never sets
`visible_instance_count`** (confirmed: no `visible_instance_count` /
`custom_aabb` / `VisibilityRange` anywhere in `scripts/`). So all ~6,000 tree +
~6,000 bush quads are vertex-processed and rasterized **every frame**. The
distance cull in `shaders/billboard_opaque.gdshader fragment()` is a per-fragment
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

## 5. Heightmap-terrain collision culling — ADVICE (likely NOT worth it)

> **2026-07 update: superseded.** The terrain deep-dive found terrain is the
> dominant per-frame GPU cost (~93% of primitives — ~125k of ~134k tris, uniform
> 1 m cells over a 5×5 ring). The structural fix is a distance-scaled prebaked
> LOD field. That work has since LANDED and its spec was retired — the shipped
> design (5 LOD levels, `TerrainLod.build_all`/`build_levels_from`, the coarse vs
> full cache split, lazy finest level) is documented in
> [`features/terrain.md`](../features/terrain.md). It folded "collision on the
> near band only" into itself and retired `DistantTerrain`. The
> advice below (don't cull heightmap collision in isolation) still holds; the LOD
> spec is the right home for the terrain work now.


The request: spatially cull the heightmap collision to just the 1–2 chunks the
car is over, and/or shrink `CHUNK_M` while raising `RADIUS` to keep the same
rendered area but reduce the collision surface per body.

### Recommendation: **don't do this first; it's low/negative ROI.** Reasoning:

1. **49 chunks have collision today** (`RADIUS=3`, 7×7). Each is a
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

Items 2/3/5 are about the GPU / fill / render-side cost. The items below are
**pure CPU and platform** costs that run every frame regardless of the graphics
style — i.e. the PS1 look does nothing for them, which is the crux of the
original "looks retro ⇒ runs on old phones" theory: the aesthetic only addresses
the GPU side, and several of the real old-phone bottlenecks are here.
**Item 6 (audio) is the one that genuinely moves the needle for old phones; item 7,
the threaded-export decision, has since been decided — single-threaded.**

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
### Plan — remaining step

5. **Optionally decouple the fill from the render frame.** Steps 1–4 have shipped
   (see the header). What is left is filling the `AudioStreamGenerator` from a thread
   / on an audio cadence rather than `_process`, so a slow render frame can't underrun
   the buffer. **Note:** the shipped web build is single-threaded, so a true audio
   thread isn't available there — on web the levers are the shipped steps plus keeping
   main-thread frames short. Heavier change; do only if a real device still crackles.

### Files
`scripts/engine_audio_synth.gd`, `scripts/engine_audio.gd`,
`scripts/game_config.gd` + `config/game_config.tres`, `features/engine-audio.md`.

## 9. Post-process back-buffer copy (awareness)

`shaders/ps1_post_process.gdshader` uses `hint_screen_texture`, forcing a
full-screen framebuffer grab every frame on GL Compatibility — one extra
full-screen bandwidth round-trip per frame. **Cheap at 480×360**, so this is
*awareness, not an action item*: if the post-process ever shows up on the `P`
overlay's render-gpu line, the alternative is rendering the scene to a
`SubViewport` and doing the dither as a single blit instead of a back-buffer
copy. Low priority; the current cost is small.
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
- The web export's threading configuration is settled (`serve_web.sh`,
  `export_presets.cfg`): the build ships **single-threaded**, so it needs no
  `SharedArrayBuffer` / cross-origin isolation.

---

## Suggested order for what's left

1. **Item 2** (foliage view-cone cull + visible cap) — the biggest GPU win.
2. **Item 3** (collision-box cull) — the biggest physics win; shares item 2's bins.
3. **Item 6 step 5** (decouple the audio fill) — only if a real device still crackles.
4. **Items 5, 9, 12** — only if the `P` overlay shows residual cost in their area;
   most likely skipped.
