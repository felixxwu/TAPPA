# Trees (low-poly mesh scatter around turns)

**Source:** `scripts/foliage.gd` (`class_name Foliage` — the ONE place that
decides tree representation and owns the shared tree/bush meshes + materials),
`scripts/tree_scatter.gd` (`class_name TreeScatter`),
`scripts/tree_mesh_field.gd` (`class_name TreeMeshField`, trees AND bushes),
`models/low_poly_tree.glb` + `textures/leaves.png` (tree model),
`models/vegetation/groundcover_opaque.glb` (bush ground cover). Wired in
`scripts/world.gd._generate_track()`.

**Centralised spawning (`Foliage`).** Every place that spawns foliage — the stage
(`world.gd`), the HQ clearing (`hq_environment.gd`), and the podium's decorative
dressing (`podium.gd`) — goes through `Foliage.spawn_trees()` /
`Foliage.spawn_bushes()` (or `Foliage.tree_mesh()` / `Foliage.bush_mesh()` for the
podium's own MultiMesh placement). So the billboard-vs-mesh decision and the
shared meshes live in exactly one file: a tree is the same kind of tree wherever
it appears, and a bush is scaled to `cfg.bush_height_m` everywhere. (The podium is
the one deliberate exception on representation: a close-up hero shot, it always
uses the 3D tree mesh — scale-jittered — because the distance-culled billboard
field reads poorly up close. It still pulls that mesh from `Foliage`.)

Shared low-level helpers used across the scatter/field code: `ScatterMath`
(`scripts/scatter_math.gd`) — seeded `hash01` + road-cell `cell_of`/`on_road`;
`SpatialGrid` (`scripts/spatial_grid.gd`) — bin points into cells and query a
3x3 neighbourhood; `ObstacleBody` (`scripts/obstacle_body.gd`) — the shared
single-`BoxShape3D` StaticBody obstacle builder used by `TreeMeshField` and
`BillboardField`.

After the track is generated and baked, foliage is scattered around each turn.
Both **trees** and **bushes** are solid low-poly 3D meshes rendered through the
same `TreeMeshField` by default. Both share the same `TreeScatter` placement.

**Perf A/B toggle (`use_billboard_trees`).** When
`GameConfig.use_billboard_trees` is true, `Foliage.spawn_trees()` renders
**trees** as opaque tight-cutout billboards instead of the low-poly 3D mesh
(`TreeMeshField`). **Bushes always stay meshes** regardless of the toggle.

The billboard cutout is baked into GEOMETRY, not the shader: `TreeSilhouette`
(`scripts/tree_silhouette.gd`) traces `textures/tree.png`'s alpha into a
low-poly silhouette `ArrayMesh` once at load (cached by `Foliage.tree_silhouette_mesh()`),
triangulating every opaque cluster `opaque_to_polygons` returns so the gaps
between clusters are real geometry holes. The silhouette is emitted as a **"+"
(cross)** — the traced triangles are added twice, once in the XY plane and once
rotated 90° about Y into the ZY plane (sharing the same UVs). `BillboardField`
instances that mesh in a single MultiMesh (one draw call) with
`shaders/billboard_opaque.gdshader` — `unshaded, cull_disabled,
depth_draw_opaque`, **no `discard`**. Because there is no per-fragment
alpha test, early-Z stays enabled and overdraw collapses to actual coverage,
which is the win on tile-based mobile-web GPUs (an alpha-`discard` billboard
disables early-Z for the whole draw and pays overdraw every frame).

**The cross does NOT face the camera.** Unlike a classic sprite billboard, the
"+" is planted at a fixed, deterministic **random yaw** per tree (hashed off the
instance's world XZ via `ScatterMath.hash01`, baked into the MultiMesh transform
basis in `BillboardField.build`). Because it's a cross, the silhouette still
reads as solid foliage from any horizontal angle, and the per-tree random yaw
stops a stand from looking like an aligned grid. The shader therefore no longer
rotates the card toward the camera — it just applies the model transform (yaw +
`tree_size_m` scale, with Z scaled by the horizontal `size.x` for the second
plane). Distance
fade is a vertex **shrink-out** over `tree_render_fade_m` before
`tree_render_distance_m` (opaque, replacing the old screen-door dither, which
needed `discard`): the shader scales the whole normalized vertex toward the
bottom-centre pivot. Trees keep the same `TreeScatter` placement and box collision.
The silhouette airiness/triangle budget is set by `TREE_SILHOUETTE_ALPHA` /
`TREE_SILHOUETTE_EPSILON` in `Foliage`.

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
`Foliage.tree_mesh()` and shared by every bin's MultiMesh. The **trunk** keeps
its baked **unshaded** `StandardMaterial3D` — the depth shading is baked into the
mesh's vertex colours (see the asset section below), so it reads correctly with no
dedicated scene light and stays in the flat PS1 look — single-sided (`CULL_BACK`).

The **canopy** is double-sided (`cull_mode = CULL_DISABLED`): the mesh winds
correctly for back-face culling in software GL, but the canopy rendered concave /
"front faces missing" on some real-device / web GL targets (a platform culling
difference), so drawing both sides guarantees the camera-facing leaves always
appear. The canopy is a closed shell, so from outside it looks identical — just
robust everywhere.

**Near-camera dissolve (`shaders/tree_canopy.gdshader`).** Double-siding the
canopy is robust but reintroduces a problem single-sided culling used to solve for
free: with both sides drawn, the inward-facing leaves still render when the chase
camera pushes *inside* a tree, blocking the view. So `Foliage.tree_mesh()` swaps
the canopy surface's material for a `ShaderMaterial` that keeps the unshaded,
double-sided, vertex-colour-tinted leaf look (`ALBEDO = leaves × COLOR`) but
**dither-dissolves fragments near the camera**: canopy fragments within
`tree_near_fade_start_m` of the camera are fully discarded and ramp back to solid
by `tree_near_fade_end_m`, via the same Bayer screen-door dither the distance cull
uses (`billboard.gdshader`). A clear pocket opens around the camera with no
transparency sorting and no per-frame CPU — independent of the platform's culling,
and it works for any camera and every tree at once (no per-instance MultiMesh
data needed). The canopy surface is identified as the textured one
(`albedo_texture != null`); the trunk is untouched.

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

## Bushes (ground-cover mesh, same renderer as trees)

Bushes are the low ground-cover patch in
`models/vegetation/groundcover_opaque.glb` (see `models/vegetation/README.md`),
rendered through the **same `TreeMeshField`** as the trees — same binning, the
same per-bin importer-LOD / `visibility_range` cull, the same deterministic yaw
and uniform height scaling. Two `build()` flags adapt it for ground cover:

- `with_collision = false` — bushes are non-colliding *pass-through* scenery, so no
  `StaticBody3D`/hitboxes are built (unlike trees, they are not solid obstacles). A
  separate `BushField` node (`scripts/bush_field.gd`) does a per-tick proximity query
  off the same scattered positions to make brushing a bush cost a little HP + apply a
  drag torque — see [damage.md](damage.md) → "Soft contacts".
- `bake_terrain_light = true` — each instance's MultiMesh colour is set to the
  terrain's baked light at its position (`light_at`), and the bush material has
  `vertex_color_use_as_albedo` enabled, so `ALBEDO = foliage_texture × COLOR`
  exactly as before — the patches keep tracking the ground tint everywhere.

Differences from trees: they scatter with `track_seed + 1013` so the per-seed grid
phase puts them on an interleaved grid (not the trees' cells), they are NOT
forest-gated (default forestiness 1.0, so undergrowth covers the whole stage),
they have no collision, and they scale to `bush_height_m` instead of
`tree_size_m.y`. They reuse the trees' scatter knobs (count, radius, jitter),
bin size and render distance/fade.

**Road keep-out (no mesh on the road).** The bush mesh is a *wide* flat patch, so
uniform-scaling it to `bush_height_m` blows its world footprint up well past a
tree trunk's. A bush is rejected not on the trees' `track_width + 2*tree_road_margin_m`
footprint but on one **also inflated by the bush's own world-space radius**:
`track_width + 2*(tree_road_margin_m + bush_radius)`, where
`bush_radius = TreeMeshField.xz_radius(bush_mesh, bush_height_m)` (half the larger
horizontal AABB extent × the height scale). That keeps the bush *centre* far
enough out that no part of the scaled mesh spills onto the road at any
per-instance yaw, while still leaving the `tree_road_margin_m` gap from the road
edge. `world.gd` rasterizes this wider footprint into a bush-specific
`road_cells`; the trees keep the un-inflated one.

`world.gd._bush_mesh()` builds the render mesh: it takes the GLB's mesh, keeps the
imported (tone-matched) foliage texture, and makes the `StandardMaterial3D`
**unshaded** (the flat PS1 look the rest of the world uses) with
`vertex_color_use_as_albedo` on so the baked-light instance colour multiplies in.
Its `albedo_color` is set to `bush_tint` (lifted a touch above the model's authored
green so the ground cover reads a bit more against the grass).
`world.gd` builds the tree field and the bush field back to back.

## Configuration

`Trees` group in `GameConfig` (`config/game_config.tres` overrides some):
`vegetation_enabled` (master switch — false skips the whole scatter + fields +
bush hit volume; the benchmark's vegetation toggle drives it, see
[benchmark.md](benchmark.md)),
`trees_per_turn` (density target), `tree_spawn_radius_m`, `tree_road_margin_m`
(gap from the road edge), `tree_jitter` (how far trees wander from the grid; lower
= more regular), `tree_size_m` (the tree model is scaled so its **height** matches
`.y`, ~6 m; `.x` is legacy footprint hinting), `tree_bin_size_m` (render bin grid
size, default 25 m — smaller = finer LOD/cull granularity but more draw calls),
`tree_collision_radius_m` (box half-extent in X/Z), `tree_collision_height_m`
(box height), `tree_render_distance_m` (cull distance), `tree_render_fade_m`
(dissolve band), `tree_near_fade_start_m` / `tree_near_fade_end_m` (the
near-camera canopy dissolve range — fragments within `start` of the camera fully
gone, fully solid again by `end`), `bush_height_m` (height the ground-cover bush mesh is scaled to),
`bush_tint` (albedo tint lifting the bush colour a touch against the grass).
`GameConfig.tree_params()` packs the scalar scatter knobs for
`TreeScatter.scatter`; the collision knobs are passed straight to
`TreeMeshField.build`.

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
`BillboardField` has one MultiMesh instance per position (with/without collision);
a built `TreeMeshField` (trees) bins instances into per-cell MultiMeshes, wires
`visibility_range_end`/`margin` to the render distance/fade, scales instances to
the tree height, and builds one collision box per tree resting on the ground; the
shared tree mesh's canopy surface is the near-camera dissolve `ShaderMaterial` with
its fade range wired from config; a
`TreeMeshField` built for bushes (`with_collision = false`, `bake_terrain_light =
true`) skips the collision body and enables per-instance MultiMesh colour; and the
live world carries two `TreeMeshField`s — trees (with collision) and bushes
(without).

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
