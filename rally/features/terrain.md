# Terrain

**Source:** `scripts/terrain_manager.gd` (`@tool extends Node3D`,
`class_name TerrainManager`), `scripts/terrain_chunk.gd`
(`@tool extends StaticBody3D`, `class_name TerrainChunk`),
`scripts/terrain_layer.gd` (`@tool class_name TerrainLayer`).

Procedurally generated rolling terrain from stacked Perlin noise. The terrain is
**infinite in theory**: `height_at(x, z)` is a pure function of absolute world
coordinates, so any point in the world has a defined height. Only the car's
immediate surroundings are ever built — a moving 3×3 grid of chunks that loads
and unloads as the car drives. `@tool` means chunks also regenerate live in the
editor (centred on the origin, since there is no car there), and config drives
the manager at runtime via `world.gd`.

## Dimensions

- `CHUNK_M = 50.0` — each chunk is 50×50 m.
- `CELL_M = 1.0` — 1 m grid cells (low-poly PS1 terrain; quarter the triangles
  and collision samples of the old 0.5 m cells).
- `SAMPLES = 51` — 51×51 height vertices per chunk (`CHUNK_M / CELL_M + 1`).
- `RADIUS = 1` — a (2·RADIUS+1)² = **3×3** ring of chunks is kept loaded around
  the car (~150 m span). Chunks are generated on worker threads as the car
  approaches each boundary.

## TerrainManager

Owns all terrain state and the chunk lifecycle.

- `noise_seed: int` — deterministic; changing it rebuilds loaded chunks.
- `layers: Array[TerrainLayer]` — each layer is a (`wavelength_m`,
  `amplitude_m`) pair. Defaults set in `_default_layers` on `_ready` if empty.
- `texture_tile_per_meter: float` — UV tiling for the ground texture (the road
  texture tiles independently via `road_tile_per_meter`, applied as the shader's
  `road_uv_scale`; see [rendering.md](rendering.md)).
- `chunk_material: Material` — applied to every chunk mesh (set to the shared
  floor material in `main.tscn` so it survives runtime mesh assignment).
- `focus_path: NodePath` — the node whose position drives loading (the car,
  `../Car`). Empty in tests so the focus is driven explicitly.

Key methods:

- `height_at(x, z)` — sums all layers at a single world position. Uses a
  main-thread noise cache (`_ensure_noise_cache`, invalidated by `_rebuild_loaded`)
  so repeated spot samples (e.g. `bake_track`) don't rebuild the noises each call.
- `build_heights(center)` — a `SAMPLES²` height array centred on a chunk centre,
  sampling absolute world coords with the noises built once (fast path for the
  ~10k samples per chunk).
- `_build_noises()` / `_sample_height(noises, amplitudes, x, z)` — shared layer
  sampling. `_build_noises` returns a fresh `[noises, amplitudes]` pair; worker
  paths (`compute_chunk_data`, `build_heights`) build their own (FastNoiseLite is
  shared mutable state), the main thread reuses the cached pair.
- `chunk_coord_for(pos)` / `target_coords(center)` — integer chunk-grid math.
- `update_focus(pos)` — recompute the car's chunk coord and, when it changes,
  `_reconcile` the loaded set: free chunks outside the 3×3 ring, instantiate and
  `setup()` the missing ones. Called every frame from `_process`; cheap because
  it early-returns until the car crosses a chunk boundary.

## TerrainChunk

One tile, created at runtime by the manager. Positioned at its chunk **centre**
`((cx+0.5)·CHUNK_M, 0, (cz+0.5)·CHUNK_M)` so the centred mesh and collision span
exactly the tile.

- Mesh — built from precomputed arrays in `apply_data`. The mesh is **indexed**:
  one shared vertex per grid sample (`SAMPLES²`), with `cells·6` indices. This is
  a quarter the vertices of the old de-indexed mesh (4 verts/cell) — the main PS1
  vertex-throughput win. `ARRAY_COLOR` is therefore **per-vertex** (Gouraud), so
  the road texture weight (alpha) blends smoothly across cells instead of
  stepping per square (see `vertex_colors` below). UVs use **world** coordinates
  × `texture_tile_per_meter` so the textures stay continuous across seams. Front faces wind
  clockwise. **No normals** are stored — the floor shader is `unshaded`.
