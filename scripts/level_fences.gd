class_name LevelFences
extends Node3D
## The level's stock fences and hawthorn hedges from the save's `fences`: merged into one mesh per 250 m chunk, with thin box colliders.
## Their shapes are mirrored by the lab (tools/level_editor_lab.html). Spans near a road are left out so the road stays clear.
# Docs: features/level-editor.md — update in the same change as this file.
# Tests: tests/headless/test_level_fences.gd — extend in the same change.

const CHUNK_M := 250.0
const POST_STEP := 2.5
const ROAD_CLEAR_M := 0.75
const HEDGE_STEP := 1.0
const NET_CELL_M := 40.0
const NET_DRAW_M := 60.0
const POST_COL := Color(0.42, 0.36, 0.28)
const NET_COL := Color(0.36, 0.37, 0.36)
const HEDGE_LOW := Color(0.12, 0.19, 0.08)
const HEDGE_MID := Color(0.20, 0.30, 0.14)
const HEDGE_HIGH := Color(0.32, 0.46, 0.20)

var meshes: Array[MeshInstance3D] = []
var bodies: Array[StaticBody3D] = []
var _chunks := {}  # Vector2i -> {"solid": surface, "shapes": [[centre, size, yaw]]}
var _nets := {}  # Vector2i (40 m cell) -> surface of netting and wire
var _data: LevelData
var _height: Callable


## Builds every fence and hedge in `fences` ({kind, pts}), standing on `height_at` and clear of `data`'s roads.
func setup(fences: Array, data: LevelData, height_at: Callable) -> void:
	_data = data
	_height = height_at
	for f: Dictionary in fences:
		var pts := PackedVector2Array()
		for p: Array in f.get("pts", []):
			pts.append(Vector2(float(p[0]), float(p[1])))
		if pts.size() < 2:
			continue
		if f.get("kind", "fence") == "hedge":
			_hedge(pts)
		else:
			_fence(pts)
	var mats := _materials()
	var range_end: float = Config.data.level_fence_draw_m + CHUNK_M * 0.71
	for key: Vector2i in _chunks:
		_add_mesh("Mesh%d_%d" % [key.x, key.y], _chunks[key].solid, mats.solid, range_end)
	for key: Vector2i in _nets:
		_add_mesh("Net%d_%d" % [key.x, key.y], _nets[key], mats.net, NET_DRAW_M + NET_CELL_M * 0.71)
	for key: Vector2i in _chunks:
		var c: Dictionary = _chunks[key]
		var body := StaticBody3D.new()
		body.name = "Body%d_%d" % [key.x, key.y]
		for sh: Array in c.shapes:
			var cs := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = sh[1]
			cs.shape = box
			cs.transform = Transform3D(Basis(Vector3.UP, sh[2]), sh[0])
			body.add_child(cs)
		add_child(body)
		bodies.append(body)
	_chunks.clear()
	_nets.clear()


func _add_mesh(mesh_name: String, s: Dictionary, mat: Material, range_end: float) -> void:
	if s.v.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = s.v
	arrays[Mesh.ARRAY_NORMAL] = s.n
	arrays[Mesh.ARRAY_TEX_UV] = s.uv
	arrays[Mesh.ARRAY_COLOR] = s.c
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	am.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.name = mesh_name
	mi.mesh = am
	mi.visibility_range_end = range_end
	mi.visibility_range_end_margin = Config.data.level_tree_fade_m
	mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(mi)
	meshes.append(mi)


func _net(a: Vector2, b: Vector2) -> Dictionary:
	var m := (a + b) / 2.0
	var key := Vector2i(floori(m.x / NET_CELL_M), floori(m.y / NET_CELL_M))
	if not _nets.has(key):
		_nets[key] = _surface()
	return _nets[key]


func _clear(p: Vector2) -> bool:
	var n := _data.nearest(p.x, p.y)
	return n.x > n.z + ROAD_CLEAR_M


func _span_clear(a: Vector2, b: Vector2) -> bool:
	return _clear(a) and _clear(b) and _clear((a + b) / 2.0)


func _chunk(p: Vector2) -> Dictionary:
	var key := Vector2i(floori(p.x / CHUNK_M), floori(p.y / CHUNK_M))
	if not _chunks.has(key):
		_chunks[key] = {"solid": _surface(), "shapes": []}
	return _chunks[key]


static func _surface() -> Dictionary:
	return {"v": PackedVector3Array(), "n": PackedVector3Array(), "uv": PackedVector2Array(), "c": PackedColorArray()}


