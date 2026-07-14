# Terrain

**Source:** `scripts/terrain_manager.gd` (`@tool extends Node3D`,
`class_name TerrainManager`), `scripts/terrain_chunk.gd`
(`@tool extends StaticBody3D`, `class_name TerrainChunk`),
`scripts/terrain_layer.gd` (`@tool class_name TerrainLayer`).

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
  (`_layers_match` guard), so the hill shape follows the live config.
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
  `../Car`). Empty in tests so the focus is driven explicitly.

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
- `build_heights(center)` — a `SAMPLES²` height array centred on a chunk centre,
  sampling absolute world coords with the noises built once (fast path for the
  ~10k samples per chunk).
- `_build_noises()` / `_sample_height(noises, amplitudes, x, z)` — shared layer
  sampling. `_build_noises` returns a fresh `[noises, amplitudes]` pair; worker
  paths (`compute_chunk_data`, `build_heights`) build their own (FastNoiseLite is
  shared mutable state), the main thread reuses the cached pair.
- `chunk_coord_for(pos)` / `target_coords(center)` — integer chunk-grid math.
- `update_focus(pos)` — recompute the car's chunk coord and, when it changes,
  `_reconcile` the loaded set: free chunks outside the 7×7 ring, instantiate and
  `setup()` the missing ones. Called every frame from `_process`; cheap because
  it early-returns until the car crosses a chunk boundary.
- `corridor_coords(centerline, leash_m)` — the full set of chunk coords the
  runtime ring can ever request while the car stays within `leash_m` of the
  centerline (the off-track reset leash): every centerline-sample chunk
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
a downward **skirt** (`terrain_lod_skirt_m`) appended to each level mesh. The LOD meshes are **prebaked
at load** in `cache_chunk` (`TerrainLod.build_all`), so runtime chunk spawns stay
a cheap node build + mesh assign. All tunables live in `GameConfig`
(`apply_terrain_lod`); `TerrainLod` is pure/static and headless-tested
(`tests/headless/test_terrain_lod.gd`).

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

