# Terrain LOD — distance-scaled, prebaked, skirt-seamed

> **Status: IMPLEMENTED, 2026-07-14/15.** Shipped: engine-driven
> distance LOD via prebaked decimated meshes + `visibility_range` HARD cutoffs
> (the dithered fade is unsupported on the Compatibility renderer AND its
> alpha-hash discard would defeat early-Z — see §5), downward skirts,
> near-band-only collision. **5 LOD levels**
> (`LOD_STRIDES = [1,2,5,10,25]` → 1/2/5/10/25 m cells) and **`RADIUS = 3`**
> (7×7 = 49-chunk ring, ~175 m reach) so the far ring reaches a horizon cheaply.
> Bands currently `[50,70,90,130]` (near-detail-favouring; tune via
> `terrain_lod_bands_m`). **Deviation from the plan
> below: `CHUNK_M` kept at 50 (not 32).** Reasons: (a) the tri-reduction win comes
> from LOD decimation, not chunk size — identical either way; (b) prebaking LOD
> meshes at load is the project's philosophy, and 32 m tripled the corridor chunk
> count (~204 → ~660), pushing terrain memory ~46 → ~90 MB and lengthening load —
> bad on the low-RAM devices this targets; (c) 50 decimates cleanly at strides
> that divide it (1/2/5/10 m cells, `TerrainLod.LOD_STRIDES`), so power-of-2 isn't
> needed for clean decimation. 32 m's only lost benefit was finer LOD granularity,
> which the crossfade + fog hide. The 32 m partition remains a *measured* follow-up
> if wanted. Files: `scripts/terrain_lod.gd` (new), `scripts/terrain_chunk.gd`,
> `scripts/terrain_manager.gd`, `scripts/game_config.gd`, `scripts/world.gd`,
> `tests/headless/test_terrain_lod.gd` (new). `DistantTerrain` NOT retired yet (it
> is already disabled via `distant_terrain_enabled = false`); retiring the code is
> deferred cleanup. Config tunables: `terrain_lod_bands_m`, `terrain_lod_fade_m`,
> `terrain_lod_skirt_m`, `terrain_collision_ring`.
>
> ORIGINAL DRAFT SPEC below (32 m plan). Brainstormed with Felix
> 2026-07-14. This is the headline structural GPU win from the performance deep
> dive: terrain is ~93% of every frame's primitives (~125k of ~134k tris,
> windowed benchmark), because the 5×5 = 25-chunk ring is tessellated at a
> uniform 1 m cell (`CELL_M = 1.0`, `SAMPLES = 51`, 5,000 tris/chunk) even though
> the heightfield's finest real feature is a 15 m wavelength
> (`config/game_config.tres:40-45`: 300 m/30 m, 40 m/0.5 m, 15 m/0.5 m). The PS1
> look made fill and shading cheap but did nothing for **vertex throughput**,
> which is now the bottleneck on the weak/mobile GPUs the project targets.
>
> Supersedes `todo/performance-optimisations.md` item 5 (heightmap collision
> culling — folded in here as "collision on the near band only") and the retired
> `DistantTerrain` backdrop.

## Goal

Aggressive, continuous-feeling, distance-scaled terrain LOD that:
- cuts terrain from ~125k tris/frame to ~40–55k,
- costs **~nothing per frame** (LOD is selected by band-crossing, like chunk
  streaming — never a per-frame mesh rebuild),
- reaches the fog horizon on its own so **`DistantTerrain` can be retired**
  (which also permanently fixes the coarse-backdrop-clips-through-dips bug that
  made Felix disable it — `distant_terrain_enabled = false` today),
- adds no vertex shader (the terrain shader deliberately has no `vertex()` stage;
  folding one in was a documented mobile regression — see `features/rendering.md`
  → `ps1_models.gdshader`).

## Why NOT literal per-quad / Nanite