static func _quad(s: Dictionary, a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color, uvs := [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]) -> void:
	var n := (b - a).cross(d - a).normalized()
	for k in [0, 1, 2, 0, 2, 3]:
		s.v.append([a, b, c, d][k])
		s.n.append(n)
		s.uv.append(uvs[k])
		s.c.append(col)


static func _hash(x: float, z: float) -> float:
	return fposmod(sin(x * 12.9898 + z * 78.233) * 43758.5453, 1.0)


static func _shade(col: Color, k: float) -> Color:
	return Color(col.r * k, col.g * k, col.b * k)


func _post(c: Dictionary, p: Vector2, end: bool) -> void:
	var half := 0.08 if end else 0.05
	var top := 1.2 if end else 1.05
	var y: float = _height.call(p.x, p.y) - 0.1
	var col := _shade(POST_COL, 0.9 + 0.2 * _hash(p.x, p.y))
	var x0 := p.x - half
	var x1 := p.x + half
	var z0 := p.y - half
	var z1 := p.y + half
	var yt: float = y + top + 0.1
	var s: Dictionary = c.solid
	_quad(s, Vector3(x0, y, z1), Vector3(x1, y, z1), Vector3(x1, yt, z1), Vector3(x0, yt, z1), col)
	_quad(s, Vector3(x1, y, z0), Vector3(x0, y, z0), Vector3(x0, yt, z0), Vector3(x1, yt, z0), col)
	_quad(s, Vector3(x0, y, z0), Vector3(x0, y, z1), Vector3(x0, yt, z1), Vector3(x0, yt, z0), col)
	_quad(s, Vector3(x1, y, z1), Vector3(x1, y, z0), Vector3(x1, yt, z0), Vector3(x1, yt, z1), col)
	_quad(s, Vector3(x0, yt, z1), Vector3(x1, yt, z1), Vector3(x1, yt, z0), Vector3(x0, yt, z0), col)


func _fence(pts: PackedVector2Array) -> void:
	var posts: Array[Vector2] = []
	var vertex: Array[bool] = []
	for i in pts.size() - 1:
		var n := ceili(pts[i].distance_to(pts[i + 1]) / POST_STEP)
		for k in n:
			posts.append(pts[i].lerp(pts[i + 1], float(k) / n))
			vertex.append(k == 0)
	posts.append(pts[-1])
	vertex.append(true)
	var drawn: Array[bool] = []
	for i in posts.size() - 1:
		drawn.append(_span_clear(posts[i], posts[i + 1]))
	for i in posts.size():
		var before := i > 0 and drawn[i - 1]
		var after := i < drawn.size() and drawn[i]
		if not _clear(posts[i]) or not (before or after or vertex[i]):
			continue
		_post(_chunk(posts[i]), posts[i], vertex[i] or not (before and after))
	for i in drawn.size():
		if not drawn[i]:
			continue
		var a := posts[i]
		var b := posts[i + 1]
		var c := _chunk((a + b) / 2.0)
		var ya: float = _height.call(a.x, a.y)
		var yb: float = _height.call(b.x, b.y)
		var u := a.distance_to(b) / 0.15
		var uv := [Vector2(0, 1), Vector2(u, 1), Vector2(u, 0), Vector2(0, 0)]
		_quad(_net(a, b), Vector3(a.x, ya + 0.05, a.y), Vector3(b.x, yb + 0.05, b.y), Vector3(b.x, yb + 0.85, b.y), Vector3(a.x, ya + 0.85, a.y), NET_COL, uv)
		var wv := Vector2(0, 0.996)
		_quad(_net(a, b), Vector3(a.x, ya + 1.0, a.y), Vector3(b.x, yb + 1.0, b.y), Vector3(b.x, yb + 1.02, b.y), Vector3(a.x, ya + 1.02, a.y), NET_COL, [wv, wv, wv, wv])
		_shape(c, a, b, 0.1, 1.05, (ya + yb) / 2.0)


func _shape(c: Dictionary, a: Vector2, b: Vector2, width: float, height: float, ground: float) -> void:
	var mid := (a + b) / 2.0
	var d := b - a
	c.shapes.append([Vector3(mid.x, ground + height / 2.0 - 0.1, mid.y), Vector3(d.length(), height, width), -atan2(d.y, d.x)])


