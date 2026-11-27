class_name GroundCover
extends Node3D
# Docs: features/level-editor.md — update in the same change as this file.
# Tests: tests/headless/test_ground_cover.gd — extend in the same change.
# The level editor's ground cover (grass, rush, heather, bushes) drawn around the camera as instanced opaque tufts,
# placed from the save's 1 m cover grid and the tuft recipes it carries (coverKinds), in square tiles built as the
# camera nears them (stream) and dropped once far behind, each tile with its own bush fields.

const DEG := PI / 180.0
const MAX_PER_LAYER := 15
const TILE := 32.0  # metres per side of one batch of tufts
const TINT_GAIN := 2.0  # the ground texture is mid-tone, so a tint colour is doubled to multiply it

var size := 600
var cover := PackedByteArray()
var kinds := {}  # type id (String) -> [[recipe dict, tufts per m²], ...]
var height_fn: Callable
var material: ShaderMaterial
var far_material: ShaderMaterial
var _meshes := {}
var _far_meshes := {}  # recipe index key -> ArrayMesh
var tiles := {}  # Vector2i -> Node3D holding that tile's tufts and bush fields


static func decode_cover(d: Dictionary) -> PackedByteArray:
	var webp: Variant = d.get("coverWebp")
	if webp is String:
		var img := Image.new()
		if img.load_webp_from_buffer(Marshalls.base64_to_raw(webp)) != OK:
			return PackedByteArray()
		img.convert(Image.FORMAT_R8)
		return img.get_data()
	var rle: Variant = d.get("coverRle")
	if rle is String:
		return rle_decode(Marshalls.base64_to_raw(rle), int(d.get("size", 600)) ** 2)
	var c: Variant = d.get("cover")
	return Marshalls.base64_to_raw(c) if c is String else PackedByteArray()


