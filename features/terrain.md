# Terrain

**Source:** `scripts/terrain_manager.gd` (`@tool extends Node3D`,
`class_name TerrainManager`), `scripts/terrain_chunk.gd`
(`@tool extends StaticBody3D`, `class_name TerrainChunk`),
`scripts/terrain_layer.gd` (`@tool class_name TerrainLayer`).

**Tests:** `tests/headless/test_terrain.gd`, `tests/headless/test_terrain_noise.gd`, `tests/headless/test_terrain_cliffs.gd`, `tests/headless/test_terrain_lod.gd`, `tests/headless/test_terrain_memory.gd`

Procedurally generated rolling terrain from stacked Perlin noise. The terrain is
**infinite in theory**: `height_at(x, z)` is a pure function of absolute world
coordinates, so any point in the world has a defined height. Only the car's
immediate surroundings are ever built — a moving 7×7 grid of chunks that loads
and unloads as the car drives. `@tool` means chunks also regenerate live in the
editor (centred on the origin, since there is no car there), and config drives
the manager at runtime via `world.gd`.

## Dimensions

- `CHUNK_M = 50.0` — each chunk is 50×50 m.
- `CELL_M = 1.0` — 1 m grid cells (low-poly PS1 terrain; quarter the triangles
  and collision samples of the old 0.5 m cells).
- `SAMPLES = 51` — 51×51 height vertices per chunk (`CHUNK_M / CELL_M + 1`).
- `RADIUS = 3` — a (2·RADIUS+1)² = **7×7** ring of chunks is kept loaded around
  the car (~350 m span, ~175 m reach). The far chunks are cheap because of LOD
  (see below), so the ring reaches a horizon at low triangle cost. Chunks are
  precomputed at level load and pulled from cache as the car approaches each
  boundary.

## TerrainManager

Owns all terrain state and the chunk lifecycle.

- `noise_seed: int` — deterministic; changing it rebuilds loaded chunks. **Driven
  from the per-event `track_seed`** by `world.gd` (was a fixed 1337), so each event
  has its own landscape — and its own lake layout (see [lakes.md](lakes.md)).
