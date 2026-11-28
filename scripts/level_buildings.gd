class_name LevelBuildings
extends Node3D
# Docs: features/buildings.md — update in the same change as this file.
# Tests: tests/headless/test_level_buildings.gd — extend in the same change.
## The level's houses, barns, huts and shops: meshes baked by tools/bake_buildings.js into <level>.buildings.json,
## textured from one shared atlas, each with a box collider over its footprint. They are all drawn as one merged mesh
## (`mesh`, a single draw call), each one's vertices placed where its body stands. Start line variants are baked in too but
## are not part of that mesh: `LevelRallies` shows only the active rally's, each as its own one-surface mesh on the same material.

const ATLAS := "res://tools/levels/buildings_atlas.png"
const MIN_SOLID_Y := 0.3  # start line triangles lower than this get no collision

var footprint_points := PackedVector2Array()  # points round each building's footprint, for crowds to steer clear of

var boxes: Array[Dictionary] = []  # each building's footprint: {centre, axis (unit, along its length), half}
var shops: Dictionary = {}  # level shop index -> {body, box}: each shop's body (its sign Label3Ds too) and baked building box
var start_lines: Dictionary = {}  # variant seed -> {mesh, shape, texts}: a start line at its own origin, ready to place
var material: ShaderMaterial  # the buildings' look, shared by every mesh built from the bake
var mesh: MeshInstance3D  # every building's geometry, in this node's space
# The merged mesh's arrays as the buildings are gathered.
var _verts := PackedVector3Array()
var _normals := PackedVector3Array()
var _uvs := PackedVector2Array()
var _cols := PackedColorArray()


## Builds every building in the bake next to `save_path`, seated on the ground's lowest point under its footprint.
func setup(save_path: String, height_at: Callable) -> void:
	var t_read := Time.get_ticks_msec()
	var list := _read(save_path.get_basename() + ".buildings")
	LevelView.load_ms["buildings_read"] = Time.get_ticks_msec() - t_read
	if list.is_empty():
		return
	var mat := ShaderMaterial.new()
	material = mat
	mat.shader = load("res://shaders/level_prop.gdshader")
	mat.set_shader_parameter("albedo_texture", load(ATLAS))
	mat.set_shader_parameter("alpha_scissor", 0.5)
	for b: Dictionary in list:
		match String(b.get("kind", "")):
			"shop":
				add_child(_shop(b, height_at))
			"start_line":
				start_lines[int(b.seed)] = _start_line(b, mat)
			_:
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


# The bake's entries: from the `.bin` sidecar if there is one, else from `.json` (entries then hold plain Arrays, not packed ones).
static func _read(base: String) -> Array:
	if FileAccess.file_exists(base + ".bin"):
		return parse_bin(FileAccess.get_file_as_bytes(base + ".bin"))
	if FileAccess.file_exists(base + ".json"):
		var list: Variant = JSON.parse_string(FileAccess.get_file_as_string(base + ".json"))
		if list is Array:
			return list
		push_error("LevelBuildings: can't read %s.json" % base)
	return []


# Layout (see tools/bake_buildings.js): u32 header length, JSON header of each entry's fields plus `np` (its float count),
# then every entry's p, n, uv, c as float32. The floats are decoded in one call and sliced per entry.
static func parse_bin(bytes: PackedByteArray) -> Array:
	var head_end := 4 + bytes.decode_u32(0)
	var list: Variant = JSON.parse_string(bytes.slice(4, head_end).get_string_from_utf8())
	if not list is Array:
		push_error("LevelBuildings: bad building bake")
		return []
	var floats := bytes.slice(head_end).to_float32_array()
	var at := 0
	for b: Dictionary in list:
		var np := int(b.np)
		var nuv := int(np / 3.0) * 2
		b["p"] = floats.slice(at, at + np)
		b["n"] = floats.slice(at + np, at + np * 2)
		b["uv"] = floats.slice(at + np * 2, at + np * 2 + nuv)
		b["c"] = floats.slice(at + np * 2 + nuv, at + np * 3 + nuv)
		at += np * 3 + nuv
	return list


# A baked entry's triangles for Godot: winding and V flipped (three.js winds front faces counter-clockwise and counts
# V from the bottom), darkened toward the ground. `height` is the tallest vertex.
static func _convert(b: Dictionary) -> Dictionary:
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
	for t in range(0, int(p.size() / 3.0), 3):
		for k in [t, t + 2, t + 1]:
			verts.append(Vector3(p[k * 3], p[k * 3 + 1], p[k * 3 + 2]))
			normals.append(Vector3(n[k * 3], n[k * 3 + 1], n[k * 3 + 2]))
			uvs.append(Vector2(uv[k * 2], 1.0 - uv[k * 2 + 1]))
			var shade := 1.0 - dark * (1.0 - smoothstep(0.0, reach, p[k * 3 + 1]))
			cols.append(Color(c[k * 3] * shade, c[k * 3 + 1] * shade, c[k * 3 + 2] * shade))
			height = maxf(height, p[k * 3 + 1])
	return {"verts": verts, "normals": normals, "uvs": uvs, "cols": cols, "height": height}