static func rle_decode(b: PackedByteArray, length: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(length)
	var i := 0
	var o := 0
	while i < b.size():
		var t := b[i]
		i += 1
		var n := 0
		var shift := 0
		var v := 128
		while v & 128:
			v = b[i]
			i += 1
			n |= (v & 127) << shift
			shift += 7
		for k in n:
			out[o + k] = t
		o += n
	return out


static func make_material(fade_start: float, fade_end: float, far_fade := Vector2.ZERO) -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """shader_type spatial;
render_mode cull_disabled;
uniform vec3 centre;
uniform vec2 fade;
uniform vec2 far_fade;
uniform bool is_far;
uniform float base_dark = 0.0;
uniform float base_height = 0.5;
#include "res://shaders/headlight_cone.gdshaderinc"
varying vec3 local;
varying vec3 world;
varying float alpha;
float hash3(vec3 p) { return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453); }
void vertex() {
	local = VERTEX;
	world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float d = distance(MODEL_MATRIX[3].xz, centre.xz);
	float near = 1.0 - smoothstep(fade.x, fade.y, d);
	alpha = is_far ? (1.0 - near) * (1.0 - smoothstep(far_fade.x, far_fade.y, d)) : near;
	VERTEX *= step(0.001, alpha);
}
void fragment() {
	// screen-door fade: near and far use the same 4x4 Bayer threshold, so where one drops a pixel the other draws it
	ivec2 px = ivec2(FRAGCOORD.xy) % 4;
	int bayer[16] = int[](0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5);
	float threshold = (float(bayer[px.y * 4 + px.x]) + 0.5) / 16.0;
	if (is_far ? 1.0 - alpha >= threshold : alpha < threshold) discard;
	vec3 base = COLOR.rgb * mix(1.0 - base_dark, 1.0, smoothstep(0.0, base_height, local.y));
	// a bush is one smooth dome; UV.x (leaves per metre) paints clumps of lit leaves over dark gaps onto it
	if (UV.x > 0.0) {
		vec3 q = local * UV.x * 3.0;
		float n = hash3(floor(q)) * 0.6 + hash3(floor(q * 2.0 + 17.0)) * 0.4;
		base *= mix(0.75, 1.15, smoothstep(0.3, 0.7, n));
	}
	ALBEDO = base * world_light;
	// this shader is sun-lit, so the headlights go in as emission to stay bright when the world is dark
	EMISSION = base * (hl_color * headlight_lit(world) + flash_lit(world));
	ROUGHNESS = 1.0;
	if (!FRONT_FACING) NORMAL = -NORMAL;
}
"""
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("fade", Vector2(fade_start, fade_end))
	m.set_shader_parameter("far_fade", far_fade)
	m.set_shader_parameter("is_far", far_fade != Vector2.ZERO)
	m.set_shader_parameter("base_dark", Config.data.level_ao_bush_base)
	m.set_shader_parameter("base_height", Config.data.level_ao_bush_base_height_m)
	return m


# How much of a tuft is drawn at `dist` from the camera (mirrors the shader); the rest of its pixels are dithered away.
static func near_alpha(dist: float, fade_start: float, fade_end: float) -> float:
	return 1.0 - smoothstep(fade_start, fade_end, dist)


# A far bush dome fills exactly the pixels its near bush dithers away, then dithers out itself between the far fade bounds.
static func far_alpha(dist: float, fade_start: float, fade_end: float, far_start: float, far_end: float) -> float:
	return (1.0 - near_alpha(dist, fade_start, fade_end)) * (1.0 - smoothstep(far_start, far_end, dist))


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


# The cover type id at (x, z), with hash-jittered cell edges; 0 off the grid or off cover.
static func cover_id(cov: PackedByteArray, grid: int, x: float, z: float) -> int:
	var half := grid / 2.0
	var cx := floori(x + half + (hash2(floori(x * 2.0), floori(z * 2.0), 901) - 0.5) * 1.2)
	var cz := floori(z + half + (hash2(floori(x * 2.0), floori(z * 2.0), 902) - 0.5) * 1.2)
	if cx < 0 or cz < 0 or cx >= grid or cz >= grid:
		return 0
	return cov[cz * grid + cx]


# The cover type ids that grow bushes.
static func bush_ids(kinds_d: Dictionary) -> Dictionary:
	var out := {}
	for id: String in kinds_d:
		for layer: Array in kinds_d[id]:
			if (layer[0] as Dictionary).has("bushRadius"):
				out[int(id)] = true
	return out


# 1 off bush cover, 1 - strength under it: the ground darkening beneath bushes.
static func bush_shade(cov: PackedByteArray, grid: int, ids: Dictionary, x: float, z: float, strength: float) -> float:
	if cov.is_empty() or ids.is_empty():
		return 1.0
	return 1.0 - strength if ids.has(cover_id(cov, grid, x, z)) else 1.0


# Multiplier for the terrain's baked light at (x, z): white off cover, the type's tint on it, with hash-jittered cell edges.
static func ground_multiplier(cov: PackedByteArray, grid: int, tint_d: Dictionary, x: float, z: float) -> Color:
	if cov.is_empty():
		return Color.WHITE
	var t: Variant = tint_d.get(cover_id(cov, grid, x, z))
	if t == null:
		return Color.WHITE
	return Color(minf((t as Color).r * TINT_GAIN, 1.5), minf((t as Color).g * TINT_GAIN, 1.5), minf((t as Color).b * TINT_GAIN, 1.5))


const MAX_INFLIGHT := 4
var max_inflight := MAX_INFLIGHT

class TileJob:
	var t: Vector2i
	var car: Node3D
	var task_id := -1
	var cancelled := false
	var placed := {}
	var far_placed := {}
	var spots := []

var _inflight: Array[TileJob] = []


func _exit_tree() -> void:
	for job in _inflight:
		job.cancelled = true
		WorkerThreadPool.wait_for_task_completion(job.task_id)
	_inflight.clear()


func _threads_ok() -> bool:
	return OS.has_feature("threads") and Config.data.threaded_chunk_build


# Registers an empty tile node at once (so it counts as built) and fills it when its worker finishes.
func _dispatch_tile(t: Vector2i, car: Node3D) -> void:
	var node := Node3D.new()
	node.name = "Tile_%d_%d" % [t.x, t.y]
	add_child(node)
	tiles[t] = node
	var job := TileJob.new()
	job.t = t
	job.car = car
	job.task_id = WorkerThreadPool.add_task(_build_job.bind(job), false, "cover tile")
	_inflight.append(job)


func _build_job(job: TileJob) -> void:
	var rect := Rect2(Vector2(job.t) * TILE, Vector2.ONE * TILE)
	job.placed = placements(cover, size, kinds, Vector2.ZERO, 1.0, height_fn, 1.0, job.far_placed, rect)
	if job.car != null and not job.cancelled:
		job.spots = bush_spots(cover, size, kinds, rect)


func _poll_tiles() -> void:
	var i := 0
	while i < _inflight.size():
		var job := _inflight[i]
		if WorkerThreadPool.is_task_completed(job.task_id):
			WorkerThreadPool.wait_for_task_completion(job.task_id)
			_inflight.remove_at(i)
			if not job.cancelled and tiles.has(job.t):
				_fill_tile(tiles[job.t], job.t, job.placed, job.far_placed, job.spots, job.car if is_instance_valid(job.car) else null)
		else:
			i += 1


func _cancel_tile(t: Vector2i) -> void:
	for job in _inflight:
		if job.t == t:
			job.cancelled = true
			WorkerThreadPool.wait_for_task_completion(job.task_id)
			_inflight.erase(job)
			return


# Tiles still being computed on workers.
func pending() -> int:
	return _inflight.size()


func setup(d: Dictionary, height: Callable, mat_size := 600) -> void:
	size = mat_size
	cover = decode_cover(d)
	kinds = d.get("coverKinds", {})
	height_fn = height
	material = make_material(Config.data.ground_cover_fade_start, Config.data.ground_cover_fade_end)
	far_material = make_material(Config.data.ground_cover_fade_start, Config.data.ground_cover_fade_end, Vector2(Config.data.ground_cover_far_fade_start, Config.data.ground_cover_far_fade_end))


# Hidden cover (the level replay's --off) builds no tiles either.
func has_cover() -> bool:
	return visible and not cover.is_empty() and not kinds.is_empty()


# How far the far layer (bush domes) streams and draws: GameConfig.ground_cover_far_reach, or photo
# mode's render override while it is set.
var _reach_override := 0.0


func far_reach() -> float:
	return maxf(Config.data.ground_cover_far_reach, _reach_override)


# Stream and draw the far layer out to `metres` (photo mode's render); 0 goes back to the configured
# reach. Built tiles take the new range at once; tiles past the normal reach go on the next stream.
func set_reach_override(metres: float) -> void:
	_reach_override = metres
	var cfg: GameConfig = Config.data
	if far_material != null:
		far_material.set_shader_parameter("far_fade", Vector2(maxf(cfg.ground_cover_far_fade_start, metres * 0.9), metres)
			if metres > 0.0 else Vector2(cfg.ground_cover_far_fade_start, cfg.ground_cover_far_fade_end))
	for node: Node in tiles.values():
		for mmi in node.get_children():
			if mmi is MultiMeshInstance3D and (mmi as MultiMeshInstance3D).material_override == far_material:
				(mmi as MultiMeshInstance3D).visibility_range_end = far_reach() + TILE * 0.71


## Puts the GameConfig ground_cover_* reaches and fades into effect on tiles already built.
func refresh_reach() -> void:
	if material == null:
		return
	var cfg: GameConfig = Config.data
	var fade := Vector2(cfg.ground_cover_fade_start, cfg.ground_cover_fade_end)
	material.set_shader_parameter("fade", fade)
	far_material.set_shader_parameter("fade", fade)
	set_reach_override(_reach_override)
	for node: Node in tiles.values():
		for mmi in node.get_children():
			if mmi is MultiMeshInstance3D and (mmi as MultiMeshInstance3D).material_override == material:
				(mmi as MultiMeshInstance3D).visibility_range_end = cfg.ground_cover_reach + TILE * 0.71


func update_centre(pos: Vector3) -> void:
	if not has_cover():
		return
	material.set_shader_parameter("centre", pos)
	far_material.set_shader_parameter("centre", pos)


# Builds the tiles within reach of `centre` (nearest first) while there is time before `deadline_us`, and drops the ones far behind.
# The tile under `centre` and its eight neighbours always build, over the deadline if need be, so cover never goes missing round the car.
func stream(centre: Vector2, deadline_us: int, car: Node3D = null) -> void:
	if not has_cover():
		return
	_poll_tiles()
	var reach := far_reach() + TILE * 0.71
	for t: Vector2i in tiles.keys():
		if tile_centre(t).distance_to(centre) > reach + TILE:
			_cancel_tile(t)
			(tiles[t] as Node).queue_free()
			tiles.erase(t)
	var core := Vector2i((centre / TILE).floor())
	for t in missing(centre):
		var is_core := maxi(absi(t.x - core.x), absi(t.y - core.y)) <= 1
		if is_core or Time.get_ticks_usec() < deadline_us:
			if _threads_ok():
				if _inflight.size() >= max_inflight:
					break
				_dispatch_tile(t, car)
			else:
				build_tile(t, car)


# The tiles within reach of `centre` that aren't built yet, nearest first.
func missing(centre: Vector2) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if not has_cover():
		return out
	var reach := far_reach() + TILE * 0.71
	var limit := size * 0.5 + TILE
	for tz in range(floori((centre.y - reach) / TILE), floori((centre.y + reach) / TILE) + 1):
		for tx in range(floori((centre.x - reach) / TILE), floori((centre.x + reach) / TILE) + 1):
			var t := Vector2i(tx, tz)
			var c := tile_centre(t)
			if not tiles.has(t) and c.distance_to(centre) <= reach and absf(c.x) < limit and absf(c.y) < limit:
				out.append(t)
	out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return tile_centre(a).distance_squared_to(centre) < tile_centre(b).distance_squared_to(centre))
	return out


