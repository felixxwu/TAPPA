# Level streamer

`scripts/level_streamer.gd` (`LevelStreamer`, a `Node3D` named `Ground` under `LevelView`, built in
`level_view.gd` → `_build_streamer`) streams the Hafren level's ground around the car: meshes at four
levels of detail, collision under the car, and the ground cover (`GroundCover`, child `Cover`). Every
height comes from the level's bake (`LevelBake.height`), so there is no terrain maths of its own. The car
sees this node as its terrain (`height_at`, `surface_at`, `road_pose`, `spawn_pose`, `snow_at`).

Tests: `tests/headless/test_level_streamer.gd`.

Until November 2026 this class extended the free-roam `TerrainStreamer` (since deleted,
with the island); the scheduler below was folded in, minus the planting,
road-network and site code only the legacy island used.

## Settings

`LevelStreamer.Settings` is a plain inner class with the sizes and the budget: `chunk_m` (96 m),
`near_tile_m` (24 m), `near_stride_m` / `mid_stride_m` / `far_stride_m` (1.5 / 6 / 12 m), `mid_radius`
(in chunks), `far_radius`, `horizon_radius_m` (0 turns the horizon off), `horizon_block_chunks`, the
budget shares, `prefill_slice_ms`, the mid band's squash, `collision_rush_s` and `far_lead_chunks`.
`LevelKnobs` (`scripts/adaptive/level_knobs.gd`) reads a fresh `Settings.new()` for the authored
rings and changes them live through `apply_rings`.

## Streaming under a strict frame budget

`budget_us(frame_s)` is the most terrain work any frame may do: `budget_fraction` of the frame time
left over (`spare_us`, set by the adaptive graphics), never below `budget_min_fraction` of the actual
frame time, with that floor capped at what it would be at `budget_floor_fps`. `_process` plans, runs the
collision safety net, runs the queue, then streams cover tiles from whatever the budget has left
(`PerfLog` keys `terrain_streamer` and `ground_cover`). Finer keys say where a slow upload frame goes: `stream_mesh` (`ArrayMesh` build in `_upload`/`_restitch`), `stream_node` (`add_child` of the chunk mesh in `_attach`), `stream_shape` (the `HeightMapShape3D` body build) and, in `ground_cover.gd`, `cover_mesh` (one `MultiMesh` layer). Draw-time engine work isn't caught; `render_cpu_ms` covers that.

A square of ground is built by a resumable `ChunkJob` moving through stages:

| Stage | Unit | How it stays inside the budget |
|---|---|---|
| `PREP` | size the buffers | atomic, measured |
| `HEIGHTS` | one baked height sample | stops before a sample that would not fit, judged by the decaying peak sample cost (`_peak_us`) |
| `ARRAYS` | vertex packing (`_pack_vertex`: sun, cover tint, snow) | clock checked every few vertices |
| `UPLOAD` | `ArrayMesh.add_surface_from_arrays` | atomic, measured per mesh size |
| `ATTACH` | create and add the `MeshInstance3D` (no shadow) | atomic, measured |
| `COLLIDE` | `HeightMapShape3D` + `StaticBody3D` | atomic, measured |

- **A stage that stops short ends the frame** (`_step` returns false), rather than spinning on the
  same job until the deadline.
- **Atomic units** keep a moving average of their own cost (`_est`); `_atomic` refuses one that would
  not fit. The first unit of a frame always runs, so a unit dearer than the whole budget still
  progresses.
- **Levels of detail** (`LevelStreamer.Level`):
  - **near**, drawn in `near_tile_m` tiles (`TileState`, in `_tiles`) whose closest point is within
    `near_reach()`: `NEAR_REACH_M`, or the whole far ring while `full_detail` is on (photo mode).
    Kept until `NEAR_REACH_M + NEAR_KEEP_MARGIN_M`. Tiles on the car's path for
    `adaptive_near_lead_s` are also wanted (`wanted_near_tiles`), at `NEAR_AHEAD_PRIORITY`.
  - **Holes, not overlap:** a chunk's drawn coarse mesh (mid, else far) is rebuilt without the cells
    its near tiles cover, with a skirt round each hole (`_cut_holes` / `_coarse_mesh`). When the
    planner drops a tile or mid mesh the recut waits in `_holes_due` and runs as a measured unit.
  - **Stitching:** a near tile edge that meets mid ground (`_stitch_mask`) is blended onto the mid
    line over `STITCH_BLEND_M` (`_stitch`); a neighbour change patches it in place (`_restitch`).
    Collision keeps the true heights.
  - **Skirts** hang below every edge. `_skirt_uv2` marks them (UV2.x = -1) and
    `level_ground.gdshader` draws them flat.
  - **mid** within `mid_radius`, narrowing to the sides and behind with speed (`squashed_distance`).
  - **far** out to `far_radius`, no halo.
  - **horizon**: one quad per chunk, baked into blocks of `horizon_block_chunks`² (`HorizonState`),
    out to `horizon_radius_m`. A block leaves out every cell whose chunk draws its own far or mid
    mesh (`horizon_cut`, recut via `_horizon_due` as the `horizon_holes` unit).
