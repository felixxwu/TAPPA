# Chunked Infinite Terrain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single fixed 200×200 m terrain tile with a moving 3×3 grid of 100 m chunks that load/unload around the car, making the terrain effectively infinite while rendering only the immediate surroundings.

**Architecture:** A `TerrainManager` (`Node3D`) owns all noise state and `height_at()`, and reconciles a 3×3 set of `TerrainChunk` (`StaticBody3D`) children around the car's current chunk coordinate. Each chunk is centred on its tile, samples the manager's noise at absolute world coordinates (so seams match automatically), and builds its own mesh + `HeightMapShape3D` collision. The old single `Floor` tile and the `Border` safety node are removed.

**Tech Stack:** Godot 4 / GDScript, `FastNoiseLite` Perlin noise, `SurfaceTool` meshes, `HeightMapShape3D` collision, GUT headless tests.

---

## File Structure

- **Create** `scripts/terrain_manager.gd` — `TerrainManager`, `@tool extends Node3D`. Owns seed/layers/tiling, `height_at()`, `build_heights()`, chunk-coord math, and the load/unload reconcile loop driven by the car.
- **Create** `scripts/terrain_chunk.gd` — `TerrainChunk`, `@tool extends StaticBody3D`. Built at runtime; turns a height array into a mesh + collision centred on its tile.
- **Delete** `scripts/terrain.gd` — its responsibilities split between the two new files.
- **Modify** `main.tscn` — repoint `Floor` to the manager, drop its child mesh/collision, add an exported chunk material, remove the `Border` node and its sub-resources.
- **Modify** `scripts/world.gd` — apply config to the manager; delete the Border block.
- **Modify** `tests/headless/test_terrain.gd` — retarget to the manager; add seam + load/unload tests.
- **Modify** `tests/headless/test_smoke.gd` — `Floor` is now a `Node3D`, not a `StaticBody3D`.
- **Modify** `features/terrain.md` — rewrite for the chunked model.

Note: this project is **not** under git, so the "Commit" steps below are written as `git` commands per the plan template but should be **skipped** — instead, run `./run_tests.sh` (background) at the marked checkpoints and confirm green.

---

## Task 1: TerrainManager core (noise + chunk math, no chunks yet)

**Files:**
- Create: `scripts/terrain_manager.gd`
- Test: `tests/headless/test_terrain.gd`

- [ ] **Step 1: Write `scripts/terrain_manager.gd` with noise state and pure helpers**

