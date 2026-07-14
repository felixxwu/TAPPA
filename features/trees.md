# Trees (opaque billboard scatter around turns)

**Source:** `scripts/foliage.gd` (`class_name Foliage` — the ONE place that owns
the shared tree/bush meshes + materials), `scripts/tree_scatter.gd`
(`class_name TreeScatter`), `scripts/billboard_field.gd`
(`class_name BillboardField`, trees), `scripts/tree_mesh_field.gd`
(`class_name TreeMeshField`, bushes), `textures/tree.png` (home tree cutout),
`models/vegetation/groundcover_opaque.glb` (bush ground cover). Wired in
`scripts/world.gd._generate_track()`.

Trees are ALWAYS opaque billboard cutouts (`BillboardField`); bushes are ALWAYS
low-poly 3D meshes (`TreeMeshField`). There is no longer any billboard-vs-mesh
toggle — the mesh-tree rendering path was removed.

**Centralised spawning (`Foliage`).** Every place that spawns foliage — the stage
(`world.gd`), the HQ clearing (`hq_environment.gd`), and the podium's decorative
dressing (`podium.gd`) — goes through `Foliage.spawn_trees()` /
`Foliage.spawn_bushes()`. So the shared meshes and the size normalization all
live in exactly one file: a tree is the same kind of tree wherever it appears (an
opaque billboard cutout), and a tree/bush is scaled to `cfg.tree_size_m` /
`cfg.bush_height_m` everywhere — including the podium, which used to hardcode the
tree mesh at its native GLB size. The podium supplies its own ring scatter
(around the podium + showroom, off the tarmac pads) and a flat y = 0
`TerrainManager` to seat the instances, but the representation and scale come from
`Foliage` like everywhere else.

Shared low-level helpers used across the scatter/field code: `ScatterMath`
(`scripts/scatter_math.gd`) — seeded `hash01` + road-cell `cell_of`/`on_road`;
`SpatialGrid` (`scripts/spatial_grid.gd`) — bin points into cells and query a
3x3 neighbourhood; `ObstacleBody` (`scripts/obstacle_body.gd`) — the shared
single-`BoxShape3D` StaticBody obstacle builder used by `TreeMeshField` and
`BillboardField`.

After the track is generated and baked, foliage is scattered around each turn.
**Trees** are opaque billboard cutouts (`BillboardField`); **bushes** are solid
low-poly 3D meshes (`TreeMeshField`). Both share the same `TreeScatter` placement.

**Per-region tree species split.** A region authors a weighted `tree_mix` of
billboard species (`{texture, profile, weight}` — see
[regions.md](regions.md) → "Tree species split"). `world.gd` splits the
scattered positions by weight (`TreeScatter.partition_by_weight`) and calls
`Foliage.spawn_trees()` once per species, passing that species' `texture` and a
`use_region_profile` flag (from its `profile`) — decoupled from the texture, so a
region's mix can carry the home `tree.png` at `home` sizing (`cfg.tree_size_m`)
alongside its own tree at `region` sizing (`cfg.region_tree_billboard_size_m`).
Greece is 70% `textures/tree-greece.webp` (a large, low canopy at the region
profile) + 30% `textures/tree.png` (the home profile). Each species traces the
same "+" cross silhouette;
the mesh is cached per source-texture path in `Foliage.tree_silhouette_mesh(tex)`
so each distinct cutout (home `tree.png` + any region texture) is built once. Both
billboard paths (home + region) get **per-instance random size jitter**: each tree
is scaled by a deterministic factor in `[floor, 1.0]` (hashed off its world XZ in
`BillboardField._size_factor`), so a stand varies in height instead of every tree
being identical. The floor is a separate tunable per path —
`cfg.tree_billboard_min_scale` for the home path and
`cfg.region_tree_billboard_min_scale` for the region path (e.g. Greece). `1.0`
disables the jitter. The factor is recomputed on felling-restore so it stays
consistent.

