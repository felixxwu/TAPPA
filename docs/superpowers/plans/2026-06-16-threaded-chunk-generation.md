# Threaded Chunk Generation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the heavy per-chunk terrain generation (noise sampling + mesh build) off the main thread so the game stays smooth when crossing chunk boundaries.

**Architecture:** Split chunk generation into a pure, thread-safe `compute_chunk_data(coord)` (heights + mesh arrays, all CPU math) and a cheap main-thread `apply_data(...)` (builds the `ArrayMesh` + `HeightMapShape3D` and adds the node). At runtime, `compute_chunk_data` runs on a `WorkerThreadPool` task; `_process` integrates at most one finished chunk per frame. The initial ring and the editor/tests stay synchronous.

**Tech Stack:** Godot 4 / GDScript, `WorkerThreadPool`, `Mutex`, `ArrayMesh.add_surface_from_arrays`, `HeightMapShape3D`, GUT headless tests.

---

## Project rules (READ FIRST)

- This project is **NOT** under git. DO NOT run git. There are NO commit steps — verify with tests instead.
- Run tests with `./run_tests.sh` (or `./run_tests.sh --fast terrain` for the terrain file) **in the background** (`run_in_background: true`), then wait for the completion notification. The full suite takes ~4 minutes. Before starting a run, confirm no other `./run_tests.sh` is already running.
- Godot: `/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot`.
- A quick parse check (no full run): `/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot --headless --check-only --path . --script res://scripts/<file>.gd` — a `Compile Error: Identifier not found: Config` is expected (autoload absent under check-only) and is NOT a parse failure.
- GDScript gotcha: `:=` cannot infer a type from a `Node3D`-typed receiver's untyped-return method, nor from `PackedFooArray` indexing. Use explicit `var x: Type = ...` in those spots (the test file already does this).

---

## File Structure

- **Modify** `scripts/terrain_manager.gd` — add `compute_chunk_data(coord)` (pure); add the threaded queue (`_pending`, `_results`, `_results_mutex`, `use_threaded_generation`, `_request_chunk`, `_generate_on_worker`, `_spawn_chunk`, `_integrate_ready`, `_exit_tree`); branch `_reconcile` on the flag; make `_ready`'s first reconcile synchronous; update `_rebuild_loaded`.
- **Modify** `scripts/terrain_chunk.gd` — replace `build`/`_build_mesh`/`_build_collision` with `apply_data(manager, coord, data)`; `setup` becomes `compute_chunk_data` + `apply_data`.
- **Modify** `tests/headless/test_terrain.gd` — `_make_manager` sets `use_threaded_generation = false`; add `compute_chunk_data` data-shape tests; add one threaded integration test; existing tests unchanged otherwise.
- **Modify** `features/terrain.md` — update the Performance section to describe threaded generation.

---

## Task 1: Pure compute path (`compute_chunk_data` + `apply_data`), still synchronous

This task introduces the compute/apply split with NO threading yet — behaviour is identical to today, just restructured. All existing terrain tests must still pass.

**Files:**
- Modify: `scripts/terrain_manager.gd`
- Modify: `scripts/terrain_chunk.gd`
- Test: `tests/headless/test_terrain.gd`

- [ ] **Step 1: Add `compute_chunk_data` to `scripts/terrain_manager.gd`**

Insert this method immediately AFTER the existing `build_heights` method (after its `return heights` line, currently ~line 109):

