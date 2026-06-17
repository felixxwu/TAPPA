# Threaded Chunk Generation — Design

**Date:** 2026-06-16
**Status:** Approved, pending implementation plan
**Builds on:** [chunked-infinite-terrain-design](2026-06-16-chunked-infinite-terrain-design.md)

## Problem

`TerrainChunk.build()` runs entirely on the main thread: per chunk it does
~121k `FastNoiseLite.get_noise_2d` calls (201² samples × 3 layers), builds a
~40k-vertex mesh, and generates normals. A boundary crossing triggers up to 3
chunk builds in a single frame, causing a visible stutter.

## Goal

Move the heavy per-chunk CPU work off the main thread so the game keeps running
smoothly. The main thread should only do the unavoidable, cheap part: assembling
the GPU mesh + collision resources and adding the node to the tree.

## Decision (from brainstorming)

- **Load latency:** accept brief pop-in. The car always sits well inside the
  loaded 3×3 ring (50–100 m of margin) and fog hides the far edge, so a newly
  entered outer chunk appearing 1–2 frames late is invisible. No prefetch ring,
  no extra memory.

## Architecture

Split chunk generation into a pure compute step (threadable) and a cheap apply
step (main thread only).

### 1. `TerrainManager.compute_chunk_data(coord) -> Dictionary` — pure, thread-safe

Produces everything that is just CPU math. Snapshots the noise parameters
(`noise_seed`, each layer's `wavelength_m`/`amplitude_m`, `texture_tile_per_meter`)
into locals first so it never reads mutating manager state from a worker thread,
then builds its own `FastNoiseLite` instances from that snapshot.

Returns a Dictionary:
- `heights: PackedFloat32Array` — `SAMPLES²`, centred on the chunk centre
  (same values as today's `build_heights`).
- `vertices: PackedVector3Array` — local-space positions.
- `uvs: PackedVector2Array` — world-coord UVs × tile (continuous across seams).
- `normals: PackedVector3Array` — computed directly from grid topology
  (accumulate per-face cross products over the two triangles per cell, then
  normalize), replacing `SurfaceTool.generate_normals()` which needs the tool.
- `indices: PackedInt32Array` — clockwise winding (a,b,c / b,d,c), as today.

No scene nodes or GPU/physics resources are created here. `build_heights` is
**kept** (still called directly by tests and reused for the height portion of
`compute_chunk_data`); the seam/determinism guarantees are unchanged because the
sampling math is identical. `height_at` (single-point lookup, used by the
car-spawn test) is also unchanged.

### 2. `TerrainChunk.apply_data(manager, coord, data)` — main thread only

The only part that touches GPU/physics resources:
- Position at the chunk centre `((cx+0.5)·CHUNK_M, 0, (cz+0.5)·CHUNK_M)`.
- Build an `ArrayMesh` via `add_surface_from_arrays(PRIMITIVE_TRIANGLES, …)` from
  `vertices/normals/uvs/indices`; assign `manager.chunk_material` as
  `material_override`.
- Build a `HeightMapShape3D` (`map_width = map_depth = SAMPLES`,
  `map_data = heights`) on the `CollisionShape3D` (scaled to 0.5 m cells in
  `_init`, unchanged).

`setup(manager, coord)` (synchronous path) becomes
`compute_chunk_data` + `apply_data`.

## Threaded flow (runtime)

**Initial ring is synchronous.** `_ready` performs its first reconcile with
generation forced synchronous, so there is always ground under the car the
instant the scene loads (and the car-spawn test stays valid). Only subsequent
reconciles — the mid-drive boundary crossings that actually cause the stutter —
use the threaded queue. The startup cost is a one-time, acceptable hitch.

The manager gains an async queue alongside `_chunks`:

- **`_pending: Dictionary`** — coord → `WorkerThreadPool` task id, for chunks
  currently generating.
- **Result holder** — a `Dictionary` (coord → data) written by workers, guarded
  by a `Mutex`.
- **`_reconcile(center)`** — frees out-of-ring chunks (as today) and drops
  out-of-ring entries from `_pending`. For each wanted coord not in `_chunks`
  and not in `_pending`, enqueue `WorkerThreadPool.add_task(...)` whose callable
  runs `compute_chunk_data(coord)` and stores the result under the mutex.
- **`_process(delta)`** — calls `update_focus(focus)` then integrates at most
  `MAX_INTEGRATIONS_PER_FRAME = 1` completed task per frame: pop a finished
  coord's data, create the `TerrainChunk`, `apply_data`, move `_pending →
  _chunks`. Skips any coord no longer wanted (car moved on). One-per-frame keeps
  even the GPU upload from hitching.
- **`_exit_tree()`** — `WorkerThreadPool.wait_for_task_completion` on every
  outstanding task id so no worker writes into a freed manager.

## Editor & tests stay synchronous

A `use_threaded_generation: bool` flag controls the path:
- Forced **false** when `Engine.is_editor_hint()` (instant live tuning, no
  threads in `@tool` context).
- Settable **false** by tests (the `_make_manager` helper) so chunk loading is
  deterministic in headless runs.
- **true** at runtime (default).

When false, `_reconcile` calls `compute_chunk_data` + `apply_data` inline
(today's behaviour). When true, it uses the queue above.

## Thread-safety notes

- Each worker builds its own `FastNoiseLite` from a snapshot — no shared mutable
  noise state.
- Workers only write into the mutex-guarded result holder; they never touch the
  scene tree or `_chunks`.
- All node creation, resource assignment, and `_chunks`/`_pending` mutation
  happen on the main thread (`_process`).
- Config changes (`_rebuild_loaded`, seed/layer setters) happen at `_ready`/
  editor time only; runtime config is static, so workers reading a snapshot is
  safe.

## Testing

- **`compute_chunk_data` (pure):** vertex/normal/uv/index array lengths
  (`SAMPLES²` verts, `(SAMPLES-1)²·6` indices); `heights` equals `build_heights`
  for the same coord; normals point up (y > 0); seam agreement across adjacent
  coords (already covered by the `build_heights` seam test, extended to the data
  path).
- **`apply_data` (synchronous):** a chunk built via the data path has an
  `ArrayMesh` with `SAMPLES²` vertices, a `HeightMapShape3D` of the right size,
  0.5 m collision scale, and a non-null `material_override` — i.e. the existing
  `test_chunk_builds_mesh_and_collision` keeps passing through the new path.
- **Load/unload (synchronous mode):** existing
  `test_moving_focus_loads_and_unloads_chunks` runs with
  `use_threaded_generation = false` and stays deterministic.
- **Threaded path (one integration test):** with threading enabled, after
  `update_focus`, `WorkerThreadPool.wait_for_task_completion` on the pending
  ids then pump integration; assert the 3×3 set ends up loaded. Kept minimal to
  avoid headless flakiness.

## Out of scope

- Prefetch / larger ring (rejected: pop-in accepted).
- Reducing test-suite wall time (each `main.tscn` load still builds 9 chunks);
  separate concern from gameplay smoothness.
- Threaded generation in the editor (`@tool` stays synchronous).