# A start line variant as a mesh of its own plus one solid shape from every triangle standing above the road, so arches,
# tents and tape are solid while flat road paint and mats snag no wheel.
func _start_line(b: Dictionary, mat: ShaderMaterial) -> Dictionary:
	var geo := _convert(b)
	var verts: PackedVector3Array = geo.verts
	var faces := PackedVector3Array()
	for t in range(0, verts.size(), 3):
		if maxf(verts[t].y, maxf(verts[t + 1].y, verts[t + 2].y)) > MIN_SOLID_Y:
			faces.append_array(verts.slice(t, t + 3))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = geo.normals
	arrays[Mesh.ARRAY_TEX_UV] = geo.uvs
	arrays[Mesh.ARRAY_COLOR] = geo.cols
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	am.surface_set_material(0, mat)
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	return {"mesh": am, "shape": shape, "texts": b.get("texts", [])}


func _append(geo: Dictionary, xf: Transform3D) -> void:
	_verts.append_array(xf * (geo.verts as PackedVector3Array))
	_normals.append_array(Transform3D(xf.basis, Vector3.ZERO) * (geo.normals as PackedVector3Array))
	_uvs.append_array(geo.uvs)
	_cols.append_array(geo.cols)


func _building(b: Dictionary, height_at: Callable) -> StaticBody3D:
	var geo := _convert(b)
	var height: float = geo.height
	var rot: float = b.rot
	var length: float = b.L
	var wid: float = b.W
	var x: float = b.x
	var z: float = b.z
	var ground := INF
	for corner in [Vector2.ZERO, Vector2(1, 1), Vector2(1, -1), Vector2(-1, 1), Vector2(-1, -1)]:
		var off := Vector2(corner.x * length / 2, corner.y * wid / 2).rotated(rot)
		ground = minf(ground, height_at.call(x + off.x, z + off.y))
	var half := Vector2(length, wid) / 2.0
	boxes.append({"centre": Vector2(x, z), "axis": Vector2.RIGHT.rotated(rot), "half": half})
	for k in range(-int(half.x), int(half.x) + 1):
		for sy in [-half.y, half.y]:
			footprint_points.append(Vector2(x, z) + Vector2(k, sy).rotated(rot))
	for k in range(-int(half.y), int(half.y) + 1):
		for sx in [-half.x, half.x]:
			footprint_points.append(Vector2(x, z) + Vector2(sx, k).rotated(rot))
	var body := StaticBody3D.new()
	body.transform = Transform3D(Basis(Vector3.UP, -rot), Vector3(x, ground - 0.1, z))
	_append(geo, body.transform)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(length, height, wid)
	shape.shape = box
	shape.position.y = height / 2
	body.add_child(shape)
	return body


# A shop stands on the ground at its origin (so its yard sits level with the gravel patch), front (+z) facing the road, with
# a box collider over the building only; the yard, fence and props have none. Its sign text is drawn by the game in its font.
func _shop(b: Dictionary, height_at: Callable) -> StaticBody3D:
	var geo := _convert(b)
	var x: float = b.x
	var z: float = b.z
	var yaw: float = b.yaw
	var box: Array = b.box
	var body := StaticBody3D.new()
	body.transform = Transform3D(Basis(Vector3.UP, yaw), Vector3(x, height_at.call(x, z), z))
	_append(geo, body.transform)
	for t: Dictionary in b.texts:
		body.add_child(text_label(t))
	var shape := CollisionShape3D.new()
	var shape_box := BoxShape3D.new()
	shape_box.size = Vector3(box[1] - box[0], box[4], box[3] - box[2])
	shape.shape = shape_box
	shape.position = Vector3((box[0] + box[1]) * 0.5, box[4] * 0.5, (box[2] + box[3]) * 0.5)
	body.add_child(shape)
	boxes.append(LevelView.shop_box({"x": x, "z": z, "yaw": yaw, "box": box}))
	shops[int(b.shop)] = {"body": body, "box": box}
	return body


# One piece of baked sign text (a shop's sign, a start line's banner) drawn in the game's font rather than baked into the atlas:
# `p` and `q` place it in the model (facing its +z), `w` x `h` metres is the room it fits in.
static func text_label(t: Dictionary) -> Label3D:
	var l := Label3D.new()
	l.text = String(t.get("text", ""))
	l.font = load(UITheme.FONT_PATH)
	l.font_size = UITheme.FONT_SIZE * 2
	l.outline_size = 0
	l.modulate = Color(String(t.get("color", "#ffffff")))
	l.shaded = false
	l.double_sided = false
	l.alpha_cut = Label3D.ALPHA_CUT_DISCARD
	l.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	var p: Array = t.get("p", [0, 0, 0])
	var q: Array = t.get("q", [0, 0, 0, 1])
	l.transform = Transform3D(Basis(Quaternion(q[0], q[1], q[2], q[3])), Vector3(p[0], p[1], p[2]))
	var em := l.font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, l.font_size)  # the text's size in font pixels
	l.pixel_size = minf(float(t.get("h", 0.2)) / maxf(em.y, 1.0), float(t.get("w", 1.0)) / maxf(em.x, 1.0))
	return l
