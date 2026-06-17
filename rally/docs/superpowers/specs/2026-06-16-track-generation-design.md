# Track Generation + Rendering — Design

**Date:** 2026-06-16
**Status:** Approved for planning

## Goal

Generate a rally stage by chaining the pacenote corner shapes (see
`features/track.md`) into a 15-turn track from the car's spawn position, and
render it by recoloring the 0.5 m terrain cells the track covers. Generation is
a purely 2D constraint search that never regenerates the terrain.

## Background

- Corner shapes live in `scripts/corner_library.gd` as `Curve2D` control points
  (meters; entry at origin heading +Y; right-hand turns). `CornerLibrary.build_curve`
  turns one entry into a `Curve2D`.
- Terrain is infinite/chunked (`scripts/terrain_manager.gd`,
  `scripts/terrain_chunk.gd`): a moving 3×3 ring of `CHUNK_M = 50` m chunks on a
  `CELL_M = 0.5` m grid. Chunk meshes use world-coordinate UVs on a checker
  texture via `shaders/ps1_models.gdshader` (`unshaded`). Mesh normals exist but
  are unused by the unshaded shader.
- Chunk vertices already lie on the global 0.5 m grid (world x =
  `coord*50 + xi*0.5`), so a global cell index `floori(world / CELL_M)` is
  well-defined and shared across chunks.

## Decisions

- **Chain shape:** corner → connecting straight → corner (a straight of random
  length is inserted between each corner).
- **Overlap:** hard-avoid. Generation is a DFS backtracking search (strategy A)
  that rejects any piece whose cells collide with already-placed cells, and
  backtracks when a step has no valid candidate.
- **Rendering:** vertex-color the terrain chunk meshes (strategy B). Cells get
  per-cell `ARRAY_COLOR`; the shader multiplies albedo by `COLOR`.
- **No terrain regen:** track generation is pure 2D (no terrain height needed —
  colored verts already sit at terrain height). Applying the track recolors
  loaded chunks in place; it never rebuilds geometry or re-runs noise.

## Components

### `TrackGenerator` (`scripts/track_generator.gd`, `RefCounted`)

Pure 2D, no scene nodes, no terrain dependency. Runs the search and returns a
`TrackResult` dictionary:

- `centerline: Curve2D` — the full track centerline in world XZ (meters).
- `cells: Dictionary` — `Vector2i` global cell coord → `true`, every 0.5 m cell
  within `width/2` of the centerline.
- `pieces: Array` — ordered piece descriptors (for tests/inspection).

Inputs: start position (`Vector2`, world XZ), start heading (`Vector2`, unit),
`seed: int`, `turn_count: int`, `width: float`, plus constants for the candidate
straight-length set and the cell size (`CELL_M = 0.5`).

#### Piece & candidate space

A **piece** = (connecting straight length) + (corner type, L/R flip). Per step,
candidates are the Cartesian product of:

- corner ∈ `CornerLibrary.CORNERS` excluding the `"Straight"` entry,
- flip ∈ {`false` = right, `true` = left} (left mirrors X of every position and
  both control handles),
- straight length ∈ `STRAIGHT_OPTIONS_M` (a fixed const set, e.g.
  `[0.0, 5.0, 10.0, 20.0]`).

Candidates are shuffled deterministically with the seeded RNG.

#### Frame & placement

A **frame** holds the current end position + heading (a `Transform2D` whose +Y
axis is the heading). It starts at the spawn position with the start heading.
To place a piece:

1. Emit the connecting straight: extend `straight_length` along the heading.
2. Transform the (optionally X-mirrored) corner's `Curve2D` control points
   through the frame and append to the world centerline (skip the duplicate
   shared point at the join).
3. Advance the frame: origin = the piece's exit point; heading = the exit
   tangent direction (from the last two tessellated centerline points, robust
   for all corner shapes including the zero-handle straight).

Joins are G1-continuous because each piece's entry tangent (+Y local) is aligned
to the previous exit heading.

#### Validity (overlap test)

Rasterize the candidate piece's cells: sample its centerline densely (≤ `CELL_M`
spacing) and add every cell within `width/2` of each sample (cell = `Vector2i`
of `floori(world / CELL_M)`). The piece is **invalid** if any of its cells is
already in the occupied set, **excluding** a small join buffer of cells near the
entry (the new piece legitimately abuts the previous one there). Buffer:
exclude cells within a short distance (e.g. `width`) of the piece's entry point
from the collision check.

#### DFS backtracking (strategy A) + safety

A stack with one frame per placed corner, each holding
`{shuffled_candidates, next_index, placed_cells, saved_frame}`:

- At a depth, try candidates from `next_index`. The first valid one is placed
  (its cells added to the occupied set), and search advances to the next depth.
