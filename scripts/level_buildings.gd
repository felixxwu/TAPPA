class_name LevelBuildings
extends Node3D
## The level's houses, barns and huts: meshes baked by tools/bake_buildings.js into <level>.buildings.json,
## textured from one shared atlas, each with a box collider over its footprint. They are all drawn as one merged mesh
## (`mesh`, a single draw call; about 11k vertices for Hafren's 68), each building's vertices placed where its body stands.

const ATLAS := "res://tools/levels/buildings_atlas.png"

var footprint_points := PackedVector2Array()  # points round each building's footprint, for crowds to steer clear of

var boxes: Array[Dictionary] = []  # each building's footprint: {centre, axis (unit, along its length), half}
var mesh: MeshInstance3D  # every building's geometry, in this node's space
# The merged mesh's arrays as the buildings are gathered.
var _verts := PackedVector3Array()
var _normals := PackedVector3Array()
var _uvs := PackedVector2Array()
var _cols := PackedColorArray()


## Builds every building in the bake next to `save_path`, seated on the ground's lowest point under its footprint.
func setup(save_path: String, height_at: Callable) -> void:
	var path := save_path.get_basename() + ".buildings.json"
	if not FileAccess.file_exists(path):
		return
	var list: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not list is Array:
		push_error("LevelBuildings: can't read %s" % path)
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = load(ATLAS)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	mat.texture_repeat = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	for b: Dictionary in list:
		add_child(_building(b, height_at))
	if _verts.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _verts
	arrays[Mesh.ARRAY_NORMAL] = _normals
	arrays[Mesh.ARRAY_TEX_UV] = _uvs
	arrays[Mesh.ARRAY_COLOR] = _cols
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	am.surface_set_material(0, mat)
	mesh = MeshInstance3D.new()
	mesh.name = "Mesh"
	mesh.mesh = am
	add_child(mesh)
	_verts = PackedVector3Array()
	_normals = PackedVector3Array()
	_uvs = PackedVector2Array()
	_cols = PackedColorArray()


func _building(b: Dictionary, height_at: Callable) -> StaticBody3D:
	var p: Array = b.p
	var n: Array = b.n
	var uv: Array = b.uv
	var c: Array = b.c
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var height := 0.0
	var dark: float = Config.data.level_ao_building_base
	var reach: float = maxf(Config.data.level_ao_building_base_height_m, 0.01)
	# three.js winds front faces counter-clockwise and counts texture V from the bottom; Godot does the opposite of both.
	for t in range(0, p.size() / 3, 3):
		for k in [t, t + 2, t + 1]:
			verts.append(Vector3(p[k * 3], p[k * 3 + 1], p[k * 3 + 2]))
			normals.append(Vector3(n[k * 3], n[k * 3 + 1], n[k * 3 + 2]))
			uvs.append(Vector2(uv[k * 2], 1.0 - uv[k * 2 + 1]))
			var shade := 1.0 - dark * (1.0 - smoothstep(0.0, reach, p[k * 3 + 1]))
			cols.append(Color(c[k * 3] * shade, c[k * 3 + 1] * shade, c[k * 3 + 2] * shade))
			height = maxf(height, p[k * 3 + 1])
	var rot: float = b.rot
	var len: float = b.L
	var wid: float = b.W
	var x: float = b.x
	var z: float = b.z
	var ground := INF
	for corner in [Vector2.ZERO, Vector2(1, 1), Vector2(1, -1), Vector2(-1, 1), Vector2(-1, -1)]:
		var off := Vector2(corner.x * len / 2, corner.y * wid / 2).rotated(rot)
		ground = minf(ground, height_at.call(x + off.x, z + off.y))
	var half := Vector2(len, wid) / 2.0
	boxes.append({"centre": Vector2(x, z), "axis": Vector2.RIGHT.rotated(rot), "half": half})
	for k in range(-int(half.x), int(half.x) + 1):
		for sy in [-half.y, half.y]:
			footprint_points.append(Vector2(x, z) + Vector2(k, sy).rotated(rot))
	for k in range(-int(half.y), int(half.y) + 1):
		for sx in [-half.x, half.x]:
			footprint_points.append(Vector2(x, z) + Vector2(sx, k).rotated(rot))
	var body := StaticBody3D.new()
	body.transform = Transform3D(Basis(Vector3.UP, -rot), Vector3(x, ground - 0.1, z))
	_verts.append_array(body.transform * verts)
	_normals.append_array(Transform3D(body.transform.basis, Vector3.ZERO) * normals)
	_uvs.append_array(uvs)
	_cols.append_array(cols)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(len, height, wid)
	shape.shape = box
	shape.position.y = height / 2
	body.add_child(shape)
	return body
