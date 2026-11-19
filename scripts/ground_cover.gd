class_name GroundCover
extends Node3D
# Docs: features/level-editor.md — update in the same change as this file.
# Tests: tests/headless/test_ground_cover.gd — extend in the same change.
# The level editor's ground cover (grass, rush, heather, bushes) drawn around the camera as instanced opaque tufts,
# generated on the fly from the save's 1 m cover grid and the tuft recipes it carries (coverKinds).

const DEG := PI / 180.0
const MAX_PER_LAYER := 15
const TINT_GAIN := 2.0  # the ground texture is mid-tone, so a tint colour is doubled to multiply it

var size := 600
var cover := PackedByteArray()
var kinds := {}  # type id (String) -> [[recipe dict, tufts per m²], ...]
var height_fn: Callable
var material: ShaderMaterial
var far_material: ShaderMaterial
var _meshes := {}
var _far_meshes := {}  # recipe index key -> ArrayMesh
var _centre := Vector2(INF, INF)
var _mmis: Array[MultiMeshInstance3D] = []


static func decode_cover(d: Dictionary) -> PackedByteArray:
	var c: Variant = d.get("cover")
	return Marshalls.base64_to_raw(c) if c is String else PackedByteArray()


static func make_material(fade_start: float, fade_end: float, far_fade := Vector2.ZERO) -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """shader_type spatial;
render_mode cull_disabled;
uniform vec3 centre;
uniform vec2 fade;
uniform vec2 far_fade;
uniform bool is_far;
void vertex() {
	vec3 root = MODEL_MATRIX[3].xyz;
	float h = fract(sin(dot(root.xz, vec2(12.9898, 78.233))) * 43758.5453);
	float cut = mix(fade.x, fade.y, h);
	float d = distance(root.xz, centre.xz);
	if (is_far) {
		float fcut = mix(far_fade.x, far_fade.y, h);
		VERTEX *= step(cut, d) * step(d, fcut);
	} else {
		VERTEX *= step(d, cut);
	}
}
void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 1.0;
	if (!FRONT_FACING) NORMAL = -NORMAL;
}
"""
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("fade", Vector2(fade_start, fade_end))
	m.set_shader_parameter("far_fade", far_fade)
	m.set_shader_parameter("is_far", far_fade != Vector2.ZERO)
	return m


# Each tuft thins out at its own distance between the fade bounds (mirrored in the shader), so it dithers into the ground tint.
static func cutoff(x: float, z: float, fade_start: float, fade_end: float) -> float:
	var h := fposmod(sin(x * 12.9898 + z * 78.233) * 43758.5453, 1.0)
	return lerpf(fade_start, fade_end, h)


# A bush's far dome is drawn from the instant its near tuft is gone (cut) until its own far cut-off (far_cut).
static func far_scale(dist: float, cut: float, far_cut: float) -> float:
	return (1.0 if dist >= cut else 0.0) * shown(dist, far_cut)


# Tufts switch off outright at their cut-off; shrinking them instead read as a visible "grow-in" while driving.
static func shown(dist: float, cut: float) -> float:
	return 1.0 if dist <= cut else 0.0


# Ground colour per cover type id: the average of its layers' tuft colours, weighted by density.
static func tints(kinds_d: Dictionary) -> Dictionary:
	var out := {}
	for id: String in kinds_d:
		var sum := Color(0, 0, 0, 0)
		var w := 0.0
		for layer: Array in kinds_d[id]:
			var s: Dictionary = layer[0]
			var d := float(layer[1])
			sum += (Color(str(s["base"])) + Color(str(s["tip"]))) * 0.5 * d
			w += d
		if w > 0.0:
			out[int(id)] = Color(sum.r / w, sum.g / w, sum.b / w)
	return out


# Multiplier for the terrain's baked light at (x, z): white off cover, the type's tint on it, with hash-jittered cell edges.
static func ground_multiplier(cov: PackedByteArray, grid: int, tint_d: Dictionary, x: float, z: float) -> Color:
	if cov.is_empty():
		return Color.WHITE
	var half := grid / 2.0
	var cx := floori(x + half + (hash2(floori(x * 2.0), floori(z * 2.0), 901) - 0.5) * 1.2)
	var cz := floori(z + half + (hash2(floori(x * 2.0), floori(z * 2.0), 902) - 0.5) * 1.2)
	if cx < 0 or cz < 0 or cx >= grid or cz >= grid:
		return Color.WHITE
	var t: Variant = tint_d.get(int(cov[cz * grid + cx]))
	if t == null:
		return Color.WHITE
	return Color(minf((t as Color).r * TINT_GAIN, 1.5), minf((t as Color).g * TINT_GAIN, 1.5), minf((t as Color).b * TINT_GAIN, 1.5))


