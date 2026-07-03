# Perlin Noise Terrain Floor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the flat BoxMesh floor with a 200×200m terrain mesh on a 0.5m grid, heights from stacked Perlin noise layers, with matching HeightMapShape3D collision.

**Architecture:** A `@tool` script `scripts/terrain.gd` on the existing `Floor` StaticBody3D generates the height field (sum of exported FastNoiseLite layers), builds an ArrayMesh via SurfaceTool for the child MeshInstance3D, and a HeightMapShape3D for the child CollisionShape3D. The car spawn is raised to terrain height + clearance.

**Tech Stack:** Godot 4, GDScript, FastNoiseLite, SurfaceTool, HeightMapShape3D.

**Notes:** This project is NOT a git repository — skip all commit steps. Tests deliberately out of scope (user request).

---

### Task 1: Terrain generator script

**Files:**
- Create: `scripts/terrain.gd`

- [ ] **Step 1: Write the script**

```gdscript
@tool
extends StaticBody3D

# Terrain dimensions: 200x200m at 0.5m cells -> 401x401 height samples.
const SIZE_M := 200.0
const CELL_M := 0.5
const SAMPLES := int(SIZE_M / CELL_M) + 1  # 401

@export var noise_seed: int = 1337:
	set(value):
		noise_seed = value
		_regenerate()

# Each layer: a FastNoiseLite (frequency = 1 / wavelength) and a height amplitude in metres.
# Add a new entry here (or in the Inspector) to stack another frequency.
@export var layers: Array[TerrainLayer] = []:
	set(value):
		layers = value
		_regenerate()

@export var texture_tile_per_meter: float = 0.125  # matches old 25 tiles / 200m


class TerrainLayer:
	extends Resource
	@export var wavelength_m: float = 60.0
	@export var amplitude_m: float = 1.5


func _ready() -> void:
	if layers.is_empty():
		layers = _default_layers()
	else:
		_regenerate()


func _default_layers() -> Array[TerrainLayer]:
	var result: Array[TerrainLayer] = []
	for params in [[60.0, 1.5], [15.0, 0.4], [3.0, 0.1]]:
		var layer := TerrainLayer.new()
		layer.wavelength_m = params[0]
		layer.amplitude_m = params[1]
		result.append(layer)
	return result


func height_at(x: float, z: float) -> float:
	var h := 0.0
	for i in layers.size():
		var layer := layers[i]
		var noise := FastNoiseLite.new()
		noise.noise_type = FastNoiseLite.TYPE_PERLIN
		noise.fractal_type = FastNoiseLite.FRACTAL_NONE
		noise.seed = noise_seed + i
		noise.frequency = 1.0 / layer.wavelength_m
		h += noise.get_noise_2d(x, z) * layer.amplitude_m
	return h


func _regenerate() -> void:
	if not is_inside_tree():
		return
	var heights := _build_heights()
	_build_mesh(heights)
	_build_collision(heights)


func _build_heights() -> PackedFloat32Array:
	# Pre-create noises once (height_at recreates per call; fine for single samples,
	# too slow for 160k samples).
	var noises: Array[FastNoiseLite] = []
	for i in layers.size():
		var noise := FastNoiseLite.new()
		noise.noise_type = FastNoiseLite.TYPE_PERLIN
		noise.fractal_type = FastNoiseLite.FRACTAL_NONE
		noise.seed = noise_seed + i
		noise.frequency = 1.0 / layers[i].wavelength_m
		noises.append(noise)

	var heights := PackedFloat32Array()
	heights.resize(SAMPLES * SAMPLES)
	var half := SIZE_M / 2.0
	for zi in SAMPLES:
		var z := -half + zi * CELL_M
		for xi in SAMPLES:
			var x := -half + xi * CELL_M
			var h := 0.0
			for i in layers.size():
				h += noises[i].get_noise_2d(x, z) * layers[i].amplitude_m
			heights[zi * SAMPLES + xi] = h
	return heights


func _build_mesh(heights: PackedFloat32Array) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half := SIZE_M / 2.0
	for zi in SAMPLES:
		for xi in SAMPLES:
			var x := -half + xi * CELL_M
			var z := -half + zi * CELL_M
			st.set_uv(Vector2(x, z) * texture_tile_per_meter)
			st.add_vertex(Vector3(x, heights[zi * SAMPLES + xi], z))
	for zi in SAMPLES - 1:
		for xi in SAMPLES - 1:
			var a := zi * SAMPLES + xi
			var b := a + 1
			var c := a + SAMPLES
			var d := c + 1
			st.add_index(a); st.add_index(c); st.add_index(b)
			st.add_index(b); st.add_index(c); st.add_index(d)
	st.generate_normals()
	var mesh_instance: MeshInstance3D = $MeshInstance3D
	mesh_instance.mesh = st.commit()


func _build_collision(heights: PackedFloat32Array) -> void:
	var shape := HeightMapShape3D.new()
	shape.map_width = SAMPLES
	shape.map_depth = SAMPLES
	shape.map_data = heights
	var col: CollisionShape3D = $CollisionShape3D
	col.shape = shape
	# HeightMapShape3D spans (SAMPLES-1) cells of 1 unit; scale cells to 0.5m.
	col.scale = Vector3(CELL_M, 1.0, CELL_M)
```