```gdscript
@tool
extends Node3D
class_name TerrainManager

# Owns the procedural terrain: noise state, height sampling, and the lifecycle
# of the TerrainChunk children loaded around the car. The terrain is infinite in
# theory (height_at is pure noise over world coords); only a RADIUS-ring of
# chunks around the focus is ever built.

const CHUNK_M := 100.0                       # chunk edge length in metres
const CELL_M := 0.5                          # grid cell size
const SAMPLES := int(CHUNK_M / CELL_M) + 1   # 201 height vertices per edge
const RADIUS := 1                            # ring radius -> (2*RADIUS+1)^2 = 3x3

const ChunkScript := preload("res://scripts/terrain_chunk.gd")

@export var noise_seed: int = 1337:
	set(value):
		noise_seed = value
		_rebuild_loaded()

@export var layers: Array[TerrainLayer] = []:
	set(value):
		layers = value
		_connect_layer_signals()
		_rebuild_loaded()

@export var texture_tile_per_meter: float = 0.125:
	set(value):
		texture_tile_per_meter = value
		_rebuild_loaded()

# Material applied to every chunk mesh. Set in main.tscn to the shared floor
# material so it survives runtime mesh assignment (see test_smoke).
@export var chunk_material: Material

# Node whose position drives chunk loading (the car). Resolved lazily.
@export var focus_path: NodePath = NodePath("../Car")

# coord (Vector2i) -> TerrainChunk
var _chunks: Dictionary = {}
var _last_focus_coord: Vector2i = Vector2i(2147483647, 0)  # force first reconcile


func _connect_layer_signals() -> void:
	for layer in layers:
		if layer == null:
			continue
		if not layer.changed.is_connected(_rebuild_loaded):
			layer.changed.connect(_rebuild_loaded)


func _default_layers() -> Array[TerrainLayer]:
	var result: Array[TerrainLayer] = []
	for params in [[60.0, 1.5], [15.0, 0.4], [3.0, 0.1]]:
		var layer := TerrainLayer.new()
		layer.wavelength_m = params[0]
		layer.amplitude_m = params[1]
		result.append(layer)
	return result


func _is_valid_layer(layer: TerrainLayer) -> bool:
	return layer != null and layer.wavelength_m > 0.0


func _make_noise(layer_index: int) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.fractal_type = FastNoiseLite.FRACTAL_NONE
	noise.seed = noise_seed + layer_index
	noise.frequency = 1.0 / layers[layer_index].wavelength_m
	return noise


func height_at(x: float, z: float) -> float:
	var h := 0.0
	for i in layers.size():
		if not _is_valid_layer(layers[i]):
			continue
		h += _make_noise(i).get_noise_2d(x, z) * layers[i].amplitude_m
	return h


# SAMPLES x SAMPLES heights centred on `center` (a chunk centre), sampled at
# absolute world coords so adjacent chunks agree on shared edges. Noises are
# built once here (height_at rebuilds per call — fine for single samples, too
# slow for 40k).
func build_heights(center: Vector3) -> PackedFloat32Array:
	var noises: Array[FastNoiseLite] = []
	var amplitudes: PackedFloat32Array = []
	for i in layers.size():
		if not _is_valid_layer(layers[i]):
			continue
		noises.append(_make_noise(i))
		amplitudes.append(layers[i].amplitude_m)

	var heights := PackedFloat32Array()
	heights.resize(SAMPLES * SAMPLES)
	var half := CHUNK_M / 2.0
	for zi in SAMPLES:
		var z := center.z - half + zi * CELL_M
		for xi in SAMPLES:
			var x := center.x - half + xi * CELL_M
			var h := 0.0
			for i in noises.size():
				h += noises[i].get_noise_2d(x, z) * amplitudes[i]
			heights[zi * SAMPLES + xi] = h
	return heights


# Chunk coordinate (integer grid) containing a world position.
func chunk_coord_for(pos: Vector3) -> Vector2i:
	return Vector2i(floori(pos.x / CHUNK_M), floori(pos.z / CHUNK_M))


# The (2*RADIUS+1)^2 coords that should be loaded around a centre coord.
func target_coords(center: Vector2i) -> Array:
	var result: Array = []
	for dz in range(-RADIUS, RADIUS + 1):
		for dx in range(-RADIUS, RADIUS + 1):
			result.append(center + Vector2i(dx, dz))
	return result


func loaded_coords() -> Array:
	return _chunks.keys()


# Placeholder; filled in Task 2.
func _rebuild_loaded() -> void:
	pass
```

- [ ] **Step 2: Add manager-targeted tests to `tests/headless/test_terrain.gd`**

Replace the header preload and `_make_terrain` helper so existing height tests run against the manager. Change the top of the file:

```gdscript
extends GutTest

# Tests for scripts/terrain_manager.gd / terrain_chunk.gd / terrain_layer.gd.
# height_at() is pure noise and works out-of-tree; chunk build tests add nodes.

const ManagerScript := preload("res://scripts/terrain_manager.gd")
const ChunkScript := preload("res://scripts/terrain_chunk.gd")

const SAMPLE_POINTS := [
	Vector2(0.0, 0.0), Vector2(12.5, -33.0), Vector2(-80.0, 41.5), Vector2(99.0, 99.0),
]


func _make_layer(wavelength: float, amplitude: float) -> TerrainLayer:
	var layer := TerrainLayer.new()
	layer.wavelength_m = wavelength
	layer.amplitude_m = amplitude
	return layer


# A bare TerrainManager (no focus node), not added to the tree by default.
func _make_manager(layer_list: Array[TerrainLayer], seed_value: int = 1337) -> Node3D:
	var manager := Node3D.new()
	manager.set_script(ManagerScript)
	manager.focus_path = NodePath("")  # no car; tests drive focus explicitly
	manager.noise_seed = seed_value
	manager.layers = layer_list
	autofree(manager)
	return manager
```