func setup(d: Dictionary, height: Callable, mat_size := 600) -> void:
	size = mat_size
	cover = decode_cover(d)
	kinds = d.get("coverKinds", {})
	height_fn = height
	material = make_material(Config.data.ground_cover_fade_start, Config.data.ground_cover_fade_end)
	far_material = make_material(Config.data.ground_cover_fade_start, Config.data.ground_cover_fade_end, Vector2(Config.data.ground_cover_far_fade_start, Config.data.ground_cover_far_fade_end))


func has_cover() -> bool:
	return not cover.is_empty() and not kinds.is_empty()


func update_centre(pos: Vector3) -> void:
	if not has_cover():
		return
	material.set_shader_parameter("centre", pos)
	far_material.set_shader_parameter("centre", pos)
	var p := Vector2(pos.x, pos.z)
	if p.distance_to(_centre) <= Config.data.ground_cover_rebuild_m:
		return
	_centre = p
	for m in _mmis:
		m.queue_free()
	_mmis.clear()
	var far_placed := {}
	var placed := placements(cover, size, kinds, p, Config.data.ground_cover_reach, height_fn, Config.data.ground_cover_far_reach, far_placed)
	for key: String in placed:
		_add_layer(placed[key], _mesh_for(key), material)
	for key: String in far_placed:
		_add_layer(far_placed[key], _far_mesh_for(key), far_material)


func _add_layer(buf: PackedFloat32Array, mesh: ArrayMesh, mat: ShaderMaterial) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = buf.size() / 12
	mm.buffer = buf
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.custom_aabb = AABB(Vector3(-size, -size, -size), Vector3.ONE * size * 2.0)
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	_mmis.append(mmi)


func _far_mesh_for(key: String) -> ArrayMesh:
	if not _far_meshes.has(key):
		var parts := key.split(":")
		_far_meshes[key] = build_far_bush(kinds[parts[0]][int(parts[1])][0])
	return _far_meshes[key]


# key is "<type id>:<layer>"
func _mesh_for(key: String) -> ArrayMesh:
	if not _meshes.has(key):
		var parts := key.split(":")
		_meshes[key] = build_tuft(1, kinds[parts[0]][int(parts[1])][0])
	return _meshes[key]


static func hash2(x: int, y: int, s: int) -> float:
	var m := 0xFFFFFFFF
	var h := ((x * 374761393) ^ (y * 668265263) ^ (s * 2147483647)) & m
	h = ((h ^ (h >> 13)) * 1274126177) & m
	return float((h ^ (h >> 16)) & m) / 4294967296.0


