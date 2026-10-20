# Free roam — streamed road-first island (prototype)

**Source:** `scripts/free_roam/free_roam.gd` (scene root), `scripts/free_roam/terrain_streamer.gd`
(`TerrainStreamer`), `scripts/free_roam/road_terrain.gd` (`RoadTerrain`),
`scripts/free_roam/road_network.gd` (`RoadNetwork`), `scripts/free_roam/lab_noise.gd` (`LabNoise`), `scripts/free_roam/free_roam_settings.gd`
(`FreeRoamSettings`), `free_roam.tscn`

**Tests:** `tests/headless/test_free_roam.gd`

The prototype of the free-roam pivot (`todo/2026-10-19-free-roam-pivot.md`). **The game boots
straight into it** (`project.godot` → `run/main_scene = res://free_roam.tscn`); the hub and the
region run are unreachable while this is the main scene. Drive with the usual controls; **R**
puts the car back on the nearest road. A label in the top-left shows the streaming stats.

**The game builds the same island as `tools/road_network_lab.html` for the same seed.**
`LabNoise` reproduces the lab's random stream (mulberry32), hash and value noise bit for bit,
and `RoadNetwork` / `RoadTerrain` follow the lab's growth, wiggle and height maths step by step,
holding coordinates in 64-bit floats (Vector2 is 32-bit). Checked on seed 1: identical
junctions and identical heights at 175 inland points. Two details keep it exact:
- a near-tie (within 1 nm) between road segments goes to the lower segment number in both,
  because two roads meeting at a junction are only equally near up to rounding;
- point counts use `ceil(x - 1e-9)`, so a length that divides exactly can't flip on
  last-digit rounding differences between the browser's `cos`/`sin` and Godot's.

Change the maths in one place and you must change it in the other.

## The three layers

1. **`RoadNetwork` — the layout, built once at boot.** Radial growth from spawn: branches step
   outward, fork, and join existing road when they run into it (`_grow`). Each link then becomes
   a wiggled polyline (`_densify`, a seeded noise offset inside a band around the straight line,
   landing exactly on both ends; `road_twist` sets how far it may swing and `bend_length_m` how
often it turns). The polylines are flattened into segments in a 100 m grid, and
   everything downstream asks one question: `nearest(p, max_d)`, which leaves its answer in
   `hit_d` / `hit_q` / `hit_s` / `hit_edge` / `hit_side` / `hit_dir` so a query allocates nothing.
   `candidates_for` gathers, once per chunk, every segment that can be nearest for any point in
   the chunk, so per-sample queries (`nearest_in`) scan a short list.
2. **`RoadTerrain` — height built from the roads.** Same model as the lab
   (`tools/road_network_lab.html`):
   - **Base field:** low-frequency noise that ignores roads (`base_h`). It sets the roads' own
     height and decides lakes (`is_lake`: base below the water level), so the layout can avoid
     water before any terrain exists. It is lifted near spawn so spawn is always dry.
   - **Mountains:** ridged noise that rises only with distance from the nearest road, so roads
     sit in valleys.
   - **Ribbon:** a bank or drop beside each road, varying along it and per side.
   - **Coast:** the island fades to a sea floor below a noisy coastline.
   - **Bumps:** two octaves of Perlin noise (`LabNoise.perlin`, `bump_height_m` /
     `bump_scale_m`) over everything. The road takes the bump at its own centre line, so it
     rolls along its length but stays level across.

   Every query is a pure function of position, so any chunk can be built alone, in any order.
3. **`TerrainStreamer` — budgeted streaming.** See below.

## Streaming under a strict frame budget

`FreeRoamSettings.budget_us` (default 1000 µs) is the most terrain work any frame may do. A chunk
(64 m) is built by a resumable `ChunkJob` moving through stages:

| Stage | Unit | How it stays inside the budget |
|---|---|---|
| `PREP` | gather road candidates | atomic, measured |
| `HEIGHTS` | one sample | stops before a sample that would not fit, judged by the running µs-per-sample average |
| `ARRAYS` | vertex packing | clock checked every few vertices |
| `UPLOAD` | `ArrayMesh.add_surface_from_arrays` | atomic, measured per mesh size |
| `ATTACH` | create and add the `MeshInstance3D` | atomic, measured |
| `COLLIDE` | `HeightMapShape3D` + `StaticBody3D` | atomic, measured |