- `_build_collision` — a `HeightMapShape3D` (map_width/depth = `SAMPLES`), with
  the `CollisionShape3D` scaled to 0.5 m cells (the standard workaround, since
  `HeightMapShape3D` has no cell-size property). Collision still uses the full
  `SAMPLES²` height array, independent of the de-indexed render mesh.

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
  unaffected.
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
  surface_feather_m)` — call
  `bake_track`, and **rebuild any currently-loaded chunks** (full `setup()`, since
  geometry changes). At startup the ring is deferred (see below), so nothing is
  loaded here and nothing rebuilds; chunks loaded later bake the blend at build
  time. (Replaces the older binary `track_cells` + `bake_road`.)

### Deferred initial build

`defer_initial_build` (set on `Floor` in `main.tscn`) makes `_ready` skip the
initial ring so `world.gd` can apply the track first, then call `build_initial()`
— the ring is built once, already flattened, with no rebuild. The editor always
previews terrain regardless of the flag.

## Boundary

None. With infinite chunks there is always collision ground beneath the car, so
the old `Border` safety wall and far visual plane were removed.

## Fog & distant backdrop

The detailed 3×3 ring's edge sits only ~75–105 m from the car. Rather than hide
that edge with dense fog (which also hid the sky), a coarse **`DistantTerrain`**
backdrop (`scripts/distant_terrain.gd`) extends the visible terrain far past the
ring — collision-free scenery sampling the same `height_at`/`light_at` noise,
re-centred on the car — so the now-thin fog (`fog_density` 0.005) reveals a
horizon for the skybox instead of a cliff. See
[rendering.md](rendering.md) and [../todo/distant-terrain-and-sky.md](../todo/distant-terrain-and-sky.md).
The coarse geometry re-centres on every focus **chunk crossing** and is a
**full, uncut grid** — it underlaps the entire detail ring rather than holing out
the loaded chunks. The rebuild is the same ~2,600-vertex, light-baked cost as a
detail chunk, so it is **deferred**, not run on the crossing frame: a crossing only
marks the backdrop dirty (coalescing to the latest centre), and the actual rebuild
waits for a frame when `TerrainManager.is_streaming_chunks()` is false (no chunk
queued, dispatched, or awaiting integration). This keeps the heavy coarse mesh
build from stacking on top of the detail-ring stream in one frame — on the
single-threaded web build those back-to-back main-thread builds were the bulk of
the chunk-crossing hitch. The backdrop is huge and fog-softened, so the few frames'
lag in re-centring is imperceptible. To stop it poking through the detailed terrain, the **whole
backdrop is sunk `sink_m`** (default 1.5 m, `GameConfig.distant_terrain_sink_m`)
below true height, so the detail ring always renders above it and the coarse mesh
stays hidden beneath. At the ring's outer edge the coarse surface steps down by
`sink_m`, but that edge is ~75 m away and softened by fog, so the step is
imperceptible. This also guarantees the skybox is never exposed (the backdrop
covers everything, including chunks the detail ring hasn't streamed in yet). It
trades a tiny, constant bit of occluded coarse overdraw under the detail ring for
**zero per-crossing work** — no loaded-chunk tracking, no index re-cut on chunk
integration, no skybox-flash race; the backdrop only rebuilds on a chunk
crossing. Tunables: `GameConfig.distant_terrain_*`.

## Performance

Chunk generation is split into a pure `compute_chunk_data(coord)` (noise +
mesh arrays — all CPU math) and a cheap main-thread `apply_data` (builds the
`ArrayMesh` + `HeightMapShape3D` and adds the node). The per-row work lives in
**`TerrainChunkBuilder`** (`scripts/terrain_chunk_builder.gd`), a resumable builder
that fills the chunk arrays a few grid ROWS at a time. `compute_chunk_data` just
runs a local builder to completion in one call, so the monolithic and incremental
paths produce byte-identical data (guarded by
`test_incremental_build_matches_full_build`); each builder is a local instance, so
the threaded path's concurrent calls never share state.

At runtime (`use_threaded_generation = true`), `compute_chunk_data` runs on a
`WorkerThreadPool` task; `_process` integrates at most
`MAX_INTEGRATIONS_PER_FRAME` (1) finished chunk per frame, so boundary crossings
don't stutter. Worker results land in a `Mutex`-guarded `_results` dict; coords
that leave the ring before integrating are discarded. `_exit_tree` waits on any
outstanding tasks.

The **initial ring** is built synchronously in `_ready` (a one-time startup
hitch — 9 chunks for the 3×3 ring) so there is always ground under the car at
spawn. The **editor**
(`Engine.is_editor_hint()`) and **tests** force `use_threaded_generation =
false` for instant, deterministic builds.

**Web export is deliberately single-threaded** (`export_presets.cfg`
`variant/thread_support=false`) so the build needs no `SharedArrayBuffer` /
cross-origin isolation and boots on any browser, including old / low-memory
phones — the project's "runs on any device" floor (decided: see
`todo/performance-optimisations.md` item 7). Without threads the worker pool
isn't available, so terrain gen runs on the main thread, frame-budgeted so a
boundary crossing doesn't generate a whole ring in one tick (a visible stutter).
`_use_budgeted_generation()` (on whenever `OS.has_feature("web")`, or forced via
`force_main_thread_budget` for desktop tests) routes missing coords into
`_build_queue`; `_pump_build_queue()` then advances generation by at most
`MAX_BUILD_ROWS_PER_FRAME` (16) grid ROWS per frame, holding one in-progress
`TerrainChunkBuilder` (`_active_builder`) across frames and spawning it when
complete. A whole chunk is ~206 rows lit — far more than one phone frame can
afford — so even the old "one chunk per frame" still stalled; row-slicing spreads a
single chunk's build across ~10-15 frames (the fog and the ring's lead distance —
the nearest new chunk is ~0.7 s of travel away at speed — hide the lag). The active
builder counts as "streaming" (`is_streaming_chunks()`, which `DistantTerrain` gates
its rebuild on) and is excluded from re-queueing; a partial build whose coord leaves
the ring is abandoned. This path keys on the `web` platform feature, not on the
export's thread flag, so it was already in force before threads were turned off —
the only thing the single-threaded export changes is dropping the unused engine
thread pools (and the SAB host requirements). `build_initial` (`force_sync`)
still builds the whole initial ring immediately, even on web. **Desktop** keeps
real worker-thread generation (`use_threaded_generation`, threads always
available there).

Newly entered chunks can appear 1–2 frames late, but the car sits well inside
the loaded 5×5 ring and fog hides the far edge, so the pop-in is not visible.

`integrations_total` counts chunk nodes spawned (the main-thread mesh +
collision build). The `PerfOverlay` (see [debug-tools.md](debug-tools.md)) reads
its per-frame delta to correlate frame-time spikes with terrain integration.

### Profiling chunk-loading cost

- **In-game:** toggle the frame profiler overlay with **P** — it splits CPU
  (process / physics / render-cpu) from GPU (render-gpu) and logs `[PERF SPIKE]`
  lines noting whether a chunk integrated that frame. Use this to tell a terrain
  hitch from a steady GPU-bound frame.
- **On-demand benchmark:** `./run_benchmark.sh` (standalone, NOT a test — see
  [debug-tools.md](debug-tools.md)) benchmarks `compute_chunk_data`
  (worker-thread CPU: noise + mesh arrays), `_spawn_chunk` (main-thread:
  ArrayMesh + `HeightMapShape3D`), the per-boundary-crossing integration cost,
  and — windowed — the real scene's render cpu/gpu time. Numbers are
  machine-dependent, so it just prints a report; there's no pass/fail gate.

## Tests

`tests/headless/test_terrain.gd` — `height_at` values and seed determinism,
chunk-coord math, chunk mesh/collision build, the **seam test** (adjacent chunks
agree on the shared edge), and the **load/unload test** (full ring loaded around the
focus; distant chunks freed when the focus moves).

## Related config

`terrain_layer{1,2,3}_{wavelength,amplitude}` and `terrain_tile_per_meter`. See
[configuration.md](configuration.md).
