extends Node
# Bakes a level save into <name>.bake.res beside it (scripts/level_bake.gd), including which trees each stretch of road can see. Run, with BAKE_LEVEL the save's path (default: the dev level):
#
#   BAKE_LEVEL=res://tools/levels/hafren_5km.json godot --audio-driver Dummy --path . res://tools/bake_level.tscn
#
# Visibility is rendered, so it needs a window; with --headless the bake skips it and every tree is drawn.
# tools/bake_level.sh runs it as N parallel shards (-- --shard=i/N) and then a merge (-- --merge=N).

const EVERY := 4                 # road samples between viewpoint rows
const VIEW_PX := 384
const SIDES := [-1.0, 0.0, 1.0]  # across the road, in road half-widths plus SIDE_M
const SIDE_M := 3.0
const EYES := [1.2, 3.0]         # bonnet and chase-camera heights
const WINDOW_M := 200.0          # how far the viewpoint can wander from the loaded window's centre before it is rebuilt

var _bake: LevelBake
var _scene := Node3D.new()
var _window := Vector2(INF, INF)
var _views: Array[SubViewport] = []
var _cams: Array[Camera3D] = []
var _levels := PackedInt32Array()   # the colour bytes this renderer returns exactly; an id is written in digits of these
var _digit := PackedInt32Array()    # per byte, its index in _levels or -1
var _last_row_ms := 0
var _shard := 0                     # this process renders the rows from _shard / _shards of the way down the road
var _shards := 1
var _merge := false

const FLAT_SHADER := "shader_type spatial;\nrender_mode unshaded, cull_disabled;\nuniform vec3 c;\nvoid fragment() { ALBEDO = c; }\n"
const STALL_S := 90.0             # no row finishing for this long means the renderer has stopped drawing (a hidden or sleeping window), so give up
const STRIP_IDS := [0, 1, 2, 255, 256, 65535, 65536]


func _ready() -> void:
	var path := OS.get_environment("BAKE_LEVEL")
	if path.is_empty():
		path = Config.data.level_path
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		push_error("bake_level: couldn't read %s" % path)
		get_tree().quit(1)
		return
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shard="):
			_shard = int(a.get_slice("=", 1).get_slice("/", 0))
			_shards = int(a.get_slice("/", 1))
		elif a.begins_with("--merge="):
			_merge = true
			_shards = int(a.get_slice("=", 1))
	var t0 := Time.get_ticks_msec()
	var data := LevelData.new()
	data.load_save(parsed)
	_bake = LevelBake.bake(data, LevelBake.key_of(path))
	var t1 := Time.get_ticks_msec()
	if _merge:
		var problem := _merge_shards()
		if not problem.is_empty():
			push_error("bake_level: %s, so nothing was saved" % problem)
			get_tree().quit(1)
			return
	elif DisplayServer.get_name() == "headless":
		push_warning("bake_level: headless, so no tree visibility was baked")
	else:
		var problem := await _bake_visibility()
		if not problem.is_empty():
			push_error("bake_level: %s, so nothing was saved" % problem)
			get_tree().quit(1)
			return
		if _shards > 1:
			get_tree().quit(0)
			return
	var out := LevelBake.bake_path(path)
	var err := ResourceSaver.save(_bake, out)
	print("bake_level: %s -> %s (%s): heights, frame and trees %d ms, visibility %d ms, %d trees, %d rows, %d bytes" % [path, out, error_string(err),
		t1 - t0, Time.get_ticks_msec() - t1, _bake.tree_count(), _bake.vis_row_count(), FileAccess.get_file_as_bytes(out).size()])
	get_tree().quit(0 if err == OK else 1)


# The lab's method: every tree is drawn in its own colour through its real cut-out, from viewpoints down the road
# (a square view's corners reach past the far plane, so ids further than the draw distance are dropped by position)
# (centre and both verges, two heights, four ways); a tree covering any pixel of one view is visible from that stretch.
func _process(_dt: float) -> void:
	if _last_row_ms > 0 and Time.get_ticks_msec() - _last_row_ms > STALL_S * 1000.0:
		push_error("bake_level: no row finished for %d s; the window is probably hidden or the display asleep. Nothing was saved." % STALL_S)
		get_tree().quit(1)