- **Atomic units** keep a moving average of their own cost (`_est`), and `_atomic` refuses to
  start one that would not fit in what is left of the frame. The first unit of a frame always
  runs, so a unit dearer than the whole budget still progresses and shows up as an overrun on
  the HUD rather than stalling the world.
- **Two levels of detail:** near chunks at `near_stride_m` (2 m) within `near_radius`, far chunks
  at `far_stride_m` (16 m) out to `far_radius` (6 chunks). Far chunks skip the one-sample
  border and take one-sided slopes at their edges.
- **Cheap paths that keep the lab match exact:** the hash multiplies are masked directly (the
  constants are below 2³¹, so nothing overflows), the hash is written out inside `vnoise`,
  points inside the closest possible coastline skip the coast noise, chunks beyond the
  furthest possible coastline are filled with sea floor without sampling, and the ring tint is
  sampled once per chunk.
- **Collision** comes only from near chunks, within `collision_radius`. `HeightMapShape3D` has
  unit cells, so the shape is scaled to the stride.
- **Skirts** hang below every chunk edge, so mixed-detail neighbours never show a crack.
- **Planning (`_plan`)** runs when the car changes chunk, and every 0.25 s otherwise. It
  measures distance from both the car and where it will be in 1.5 s, and queues missing work in
  priority order: collision, then near meshes, then far meshes, nearest first. Chunks beyond
  the horizon are dropped.
- **Boot:** `prefill()` builds the planned set with no budget before the car is released.
- **Height queries** (`height_at`, used by the chase camera) are answered from the loaded
  chunk under the point, interpolated across the same two triangles per cell as the mesh,
  so they are cheap and match the drawn surface. Only unloaded ground falls back to the full
  terrain maths.
- **Road surface queries** (`surface_at`, four per physics tick from the car's wheels) read
  the distance to the road stored at every near-chunk vertex (`near_road_d`) the same way.
- **Road candidates** are gathered once per chunk (`ChunkState.cands`), with a margin wide
  enough for both strides, and shared by its far and near builds.

## Trees, bushes and rocks

Near chunks are planted after their mesh (and collision) is attached, through the same
`Foliage.spawn_trees` / `spawn_bushes` / `spawn_rocks` the stages used, so a tree looks and
collides exactly as before. `Foliage` and its fields take any terrain with `height_at` (and
`light_at` for the bushes' baked light); the streamer provides both, read from the loaded
chunk.

- **Spots** come from jittered grids in world space (`tree_cell_m`, `bush_cell_m`,
  `rock_cell_m`), so a chunk always plants the same things in the same places.
  - Trees are thinned by the stages' forest noise (`forestiness`).
  - Rock groups are thinned by `rock_group_chance` × the region's rock density, then fanned
    into outcrops with `TreeScatter.cluster`.
  - Each spot is rejected if it is in water or within the road's width plus
    `tree_road_margin_m` plus the plant's own radius.
- **Biomes:** ring i wears region i of `RegionLibrary.ordered()` (wrapping), so each ring
  uses that region's `tree_mix`, its bush switch (`spawns_bush_mesh`) and its rock density.
- **Under the budget:** the `PLANT` stage checks a few spots at a time, and `SPAWN` builds
  one foliage field per species as its own unit of work.
- **Lifetime:** the foliage lives on `ChunkState.foliage` and is freed with the near mesh.
  It is only planted within the near ring, which matches `tree_render_distance_m` (120 m).
- **Not yet:** bush brushing (the stages' `BushField` hit-and-drag) and knocking trees over.

## Not in the prototype yet

Barriers, rest stops (the lab places one every 300 m; `RoadNetwork` doesn't port that yet),
pickups, the per-region look (rings are a vertex tint only), damage and checkpoint logic,
stuck or flipped recovery (only the manual **R**), the game HUD, mobile touch controls, a
pause or settings page, threading, and the self-testing auto driver. The remaining work is
staged in `todo/2026-10-19-free-roam-pivot.md` → *Staging*. The settings
live on a `FreeRoamSettings` resource rather than `GameConfig` while the shape settles.