static func tile_centre(t: Vector2i) -> Vector2:
	return (Vector2(t) + Vector2(0.5, 0.5)) * TILE


# One tile's tufts, one MultiMesh per layer drawn only within its reach of the camera, plus a BushField per bush layer when there is a car to brush them.
func build_tile(t: Vector2i, car: Node3D = null) -> void:
	var node := Node3D.new()
	node.name = "Tile_%d_%d" % [t.x, t.y]
	add_child(node)
	tiles[t] = node
	var rect := Rect2(Vector2(t) * TILE, Vector2.ONE * TILE)
	var far_placed := {}
	var placed := placements(cover, size, kinds, Vector2.ZERO, 1.0, height_fn, 1.0, far_placed, rect)
	var spots := bush_spots(cover, size, kinds, rect) if car != null else []
	_fill_tile(node, t, placed, far_placed, spots, car)


func _fill_tile(node: Node3D, t: Vector2i, placed: Dictionary, far_placed: Dictionary, spots_list: Array, car: Node3D) -> void:
	var diag := TILE * 0.71
	for key: String in placed:
		_add_layer(node, t, placed[key], _mesh_for(key), material, Config.data.ground_cover_reach + diag)
	for key: String in far_placed:
		_add_layer(node, t, far_placed[key], _far_mesh_for(key), far_material, far_reach() + diag)
	if car == null:
		return
	var cfg: GameConfig = Config.data
	for spots: Array in spots_list:
		var field := BushField.new()
		field.name = "BushInteraction"
		node.add_child(field)
		field.setup(spots[0], car, float(spots[1]) * cfg.bush_hit_radius_frac, cfg.bush_drag_strength,
			cfg.bush_drag_torque, cfg.bush_min_speed_kmh / DamageModel.MPS_TO_KMH)