On top of that uniform size, each tree also gets **aspect jitter**: width (x/z)
and height (y) are scaled by *independent* random factors in `[1 - k, 1 + k]`
(distinct hash salts in `BillboardField._instance_scale`), so some trees read
taller-and-narrower and others shorter-and-wider. The amplitude `k` is the
"how drastic" dial, a separate tunable per path —
`cfg.tree_billboard_aspect_jitter` (home) and
`cfg.region_tree_billboard_aspect_jitter` (region) — clamped to `[0, 0.9]`; `0`
disables the shape variation. Like the size factor it's deterministic per world XZ,
so felling-restore keeps the same stretched shape.

Each billboard path also has its own **ground-sink offset** (`BillboardField.build`'s
`y_offset`, added to the terrain height per instance): `cfg.tree_billboard_ground_offset_m`
for the home path and `cfg.region_tree_billboard_ground_offset_m` for the region path.
A negative value pushes the card's bottom edge below the terrain to hide the seam where
the trunk meets a sloped surface; positive lifts it.

The billboard cutout is baked into GEOMETRY, not the shader: `TreeSilhouette`
(`scripts/tree_silhouette.gd`) traces the tree texture's alpha (home:
`textures/tree.png`) into a
low-poly silhouette `ArrayMesh` once at load (cached by `Foliage.tree_silhouette_mesh()`),
triangulating every opaque cluster `opaque_to_polygons` returns so the gaps
between clusters are real geometry holes. The silhouette is emitted as a **"+"
(cross)** — the traced triangles are added twice, once in the XY plane and once
rotated 90° about Y into the ZY plane (sharing the same UVs), and each vertex
carries a **plane flag** in its vertex `COLOR.r` (0 = XY plane, 1 = ZY plane) so
the shader can treat the two planes differently. `BillboardField`
instances that mesh in **per-bin MultiMeshes** (one per `tree_bin_size_m` grid
cell, like `TreeMeshField`) with
`shaders/billboard_opaque.gdshader` — `unshaded, cull_disabled,
depth_draw_opaque`, **no `discard`**. Because there is no per-fragment
alpha test, early-Z stays enabled and overdraw collapses to actual coverage,
which is the win on tile-based mobile-web GPUs (an alpha-`discard` billboard
disables early-Z for the whole draw and pays overdraw every frame).

**Standing = one camera-facing card; felled = locked cross.** Each instance
carries a **felled flag** in its MultiMesh custom data (`INSTANCE_CUSTOM.x`: 0
standing, 1 knocked over), and `billboard_opaque.gdshader` branches on it:
- **Standing** — plane 0 (XY) is Y-billboarded about world Y so its face always
  points at the camera (upright, like `billboard.gdshader`), and plane 1 (ZY, the
  vertex-`COLOR.r == 1` plane) is **collapsed to a point**. A standing tree is thus
  a single camera-facing card — no "+" grid look, and no doubled overdraw. The
  instance basis carries only the `tree_size_m` scale (identity rotation), which the
  shader reads from the column lengths.
- **Felled** — the flag flips (`BillboardField.knock_down`), so the shader stops
  billboarding and locks BOTH planes in place, applying the instance's MODEL
  transform (a **topple tilt** about the base + the size scale) verbatim. The card
  snaps into the fixed "+" cross and topples, so a fallen tree reads as a solid 3D
  shape instead of a flat sheet lying on the ground. `reset_fallen` clears the flag.

Distance
fade is a vertex **shrink-out** over `tree_render_fade_m` before
`tree_render_distance_m` (opaque, replacing the old screen-door dither, which
needed `discard`): the shader scales the whole normalized vertex toward the
bottom-centre pivot. The **near-camera dissolve** is now ALSO a vertex
shrink-out (not a dither): within `tree_near_fade_end_m` the card scales back
toward its base, so a tree the camera pushes inside (the chase cam, or a planted
replay cam) shrinks away instead of dithering out. Both fades multiply into one
`scale` in `vertex()`, so `billboard_opaque.gdshader` has **no `discard` at all** —
the mesh-baked cutout keeps it fully opaque, which keeps early-Z / hidden-surface
removal ON for the draw (the old per-fragment near dither forced HSR off on
tile-based mobile GPUs). Near-fade range is still wired in `BillboardField.build`
for the opaque path only (the quad path has its own alpha-cutout distance fade). Trees
keep the same `TreeScatter` placement and box collision.