# Per "<id>:<layer>", MultiMesh buffers (12 floats per tuft) for every cover cell within `reach` of `centre`.
# With far_reach > 0, bush layers' instances out to that distance are also written (same transforms) into far_out.
static func placements(cov: PackedByteArray, grid: int, kinds_d: Dictionary, centre: Vector2, reach: float, height: Callable, far_reach := 0.0, far_out := {}) -> Dictionary:
	var out := {}
	var ext := maxf(reach, far_reach)
	var half := grid / 2.0
	var c0 := maxi(0, floori(centre.x + half - ext))
	var c1 := mini(grid - 1, ceili(centre.x + half + ext))
	var r0 := maxi(0, floori(centre.y + half - ext))
	var r1 := mini(grid - 1, ceili(centre.y + half + ext))
	var lists := {}
	var far_lists := {}
	for rr in range(r0, r1 + 1):
		for cc in range(c0, c1 + 1):
			var id := cov[rr * grid + cc]
			if id == 0 or not kinds_d.has(str(id)):
				continue
			var wx := cc - half
			var wz := rr - half
			var cell_d := Vector2(wx + 0.5, wz + 0.5).distance_to(centre)
			if cell_d > ext:
				continue
			var layers: Array = kinds_d[str(id)]
			for li in layers.size():
				var salt := (id * 8 + li + 1) * 64
				var n := mini(MAX_PER_LAYER, floori(float(layers[li][1]) + hash2(cc, rr, salt + 63)))
				if n <= 0:
					continue
				var key := "%d:%d" % [id, li]
				var near := cell_d <= reach
				var far := far_reach > 0.0 and cell_d <= far_reach and str(layers[li][0].get("shape", "blades")) == "bush"
				if not near and not far:
					continue
				if not lists.has(key):
					lists[key] = PackedFloat32Array()
				var buf: PackedFloat32Array = lists[key]
				if far and not far_lists.has(key):
					far_lists[key] = PackedFloat32Array()
				var fbuf: PackedFloat32Array = far_lists.get(key, PackedFloat32Array())
				for k in n:
					var x := wx + hash2(cc, rr, salt + k * 4)
					var z := wz + hash2(cc, rr, salt + k * 4 + 1)
					var yaw := hash2(cc, rr, salt + k * 4 + 2) * TAU
					var sc := 0.7 + 0.6 * hash2(cc, rr, salt + k * 4 + 3)
					var cy := cos(yaw) * sc
					var sy := sin(yaw) * sc
					var t := [cy, 0.0, sy, x, 0.0, sc, 0.0, float(height.call(x, z)), -sy, 0.0, cy, z]
					if near:
						buf.append_array(t)
					if far:
						fbuf.append_array(t)
				if far:
					far_lists[key] = fbuf
	for key: String in lists:
		if not (lists[key] as PackedFloat32Array).is_empty():
			out[key] = lists[key]
	for key: String in far_lists:
		far_out[key] = far_lists[key]
	return out


static func build_tuft(seed_: int, s: Dictionary) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_
	# plain Arrays while building: packed arrays are copied by value, so appending through the dictionary would be lost
	var g := {"pos": [], "col": [], "nrm": [], "idx": PackedInt32Array(), "tips": []}
	if str(s.get("shape", "blades")) == "bush":
		_add_bush(g, rng, s)
	else:
		_add_blades(g, rng, s)
	_add_flowers(g, rng, s)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array(g["pos"])
	arrays[Mesh.ARRAY_COLOR] = PackedColorArray(g["col"])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array(g["nrm"])
	arrays[Mesh.ARRAY_INDEX] = g["idx"]
	var mesh := ArrayMesh.new()
	if not (g["idx"] as PackedInt32Array).is_empty():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# Low-poly dome (6 sides x 2 rows, 18 triangles) in the bush's mixed colour, for bushes too far for leaves.
# The far bush is the same bush with a coarser core and a quarter of the leaves at twice the size (so they cover about
# as much), so it keeps the near bush's colours and outline and the swap is hard to spot.
static func build_far_bush(s: Dictionary) -> ArrayMesh:
	var far := s.duplicate()
	far["leaves"] = maxi(6, int(s["leaves"]) / 4)
	far["leafSize"] = float(s["leafSize"]) * 2.0
	far["coreSides"] = 6
	far["coreRows"] = 2
	far["flowers"] = 0
	return build_tuft(1, far)


static func _vert(g: Dictionary, p: Vector3, c: Color, n: Vector3) -> int:
	(g["pos"] as Array).append(p)
	(g["col"] as Array).append(c)
	(g["nrm"] as Array).append(n)
	return (g["pos"] as Array).size() - 1


static func _add_blades(g: Dictionary, rng: RandomNumberGenerator, s: Dictionary) -> void:
	var base := Color(str(s["base"]))
	var tip := Color(str(s["tip"]))
	var n := int(s["segments"])
	var idx: PackedInt32Array = g["idx"]
	for _b in int(s["blades"]):
		var a := rng.randf() * TAU
		var r := float(s["radius"]) * sqrt(rng.randf())
		var yaw := a + (rng.randf() - 0.5) * 0.8
		var dir := Vector3(cos(yaw), 0, sin(yaw))
		var side := Vector3(-sin(yaw), 0, cos(yaw))
		var h := float(s["height"]) * (1.0 - float(s["heightJitter"]) * rng.randf())
		var lean := (float(s["lean"]) + (rng.randf() * 2.0 - 1.0) * float(s["leanJitter"])) * DEG
		var shade := 1.0 + (rng.randf() * 2.0 - 1.0) * float(s["colourVar"])
		var p := Vector3(cos(a) * r, 0, sin(a) * r)
		var first: int = (g["pos"] as Array).size()
		for i in n + 1:
			var t := float(i) / n
			var w := float(s["width"]) * (1.0 - t) / 2.0
			var c := base.lerp(tip, t) * shade
			c.a = 1.0
			if i < n:
				_vert(g, p - side * w, c, Vector3.UP)
				_vert(g, p + side * w, c, Vector3.UP)
				var mid := lean + float(s["bend"]) * DEG * (i + 0.5) / n
				p += dir * sin(mid) * h / n + Vector3.UP * cos(mid) * h / n
			else:
				_vert(g, p, c, Vector3.UP)
				(g["tips"] as Array).append(p)
		for i in n - 1:
			var q := first + 2 * i
			idx.append_array([q, q + 2, q + 1, q + 1, q + 2, q + 3])
		var q := first + 2 * (n - 1)
		idx.append_array([q, first + 2 * n, q + 1])
	g["idx"] = idx