```gdscript
# Pure CPU work for one chunk: heights + mesh arrays. Safe to call from a worker
# thread — it reads only the (runtime-static) noise params and builds its own
# FastNoiseLite instances, touching no scene state.
func compute_chunk_data(coord: Vector2i) -> Dictionary:
	var half := CHUNK_M / 2.0
	var center := Vector3((coord.x + 0.5) * CHUNK_M, 0.0, (coord.y + 0.5) * CHUNK_M)
	var tile := texture_tile_per_meter

	var noises: Array[FastNoiseLite] = []
	var amplitudes: PackedFloat32Array = []
	for i in layers.size():
		if not _is_valid_layer(layers[i]):
			continue
		noises.append(_make_noise(i))
		amplitudes.append(layers[i].amplitude_m)

	var count := SAMPLES * SAMPLES
	var heights := PackedFloat32Array()
	heights.resize(count)
	var vertices := PackedVector3Array()
	vertices.resize(count)
	var uvs := PackedVector2Array()
	uvs.resize(count)
	var normals := PackedVector3Array()
	normals.resize(count)  # zero-initialised; accumulated below
	for zi in SAMPLES:
		var lz := -half + zi * CELL_M
		var wz := center.z + lz
		for xi in SAMPLES:
			var lx := -half + xi * CELL_M
			var wx := center.x + lx
			var h := 0.0
			for i in noises.size():
				h += noises[i].get_noise_2d(wx, wz) * amplitudes[i]
			var idx := zi * SAMPLES + xi
			heights[idx] = h
			vertices[idx] = Vector3(lx, h, lz)
			# UVs in world coords so the checker is continuous across seams.
			uvs[idx] = Vector2(wx, wz) * tile

	var indices := PackedInt32Array()
	indices.resize((SAMPLES - 1) * (SAMPLES - 1) * 6)
	var ii := 0
	for zi in SAMPLES - 1:
		for xi in SAMPLES - 1:
			var a := zi * SAMPLES + xi
			var b := a + 1
			var c := a + SAMPLES
			var d := c + 1
			# Clockwise winding (matches the old SurfaceTool path).
			indices[ii] = a; indices[ii + 1] = b; indices[ii + 2] = c
			indices[ii + 3] = b; indices[ii + 4] = d; indices[ii + 5] = c
			ii += 6

	# Per-vertex normals: accumulate face normals, then normalize. The (c-a)x(b-a)
	# order makes the normals point up for this clockwise winding (see the
	# normals-point-up test).
	for t in range(0, indices.size(), 3):
		var ia := indices[t]
		var ib := indices[t + 1]
		var ic := indices[t + 2]
		var n := (vertices[ic] - vertices[ia]).cross(vertices[ib] - vertices[ia])
		normals[ia] += n
		normals[ib] += n
		normals[ic] += n
	for i in count:
		normals[i] = normals[i].normalized()

	return {
		"center": center,
		"heights": heights,
		"vertices": vertices,
		"uvs": uvs,
		"normals": normals,
		"indices": indices,
	}
```

- [ ] **Step 2: Replace the chunk build methods in `scripts/terrain_chunk.gd`**

Replace EVERYTHING from `func setup(` through the end of the file (current lines 26–74: `setup`, `build`, `_build_mesh`, `_build_collision`) with:

```gdscript
func setup(manager: TerrainManager, chunk_coord: Vector2i) -> void:
	apply_data(manager, chunk_coord, manager.compute_chunk_data(chunk_coord))


# Main-thread only: assemble the GPU mesh + collision from precomputed arrays.
func apply_data(manager: TerrainManager, chunk_coord: Vector2i, data: Dictionary) -> void:
	coord = chunk_coord
	position = data["center"]
	_mesh_instance.material_override = manager.chunk_material

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = data["vertices"]
	arrays[Mesh.ARRAY_NORMAL] = data["normals"]
	arrays[Mesh.ARRAY_TEX_UV] = data["uvs"]
	arrays[Mesh.ARRAY_INDEX] = data["indices"]
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh_instance.mesh = mesh

	var shape := HeightMapShape3D.new()
	shape.map_width = TerrainManager.SAMPLES
	shape.map_depth = TerrainManager.SAMPLES
	shape.map_data = data["heights"]
	_collision.shape = shape
```

Leave `_init` (lines 13–23) and the var declarations unchanged.

- [ ] **Step 3: Update `_rebuild_loaded` in `scripts/terrain_manager.gd`**

`chunk.build(self)` no longer exists. Replace the body (currently ~lines 178–180):

```gdscript
func _rebuild_loaded() -> void:
	for chunk in _chunks.values():
		chunk.setup(self, chunk.coord)
```

- [ ] **Step 4: Parse-check both scripts**