On top of the shader shrink-out, the per-bin split gives the engine a real **cull**:
each bin's `MultiMeshInstance3D` carries `visibility_range_end = tree_render_distance_m`
(fade `tree_render_fade_m`) and a compact bin-centred AABB, so far bins are
frustum- and distance-culled *whole* — their instances aren't vertex-processed or
submitted at all. (A single field-wide MultiMesh, which is what `BillboardField` used
to be, submits and vertex-shades every billboard every frame; its one track-spanning
AABB is always on-screen so it never frustum-culls.) Collision stays one
`StaticBody3D` in build order, so a contact's shape index still equals the global
instance index; `_slot_of` bridges that index back to the binned MultiMesh for
felling. The silhouette
airiness/triangle budget is set by `TREE_SILHOUETTE_ALPHA` / `TREE_SILHOUETTE_EPSILON`
in `Foliage`.

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

## Rendering — trees (`BillboardField`)

Trees render as opaque billboard cutouts through `BillboardField`
(`scripts/billboard_field.gd`) — see the silhouette / "+"-cross / shader detail
above. All instances share a single MultiMesh (one draw call), with a compact
per-field AABB and a `visibility_range` cull past `tree_render_distance_m` over a
`tree_render_fade_m` band. `build()` records each placed world position in
`instance_positions: PackedVector3Array` — a renderer-independent mirror, since
the MultiMesh transform buffer lives in the RenderingServer (a no-op stub under
`--headless`, so tests read this instead). The opaque billboard shader avoids the
per-fragment `discard` (early-Z stays on, overdraw collapses to coverage), the win
on tile-based mobile-web GPUs.

## Collision (`BillboardField` + `ObstacleBody`)

For stage trees (`with_collision = true`), `BillboardField` builds a child
`StaticBody3D` named `Collision` holding one box hitbox per tree, via the shared
`ObstacleBody` builder. All boxes share a single `BoxShape3D` resource instanced
via `PhysicsServer3D.body_add_shape(body_rid, shape_rid, transform)` — one shape,
N transforms, so thousands of trees add negligible node/memory overhead. Each box
is `2*tree_collision_radius_m` wide (square footprint), `tree_collision_height_m`
tall, and centred half its height above the ground so it rests on the surface.
The body stays on `collision_layer = 1` like `TerrainChunk`, so the car collides
with trees the same way it collides with the ground. Decorative fields (HQ,
podium) pass `with_collision = false` and build no body.

## Felling — crash a tree over at speed (`TreeFall` + `BillboardField`)

Crash into a tree carrying real speed and it topples over and loses its hitbox, so
you can drive on through where it stood. Hit one slowly and it stays a solid
obstacle (the collision above, unchanged).

- **Threshold (size-aware).** `TreeFall.should_fell_sized(speed_mps, size, cfg)`
  (`scripts/tree_fall.gd`, a pure static module like `ScatterMath`) returns true when
  the km/h-converted approach speed is `>= TreeFall.fell_speed_kmh(size, cfg)`, which
  scales **linearly** with the tree's visual `size`: `cfg.tree_fell_speed_kmh * size`
  (0 disables felling). So a small billboard tree topples at a low speed while a
  full-size tree keeps the configured threshold. Keyed to the car's **pre-solve**
  `_approach_speed` / `_approach_dir` (`car.gd`), captured at the top of
  `_physics_process` — a head-on hit's post-solve velocity is ~0, so reading it later
  would never fell (same rationale as the damage speed). (The size-agnostic
  `should_fell(speed, cfg)` is kept for callers/tests without a size — equivalent to
  `size == 1.0`.)
- **Trigger.** `car.gd._integrate_forces`'s object-reaction loop (contact-driven, and
  now run **before** the global deceleration-damage tick): for each obstacle contact
  it reads the struck instance's `field.size_factor(shape_idx)` and, if the approach
  speed fells a tree that size, calls
  `field.knock_down(state.get_contact_collider_shape(i), _approach_dir, cfg.tree_fell_duration_s)`.
  The contact's **shape index equals the tree's global index** (boxes are added in
  build order; see `ObstacleBody`). Ploughing into a line of trees drops each one.
