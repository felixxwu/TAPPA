# Terrain

**Source:** `scripts/terrain_manager.gd` (`@tool extends Node3D`,
`class_name TerrainManager`), `scripts/terrain_chunk.gd`
(`@tool extends StaticBody3D`, `class_name TerrainChunk`),
`scripts/terrain_layer.gd` (`@tool class_name TerrainLayer`).

Procedurally generated rolling terrain from stacked Perlin noise. The terrain is
**infinite in theory**: `height_at(x, z)` is a pure function of absolute world
coordinates, so any point in the world has a defined height. Only the car's
immediate surroundings are ever built — a moving 5×5 grid of chunks that loads
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
- `smooth_ramp(d, inner, outer)` — the weight curve: 1 for `d ≤ inner`
  (`= width/2`), 0 for `d ≥ outer` (`= inner + transition`), smoothstep between.
- `bake_track(centerline, width, transition_m)` — samples `height_at` densely
  along the 2D centerline and fills all three fields (nearest height + ramp
  weight per grid vertex, ramp weight per cell). The road follows terrain
  elevation lengthwise, is flat across its width, and feathers out over the band.
- `compute_chunk_data` — `h = lerp(noise_height, road_heights[v], road_blend[v])`
  for vertices in `road_blend` (**mesh + collision**): weight 1 fully flat,
  weight 0 true terrain, between ramps. Off-band vertices keep their noise height.
- `vertex_colors(coord)` — per grid vertex, RGB is `default_cell_color`; ALPHA is
  the average of the (up to 4) surrounding cells' `track_weights`, so the road
  fade is smooth over the band. `track_weights` is keyed by **global** cell
  coords, so a shared edge vertex averages the same four cells from either chunk
  → weights match exactly across seams.
- `set_track(centerline, width, transition_m)` — call
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

## Fog

The far chunk edge sits ~100–150 m from the car (with the 5×5 ring). Fog (`fog_density` in
`config/game_config.tres`) should hide chunks loading/unloading at that range;
if chunks visibly pop in, increase the fog density.

## Performance

Chunk generation is split into a pure `compute_chunk_data(coord)` (noise +
mesh arrays — all CPU math) and a cheap main-thread `apply_data` (builds the
`ArrayMesh` + `HeightMapShape3D` and adds the node).

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
