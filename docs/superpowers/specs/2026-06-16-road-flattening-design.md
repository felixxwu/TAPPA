# Road Flattening — Design

**Date:** 2026-06-16
**Status:** Approved for planning

## Goal

Make the generated track read as a real road: terrain grid nodes on the road are
lowered/raised to the road's height so the road surface is flat across its width,
producing a sharp vertical step at the road edge wherever the surrounding terrain
is tilted. Builds on the existing track generation + vertex-color rendering (see
`features/track.md`).

## Background

- `TrackGenerator.generate(...)` produces a pure-2D centerline `Curve2D` (world
  XZ) + an occupied-cell set. It has no height information.
- Terrain is chunked (`scripts/terrain_manager.gd` / `terrain_chunk.gd`): a 3×3
  ring of `CHUNK_M = 50` m chunks on a `CELL_M = 0.5` m grid, `SAMPLES = 101`.
  Chunk meshes are de-indexed (4 verts per cell) with per-cell vertex colors;
  collision is a `HeightMapShape3D` from a separate `SAMPLES²` height array.
- Grid sample vertices lie on the global 0.5 m grid: world x = `coord.x*50 +
  xi*0.5`, so a **global vertex index** `Vector2i(roundi(world_x/0.5),
  roundi(world_z/0.5)) == Vector2i(coord.x*(SAMPLES-1)+xi, coord.y*(SAMPLES-1)+zi)`
  is shared across chunk seams.
- Startup ordering today: `TerrainManager._ready` (a child) builds the initial
  ring before `world._ready` (the parent) runs.

## Decisions

- **Road height = terrain sampled along the centerline.** The road follows the
  terrain's elevation lengthwise but is flat across its width.
- **Flatten mesh + collision.** Both the rendered surface and the heightmap, so
  the car physically drives on the flat road.
- **Per-vertex rule.** A grid vertex is "on road" if within `track_width/2` of
  the centerline; its height becomes the Y of the nearest centerline point.
  Vertices just outside keep their noise height → a sharp step at the edge.
- **No rebuild.** The track is generated *before* the terrain ring is built, so
  flattening is baked in on first build. The initial-ring build is deferred out
  of `TerrainManager._ready` and triggered by `world` after the track is applied.

## Components

### `TrackGenerator` — unchanged

Still returns `{ centerline, cells, pieces, complete }`. Height sampling and
baking happen in the terrain/world layer where `height_at` is available.

### `TerrainManager` changes (`scripts/terrain_manager.gd`)

- New state: `road_heights: Dictionary` — global vertex index (`Vector2i`) →
  flattened Y. Default empty.
- New `@export var defer_initial_build := false`. When `true`, `_ready` does NOT
  build the initial ring (so a parent can order generation first). Default
  `false` keeps tests and the editor (`@tool`) building in `_ready` as today.
- Extract the current `_ready` initial-ring logic into `build_initial()`:
  resolve the focus, `_reconcile(chunk_coord_for(origin), true)`, set
  `_last_focus_coord`. `_ready` calls it unless `defer_initial_build`.
- `bake_road(centerline: Curve2D, width: float)` — tessellate the centerline;
  sample `height_at(x, z)` at each point to get a 3D centerline; build
  `road_heights` by stamping every global vertex index within `width/2` of each
  centerline sample, keeping the nearest sample's height (min distance wins).
  Stores the result in `road_heights` and returns it.
- `set_track(cells, color, road_heights)` — store `track_cells`, `track_color`,
  `road_heights`; then rebuild any **currently-loaded** chunks via `setup()`
  (mesh + collision). At startup the ring is deferred, so `_chunks` is empty and
  nothing rebuilds; called at runtime with chunks loaded, it rebuilds them.
- `compute_chunk_data(coord)` — when sampling each grid vertex, compute its
  global vertex index; if it is in `road_heights`, use that height for **both**
  the mesh grid position and the `heights` (collision) array; otherwise use the
  noise height. Colors are unchanged (still `cell_colors`).

### `world.gd` change

Replace the current single `_generate_track(cfg)` call with the ordered flow,
all in `_ready` after `$Car.apply_car(0)`:

1. Generate the track from the car's spawn pose (position + −Z forward → XZ) with
   the `track_*` config knobs.
2. `road_heights = $Floor.bake_road(result.centerline, cfg.track_width)`.
3. `$Floor.set_track(result.cells, cfg.track_color, road_heights)`.
4. `$Floor.build_initial()` — builds the ring once, already flattened.

`$Floor` has `defer_initial_build = true` set in `main.tscn`.

### `main.tscn` change

Set `defer_initial_build = true` on the `Floor` node.

## Data flow & ordering

`world._ready` runs after the (deferred) `Floor._ready`, so: track generated →
centerline heights sampled (`bake_road`) → cells/color/road_heights stored
(`set_track`, no chunks yet) → `build_initial()` builds the flattened ring. New
chunks loaded while driving read `road_heights`/`track_cells` in
`compute_chunk_data` and bake flattening at build time. No chunk is ever rebuilt
at startup.

## Testing

- **`tests/headless/test_terrain.gd`**:
  - `bake_road` maps a vertex within `width/2` of a known centerline to that
    centerline's sampled height, and leaves a far vertex out of `road_heights`.
  - `compute_chunk_data` with a populated `road_heights` sets on-road grid
    vertices (mesh) **and** the matching collision `heights` entries to the
    flattened height, while off-road vertices keep their noise height.
  - Update the existing `set_track` test: it now passes `road_heights` and
    asserts a road cell's vertices are flattened after the in-place rebuild
    (the old "geometry unchanged" assertion is intentionally replaced, since
    flattening changes geometry by design).
  - `defer_initial_build = true` means `_ready` builds no chunks until
    `build_initial()` is called.
- **`tests/headless/test_smoke.gd`**: still asserts `main.tscn` generates a
  non-empty track (the deferred build + ordered apply must leave the ring built
  and `track_cells` non-empty).
- Full `./run_tests.sh` green before completion.

## Documentation

Update `features/terrain.md` (road flattening: `road_heights`, `bake_road`,
`defer_initial_build`/`build_initial`, flattened mesh + collision) and
`features/track.md` (the road is flattened into the terrain; startup ordering
generates the track before the terrain ring builds, so no rebuild).

## Out of scope

- Smoothing / ramps at the road edge (the step is intentional).
- Banking/cambering corners (road is flat across width).
- Re-sampling road heights when terrain noise changes at runtime.
- Widening flattening beyond the colored road width.