Nanite is GPU-driven cluster selection with mesh shaders + a prebuilt hierarchy —
none of which exist on GL Compatibility (no compute, no mesh shaders). Emulating
"a 1 m quad collapses to 2 m the instant it passes a distance" on the CPU would
mean re-emitting a chunk's `ArrayMesh` on threshold crossings — and building the
mesh is the single most expensive terrain op we have (~6.7 ms/chunk,
`compute_chunk_data`, benchmark). That would convert a vertex-bound game into a
CPU-bound one on exactly the hardware we're protecting. The felt result Felix
wants is delivered instead by **prebaked discrete LOD levels selected by
distance**, below.

## Design (decisions locked with Felix)

### 1. Smaller chunks = the LOD granularity unit — POWER OF 2
Shrink `CHUNK_M` to a **power of 2: 32 m** (down from 50 — TUNABLE, put in
`GameConfig`). The chunk *is* the LOD unit: more chunks over the same area →
finer distance granularity, with no second spatial structure (no sub-tile
quadtree). This is coherent because heights/road/cliffs are keyed by **global
vertex index** (`terrain_chunk_builder.gd:129` `coord.x * per_edge + xi`,
`road_blend`/`cliff_offsets` dicts keyed by `Vector2i` global vidx) — shrinking a
chunk just repartitions the same global grid.

**Why power of 2.** With `CELL_M = 1 m` at L0, cells-per-edge = `CHUNK_M`, and LOD
decimation halves that count per level — so it must be even at every level to land
on integer vertices. 32 halves cleanly to a single quad: 32→16→8→4→2→1 (cell
sizes 1/2/4/8/16/32 m, six levels). A non-power-of-2 like 25 can't decimate
(25→12.5 has no integer vertex). `SAMPLES = 33`, `per_edge = 32`.

**Why 32 over 16.** Draw calls = number of *visible* chunks = `area / CHUNK_M²`,
and **LOD does NOT reduce this** (it cuts tris-per-chunk, not chunk count). So
chunk size is the knob that controls the draw-call cost of reaching the fog
horizon. Reaching a ~250 m horizon through a forward chase-cam frustum: **32 m ≈
60–80 visible chunks** (total draws stay near today's `draws 69`); **16 m is 4× ≈
250–300**, which is where GDScript→`RenderingServer` submit starts to bite on the
weakest phones. 16 m buys almost nothing visually — near the car every chunk is
L0 (1 m cells) regardless of chunk size, so up-close detail is identical; 16 m
only makes mid-distance LOD transitions step at finer intervals, and those are
already hidden by the dither crossfade + fog. Not worth 4× the draw calls.
32 m L0 = 33×33 = 2,048 tris/chunk (vs 5,000 at 50 m); far bands collapse to a
couple of tris each. Keep an eye on visible chunk count on-device; 32 m is the
recommendation, not a locked number.

### 2. Prebaked LOD levels per chunk (cells coarsen with distance)
The corridor is already fully precomputed at load into `_chunk_cache`
(`terrain_manager.gd`, bounded by the reset leash). Extend the precompute to bake
each chunk at several resolutions:
- **L0 = 1 m** cells (full detail)
- **L1 = 2 m**
- **L2 = 4 m**
- **L3 = 8 m**

A coarse level is L0 subsampled every 2ⁿ-th **global** vertex (see
`terrain_chunk_builder.gd:_vertex_row` — sample stride instead of every cell), so
it reads the same baked road/cliff heights, just fewer of them. Baked per-vertex
light (`_lights` / `_light_from_neighbours`) is likewise subsampled/re-baked at
the coarse stride so shading stays consistent. Building a coarse level is a cheap
decimation of the L0 pass.

For 32 m chunks: L0 = 33×33 = 2,048 tris, L1 = 17×17, L2 = 9×9, L3 = 5×5, and the
furthest levels collapse to 3×3 / 2×2 (a couple of tris). A far chunk is a handful
of tris — its only real cost is the draw call.

**Memory:** keeping all 4 levels for every corridor chunk is ~1.34× the L0-only
cache (46 MB → ~60 MB). Acceptable; the car can reach anywhere so we can't drop
L0 for "always-far" chunks. Revisit if a target device is RAM-bound — could
generate coarse levels lazily by decimation on first far-display.

### 3. Runtime LOD selection = band-crossing, not per-frame
Pick each chunk's level from its distance to the camera (XZ), in bands
(`lod_band_m` array in `GameConfig`, e.g. `[near→L0, mid→L1, far→L2, horizon→L3]`
— TUNABLE). Selection updates only when the camera crosses a band boundary for a
chunk — mirror the existing `_reconcile` / `update_focus` pattern
(`terrain_manager.gd:826-871`), which already early-returns unless the focus
crosses a chunk. Applying a level = swap the chunk's shown mesh (or toggle among
prebuilt per-level `MeshInstance3D`s) — a reference swap, ~free. **No per-frame
mesh build, ever.**

