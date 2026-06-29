# Trees (low-poly mesh scatter around turns)

**Source:** `scripts/tree_scatter.gd` (`class_name TreeScatter`),
`scripts/tree_mesh_field.gd` (`class_name TreeMeshField`, trees),
`scripts/billboard_field.gd` (`class_name BillboardField`, bushes),
`models/low_poly_tree.glb` + `textures/leaves.png` (tree model),
`textures/bush.webp` (bush sprite). Wired in
`scripts/world.gd._generate_track()`.

After the track is generated and baked, foliage is scattered around each turn.
**Trees are solid low-poly 3D meshes** (`TreeMeshField`); **bushes are still
alpha-cutout billboards** (`BillboardField`). Both share the same `TreeScatter`
placement.

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

## Rendering — trees (`TreeMeshField`)

`TreeMeshField` (`scripts/tree_mesh_field.gd`) renders trees as **solid low-poly
3D meshes** (`models/low_poly_tree.glb`), the opaque-mesh direction from
`todo/performance-optimisations.md` item 2. On tile-based mobile-web GPUs the old
alpha-cutout billboards were the worst case (the `discard` breaks early-Z and
stacks overdraw); opaque meshes occlude each other and pay no per-fragment cutout
tax.

Trees are **spatially binned** into a grid of `tree_bin_size_m` cells, one
`MultiMeshInstance3D` per non-empty bin (still one draw call per bin). Binning is
what makes the engine's automatic LOD/cull useful: a single field-wide MultiMesh
picks **one** mesh LOD for the whole field (by its overall AABB) and a field-wide
`visibility_range` would gate every tree at once — verified, a 100-instance
MultiMesh kept full primitive count from 12 m to 300 m. Per-bin MultiMeshes each
have a compact AABB centred on the bin (`mmi.position = bin centre`,
instance transforms bin-local), so the engine drops far bins to the **importer-
generated mesh LODs** (`meshes/generate_lods=true` on the `.glb` import) and fades
them out past `visibility_range_end = tree_render_distance_m` over a
`visibility_range_end_margin = tree_render_fade_m` band (`VISIBILITY_RANGE_FADE_SELF`
dither). No per-frame CPU.

