# Road Flattening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Flatten terrain grid nodes that lie on the generated track to the road's height (terrain sampled along the centerline), so the road is flat across its width with a sharp step at the edges — affecting both the rendered mesh and collision.

**Architecture:** `TerrainManager.bake_road()` samples `height_at` along the 2D centerline and records, per global grid-vertex index, the nearest centerline height (`road_heights`). `compute_chunk_data` overrides on-road vertices' height (mesh + collision) from `road_heights`. The track is generated and applied *before* the terrain ring is built (a deferred `build_initial()` driven by `world.gd`), so nothing is rebuilt.

**Tech Stack:** Godot 4.6 GDScript, GUT headless tests.

> **Project rules:** NOT under git — no git commands; tasks end with a **Checkpoint** (confirm tests pass), not a commit. Run tests with `./run_tests.sh --fast <name>` ALWAYS via `run_in_background: true`; wait for the completion notification; never two at once; check none running first. Save the full `./run_tests.sh` for the END. Godot: `/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot`.

> **Conventions:** Global grid-vertex index `Vector2i(coord.x*(SAMPLES-1)+xi, coord.y*(SAMPLES-1)+zi)` equals `Vector2i(roundi(world_x/CELL_M), roundi(world_z/CELL_M))` and is shared across chunk seams. `CELL_M == 0.5`, `SAMPLES == 101`, `SAMPLES-1 == 100`. The centerline is a `Curve2D` whose x→world x, y→world z.

---

## File Structure

- Modify: `scripts/terrain_manager.gd` — `road_heights` state, `defer_initial_build`, `build_initial()`, `bake_road()`, flatten in `compute_chunk_data`, new `set_track` signature.
- Modify: `scripts/terrain_chunk.gd` — remove the now-unused `apply_colors`.
- Modify: `scripts/world.gd` — ordered generate → bake → set_track → build_initial.
- Modify: `main.tscn` — `defer_initial_build = true` on `Floor`.
- Modify: `tests/headless/test_terrain.gd` — defer/build_initial, bake_road, flatten, updated set_track tests.
- Modify: `tests/headless/test_smoke.gd` — assert the ring is built in the deferred+ordered startup.

---

## Task 1: Defer the initial ring build

**Files:**
- Modify: `scripts/terrain_manager.gd`
- Test: `tests/headless/test_terrain.gd`

- [ ] **Step 1: Write the failing test**

Append to `tests/headless/test_terrain.gd`:

```gdscript
func test_defer_initial_build_skips_ring_until_called() -> void:
	var m := _make_manager([_make_layer(60.0, 1.5)] as Array[TerrainLayer], 21)
	m.defer_initial_build = true
	add_child_autofree(m)  # _ready must NOT build the ring when deferred
	assert_eq(m.loaded_coords().size(), 0, "no chunks built when deferred")
	m.build_initial()
	assert_eq(m.loaded_coords().size(), 9, "build_initial builds the 3x3 ring")
```

- [ ] **Step 2: Run to verify it fails**

Run (background): `./run_tests.sh --fast terrain`
Expected: FAIL — `defer_initial_build` / `build_initial` don't exist (and `_ready` builds 9 chunks regardless).

- [ ] **Step 3: Add the flag**

In `scripts/terrain_manager.gd`, add after the `use_threaded_generation` export (around the other `var` declarations near the top):

```gdscript
# When true, _ready does NOT build the initial ring — a parent (world.gd) builds
# it via build_initial() after the track is applied, so flattening is baked in on
# the first build. The editor always previews terrain regardless of this flag.
@export var defer_initial_build: bool = false
```

- [ ] **Step 4: Extract `build_initial` and gate `_ready`**

In `scripts/terrain_manager.gd`, replace the current `_ready`:

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

with:

```gdscript
func _ready() -> void:
	if Engine.is_editor_hint():
		use_threaded_generation = false
	if layers.is_empty():
		layers = _default_layers()
	else:
		_connect_layer_signals()
	# Build the initial ring now unless a parent will drive it (defer). The editor
	# always previews, so it builds regardless of the flag.
	if Engine.is_editor_hint() or not defer_initial_build:
		build_initial()


# Build the initial 3x3 ring synchronously around the focus (the car), so there
# is always ground under the car at spawn; later boundary crossings use the
# threaded queue.
func build_initial() -> void:
	var focus := _focus_node()
	var origin: Vector3 = focus.global_position if focus != null else Vector3.ZERO
	_reconcile(chunk_coord_for(origin), true)
	_last_focus_coord = chunk_coord_for(origin)
```