Ring extends to the fog horizon (bands go out much further than today's 125 m
because far bands are nearly free). Once it reaches the horizon, delete the
`DistantTerrain` node/build (`world.gd:371-378`, `scripts/distant_terrain.gd`) and
its `GameConfig` block.

**Frustum culling is already active — don't count on it for more.** Godot
frustum-culls every `VisualInstance3D` automatically; the ~60–80 visible-chunk
budget above is ALREADY the post-cull number (the surrounding square is ~240
chunks — the rest are culled for free). Two consequences:
- Frustum culling still costs a **per-node AABB test every frame**, so we must NOT
  instantiate the whole precomputed corridor as nodes. Keep a **bounded moving
  window** of instantiated chunk nodes around the car (stream in/out via the
  existing `_reconcile`/`update_focus` pattern, `terrain_manager.gd:826-871`) and
  assign LOD within it. This bounds draw calls AND cull-traversal cost; frustum
  culling then trims the window to the visible front.
- The window ring radius (in chunks) is a `GameConfig` tunable, sized so its outer
  edge reaches the fog horizon at the coarsest LOD.

### 3a. Far-band mesh merging (optional draw-call lever, only if needed)
Frustum culling is maxed, so the remaining draw-call reducers are chunk size
(done: 32 m) and **merging far coarse chunks into one mesh**. At the furthest
bands a chunk is 2–8 tris; submitting each as its own draw is wasteful. Bake an
N×N block of far chunks into a single merged mesh → 1 draw call instead of N²
(the clipmap trick). Adds bake/bookkeeping complexity; implement ONLY if on-device
draw counts at 32 m are too high. Occlusion culling (`OccluderInstance3D`, hills
hiding valleys) is a further option but carries its own per-frame CPU cost — treat
as last resort.

### 4. Seams = skirts (Felix's call)
Adjacent chunks at different LOD crack apart. Fix with **skirts**: a vertical
wall dropped a few metres down along each chunk's 4 edges, sharing the edge
vertices, so the crack is covered by geometry from behind. Invisible under fog,
very PS1, no neighbour-awareness needed (unlike edge-stitching). Skirt depth =
`terrain_lod_skirt_m` (TUNABLE). Cheap: 4 edges × ~edge-vertex-count quads per
chunk.

### 5. Pop-hiding = HARD cutoff (dither fade unavailable on Compatibility)

