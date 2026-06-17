# Track (corner shapes + generation)

**Source:** `scripts/corner_library.gd` (`class_name CornerLibrary`),
`scripts/corner_catalog.gd` (`class_name CornerCatalog`), `corner_catalog.tscn`,
`scripts/track_generator.gd` (`class_name TrackGenerator`).

Defines the **shape vocabulary** for rally corners and chains them into a
generated stage that is painted onto the terrain at startup.

## Corner shapes (`CornerLibrary`)

Each pacenote turn type is a 2D bezier curve (`Curve2D`), hand-authored as
control points in **meters**, with the entry at the origin heading **+Y** and
right-hand turns. The 2D curve is the source of truth; lifting it onto the 3D
terrain surface is a separate, future step.

- `CORNERS: Array[Dictionary]` — one entry per turn type: `name` plus `points`,
  an ordered list of `[position, in_control, out_control]` (Vector2, meters;
  in/out relative to position, as `Curve2D.add_point` expects). Values are baked
  (pre-computed) cubic-bezier arc handles — there is no runtime generator.
- `build_curve(spec)` — the single helper that turns one entry into a `Curve2D`.

The shipped set: the **gradient 1–6** (1 ≈ 85°/~15 m radius sharpest … 6 ≈
12°/~90 m radius gentlest — both angle and radius grow with the number),
**Square** (sharp ~90°), **Hairpin** (~180°), **Straight** (50 m line), and a
compound **"Right 4 tightens 2"** demonstrating authored multi-point corners.

## Catalog scene (`corner_catalog.tscn`)

A standalone 2D debug viewer (not the project main scene — run it directly). It
loads `CornerLibrary`, lays every corner out in a left-to-right row, and draws
each one's centerline, control-point markers, tangent handles, a green entry
dot, and a name label. Used to eyeball and tune the shapes.

## Track generation (`TrackGenerator`)

`scripts/track_generator.gd` is a **pure-2D** search (no scene nodes, no
terrain) that chains corners into a stage. It works in a plane mapping directly
to world XZ (`x → world x`, `y → world z`).

- **Chain shape:** corner → connecting straight → corner. Each step places a
  *piece* = (straight length) + (corner type, L/R flip). Candidates are
  `CornerLibrary` corners (excluding `Straight`) × {left, right} × a fixed set of
  straight lengths (`STRAIGHT_OPTIONS_M`), shuffled with a seeded RNG.
- **Frame transform:** a `Transform2D` (`frame_transform`) maps each corner's
  local space (x = right, y = forward) onto the current end pose; a **left**
  turn is a right-hand corner with its x mirrored (`mirror_points`). Joins are
  G1-continuous (each piece's entry tangent aligns to the previous exit heading,
  `exit_heading`).
- **Overlap (hard-avoid):** each piece rasterizes its cells (`rasterize_cells`,
  every 0.5 m global cell within `width/2` of the centerline). A candidate is
  rejected if any cell is already occupied, **excluding** a join buffer of cells
  within `width` of the entry (where it legitimately abuts the previous piece).
- **DFS backtracking:** a per-depth stack of shuffled candidate iterators. The
  first valid candidate is placed; when a depth's candidates are exhausted, the
  last placed corner is undone (cells/points/frame restored) and the previous
  depth resumes at its next untried candidate.
- **Safety:** `MAX_STEPS` caps placements+backtracks per attempt; on failure the
  search restarts with a perturbed seed up to `MAX_RESTARTS`, then returns its
  best partial track (never hangs). `generate(start_pos, start_heading, seed,
  turn_count, width, clearance=0)` returns `{ centerline: Curve2D, cells: Dictionary,
  pieces: Array, complete: bool }`.
- **Clearance:** the overlap test rasterizes the collision footprint at
  `width + 2*clearance`, not the visible `width`. So `track_clearance` (m) forces
  non-adjacent sections to keep that much extra gap — stopping the track from
  looping back and running alongside itself too closely — without widening the
  rendered road (these `cells` feed only the overlap test, never `set_track`).

## Rendering

The track is drawn into the terrain, not as extra geometry: the terrain nodes
under the road are **flattened** to the road's height (the nearest centerline
point's terrain elevation) and on-road cells fade from the **ground texture to a
road texture** (grass → gravel). The road is flat across its width, and its edge
**feathers** over `track_transition_cells` cells (default 3) just outside
`track_width/2` — both the height (mesh + collision) and the texture fade blend
smoothly (smoothstep) from the flat road to the true terrain across that band.

`world.gd._generate_track()` orders startup so nothing is rebuilt: run the search
from the car's spawn pose (position + −Z forward, projected to XZ) using the
`track_*` config knobs → `Floor.set_track(centerline, width, transition_m)`
(bakes the weighted height + road-blend fields) → `Floor.build_initial()`. Because
`Floor` has `defer_initial_build = true`, the terrain ring is built once *after*
the track is applied. See [terrain.md](terrain.md) for the weighted
`road_heights`/`road_blend`/`track_weights` fields, `bake_track`, the indexed
per-vertex-colored mesh, and the deferred build; [rendering.md](rendering.md) for the
shader change.

## Configuration

`track_width`, `track_clearance`, `track_seed`, `track_turn_count`,
`track_transition_cells` in `config/game_config.tres` (the `Track` group of
`GameConfig`).

## Tests

`tests/headless/test_corner_library.gd` — the library has the expected unique
corners, `build_curve` yields a non-degenerate `Curve2D` (≥ 2 points, positive
length, starts at origin) for each, the documented right-hand turn direction and
1→6 sharpness ordering hold, and the catalog scene builds one label per corner.

`tests/headless/test_track_generator.gd` — the geometry helpers (`frame_transform`,
`mirror_points`, `rasterize_cells`, `exit_heading`) and the search: determinism
per seed, exact corner count, start at the spawn frame, no cell overlap between
pieces, G1 continuity at joins, and both L/R flips appearing across seeds.