Then update each existing `height_at` test's helper call from `_make_terrain(` to `_make_manager(` (tests: `test_height_at_is_deterministic_per_seed`, `test_doubling_amplitude_doubles_height`, `test_two_layers_sum_of_individual_layers`, `test_invalid_layers_are_skipped`). Add new tests for the coord math:

```gdscript
func test_chunk_coord_for_partitions_by_chunk_size() -> void:
	var m := _make_manager([_make_layer(60.0, 1.5)] as Array[TerrainLayer])
	assert_eq(m.chunk_coord_for(Vector3(0, 0, 0)), Vector2i(0, 0))
	assert_eq(m.chunk_coord_for(Vector3(50, 0, 50)), Vector2i(0, 0))
	assert_eq(m.chunk_coord_for(Vector3(100, 0, 0)), Vector2i(1, 0))
	assert_eq(m.chunk_coord_for(Vector3(-1, 0, -1)), Vector2i(-1, -1))


func test_target_coords_is_three_by_three() -> void:
	var m := _make_manager([_make_layer(60.0, 1.5)] as Array[TerrainLayer])
	var coords := m.target_coords(Vector2i(0, 0))
	assert_eq(coords.size(), 9, "3x3 ring around centre")
	assert_true(coords.has(Vector2i(0, 0)), "includes centre")
	assert_true(coords.has(Vector2i(1, 1)), "includes a corner")
	assert_false(coords.has(Vector2i(2, 0)), "excludes radius-2")
```

- [ ] **Step 3: Run the manager tests, expect FAIL (chunk script not created yet)**

Run: `./run_tests.sh --fast terrain` in the background.
Expected: FAIL — `tests/headless/test_terrain.gd` fails to parse because `res://scripts/terrain_chunk.gd` doesn't exist yet (preloaded at the top). This proves the test file is loaded; Task 2 creates the chunk script.

- [ ] **Step 4: Checkpoint** — leave failing; the chunk script in the next task makes the file parse. Do not commit (project not under git).

---

## Task 2: TerrainChunk + reconcile loop

**Files:**
- Create: `scripts/terrain_chunk.gd`
- Modify: `scripts/terrain_manager.gd` (fill in `_rebuild_loaded`, add reconcile + lifecycle)
- Test: `tests/headless/test_terrain.gd`

- [ ] **Step 1: Write `scripts/terrain_chunk.gd`**