**Important implementation details for the engineer:**
- `HeightMapShape3D` places samples 1 unit apart in local space, centered on the node — scaling the CollisionShape3D by `CELL_M` on x/z makes it span the same 200m as the mesh. Do NOT scale y.
- UVs: the old material tiled the checker 25× over 200m via `shader_parameter/texture_tile=Vector2(25, 25)` with BoxMesh's 0–1 UVs. With world-coordinate UVs (`texture_tile_per_meter = 0.125` → 25 repeats per 200m), the shader's tile parameter must become `Vector2(1, 1)` (Task 2).
- Inner `class TerrainLayer` extending Resource exports fine in Godot 4; if the Inspector won't create entries, move it to its own file `scripts/terrain_layer.gd` with `class_name TerrainLayer`.

- [ ] **Step 2: Syntax-check the script**

Run: `godot --headless --check-only --script scripts/terrain.gd --path .` (if `godot` is on PATH; otherwise rely on the editor in Task 4)
Expected: no script errors.

### Task 2: Scene changes in main.tscn

**Files:**
- Modify: `main.tscn`

- [ ] **Step 1: Register the script as an ext_resource**

Add after line 7 (`id="5_cam"` ext_resource):

```
[ext_resource type="Script" path="res://scripts/terrain.gd" id="6_terrain"]
```

Bump the header's `load_steps` count accordingly (it must equal total resources + 1; removing the two floor sub-resources below and adding one ext_resource means `load_steps=17`).

- [ ] **Step 2: Update the floor material tiling**

Change `shader_parameter/texture_tile=Vector2(25, 25)` to `Vector2(1, 1)` in the `mat_floor` sub-resource (UVs are now in tiled world units already).

- [ ] **Step 3: Remove the box floor sub-resources**

Delete these blocks:

```
[sub_resource type="BoxMesh" id="mesh_floor"]
size=Vector3(200, 1, 200)

[sub_resource type="BoxShape3D" id="shape_floor"]
size=Vector3(200, 1, 200)
```

- [ ] **Step 4: Update the Floor node**

Replace the Floor node section with (note: no y-offset, script attached, mesh/shape now assigned at runtime):

```
[node name="Floor" type="StaticBody3D" parent="."]
script=ExtResource("6_terrain")

[node name="MeshInstance3D" type="MeshInstance3D" parent="Floor"]
surface_material_override/0=SubResource("mat_floor")

[node name="CollisionShape3D" type="CollisionShape3D" parent="Floor"]
```

### Task 3: Car spawn height

**Files:**
- Modify: `main.tscn` (Car node transform) or `scripts/car.gd`

- [ ] **Step 1: Raise spawn clearance**

The terrain max height at origin can reach ~2m. Simplest robust fix: in `scripts/car.gd` `_ready()`, sample the floor and lift the car:

```gdscript
func _ready() -> void:
	var floor_node := get_node_or_null("../Floor")
	if floor_node and floor_node.has_method("height_at"):
		global_position.y = floor_node.height_at(global_position.x, global_position.z) + 1.0
```

(Append to existing `_ready` if one exists; otherwise add it.)

### Task 4: Verify in Godot

- [ ] **Step 1: Run the game**

Run: `godot --path .` (or open in the editor and press F5)
Expected: rolling terrain with checker texture, car drops onto it and drives; no script errors in the output.

- [ ] **Step 2: Sanity-check drivability**

Drive around briefly: car should not fall through the floor (collision matches visuals) and should handle slopes without flipping.

---

## Self-review notes

- Spec coverage: height field ✓ (Task 1), mesh+normals+UVs ✓ (Task 1), HeightMapShape3D ✓ (Task 1), layer defaults 60/15/3m ✓, scene changes ✓ (Task 2), car spawn ✓ (Task 3). Tests intentionally omitted per spec.
- No placeholders; all code shown in full.
