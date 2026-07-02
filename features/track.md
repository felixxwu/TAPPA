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

The shipped set: the **gradient 1–6** (1 ≈ 85°/~18 m radius sharpest … 6 ≈
12°/~108 m radius gentlest — both angle and radius grow with the number),
**Square** (sharp ~90°), **Hairpin** (~180°), **Straight** (50 m line), and a
compound **"Right 4 tightens 2"** demonstrating authored multi-point corners.
Every turn except the **Hairpin** (and the plain **Straight**) is scaled 1.2×
larger than its original authored geometry — angles unchanged, radii grown.

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
- **Straightness bias (easy turns):** `straightness` (0..1) weights the candidate
  shuffle toward *straighter* pieces — gentler corners (less heading change) and
  longer connecting straights — so the search tries them first and the placed track
  favours easy turns. `_candidate_straightness` blends `_corner_straightness` (the
  corner's gentleness, derived from its total heading change so it needs no table)
  with the connecting-straight length; the ordering is an Efraimidis-Spirakis
  weighted draw (`key = u^(1/weight)`), so it stays fully seeded → deterministic and
  every candidate remains present (the DFS can still backtrack onto a sharp corner
  when a gentle one won't fit — completeness is unaffected). `0` (default) is the
  original unbiased Fisher-Yates shuffle. It changes the generated SHAPE, so the same
  value is passed wherever a track's target time is derived. Set per rally event by
  `RallyLibrary.event_straightness` — earlier-game events run higher (easier).
- **Frame transform:** a `Transform2D` (`frame_transform`) maps each corner's
  local space (x = right, y = forward) onto the current end pose; a **left**
  turn is a right-hand corner with its x mirrored (`mirror_points`). Joins are
  G1-continuous (each piece's entry tangent aligns to the previous exit heading,
  `exit_heading`).
- **Overlap (hard-avoid), early-exit:** a candidate is rejected if its footprint
  (0.5 m global cells within `width/2` of its centerline) overlaps an already-occupied
  cell, **excluding** a join buffer of cells within `width` of the entry (where it
  legitimately abuts the previous piece). `_collide_and_cells` rasterizes the
  footprint **and** tests `occupied` in one pass, **bailing on the first overlapping
  cell** — most candidates during backtracking collide, so this avoids rasterizing
  their whole footprint. It scans each segment's bounding box once (point-to-segment
  distance), not a `reach×reach` block at every 0.25 m sample; the old oversampling
  re-tested each cell ~`width/RASTER_STEP` times and made one candidate ~70 ms,
  turning a boxed-in seed into a multi-minute hang.
- **DFS backtracking:** a per-depth stack of shuffled candidate iterators. The
  first valid candidate is placed; when a depth's candidates are exhausted, the
  last placed corner is undone (cells/points/frame restored) and the previous
  depth resumes at its next untried candidate.
- **Safety / no hang:** each attempt is capped at `STEPS_BASE + turn_count *
  STEPS_PER_TURN` steps — generous over a healthy search (~`turn_count` steps) but
  tight enough that a seed that boxes itself in and backtracks exponentially is
  **abandoned** rather than ground out. `generate` then restarts with a far-apart
  seed (`seed + restart * RESTART_SEED_STRIDE`, so restarts explore genuinely
  different searches; **restart 0 keeps the authored seed**) up to `MAX_RESTARTS`,
  returning the deepest partial if all fail. A pathological seed that once took ~8
  minutes now bails and a fresh restart completes the track in well under a second.
  `generate(start_pos, start_heading, seed, turn_count, width, clearance=0, reserve_behind_m=0, straightness=0, runoff_m=0)`
  returns `{ centerline: Curve2D, cells: Dictionary, pieces: Array, complete: bool, runoff: Dictionary }`. Each
  piece dict records `corner`, `flip`, `straight`, `cells`, and its `entry_pos` /
  `entry_heading` (the pose at the start of its connecting straight — used by
  roadside-sign placement, see [signs.md](signs.md)).
- **Clearance:** the overlap test rasterizes the collision footprint at
  `width + 2*clearance`, not the visible `width`. So `track_clearance` (m) forces
  non-adjacent sections to keep that much extra gap — stopping the track from
  looping back and running alongside itself too closely — without widening the
  rendered road (these `cells` feed only the overlap test, never `set_track`).
- **Reserved start corridor:** `reserve_behind_m` pre-occupies a straight corridor
  directly *behind* the start (at the collision width), so the search can't loop the
  track back across the start-line lead-in stub the run scene prepends there
  ([start-line.md](start-line.md)). Cells within the join buffer of the start may
  still overlap (the track emerges from there); only loop-backs further out are
  rejected. It's defined relative to the start frame, so the generated SHAPE depends
  only on `(seed, turn_count, width, reserve)` — the same value is passed when
  deriving opponent target times, keeping them in sync with the run-scene track.
- **Finish runoff:** `runoff_m` (config `track_runoff_m`, default 20 m) requires a
  straight runoff off the LAST corner's exit — the room the car skids to a stop in
  past the finish. It's a real collision constraint *inside* the DFS: when a
  candidate would complete the track, its runoff footprint is overlap-tested like a
  corner, and if it won't fit that final-corner candidate is rejected and the search
  backtracks. The generated `centerline` still ends at the finish; the runoff is
  reported separately as `runoff = { end_pos, heading }` (empty when disabled or the
  track didn't complete). `world.gd._with_finish_runoff` appends one dead-straight
  point at `end_pos` to the RENDERED centerline, so the terrain bake + road markings
  render the runoff as real road — but the finish arch and 100% progress stay at the
  generated end ([finish-arch.md](finish-arch.md), [progress.md](progress.md)). Like
  the other shape inputs, the same `runoff_m` is passed when deriving opponent
  target times (it can change which final corner is chosen).

## Rendering

The track is drawn into the terrain, not as extra geometry: the terrain nodes
under the road are **flattened** to the road's height (the nearest centerline
point's terrain elevation) and on-road cells fade from the **ground texture to a
road texture** (grass → gravel). The road is flat across its width, and its edge
**feathers** over `track_transition_cells` cells (default 3) just outside
`track_width/2` — both the height (mesh + collision) and the texture fade blend
smoothly (smoothstep) from the flat road to the true terrain across that band.

## Surface split (gravel ↔ tarmac)

`scripts/track_surface.gd` (`class_name TrackSurface`, pure static functions)
splits the road between **gravel** and **tarmac** along its length. A track
switches surface **exactly once** (each surface is one contiguous run): it either
opens on gravel and switches to tarmac, or opens on tarmac and switches to gravel
— `orientation_tarmac_first(seed)` picks which, deterministically from
`track_seed`. The tarmac run covers `track_tarmac_fraction` of the length (set per
rally event by `RallyLibrary.event_tarmac_fraction`), which also fixes where the
switch sits. `tarmac_weight(dist, total, fraction, tarmac_first, feather_m)`
returns the tarmac-ness in `[0,1]` at a distance along the track, **feathered**
with a smoothstep over `track_surface_transition_m` (default 6 m) so the
gravel↔tarmac seam blends like the perpendicular grass↔road edge. It drives BOTH
the road colour (baked per cell into `track_surface`, then per vertex into mesh
UV2.x — the shader fades the gravel texture to the flat `tarmac_color`) and the
per-wheel grip (`surface_at` → `Drivetrain.surface_grip`), so look and feel stay
in sync. Tarmac is a placeholder solid grey for now — see
[../todo/tarmac-texture.md](../todo/tarmac-texture.md).

### Road markings (`RoadMarkings`)

`scripts/road_markings.gd` (`class_name RoadMarkings`, a `Node3D`) paints lane
lines along the **tarmac** stretches so tarmac reads unmistakably as tarmac
(gravel stays bare): two **solid edge lines** just inside the shoulders plus a
**dashed centre line**. It is a single static unshaded `ArrayMesh`, built once by
`world.gd._generate_track()` (after `set_track`, so the surface split is baked)
and rebuilt on a regeneration — it never updates per frame, so the heaviest
shader (the floor) is untouched. `build()` walks the centerline by arc length;
at each sample it reads the tarmac weight from the terrain's `surface_at()` and
paints only above `road_marking_tarmac_threshold`, breaking the strip in the
gravel sections and (for the centre line) in the dash gaps. Vertices sit
`road_marking_height_m` above the road surface (`terrain.height_at()`, since the
road is flattened to the centerline height across its width) and carry the same
baked terrain light (`terrain.light_at()`) in their vertex colour as the floor,
so the lines shade with the hills instead of glowing flat white. The terrain is
duck-typed (`surface_at`/`height_at`/`light_at`), so a null/stub terrain on flat
test fixtures reads as ground 0 / full tarmac / unlit white.

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
`track_straightness`, `track_runoff_m` (straight runoff road past the finish,
default 20 m — see the *Finish runoff* generation bullet above),
`track_transition_cells`, `track_tarmac_fraction`,
`track_surface_transition_m`, `tarmac_color` in `config/game_config.tres` (the
`Track` group of `GameConfig`). Lane paint lives in the `Road Markings` group:
`road_markings_enabled`, `road_marking_color`, `road_marking_width_m`,
`road_marking_edge_inset_m`, `road_marking_center_dash_m`,
`road_marking_center_gap_m`, `road_marking_height_m`,
`road_marking_tarmac_threshold`, `road_marking_sample_step_m`
(via `GameConfig.road_marking_params()`).

## Track progress & off-track reset

The generated centerline is retained after `set_track` by a `TrackProgress` node
(`scripts/track_progress.gd`), which tracks how far the car has driven along the
road and snaps it back on when it strays too far. See
[progress.md](progress.md).

## Tests

`tests/headless/test_corner_library.gd` — the library has the expected unique
corners, `build_curve` yields a non-degenerate `Curve2D` (≥ 2 points, positive
length, starts at origin) for each, the documented right-hand turn direction and
1→6 sharpness ordering hold, and the catalog scene builds one label per corner.

`tests/headless/test_track_generator.gd` — the geometry helpers (`frame_transform`,
`mirror_points`, `rasterize_cells`, `exit_heading`) and the search: determinism
per seed, exact corner count, start at the spawn frame, no cell overlap between
pieces, G1 continuity at joins, both L/R flips appearing across seeds, and the
finish runoff (zero `runoff_m` reports no segment; a positive runoff's footprint
never overlaps the placed track beyond the join buffer).

`tests/headless/test_road_markings.gd` — `RoadMarkings.build()` against a straight
curve + stub terrain: paint appears on tarmac and not on gravel, the disabled flag
yields no mesh, the edge lines stay inside the road edges, the paint starts at the
gravel→tarmac switch, and wider dash gaps remove centre-line geometry.