- [ ] **Step 5: Run to verify it passes**

Run (background): `./run_tests.sh --fast terrain`
Expected: PASS (all terrain tests, including the new defer test).

- [ ] **Step 6: Checkpoint** — deferred build works.

---

## Task 2: `bake_road` + `road_heights`

**Files:**
- Modify: `scripts/terrain_manager.gd`
- Test: `tests/headless/test_terrain.gd`

- [ ] **Step 1: Write the failing test**

Append to `tests/headless/test_terrain.gd`:

```gdscript
func test_bake_road_flattens_vertices_to_nearest_centerline_height() -> void:
	var m := _make_manager([_make_layer(20.0, 3.0)] as Array[TerrainLayer], 5)
	# A 10 m straight centerline along +X at world z = 0.
	var curve := Curve2D.new()
	curve.add_point(Vector2(0.0, 0.0))
	curve.add_point(Vector2(10.0, 0.0))
	var rh := m.bake_road(curve, 2.0)  # width 2 m -> vertices within 1 m of the line
	# The grid vertex at world (5, 0) -> global index (10, 0) is on the road.
	var on := Vector2i(roundi(5.0 / ManagerScript.CELL_M), 0)
	assert_true(rh.has(on), "vertex on the road is baked")
	assert_almost_eq(rh[on], m.height_at(5.0, 0.0), 0.1,
		"road vertex takes the nearest centerline point's terrain height")
	# A vertex 8 m off the line in z is not on the road.
	var off := Vector2i(roundi(5.0 / ManagerScript.CELL_M), roundi(8.0 / ManagerScript.CELL_M))
	assert_false(rh.has(off), "vertex far from the road is not baked")
	assert_eq(m.road_heights, rh, "bake_road stores the result on the manager")
```

- [ ] **Step 2: Run to verify it fails**

Run (background): `./run_tests.sh --fast terrain`
Expected: FAIL — `bake_road` / `road_heights` don't exist.

- [ ] **Step 3: Add `road_heights` state**

In `scripts/terrain_manager.gd`, add next to the `track_cells`/`track_color` declarations:

```gdscript
# Global grid-vertex index (Vector2i) -> flattened Y for vertices on the road.
# Built by bake_road(); read by compute_chunk_data(). Empty = no flattening.
var road_heights: Dictionary = {}
```

- [ ] **Step 4: Add a sample-step const + `bake_road`**

In `scripts/terrain_manager.gd`, add a const near the top consts:

```gdscript
const ROAD_SAMPLE_STEP_M := 0.25  # centerline sampling density for bake_road
```

Add the method (e.g. just before `set_track`):

```gdscript
# Sample the terrain along the 2D centerline (x -> world x, y -> world z) and
# record, per global grid-vertex index within `width`/2 of the line, the height
# of the nearest centerline sample. Densely sub-samples each segment so straight
# spans (which tessellate to just their endpoints) still flatten their interior.
# Stores and returns the road_heights dictionary.
func bake_road(centerline: Curve2D, width: float) -> Dictionary:
	var heights_out: Dictionary = {}
	var best: Dictionary = {}  # vertex index -> best (smallest) distance so far
	var half := width / 2.0
	var reach := int(ceil(half / CELL_M)) + 1
	var poly := centerline.tessellate()
	for i in range(1, poly.size()):
		var a := poly[i - 1]
		var b := poly[i]
		var seg_len := a.distance_to(b)
		var steps := int(ceil(seg_len / ROAD_SAMPLE_STEP_M)) + 1
		for s in steps + 1:
			var t := float(s) / float(steps) if steps > 0 else 0.0
			var p := a.lerp(b, t)
			var y := height_at(p.x, p.y)
			var cx := roundi(p.x / CELL_M)
			var cz := roundi(p.y / CELL_M)
			for dz in range(-reach, reach + 1):
				for dx in range(-reach, reach + 1):
					var v := Vector2i(cx + dx, cz + dz)
					var d := Vector2(v.x * CELL_M, v.y * CELL_M).distance_to(p)
					if d <= half and (not best.has(v) or d < best[v]):
						best[v] = d
						heights_out[v] = y
	road_heights = heights_out
	return heights_out
```

