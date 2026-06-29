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
- `scatter(pieces, road_cells, params, seed_value)` — places foliage on a **global
  jittered grid**, not by rejection sampling. The grid cell size
  (`grid_cell_size`) is derived from the target density —
  `spawn_radius_m * sqrt(PI / trees_per_turn)` — so one point per cell over a turn
  disc yields ~`trees_per_turn` trees. For each turn, it walks the grid cells its
  disc covers; each cell emits a single point at the cell centre plus a **seeded
  jitter** of up to ±`jitter`/2 of a cell, then keeps it only if the point lands
  inside the disc and its 0.5 m cell is not a road cell (`_on_road`, one dict
  lookup). The grid is **global** — a `used` set means overlapping turn discs share
  cells, so a cell is never placed twice and spacing stays even across the whole
  track. Because there's one point per cell, two trees are **never closer than
  `(1 - jitter) * cell`** (axis-adjacent worst case) — spacing is guaranteed by
  construction with **no neighbour scan**, so the cost is O(cells), not the old
  O(N²). The jitter (and a per-seed whole-lattice **phase**) are pure hashes of
  `(cell, seed_value)`, so placement is deterministic and order-independent, and a
  different seed (the bush offset) lands on an interleaved grid rather than the same
  cells. Reads only the in-memory `pieces` + `road_cells` — never the placed scene.
- **Forest patches** — trees are then gated by a low-frequency Perlin field so a stage
  reads as stands of forest broken by clearings, not one continuous tree line. The
  optional `forestiness` (0–1) + `forest_wavelength` args build a seeded
  `make_forest_noise` (wavelength in metres, default 300); a tree is kept only where
  `forest_density(p)` (the noise remapped to [0,1]) exceeds `1 - forestiness`. So
  `forestiness = 1` keeps everything (the noise is skipped), `0` keeps nothing, and
  values between thin the trees into patches. It's **per rally event**
  (`RallyLibrary.event_forestiness` → `cfg.track_forestiness`, written by
  `RallySession`); free-roam defaults to 1.0 (fully wooded). **Bushes pass the default
  1.0**, so undergrowth covers the whole stage regardless of the forest pattern.

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
they scatter with `track_seed + 1013` so the per-seed grid phase puts them on an
interleaved grid (not the trees' cells), they use their own (smaller) `bush_size_m`,
and they are sunk into the ground by `bush_sink_m` (passed as a negative `y_offset`
to `BillboardField.build`) to hide the gap at the bottom of the bush texture. They
reuse every other `tree_*` value (count, radius, margin, jitter, render
distance/fade). `world.gd` builds the tree field and the bush field back to back.

## Configuration

`Trees` group in `config/game_config.tres`: `trees_per_turn` (density target),
`tree_spawn_radius_m`, `tree_road_margin_m` (gap from the road edge),
`tree_jitter` (how far trees wander from the grid; lower = more regular),
`tree_size_m` (width × height),
`tree_collision_radius_m` (box half-extent in X/Z), `tree_collision_height_m`
(box height), `tree_render_distance_m` (cull distance), `tree_render_fade_m`
(dissolve band), `bush_size_m` (bush billboard size), `bush_sink_m` (how far
bushes sink into the ground). `GameConfig.tree_params()` packs the scalar scatter knobs for
`TreeScatter.scatter`; the collision knobs are passed straight to
`BillboardField.build`.

The **forest-patch** knobs live in the `Track` group instead, since they're per-stage:
`track_forestiness` (0–1, set per rally event by `RallyLibrary.event_forestiness`) and
`forest_wavelength_m` (Perlin wavelength, default 300). `world.gd` passes them to the
tree scatter; the bush scatter omits them (forestiness 1.0).

## Tests

`tests/headless/test_tree_scatter.gd` — anchor centroid, determinism per seed,
different seeds differ, no tree on a road cell, the grid's guaranteed minimum
spacing `(1 - jitter) * cell`, within-radius of an anchor, density bounded by the
grid cells a disc covers, a zero target placing nothing, an all-road area placing
nothing, and the **forestiness gate** (1.0 = unfiltered, 0 = bare, monotonic in
between, and every gated tree sits above the `1 - forestiness` noise threshold).
`tests/headless/test_smoke.gd` — the billboard shader loads with code, and a built
`BillboardField` has one MultiMesh instance per position.

## Low-poly 3D tree model (asset)

**Source:** `tools/lowpoly_tree.gd` (generator + render harness),
`models/low_poly_tree.glb` (the baked model). This is a standalone asset modelled
after the rounded broadleaf park trees visible in the skybox
(`textures/sky_field.png`) — not yet wired into the billboard scatter above, kept
as a 3D alternative / future LOD-0 for near trees.

The mesh is fully procedural and deterministic: a tapered 6-sided trunk plus a
crown built from a cluster of overlapping subdivided icospheres ("blobs"). It is
flat-shaded (one face normal per triangle) with **per-face vertex colours** — a
green base modulated by a height gradient (darker underside, lighter top) and a
small per-face jitter — so it carries its own colour with no texture, matching the
project's unshaded PS1-flat look. Per-vertex lumpiness is keyed on the icosphere
vertex *direction* (`_vhash`), so triangles sharing a vertex move together and the
surface stays watertight (no sky cracks or spikes between blobs).

Regenerate / re-render:

```
# export the .glb (headless is fine)
godot --headless -s tools/lowpoly_tree.gd -- --export
# also save multi-angle verification PNGs (needs a GL context)
xvfb-run -a godot --rendering-driver opengl3 -s tools/lowpoly_tree.gd -- --render
```

Renders land in `tools/tree_renders/` (gitignored, regenerable). Tune the look by
editing the trunk dims, the `blobs` cluster (centre / radius / squash), the leaf
colour, and the `_vhash` wobble amount in `build_tree()`.