static func _add_bush(g: Dictionary, rng: RandomNumberGenerator, s: Dictionary) -> void:
	var base := Color(str(s["base"]))
	var tip := Color(str(s["tip"]))
	var R := float(s["bushRadius"])
	var H := float(s["bushHeight"])
	var idx: PackedInt32Array = g["idx"]
	if int(s["core"]) != 0:
		var first: int = (g["pos"] as Array).size()
		var inner := base * 0.7
		inner.a = 1.0
		var sides := int(s.get("coreSides", 8))
		var rows := int(s.get("coreRows", 4))
		for iy in rows + 1:
			var th := float(iy) / rows * PI / 2.0
			for ix in sides + 1:
				var ph := float(ix) / sides * TAU
				var d := Vector3(-cos(ph) * sin(th), cos(th), sin(ph) * sin(th))
				_vert(g, Vector3(d.x * R * 0.85, d.y * H * 0.9, d.z * R * 0.85), inner, (d + Vector3.UP).normalized())
		for iy in rows:
			for ix in sides:
				var a := first + iy * (sides + 1) + ix + 1
				var b := first + iy * (sides + 1) + ix
				var c := first + (iy + 1) * (sides + 1) + ix
				var d2 := first + (iy + 1) * (sides + 1) + ix + 1
				idx.append_array([a, b, d2, b, c, d2])
	var fuzz := float(s["fuzz"])
	for _k in int(s["leaves"]):
		var y := rng.randf() * 1.1 - 0.1
		var th := rng.randf() * TAU
		var rr := sqrt(maxf(0.0, 1.0 - y * y))
		var d := Vector3(rr * cos(th), y, rr * sin(th))
		var out := 1.0 + (rng.randf() - 0.4) * fuzz * 0.5
		var c0 := Vector3(d.x * R * out, maxf(d.y, 0.0) * H * out, d.z * R * out)
		var t1 := (Vector3(1, 0, 0) if absf(d.y) > 0.9 else Vector3.UP).cross(d).normalized()
		var t2 := d.cross(t1)
		var col := base.lerp(tip, maxf(0.0, y) * 0.8 + rng.randf() * 0.2) * (1.0 + (rng.randf() * 2.0 - 1.0) * float(s["colourVar"]))
		col.a = 1.0
		var a0 := rng.randf() * TAU
		var sz := float(s["leafSize"]) * (0.6 + 0.4 * rng.randf()) / 1.7
		var n := (d + Vector3.UP).normalized()
		for j in 3:
			var a := a0 + j * 2.0944
			var p := c0 + t1 * cos(a) * sz + t2 * sin(a) * sz
			if j == 0:
				p += d * fuzz * sz * 1.5
			idx.append(_vert(g, p, col, n))
		(g["tips"] as Array).append(c0)
	g["idx"] = idx


static func _add_flowers(g: Dictionary, rng: RandomNumberGenerator, s: Dictionary) -> void:
	var tips: Array = g["tips"]
	var c := Color(str(s.get("flowerColour", "#f2d01c")))
	var count := floori(float(s.get("flowers", 0)) + rng.randf())
	var idx: PackedInt32Array = g["idx"]
	for _k in count:
		if tips.is_empty():
			break
		var p: Vector3 = tips[rng.randi() % tips.size()]
		var a0 := rng.randf() * TAU
		for j in 3:
			var a := a0 + j * 2.0944
			idx.append(_vert(g, Vector3(p.x + cos(a) * 0.02, p.y + 0.01, p.z + sin(a) * 0.02), c, Vector3.UP))
	g["idx"] = idx