Run:
```
/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot --headless --check-only --path . --script res://scripts/terrain_chunk.gd
/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot --headless --check-only --path . --script res://scripts/terrain_manager.gd
```
Expected: no `Parse Error` / `infer` errors. (A `Config` identifier error is fine — it only appears for scripts that reference the autoload; these don't.)

- [ ] **Step 5: Add `compute_chunk_data` data-shape tests to `tests/headless/test_terrain.gd`**

Append:

```gdscript
func test_compute_chunk_data_shapes_and_heights() -> void:
	var m := _make_manager([_make_layer(60.0, 1.5), _make_layer(15.0, 0.4)] as Array[TerrainLayer], 21)
	var samples: int = ManagerScript.SAMPLES
	var data: Dictionary = m.compute_chunk_data(Vector2i(0, 0))

	var verts: PackedVector3Array = data["vertices"]
	var uvs: PackedVector2Array = data["uvs"]
	var normals: PackedVector3Array = data["normals"]
	var indices: PackedInt32Array = data["indices"]
	var heights: PackedFloat32Array = data["heights"]
	assert_eq(verts.size(), samples * samples, "one vertex per sample")
	assert_eq(uvs.size(), samples * samples, "one uv per sample")
	assert_eq(normals.size(), samples * samples, "one normal per sample")
	assert_eq(heights.size(), samples * samples, "one height per sample")
	assert_eq(indices.size(), (samples - 1) * (samples - 1) * 6, "two triangles per cell")

	# heights match build_heights for the same chunk centre.
	var center: Vector3 = data["center"]
	var bh: PackedFloat32Array = m.build_heights(center)
	for i in [0, samples * samples / 2, samples * samples - 1]:
		assert_almost_eq(heights[i], bh[i], 1e-5, "compute_chunk_data height %d matches build_heights" % i)


func test_compute_chunk_data_normals_point_up() -> void:
	var m := _make_manager([_make_layer(60.0, 1.5)] as Array[TerrainLayer], 21)
	var data: Dictionary = m.compute_chunk_data(Vector2i(0, 0))
	var normals: PackedVector3Array = data["normals"]
	var samples: int = ManagerScript.SAMPLES
	for i in [0, samples * samples / 2, samples * samples - 1]:
		assert_gt(normals[i].y, 0.0, "vertex normal %d points up" % i)
```

- [ ] **Step 6: Run terrain tests, expect all PASS**

Run `./run_tests.sh --fast terrain` in the BACKGROUND; wait for the notification.
Expected: every test in `test_terrain.gd` passes — the two new `compute_chunk_data` tests AND the existing `test_chunk_builds_mesh_and_collision` / load-unload / seam / spawn tests (now exercising the `apply_data` path). If `test_chunk_builds_mesh_and_collision`'s normals-point-up assertion fails, the normal cross-product order is wrong — it must be `(vertices[ic] - vertices[ia]).cross(vertices[ib] - vertices[ia])`; do NOT weaken the test.

- [ ] **Step 7: Checkpoint** — terrain tests green; no threading yet. Do not commit (no git).

---

## Task 2: Threaded generation queue

Add the runtime threaded path. Editor and tests run synchronous via a flag.

**Files:**
- Modify: `scripts/terrain_manager.gd`
- Test: `tests/headless/test_terrain.gd`

- [ ] **Step 1: Add the queue state + constant to `scripts/terrain_manager.gd`**

Add the constant near the other consts (after `const RADIUS := 1`):

```gdscript
const MAX_INTEGRATIONS_PER_FRAME := 1   # cap chunk node creation per frame
```

Add these member vars next to `var _chunks: Dictionary = {}` (after the `_last_focus_coord` line):

```gdscript
# Runtime generates chunks on worker threads; editor/tests stay synchronous.
@export var use_threaded_generation: bool = true
var _pending: Dictionary = {}          # coord -> WorkerThreadPool task id
var _results: Dictionary = {}          # coord -> data Dictionary (worker-written)
var _results_mutex: Mutex = Mutex.new()
```

- [ ] **Step 2: Force synchronous editor mode + synchronous initial ring in `_ready`**

Replace the existing `_ready` (currently ~lines 130–137) with:

```gdscript
func _ready() -> void:
	if Engine.is_editor_hint():
		use_threaded_generation = false
	if layers.is_empty():
		layers = _default_layers()
	else:
		_connect_layer_signals()
	# Initial ring is built synchronously so there is always ground under the car
	# at spawn; only later boundary crossings use the threaded queue.
	var focus := _focus_node()
	var origin: Vector3 = focus.global_position if focus != null else Vector3.ZERO
	_reconcile(chunk_coord_for(origin), true)
	_last_focus_coord = chunk_coord_for(origin)
```

- [ ] **Step 3: Add `_integrate_ready` to `_process`**

Replace the existing `_process` (currently ~lines 140–143) with:

```gdscript
func _process(_delta: float) -> void:
	var focus := _focus_node()
	if focus != null:
		update_focus(focus.global_position)
	_integrate_ready()
```

- [ ] **Step 4: Branch `_reconcile` on the flag and add the worker helpers**

Replace the existing `_reconcile` (currently ~lines 162–175) with the version below, and add the four helper functions after it:

```gdscript
func _reconcile(center: Vector2i, force_sync: bool = false) -> void:
	var wanted := target_coords(center)
	# Free chunks outside the ring.
	for coord in _chunks.keys():
		if not wanted.has(coord):
			_chunks[coord].queue_free()
			_chunks.erase(coord)
	# Forget pending requests outside the ring (their results are discarded on arrival).
	for coord in _pending.keys():
		if not wanted.has(coord):
			_pending.erase(coord)
	# Schedule / build missing chunks.
	for coord in wanted:
		if _chunks.has(coord) or _pending.has(coord):
			continue
		if use_threaded_generation and not force_sync:
			_request_chunk(coord)
		else:
			_spawn_chunk(coord, compute_chunk_data(coord))


func _request_chunk(coord: Vector2i) -> void:
	_pending[coord] = WorkerThreadPool.add_task(_generate_on_worker.bind(coord))


# Runs on a worker thread.
func _generate_on_worker(coord: Vector2i) -> void:
	var data := compute_chunk_data(coord)
	_results_mutex.lock()
	_results[coord] = data
	_results_mutex.unlock()


func _spawn_chunk(coord: Vector2i, data: Dictionary) -> void:
	var chunk: TerrainChunk = ChunkScript.new()
	add_child(chunk)
	chunk.apply_data(self, coord, data)
	_chunks[coord] = chunk


# Main thread: turn up to MAX_INTEGRATIONS_PER_FRAME finished worker results into
# chunk nodes. Results for coords no longer wanted are discarded.
func _integrate_ready() -> void:
	var integrated := 0
	_results_mutex.lock()
	var ready_coords: Array = _results.keys()
	_results_mutex.unlock()
	for coord in ready_coords:
		if integrated >= MAX_INTEGRATIONS_PER_FRAME:
			break
		_results_mutex.lock()
		var data: Dictionary = _results[coord]
		_results.erase(coord)
		_results_mutex.unlock()
		if not _pending.has(coord) or _chunks.has(coord):
			continue  # no longer wanted, or already built — discard
		_pending.erase(coord)
		_spawn_chunk(coord, data)
		integrated += 1
```

- [ ] **Step 5: Wait for outstanding tasks on exit**

Add this method (anywhere at top level, e.g. after `_integrate_ready`):

```gdscript
func _exit_tree() -> void:
	# Ensure no worker writes into freed state after the manager leaves the tree.
	for coord in _pending:
		WorkerThreadPool.wait_for_task_completion(_pending[coord])
	_pending.clear()
	_results.clear()
```

- [ ] **Step 6: Default tests to synchronous in `_make_manager`**

In `tests/headless/test_terrain.gd`, in the `_make_manager` helper, add the flag right after the `manager.set_script(ManagerScript)` line (before `noise_seed`/`layers` are set is fine):

```gdscript
	manager.use_threaded_generation = false  # deterministic synchronous tests
```

- [ ] **Step 7: Add a threaded integration test**

Append to `tests/headless/test_terrain.gd`:

```gdscript
func test_threaded_generation_loads_ring() -> void:
	var m := _make_manager([_make_layer(60.0, 1.5)] as Array[TerrainLayer])
	m.use_threaded_generation = true
	add_child_autofree(m)  # _ready builds the origin ring synchronously
	assert_eq(m.loaded_coords().size(), 9, "origin ring built synchronously at ready")

	# Drive far away -> the new ring is requested on worker threads.
	m.update_focus(Vector3(1000, 0, 0))  # chunk coord (10, 0)
	assert_eq(m._pending.size(), 9, "9 chunks requested for the new ring")
	assert_eq(m.loaded_coords().size(), 0, "old ring freed; new ring not yet integrated")

	# Wait for the workers, then integrate (cap is 1/frame, so pump until drained).
	for coord in m._pending.keys():
		WorkerThreadPool.wait_for_task_completion(m._pending[coord])
	var guard := 0
	while not m._pending.is_empty() and guard < 100:
		m._integrate_ready()
		guard += 1
	assert_eq(m.loaded_coords().size(), 9, "all requested chunks integrated")
	assert_true(m._chunks.has(Vector2i(10, 0)), "centre of the new ring loaded")
```

- [ ] **Step 8: Run terrain tests, expect all PASS**

Run `./run_tests.sh --fast terrain` in the BACKGROUND; wait for the notification.
Expected: all pass, including `test_threaded_generation_loads_ring`. If it hangs or flakes, check that `_exit_tree` waits on tasks and that `_make_manager` set the flag false for the other tests.

- [ ] **Step 9: Checkpoint** — terrain tests green with threading.

---

## Task 3: Docs + full-suite verification

**Files:**
- Modify: `features/terrain.md`

- [ ] **Step 1: Update the Performance section of `features/terrain.md`**

Replace the current Performance section:

```markdown
## Performance

Builds are synchronous. Crossing a chunk boundary rebuilds only the new
row/column (≤3 chunks), not the whole grid. Threaded/background generation is a
possible future upgrade if it stutters.
```

with:

```markdown
## Performance

Chunk generation is split into a pure `compute_chunk_data(coord)` (noise +
mesh arrays — all CPU math) and a cheap main-thread `apply_data` (builds the
`ArrayMesh` + `HeightMapShape3D` and adds the node).

At runtime (`use_threaded_generation = true`), `compute_chunk_data` runs on a
`WorkerThreadPool` task; `_process` integrates at most
`MAX_INTEGRATIONS_PER_FRAME` (1) finished chunk per frame, so boundary crossings
don't stutter. Worker results land in a `Mutex`-guarded `_results` dict; coords
that leave the ring before integrating are discarded. `_exit_tree` waits on any
outstanding tasks.

The **initial ring** is built synchronously in `_ready` (a one-time startup
hitch) so there is always ground under the car at spawn. The **editor**
(`Engine.is_editor_hint()`) and **tests** force `use_threaded_generation =
false` for instant, deterministic builds.

Newly entered chunks can appear 1–2 frames late, but the car sits well inside
the loaded 3×3 ring and fog hides the far edge, so the pop-in is not visible.
```

- [ ] **Step 2: Run the FULL suite, expect all PASS**

Run `./run_tests.sh` in the BACKGROUND; wait for the notification (~4 min).
Expected: `ALL TESTS PASSED` (107+ tests). The new tests add a few asserts.

- [ ] **Step 3: Final checkpoint** — full suite green; `features/terrain.md` matches the code.

---

## Self-Review

- **Spec coverage:** `compute_chunk_data` pure + arrays (Task 1) ✓; manual normals replacing SurfaceTool (Task 1, with correct cross order) ✓; `apply_data` main-thread mesh/shape (Task 1) ✓; `_pending`/`_results`/mutex (Task 2) ✓; `_reconcile` enqueues via `WorkerThreadPool.add_task` (Task 2) ✓; `_process` integrates ≤1/frame (Task 2) ✓; `_exit_tree` waits (Task 2) ✓; `use_threaded_generation` flag, editor-forced-false, tests-false (Task 2) ✓; initial ring synchronous (Task 2 `_ready`) ✓; testing: data-shape, heights match, normals up, threaded integration (Tasks 1–2) ✓; docs (Task 3) ✓.
- **Type consistency:** `compute_chunk_data(coord) -> Dictionary` with keys `center/heights/vertices/uvs/normals/indices`; `apply_data(manager, coord, data)` reads those exact keys; `_request_chunk`/`_generate_on_worker`/`_spawn_chunk`/`_integrate_ready`/`_exit_tree`, `_pending`, `_results`, `_results_mutex`, `use_threaded_generation`, `MAX_INTEGRATIONS_PER_FRAME` used consistently across tasks. `setup` and `_rebuild_loaded` updated to the new API.
- **Placeholder scan:** none — every code step is complete.
- **Note:** git "commit" steps intentionally omitted (project not under git); checkpoints use `./run_tests.sh`.