- `road_heights: Dictionary` — grid-vertex index (`Vector2i`,
  `coord.x*(SAMPLES-1)+xi`, shared across seams) → nearest centerline terrain Y.
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
  surface_feather_m)` — samples `height_at` densely along the 2D centerline and
  fills all four fields (nearest height + ramp weight per grid vertex, ramp weight
  + tarmac weight per cell). The road follows terrain elevation lengthwise, is flat
  across its width, and feathers out over the band. Tarmac weight comes from each
  sample's cumulative distance along the polyline via `TrackSurface.tarmac_weight`.
  The surface args default to all-gravel, so callers that don't split surfaces are
  unaffected. A trailing `should_yield: bool = false` (forwarded to `_bake_cliffs`)
  makes the two heavy centerline walks `await get_tree().process_frame` ~40 times each,
  so the interactive loading overlay keeps painting during this multi-second bake
  instead of freezing; it never changes the baked result. Because the body then
  contains `await`, `bake_track` (and `set_track`) are **always coroutines** — call
  them with `await`. With `should_yield` false (the default, and always under headless)
  they never suspend, completing in the same frame, so headless world-build stays
  synchronous. A further trailing `on_progress: Callable(fraction: float)` (forwarded
  from `set_track` and on to `_bake_cliffs`), when valid, is called at the same stride
  with a carve fraction (0→1) — `world.gd` wires it to `LoadingScreen.set_carve_progress`
  so the grey preview line fills white as the bake progresses. The fraction spans BOTH
  passes: the flatten walk fills 0→0.5 when a cliff pass will follow (`_cliffs_active()`),
  else the whole bar 0→1; `_bake_cliffs` fills 0.5→1 — so the line keeps advancing through
  the cliff pass rather than sitting full-white while it runs. Independent of `should_yield`
  (reports even without yielding) and never changes the baked result.
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
- Contested-vertex flatten — the inside crook of a hairpin (or any pocket the road
  wraps around) goes **flat**, detected **geometrically**: per stamped vertex, the
  vertex→sample bearings are unioned into `CLIFF_BEARING_BUCKETS` circular buckets
  (order-independent, wrap-safe — never min/max of the angle). The wrap span =
  `360° − largest empty arc`; a straight / the *outside* of a bend stays within a
  half-plane (≤ 180° → keep the cliff), an inside crook wraps > 180° → flatten.
  Feathered over `cliff_pinch_angle_deg` past 180° (`_contested_from_span`), so the
  taper to flat is continuous (no wedge seam, no step seam).
- **Bake** (`_bake_cliffs`, called at the end of `bake_track`): one coarse
  centerline walk at `CLIFF_SAMPLE_STEP_M` (≫ the road's `ROAD_SAMPLE_STEP_M` — the
  main cost lever, since the stamp band is ~10-20× wider). Per sample: compute
  `camber(s)`; per stamped vertex within `R`, keep the nearest sample's
  `side·camber·profile` and OR its bearing bucket. After the walk, fold the wrap
  span into `contested` and scale by `cliff_max_height_m · cliff_amount`.
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
  `cliff_fade_m`, `cliff_pinch_angle_deg`, `cliff_amount` (runtime per-event scale,
  written by `RallySession` from the event's `cliffiness`), `cliff_seed`
  (`= track_seed`). See the `Cliffs` group in [configuration.md](configuration.md).
- Tests: `tests/headless/test_terrain_cliffs.gd` (zero-when-off/level, flat road +
  band handoff, antisymmetry, bounded, fade-out, determinism, hairpin flatten,
  chunk height, cliff seam).

### Deferred initial build

`defer_initial_build` (set on `Floor` in `main.tscn`) makes `_ready` skip the
initial ring so `world.gd` can apply the track first, then call `build_initial()`
— the ring is built once, already flattened, with no rebuild. The editor always
previews terrain regardless of the flag.

## Boundary

None. With infinite chunks there is always collision ground beneath the car, so
the old `Border` safety wall and far visual plane were removed.

## Fog & distant backdrop

The detailed 7×7 ring's edge sits ~175 m from the car (its far chunks are cheap
coarse LOD levels). Rather than hide
that edge with dense fog (which also hid the sky), a coarse **`DistantTerrain`**
(`scripts/distant_terrain.gd`, a plain `Node3D`) extends the visible terrain far
past the ring — collision-free scenery sampling the same `height_at`/`light_at`
— so the now-thin fog (`fog_density` 0.005) reveals a horizon for the skybox
instead of a cliff. See [rendering.md](rendering.md) and
[../todo/distant-terrain-and-sky.md](../todo/distant-terrain-and-sky.md).

Because the play area is now a **bounded corridor** (the off-track reset leash
caps how far the car can ever get from the track), the backdrop no longer
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
over a bounded corridor**, done behind the loading screen. The play area is
bounded because the off-track reset leash caps how far the car can ever get
from the track, so the reachable chunk set is knowable in advance:

1. `world.gd._generate_track` (loading stage "Precomputing chunks…") calls
   `TerrainManager.corridor_coords(centerline, leash_m)` to get the full coord
   list, then `set_corridor(coords)` and loops `cache_chunk(coord)` in
   **batches of 8 per awaited frame** so the loading bar keeps painting.
   Measured on the default stage: **204 chunks, 46.2 MB** cached
   (`print("terrain precompute: %d chunks, %.1f MB cached")`), roughly
   **~185 KB/chunk** (heights + mesh arrays + baked lights, all packed
   arrays — see `cache_size_mb()`'s per-type accounting).
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
   - **Populated cache, coord missing** (the corridor/leash invariant broke —
     should never happen in play): `push_error` and the same synchronous
     fallback — a slow frame, not a hole in the ground.

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

`tests/headless/test_terrain_precompute.gd` — the precomputed-corridor
machinery: `corridor_coords` region math (covers every reachable position
within the leash band, including straight-span sub-sampling), `set_corridor`/
`cache_chunk`/`precompute_corridor`, cache-first `height_at`/`light_at`
(matches the flattened/lit chunk data, not raw noise), and the empty-cache /
populated-cache-miss fallback behaviour in `_reconcile`.

## Region look overrides

A rally's `region` (see [regions.md](regions.md)) can override the ground
textures the floor shader reads. `world.gd._apply_region_look` (called right
after the base environment is built) sets the floor's `chunk_material` shader
params — `albedo_texture` from the region's `grass_texture`, `road_texture`
from `gravel_texture` — whenever the region authors them; a region that omits
a key (home authors none) leaves the `main.tscn`-baked baseline untouched. The
`WorldEnvironment` sky panorama and `background_color`/`fog_light_color` get
the same treatment; see [rendering.md](rendering.md) for the shader/sky
plumbing itself. Terrain tints/layers per region are a reserved, unused hook —
no region ships them yet.

## Related config

`terrain_layer{1,2,3}_{wavelength,amplitude}` and `terrain_tile_per_meter`. See
[configuration.md](configuration.md).