# The tile's footprint, as tall as its tufts' ground: the draw range is measured to the middle of this box, so a tall box would put it out of range.
static func tile_aabb(t: Vector2i, buf: PackedFloat32Array) -> AABB:
	var lo := INF
	var hi := -INF
	for i in range(7, buf.size(), 12):
		lo = minf(lo, buf[i])
		hi = maxf(hi, buf[i])
	if lo > hi:
		lo = 0.0
		hi = 0.0
	return AABB(Vector3(t.x * TILE, lo - 1.0, t.y * TILE), Vector3(TILE, hi - lo + 4.0, TILE))


func _add_layer(parent: Node3D, t: Vector2i, buf: PackedFloat32Array, mesh: ArrayMesh, mat: ShaderMaterial, reach: float) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = buf.size() / 12
	mm.buffer = buf
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.custom_aabb = tile_aabb(t, buf)
	mmi.visibility_range_end = reach
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mmi)


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
static func placements(cov: PackedByteArray, grid: int, kinds_d: Dictionary, centre: Vector2, reach: float, height: Callable, far_reach := 0.0, far_out := {}, tile := Rect2()) -> Dictionary:
	var out := {}
	var ext := maxf(reach, far_reach)
	var half := grid / 2.0
	var c0 := maxi(0, floori(centre.x + half - ext))
	var c1 := mini(grid - 1, ceili(centre.x + half + ext))
	var r0 := maxi(0, floori(centre.y + half - ext))
	var r1 := mini(grid - 1, ceili(centre.y + half + ext))
	var boxed := tile.has_area()
	if boxed:
		c0 = maxi(0, floori(tile.position.x + half))
		c1 = mini(grid - 1, ceili(tile.end.x + half) - 1)
		r0 = maxi(0, floori(tile.position.y + half))
		r1 = mini(grid - 1, ceili(tile.end.y + half) - 1)
	var lists := {}
	var far_lists := {}
	for rr in range(r0, r1 + 1):
		for cc in range(c0, c1 + 1):
			var id := cov[rr * grid + cc]
			if id == 0 or not kinds_d.has(str(id)):
				continue
			var wx := cc - half
			var wz := rr - half
			var cell_d := 0.0 if boxed else Vector2(wx + 0.5, wz + 0.5).distance_to(centre)
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
					var z := wz + hash2(cc, rr, salt + k * 4 + 1)  # bush_spots repeats these two lines
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
	var g := {"pos": [], "col": [], "nrm": [], "uv": [], "idx": PackedInt32Array(), "tips": []}
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
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array(g["uv"])
	arrays[Mesh.ARRAY_INDEX] = g["idx"]
	var mesh := ArrayMesh.new()
	if not (g["idx"] as PackedInt32Array).is_empty():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# The far bush is the same leaf-painted dome with fewer sides, so the swap is hard to spot.