Each instance is placed at `(x, Floor.height_at(x,z), z)` with a deterministic
per-tree yaw (so the cluster isn't visibly cloned) and a **uniform scale** so the
model's height matches `tree_size_m.y` (~6 m) — a 3D tree is scaled, never
stretched like a billboard quad. `build()` records each placed world position in
`instance_positions: PackedVector3Array` and the applied `instance_scale` —
renderer-independent mirrors, since the MultiMesh transform buffer lives in the
RenderingServer (a no-op stub under `--headless`, so tests read these instead).

The tree mesh is extracted once from the `.glb` PackedScene by
`world.gd._tree_mesh()` and shared by every bin's MultiMesh. Its materials are
**unshaded** `StandardMaterial3D` — the depth shading is baked into the mesh's
vertex colours (see the asset section below), so trees read correctly with no
dedicated scene light and stay in the flat PS1 look. The **canopy material is
double-sided** (`cull_mode = CULL_DISABLED`): the mesh winds correctly for
back-face culling in software GL, but the canopy rendered concave / "front faces
missing" on some real-device / web GL targets (a platform culling difference), so
drawing both sides guarantees the camera-facing leaves always appear. The canopy
is a closed shell, so from outside it looks identical — just robust everywhere.
The trunk stays single-sided (`CULL_BACK`).

## Collision (`TreeMeshField`)

`TreeMeshField` builds a child `StaticBody3D` named `Collision` holding one box
hitbox per tree. All boxes share a single `BoxShape3D` resource (held on the field
as `_collision_shape`) instanced via
`PhysicsServer3D.body_add_shape(body_rid, shape_rid, transform)` — one shape, N
transforms, so thousands of trees add negligible node/memory overhead. Each box
is `2*tree_collision_radius_m` wide (square footprint), `tree_collision_height_m`
tall, and centred half its height above the ground so it rests on the surface.
The body stays on `collision_layer = 1` like `TerrainChunk`, so the car collides
with trees the same way it collides with the ground. (`BillboardField` keeps the
identical scheme for the bush field's optional collision.)

## Bushes (`BillboardField`)

Bushes are still alpha-cutout billboards. `BillboardField`
(`scripts/billboard_field.gd`) is a `MultiMeshInstance3D` subclass: one `MultiMesh`
of `QuadMesh` instances (one draw call), each placed at
`(x, Floor.height_at(x,z), z)` with the quad pivot at its bottom edge
(`center_offset`). `shaders/billboard.gdshader` is a cylindrical billboard (each
quad yaws to face the camera but stays upright) with an alpha-scissor cutout and
an unshaded PS1-flat look; it culls past `tree_render_distance_m` and dissolves
over `tree_render_fade_m` via a 4×4 Bayer screen-door dither. Like `TreeMeshField`
it records `instance_positions` for headless tests.

Bushes use the same `TreeScatter` placement as trees, with these differences: they
use `textures/bush.webp`, they are built with `with_collision = false` (no hitbox),
they scatter with `track_seed + 1013` so the per-seed grid phase puts them on an
interleaved grid (not the trees' cells), they use their own (smaller) `bush_size_m`,
and they are sunk into the ground by `bush_sink_m` (passed as a negative `y_offset`
to `BillboardField.build`) to hide the gap at the bottom of the bush texture. They
reuse the other `tree_*` values (count, radius, margin, jitter, render
distance/fade). `world.gd` builds the tree field and the bush field back to back.

## Configuration

`Trees` group in `GameConfig` (`config/game_config.tres` overrides some):
`trees_per_turn` (density target), `tree_spawn_radius_m`, `tree_road_margin_m`
(gap from the road edge), `tree_jitter` (how far trees wander from the grid; lower
= more regular), `tree_size_m` (the tree model is scaled so its **height** matches
`.y`, ~6 m; `.x` is legacy footprint hinting), `tree_bin_size_m` (render bin grid
size, default 25 m — smaller = finer LOD/cull granularity but more draw calls),
`tree_collision_radius_m` (box half-extent in X/Z), `tree_collision_height_m`
(box height), `tree_render_distance_m` (cull distance), `tree_render_fade_m`
(dissolve band), `bush_size_m` (bush billboard size), `bush_sink_m` (how far
bushes sink into the ground). `GameConfig.tree_params()` packs the scalar scatter
knobs for `TreeScatter.scatter`; the render/collision knobs are passed straight to
`TreeMeshField.build` (trees) / `BillboardField.build` (bushes).

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
`tests/headless/test_smoke.gd` — the billboard shader loads with code; a built
`BillboardField` (bushes) has one MultiMesh instance per position; a built
`TreeMeshField` bins instances into per-cell MultiMeshes, wires
`visibility_range_end`/`margin` to the render distance/fade, scales instances to
the tree height, and builds one collision box per tree resting on the ground; and
the live world carries a `TreeMeshField` (trees swapped from billboards to meshes).

## Low-poly 3D tree model (asset)

**Source:** `tools/lowpoly_tree.gd` (generator + render harness),
`tools/gen_leaf_texture.py` (canopy texture), `models/low_poly_tree.glb` (the
baked model), `textures/leaves.png` (the leaf texture). This is a standalone asset
modelled after the rounded broadleaf park trees visible in the skybox
(`textures/sky_field.png`) — not yet wired into the billboard scatter above, kept
as a 3D alternative / future LOD-0 for near trees.

The mesh is fully procedural and deterministic: a tapered 6-sided trunk plus a
crown built from a cluster of overlapping subdivided icospheres ("blobs"). It is
flat-shaded (one face normal per triangle). Per-vertex lumpiness is keyed on the
icosphere vertex *direction* (`_vhash`), so triangles sharing a vertex move
together and the surface stays watertight (no sky cracks or spikes between blobs).

The mesh has **two surfaces / materials**: surface 0 is the trunk (plain bark
colour from vertex colours), surface 1 is the canopy, textured with a **tileable
leaf map** (`textures/leaves.png`). Canopy UVs are a baked "triplanar" projection
— each flat face is projected along its dominant-axis world plane (`uv_scale` sets
the leaf size), so the texture tiles over the lumpy crown with no authored UVs and
minimal stretch. The canopy still carries vertex colours, but now as a
near-grey/faintly-green **brightness** (height gradient: darker underside, lighter
sunlit top) that *multiplies* the texture, preserving the low-poly depth shading
while the texture supplies the leaf colour and detail. The `.glb` embeds the leaf
texture, so the model is self-contained.

**Leaf texture (`textures/leaves.png`).** Generated by
`tools/gen_leaf_texture.py` (PIL) — many small leaf shapes scattered in varied
skybox-matched greens over a dark base, drawn at all 9 wrap offsets so the image
tiles seamlessly. It is self-authored (CC0): the usual CC0 texture libraries
(ambientCG, Poly Haven, OpenGameArt) are unreachable from the build environment's
egress policy, so the texture is synthesised rather than downloaded.

Regenerate / re-render:

```
# (re)generate the leaf texture, then re-import so Godot picks it up
python3 tools/gen_leaf_texture.py
godot --headless --import
# export the .glb (headless is fine)
godot --headless -s tools/lowpoly_tree.gd -- --export
# also save multi-angle verification PNGs (needs a GL context)
xvfb-run -a godot --path . --rendering-driver opengl3 -s tools/lowpoly_tree.gd -- --render
```

Renders land in `tools/tree_renders/` (gitignored, regenerable). Tune the look by
editing the trunk dims, the `blobs` cluster (centre / radius / squash), the canopy
`uv_scale` (leaf size) and the `_vhash` wobble amount in `lowpoly_tree.gd`, or the
leaf shapes / greens in `gen_leaf_texture.py`.