func _bake_visibility() -> String:
	add_child(_scene)
	var failure := await _calibrate()
	if failure.is_empty():
		failure = await _self_check()
	if not failure.is_empty():
		return failure
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	for _i in SIDES.size() * EYES.size() * 4:
		var vp := SubViewport.new()
		vp.size = Vector2i(VIEW_PX, VIEW_PX)
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		var cam := Camera3D.new()
		cam.fov = 90.0
		cam.near = 0.3
		cam.far = Config.data.level_tree_draw_m
		cam.environment = env
		vp.add_child(cam)
		add_child(vp)
		_views.append(vp)
		_cams.append(cam)
	var n := _bake.tree_count()
	var rows: Array = []
	var row_count := ceili(_bake.sx.size() / float(EVERY))
	var bad := 0
	var impossible := 0
	var edge := 0
	var base := _levels.size()
	var dig := _digit
	var r0 := row_count * _shard / _shards
	var r1 := row_count * (_shard + 1) / _shards
	for r in range(r0, r1):
		_last_row_ms = Time.get_ticks_msec()
		var i := r * EVERY
		_load_window(Vector2(_bake.sx[i], _bake.sz[i]))
		var tangent := _tangent(i)
		var normal := Vector2(-tangent.y, tangent.x)
		var v := 0
		for side: float in SIDES:
			var p := Vector2(_bake.sx[i], _bake.sz[i]) + normal * side * (_bake.sw[i] + SIDE_M)
			for h: float in EYES:
				for k in 4:
					_cams[v].global_transform = Transform3D(Basis(Vector3.UP, k * PI / 2), Vector3(p.x, _bake.height(p.x, p.y) + h, p.y))
					_views[v].render_target_update_mode = SubViewport.UPDATE_ONCE
					v += 1
		await RenderingServer.frame_post_draw
		var seen := {}
		for vp in _views:
			var img := vp.get_texture().get_image()
			img.convert(Image.FORMAT_RGBA8)
			var px := img.get_data().to_int32_array()
			px.sort()
			var j := 0
			while j < px.size():
				var pv := px[j]
				j = px.bsearch(pv + 1)
				if pv & 0xFFFFFF == 0:
					continue
				var d0 := dig[pv & 255]
				var d1 := dig[(pv >> 8) & 255]
				var d2 := dig[(pv >> 16) & 255]
				if d0 < 0 or d1 < 0 or d2 < 0:
					edge += 1
					continue
				var id := d0 + d1 * base + d2 * base * base
				if id > n:
					bad += 1
					continue
				seen[id - 1] = true
		var ids := PackedInt32Array()
		var here := Vector2(_bake.sx[i], _bake.sz[i])
		var reach: float = Config.data.level_tree_draw_m + 50.0
		var corner_reach := Config.data.level_tree_draw_m * sqrt(3.0) + 50.0
		for id: int in seen:
			var far_m := Vector2(_bake.tree_xf[id * 12 + 3], _bake.tree_xf[id * 12 + 11]).distance_to(here)
			if far_m > corner_reach:
				impossible += 1
			if far_m <= reach:
				ids.append(id)
		ids.sort()
		rows.append(ids)
		if (r - r0) % 25 == 0:
			print("bake_level: row %d / %d, %d trees visible" % [r - r0 + 1, r1 - r0, ids.size()])
	if bad > 0:
		return "%d pixels held an impossible tree ID, so the render's colours are not exact" % bad
	if impossible > 0:
		return "%d trees were seen from further away than a view can reach, so the ids are corrupt" % impossible
	print("bake_level: %d edge pixels ignored" % edge)
	if _shards > 1:
		var f := FileAccess.open(_shard_file(_shard), FileAccess.WRITE)
		f.store_var({"rows": rows, "edge": edge})
		f.close()
		return ""
	_bake.set_visibility(EVERY, rows)
	return _bake.visibility_problem(Config.data.level_tree_draw_m + 50.0)