static func build_far_bush(s: Dictionary) -> ArrayMesh:
	var far := s.duplicate()
	far["coreSides"] = 6
	far["coreRows"] = 2
	far["flowers"] = 0
	return build_tuft(1, far)


static func _vert(g: Dictionary, p: Vector3, c: Color, n: Vector3, uv := Vector2.ZERO) -> int:
	(g["uv"] as Array).append(uv)
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


# Per bush layer: [every bush's XZ over the square, or only the cells of `tile` (the spots placements draws them at), the bush's radius].
static func bush_spots(cov: PackedByteArray, grid: int, kinds_d: Dictionary, tile := Rect2()) -> Array:
	var lists := {}
	var half := grid / 2.0
	var c0 := 0
	var c1 := grid - 1
	var r0 := 0
	var r1 := grid - 1
	if tile.has_area():
		c0 = maxi(0, floori(tile.position.x + half))
		c1 = mini(grid - 1, ceili(tile.end.x + half) - 1)
		r0 = maxi(0, floori(tile.position.y + half))
		r1 = mini(grid - 1, ceili(tile.end.y + half) - 1)
	for rr in range(r0, r1 + 1):
		for cc in range(c0, c1 + 1):
			var id := cov[rr * grid + cc]
			if id == 0 or not kinds_d.has(str(id)):
				continue
			var layers: Array = kinds_d[str(id)]
			for li in layers.size():
				var recipe: Dictionary = layers[li][0]
				if str(recipe.get("shape", "blades")) != "bush":
					continue
				var salt := (id * 8 + li + 1) * 64
				var n := mini(MAX_PER_LAYER, floori(float(layers[li][1]) + hash2(cc, rr, salt + 63)))
				var key := "%d:%d" % [id, li]
				if n > 0 and not lists.has(key):
					lists[key] = [PackedVector2Array(), float(recipe["bushRadius"])]
				var pts: PackedVector2Array = lists[key][0] if n > 0 else PackedVector2Array()
				for k in n:
					pts.append(Vector2(cc - half + hash2(cc, rr, salt + k * 4), rr - half + hash2(cc, rr, salt + k * 4 + 1)))
				if n > 0:
					lists[key][0] = pts
	return lists.values()


# A bush is one lumpy dome, shaded from base to tip colour by height; the shader paints its leaves on.
static func _add_bush(g: Dictionary, rng: RandomNumberGenerator, s: Dictionary) -> void:
	var base := Color(str(s["base"]))
	var tip := Color(str(s["tip"]))
	var R := float(s["bushRadius"])
	var H := float(s["bushHeight"])
	var fuzz := float(s["fuzz"])
	var leaf := Vector2(1.0 / maxf(float(s["leafSize"]), 0.01), 0.0)
	var idx: PackedInt32Array = g["idx"]
	var first: int = (g["pos"] as Array).size()
	var sides := int(s.get("coreSides", 8))
	var rows := int(s.get("coreRows", 4))
	var p1 := rng.randf() * TAU
	var p2 := rng.randf() * TAU
	for iy in rows + 1:
		var th := float(iy) / rows * PI / 2.0
		for ix in sides + 1:
			var ph := float(ix) / sides * TAU
			var d := Vector3(-cos(ph) * sin(th), cos(th), sin(ph) * sin(th))
			# whole-number frequencies around and zero at the top, so the lumps close up at the seam and the pole
			var lump := 1.0 + fuzz * 0.3 * (sin(3.0 * ph + p1) * sin(3.0 * th) + 0.5 * sin(5.0 * ph + p2) * sin(5.0 * th))
			var col := base.lerp(tip, d.y * 0.8)
			col.a = 1.0
			_vert(g, Vector3(d.x * R * lump, d.y * H * lump, d.z * R * lump), col, (d + Vector3.UP).normalized(), leaf)
			if iy == 0 or (iy < rows and ix < sides and rng.randf() < 0.3):
				(g["tips"] as Array).append(Vector3(d.x * R * lump, d.y * H * lump, d.z * R * lump))
	for iy in rows:
		for ix in sides:
			var a := first + iy * (sides + 1) + ix + 1
			var b := first + iy * (sides + 1) + ix
			var c := first + (iy + 1) * (sides + 1) + ix
			var d2 := first + (iy + 1) * (sides + 1) + ix + 1
			idx.append_array([a, b, d2, b, c, d2])
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