```gdscript
@tool
extends StaticBody3D
class_name TerrainChunk

# One tile of the chunked terrain, built at runtime by TerrainManager. Centred
# on its chunk so the centred mesh + HeightMapShape3D span exactly the tile.

var coord: Vector2i
var _mesh_instance: MeshInstance3D
var _collision: CollisionShape3D


func _init() -> void:
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "MeshInstance3D"
	add_child(_mesh_instance)
	_collision = CollisionShape3D.new()
	_collision.name = "CollisionShape3D"
	# HeightMapShape3D spans (SAMPLES-1) cells of 1 unit; scale cells to CELL_M.
	_collision.transform = Transform3D(
		TerrainManager.CELL_M, 0, 0, 0, 1.0, 0, 0, 0, TerrainManager.CELL_M,
		0, 0, 0)
	add_child(_collision)


func setup(manager: TerrainManager, chunk_coord: Vector2i) -> void:
	coord = chunk_coord
	# Position at the chunk centre.
	position = Vector3((chunk_coord.x + 0.5) * manager.CHUNK_M, 0.0,
		(chunk_coord.y + 0.5) * manager.CHUNK_M)
	build(manager)


func build(manager: TerrainManager) -> void:
	var heights := manager.build_heights(position)
	_mesh_instance.material_override = manager.chunk_material
	_build_mesh(manager, heights)
	_build_collision(heights)


func _build_mesh(manager: TerrainManager, heights: PackedFloat32Array) -> void:
	var samples := manager.SAMPLES
	var cell := manager.CELL_M
	var half := manager.CHUNK_M / 2.0
	var tile := manager.texture_tile_per_meter
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for zi in samples:
		for xi in samples:
			var lx := -half + xi * cell
			var lz := -half + zi * cell
			# UVs in world coords so the checker is continuous across seams.
			st.set_uv(Vector2(position.x + lx, position.z + lz) * tile)
			st.add_vertex(Vector3(lx, heights[zi * samples + xi], lz))
	for zi in samples - 1:
		for xi in samples - 1:
			var a := zi * samples + xi
			var b := a + 1
			var c := a + samples
			var d := c + 1
			# Godot front faces wind clockwise (viewed from the top here).
			st.add_index(a); st.add_index(b); st.add_index(c)
			st.add_index(b); st.add_index(d); st.add_index(c)
	st.generate_normals()
	_mesh_instance.mesh = st.commit()


func _build_collision(heights: PackedFloat32Array) -> void:
	var shape := HeightMapShape3D.new()
	shape.map_width = TerrainManager.SAMPLES
	shape.map_depth = TerrainManager.SAMPLES
	shape.map_data = heights
	_collision.shape = shape
```

- [ ] **Step 2: Replace `_rebuild_loaded` and add the reconcile/lifecycle code in `scripts/terrain_manager.gd`**

Replace the placeholder `_rebuild_loaded` with the real lifecycle. Add `_ready`, `_process`, `update_focus`, `_reconcile`:

```gdscript
func _ready() -> void:
	if layers.is_empty():
		layers = _default_layers()
	else:
		_connect_layer_signals()
	# Initial load: around the focus if present, else origin (editor preview).
	var focus := _focus_node()
	update_focus(focus.global_position if focus != null else Vector3.ZERO)


func _process(_delta: float) -> void:
	var focus := _focus_node()
	if focus != null:
		update_focus(focus.global_position)


func _focus_node() -> Node3D:
	if focus_path.is_empty():
		return null
	return get_node_or_null(focus_path) as Node3D


# Reconcile the loaded 3x3 set to be centred on `pos`. Cheap to call every
# frame: only does work when the focus crosses into a new chunk.
func update_focus(pos: Vector3) -> void:
	var center := chunk_coord_for(pos)
	if center == _last_focus_coord and not _chunks.is_empty():
		return
	_last_focus_coord = center
	_reconcile(center)


func _reconcile(center: Vector2i) -> void:
	var wanted := target_coords(center)
	# Free chunks outside the ring.
	for coord in _chunks.keys():
		if not wanted.has(coord):
			_chunks[coord].queue_free()
			_chunks.erase(coord)
	# Load missing chunks.
	for coord in wanted:
		if not _chunks.has(coord):
			var chunk: TerrainChunk = ChunkScript.new()
			add_child(chunk)
			chunk.setup(self, coord)
			_chunks[coord] = chunk


func _rebuild_loaded() -> void:
	for chunk in _chunks.values():
		chunk.build(self)
```

- [ ] **Step 3: Add chunk build, seam, and load/unload tests to `tests/headless/test_terrain.gd`**