func _shard_file(i: int) -> String:
	return "user://bake_shard_%d.var" % i


# Joins the shards' rows in road order, then applies the same range gate as an unsharded bake.
func _merge_shards() -> String:
	var rows: Array = []
	for i in _shards:
		var f := FileAccess.open(_shard_file(i), FileAccess.READ)
		if f == null:
			return "shard %d left no result" % i
		rows.append_array(f.get_var()["rows"])
		f.close()
	if rows.size() != ceili(_bake.sx.size() / float(EVERY)):
		return "the shards produced %d rows, expected %d" % [rows.size(), ceili(_bake.sx.size() / float(EVERY))]
	_bake.set_visibility(EVERY, rows)
	return _bake.visibility_problem(Config.data.level_tree_draw_m + 50.0)


# One pixel-exact viewport with an orthographic camera, `units` tall and wide.
func _rig(px: Vector2i, units: float) -> SubViewport:
	var vp := SubViewport.new()
	vp.size = px
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var cam := Camera3D.new()
	cam.environment = env
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = units
	cam.position = Vector3(0, 0, 2)
	vp.add_child(cam)
	add_child(vp)
	return vp


# The renderer bends dark colour bytes, so find which bytes of 0-255 come back unchanged and write ids only in those.
func _calibrate() -> String:
	var vp := _rig(Vector2i(8, 8), 2.0)
	var quad := MeshInstance3D.new()
	quad.mesh = QuadMesh.new()
	quad.scale = Vector3(4, 4, 1)
	var mat := ShaderMaterial.new()
	mat.shader = Shader.new()
	mat.shader.code = FLAT_SHADER
	quad.material_override = mat
	vp.add_child(quad)
	_digit.resize(256)
	_digit.fill(-1)
	for b in 256:
		mat.set_shader_parameter("c", Vector3.ONE * (b / 255.0))
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var px := vp.get_texture().get_image().get_pixel(4, 4)
		if roundi(px.r * 255.0) == b and roundi(px.g * 255.0) == b and roundi(px.b * 255.0) == b:
			_digit[b] = _levels.size()
			_levels.append(b)
	vp.queue_free()
	var cap := _levels.size() * _levels.size() * _levels.size()
	print("bake_level: %d exact colour levels, room for %d ids" % [_levels.size(), cap])
	if _levels.is_empty() or _levels[0] != 0 or cap <= _bake.tree_count():
		return "this renderer returns too few colour levels exactly (%d) to number %d trees" % [_levels.size(), _bake.tree_count()]
	return ""


func _tag_colour(tag: int) -> Color:
	var base := _levels.size()
	return Color(_levels[tag % base] / 255.0, _levels[(tag / base) % base] / 255.0, _levels[tag / (base * base)] / 255.0, 1.0)


# Draws known ids through the real ID shader and reads them back; any difference stops the bake.
func _self_check() -> String:
	var ids: Array = STRIP_IDS.duplicate()
	ids.append(_bake.tree_count())
	var vp := _rig(Vector2i(ids.size() * 16, 16), 1.0)
	var img := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	var white := ImageTexture.create_from_image(img)
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://shaders/level_tree_id.gdshader")
	mat.set_shader_parameter("albedo", white)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = QuadMesh.new()
	mm.instance_count = ids.size()
	for i in ids.size():
		mm.set_instance_transform(i, Transform3D(Basis(), Vector3(i + 0.5 - ids.size() / 2.0, 0, 0)))
		mm.set_instance_custom_data(i, _tag_colour(ids[i]))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	vp.add_child(mmi)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var out := vp.get_texture().get_image()
	var base := _levels.size()
	for i in ids.size():
		var c := out.get_pixel(i * 16 + 8, 8)
		var d0 := _digit[roundi(c.r * 255.0)]
		var d1 := _digit[roundi(c.g * 255.0)]
		var d2 := _digit[roundi(c.b * 255.0)]
		var got := d0 + d1 * base + d2 * base * base if d0 >= 0 and d1 >= 0 and d2 >= 0 else -1
		if got != ids[i]:
			return "the id render is not exact: id %d came back as %d" % [ids[i], got]
	vp.queue_free()
	print("bake_level: id render self-check passed")
	return ""