- **Collision** covers the 2×2 chunks round the chunk corner nearest the car
  (`collision_block_of`), built per tile from the finest grid there (`_collide_tile`,
  `TileState.body_level`): mid first, rebuilt from the near grid when that attaches.
- **Safety net** (`_guard_collision`, every frame): if the tile under the car, or where it will be in
  `collision_rush_s`, has no collision, it is built at once with no budget (`_rush_collision`).
- **Queue order** (`_plan`, on a chunk change and every 0.25 s; lowest first, d in chunks):
  collision `d − 2000`, near tiles on the path `NEAR_AHEAD_PRIORITY + eta`, mid meshes with collision
  `d − 1000`, near meshes `d − 200`, mid meshes `d − 100`, far meshes filling a gap in the horizon
  `d + FAR_GAP_PRIORITY − far_lead_chunks` (`_far_priority`), hidden far meshes and horizon blocks
  `d`. Jobs past `SKIPPABLE_PRIORITY` may be passed over when blocked. While a path tile is overdue
  (`near_overdue`, judged by the measured `near_build_s`) only collision and path tiles run, for at
  most `MAX_STARVED_FRAMES` frames.
- **Dropping:** near tiles past their keep distance, mid meshes past `mid_radius + 1.5`, collision
  past `NEAR_KEEP_CHUNKS`, far jobs past `far_radius + 1.5`, whole chunks past `far_radius + 2`. The
  near / collision drops come before the horizon test, so a teleport sheds them before the prefill.
  Cancelled and finished jobs leave the queue at each plan.
- **Boot:** `prefill()` builds everything with no budget (tests, tools). The game uses
  `prefill_async()`: `prefill_slice_ms` slices a frame apart behind the loading screen, then every
  cover tile in reach.
- **Golden replays** (`Benchmark.golden`, features/benchmark.md): `prefill_async` runs `_run_all` and
  `_settle_cover` with no awaits, so the frames before the replay never depend on machine speed; `_process`
  drains the same way every frame instead of spending `budget_us`. `_now_us()` (used for `_plan_us`,
  `wanted_us`, `_path_due` and `started_us`) returns `_clock_us`, the summed frame `delta`, instead of the wall clock.

## Build hook (neutral export)

`static var on_chunk_built: Callable` is called in `_upload` and `_restitch` with `(level, coord, n, stitch mask,
arrays)` just before the `ArrayMesh` is made. `tools/neutral_geometry.gd` (`NeutralGeometry.export(dir)`, run by
`tools/neutral_export.tscn -- --geometry=<dir>`) sets it, plus `GroundCover.on_layer_built`, and flies a marker along
`benchmark/runs/hafren.rec` prefilling every 50 m, writing `level_geometry.tapn` (chunk arrays, one shared index list per
`n`, cover buffers, tuft meshes, and per sample the live chunk and cover lists, see `features/neutral-format.md`) and its parity manifest lines. Unset, the hook costs one `is_valid()` check.

## Threads

`_run_queue` hands a job's HEIGHTS and ARRAYS stages to `WorkerThreadPool` (`_dispatch_build` →
`_build_job`, which runs the budget-free `_compute_heights` / `_compute_arrays` / `_finish_arrays`
the budgeted `_heights` / `_arrays` also use) when `_threads_ok()`: the platform has `threads` and
`GameConfig.threaded_chunk_build` is on. At most `chunk_build_tasks_web` / `chunk_build_tasks_desktop`
jobs are in flight (`_inflight`; all cores during a prefill); `_poll_builds` collects each finished one
exactly once (`_collect_build`) into UPLOAD, or drops it if `cancelled`. Everything the worker reads is
captured on the `ChunkJob` at dispatch (`ao_bush`, `bank_m`, `stitch`), and `setup` warms the lazy road
index so workers only read it. `_rush_collision` waits on its job if it is in flight, the prefills loop
until the queue and `_inflight` are empty, and `_exit_tree` cancels and drains every task. With threads
off the budgeted main-thread path runs instead.

## Stats

`stat_near_misses` (the car rolled onto a tile with no near mesh), `near_build_s`, `due_by_kind()` and
`chunk_counts()` feed the HUD, `LevelStats` and the replay benchmark (`benchmark/level_replay.gd`).