- `layers: Array[TerrainLayer]` — each layer is a (`wavelength_m`,
  `amplitude_m`) pair. Defaults set in `_default_layers` on `_ready` if empty.
  `world.gd` (re)builds this from `cfg.terrain_layers()` whenever it changes
  (`WorldRuntime.layers_match` guard, shared by `world.gd` and `overworld.gd`), so the hill shape follows the live config.
  **Per-event override:** an event may set any of the 6 flat keys
  `terrain_layer{1,2,3}_{wavelength,amplitude}` to reshape its hills; omitted
  keys fall back to the authored `GameConfig` global default (never to a prior
  event's override — see `RallySession.apply_event_config`, [rally-session.md](rally-session.md)).
- `texture_tile_per_meter: float` — UV tiling for the ground texture (the road
  texture tiles independently via `road_tile_per_meter`, applied as the shader's
  `road_uv_scale`; see [rendering.md](rendering.md)).
- `chunk_material: Material` — applied to every chunk mesh (set to the shared
  floor material in `main.tscn` so it survives runtime mesh assignment).
- `focus_path: NodePath` — the node whose position drives loading (the car,
  `../Car`). Empty in tests so the focus is driven explicitly. `_focus_node()`
  runs every rendered frame, so the resolved node is **cached** (`_focus_cached`,
  invalidated by the `focus_path` setter and by `is_instance_valid`) — a
  `get_node_or_null()` scene-tree walk per frame is the pattern this project bans
  on low-end mobile (same fix as `engine_audio.gd`'s resolved-once car/engine refs).
- `load_radius: int` — the **live** ring radius in chunks; `(2*load_radius+1)²` chunks
  are spawned around the focus. Defaults to the `RADIUS` const (3 → 7×7 = 49), which is
  what every stage uses. It used to *be* that const, read directly by `target_coords`,
  `_corridor_margin`, `detail_ring` and `_reconcile`; all of them now read the field so
  the open world can raise it. Cost is quadratic — see
  [Open-world mode](#open-world-mode-the-overworld).

Key methods:

- `height_at(x, z)` / `light_at(x, z)` — **cache-first**: bilinear-sample the
  cached chunk grid (`_cached_height_at` / `_cached_light_at`) when the point
  falls inside the precomputed corridor — this is flattening-accurate (it
  matches the actual `HeightMapShape3D` collision the car drives on, road
  bake included), not just the raw noise. Outside the corridor (editor, tests
  without a precompute, or the `DistantTerrain` margin beyond it) they fall
  back to the pure-noise sampler. `_noise_height_at` is the internal pure
  sampler (used by `bake_track` and the fallback — flattening is *derived
  from* it, so it must never read the cache itself). Uses a main-thread noise
  cache (`_ensure_noise_cache`, invalidated by `_rebuild_loaded`) so repeated
  spot samples don't rebuild the noises each call.
- `baked_height_at(x, z)` — **bake-field-first**, for the window `height_at` can't
  serve: after `bake_track` has run but before the chunk precompute has populated the
  cache. There, `height_at` silently falls back to pure noise — which is a trap, since
  the caller usually wants the *carved* ground. This reads `cliff_offsets` +
  `road_heights`/`road_blend` directly at the nearest L0 vertex, reproducing
  `TerrainChunkBuilder._sampled_height`. Vertex-nearest, not bilinear (its callers
  sample a coarse lattice anyway). Falls back to `height_at` once
  `free_load_only_data()` drops the bake fields. Used by the loading screen's and Seed
  Lab's water previews — see [lakes.md](lakes.md) → "Three water passes".
- `bake_args(cfg)` (static) — the `[width, transition_m, tarmac_fraction, tarmac_first,
  surface_feather_m]` tuple `bake_track`/`set_track` take, derived from a `GameConfig`
  in ONE place so every baker agrees. Both `world.gd`'s real carve and
  `baked_preview` go through it.
- `baked_preview(cfg, centerline)` (static) — a bare, off-tree `TerrainManager` baked
  for a centerline: layers/seed/cliff params seated from `cfg`, then `bake_track`. No
  chunks, no meshes, never added to the tree, so it costs the distance-field pass and
  nothing else. Exists so a preview with no run scene (the Seed Lab) can still sample
  cliff-accurate ground. Free it when done.
- `_build_noises()` / `_sample_height(noises, amplitudes, x, z)` — shared layer
  sampling. `_build_noises` returns a fresh `[noises, amplitudes]` pair; the worker
  path (`compute_chunk_data`, via `TerrainChunkBuilder`) builds its own (FastNoiseLite
  is shared mutable state), the main thread reuses the cached pair via
  `_ensure_noise_cache`/`_noise_height_at`. (There used to be a second, unused
  `build_heights(center)` height-grid builder duplicating `compute_chunk_data`'s
  math — deleted; it had no production caller, and the test that pinned it against
  `compute_chunk_data` was a circular oracle. That test now checks
  `compute_chunk_data`'s heights against `_noise_height_at` directly — see
  `test_terrain.gd` → `test_compute_chunk_data_shapes_and_heights`.)
- `chunk_coord_for(pos)` / `target_coords(center)` — integer chunk-grid math.
- `update_focus(pos)` — recompute the car's chunk coord and, when it changes,
  `_reconcile` the loaded set: free chunks outside the 7×7 ring, instantiate and
  `setup()` the missing ones. Called every frame from `_process`; cheap because
  it early-returns until the car crosses a chunk boundary.
- `corridor_coords(centerline, leash_m)` — the full set of chunk coords the
  runtime ring can ever request while the car stays within `leash_m` of the
  centerline (callers pass `Config.data.track_progress_max_dist_m`, the track-progress
  leash — see the note on the timed reset below): every centerline-sample chunk
  dilated by `RADIUS + ceil(leash_m/CHUNK_M) + 1`. Straight spans tessellate to
  just their endpoints, so segments are sub-sampled every `CHUNK_M/2` to avoid
  skipping interior chunks. Pure function of the track + config, used once at
  load to size the precompute (see Performance below).
- `set_corridor(coords)` / `cache_chunk(coord)` / `precompute_corridor(centerline,
  leash_m)` / `corridor()` / `has_cached(coord)` / `cache_size_mb()` /
  `corridor_bounds()` — the precomputed-cache API. `set_corridor` stores the
  coord list and clears `_chunk_cache`; `cache_chunk` computes and caches one
  coord; `precompute_corridor` does both synchronously for the whole corridor
  (used by tests and `_rebuild_loaded`, which must refill after a seed/layer
  change). `corridor_bounds()` is the world-XZ AABB of the cached coords —
  `world.gd` dilates it for the static `DistantTerrain` backdrop.

### What the cache keeps — and what is freed (memory)

The cache is the game's largest resident allocation, so most of what
`TerrainChunkBuilder.data()` produces is dropped again as soon as it has been
consumed (`todo/mobile-web-performance.md` 1.6 / 1.7 / 2.7):

- **Dropped immediately, in `cache_chunk`** — `vertices`, `uvs`, `colors`,
  `uv2s`, `indices` (`TerrainManager.DEAD_AFTER_PREBAKE`). `TerrainLod.build_all`
  has already turned them into GPU meshes, and nothing reads them off the cache
  again. They are ~5/6 of a full-res chunk's bytes.
  - **Hazard, handled:** `TerrainChunk.apply_data` has a fallback that rebuilds
    the LOD meshes from those arrays when `lod_meshes` is empty — correct for
    on-demand (editor/test) data straight out of `compute_chunk_data`, impossible
    for a cached dict. It now checks for `vertices` first and `push_error`s
    instead of building garbage (collision, which only needs `heights`, still builds).
- **Dropped on `load_finished`, via `free_load_only_data()`** (wired in `_ready`
  to the host's signal — see [loading.md](loading.md)):
  - `lights` on every cached chunk. Every `light_at` caller (`tree_mesh_field`
    bush tint, `distant_terrain` backdrop, `road_markings`) is a one-shot build
    that runs during generation, and the value is folded into the mesh vertex
    colours anyway.
  - `road_heights`, `road_blend`, `cliff_offsets` — read **only** by
    `TerrainChunkBuilder`, and gated on `corridor_complete()` so the editor /
    on-demand rebuild path (no corridor) keeps them. `track_weights` and
    `track_surface` are **kept**: `surface_at()` drives per-tick grip.
- **Kept forever:** `heights` (collision + `height_at`), `center`, `lod_meshes`,
  `coarse`, `grid_n`, `stride`, and — when the finest LOD level is deferred —
  `l0_light` (see **Lazy finest LOD level** below). `l0_light` is a deliberate
  *live* need, not load-only data: do not fold it into `free_load_only_data`.

**`cache_size_mb()` only sees the CPU side.** It sums `Packed*Array` values, so it
misses `lod_meshes` entirely — an `ArrayMesh` uploads to the RenderingServer the
instant `add_surface_from_arrays` runs, and the GPU-side buffers are the larger
half. `TerrainManager` therefore logs the real figure too, once the last corridor
chunk is cached: `terrain precompute vram: … MB total, … MB added by the prebake`
(from `Performance.RENDER_VIDEO_MEM_USED`; reads 0 in a headless run). Measured on
a free-roam stage (279 corridor chunks, desktop bands): **26.8 MB added by the
prebake with every level prebaked, 7.6 MB with the finest level deferred.**

Both frees would otherwise fail **silently** — `_cached_light_at` and a rebuilt
chunk would return plausible-but-wrong values — so each has a loud sentinel:
`_lights_freed` makes a post-free `light_at` `push_error`, and `_bake_fields_freed`
makes `_rebuild_loaded` `push_error` (its chunks would lose the road flatten).
Both latches track the **data, not the event**: a fresh `bake_track` clears
`_bake_fields_freed` and `set_corridor` clears `_lights_freed`, so a world
**regeneration** (`_generate_track` run again on a booted world — `load_finished`
has already latched and will not re-fire) is correct rather than permanently
poisoned. Covered by `tests/headless/test_terrain_memory.gd`.

- **Per-chunk resolution classification** (`corridor_coords` → `_classify_chunk`,
  `chunk_class(coord)`). As the corridor is built, each chunk is classed
  **full-res** or **coarse** by its nearest distance to the centerline (stored in
  `_corridor_class`, which survives `set_corridor`'s cache clear so `_rebuild_loaded`
  reproduces the split):
  - `full-res` — the chunk is inside the **collision band** (`_collision_band_chunks`
    = `collision_ring + ceil(leash/CHUNK) + 1`, sharing the corridor margin's `+1`
    leash-overshoot slop via the same derivation) **or** its closest-possible camera
    distance (`min_dist − leash − precompute_safety_slack_m`) can reach the finest LOD
    (`l_min == 0`). It gets the full `SAMPLES²` grid + all 5 LOD meshes + collision —
    exactly as before.
  - `coarse` — `cache_chunk` builds ONLY LOD levels `l_min..last` via
    `TerrainLod.build_levels_from`, each sampled directly at its own stride
    (`TerrainChunkBuilder(manager, coord, stride)`). No full-res grid, no collision,
    no cache-backed height/light (see below). This is the loading-screen precompute
    optimisation — the majority of corridor chunks are coarse. Toggle with
    `precompute_prune_enabled` (GameConfig).
  - The coarse cache entry carries only `{center, lod_meshes (nulls < l_min), coarse}`.
    `_resolve_bilinear` treats a coord with no full-res `heights` as "not covered", so
    `height_at`/`light_at` fall through to the live noise/`_bake_light` path there
    (visually identical: no road/cliff bake happens in coarse regions). `apply_data`
    builds the `HeightMapShape3D` only when full-res heights are present and asserts a
    grid-less chunk is `coarse` (the collision-band rule guarantees no coarse chunk
    ever enters `collision_ring`).
  - A **real-play cache miss** in `_reconcile` (cache populated, coord absent) leaves
    a **hole** — it spawns nothing rather than building on the fly (holes over
    hitches). Only an **in-corridor** miss (`_corridor_class` has the coord) is
    *logged*, once per coord (`_logged_misses`): that one is a real bug. A miss
    **outside** the corridor is a deep off-road excursion — expected now that the
    off-track reset is timed — and stays silent. The empty-cache editor/test path
    still builds on demand.

## TerrainChunk

One tile, created at runtime by the manager. Positioned at its chunk **centre**
`((cx+0.5)·CHUNK_M, 0, (cz+0.5)·CHUNK_M)` so the centred mesh and collision span
exactly the tile.

- Meshes — **one MeshInstance3D per LOD level** (`LOD0`…`LODn`), built in
  `apply_data`. Each level is a decimated copy of the same `SAMPLES²` grid (see
  **Terrain LOD** below); `LOD0` is full resolution. `ARRAY_COLOR` is per-vertex
  (Gouraud), so the road texture weight (alpha) blends smoothly across cells (see
  `vertex_colors`). UVs use **world** coordinates × `texture_tile_per_meter` so
  textures stay continuous across seams. Front faces wind clockwise. **No normals**
  — the floor shader is `unshaded`.
- Collision — a `HeightMapShape3D` (map_width/depth = `SAMPLES`), `CollisionShape3D`
  scaled to `CELL_M` cells (the standard workaround, since `HeightMapShape3D` has
  no cell-size property). Collision always uses the full-res `SAMPLES²` heights
  (never a decimated level), and is **enabled only on the near band** —
  `set_collision_enabled` is toggled by the manager so only chunks within
  `collision_ring` (Chebyshev, in chunks) of the car are live broadphase entries.
  `coarse` chunks (see per-chunk classification below) carry **no** heightfield at
  all — they can never enter `collision_ring`, so `apply_data` leaves their shape
  null; a grid-less chunk that is not `coarse` trips an assert.

### Terrain LOD (`scripts/terrain_lod.gd`)

Terrain is the dominant per-frame primitive cost (a uniform 1 m grid over the
loaded ring is far finer than the heightfield's 15–300 m feature wavelengths need
at distance). Each chunk carries one MeshInstance3D per level in
`TerrainLod.LOD_STRIDES` (`[1, 2, 5, 10, 25]` → 1/2/5/10/25 m display cells; the
strides divide `SAMPLES-1 = 50` so each coarse grid lands **exactly** on L0 vertices — a
pure subsample, so it can never disagree with collision or `height_at`). Each
level MeshInstance sets a `visibility_range` band (`terrain_lod_bands_m` far
cutoffs), so the **engine** selects the level by real camera distance every frame
at zero script cost. The cutoff is **hard** (`VISIBILITY_RANGE_FADE_DISABLED`): the
dithered visibility-range fade is a Forward+/Mobile feature the **Compatibility
renderer this game uses ignores** (it hard-cuts regardless), and the fade's
alpha-hash `discard` would defeat early-Z on tile GPUs — bad for our opaque
terrain. The level pop is small and hidden by construction: coarse levels are
exact subsamples (shared vertices don't move), the terrain is gentle, fog softens
distance, and seams between neighbouring chunks at different levels are covered by
a downward **skirt** (`terrain_lod_skirt_m`) appended to each level mesh. The coarser LOD meshes are **prebaked
at load** in `cache_chunk` (`TerrainLod.build_all`), so runtime chunk spawns stay
a cheap node build + mesh assign. **Every** level including the finest is prebaked by
default; deferring the finest one to an on-demand runtime build is an opt-in escape
hatch (see **Lazy finest LOD level** below). All tunables live in `GameConfig`
(`apply_terrain_lod`); `TerrainLod` is pure/static and headless-tested
(`tests/headless/test_terrain_lod.gd`).

**Mesh assembly is one shared function.** `build_level` (decimate from a full-res
grid), `mesh_from_grid` (mesh a grid that was already generated at its target
stride — coarse chunks), and `DistantTerrain._build_tile` (the backdrop's own
coarse grid) all triangulate an n×n vertex grid and assemble it into an
`ArrayMesh` identically, so the triangulation + `arrays[Mesh.ARRAY_*]` wiring
lives in exactly one place: `TerrainLod.grid_mesh(verts, uvs, colors, uv2s, n,
skirt_m) -> ArrayMesh` (plus its `TerrainLod.build_grid_indices(n)` helper for
the a,b,c/b,d,c triangle indices alone). Each caller only does its OWN sampling
loop and hands the resulting flat arrays to `grid_mesh`. `uv2s` empty means "no
UV2 channel" — `grid_mesh` writes `ARRAY_TEX_UV2` only when it's non-empty, and
skips the skirt entirely when `skirt_m <= 0.0` (the backdrop passes `0.0`: it
has its own sink instead, see "Fog & distant backdrop" below).

The band set is **per-target**: `world.gd._ready` picks it via
`GameConfig.terrain_lod_bands_for(web, touch)` — a web **touch** device (the low-end
/ 30fps target) gets the tighter `terrain_lod_bands_web_touch_m` (`[40,70,80,90]`, finer
levels dropped sooner), every other target the higher-quality `terrain_lod_bands_m`
(`[60,100,115,120]`, finer terrain held out to match the longer desktop foliage render
distance — see [rendering.md](rendering.md) → "Shared render distance"). The resolved
set is written back onto `cfg.terrain_lod_bands_m` **before** `apply_terrain_lod()`, so
the prebake reads the right one.

**Far chunks prebake fewer levels.** A chunk more than ~`leash + band` from the
racing line can never be viewed at the finer LOD levels (the car stays within the
progress leash the corridor is sized from), so `cache_chunk` prunes them for `coarse`
chunks: only levels
`l_min..last` are built, each sampled at its own stride by a strided
`TerrainChunkBuilder` (`TerrainLod.build_levels_from` → `mesh_from_grid`) instead of
decimating a full-res grid that was never generated. Because every channel (height,
UV, colour, tarmac, and lighting via ±1 m neighbour samples that include the cliff
offset) is a pure function of global coordinates, a strided build is bit-identical to
decimating the full-res grid — seams with full-res neighbours still match. See
`docs/superpowers/specs/2026-07-21-per-chunk-terrain-resolution-design.md` and the
per-chunk classification under **TerrainManager**; tests in
`tests/headless/test_terrain_resolution.gd`.

**Lazy finest LOD level** (`TerrainManager.lazy_finest_lod` /
`GameConfig.terrain_lazy_finest_lod` — **OFF by default since 2026-07-30, on every
target including web**; kept as the escape hatch for a device that runs out of VRAM).
Read the "Why it is off" note at the end of this section before turning it back on.
An `ArrayMesh` is resident VRAM from the moment
it is built, whether or not its chunk is one of the `(2·RADIUS+1)²` currently spawned —
so prebaking level 0 for the *whole corridor* (~280 chunks) to serve the handful that
can display it was the single largest avoidable GPU allocation at load. `cache_chunk`
now calls `TerrainLod.build_all(data, skirt, 1)`: levels 1…n are prebaked as before,
level 0 is left `null` and built per-chunk at runtime by `TerrainLod.build_finest`.

- **Nothing is lost.** Everything level 0 needs is either still cached or derivable:
  local vertices from `heights` (already road-flattened and cliff-offset), UVs from
  world XZ × `texture_tile_per_meter`, colours/UV2 from the retained `track_weights` /
  `track_surface`, indices from arithmetic. The one exception is the baked per-vertex
  light, kept as `l0_light` — the same values quantised to RGB8 (~1/5 the bytes, and
  invisible in an 8-bit framebuffer). `test_terrain_lod.gd` asserts the rebuilt level
  matches the prebaked one vertex for vertex.
  **UV2.y is the trap here**: refilling UV2 from `track_surface` writes UV2.**x** only, so the
  baked region rank came back as 0 and the rebuilt level 0 rendered as region slot A while the
  chunk's prebaked coarser levels (decimated from the full-res arrays, rank intact) rendered
  correctly — one chunk wearing two regions depending on camera distance. `build_finest`
  therefore re-runs `TerrainManager._apply_region_blend` on the rebuilt grid, exactly as the
  cache-rehydrate path does, and the rank is a pure function of position so the value is
  reproduced not approximated (`test_the_lazily_rebuilt_finest_level_keeps_the_region_rank`).
- **A detail ring, not the whole loaded ring.** `TerrainManager.detail_ring()` derives
  from the live tunables — a chunk at Chebyshev distance `d` is never closer than
  `(d−1)·CHUNK_M` to the focus, and the camera can be `precompute_safety_slack_m` from
  the focus, so level 0 can only matter while `(d−1)·CHUNK_M ≤ lod_band_ends_m[0] +
  slack`. Chunks leaving the ring drop the mesh and give the VRAM straight back.
- **Amortised, so it is not the stutter the prebake existed to prevent.** A full-res
  level-0 rebuild is ~5 ms of GDScript, and crossing a chunk boundary brings a whole
  column into the ring at once. `_detail_queue` holds them nearest-first and
  `_drain_detail_queue` builds `detail_builds_per_frame` (1) per frame;
  `flush_detail_queue()` builds them all at once behind the loading screen
  (`build_initial`). Latency is free here: a chunk enters the ring about a chunk-width
  outside level 0's band.
- **Why it is OFF by default (2026-07-30).** The amortisation above bounds the hitch to
  *one* rebuild per frame, but cannot make that rebuild cheap: it is a measured ~6.2 ms,
  of which ~67% is the 8 `track_weights`/`track_surface` dictionary lookups per vertex
  in `_vertex_color_row` / `_surface_uv2_row` across 51×51 vertices, ~24% `build_level`
  (arrays + `add_surface_from_arrays`), and the rest vertex/UV setup and
  `decode_lights`. Since a crossing queues a whole row, the cost lands as a sustained
  ~6 ms/frame burst after every crossing. Windowed A/B on the benchmark stage, same
  seed (see `todo/performance-optimisations.md` for the full breakdown):

  | | lazy ON | prebaked (default) |
  |---|---|---|
  | frame p99 | 11.03 ms | **4.52 ms** |
  | 1% low | 90.6 fps | **221.3 fps** |
  | `spikes>28ms` | 1 | **0** |
  | VRAM added by prebake | 9.5 MB | 35.1 MB |
  | RAM cache (peak) | 12.3 MB | **10.7 MB** |

  So prebaking costs ~+25.6 MB VRAM and *saves* ~1.6 MB RAM — `l0_light` exists only to
  feed a lazy rebuild, so prebaking drops it (`test_terrain_memory.gd` →
  `test_prebake_does_not_retain_the_lazy_rebuild_light`). Deliberately **not** gated per
  platform the way `terrain_lod_bands_for()` / `tree_render_distance_for()` are: web gets
  the smoothness win too. If a low-VRAM browser/device ever fails, flipping this flag
  back on is the single-line mitigation.
- **What it costs at load.** Prebaking level 0 for the whole corridor moves that work
  behind the loading screen, where it is paid once instead of mid-drive. `world.gd`'s
  precompute loop (`for coord in floor_tm.corridor(): floor_tm.cache_chunk(coord)`)
  yields only every 8th chunk, so on a ~350-chunk corridor the extra level-0 builds add
  roughly **1–2 s of load time** (a few ms per full-res chunk). This degrades
  gracefully — the loading screen keeps painting its chunk grid on each yield and there
  is no timeout to trip — but it is a real, deliberate trade: a one-off second or two of
  load in exchange for removing every mid-drive rebuild hitch. If load time ever becomes
  the binding constraint, lowering the yield interval spreads it more smoothly rather
  than reducing it.
- **An absent level 0 is never a hole.** `TerrainChunk._apply_level_bands` starts each
  present level's `visibility_range_begin` at the previous **present** level's cutoff,
  so when level 0 is missing (deferred *or* coarse-pruned) level 1 covers the near band
  itself. Worst case the ground is one LOD step coarser for a few frames.

**Debug overlay:** press **H** (`toggle_debug_arrows`, the shared debug key, debug
builds only) to toggle a Minecraft-style chunk-border grid
(`scripts/chunk_border_debug.gd`, `ChunkBorderDebug`). It outlines every loaded
chunk as a terrain-hugging line loop + corner posts, drawn through hills (no depth
test), colour-coded by role: **yellow** = the car's current chunk, **lime** = near
band with live collision (`collision_ring`), **sky blue** = render-only far
chunks. `TerrainManager` lazily creates it on first toggle and rebuilds it on
chunk crossings. (Note: H also toggles the wheel-force arrows — the same debug
key drives both.)

Because adjacent chunks sample `height_at` at the same world position on their
shared edge, seams match exactly with no stitching.

## Track overlay (road texture fade + flattening)

The generated track (see [track.md](track.md)) is drawn by cross-fading the
ground texture to a road texture (grass → gravel) and flattening the terrain
under the road — no extra geometry. Both blend smoothly from the flat road to
the true terrain across a transition band just outside the road edge, using
**weighted fields**. The per-vertex road weight is carried in the vertex-colour
**alpha** channel; the shader fades `albedo_texture → road_texture` by it (see
[rendering.md](rendering.md)). `default_cell_color` is a flat RGB ground tint
(white by default):

`road_heights`, `road_blend` and `cliff_offsets` are **load-only** — see *What the
cache keeps* above; `track_weights` / `track_surface` are resident for the whole run.

- `road_heights: Dictionary` — grid-vertex index (`Vector2i`,
  `coord.x*(SAMPLES-1)+xi`, shared across seams) → terrain Y at the vertex's exact
  perpendicular foot on the centerline (so the cross-section is laterally flat).
- `road_blend: Dictionary` — vertex index → height blend weight (1 on the road,
  ramping to 0 at the outer band edge; omitted where 0).
- `track_weights: Dictionary` — cell index → road blend weight (same ramp).
- `track_surface: Dictionary` — cell index → **tarmac weight** in `[0,1]` at the
  cell's nearest centerline point (0 = gravel, 1 = tarmac), feathered across the
  single gravel↔tarmac switch (`TrackSurface`, see [track.md](track.md)). Keyed
  like `track_weights`. Read by `surface_uv2` (baked into the mesh **UV2.x** so the
  shader fades the gravel texture → flat tarmac colour) and by `surface_at`.
- `surface_at(x, z) → Vector2` — `(road_weight, tarmac_weight)` at a world XZ
  (cell lookup; both 0 off any track). Pure, so the `@tool` script stays
  editor-safe; the drivetrain turns it into the per-wheel grip multiplier (see
  [drivetrain-and-tires.md](drivetrain-and-tires.md)).
- `smooth_ramp(d, inner, outer)` — the weight curve: 1 for `d ≤ inner`
  (`= width/2`), 0 for `d ≥ outer` (`= inner + transition`), smoothstep between.
- `bake_track(centerline, width, transition_m, tarmac_fraction, tarmac_first,
  surface_feather_m)` — a **single distance-field pass** fills all four fields (and the
  cliff offsets). It finds, for each band grid vertex, its true nearest point on the
  centerline (a segment spatial hash + early-terminated ring search, `_nearest_seg`), then
  derives everything from that one nearest point: `road_heights` = noise height at the
  exact foot, `road_blend`/`track_weights` = `smooth_ramp(distance)`, `track_surface` =
  `TrackSurface.tarmac_weight(arc_length)`, and the signed cliff offset. Because the height
  is taken at the true foot rather than a discrete along-arc sample, the road is laterally
  flat regardless of tessellation density — there is **no sampling-step knob**. The road
  follows terrain elevation lengthwise, is flat across its width, and feathers out over the
  band. The surface args default to all-gravel, so callers that don't split surfaces are
  unaffected. A trailing `should_yield: bool = false` makes the heavy vertex sweep
  `await get_tree().process_frame` ~40 times, so the interactive loading overlay keeps
  painting during this multi-second bake instead of freezing; it never changes the baked
  result. Because the body then contains `await`, `bake_track` (and `set_track`) are
  **always coroutines** — call them with `await`. With `should_yield` false (the default,
  and always under headless) they never suspend, completing in the same frame, so headless
  world-build stays synchronous. A further trailing `on_progress: Callable(fraction: float)`
  (forwarded from `set_track`), when valid, is called at the same stride with a carve
  fraction (0→1) — `world.gd` wires it to `LoadingScreen.set_carve_progress` so the grey
  preview line fills white as the bake progresses. Independent of `should_yield` (reports
  even without yielding) and never changes the baked result.
  - **Carve performance.** The sweep is O(band vertices × ring-search) in interpreted
    GDScript, so the carve is usually the single heaviest load stage (grep the console for
    `load stage:`). What keeps it down: (1) the **segment spatial hash** — each vertex only
    checks segments in the grid cells around it, found via an early-terminated ring search
    that culls cells beyond the current best and seeds from the previous vertex's winner;
    (2) the flatten/cliff/cell fields are all computed from that **single** nearest-point
    result rather than in separate passes (unifying what used to be a stamp-based flatten
    walk plus a distance-field cliff walk); (3) the cell sweep (colour + tarmac) is driven
    off the `road_blend` keys — only cells touching a flattened vertex can be in the band —
    instead of re-searching the whole grid; and (4) a morphological open (`_open_thin_offsets`)
    knocks down thin cliff walls. All single-threaded (the web build has no thread support).
    Not bit-identical to the pre-optimisation bake (the cliff mechanism changed hairpin
    handling — see the Cliffs section). NOTE: an earlier version stamped the flatten from
    discrete centerline samples at `ROAD_SAMPLE_STEP_M`; coarsening that step to 1 m made
    the cross-section laterally uneven and visibly **rolled the car**, which is what
    motivated folding the flatten into the exact nearest-point distance field.
- `compute_chunk_data` — `h = lerp(noise_height, road_heights[v], road_blend[v])`
  for vertices in `road_blend` (**mesh + collision**): weight 1 fully flat,
  weight 0 true terrain, between ramps. Off-band vertices keep their noise height.
- `vertex_colors(coord, lights)` — per grid vertex, RGB is `default_cell_color ×
  baked light`; ALPHA is the average of the (up to 4) surrounding cells'
  `track_weights`, so the road fade is smooth over the band. `track_weights` is
  keyed by **global** cell coords, so a shared edge vertex averages the same four
  cells from either chunk → weights match exactly across seams.
- `_light_from_neighbours(hl, hr, hd, hu)` / `_bake_light(noises, amplitudes, wx,
  wz)` — the static terrain shading, baked ONCE per vertex at generation time into
  the colour RGB above (the flat terrain shader already multiplies RGB into ALBEDO,
  so this costs nothing per frame). Mirrors `shaders/ps1_models_lit.gdshader`
  (hemisphere ambient + one directional sun) but on the CPU, with the normal taken
  from the noise height field via central differences at ±1 cell — continuous
  across world coords, so it matches at chunk seams with no stitching. Returns
  white when `light_amount` is 0. **Performance:** the bake needs each vertex's four
  ±1-cell neighbour heights; rather than re-sample the noise 4× per vertex (the old
  `_bake_light` did — ~5× the noise work of a bare height, and `terrain_light_amount`
  ships at `1.0`), `compute_chunk_data` samples the PURE (pre-flatten) height field
  ONCE over a 1-cell **halo** (`SAMPLES+2` per edge) and feeds neighbours read from
  that array to `_light_from_neighbours` — bit-identical output (covered by
  `test_baked_light_halo_matches_per_vertex_sampling`) for ~52% off the lit chunk
  build. `_bake_light` keeps the per-call sampling for single-point callers
  (`light_at`, used by `DistantTerrain`). Params (`light_amount`, `sun_dir`,
  `sun_color`, `sky_color`, `ground_color`) are pushed from `GameConfig` by
  `world.gd` (`apply_terrain_light`) before the initial build. Valid because the
  terrain and sun never move; the car can't bake (it rotates) and lights in its shader.
- `set_track(centerline, width, transition_m, tarmac_fraction, tarmac_first,
  surface_feather_m, should_yield=false)` — `await`
  `bake_track` (forwarding `should_yield`), and **rebuild any currently-loaded chunks** (full `setup()`, since
  geometry changes). At startup the ring is deferred (see below), so nothing is
  loaded here and nothing rebuilds; chunks loaded later bake the blend at build
  time. (Replaces the older binary `track_cells` + `bake_road`.)

## Cliffs & drops

Artificial **cliffs** and **drops** sculpted into the terrain along the sides of
the track, so a stage can run along a ledge — a wall rising on one side, the
ground falling away on the other. A **terrain-height feature**: one more signed
per-vertex term on top of the noise height, added *before* the road flatten, so
it changes both the render mesh and the `HeightMapShape3D` collision (real,
drivable geometry). Driven by 1-D noise along the track, so it varies smoothly
and needs no hand-authoring.

- `cliff_offsets: Dictionary` — grid-vertex index (`Vector2i`, **global**, keyed
  exactly like `road_heights` → seam-safe by construction) → signed height offset
  (m). Empty when disabled or the effective height is 0 (identity, zero cost).
- Per-vertex offset (from the **nearest** centerline sample):
  `side(d) · camber(s) · profile(|d|) · (1 − contested) · cliff_max_height_m · cliff_amount`.
  `side` flips across the centerline and `camber` carries the sign, so one side
  rises by exactly what the other falls — *"a cliff is as tall as the drop is
  deep"* falls out for free, and the slice is level at `camber = 0`.
- `camber(s)` — a 1-D `FastNoiseLite` value in `[-1, 1]` along arc length `s`
  (`_make_camber_noise` / `_camber`, seeded `cliff_seed ^ CLIFF_SEED_SALT` off the
  stage's `track_seed`; `cliff_gain` scales before the clamp, `cliff_wavelength_m`
  is the along-track period — **global**, same for every event).
- `_cliff_profile(d, inner, rise, outer)` — the cross-section: **0 across the whole
  road + transition band** (`inner = width/2 + transition_m`, so the cliff only
  begins where the road has fully met the grass and never tilts the shoulder),
  rising 0→1 over `cliff_run_m` (to `rise`), then falling 1→0 over `cliff_fade_m`
  (to `outer = R`, the influence radius). A localized berm/ditch that returns to
  grade — **not** an infinite shelf: past `R` the offset is 0, so `height_at`
  matches pure noise again and the `DistantTerrain` backdrop needs no `cliff_offset`
  fallback (no seam). Keep `R` inside the corridor dilation (~150 m at the default
  leash) — any sane `R` (tens of m) is safe.
- Thin-wall removal — the inside crook of a hairpin (or any pocket) can leave a thin
  tall wall. Rather than detect it geometrically, the bake gives every vertex a cliff
  from its single nearest track point and then runs a morphological grayscale **open**
  (erosion then dilation, square element radius `cliff_open_radius_m`) on the signed
  offset field, applied to `|offset|` with the sign restored (`_open_thin_offsets`).
  Opening is anti-extensive — it only knocks *down* features narrower than ~2× the
  radius in either axis, never raising an offset or creating one where there was none
  — so thin walls (and thin gashes) vanish while wide cliffs and drops survive. This
  removes ALL narrow tall walls, scenery included (a deliberate change from the old
  road-wrap test, which spared single-sided cliffs of the same width).
- **Bake** (folded into `bake_track`'s single distance-field pass): not a stamp. The
  centerline is turned into segments indexed in a `CLIFF_GRID_M` spatial hash; each band
  vertex finds its nearest segment via an early-terminated ring search over that grid
  (`_nearest_seg`; vertices whose nearest track point is beyond `R` are never processed),
  then — in the SAME pass that computes the road flatten — sets
  `side·camber(s)·profile(d)·cliff_max_height_m·cliff_amount` from that one nearest point.
  Finally `_open_thin_offsets` runs. Visiting each vertex
  once (vs the old disc-stamp, which wrote every vertex dozens of times) is what keeps
  the wide `R` affordable single-threaded. The nearest search uses three exact
  speed-ups: a **camber arc-length LUT** (sample the smooth 1-D camber once, lerp per
  vertex — no per-vertex noise eval); **neighbour-seeded search + per-cell distance
  cull** (project onto the previous vertex's segment first for a tight bound, then skip
  any grid cell whose nearest corner is already beyond it); and **shell-only,
  allocation-free ring iteration** (`while` loops, not `range()`).
- **Apply** (`terrain_chunk_builder._vertex_row`): `h += cliff_offsets[vidx]` on the
  noise height, before the road-flatten `lerp`. Feeds `_heights` → mesh **and**
  collision.
- **Lighting** — the light normal must include the cliff or steep cliffs shade as
  flat. The `_ph` halo (`_halo_row`) carries **noise + cliff** (still excluding the
  road flatten, as before), so `_light_from_neighbours` shades cliffs correctly; the
  lit `_vertex_row` reads `h` straight from that halo (already cliff-inclusive), and
  only the unlit path adds the offset separately.
- **Params** are pushed from `GameConfig` (`apply_cliffs`) onto the manager by
  `world.gd` before `set_track` (mirrors `apply_terrain_light`): `cliff_enabled`,
  `cliff_wavelength_m`, `cliff_gain`, `cliff_max_height_m`, `cliff_run_m`,
  `cliff_fade_m`, `cliff_open_radius_m` (thin-wall open radius), `cliff_amount`
  (runtime per-event scale, written by `RallySession` from the event's `cliffiness`),
  `cliff_seed` (`= track_seed`). See the `Cliffs` group in
  [configuration.md](configuration.md).
- Tests: `tests/headless/test_terrain_cliffs.gd` (zero-when-off/level, flat road +
  band handoff, antisymmetry, bounded, fade-out, determinism, thin-wall open,
  chunk height, cliff seam).

### Deferred initial build

`defer_initial_build` (set on `Floor` in `main.tscn`) makes `_ready` skip the
initial ring so `world.gd` can apply the track first, then call `build_initial()`
— the ring is built once, already flattened, with no rebuild. The editor always
previews terrain regardless of the flag.

#### Who builds the initial ring

**`build_initial()` — and nothing else.** Skipping the build in `_ready` is only half
the deferral: `_process` also reconciles the ring, and `world.gd`'s generation spans
hundreds of awaited frames (`_yield_frame`) on the interactive path. Deferring `_ready`
alone therefore just moved the build into the *first loading frame*, where `_reconcile`
found an empty `_chunk_cache` and took its on-demand branch for the whole
`(2*RADIUS+1)^2` ring. Measured on a real (non-headless) free-roam load before the fix:
all 49 coords built from raw noise during the *carve* stage, plus another column as the
unfrozen car slid downhill on that un-flattened ground — then `set_track` re-`setup()`ed
every one of them after the carve, the precompute cached the same coords a third time,
and `build_initial` found `_chunks` already populated and did nothing.

Two flags close it, and they belong together:

- `TerrainManager._initial_pending` — armed by `_ready` when the build is deferred,
  cleared by `build_initial()`. While armed, `_timed_process` returns immediately, so
  the ring cannot exist before the corridor cache does.
- `world.gd::_generate_track` **freezes the car** (`RigidBody3D.freeze`) for the whole
  generation window and restores the previous value right after `$Floor.build_initial()`.
  `controls_locked` stops the *player* driving off; it does not stop the *body* falling,
  and between the two flags there is deliberately no collision under it. Frozen, the car
  waits at its spawn pose and drops onto carved, flattened ground once the ring exists —
  strictly better than the old behaviour, where it settled on terrain that was then
  re-baked underneath it.

Beyond the wasted compute, the on-demand path was a correctness problem for LOD: a chunk
built from `compute_chunk_data` builds *every* level itself (`TerrainChunk._lazy_finest`
stays false), so the ring the player actually stands on never joined the lazy finest-LOD
path and pinned its level-0 buffers until the chunk first despawned. Coming from the
cache, the initial ring behaves like every other chunk — which by default means fully
prebaked, and under the `lazy_finest_lod` escape hatch means finest-deferred like the
rest (`test_terrain_memory.gd` →
`test_initial_ring_participates_in_the_lazy_finest_path` covers the latter).

`on_demand_builds` counts `_reconcile`'s raw-noise builds. It is legitimately non-zero
for the editor preview and for tests that never precompute; **on a real load it must be
0**, and `test_car_terrain.gd` asserts exactly that on `main.tscn`.

Tests: `test_terrain_memory.gd` (`_process` builds nothing while pending; the ring is a
cache pull; the ring is finest-deferred like any later chunk), `test_car_terrain.gd`
(zero on-demand builds on the real scene, car handed back to physics), and
`test_terrain.gd::test_defer_initial_build_skips_ring_until_called`.

## Open-world mode (the overworld)

`TerrainManager` also supports a **bounded, streamed** world — the drivable overworld hub
(see `docs/superpowers/specs/2026-08-17-overworld-hq-design.md`, and `features/overworld.md`
once it lands). This is a set of **additive, off-by-default opt-ins**: leave every field
below alone and behaviour is bit-identical to a stage. Nothing here is used by
`main.tscn`.

| Field / method | Default | What it does |
|---|---|---|
| `load_radius: int` | `RADIUS` (3) | Live ring radius, above. |
| `stream_on_miss: bool` | `false` | A cache miss **builds** instead of leaving a hole. |
| `cache_cap_mb: float` | `0.0` (off) | Cap on `cache_size_mb()`; over it, `evict_to_cap()` drops chunks. |
| `chunk_source: Object` | `null` | Duck-typed chunk store (see below). |
| `road_source: Object` | `null` | Duck-typed road network (an `OverworldRoads`) — the per-chunk road carve and `surface_at`'s network branch (see below). |
| `capture_encoded_light: bool` | `false` | Keep `l0_light` even when `lazy_finest_lod` is off. |
| `world_bounds: Rect2` | empty | The bounded world; empty = a stage. |
| `edge_taper_m` / `edge_depth_m` / `water_level_m` | `0` | The coastline taper. |
| `bounds_surface: Vector2` | `(0, 0)` | What `surface_at` returns inside bounds. |
| `set_bounds(rect, taper_m, depth_m, water_y)` | — | Declares the bounded world. |
| `clear_bounds()` / `has_bounds()` | — | Back to stage mode / the predicate. |
| `apply_overworld_bounds(cfg, rect)` | — | Seats all of the above from a `GameConfig` in one place. |
| `set_chunk_source(source)` | — | Attaches the store (and arms `capture_encoded_light`). |
| `set_road_source(source)` | — | Attaches (or clears) the road network. Must be seated **before** any chunk is built or cached. |
| `taper_height(h, x, z)` | — | The falloff itself; a no-op outside bounded mode. |

Params are **passed in**, not read off `Config`, so this `@tool` script stays editor-safe
and pure — the same convention as the `light_*` and `cliff_*` fields.
`apply_overworld_bounds` is the one place that reads `GameConfig`
(`overworld_load_radius`, `overworld_chunk_build_budget`, `overworld_edge_taper_m`,
`overworld_edge_depth_m`, `track_water_level_m`).

### Bounds replace the track corridor

An open world has no `set_track`/`bake_track`, and five behaviours degrade without a
corridor. `has_bounds()` is the switch that fixes each:

| Behaviour | Without a corridor | With `set_bounds` |
|---|---|---|
| `chunk_class` | full-res `l_min` 0 for unknown coords, so pruning is dead | explicitly full-res **and** in the collision band — correct, because the car can reach anywhere, so no chunk is "far from the route" |
| `corridor_complete()` | permanently false, so `free_load_only_data()` never fires | `true` — "no chunk can still be asked for the bake fields", which is true by construction (there are none) |
| `corridor_bounds()` | empty `Rect2`, so `DistantTerrain.build_static` builds no horizon | returns `world_bounds` |
| `surface_at` | reads the empty `track_weights`/`track_surface` and answers 0 by accident | asks `road_source` when one is attached (`_road_surface_at`), else returns `bounds_surface` by decision |
| light queries | `lights` freed while `corridor_complete()` stays false → `_cached_light_at` `push_error`s per query | `free_load_only_data()` **keeps** the light and never latches the sentinel; `_cached_light_at` also falls through silently under bounds, so no spam |

Keeping the light is not a leak — in an open world `light_at` is a repeated query and chunks
are generated in *play*, so `lights` is a live input to every `chunk_source` write, not
load-only data. (`compute_chunk_data`'s five post-passes, `_chunk_view`, and the `bake_track` split: [terrain-chunk-modifiers.md](terrain-chunk-modifiers.md).)

### The coastline edge taper (D9)

`taper_height(h, x, z)` drives the height toward `water_level_m - edge_depth_m` as a point
approaches the perimeter of `world_bounds`, smoothstepped over `edge_taper_m`. So the world
is an island and the sea is the border — no invisible wall, no turn-back logic, and it reuses
the waterline `LakeField` already builds ([lakes.md](lakes.md)). Beyond the bounds the inward
distance clamps at 0, so the sea floor is a flat shelf at full depth rather than falling
forever.

**Where it is applied is load-bearing.** It runs *inside height generation*, before any
quantisation or caching, through exactly two call sites — both delegating to the one
`taper_height`:

1. `_noise_height_at` — the pure-noise fallback `height_at` uses for any uncached coord.
2. `TerrainManager._apply_edge_taper`, called by `compute_chunk_data` immediately after
   `TerrainChunkBuilder.build()`, which rewrites `heights` **and** `vertices` in lockstep.

Both paths must agree or the coast disagrees with itself, which is why they share one
function. `heights` is what the `HeightMapShape3D` collision, `height_at` and
`TerrainLod.build_finest` read; `vertices` is what the displayed meshes are built from. It
is done in the manager rather than in `TerrainChunkBuilder` because the builder's height path
is the *static* `TerrainManager._sample_height`, which has no instance and so cannot see the
bounds.

Two accepted consequences, both commented at the code:

- The per-vertex **baked light** is computed inside the builder from the untapered field, so
  the taper slope shades as the inland noise would. Shading only — geometry, collision and
  queries all agree.
- The **coarse** (`stride > 1`) builder path is untapered, and is unreachable in bounded
  mode because `chunk_class` returns `full_res` for every chunk there.

Pin safety: no authored `map_pos` may sit inside the taper band, or its zone drowns. That is
a shipped-content guard on `tools/fit_map_pins.py`, not something this file enforces.

### The road carve (per chunk, not a global bake)

The overworld's roads come from `OverworldRoads` (`scripts/overworld_roads.gd`) — a
deterministic network over the rally pins plus the garage, queried per point by `road_at`.
`TerrainManager` consumes it through the duck-typed `road_source` (`set_road_source`), never by
class, so this file keeps no dependency on it and `null` (every stage) is byte-identical to
before.

`TerrainManager._apply_road_carve(data, carve_heights)` is the carve, run by
`compute_chunk_data` as a post-pass on the builder's arrays — deliberately **not** through
`bake_track`:

- `bake_track` is one global distance-field pass over a corridor derived from a single
  `Curve2D`, filling map-wide per-cell dictionaries. The overworld is a network over ~1,600
  chunks, so those dictionaries would hold millions of cells.
- `free_load_only_data()` drops `road_heights`/`road_blend` after load, so any chunk generated
  later — and in the overworld *every* chunk is — would silently lose its flatten.

What it writes, in one pass over the grid, is the same four things `bake_track` expresses per
cell:

| The carve writes | `bake_track`'s equivalent | Read by |
|---|---|---|
| `heights` **and** `vertices`, in lockstep | `road_heights` + `road_blend` | the `HeightMapShape3D` collision, `height_at`, `TerrainLod.build_finest` / `build_all`, and the cached bytes |
| vertex colour **alpha** = `road_weight` | `track_weights` (via `_vertex_color_row`) | `ps1_models.gdshader` — `road_t = COLOR.a` under `blend_road` |
| **`UV2.x`** = `tarmac_weight` | `track_surface` (via `_surface_uv2_row`) | the same shader — `tarmac_t = UV2.x` |

**`UV2.y`** is filled by a separate overworld-only post-pass, `_apply_region_blend`: the
**canonical region rank** the ground shaders decode into a spatial region cross-fade — through the
all-regions colour LUT (`region_lut_look`) for tint/tarmac and through the two-slot pair
(`region_blend_t`) for the ground texture. It runs after the carve and the coastline taper and before the height quantum,
is repeated in `_rehydrate_chunk_data` (the row builders rebuild `uv2s` from scratch), and is a
no-op without a `region_source` — so a stage never writes it and `blend_region` ships false. The
rank is sampled at the chunk's **four corners** and bilinearly interpolated, because the region
field varies over kilometres while a chunk is 50 m, and `region_weights_at` is linear in the rally
roster. See [overworld.md](overworld.md) → "Region blending".

The roadbed height is the terrain's own **pure noise** at `hit.foot` (the nearest point on the
centreline), blended in by `hit.road_weight` — exactly `bake_track`'s
`road_heights`/`road_blend` pairing. `road_weight` doubles as the flatten weight rather than a
second `height_bias_at` call, because the two are equal today and this is a per-vertex hot
loop; `OverworldRoads.height_bias_at` exists so the flatten band and the colour band *may*
diverge later, and the carve carries a comment saying what to change if they ever do. Noise
instances are built locally (`_build_noises`), not taken from the main-thread cache, because
`compute_chunk_data` runs on worker threads.

**Two ordering rules make it correct:**

1. It runs **inside generation** — after `builder.build()`, before quantisation and before any
   cache write — so the mesh, the collision heightfield, `height_at` and the cached bytes all
   derive from one number. Same reason the coastline taper is a grid pass here.
2. **The coastline taper wins.** `compute_chunk_data` calls `_apply_road_carve` *first* and
   `_apply_edge_taper` *second*, so a road running to the shore is flattened onto the noise
   ground and then dragged down to the sea floor with everything around it. The alternative —
   taper first, then clamp the flatten so it can never raise tapered ground — needs an extra
   rule the flatten has to remember; carve-then-taper needs none, because `taper_height` is a
   plain function of `(h, x, z)` that re-derives the shoreline from scratch. A road therefore
   sinks into the water at the map edge instead of standing on a causeway out to sea.

Cost, and the three things that were paid for nothing before:

- **The per-chunk reject** is `has_segments_in_rect(rect)` where the source has it — a predicate
  that stops at the first hit. `segments_in_rect(rect).is_empty()` answered the same question but
  first built an Array of freshly allocated per-segment Dictionaries that the carve then threw
  away, on the *common* path (nearly every chunk of ~1,600 is road-free). Both share one scan
  (`OverworldRoads._scan_rect`) so the cheap reject cannot drift from the list it predicts.
- **The per-vertex query** is `OverworldRoads.road_at_into(x, z, out)` where the source has it — an
  allocation-free twin of `road_at` filling one caller-owned 5-slot `Array`
  (`[road_weight, tarmac_weight, distance_m, foot.x, foot.y]`, indexed by the `PROBE_*` constants).
  `road_at` is now a thin Dictionary wrapper over it, so the two cannot disagree. A source without
  the variant (the duck-typed fakes in the tests) keeps the dictionary path.
- **The noise set** is the shared `_ensure_noise_cache()` pair, not a fresh `_build_noises()` per
  carved chunk. The old code minted 3–4 new `FastNoiseLite` objects per chunk, justified by a
  comment claiming `compute_chunk_data` runs on worker threads. **It does not** — there is no
  threading anywhere in the terrain path (`WorkerThreadPool` / `Thread` / `Mutex` appear in exactly
  one file in `scripts/`, `cloud/google_sign_in.gd`), and the target platforms include
  single-threaded ones (mobile web), so threads are not an escape hatch either. `TerrainChunkBuilder`
  still calls `_build_noises()` per chunk on the same stale reasoning and is the obvious next win on
  the *generate* path.

A chunk with no road still pays exactly one rect query and returns. Only the full-res grid is carved; the coarse
(`stride > 1`) path is unreachable in bounded mode because `chunk_class` returns `full_res`
there, and the guard says so explicitly rather than leaving it ambiguous.

`_rehydrate_chunk_data` calls the carve with `carve_heights = false` — **colours only** — but only
when the record carries no stored surface channels (see "The stored surface channels" above; with
them, both passes are skipped outright). Its
`heights` came out of a previous `compute_chunk_data` and are already carved (re-flattening
would compound the lerp), but its colour/uv2 rows are rebuilt from `track_weights` /
`track_surface`, which a bounded world never fills, so without this a cached chunk would come
back road-*less* under the wheels' road.

`surface_at` also answers from the network in bounded mode (`_road_surface_at`), returning the
same `(road_weight, tarmac_weight)` pair the dictionary path does, and `bounds_surface` when
fully off it. Without this the tyre model, grip, deep-snow drag and reset logic would all see
one flat surface and a carved road would have no grip difference at all. It is called per wheel
contact per tick and `road_at` returns a Dictionary, so `_road_surface_at` keeps a one-entry
memo keyed on the contact point quantised to a quarter cell — several consumers ask about the
same point in the same tick (`Drivetrain.surface_tire_params`, itself allocation-free via
`_surf_scratch`, plus grip and the snow drag), so the repeats cost nothing. A lean scalar
variant on `OverworldRoads` would remove the miss allocation too, if it ever shows up in a
profile.

`_road_surface_at` also consults `pad_source`, `maxf`'d over the road's own answer with the same
pad-wins precedence `_apply_pad_flatten` bakes into the mesh (see "Flat pads" below) — this is
what keeps `wheel_particles.gd` and `Drivetrain.surface_tire_params` agreeing with what the pad
*looks* like. Both go through this one function, so the fix lives here rather than being
duplicated in each consumer. `set_pad_source` invalidates the one-entry memo for the same reason
`set_road_source` already does: a query made before the pad was attached (or before a pad swap)
must not answer stale afterwards.

### Flat pads

A **level circle of ground** under every rally zone and under the garage, so the things standing
there sit flat. The pad set is `OverworldPads` (`scripts/overworld_pads.gd`, and see
`features/overworld.md` → "Flat pads" for its shape and radii); `TerrainManager` consumes it
duck-typed through `pad_source` / `set_pad_source`, never by class, so `null` — **every stage** —
is byte-identical to before pads existed.

Two entry points for the HEIGHT flatten, both driven by `pad_at(x, z)` (`.x` = feathered weight,
`.y` = target height) — `pad_height(h, x, z)` wraps it for callers that only want the height:

- `_apply_pad_flatten(data)`, a grid post-pass in `compute_chunk_data`, rewriting `heights` and
  `vertices` in lockstep exactly as `_apply_edge_taper` does. It exits on one `pads_in_rect`
  query for the ~1,600 chunks that hold no pad.
- `_noise_height_at`, the pure-noise generator. **This is the deliberate difference from the road
  carve**, which is *not* in the generator (a known latent bug). Everything a pad exists for —
  seating the garage building, a zone's tube and marker, a ghost car, the default spawn, the
  foliage `dry` test — queries `height_at`, which falls back to `_noise_height_at` for any coord
  the chunk cache has not built. Leaving the pad out of the generator would break the pad exactly
  where it is used, so the pad follows the taper, not the carve.

`_apply_pad_flatten` **also bakes tarmac** — `COLOR.a` (road weight) and `UV2.x` (tarmac weight),
the same channels `_apply_road_carve` fills and `ps1_models.gdshader`'s `blend_road` branch reads
— using the *same* `pad_at(x, z).x` weight that drives the height blend, `maxf`'d against whatever
the carve already wrote there. So the whole pad disc (every rally zone **and the garage**) reads as
forecourt rather than roads simply meeting on bare grass at the pin, and it fades to grass across
exactly the same feather band the height flatten uses — one weight, no separate radius to keep in
sync. A `flatten_heights := true` parameter lets `_rehydrate_chunk_data`'s no-stored-surface branch
call it a second time for the tarmac alone (see below).

**Ordering in `compute_chunk_data`, all three rules load-bearing:**

1. **After `_apply_road_carve`.** A pad wins over a road inside it, on *both* channels: the
   forecourt is level ground the road paints across, and its tarmac weight is `maxf`'d over the
   carve's rather than left as the carve wrote it — a dirt/dead road running through a pad (its own
   `tarmac_weight` might be `0`) must not leave a stripe of non-tarmac ground across the pad's own
   surface.
2. **Before `_apply_edge_taper` — the coastline still wins.** The taper re-derives the shoreline
   from `(h, x, z)`, so a pad near the map edge is pulled to the sea floor rather than standing on
   a plinth out of the water. Same rule, same order, as the carve.
3. **`_apply_height_quantum` stays last.**

**Rehydration.** `_rehydrate_chunk_data` splices a stored `surface` section straight back in when
present — it already carries the pad's tarmac contribution bit-for-bit, since it was written from a
`compute_chunk_data` that included this pass. When no `surface` is stored, colours/UV2 are rebuilt
from scratch via `_apply_road_carve(out, false)`, which would otherwise wipe any pad tarmac back out
even though the stored heights already carry the flatten; `_apply_pad_flatten(out, false)` runs
right after it to restore just the two texture channels, mirroring the road carve's own
`carve_heights` split.

`_noise_height_at` applies pad-then-taper for the same reason, so the generator and the baked grid
cannot disagree.

#### The junction: roads run *into* every pad

`OverworldRoads` builds its graph with the rally pins and the garage as its **nodes**, so a pad
centre is literally a road endpoint and 3–5 edges typically converge there. The roadbed target
(noise along the centreline) and the pad's level agree exactly at the pin and drift apart outward,
so two independent passes would leave a step or a crease in a ring around the pad — at the most
looked-at spot on the map.

The fix is inside `_apply_road_carve`: the roadbed target is itself run through `pad_height`,
evaluated **at the foot** (the nearest point on the centreline). The road therefore *arrives
level*, ramping onto the pad's plane over its last stretch the way a real road eases into a yard.
Inside the pad the road's target **is** the pad level, so the pad pass that follows changes nothing
the carve did not already do and the two cannot fight; outside, both influences decay smoothly.

**Is it genuinely continuous?** Yes by construction, not by tuning — every term is a continuous
function of position, so no combination of tunables can reintroduce a *step*. Two honest caveats:

- The foot point jumps across a road's medial axis (equidistant between two segments), so the
  pad-adjusted target has a hairline discontinuity there. It is damped by the road weight and by
  the fact that the two feet are near-equidistant from the pad centre, i.e. sub-millimetre in
  practice — but it is not exactly zero. Several roads entering within a few degrees of each other
  is the case that makes it largest.
- **Gradient, not continuity, is what actually breaks.** The steepest grade a feather can produce
  is about `1.5 × Δh / feather width`, where `Δh` is the height difference between the pad's level
  and the ground just outside it. With a FIXED band that grade is whatever the site hands you, and
  on a rough site it exceeded the ~22% FWD / ~33% RWD a car climbs at snow grip — a lip the player
  could not drive out over, on the very road that led them in.

**Each pad therefore sizes its own feather** (`OverworldPads._feather_for`, called once per pad at
build time). It samples a ring of the terrain's *own generated* height at the candidate band's
outer edge, takes the worst `|level − h|`, and demands `1.5 × Δh / overworld_pad_max_grade` of run
for it — re-sampling a couple of times, since widening moves the ring outward onto possibly rougher
ground. The width only ever grows from the authored `overworld_pad_feather_m` (the *minimum*) and
is capped at `overworld_pad_max_feather_m`, so a pad on a cliff edge accepts a steeper lip rather
than flattening the neighbourhood. It stays pure and deterministic, and the per-pad width is folded
into `stamp()` so the chunk cache re-warms when it changes.

**Three constraints resolve the width, and they were derived by MEASUREMENT** — see
`tools/analyse_road_grades.gd`, which walks every road on the real map and reports the grade the
car meets (run it before touching any of this):

1. **The grade-driven widening** above asks for `1.5 × Δh / overworld_pad_max_grade`.
2. **The neighbour cap** (`_neighbour_cap`) refuses more than *half the clear gap* to the nearest
   other pad, floored at the authored feather. Without it, the widening ran every band to the
   60 m ceiling on a map whose pads sit ~150 m apart, so every band overlapped its neighbours and
   the ground between two pads was a blend of two pad levels the whole way across — the entire
   height difference had to be paid in the narrow strip where the blend handed over. Roads that
   ran at worst 0.28 over open ground hit **0.67** with pads on. The widening was manufacturing
   the defect it exists to prevent.
3. **The radius shrink** (`_shrink_to_fit`) is the lever left when the cap refuses the width: a
   smaller disc has less to give back (`Δh` ≈ terrain slope × radius). Bounded by
   `_MIN_RADIUS_SHARE`, and the **garage pad is exempt** — `overworld_garage.gd` clamps the
   building against the *configured* radius, so shrinking the pad would leave the building off
   the flattened ground.

The pad's **level** is the mean of the terrain over its own footprint (two rings plus the centre),
not the height at the single centre point: a pin on a local bump used to take its level from that
bump and pay the whole offset back across the feather.

**Overlapping pads blend their target.** The flatten *weight* is still the strongest pad's (a
pad's own footprint must read as fully flat), but the target height is
`Σ (w/(1−w))·level / Σ (w/(1−w))`, not the strongest pad's level taken outright. Outright, the
target jumps by `w·(levelA − levelB)` where two influences cross — metres tall on rough ground,
the very cliff the feather exists to prevent. That used to be rare (two pads had to sit within one
14 m band); with bands that widen it is common. `w/(1−w)` diverges as `w → 1`, so a sample inside
a pad outvotes every neighbour and the interior stays flat — this is not the honest average, which
would tilt both pads. (It replaced a `w⁸` weighting that did keep interiors flat but swung the
target almost entirely from one level to the other across the locus where two weights are equal.)

Consequences elsewhere: `influence_m()` reports the **widest built** feather (a caller inflating by
the authored width would miss a widened pad's outer skirt), `pads_in_rect` and `pad_at` use each
pad's own width, and `feather_m()` now means the authored minimum — ask `pad_feather(i)` for what
pad *i* actually uses.

No *extra* widening is done where a road enters, and none is needed: the road already arrives at
the pad's level, so there is no height difference for the two feathers' differing rates to expose.

### `stream_on_miss` — a correctness fallback, not the supply mechanism

Today a miss with a partially-filled cache deliberately spawns **nothing** (a hole, plus a
`push_error`) because a mid-drive build is a measured hitch. `stream_on_miss` builds instead.
It goes through `_stream_chunk`, which routes to `cache_chunk()` rather than the raw
`compute_chunk_data` on-demand branch, because that branch has two side effects that must not
be inherited:

1. It hands `TerrainChunk.apply_data` a dict with no `lod_meshes`, so the **node** builds all
   five LOD levels itself and never joins the lazy finest-LOD path — pinning level-0 VRAM
   until it first despawns. Via `cache_chunk` the levels are prebaked, `lazy_finest_lod` is
   honoured, the collision shape is built once and `DEAD_AFTER_PREBAKE` is dropped.
2. It reads the road/cliff bake fields that `free_load_only_data()` deletes. Bounded mode
   never frees them; a stage that turned this on after the free would get unflattened ground,
   so that case `push_error`s.

It **logs once per session** (`terrain stream-on-miss:`, `stream_on_miss_builds` counts them)
so an undersupplied window or a gap in the store is visible rather than silent — never per
coord and never per frame, since a boundary crossing re-visits the same coords every frame
until they are built.

### `chunk_source` — the duck-typed chunk store

`chunk_source` is used **only** through `has_method`, never by class, exactly the way
`drivetrain.terrain` is duck-typed. The contract is three methods:

- `read(coord) -> Dictionary` — `{"heights": PackedFloat32Array, "l0_light": PackedByteArray,
  "surface": PackedFloat32Array}` (`surface` optional)
- `write(coord, heights, lights, surface := PackedFloat32Array()) -> bool`
- `has(coord) -> bool`

The store holds the two genuinely expensive **sampling** products (heights and baked light) plus
the three **derived surface channels**. Everything else is arithmetic over a fixed grid, so
`TerrainManager._rehydrate_chunk_data` reconstructs a full builder-shaped dict — mirroring
`TerrainLod.build_finest`'s derivation and reusing `_vertex_color_row`, so a rehydrated chunk is
the same surface a generated one produces.

#### The stored surface channels — why a READ is cheap

Storing heights + light removed the height *generation* from a read and **nothing else**: the
rehydrate still ran `_apply_road_carve(out, false)` and `_apply_region_blend(out)`, and the carve
queries the road network **once per vertex** (`SAMPLES²` = 2,601 per chunk), each query allocating
a Dictionary. Measured, that made every chunk-boundary crossing a 3–4 frame cluster of 13–34 ms
spikes even with `overworld_chunk_build_budget` honoured and `stream_builds` at 0 — the cost was
pure rehydration.

So the three values those two passes produce are stored too, via
`TerrainManager.surface_channels_from(data)` — interleaved per vertex as
`(road_weight, tarmac_weight, region_rank)`, i.e. `(COLOR.a, UV2.x, UV2.y)`:

| Channel | Produced by | Consumed by |
|---|---|---|
| `COLOR.a` road weight | `_apply_road_carve` (colours arm) | `ps1_models.gdshader` `road_t` |
| `UV2.x` tarmac weight | `_apply_road_carve` (colours arm) | `ps1_models.gdshader` `tarmac_t` |
| `UV2.y` region rank | `_apply_region_blend` | the ground shaders' A→B remap |

When `_rehydrate_chunk_data` is given a correctly-sized `surface` it splices those values in and
**skips both passes entirely**; `_surface_uv2_row` is skipped with them. `_vertex_color_row` still
runs for the **RGB** (ground tint × baked light) — the light is stored, the tint is a runtime
field, so nothing about that path changes.

**Stored as raw f32, deliberately.** The cache's contract is an *exact* round trip, not an
approximate one (`test_overworld_cache` asserts bit-identical heights, `test_terrain_digest` is a
golden SHA-256 over generated terrain). Heights get away with int16 only because they are
**snapped at generation** (`height_quantum` / `snap_heights`), so cached and generated numbers are
literally equal. These three channels are snapped nowhere, so a quantised channel would make a
rehydrated chunk differ from a generated one — a shading seam wherever the cache boundary happens
to fall. f32 costs 12 bytes/vertex, ~31 KB raw per chunk before the record's zstd, which crushes
it: the road channels are exactly `0.0` across nearly every vertex of the map and the rank is
near-constant inside a region.

**Optional in both directions**, so the fast path is never a correctness dependency: a record
written without the section (no road/region source, or a record predating it), a mis-sized array,
or a caller that only has heights all fall back to recomputing the two passes exactly as before.
`OverworldCache.write` drops a wrong-sized array with a warning rather than storing it.

`chunk_data_for(coord)` is the single seam: read from the store, else generate and offer the
result back. Stored heights are **already tapered** (they came out of `compute_chunk_data`),
so a round trip is idempotent and the taper is never re-applied. A store is always a pure
speed-up — no store, no record, or an unusable record all fall through to generation.

`capture_encoded_light` extends the `l0_light` retention (previously only under
`lazy_finest_lod`) to the open world, because `free_load_only_data()` erases the
full-precision `lights` and a `write` after that would persist a light-less record the
invalidation key could never discard. It stays **off** for stages: ~7.8 KB per chunk with no
reader.

### Cache eviction (`evict_to_cap`)

`_chunk_cache` was only ever cleared wholesale — the per-coord `erase` in `_reconcile` is on
the spawned-node dict, not the cache — so a large resident window grew without bound.
`evict_to_cap()` drops cached chunks farthest from the focus first until `cache_size_mb()` is
back under `cache_cap_mb`. It is called from `cache_chunk` and from the end of `_reconcile`,
and is a no-op with no cap (every stage: a stage's corridor cache is sized by the precompute
and losing an entry would leave a hole).

Three hard safety rules, each a real bug if broken:

1. **Never evict a coord whose `TerrainChunk` node is live.** `lod_meshes` and `shape` are
   handed straight to the node, so freeing the dict under it would pull the meshes and the
   collision heightfield out from beneath ground the player is driving on.
2. **Stay strictly outside the built window** — Chebyshev `> load_radius + 1` from the focus
   chunk, the `+1` being hysteresis so a coord the next reconcile is about to spawn is not
   thrown away a frame early. Eviction is *not* lossless: once a coord leaves the cache,
   `height_at` / `light_at` / `surface_at` fall back to pure noise, so the queried height
   would disagree with the mesh the player stands on. Outside the window nothing is standing
   on it.
3. **Free both products explicitly** — `lod_meshes` (the per-level `ArrayMesh` array, i.e.
   the VRAM) and any prebuilt `shape` (the `HeightMapShape3D` committed to the
   `PhysicsServer`) are erased before the dict is dropped, so the intent is visible rather
   than left to refcount coincidence.

`cache_size_mb()` (now factored over a `_chunk_bytes` helper) is the reporting hook. Note it
counts CPU-side packed arrays only, **not** `lod_meshes` — those are already-uploaded GPU
buffers; `_log_precompute_vram` covers that half.

Related: `build_initial()` now seats `_last_focus_coord` **before** reconciling rather than
after. Eviction measures distance from it, and the sentinel it starts at is ~2 billion chunks
away, which would make every cached chunk look evictable during the very first build.
`_reconcile` takes its centre as an argument, so the reorder changes nothing else.

### The reconcile queue's cost

The detail queue was sized for 49 chunks and is quadratic-ish at 441. The `O(n²)` half is
gone: membership is now an `O(1)` `_queued_for_detail` dictionary mirroring `_detail_queue`
(kept in step by `_drain_detail_queue`, which erases on every exit path) instead of a linear
`_detail_queue.has(coord)` inside a loop over every loaded chunk.

The per-reconcile **re-sort** is kept deliberately and was not rewritten. It is `O(n log n)`
on a queue that only ever holds chunks inside `detail_ring()` — 2 at the shipped tunables,
i.e. a 25-chunk cap regardless of `load_radius` — and it runs only when the focus *crosses*
a chunk boundary, not per frame. A heap or an incremental insert would be a risky rewrite of
the detail path for no measured gain. Revisit if `detail_ring()` is ever raised so the queue
holds hundreds of entries.

### `detail_ring()` and a larger radius

`detail_ring()` clamps to `load_radius` now, not the old `RADIUS` const, and that is a
decision rather than a mechanical substitution. The computed value depends only on
`lod_band_ends_m[0]` and `precompute_safety_slack_m` — **not** on the radius — so at the
shipped tunables it is 2 and the clamp does not bind at either radius: raising `load_radius`
to 10 leaves the result unchanged, so lazy-LOD behaviour on a stage is identical. The clamp
only binds when level 0's band plus the camera slack reaches *beyond* the loaded ring, and
there "every loaded chunk keeps its finest level" is the right answer at whatever the ring
actually is — clamping to 3 inside a 21×21 window would instead have *reduced* the detail
ring below what the bands ask for. Same reasoning for the empty-bands case: no bands means
one level, so the whole ring is finest.

### Spawning within the frame budget

`_reconcile` does **not** spawn a crossing's whole new ring row in one call when
`spawn_budget > 0` (the overworld sets it from `overworld_chunk_build_budget`): `_enqueue_spawns`
sorts the missing coords nearest-first and queues them, and `_drain_spawn_queue(spawn_budget)`
builds at most the budget per frame thereafter.

**The forced set is bounded to `collision_ring` exactly** — the band that carries live collision.
That set is never deferred, because the project chose *loud holes over generate-on-miss* and a
missing chunk under the car is a fall-through, not a cosmetic gap. It used to be
`collision_ring + 1`, which cost 5 immediate builds per crossing instead of 3 (a 3×3 crossing adds
one row of 3) — and immediate builds bypass the budget entirely, so they were the `update_focus`
half of the measured chunk-boundary spike. A chunk one ring beyond the collision band cannot be
touched until it has itself *become* the collision band, which is a whole chunk of travel (50 m,
well over a second at any speed the car reaches) and therefore many frames of budgeted draining.
The no-hole guarantee is unchanged: the band the car can stand on is complete before
`update_focus` returns.

**Ring membership is arithmetic, never `target_coords(...).has(coord)`.** `target_coords` is
exactly the Chebyshev ball of radius `load_radius`, so `maxi(absi(dx), absi(dy)) <= load_radius`
answers the same question with no allocation. Three places used the Array instead:
`_drain_spawn_queue` rebuilt the whole 441-entry Array **every frame** the queue was non-empty and
then linear-scanned it per drained coord; `_reconcile`'s despawn loop linear-scanned it per
resident chunk (441 × 441 ≈ 195k `Vector2i` comparisons per crossing at radius 10, straight into
the measured `update_focus` cost); and `_enqueue_spawns` built its forced set then `erase`d each
entry from the queue, which is quadratic in the forced set's size — it now partitions in one pass.

### Budget, not proven

A 21×21 window is ~441 spawned chunks, on the order of 2,600 `MeshInstance3D` and 441
heightfield shapes. That is a genuinely new budget — `overworld_load_radius` must be sized
from a **measurement on a real device**, not assumed. Note also that 7×7 is the *render*
ring; the collision ring is `collision_ring` (1, i.e. 3×3), which is unchanged by any of
this.

## Boundary

**Stages: none.** With infinite chunks there is always collision ground beneath the car, so
the old `Border` safety wall and far visual plane were removed.

**Bounded (open-world) mode:** the boundary is the coastline taper — see
[Open-world mode](#open-world-mode-the-overworld) → "The coastline edge taper". Still no
wall, no collider and no turn-back: the ground simply falls below the waterline all the way
around.

## Fog & distant backdrop

The detailed 7×7 ring's edge sits ~175 m from the car (its far chunks are cheap
coarse LOD levels). Rather than hide
that edge with dense fog (which also hid the sky), a coarse **`DistantTerrain`**
(`scripts/distant_terrain.gd`, a plain `Node3D`) extends the visible terrain far
past the ring — collision-free scenery sampling the same `height_at`/`light_at`
— so the now-thin fog (`fog_density`, authored 0.01 in
`config/game_config.tres`; the script/scene default 0.005 is only a fallback)
reveals a horizon for the skybox instead of a cliff. See
[rendering.md](rendering.md).

Two things to know before relying on this section: `distant_terrain_enabled` is
**`false`** in the shipped `config/game_config.tres`, so the backdrop described
below is currently switched off; and the ring radius and the fog are entirely
independent — no cull anywhere reads a fog value, so a foggy/wet stage still draws
the geometry the fog hides (see [rendering.md](rendering.md) → "Fog does not shorten
the cull").

`_build_tile`'s own job is just the sampling loop (world-XZ → `height_at`/
`light_at` → flat vertex/uv/color arrays); the triangulation and `ArrayMesh`
assembly are the same `TerrainLod.grid_mesh` used by the LOD levels above
(called with `skirt_m = 0.0` and no UV2 — the backdrop has no road blend and
relies on `sink_m` instead of a skirt to hide seams).

Because the play area is a **bounded corridor** (see the caveat under Performance —
in practice the band reaches hundreds of metres off the road), the backdrop no longer
needs to track the car at all: `build_static(terrain, bounds)` builds a grid of
static `250 m` tiles (`tile_m`) covering `TerrainManager.corridor_bounds()`
dilated by `GameConfig.distant_terrain_radius_m` (now a **margin**, not a
follow-radius) **once**, behind the loading screen, and never re-centres or
rebuilds again. Tiles (rather than one huge mesh) keep the backdrop
frustum-cullable — a single mesh spanning the whole stage would submit every
triangle every frame through one giant AABB. `height_at`/`light_at` are
cache-first inside the corridor and fall back to pure noise for the margin
band beyond it, so the seam between "real" and "backdrop" terrain is
continuous either way.

To stop it poking through the detailed terrain, the **whole backdrop is sunk
`sink_m`** (default 1.5 m, `GameConfig.distant_terrain_sink_m`) below true
height, so the detail ring always renders above it and the coarse mesh stays
hidden beneath; the visible step at the ring's outer edge is ~125 m away and
softened by fog. This also guarantees the skybox is never exposed — the
backdrop covers the whole corridor plus margin unconditionally, so there's no
race with which chunks happen to be loaded. Tunables: `GameConfig.distant_terrain_*`
(`cell_m`, `sink_m`, `tile_m` map straight to the matching `DistantTerrain`
properties).

## Performance

Terrain generation is no longer a runtime stream — it's a one-time **precompute
over a bounded corridor**, done behind the loading screen. The corridor is sized
from `Config.data.track_progress_max_dist_m` and dilated by `RADIUS + 1` chunks on
top, which puts its edge hundreds of metres off the road — far enough that the
reachable chunk set is knowable in advance for any realistic driving:

> **This is no longer a hard invariant.** It used to be: the off-track reset was a
> distance leash, so the car physically could not leave the band. The reset is now
> **timed** ([progress.md](progress.md)), so a car launched off a cliff can outrun the
> corridor before its clock expires. That case is deliberately left to **degrade**
> rather than being engineered around: the chunk is a silent hole (see 3 below), the
> static `DistantTerrain` backdrop still draws the landscape, and the car is recovered
> within a second or two by whichever net gets it first — the off-road clock, or
> `fell_off_world_y` if it drops through. Two alternatives were considered and
> rejected: sizing the corridor to the true worst case (`timeout × top speed`) widens
> the precompute band by ~40%, paying loading time and VRAM on **every** stage; and
> building the chunk on demand pays a main-thread hitch, for ground the player is
> about to be teleported off anyway.

1. `world.gd._generate_track` (loading stage "Precomputing chunks…") calls
   `TerrainManager.corridor_coords(centerline, leash_m)` to get the full coord
   list, then `set_corridor(coords)` and loops `cache_chunk(coord)` in
   **batches of 8 per awaited frame** so the loading bar keeps painting.
   The `print("terrain precompute: %d chunks, %.1f MB cached")` line reports the
   total (`cache_size_mb()`'s per-type packed-array accounting). It is logged
   *during* the precompute, so it still counts the baked `lights` that
   `load_finished` drops shortly afterwards — the resident figure is lower.
   Since the dead-array free (see **What the cache keeps** above) a stage measures
   in the **single-digit MB**, down from ~46 MB for ~200 chunks before it.
   `bake_track` also logs its five dictionaries' entry counts
   (`track bake fields: …`) — `cliff_offsets` dominates, and on a measured stage
   the three freed dicts came to ~99k entries (≈6–9 MB at Godot's ~60–90 bytes per
   `HashMap` entry), i.e. materially **less** than `todo/mobile-web-performance.md`
   2.7's 20–30 MB estimate.
2. Chunk generation itself is unchanged at the single-chunk level:
   `compute_chunk_data(coord)` (noise + mesh arrays, pure CPU) runs a
   `TerrainChunkBuilder.build()` (`scripts/terrain_chunk_builder.gd`) to
   completion and returns its `data()` dict in one call — there is no
   worker-thread pool or resumable/incremental path anymore; a
   `TerrainChunkBuilder` instance is just a local scratchpad for the row loop.
3. At runtime, `_reconcile` (driven by `update_focus` on chunk-boundary
   crossings) is a **cache pull, not a build**: `_chunk_cache` lookup +
   `_spawn_chunk` (mesh + `HeightMapShape3D` from the cached data) — measured
   **~0.2 ms** per crossing, no stutter possible because there's no CPU-heavy
   noise/mesh work left on the hot path.
   - **Empty cache** (editor previews, most headless tests that never call
     `precompute_corridor`): `_reconcile` silently falls through to a fresh
     `compute_chunk_data(coord)` — the old synchronous on-demand behaviour,
     unchanged so `@tool` editing and existing tests keep working.
   - **Populated cache, coord missing**: **spawn nothing**, leaving a hole (holes over
     hitches). Whether it is *logged* depends on which side of the corridor it is on:
     a coord INSIDE the corridor (`_corridor_class` has an entry) is a real bug — the
     region maths broke, or the cache was cleared out from under us — and gets a
     `push_error` once per coord. A coord OUTSIDE it is a deep off-road excursion (see
     the caveat above), which is expected rather than broken, so it stays silent.

`integrations_total` still counts chunk nodes spawned (mesh + collision
build); `PerfOverlay` (see [debug-tools.md](debug-tools.md)) reads its
per-frame delta.

### Profiling chunk-loading cost

- **In-game:** toggle the frame profiler overlay with **P** — it splits CPU
  (process / physics / render-cpu) from GPU (render-gpu) and logs `[PERF SPIKE]`
  lines noting whether a chunk integrated that frame. Use this to tell a terrain
  hitch from a steady GPU-bound frame.
- **On-demand benchmark:** `./run_benchmark.sh` (standalone, NOT a test — see
  [debug-tools.md](debug-tools.md)) benchmarks `compute_chunk_data` (CPU:
  noise + mesh arrays), `_spawn_chunk` (main-thread: ArrayMesh +
  `HeightMapShape3D`), the per-boundary-crossing integration cost, and —
  windowed — the real scene's render cpu/gpu time. Numbers are
  machine-dependent, so it just prints a report; there's no pass/fail gate.
  Last measured: 204 chunks / 46.2 MB precomputed, ~1 non-terrain spike per
  600 frames post-load (the precompute absorbs what used to be per-crossing
  cost).

## Tests

`tests/headless/test_terrain.gd` — `height_at` values and seed determinism,
chunk-coord math, chunk mesh/collision build, the **seam test** (adjacent chunks
agree on the shared edge), and the **load/unload test** (full ring loaded around the
focus; distant chunks freed when the focus moves).
`test_cached_chunk_data_matches_fresh_compute` guards that a cached chunk's
data is byte-identical to a fresh `compute_chunk_data` call (replaces the old
incremental-vs-monolithic comparison now that there's only one build path).

`tests/headless/test_terrain_memory.gd` — what the cache and the track bake keep
versus drop, and the sentinels: dead mesh arrays erased but collision / `height_at`
still correct, despawn-and-respawn from cache, `apply_data`'s missing-arrays branch
erroring loudly while still building collision, `light_at` baked before the free and
loud after it, `surface_at` surviving the bake-field free, and the corridor-complete
gate leaving the on-demand rebake path working.

`tests/headless/test_terrain_precompute.gd` — the precomputed-corridor
machinery: `corridor_coords` region math (covers every reachable position
within the leash band, including straight-span sub-sampling), `set_corridor`/
`cache_chunk`/`precompute_corridor`, cache-first `height_at`/`light_at`
(matches the flattened/lit chunk data, not raw noise), and the empty-cache /
populated-cache-miss fallback behaviour in `_reconcile`.

## Night: the one thing the terrain shader does not bake

Terrain shading is otherwise entirely baked (vertex colours, generated once — see
"TerrainManager"), but the terrain is **no longer purely flat-shaded**: on a night
stage `shaders/ps1_models.gdshader` adds the fake headlight cone into the light
term in its **fragment** stage,
`ALBEDO = surface * (COLOR.rgb + hl_color * headlight_lit(world_pos))`. World
position is recovered per fragment from `INV_VIEW_MATRIX`.

Three constraints this had to respect, all still true:

- **`ps1_models` still has NO `vertex()` stage**, and must not gain one — terrain
  is the heaviest geometry in the game, so its vertex path stays pass-through.
  Enforced by `test_render_smoke.gd::test_terrain_shader_has_no_vertex_stage`
  (which also bans the string `light_amount` from it) and re-asserted by
  `test_headlight_cone.gd`. That ban is *why* the cone is fragment-side here and
  why world position costs a mat4 multiply per fragment; view space would be
  cheaper but is wrong, since the uniforms are global and the game has several
  cameras.
- **Fragment, not vertex, is the right stage anyway**: cells reach 25 m across at
  the coarsest LOD stride, so a per-vertex cone would snap its soft edge to
  triangle boundaries. (Everything else — cars, trees, bushes — takes it per
  vertex.)
- **Uniform-set parity with `ps1_terrain_snow` is load-bearing.**
  `world.gd::_apply_deep_snow_ground` swaps the floor material between the two
  shaders every stage boot and re-applies only `snow_depth`, relying on
  `ShaderMaterial` keeping its by-name parameter map across the swap. That works
  only while the two declare identical uniform sets, so **any uniform added to
  one must be added to the other** — both `#include`
  `shaders/headlight_cone.gdshaderinc` for exactly this reason.

Nothing about the bake, the chunk cache or `data/track_cache.json` changes: the
cone is per-frame arithmetic from global uniforms, and weather never reaches
`TrackGenParams`. See [rendering.md](rendering.md) → "The fake headlight cone"
and [weather.md](weather.md) → "Night" (five stages author it, one per region).

## Region look overrides

A rally's `region` (see [regions.md](regions.md)) can override the ground
textures the floor shader reads. `world.gd._apply_region_look` (called right
after the base environment is built) sets the floor's `chunk_material` shader
params — `albedo_texture` from the region's `grass_texture`, `road_texture`
from `gravel_texture` — whenever the region authors them; a region that omits
a key (home authors none) leaves the `main.tscn`-baked baseline untouched. The
`background_color`/`fog_light_color` get the same treatment.

The **sky panorama does not**, and this doc used to claim otherwise.
`world.gd::_apply_region_look` assigns `sky_mat.panorama` **unconditionally**,
falling back to `Config.data.default_sky_panorama` when the region authors no
`sky_panorama` key. That is deliberate, not an oversight: the
`PanoramaSkyMaterial` is a shared sub-resource with no `resource_local_to_scene`,
so an only-if-authored assignment let one region's sky follow the player into
later stages. [regions.md](regions.md) has always been right about this. See
[rendering.md](rendering.md) for the shader/sky plumbing itself. Terrain tints/layers per region are a reserved, unused hook —
no region ships them yet.

## Related config

`terrain_layer{1,2,3}_{wavelength,amplitude}` and `terrain_tile_per_meter`. For the overworld:
`overworld_edge_taper_m` / `overworld_edge_depth_m` (the coastline) and
`overworld_pad_zone_radius_m` / `overworld_pad_garage_radius_m` / `overworld_pad_feather_m` /
`overworld_pad_max_grade` / `overworld_pad_max_feather_m` (the flat pads — all five are baked, so
retuning any of them re-warms the chunk cache). See
[configuration.md](configuration.md).