- [ ] **Step 5: Run to verify it passes**

Run (background): `./run_tests.sh --fast terrain`
Expected: PASS.

- [ ] **Step 6: Checkpoint** — road heights bake correctly.

---

## Task 3: Flatten in `compute_chunk_data` + new `set_track`

**Files:**
- Modify: `scripts/terrain_manager.gd`
- Modify: `scripts/terrain_chunk.gd`
- Test: `tests/headless/test_terrain.gd`

- [ ] **Step 1: Write the failing tests**

Append to `tests/headless/test_terrain.gd`:

```gdscript
func test_compute_chunk_data_flattens_on_road_vertices() -> void:
	var m := _make_manager([_make_layer(20.0, 3.0)] as Array[TerrainLayer], 5)
	var samples: int = ManagerScript.SAMPLES
	# Flatten chunk (0,0)'s local vertex (xi=10, zi=0) -> global index (10, 0).
	var vidx := Vector2i(0 * (samples - 1) + 10, 0 * (samples - 1) + 0)
	m.road_heights = { vidx: 42.0 }
	var data: Dictionary = m.compute_chunk_data(Vector2i(0, 0))
	var heights: PackedFloat32Array = data["heights"]
	var verts: PackedVector3Array = data["vertices"]
	# Collision: sample index zi*SAMPLES+xi = 10.
	assert_almost_eq(heights[10], 42.0, 1e-4, "collision height flattened at the road vertex")
	# Mesh: cell (xi=10, zi=0) is cell index 10; its first de-indexed vertex (base
	# = 40) is grid sample (10, 0).
	assert_almost_eq(verts[40].y, 42.0, 1e-4, "mesh vertex flattened at the road vertex")
	# An off-road sample keeps its noise height: sample (xi=5, zi=0) -> world (2.5, 0).
	assert_almost_eq(heights[5], m.height_at(2.5, 0.0), 1e-4, "off-road vertex keeps noise height")


func test_set_track_applies_colour_and_flattening_to_loaded_chunks() -> void:
	var m := _make_manager([_make_layer(60.0, 1.5)] as Array[TerrainLayer], 21)
	add_child_autofree(m)  # not deferred in tests -> ring built in _ready
	var vidx := Vector2i(10, 0)  # chunk (0,0) local vertex (10, 0)
	m.set_track({ Vector2i(0, 0): true }, Color(1, 0, 0), { vidx: 99.0 })
	var chunk = m._chunks[Vector2i(0, 0)]
	var arrays := (chunk.get_node("MeshInstance3D").mesh as ArrayMesh).surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	assert_almost_eq(verts[40].y, 99.0, 1e-4, "set_track rebuilt the chunk with the flattened road vertex")
	assert_eq(colors[0], Color(1, 0, 0), "painted cell (0,0) is the track colour")
	assert_eq(m.road_heights.size(), 1, "road heights stored on the manager")
```

Also delete the now-obsolete `test_set_track_recolors_without_changing_geometry` function from `tests/headless/test_terrain.gd` (flattening changes geometry by design, so its "vertex positions unchanged" premise no longer holds — it is replaced by the two tests above).

- [ ] **Step 2: Run to verify it fails**

Run (background): `./run_tests.sh --fast terrain`
Expected: FAIL — flattening not applied; `set_track` takes 2 args, not 3.

- [ ] **Step 3: Flatten in `compute_chunk_data`**

In `scripts/terrain_manager.gd`, replace the height-sampling loop inside `compute_chunk_data`:

```gdscript
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
			grid[idx] = Vector3(lx, h, lz)
```