- If a depth exhausts its candidates, **pop**: remove the last piece's cells,
  restore the saved frame, and resume the previous depth at its `next_index`.
- **Safety cap:** a maximum total placement/backtrack count. If exceeded,
  **random restart** — clear all state and restart the whole search with a
  perturbed seed (`seed + restart_count`). A bounded number of restarts; if all
  fail the generator returns the longest valid partial track it found and logs a
  warning (never hangs, never crashes).

Openness-ordered candidates are a noted future refinement, not in this cut.

### `TerrainManager` changes (`scripts/terrain_manager.gd`)

- New state: `track_cells: Dictionary` (default empty), `track_color: Color`
  (default the track color), and `default_cell_color: Color` (default white, so
  the checker texture shows through unchanged where there is no track).
- `compute_chunk_data` now builds a **de-indexed** mesh: each 0.5 m cell emits
  its own 2 triangles with its own vertices, so per-cell `ARRAY_COLOR` produces
  crisp squares. Each cell's color is `track_color` if its global cell coord is
  in `track_cells`, else `default_cell_color`. UVs stay world-coordinate. Normals
  are dropped (unused by the unshaded shader); collision is unaffected (it uses
  the separate `HeightMapShape3D` from the height array, unchanged).
- `set_track(cells: Dictionary, color: Color)` — stores the cells/color and
  **recolors every loaded chunk in place**: reassemble each chunk's mesh surface
  with a freshly computed COLOR array, reusing the existing vertices/UVs/heights
  (no noise, no worker threads, no height sampling). New chunks loaded later read
  `track_cells` at build time in `compute_chunk_data` (read-only after
  generation → safe on worker threads).

`TerrainChunk` gains a way to replace just its color array (e.g.
`apply_colors(colors)` that re-adds the surface with new colors) used by the
recolor path.

### `ps1_models.gdshader` change

Add vertex-color support: `ALBEDO = texture(...).rgb * albedo_color.rgb * COLOR.rgb`.
Stays `unshaded`. Meshes without vertex colors default `COLOR` to white, so the
car and other meshes are unaffected.

### `world.gd` change

After `$Car.apply_car(0)`: build the start frame from the car's spawn transform
(position XZ + forward direction), construct a `TrackGenerator` with the
`GameConfig` track knobs, generate the `TrackResult`, and call
`$Floor.set_track(result.cells, cfg.track_color)`.

### `GameConfig` additions (`scripts/game_config.gd` + `config/game_config.tres`)

- `track_width: float` (meters, default e.g. `6.0`).
- `track_color: Color` (default a distinct track color).
- `track_seed: int` (default e.g. `1`).
- `track_turn_count: int` (default `15`).

## Testing

- **`tests/headless/test_track_generator.gd`**: determinism per seed; exactly
  `turn_count` corners placed; no overlaps (each piece's cells disjoint from
  earlier pieces' cells, minus the join buffer); G1 continuity (heading matches
  across each join within tolerance); both L and R flips appear across a few
  seeds; the track starts at the spawn position with the start heading;
  generation terminates within the safety cap.
- **`tests/headless/test_terrain.gd`** (extend): `compute_chunk_data` colors
  on-track cells `track_color` and others `default_cell_color`; the mesh is
  de-indexed (vertex count = `(SAMPLES-1)² × verts_per_cell`); `set_track`
  changes only the color array — vertex positions and the height array are
  identical before/after. The existing **seam** test is updated for the
  de-indexed layout (shared-edge vertices still agree on world position/height);
  the **normals-point-up** test is removed or updated since normals are dropped
  (flagged as an intended change in the plan).
- **`tests/headless/test_render_smoke.gd`** (extend): `ps1_models.gdshader`
  still compiles and its source references `COLOR`.
- **`tests/headless/test_smoke.gd`** (extend): `main.tscn` boots, a track is
  generated, and `$Floor.track_cells` is non-empty.
- Full `./run_tests.sh` green before the work is complete.

## Documentation

Update `features/track.md` with the generation algorithm (DFS backtracking,
piece/candidate space, frame transform, overlap test, safety cap) and the
rendering approach (de-indexed vertex-colored chunks, `set_track` recolor,
shader change). Update `features/terrain.md` for the de-indexed mesh + vertex
colors + `set_track`. Update `features/rendering.md` for the shader COLOR change.
Add the new track config knobs to `features/configuration.md` if it enumerates
them.

## Out of scope

- Driving/lap logic, checkpoints, or scoring on the track.
- Openness-ordered candidate heuristics (future refinement).
- Closed-loop tracks (the chain is open-ended).
- Imprinting/raising the track surface (it reuses existing terrain heights).
- Strategies B (multi-step backoff) and C (exponential backoff).
