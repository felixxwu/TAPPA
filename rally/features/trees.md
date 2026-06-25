# Trees (billboard scatter around turns)

**Source:** `scripts/tree_scatter.gd` (`class_name TreeScatter`),
`scripts/tree_field.gd` (`class_name TreeField`), `shaders/billboard.gdshader`,
`textures/tree.png`. Wired in `scripts/world.gd._generate_track()`.

After the track is generated and baked, billboard tree sprites are scattered
around each turn.

## Placement (`TreeScatter`)

Pure, headless, seeded — same world-XZ plane as `TrackGenerator`
(`x → world x`, `y → world z`).

- `turn_anchor(piece)` — centroid of the piece's rasterized `cells` (world XZ),
  i.e. roughly where the turn is.
- `scatter(pieces, road_cells, params, seed_value)` — for each piece, makes
  `trees_per_turn` placement attempts. Each attempt samples a uniform point in
  a disc of `spawn_radius_m` around the anchor, then rejects it if its 0.5 m
  cell IS a road cell (`_on_road`, a single dict lookup) or if it is within
  `min_tree_dist_m` of an already-placed tree. Rejecting only on-road cells
  (rather than by a distance margin) lets trees spawn right up to the road
  edge — a tree may sit in the cell immediately beside the road — while never
  landing on it. A rejected tree retries up to `max_retries` times, then is
  skipped. The seed is `track_seed` offset, so placement is deterministic but
  does not visually track corner choices. Returns accepted positions; never
  hangs (work is bounded by `turns × trees_per_turn × (1 + max_retries)`).

  **`road_cells` is the visible road footprint inflated by the margin**,
  rasterized at `track_width + 2*tree_road_margin_m` via
  `TrackGenerator.rasterize_cells(centerline.tessellate(), …)` in `world.gd`.
  `tree_road_margin_m` is the tunable gap kept between the nearest trees and the
  road edge. The footprint is deliberately NOT `TrackGenerator.generate`'s
  returned `cells`, which are the collision set inflated to `track_width +
  2*track_clearance` — using those would push every tree `track_clearance`
  metres back from the real road edge.

## Rendering (`BillboardField`)

`BillboardField` (`scripts/billboard_field.gd`) is the shared renderer for both
trees and bushes — a `MultiMeshInstance3D` subclass: one `MultiMesh` of `QuadMesh` instances (one
draw call). Each instance is placed at `(x, Floor.height_at(x,z), z)`; the quad
pivot is its bottom edge (`center_offset`) so trunks sit on the ground. `build()`
also records each placed world position in `instance_positions: PackedVector3Array`
— a renderer-independent mirror of the MultiMesh transforms, since the MultiMesh
buffer lives in the RenderingServer (a no-op stub under `--headless`, so tests
read `instance_positions` instead).
`shaders/billboard.gdshader` is a cylindrical billboard — each quad yaws to face
the camera but stays upright — with an alpha-scissor cutout (crisp edges, no
blend sorting) and an unshaded PS1-flat look.

Trees are culled by distance in the shader: past `tree_render_distance_m` they
are fully discarded, and over the `tree_render_fade_m` band just before that they
dissolve out via a 4×4 Bayer screen-door dither (keeping the opaque alpha-scissor
pipeline — no transparency sorting). The default ~80 m roughly matches the loaded
terrain (`RADIUS=1`, `CHUNK_M=50` → ~75 m). The cut tracks the camera with no
per-frame CPU.

## Collision (`BillboardField`)

When built `with_collision`, `BillboardField` also builds a child `StaticBody3D`
named `Collision` holding one box hitbox per tree. All boxes share a single `BoxShape3D` resource (held on the
field as `_collision_shape`) instanced via
`PhysicsServer3D.body_add_shape(body_rid, shape_rid, transform)` — one shape, N
transforms, so thousands of trees add negligible node/memory overhead. Each box
is `2*tree_collision_radius_m` wide (square footprint), `tree_collision_height_m`
tall, and centred half its height above the ground so it rests on the surface.
The body stays on `collision_layer = 1` like `TerrainChunk`, so the car collides
with trees the same way it collides with the ground.

## Bushes

Bushes use the same `TreeScatter` placement and the same `BillboardField`
renderer / render-distance dissolve as trees, with these differences: they use
`textures/bush.webp`, they are built with `with_collision = false` (no hitbox),
they scatter with `track_seed + 1013` so they don't land on the same spots as the
trees, they use their own (smaller) `bush_size_m`, and they are sunk into the
ground by `bush_sink_m` (passed as a negative `y_offset` to `BillboardField.build`)
to hide the gap at the bottom of the bush texture. They reuse every other `tree_*`
value (count, radius, margin, spacing, retries, render distance/fade). `world.gd`
builds the tree field and the bush field back to back.

## Configuration

`Trees` group in `config/game_config.tres`: `trees_per_turn`,
`tree_spawn_radius_m`, `tree_road_margin_m` (gap from the road edge),
`tree_min_tree_dist_m`, `tree_max_retries`, `tree_size_m` (width × height),
`tree_collision_radius_m` (box half-extent in X/Z), `tree_collision_height_m`
(box height), `tree_render_distance_m` (cull distance), `tree_render_fade_m`
(dissolve band), `bush_size_m` (bush billboard size), `bush_sink_m` (how far
bushes sink into the ground). `GameConfig.tree_params()` packs the scalar scatter knobs for
`TreeScatter.scatter`; the collision knobs are passed straight to
`TreeField.build`.

## Tests

`tests/headless/test_tree_scatter.gd` — anchor centroid, determinism per seed,
no tree on a road cell, trees can hug the road edge, tree spacing,
within-radius, count bound, and impossible constraints returning quickly. `tests/headless/test_smoke.gd` — the billboard
shader loads with code, and a built `TreeField` has one MultiMesh instance per
position.