- **Plough-through (size-aware collision).** A felled tree no longer necessarily stops
  the car dead. Because Godot's solver arrests the car head-on *before*
  `_integrate_forces` runs, the loop restores a size-scaled slice of the shed **forward
  momentum**: `keep = TreeFall.plough_keep(size, cfg)` rises from `0` at full size
  (`plough_keep(1.0) == 0` → a big tree hard-stops exactly as before) toward
  `cfg.tree_plough_keep_max` as the tree shrinks. The restore
  (`TreeFall.plough_restore_velocity`) sets `state.linear_velocity` to hand back
  `keep`·(shed horizontal momentum), clamped to the pre-solve approach speed — a
  **central** change (linear velocity only), so the solver's off-center contact
  response is untouched and **clipping a tree with the rear quarter still spins the
  car** (drift tail-swing preserved). The restore only fires when *every* obstacle
  touched this tick was felled; a still-standing wall (a big tree below its threshold,
  or a non-tree obstacle) legitimately stops the car (`solid_wall` guard). Across
  several felled contacts the **largest** felled tree governs (`keep` is the `min`).
  `cfg.tree_plough_keep_max == 0` disables plough-through entirely (every felled tree
  hard-stops). `size_factor()` returns the billboard's per-instance jitter scale.
- **`knock_down(idx, dir, duration)`** (idempotent). Disables that tree's box in
  place via `PhysicsServer3D.body_set_shape_disabled(body_rid, idx, true)` — never
  `body_remove_shape`, which would shift every higher shape index and break the
  index→tree mapping. Then it queues a fall record; `is_fallen(idx)` reports the
  bookkeeping (the physics server has no public "is disabled" getter). The field is
  one unbinned MultiMesh, so the contact shape index IS the instance index. Only the
  **opaque tree path** is fellable: `knock_down` flips the instance's **felled flag**
  (`INSTANCE_CUSTOM.x`) so `billboard_opaque.gdshader` locks the "+" cross and stops
  billboarding, then the topple tilt shows. An unknown idx is a safe no-op.