func _hedge(pts: PackedVector2Array) -> void:
	var line: Array[Vector2] = []
	for i in pts.size() - 1:
		var n := ceili(pts[i].distance_to(pts[i + 1]) / HEDGE_STEP)
		for k in n:
			line.append(pts[i].lerp(pts[i + 1], float(k) / n))
	line.append(pts[-1])
	var rings: Array = []  # per vertex: 7 points round the cross-section, left base to right base over the ragged top
	var cols := [HEDGE_LOW, HEDGE_MID, HEDGE_HIGH, HEDGE_HIGH, HEDGE_HIGH, HEDGE_MID, HEDGE_LOW]
	for i in line.size():
		var dir := (line[mini(i + 1, line.size() - 1)] - line[maxi(i - 1, 0)]).normalized()
		var side := dir.orthogonal()
		var p := line[i]
		var sx := snappedf(p.x, 0.1)
		var sz := snappedf(p.y, 0.1)
		var h := _hash(sx, sz)
		var y: float = _height.call(p.x, p.y) - 0.1
		var height := 1.7 + (h - 0.5) * 0.5
		var wide := (h - 0.5) * 0.3
		var bulge_l := (_hash(sx + 1.0, sz) - 0.5) * 0.5
		var bulge_r := (_hash(sx, sz + 1.0) - 0.5) * 0.5
		var tl := (_hash(sx + 2.0, sz) - 0.5) * 0.5
		var tc := (_hash(sx, sz + 2.0) - 0.5) * 0.6
		var t_right := (_hash(sx + 3.0, sz) - 0.5) * 0.5
		var offs := [[0.7 + wide, 0.0], [0.62 + wide * 0.8 + bulge_l, height * 0.5], [0.45 + wide * 0.6, height + tl * 0.5],
			[0.0, height + 0.15 + tc * 0.5], [-0.45 - wide * 0.6, height + t_right * 0.5], [-0.62 - wide * 0.8 - bulge_r, height * 0.5], [-0.7 - wide, 0.0]]
		var ring := []
		for j in 7:
			var o := side * float(offs[j][0])
			ring.append([Vector3(p.x + o.x, y + float(offs[j][1]), p.y + o.y), _shade(cols[j], 1.0 + (h - 0.5) * 0.16)])
		rings.append(ring)
	for i in line.size() - 1:
		if not _span_clear(line[i], line[i + 1]):
			continue
		var c := _chunk((line[i] + line[i + 1]) / 2.0)
		var u0 := float(i)
		for j in 6:
			var a0: Array = rings[i][j]
			var b0: Array = rings[i][j + 1]
			var a1: Array = rings[i + 1][j]
			var b1: Array = rings[i + 1][j + 1]
			var v0 := float(j)
			_quad(c.solid, a0[0], a1[0], b1[0], b0[0], Color.WHITE, [Vector2(u0, v0), Vector2(u0 + 1, v0), Vector2(u0 + 1, v0 + 1), Vector2(u0, v0 + 1)])
			var n: int = c.solid.c.size()
			for k in 6:
				c.solid.c[n - 6 + k] = [a0, a1, b1, a0, b1, b0][k][1]
		_shape(c, line[i], line[i + 1], 1.4, 1.7, (rings[i][0][0].y + rings[i + 1][0][0].y) / 2.0 + 0.1)
	for end in [0, line.size() - 1]:
		if not _clear(line[end]):
			continue
		var r: Array = rings[end]
		var c := _chunk(line[end])
		for j in [[0, 1, 5, 6], [1, 2, 4, 5], [2, 3, 3, 4]]:
			_quad(c.solid, r[j[0]][0], r[j[1]][0], r[j[2]][0], r[j[3]][0], r[j[1]][1], [Vector2.ZERO, Vector2(0, 1), Vector2(1, 1), Vector2(1, 0)])


static func _leaf_texture() -> Texture2D:
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	for y in 32:
		for x in 32:
			var h := _hash(x * 1.7, y * 2.3)
			var g := 0.55 + 0.45 * h * h
			img.set_pixel(x, y, Color(g, g, g))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func _materials() -> Dictionary:
	var solid := _prop_material()
	solid.set_shader_parameter("albedo_texture_linear", _leaf_texture())
	# One 0.15 m mesh cell of stock netting, its wires one pixel thick (about a centimetre) and closer together near the ground.
	var rows := [0, 8, 20, 36, 56, 80, 108, 127]
	var img := Image.create(16, 128, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 0))
	for y in 128:
		img.set_pixel(0, y, Color.WHITE)
	for r: int in rows:
		for x in 16:
			img.set_pixel(x, 127 - r, Color.WHITE)
	var net := _prop_material()
	img.generate_mipmaps()
	net.set_shader_parameter("albedo_texture_linear", ImageTexture.create_from_image(img))
	net.set_shader_parameter("alpha_scissor", 0.25)
	return {"solid": solid, "net": net}


static func _prop_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/level_prop.gdshader")
	mat.set_shader_parameter("linear_filter", true)
	mat.set_shader_parameter("vertex_color_is_srgb", true)
	return mat