```gdscript
func test_chunk_builds_mesh_and_collision() -> void:
	var m := _make_manager([_make_layer(60.0, 1.5)] as Array[TerrainLayer], 21)
	add_child_autofree(m)  # _ready loads the 3x3 around origin (no focus -> origin)
	var samples: int = ManagerScript.SAMPLES
	assert_eq(m.loaded_coords().size(), 9, "3x3 chunks loaded around origin")

	var chunk = m._chunks[Vector2i(0, 0)]
	var mesh := chunk.get_node("MeshInstance3D").mesh as ArrayMesh
	assert_not_null(mesh, "chunk mesh is an ArrayMesh")
	assert_eq(mesh.surface_get_array_len(0), samples * samples, "one vertex per sample")

	var col: CollisionShape3D = chunk.get_node("CollisionShape3D")
	var shape := col.shape as HeightMapShape3D
	assert_eq(shape.map_width, samples, "map_width matches sample count")
	assert_eq(col.scale, Vector3(0.5, 1.0, 0.5), "collision scaled to 0.5m cells")

	# Front faces must wind so normals point up, else culling hides the terrain.
	var normals: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_NORMAL]
	for i in [0, (samples * samples) / 2, samples * samples - 1]:
		assert_gt(normals[i].y, 0.0, "vertex normal %d points up" % i)


func test_adjacent_chunks_agree_on_shared_edge() -> void:
	# Chunk (0,0) spans x in [0,100]; chunk (1,0) spans x in [100,200]. Their
	# shared edge is the plane x=100 — heights there must match exactly.
	var m := _make_manager([_make_layer(60.0, 1.5), _make_layer(15.0, 0.4)] as Array[TerrainLayer], 9)
	var half: float = ManagerScript.CHUNK_M / 2.0
	var c0 := Vector3((0 + 0.5) * ManagerScript.CHUNK_M, 0, (0 + 0.5) * ManagerScript.CHUNK_M)
	var c1 := Vector3((1 + 0.5) * ManagerScript.CHUNK_M, 0, (0 + 0.5) * ManagerScript.CHUNK_M)
	var h0 := m.build_heights(c0)
	var h1 := m.build_heights(c1)
	var samples: int = ManagerScript.SAMPLES
	for zi in samples:
		var right_edge := h0[zi * samples + (samples - 1)]  # x = c0.x + half = 100
		var left_edge := h1[zi * samples + 0]               # x = c1.x - half = 100
		assert_almost_eq(left_edge, right_edge, 1e-5,
			"chunk seam heights agree at row %d" % zi)


func test_moving_focus_loads_and_unloads_chunks() -> void:
	var m := _make_manager([_make_layer(60.0, 1.5)] as Array[TerrainLayer])
	add_child_autofree(m)
	m.update_focus(Vector3.ZERO)
	assert_true(m._chunks.has(Vector2i(0, 0)), "centre chunk loaded at origin")
	assert_false(m._chunks.has(Vector2i(5, 0)), "far chunk not loaded")

	# Move far away: the origin chunk should unload, the new ring should load.
	m.update_focus(Vector3(500, 0, 0))  # chunk coord (5,0)
	assert_eq(m.loaded_coords().size(), 9, "still exactly 3x3 loaded")
	assert_true(m._chunks.has(Vector2i(5, 0)), "new centre chunk loaded")
	assert_false(m._chunks.has(Vector2i(0, 0)), "origin chunk unloaded")
```

- [ ] **Step 4: Run terrain tests, expect PASS**

Run: `./run_tests.sh --fast terrain` in the background.
Expected: all `test_terrain.gd` tests PASS (height determinism, coord math, chunk build, seam, load/unload).

Note: `test_generated_mesh_collision_and_agreement`, `test_editing_layer_amplitude_regenerates_heightmap`, and `test_ready_with_empty_layers_creates_defaults` reference the OLD `_make_terrain` StaticBody helper and `TerrainScript` — delete those three tests; their behaviour is now covered by `test_chunk_builds_mesh_and_collision`, the `_rebuild_loaded` path, and `_default_layers` (add the small assert below).

```gdscript
func test_ready_with_empty_layers_creates_defaults() -> void:
	var m := _make_manager([] as Array[TerrainLayer])
	add_child_autofree(m)  # _ready populates defaults
	assert_eq(m.layers.size(), 3, "three default layers")
	var expected := [[60.0, 1.5], [15.0, 0.4], [3.0, 0.1]]
	for i in mini(m.layers.size(), 3):
		assert_eq(m.layers[i].wavelength_m, float(expected[i][0]), "layer %d wavelength" % i)
		assert_eq(m.layers[i].amplitude_m, float(expected[i][1]), "layer %d amplitude" % i)
```