- **Animation.** `BillboardField._process` advances each fall, rebuilding only that
  instance's MODEL transform: `Basis(axis, TreeFall.fall_angle(elapsed, duration)) *
  _upright_basis(idx)` at the unchanged base origin, so it pivots about the trunk
  base. `topple_axis(dir)` is horizontal and perpendicular to travel (falls along
  `dir`). `fall_angle` is an eased 0 → `FLAT_ANGLE` (just past PI/2), monotone,
  clamped. Records retire when flat and `set_process(false)` when none remain, so a
  settled forest costs nothing per frame.
- **`reset_fallen()`** stands every felled tree back up: re-enables each box in place
  (`body_set_shape_disabled(..., idx, false)`), clears the felled flag and restores
  the instance's upright pose (identity rotation + size scale from `_upright_basis`),
  and clears `_fallen` / `_falling` (`set_process(false)`). Only the `_fallen` set is
  touched, so a stand with nothing knocked over is a cheap early-out. The **event
  replay** calls it — see Persistence.
- **Persistence.** Run-local and transient — a fresh run regenerates standing trees.
  A mid-run off-track auto-reset (`TrackProgress`) does not regenerate the world, so
  **felled trees stay felled** after a reset (you broke them, they're broken). BUT when
  the run ends and the **replay** begins, `world.gd._present_standings_overlay` calls
  `_reset_props_for_replay()` (which invokes `reset_fallen()` on every foliage field and
  `reset_knocked()` on the `SignField`) so the replay plays back against a pristine,
  intact stage rather than the wreckage the driven run left behind.

Config knobs `tree_fell_speed_kmh` / `tree_fell_duration_s` are balance values (see
Configuration); tests assert the felling *logic*, never the chosen numbers.

## Bushes (low-poly 3D ground-cover mesh, `TreeMeshField`)

Bushes are the low ground-cover patch in
`models/vegetation/groundcover_opaque.glb` (see `models/vegetation/README.md`),
rendered through `TreeMeshField` (`scripts/tree_mesh_field.gd`) as **solid
low-poly 3D meshes**. `TreeMeshField` spatially bins instances into a grid of
`tree_bin_size_m` cells, one `MultiMeshInstance3D` per non-empty bin (one draw
call per bin), so the engine drops far bins to the importer-generated mesh LODs
(`meshes/generate_lods=true` on the `.glb`) and fades them out past
`visibility_range_end = tree_render_distance_m` over a
`visibility_range_end_margin = tree_render_fade_m` band. Each instance sits at
`(x, Floor.height_at(x,z), z)` with a deterministic per-instance yaw and a uniform
scale so the mesh height matches `bush_height_m`; `build()` records
`instance_positions` + `instance_scale` (renderer-independent mirrors for headless
tests). Two `build()` flags adapt it for ground cover:

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

`Foliage.bush_mesh()` builds the render mesh: it takes the GLB's mesh, keeps the
imported (tone-matched) foliage texture, and rebuilds the surface as the **shared
foliage near-fade `ShaderMaterial`** (`shaders/tree_canopy.gdshader`). It's unshaded
and **double-sided** (`cull_disabled`, so the single-sided foliage cards don't vanish
from behind — `cull_back` is NOT safe here), multiplies the texture by the
per-instance MultiMesh `COLOR` (the baked-light instance tint) and by a `tint` uniform
set to `bush_tint` (lifted a touch above the model's authored green so the ground cover
reads against the grass), and — the reason for the swap — **shrinks out near the
camera** (`tree_near_fade_start_m` / `tree_near_fade_end_m`): a vertex-stage collapse
toward the instance origin, so a bush right in front of the camera (the chase cam
brushing one, or a planted replay cam sitting among them) shrinks away instead of
filling the frame. This replaced a per-fragment Bayer `discard`; with no `discard`
the shader keeps early-Z / HSR on for the draw (a mobile-GPU win). `world.gd` builds
the tree field and the bush field back to back.

## Configuration

`Trees` group in `GameConfig` (`config/game_config.tres` overrides some):
`vegetation_enabled` (master switch — false skips the whole scatter + fields +
bush hit volume; the benchmark's vegetation toggle drives it, see
[benchmark.md](benchmark.md)),
`trees_per_turn` (density target), `tree_spawn_radius_m`, `tree_road_margin_m`
(gap from the road edge), `tree_jitter` (how far trees wander from the grid; lower
= more regular), `tree_size_m` (billboard card size, width `.x` × height `.y`),
`tree_billboard_min_scale` / `tree_billboard_ground_offset_m` (per-instance size
jitter floor + ground-sink for home billboard trees), `tree_bin_size_m` (bush
render bin grid size, default 25 m — smaller = finer LOD/cull granularity but more
draw calls),
`tree_collision_radius_m` (box half-extent in X/Z), `tree_collision_height_m`
(box height), `tree_fell_speed_kmh` (approach speed at/above which a crash topples
the tree and removes its hitbox — 0 disables felling), `tree_fell_duration_s`
(seconds a felled tree takes to tilt flat), `tree_render_distance_m` (cull
distance), `tree_render_fade_m`
(shrink-out band), `tree_near_fade_start_m` / `tree_near_fade_end_m` (the
near-camera shrink range — the instance is fully collapsed within `start` of the
camera, full size again by `end`), `bush_height_m` (height the ground-cover bush mesh is scaled to),
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
`Foliage.spawn_trees()` always produces a `BillboardField`, and a region texture
selects that texture's cutout; the silhouette cutout is cached per texture; a
`TreeMeshField` built for bushes (`with_collision = false`, `bake_terrain_light =
true`) bins instances, skips the collision body, and enables per-instance MultiMesh
colour; and the live world carries a colliding tree field (`BillboardField`) plus a
non-colliding bush field (`TreeMeshField`).