func _tangent(i: int) -> Vector2:
	var s := _bake
	var d := Vector2.RIGHT
	if i + 1 < s.sx.size() and s.sc[i + 1] == s.sc[i]:
		d = Vector2(s.sx[i + 1] - s.sx[i], s.sz[i + 1] - s.sz[i])
	elif i > 0 and s.sc[i - 1] == s.sc[i]:
		d = Vector2(s.sx[i] - s.sx[i - 1], s.sz[i] - s.sz[i - 1])
	return d.normalized() if d.length() > 0.0 else Vector2.RIGHT


# The ground and trees within draw distance (plus a margin) of `centre`, as ID-coloured geometry.
func _load_window(centre: Vector2) -> void:
	if _window.distance_to(centre) < WINDOW_M:
		return
	_window = centre
	for c in _scene.get_children():
		c.free()
	var reach: float = Config.data.level_tree_draw_m + WINDOW_M + 50.0
	var half := _bake.size / 2
	var lo := Vector2(maxf(centre.x - reach, -half), maxf(centre.y - reach, -half))
	var hi := Vector2(minf(centre.x + reach, half), minf(centre.y + reach, half))
	_scene.add_child(_ground(lo, hi))
	var by_kind: Array[PackedFloat32Array] = []
	by_kind.resize(_bake.tree_kinds.size())
	var counts := PackedInt32Array()
	counts.resize(by_kind.size())
	var n := _bake.tree_tile_n
	var t_lo := Vector2i((lo / LevelBake.TREE_TILE_M + Vector2.ONE * n / 2.0).floor())
	var t_hi := Vector2i((hi / LevelBake.TREE_TILE_M + Vector2.ONE * n / 2.0).floor())
	for tz in range(clampi(t_lo.y, 0, n - 1), clampi(t_hi.y, 0, n - 1) + 1):
		for tx in range(clampi(t_lo.x, 0, n - 1), clampi(t_hi.x, 0, n - 1) + 1):
			for id in range(_bake.tree_tile_first[tz * n + tx], _bake.tree_tile_first[tz * n + tx + 1]):
				var k := _bake.tree_kind[id]
				by_kind[k].append_array(_bake.tree_xf.slice(id * 12, id * 12 + 12))
				var c := _tag_colour(id + 1)
				by_kind[k].append_array([c.r, c.g, c.b, 1.0])
				counts[k] += 1
	var card := Foliage._alpha_card_mesh()
	for k in by_kind.size():
		if counts[k] == 0:
			continue
		var mat := ShaderMaterial.new()
		mat.shader = preload("res://shaders/level_tree_id.gdshader")
		mat.set_shader_parameter("albedo", LevelBake.tree_texture(_bake.tree_kinds[k]))
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = card
		mm.instance_count = counts[k]
		mm.buffer = by_kind[k]
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = mat
		mmi.custom_aabb = AABB(Vector3(lo.x, -2000.0, lo.y), Vector3(hi.x - lo.x, 4000.0, hi.y - lo.y))
		_scene.add_child(mmi)


func _ground(lo: Vector2, hi: Vector2) -> MeshInstance3D:
	var cell := _bake.step if _bake.size <= 1000.0 else 3.0
	var nx := ceili((hi.x - lo.x) / cell) + 1
	var nz := ceili((hi.y - lo.y) / cell) + 1
	var verts := PackedVector3Array()
	verts.resize(nx * nz)
	for z in nz:
		for x in nx:
			var px := minf(lo.x + x * cell, hi.x)
			var pz := minf(lo.y + z * cell, hi.y)
			verts[z * nx + x] = Vector3(px, _bake.height(px, pz), pz)
	var idx := PackedInt32Array()
	idx.resize((nx - 1) * (nz - 1) * 6)
	var o := 0
	for z in nz - 1:
		for x in nx - 1:
			var a := z * nx + x
			for q in [a, a + nx, a + 1, a + 1, a + nx, a + nx + 1]:
				idx[o] = q
				o += 1
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color.BLACK
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	return mi