- [ ] **Step 5: Checkpoint** — confirm `--fast terrain` green before wiring the scene.

---

## Task 3: Wire the scene (main.tscn + world.gd), remove Border, delete old script

**Files:**
- Modify: `main.tscn`
- Modify: `scripts/world.gd`
- Delete: `scripts/terrain.gd`

- [ ] **Step 1: Repoint the `Floor` node and material in `main.tscn`**

In the `[ext_resource ...]` block at the top, change the terrain script resource (line 9) from `terrain.gd` to the manager:

```
[ext_resource type="Script" path="res://scripts/terrain_manager.gd" id="6_terrain"]
```

(Drop the stale `uid=` if Godot complains; it will reassign.)

Replace the `Floor` node block (was a `StaticBody3D` with `MeshInstance3D` + `CollisionShape3D` children) with a bare manager `Node3D` that references the floor material via the new export:

```
[node name="Floor" type="Node3D" parent="."]
script = ExtResource("6_terrain")
layers = Array[ExtResource("3_5vw27")]([SubResource("Resource_kek77"), SubResource("Resource_4c57u"), SubResource("Resource_efxa6")])
chunk_material = SubResource("mat_floor")
```

Delete the `Floor/MeshInstance3D` and `Floor/CollisionShape3D` node blocks (old lines 66–70) — chunks create these at runtime.

- [ ] **Step 2: Remove the `Border` node and its sub-resources from `main.tscn`**

Delete these node blocks (old lines 72–80): `Border`, `Border/MeshInstance3D`, `Border/CollisionShape3D`. Delete the now-unused sub-resources: `mat_border` (lines 40–45), `mesh_border` (47–48), `shape_border` (50). Leave `mat_floor` and `checker` in place (still used by chunks).

- [ ] **Step 3: Update `scripts/world.gd` — apply config to manager, drop Border block**

The `$Floor` setters still exist on the manager (`texture_tile_per_meter`, `layers`), so the existing apply logic works unchanged. Remove the Border tiling block. Delete these three lines from `_ready`:

```gdscript
	# Border tiling matches the hilly terrain's checker density.
	var border_size: Vector2 = ($Border/MeshInstance3D.mesh as PlaneMesh).size
	($Border/MeshInstance3D.material_override as ShaderMaterial).set_shader_parameter(
		"texture_tile", border_size * cfg.terrain_tile_per_meter)
```

Everything else in `world.gd` (`_layers_match`, car wiring, fog) stays.

- [ ] **Step 4: Delete the obsolete script**

```bash
rm scripts/terrain.gd
```

(`terrain_layer.gd` stays — still used by both new files.)

- [ ] **Step 5: Run the full suite**

Run: `./run_tests.sh` in the background.
Expected: smoke + gameplay green except `test_smoke.gd::test_floor_is_static_body` and `test_terrain.gd::test_car_spawns_just_above_terrain`, fixed in Task 4. Confirm no parse errors (no dangling `terrain.gd` / `Border` references).

---

## Task 4: Fix smoke + spawn tests, update docs

**Files:**
- Modify: `tests/headless/test_smoke.gd`
- Modify: `tests/headless/test_terrain.gd` (`test_car_spawns_just_above_terrain`)
- Modify: `features/terrain.md`

- [ ] **Step 1: Update `test_smoke.gd::test_floor_is_static_body`**

`Floor` is now the manager `Node3D`; chunks are the static bodies. Replace the test:

```gdscript
func test_floor_is_terrain_manager() -> void:
	var floor_node := _scene.get_node("Floor")
	assert_not_null(floor_node as Node3D, "Floor is the TerrainManager node")
	assert_true(floor_node.has_method("height_at"), "manager exposes height_at")
	assert_gt(floor_node.loaded_coords().size(), 0, "chunks loaded around the car at boot")
```

If `test_smoke.gd` asserts the absence/presence of `Border` anywhere else, remove those assertions (grep the file for `Border`).