with (override on-road vertices' height for both mesh and collision):

```gdscript
	for zi in SAMPLES:
		var lz := -half + zi * CELL_M
		var wz := center.z + lz
		for xi in SAMPLES:
			var lx := -half + xi * CELL_M
			var wx := center.x + lx
			var h := 0.0
			for i in noises.size():
				h += noises[i].get_noise_2d(wx, wz) * amplitudes[i]
			# Flatten road vertices to the baked road height (mesh + collision).
			var vidx := Vector2i(coord.x * (SAMPLES - 1) + xi, coord.y * (SAMPLES - 1) + zi)
			if road_heights.has(vidx):
				h = road_heights[vidx]
			var idx := zi * SAMPLES + xi
			heights[idx] = h
			grid[idx] = Vector3(lx, h, lz)
```

- [ ] **Step 4: New `set_track` signature (rebuild loaded chunks)**

In `scripts/terrain_manager.gd`, replace `set_track`:

```gdscript
# Apply a track overlay: store the painted cells/colour and recolour every
# loaded chunk in place. This does NOT rebuild geometry or re-run noise — it only
# swaps each chunk's vertex-colour array. New chunks loaded later read
# track_cells in compute_chunk_data and bake colours at build time.
func set_track(cells: Dictionary, color: Color) -> void:
	track_cells = cells
	track_color = color
	for coord in _chunks:
		_chunks[coord].apply_colors(cell_colors(coord))
```

with:

```gdscript
# Apply a track: store the painted cells/colour and baked road heights, then
# rebuild any currently-loaded chunks (mesh + collision) so colouring AND
# flattening take effect. At startup the ring is deferred (see build_initial),
# so _chunks is empty here and nothing rebuilds; chunks loaded later read the
# stored state in compute_chunk_data and bake it in at build time.
func set_track(cells: Dictionary, color: Color, road_height_map: Dictionary) -> void:
	track_cells = cells
	track_color = color
	road_heights = road_height_map
	for coord in _chunks:
		_chunks[coord].setup(self, coord)
```

- [ ] **Step 5: Remove the now-unused `apply_colors`**

In `scripts/terrain_chunk.gd`, delete the `apply_colors` method (no longer called — `set_track` now does a full `setup()` rebuild):

```gdscript
# Swap just the vertex-colour array on the existing mesh, reusing its vertices,
# UVs and indices (no height sampling, no regeneration).
func apply_colors(colors: PackedColorArray) -> void:
	var mesh := _mesh_instance.mesh as ArrayMesh
	if mesh == null:
		return
	var arrays := mesh.surface_get_arrays(0)
	arrays[Mesh.ARRAY_COLOR] = colors
	var rebuilt := ArrayMesh.new()
	rebuilt.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh_instance.mesh = rebuilt
```

- [ ] **Step 6: Run to verify it passes**

Run (background): `./run_tests.sh --fast terrain`
Expected: PASS — flatten + new set_track tests green; obsolete test removed.

- [ ] **Step 7: Checkpoint** — flattening applied to mesh + collision.

---

## Task 4: Ordered startup wiring

**Files:**
- Modify: `scripts/world.gd`
- Modify: `main.tscn`
- Test: `tests/headless/test_smoke.gd`

- [ ] **Step 1: Update the smoke test**

Replace the `test_main_scene_generates_a_track` function in `tests/headless/test_smoke.gd` with:

```gdscript
func test_main_scene_generates_a_track() -> void:
	await get_tree().physics_frame  # let world._ready() generate + apply + build
	var floor_node = _scene.get_node("Floor")
	assert_gt(floor_node.track_cells.size(), 0, "world generated a non-empty track")
	assert_gt(floor_node.road_heights.size(), 0, "world baked road heights for flattening")
	assert_eq(floor_node.loaded_coords().size(), 9, "deferred ring is built once the track is applied")
```

- [ ] **Step 2: Run to verify it fails**

Run (background): `./run_tests.sh --fast smoke`
Expected: FAIL — `road_heights` empty and/or `set_track` arity error (world still calls the 2-arg form), and the ring may be unbuilt once `main.tscn` defers.

- [ ] **Step 3: Reorder `world._generate_track`**

In `scripts/world.gd`, replace `_generate_track`:

```gdscript
# Build the track from the car's spawn pose and paint it onto the terrain.
func _generate_track(cfg: GameConfig) -> void:
	var xform: Transform3D = $Car.global_transform
	var start_pos := Vector2(xform.origin.x, xform.origin.z)
	# A Node3D's forward is -Z; project it onto the XZ plane.
	var fwd := -xform.basis.z
	var start_heading := Vector2(fwd.x, fwd.z).normalized()
	var result := TrackGenerator.generate(
		start_pos, start_heading, cfg.track_seed, cfg.track_turn_count, cfg.track_width)
	$Floor.set_track(result["cells"], cfg.track_color, result["road_heights"])
```

with the ordered flow (generate → bake → apply → build):

```gdscript
# Build the track from the car's spawn pose, bake road heights, and build the
# (deferred) terrain ring with flattening + colouring already applied — so no
# chunk is ever rebuilt at startup.
func _generate_track(cfg: GameConfig) -> void:
	var xform: Transform3D = $Car.global_transform
	var start_pos := Vector2(xform.origin.x, xform.origin.z)
	# A Node3D's forward is -Z; project it onto the XZ plane.
	var fwd := -xform.basis.z
	var start_heading := Vector2(fwd.x, fwd.z).normalized()
	var result := TrackGenerator.generate(
		start_pos, start_heading, cfg.track_seed, cfg.track_turn_count, cfg.track_width)
	var road_heights := $Floor.bake_road(result["centerline"], cfg.track_width)
	$Floor.set_track(result["cells"], cfg.track_color, road_heights)
	$Floor.build_initial()
```

(Note: the previous version's `set_track(..., result["road_heights"])` was wrong — the generator returns no `road_heights`; the manager bakes them. The block above is the correct call sequence.)

- [ ] **Step 4: Defer the Floor build in the scene**

In `main.tscn`, add `defer_initial_build = true` to the `Floor` node. Find:

```
[node name="Floor" type="Node3D" parent="." unique_id=1791309600]
script = ExtResource("6_terrain")
```

and add the property line under the script line:

```
[node name="Floor" type="Node3D" parent="." unique_id=1791309600]
script = ExtResource("6_terrain")
defer_initial_build = true
```

(Keep the existing `chunk_material = SubResource("mat_floor")` line that follows.)

- [ ] **Step 5: Run to verify it passes**

Run (background): `./run_tests.sh --fast smoke`
Expected: PASS — track + road heights present and the ring is built.

- [ ] **Step 6: Visually confirm**

Run: `/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot res://main.tscn`
Expected: the painted track is now a flat road cut into the terrain — flat across its width with a visible vertical step at the edges where the ground is sloped, following the terrain's rise/fall along its length. (Manual check; close the window when done.)

- [ ] **Step 7: Checkpoint** — flattened road renders in the game.

---

## Task 5: Documentation + final full test run

**Files:**
- Modify: `features/terrain.md`, `features/track.md`

- [ ] **Step 1: Update `features/terrain.md`**

In the track-overlay section, document road flattening: `road_heights` (global
vertex index → flattened Y), `bake_road(centerline, width)` (samples `height_at`
along the centerline, records the nearest height per vertex within `width/2`),
that `compute_chunk_data` overrides on-road vertices' height for **both** the
mesh and the collision height array, and that `set_track(cells, color,
road_heights)` now rebuilds loaded chunks (geometry changes, so it is a full
`setup()` rather than a colour-only swap; `apply_colors` was removed). Document
`defer_initial_build` + `build_initial()`: when deferred, `_ready` skips the ring
so a parent can apply the track first (the editor always previews regardless).

- [ ] **Step 2: Update `features/track.md`**

In the Rendering section, note that the road is **flattened into the terrain**
(grid nodes on the road share the nearest centerline point's height — flat across
width, stepped at the edges, mesh + collision), and that startup ordering
generates + applies the track **before** the terrain ring is built
(`world._generate_track`: generate → `bake_road` → `set_track` → `build_initial`),
so no chunk is rebuilt.

- [ ] **Step 3: Final full test run**

Confirm no background `run_tests.sh` is running, then run the FULL suite
(background): `./run_tests.sh`
Expected: ends with `ALL TESTS PASSED`, no `SCRIPT ERROR` / `Parse Error`.

- [ ] **Step 4: Checkpoint** — feature complete: flattening, ordering, tests, docs in sync.

---

## Self-Review notes

- **Spec coverage:** height source = terrain along centerline (`bake_road`, Task 2); mesh+collision flatten (`compute_chunk_data`, Task 3); per-vertex within `width/2` (Task 2 baking); no-rebuild via deferred build + ordering (Tasks 1, 4); `set_track` signature + removed `apply_colors` (Task 3); tests + docs (Tasks 1–5).
- **Type consistency:** `bake_road(centerline: Curve2D, width: float) -> Dictionary`; `set_track(cells: Dictionary, color: Color, road_height_map: Dictionary)`; `road_heights: Dictionary` keyed by global vertex index `Vector2i`; `build_initial()` / `defer_initial_build: bool`. `world` calls `bake_road` then `set_track(..., road_heights)` then `build_initial` — matches the manager API. Generator return shape is unchanged (no `road_heights` key).
- **No git:** Checkpoints replace commits.
