# Road Edge Smoothing — Design

**Date:** 2026-06-16
**Status:** Approved for planning

## Goal

Soften the hard step at the road edge. The road keeps its full flat width; a
configurable transition band (default 2–3 cells) just **outside** the road edge
ramps both the terrain height and the vertex colour from the road's flattened
value to the true terrain. Applies to mesh and collision.

## Background

Road flattening (see `features/track.md` / `terrain.md`) currently uses a hard
per-vertex cutoff: `TerrainManager.bake_road` records a flattened Y for every
grid vertex within `track_width/2` of the centerline, and `compute_chunk_data`
replaces those vertices' height outright. Colour is a binary set (`track_cells`):
cells within `width/2` get `track_color`, others `default_cell_color`. The result
is a vertical step wherever the terrain is tilted.

Conventions: global grid-vertex index `Vector2i(coord.x*(SAMPLES-1)+xi, …)`;
global cell index `Vector2i(coord.x*(SAMPLES-1)+xi, …)`; `CELL_M = 0.5`. The
centerline `Curve2D` maps x→world x, y→world z.

## Decisions

- **Band outside the road.** The flat drivable surface stays `track_width` wide;
  the transition is extra cells beyond `width/2`. The road already tuned is
  unchanged — only the shoulder feathers.
- **Configurable width in cells.** `track_transition_cells: int` (default `3`);
  `transition_m = track_transition_cells * CELL_M`.
- **Weighted fields replace the binary cutoff.** A blend weight `w ∈ [0,1]` per
  grid feature: `1` where distance ≤ `width/2`, smoothstep-ramping to `0` at
  `width/2 + transition_m`. Both height and colour blend by `w`.
- **Mesh + collision** both use the blended height (consistent with the existing
  flattening).

## Components

### `GameConfig` (`scripts/game_config.gd` + `config/game_config.tres`)

- Add `track_transition_cells: int` (default `3`) to the `Track` group.

### `TerrainManager` (`scripts/terrain_manager.gd`)

State (replacing `track_cells` + plain `road_heights`):

- `road_heights: Dictionary` — vertex index (`Vector2i`) → nearest-centerline Y
  (for every vertex within `width/2 + transition_m`).
- `road_blend: Dictionary` — vertex index → blend weight `w` (omitted where 0).
- `track_weights: Dictionary` — cell index → colour blend weight `w` (omitted
  where 0).
- Keep `track_color`, `default_cell_color`.

`bake_track(centerline: Curve2D, width: float, transition_m: float)` — one pass:
densely sub-sample each centerline segment (`ROAD_SAMPLE_STEP_M`); for each
sample point `p` with `y = height_at(p)`:
- stamp grid **vertices** within `outer = width/2 + transition_m`: weight
  `w = smooth_ramp(distance, width/2, outer)`; if `w > 0` and nearer than any
  prior sample for that vertex, set `road_heights[v] = y`, `road_blend[v] = w`.
- stamp **cells** (cell-centre distance) the same way into `track_weights`,
  keeping the max weight per cell.

Helper `smooth_ramp(d, inner, outer)` → `1` for `d ≤ inner`, `0` for `d ≥ outer`,
smoothstep between: `raw = clampf((outer-d)/(outer-inner), 0, 1)`, return
`raw*raw*(3-2*raw)`.

`compute_chunk_data` height: after the noise height `h`, if
`road_blend.has(vidx)` then `h = lerpf(h, road_heights[vidx], road_blend[vidx])`
— used for **both** the mesh vertex and the collision `heights` entry.

`cell_colors(coord)`: each cell colour is
`default_cell_color.lerp(track_color, track_weights.get(cell, 0.0))`.

`set_track(centerline: Curve2D, width: float, transition_m: float, color: Color)`
— store `track_color`, call `bake_track(...)`, then rebuild any currently-loaded
chunks via `setup()` (geometry changes). At startup the ring is deferred, so
nothing rebuilds.

Remove the old `track_cells` field, the old `bake_road`, and the old
`set_track(cells, color, road_heights)`.

### `world.gd`

`_generate_track`: after generating the track, call
`$Floor.set_track(result["centerline"], cfg.track_width,
cfg.track_transition_cells * TerrainManager.CELL_M, cfg.track_color)` then
`$Floor.build_initial()`. (No separate `bake_road` call — `set_track` bakes.)

### `main.tscn`

Unchanged (`defer_initial_build = true` stays).

## Data flow

`world._ready` → generate 2D track → `set_track(centerline, width, transition,
color)` bakes weighted height + colour fields and stores them (ring deferred, no
rebuild) → `build_initial()` builds the ring with blended height + colour baked
in. Chunks loaded later while driving read the stored fields in
`compute_chunk_data` / `cell_colors`. The generator's `cells` output is used only
for its own overlap search, not for rendering.

## Testing (`tests/headless/test_terrain.gd`)

- `bake_track`: a vertex inside `width/2` has `road_blend == 1`; a vertex in the
  band has `0 < road_blend < 1`; a vertex beyond `width/2 + transition_m` is
  absent. `road_heights` holds the nearest centerline height for in-road
  vertices. `track_weights` follows the same 1 → fractional → absent pattern per
  cell.
- `compute_chunk_data`: an on-road vertex is fully flattened (`h == road Y`,
  mesh + collision); a band vertex's height lies strictly between its noise
  height and the road Y; an off-band vertex keeps its noise height.
- `cell_colors` / mesh colours: an on-road cell is `track_color`; a band cell is
  between `track_color` and `default_cell_color`; an off-band cell is
  `default_cell_color`.
- `set_track(centerline, width, transition_m, color)` rebuilds loaded chunks with
  the blended geometry/colour.
- Update tests that referenced `track_cells` / `bake_road` / the old `set_track`
  signature to the new API.
- `tests/headless/test_smoke.gd`: `main.tscn` applies a track (`track_weights`
  non-empty) and the deferred ring is built (9 chunks).
- Full `./run_tests.sh` green before completion.

## Documentation

Update `features/terrain.md` (weighted `road_heights`/`road_blend`/`track_weights`,
`bake_track`, `smooth_ramp`, blended height + colour, new `set_track` signature,
removal of `track_cells`/`bake_road`) and `features/track.md` (the road edge
feathers over `track_transition_cells` cells in height and colour). Add
`track_transition_cells` to the `Track` config docs.

## Out of scope

- Per-vertex (sub-cell) colour gradients — colour stays per-cell (stepped).
- Inside-the-road transition (the band is strictly outside `width/2`).
- Banking / camber.
- Changing the generator's overlap logic or `cells` output.