- [ ] **Step 2: Fix `test_car_spawns_just_above_terrain` in `test_terrain.gd`**

`floor_node` is now the manager — `height_at` still works. The material assertion must target a chunk's mesh instead of `Floor/MeshInstance3D`:

```gdscript
func test_car_spawns_just_above_terrain() -> void:
	var scene: Node3D = load("res://main.tscn").instantiate()
	add_child_autofree(scene)
	var car := scene.get_node("Car") as VehicleBody3D
	var floor_node := scene.get_node("Floor")
	var expected: float = (
		floor_node.height_at(car.global_position.x, car.global_position.z)
		+ Config.data.spawn_clearance
	)
	assert_almost_eq(car.global_position.y, expected, 0.01,
		"car lifted to terrain height + spawn_clearance at spawn")

	# Chunk meshes must use node-level material_override: surface_material_override/0
	# silently fails to load when the mesh is assigned at runtime (no surfaces yet).
	var center := floor_node.chunk_coord_for(car.global_position)
	var chunk = floor_node._chunks[center]
	var mi: MeshInstance3D = chunk.get_node("MeshInstance3D")
	assert_not_null(mi.material_override, "chunk material survives runtime mesh assignment")
```

- [ ] **Step 3: Run the full suite, expect all PASS**

Run: `./run_tests.sh` in the background.
Expected: every test passes.

- [ ] **Step 4: Rewrite `features/terrain.md`**

Replace the dimensions/source/boundary sections to describe the chunked model:
- Source: `scripts/terrain_manager.gd` (`TerrainManager`) + `scripts/terrain_chunk.gd` (`TerrainChunk`) + `terrain_layer.gd`.
- Constants: `CHUNK_M = 100`, `CELL_M = 0.5`, `SAMPLES = 201`, `RADIUS = 1` (3×3).
- Generation: manager owns noise + `height_at()` + `build_heights()`; chunks centre on their tile and build mesh + `HeightMapShape3D`; UVs use world coords for seamless texturing.
- Lifecycle: `_process` reads the car (`focus_path`), `update_focus` reconciles the 3×3 ring (`chunk_coord_for`, `target_coords`, `_reconcile`), rebuilding only on chunk crossings.
- Note the **Border node is removed** (infinite chunks always have ground under the car).
- Note the fog caveat: far chunk edge is 100–200 m out; if chunks pop in, tune `fog_density` in `config/game_config.tres`.
- Update the Tests section to list the seam + load/unload tests.

Also update the one-line entry in `features/README.md` if it describes terrain dimensions.

- [ ] **Step 5: Final checkpoint** — full `./run_tests.sh` green; `features/terrain.md` matches the code.

---

## Self-Review

- **Spec coverage:** follow-car load trigger (Task 2 `_process`/`update_focus`) ✓; 100 m / 3×3 / 0.5 m (Task 1 constants) ✓; Border removed (Task 3) ✓; manager owns `height_at` (Task 1) ✓; runtime chunks + editor-origin preview (Task 2 `_ready`) ✓; seam + load/unload tests (Task 2) ✓; smoke/spawn/doc updates (Task 4) ✓; synchronous build (no threading added) ✓; fog caveat documented (Task 4) ✓.
- **Type consistency:** `TerrainManager` API used consistently — `CHUNK_M`/`CELL_M`/`SAMPLES`/`RADIUS`, `height_at`, `build_heights(center)`, `chunk_coord_for`, `target_coords`, `loaded_coords`, `_chunks`, `update_focus`, `_reconcile`, `_rebuild_loaded`, `chunk_material`, `focus_path`. `TerrainChunk` API: `coord`, `setup(manager, coord)`, `build(manager)`. Names match across Tasks 1–4.
- **Placeholder scan:** `_rebuild_loaded` is an intentional, labelled placeholder in Task 1 filled in Task 2; no other TBDs. All code steps show full code.
- **Note:** git "commit" steps are intentionally omitted (project not under git); checkpoints use `./run_tests.sh` instead.