> **IMPLEMENTED AS HARD CUTOFF.** The plan below assumed a dithered
> `visibility_range` crossfade, but that fade is a **Forward+/Mobile-only**
> feature — the **Compatibility renderer this game ships ignores it and hard-cuts
> regardless**. It's also undesirable: the fade is an alpha-hash `discard` that
> defeats early-Z on tile GPUs (the exact tax the opaque terrain avoids). So
> terrain uses `VISIBILITY_RANGE_FADE_DISABLED` (hard cutoff). The pop is small
> and hidden by construction: coarse levels are exact subsamples (shared vertices
> don't move), terrain is gentle, fog softens distance, skirts cover cracks, and
> popping LOD is on-aesthetic for PS1. The `terrain_lod_fade_m` knob was removed.

Original plan (not used):
Since there's no vertex stage to morph in, hide the level pop with the engine's
`visibility_range` **dither crossfade** — the exact mechanism the foliage already
uses (`VISIBILITY_RANGE_FADE_SELF`, see `features/rendering.md` → Shared render
distance). At a band boundary, crossfade the outgoing and incoming level meshes
over a `terrain_lod_fade_m` band. No shader change.

### 6. Collision on the near band only
Today all loaded chunks get a `HeightMapShape3D` (`terrain_chunk.gd:45-53`). With
the LOD field, give collision **only to the innermost L0 chunks** — the ones the
car can contact within a frame (keep-radius comfortably > car + braking distance
per cull tick, like the tree-collision plan). Coarse/far chunks are render-only.
This removes the physics-body growth that made "just shrink `CHUNK_M`" a bad idea
before (`todo/performance-optimisations.md` item 5), turning smaller chunks into
a net win. Collision always uses L0 heights (never a decimated level) so the car
never catches air on a coarse edge. `terrain_collision_radius_m` — TUNABLE.

## Expected result
- Terrain: ~125k → ~40–55k tris/frame.
- Per-frame runtime cost: ~unchanged (band-crossing swaps only).
- Load time + cache: coarse levels are cheap to bake; net load roughly flat,
  memory ~+34%. Retiring `DistantTerrain` removes its build + its tile draws.
- `DistantTerrain` clipping bug: gone (one LOD'd surface, no second mesh).

## Files (grounded in current code)
- `scripts/terrain_manager.gd` — `CHUNK_M`/`CELL_M`/`SAMPLES`/`RADIUS` consts
  (`:11-14`), precompute/`_chunk_cache`, `_reconcile`/`update_focus`
  (`:826-871`), collision radius gating.
- `scripts/terrain_chunk_builder.gd` — add coarse-stride level builds
  (`_vertex_row` `:121`, `_halo_row`/light `:104-138`, `data()`/index gen `:78`).
- `scripts/terrain_chunk.gd` — per-level meshes / mesh swap, skirts,
  `visibility_range` fade, collision-only-on-near.
- `scripts/distant_terrain.gd` + `world.gd:371-378` + `GameConfig`
  `distant_terrain_*` — **delete** once the ring reaches the horizon.
- `scripts/game_config.gd` + `config/game_config.tres` — new tunables:
  `CHUNK_M` (or a config mirror), `terrain_lod_band_m`, `terrain_lod_fade_m`,
  `terrain_lod_skirt_m`, `terrain_collision_radius_m`.
- `features/terrain.md`, `features/rendering.md` — update.
- `benchmark/perf_benchmark.gd` — already measures prims/draws; expect the
  terrain prim count to drop.

## Tests (per CLAUDE.md — test logic, not tuned values)
- Coarse level subsamples the SAME global heightfield: a decimated level's shared
  vertices equal the L0 heights at those global indices (bit-identical), incl.
  road/cliff offsets. Mirror `test_incremental_build_matches_full_build`.
- LOD selection is pure: `(chunk_center, cam_pos, bands) → level` — factor to a
  static fn, assert band boundaries + monotonic (nearer ≤ level index). No
  viewport needed.
- Collision present only within `terrain_collision_radius_m`; crossing a chunk
  updates the set (assert via `PhysicsServer3D.body_get_shape_count` / shape
  presence). Collision heights come from L0.
- Skirt geometry exists on every chunk edge (or the crack test: no gap at a
  fine/coarse boundary within tolerance).
- Keep the full-generation smoke (`test_smoke.gd`) green.

## Open questions / tunables to settle on-device
- Final `CHUNK_M` (25 m candidate) — balance LOD granularity vs draw-call count.
- LOD band distances + number of levels (3 vs 4) and fade width.
- Skirt depth.
- Whether to prebake all levels vs decimate-on-demand if RAM-bound.
- Real mid/low-end device pass to confirm the draw-call count at the chosen chunk
  size is acceptable.
