class_name LevelBake
extends Resource
# Docs: features/level-editor.md — update in the same change as this file.
# Tests: tests/headless/test_level_bake.gd — extend in the same change.
# Everything about a level that is worked out once, offline: final ground heights, the road frame textures the ground shader reads, the road samples, the trees in tiles and which of them each stretch of road can see. Saved beside the level as <name>.bake.res and loaded instead of running LevelData's road build.
# The big arrays live decoded in memory but are stored as zstd blobs (see _get_property_list), and visibility stays as row-to-row diffs.

const BAKE_VERSION := 13
const FRAME_RANGE := 16.0    # across and half-width are stored within this many metres; beyond it there is no road to paint
const FRAME_CELL := 2.0      # road frame texel size in metres
const PATCH_HALF := 8.0      # a gravel patch is stored in the frame as a road this wide whose centre is the patch's inside
const ALONG_PERIOD := 64.0   # along is stored modulo this; the gravel noise repeats at it (level_ground.gdshader)
const TREE_TILE_M := 100.0
const VIS_KEY := 64          # every this many rows the visibility is stored whole, so decoding a row never walks far
const BLOBS := ["z_heights", "z_frame", "z_road", "z_patches", "z_trees", "z_tree_first", "z_tree_kind", "z_vis_add", "z_vis_rem", "z_vis_add_start", "z_vis_rem_start"]
const TREE_HEIGHT := {       # species heights, as in the lab's KINDS table; width comes from each atlas frame's aspect
	"tree.png": 9.375, "tree-greece.webp": 4.0, "tree-taiga.webp": 22.5, "tree-snow.webp": 12.9,
	"tree-snow-laden.webp": 12.4, "levels/trees/sitka_spruce.png": 22.0, "levels/trees/young_spruce.png": 10.0,
	"levels/trees/birch.png": 9.0, "levels/trees/rowan.png": 5.0, "levels/trees/alder.png": 9.0,
	"levels/trees/scrub.png": 1.4, "levels/trees/snow_laden_spruce.png": 18.0, "levels/trees/snowy_young_spruce.png": 7.0,
	"levels/trees/dusted_spruce.png": 20.0, "levels/trees/snow_bowed_birch.png": 6.0,
}

@export var source_key := ""
@export var size := 600.0
@export var step := 1.5
@export var n := 0                       # height samples per side
@export var height_base := 0.0           # heights are uint16 centimetres above this
var heights := PackedByteArray()
@export var frame_n := 0                 # road frame texels per side
var frame := PackedByteArray()   # RGBA8 per texel: across (signed), half-width, along (modulo ALONG_PERIOD), junction weight in the low 4 bits and tarmac weight in the high 4
var sx := PackedFloat32Array()   # road samples, as LevelData's
var sz := PackedFloat32Array()
var sw := PackedFloat32Array()
var sh := PackedFloat32Array()
var sa := PackedFloat32Array()
var sc := PackedInt32Array()
var st := PackedFloat32Array()
var patches: Array[PackedVector2Array] = []
@export var spawn_nodes := PackedVector2Array()  # the first road's first two nodes
@export var tree_kinds := PackedStringArray()    # species, by the index tree_kind holds
@export var tree_tile_n := 0                     # tree tiles per side
var tree_tile_first := PackedInt32Array() # per tile (row * tree_tile_n + column), its first tree; one extra entry ends the last
var tree_kind := PackedByteArray()       # per tree, its species. Trees are numbered tile by tile, then species by species
var tree_xf := PackedFloat32Array()      # per tree, 12 floats in MultiMesh's own layout: the basis rows each followed by the origin
@export var vis_every := 0                       # road samples between viewpoint rows; 0 means no visibility was baked
var vis_add_start := PackedInt32Array()          # per row, where its added trees start in vis_add; one extra entry ends the last
var vis_add := PackedInt32Array()                # trees newly visible from each row compared with the row before (the whole row at a keyframe), ascending
var vis_rem_start := PackedInt32Array()
var vis_rem := PackedInt32Array()                # trees no longer visible from each row

static var last_error := ""
static var baked_in_process := 0
static var progress := 0.0  # 0..1 through the running bake, for a loading screen on another thread

var _road: LevelData
var _cur := PackedInt32Array()   # the decoded visibility of _cur_row
var _cur_row := -2
var _rows := {}  # a few recently decoded rows, since the trees ask for two neighbouring rows in turn for every tile
var _texture: ImageTexture


# The ground cover recipes (coverKinds) and the biome mask aren't baked, so retuning a bush or grass or repainting snow doesn't force a rebake.
static func key_of(save_path: String) -> String:
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(save_path))
	if not d is Dictionary:
		return "%s/v%d" % [FileAccess.get_md5(save_path), BAKE_VERSION]
	(d as Dictionary).erase("coverKinds")
	(d as Dictionary).erase("logPiles")
	(d as Dictionary).erase("fences")
	(d as Dictionary).erase("spectators")
	(d as Dictionary).erase("teleports")
	(d as Dictionary).erase("shops")
	(d as Dictionary).erase("rallies")
	(d as Dictionary).erase("biomeRle")
	return "%s/v%d" % [JSON.stringify(d).md5_text(), BAKE_VERSION]


static func bake_path(save_path: String) -> String:
	return save_path.get_basename() + ".bake.res"


static func bake(data: LevelData, key := "") -> LevelBake:
	baked_in_process += 1
	var b := LevelBake.new()
	b.source_key = key
	b.size = data.size
	b.n = roundi(b.size / b.step) + 1
	var spacing := b.size / (b.n - 1)
	var hs := PackedFloat32Array()
	hs.resize(b.n * b.n)
	for r in b.n:
		progress = 0.5 * r / b.n
		for c in b.n:
			hs[r * b.n + c] = data.ground(c * spacing - b.size / 2, r * spacing - b.size / 2)
	b.height_base = hs[0]
	for h in hs:
		b.height_base = minf(b.height_base, h)
	b.heights.resize(hs.size() * 2)
	for i in hs.size():
		b.heights.encode_u16(i * 2, clampi(roundi((hs[i] - b.height_base) * 100.0), 0, 65535))
	b.frame_n = roundi(b.size / FRAME_CELL) + 1
	b.frame.resize(b.frame_n * b.frame_n * 4)
	var fcell := b.size / (b.frame_n - 1)
	for r in b.frame_n:
		progress = 0.5 + 0.5 * r / b.frame_n
		for c in b.frame_n:
			var x := c * fcell - b.size / 2
			var z := r * fcell - b.size / 2
			var f := data.road_frame(x, z)
			var tarmac := data.nearest(x, z).w
			var pad := data.patch_at(x, z).x
			var on_road := f.x != INF and absf(f.x) <= f.y
			if not on_road and pad < (absf(f.x) - f.y if f.x != INF else INF):
				# off the road and nearer a patch's inside than any road's edge: an even junction-style pad, so the gravel has
				# no direction; the road itself always keeps its own surface
				f = Vector4(maxf(PATCH_HALF + pad, 0.0), PATCH_HALF, 0.0, 1.0)
				tarmac = 0.0
			var across := clampf(f.x if f.x != INF else FRAME_RANGE, -FRAME_RANGE, FRAME_RANGE)
			var o := (r * b.frame_n + c) * 4
			b.frame[o] = roundi((across + FRAME_RANGE) / (2.0 * FRAME_RANGE) * 255.0)
			b.frame[o + 1] = roundi(clampf(f.y, 0.0, FRAME_RANGE) / FRAME_RANGE * 255.0)
			b.frame[o + 2] = roundi(fposmod(f.z, ALONG_PERIOD) / ALONG_PERIOD * 255.0)
			b.frame[o + 3] = roundi(clampf(f.w, 0.0, 1.0) * 15.0) | (roundi(clampf(tarmac, 0.0, 1.0) * 15.0) << 4)
	b.sx = data.sx
	b.sz = data.sz
	b.sw = data.sw
	b.sh = data.sh
	b.sa = data.sa
	b.sc = data.sc
	b.st = data.st
	b.patches = data.patches
	b._bake_trees(data.level.get("trees", []))
	var cs := LevelData.chains(data.level)
	if not cs.is_empty() and cs[0].size() >= 2:
		b.spawn_nodes = PackedVector2Array([Vector2(cs[0][0]["x"], cs[0][0]["z"]), Vector2(cs[0][1]["x"], cs[0][1]["z"])])
	return b


# The baked road for a save (an empty path bakes in memory only): loaded when its key still matches the file's bytes, else baked here on desktop (and saved beside the level), or refused on web, which has no time to bake.
# The saved bake if it matches the save, else null.
static func load_fresh(save_path: String) -> LevelBake:
	if save_path.is_empty():
		return null
	var path := bake_path(save_path)
	if ResourceLoader.exists(path):
		var found := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as LevelBake
		if found != null and found.source_key == key_of(save_path):
			return found
	return null


# `data` must carry the trees (load_save's default) in case the bake has to be made.
static func load_or_bake(save_path: String, data: LevelData) -> LevelBake:
	last_error = ""
	if save_path.is_empty():
		return bake(data)
	var found := load_fresh(save_path)
	if found != null:
		return found
	var key := key_of(save_path)
	var path := bake_path(save_path)
	if OS.has_feature("web"):
		if last_error.is_empty():
			last_error = "The level's bake is missing or out of date. Rebake it with tools/bake_level.gd and rebuild."
		return null
	push_warning("LevelBake: %s is missing or stale, baking in process" % path)
	var b := bake(data, key)
	if ResourceSaver.save(b, path) != OK:
		push_warning("LevelBake: couldn't save %s" % path)
	return b


static func tree_texture(kind: String) -> Texture2D:
	var path := ("res://tools/" if "/" in kind else "res://textures/") + kind
	return load(path) if ResourceLoader.exists(path) else null


func tree_count() -> int:
	return tree_kind.size()


func tree_tile_of(x: float, z: float) -> int:
	var tx := clampi(floori((x + size / 2) / TREE_TILE_M), 0, tree_tile_n - 1)
	var tz := clampi(floori((z + size / 2) / TREE_TILE_M), 0, tree_tile_n - 1)
	return tz * tree_tile_n + tx


# The tile a tree index belongs to.
func tree_tile_at(idx: int) -> int:
	return tree_tile_first.bsearch(idx, false) - 1


# Trees but no visibility: an in-process bake, which draws every tree until tools/bake_level.tscn renders the rest.
func is_incomplete() -> bool:
	return tree_count() > 0 and not has_visibility()


# "" when every row only names real trees and mostly trees within `reach` of its viewpoint, else what is wrong; catches a broken visibility render.
func visibility_problem(reach: float) -> String:
	var trees := tree_count()
	for r in vis_row_count():
		var ids := visible_in(r, -0x7fffffff, 0x7fffffff)
		if ids.is_empty():
			continue
		if ids[0] < 0 or ids[ids.size() - 1] >= trees:
			return "row %d holds a tree id outside 0..%d" % [r, trees - 1]
		var i := r * vis_every
		if i >= sx.size():
			continue
		var far := 0
		for id in ids:
			if Vector2(tree_xf[id * 12 + 3] - sx[i], tree_xf[id * 12 + 11] - sz[i]).length() > reach:
				far += 1
		if far > maxi(2, int(ids.size() / 20.0)):
			return "row %d: %d of its %d trees are beyond %.0f m of its viewpoint" % [r, far, ids.size(), reach]
	return ""


func has_visibility() -> bool:
	return vis_every > 0


func vis_row_count() -> int:
	return maxi(vis_add_start.size() - 1, 0)


# Stores which trees each viewpoint row sees (the visibility render's answer, or a test's); tests inject rows here instead of rendering.
func set_visibility(every: int, rows: Array) -> void:
	vis_every = every
	vis_add_start = PackedInt32Array([0])
	vis_rem_start = PackedInt32Array([0])
	vis_add = PackedInt32Array()
	vis_rem = PackedInt32Array()
	_cur_row = -2
	_rows.clear()
	var prev := PackedInt32Array()
	for r in rows.size():
		var ids := PackedInt32Array(rows[r])
		ids.sort()
		var base := prev if r % VIS_KEY != 0 else PackedInt32Array()
		var i := 0
		var j := 0
		while i < base.size() or j < ids.size():
			if j >= ids.size() or (i < base.size() and base[i] < ids[j]):
				vis_rem.append(base[i])
				i += 1
			elif i >= base.size() or ids[j] < base[i]:
				vis_add.append(ids[j])
				j += 1
			else:
				i += 1
				j += 1
		vis_add_start.append(vis_add.size())
		vis_rem_start.append(vis_rem.size())
		prev = ids


# The trees of `row` numbered in [first, end), ascending.
func visible_in(row: int, first: int, end: int) -> PackedInt32Array:
	if row < 0 or row >= vis_row_count():
		return PackedInt32Array()
	if not _rows.has(row):
		_decode_row(row)
		if _rows.size() >= 4:
			_rows.erase(_rows.keys()[0])
		_rows[row] = _cur
	var ids: PackedInt32Array = _rows[row]
	return ids.slice(ids.bsearch(first), ids.bsearch(end))


func _decode_row(row: int) -> void:
	_cur = decoded_row(row, _cur_row, _cur)
	_cur_row = row


# Every tree `row` sees, decoded without touching shared state so worker threads can call it; pass a row
# already decoded as `from_row`/`from` to step on from it instead of from the row's keyframe.
func decoded_row(row: int, from_row := -2, from := PackedInt32Array()) -> PackedInt32Array:
	if row < 0 or row >= vis_row_count():
		return PackedInt32Array()
	var key := row - row % VIS_KEY
	var r := from_row
	var cur := from
	if r < key or r > row:
		r = key - 1
		cur = PackedInt32Array()
	while r < row:
		r += 1
		cur = _step_row(r, cur if r % VIS_KEY != 0 else PackedInt32Array())
	return cur


func _step_row(r: int, base: PackedInt32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	var j := vis_rem_start[r]
	var je := vis_rem_start[r + 1]
	var k := vis_add_start[r]
	var ke := vis_add_start[r + 1]
	for v in base:
		if j < je and vis_rem[j] == v:
			j += 1
			continue
		while k < ke and vis_add[k] < v:
			out.append(vis_add[k])
			k += 1
		out.append(v)
	while k < ke:
		out.append(vis_add[k])
		k += 1
	return out


func nearest_sample(x: float, z: float) -> int:
	return _roads().nearest_sample(x, z)


# Nearest road point: (distance, road height, half-width, tarmac weight), as LevelData.nearest.
func road_nearest(x: float, z: float) -> Vector4:
	return _roads().nearest(x, z)


func cell() -> float:
	return size / (n - 1)


func grid_height(ix: int, iz: int) -> float:
	return height_base + heights.decode_u16((clampi(iz, 0, n - 1) * n + clampi(ix, 0, n - 1)) * 2) / 100.0


# Bilinear on the baked grid; outside the square the edge heights repeat outwards.
func height(x: float, z: float) -> float:
	var fc := clampf((x + size / 2) / cell(), 0.0, n - 1.0)
	var fr := clampf((z + size / 2) / cell(), 0.0, n - 1.0)
	var c := mini(int(fc), n - 2)
	var r := mini(int(fr), n - 2)
	var u := fc - c
	var v := fr - r
	return lerpf(lerpf(grid_height(c, r), grid_height(c + 1, r), u), lerpf(grid_height(c, r + 1), grid_height(c + 1, r + 1), u), v)


# One road frame texel as LevelData.road_frame returns it, except across and half-width are clamped to FRAME_RANGE, along is modulo ALONG_PERIOD, and all are 8-bit quantised (the junction weight 4-bit).
func frame_texel(ix: int, iz: int) -> Vector4:
	var o := _frame_offset(ix, iz)
	return Vector4(frame[o] / 255.0 * 2.0 * FRAME_RANGE - FRAME_RANGE, frame[o + 1] / 255.0 * FRAME_RANGE,
		frame[o + 2] / 255.0 * ALONG_PERIOD, (frame[o + 3] & 15) / 15.0)


func frame_tarmac(ix: int, iz: int) -> float:
	return (frame[_frame_offset(ix, iz) + 3] >> 4) / 15.0


func _frame_offset(ix: int, iz: int) -> int:
	return (clampi(iz, 0, frame_n - 1) * frame_n + clampi(ix, 0, frame_n - 1)) * 4


func surface_at(x: float, z: float) -> Vector2:
	return _roads().surface_at(x, z)


# Signed metres to the nearest gravel patch's edge (negative inside), INF with none near.
func patch_distance(x: float, z: float) -> float:
	return _roads().patch_at(x, z).x


func spawn_pose(h := Callable()) -> Transform3D:
	var hf := h if h.is_valid() else height
	if spawn_nodes.size() < 2:
		return Transform3D(Basis(), Vector3(0, hf.call(0.0, 0.0) + 1.0, 0))
	var a := Vector3(spawn_nodes[0].x, 0, spawn_nodes[0].y)
	var b := Vector3(spawn_nodes[1].x, 0, spawn_nodes[1].y)
	a.y = hf.call(a.x, a.z) + 1.0
	return Transform3D(Basis.looking_at((b - a) * Vector3(1, 0, 1)), a)


func road_pose(p: Vector2, facing: Vector3, h := Callable()) -> Transform3D:
	if sx.size() < 2:
		return spawn_pose(h)
	return _roads().road_pose(p, facing, h if h.is_valid() else height)


func apply_to(mat: ShaderMaterial) -> void:
	_texture = ImageTexture.create_from_image(Image.create_from_data(frame_n, frame_n, false, Image.FORMAT_RGBA8, frame))
	mat.set_shader_parameter("road_frame", _texture)
	mat.set_shader_parameter("frame_size_m", size)
	mat.set_shader_parameter("frame_cell_m", size / (frame_n - 1))
	mat.set_shader_parameter("frame_n", frame_n)


func _bake_trees(trees: Array) -> void:
	tree_tile_n = ceili(size / TREE_TILE_M)
	var slot := {}
	var aspect: Array[float] = []
	var groups := {}  # tile * 256 + species -> the saved trees in it
	for t: Dictionary in trees:
		var kind: String = t["kind"]
		if not slot.has(kind):
			slot[kind] = tree_kinds.size()
			tree_kinds.append(kind)
			var tex := tree_texture(kind)
			aspect.append(tex.get_width() / 6.0 / tex.get_height() if tex != null else 1.0)
		var key: int = tree_tile_of(t["x"], t["z"]) * 256 + int(slot[kind])
		if not groups.has(key):
			groups[key] = []
		groups[key].append(t)
	var keys := groups.keys()
	keys.sort()
	var counts := PackedInt32Array()
	counts.resize(tree_tile_n * tree_tile_n)
	for key: int in keys:
		var kind_i := key & 255
		var h0: float = TREE_HEIGHT.get(tree_kinds[kind_i], 8.0)
		for t: Dictionary in groups[key]:
			var h: float = h0 * t["sy"]
			var w: float = h0 * aspect[kind_i] * t["sx"]
			var bs := Basis(Vector3.UP, deg_to_rad(t["rot"])).scaled(Vector3(w, h, w))
			var o := Vector3(t["x"], height(t["x"], t["z"]) - 0.2, t["z"])
			tree_xf.append_array([bs.x.x, bs.y.x, bs.z.x, o.x, bs.x.y, bs.y.y, bs.z.y, o.y, bs.x.z, bs.y.z, bs.z.z, o.z])
			tree_kind.append(kind_i)
		counts[key >> 8] += groups[key].size()
	tree_tile_first.resize(counts.size() + 1)
	for i in counts.size():
		tree_tile_first[i + 1] = tree_tile_first[i] + counts[i]


func _roads() -> LevelData:
	if _road == null:
		_road = LevelData.new()
		_road.sx = sx
		_road.sz = sz
		_road.sw = sw
		_road.sh = sh
		_road.sa = sa
		_road.sc = sc
		_road.st = st
		_road.patches = patches
		_road.bucket_patches()
		_road.bucket_samples()
	return _road


static func _zip(raw: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u32(0, raw.size())
	if not raw.is_empty():
		out.append_array(raw.compress(FileAccess.COMPRESSION_ZSTD))
	return out


static func _unzip(z: PackedByteArray) -> PackedByteArray:
	var raw_size := z.decode_u32(0) if z.size() >= 4 else 0
	return z.slice(4).decompress(raw_size, FileAccess.COMPRESSION_ZSTD) if raw_size > 0 else PackedByteArray()


# Differences between neighbours with each byte of them in its own plane: smooth data turns into long runs of zeros that zstd squeezes.
static func _zip_ints(a: PackedInt32Array) -> PackedByteArray:
	var count := a.size()
	var raw := PackedByteArray()
	raw.resize(count * 4)
	var prev := 0
	for i in count:
		var d := (a[i] - prev) & 0xFFFFFFFF
		prev = a[i]
		raw[i] = d & 255
		raw[count + i] = (d >> 8) & 255
		raw[count * 2 + i] = (d >> 16) & 255
		raw[count * 3 + i] = (d >> 24) & 255
	return _zip(raw)


static func _unzip_ints(z: PackedByteArray) -> PackedInt32Array:
	var raw := _unzip(z)
	var count := raw.size() >> 2
	var a := PackedInt32Array()
	a.resize(count)
	var acc := 0
	for i in count:
		acc = (acc + (raw[i] | raw[count + i] << 8 | raw[count * 2 + i] << 16 | raw[count * 3 + i] << 24)) & 0xFFFFFFFF
		a[i] = acc if acc < 0x80000000 else acc - 0x100000000
	return a


func _zip_heights() -> PackedByteArray:
	var count := heights.size() >> 1
	var raw := PackedByteArray()
	raw.resize(count * 2)
	var prev := 0
	for i in count:
		var v := heights.decode_u16(i * 2)
		var d := (v - prev) & 0xFFFF
		prev = v
		raw[i] = d & 255
		raw[count + i] = d >> 8
	return _zip(raw)


func _unzip_heights(z: PackedByteArray) -> void:
	var raw := _unzip(z)
	var count := raw.size() >> 1
	heights.resize(count * 2)
	var acc := 0
	for i in count:
		acc = (acc + (raw[i] | raw[count + i] << 8)) & 0xFFFF
		heights.encode_u16(i * 2, acc)


func _get_property_list() -> Array:
	var list := []
	for name: String in BLOBS:
		list.append({"name": name, "type": TYPE_PACKED_BYTE_ARRAY, "usage": PROPERTY_USAGE_STORAGE})
	return list


func _get(property: StringName) -> Variant:
	match property:
		&"z_heights": return _zip_heights()
		&"z_frame": return _zip(frame)
		&"z_road":
			var raw := PackedByteArray()
			raw.append_array(sx.to_byte_array())
			raw.append_array(sz.to_byte_array())
			raw.append_array(sw.to_byte_array())
			raw.append_array(sh.to_byte_array())
			raw.append_array(sa.to_byte_array())
			raw.append_array(sc.to_byte_array())
			raw.append_array(st.to_byte_array())
			return _zip(raw)
		&"z_patches":
			var flat := PackedFloat32Array()
			for poly in patches:
				flat.append(poly.size())
				for q in poly:
					flat.append_array([q.x, q.y])
			return _zip(flat.to_byte_array())
		&"z_trees": return _zip(tree_xf.to_byte_array())
		&"z_tree_first": return _zip_ints(tree_tile_first)
		&"z_tree_kind": return _zip(tree_kind)
		&"z_vis_add": return _zip_ints(vis_add)
		&"z_vis_rem": return _zip_ints(vis_rem)
		&"z_vis_add_start": return _zip_ints(vis_add_start)
		&"z_vis_rem_start": return _zip_ints(vis_rem_start)
	return null


func _set(property: StringName, value: Variant) -> bool:
	match property:
		&"z_heights": _unzip_heights(value)
		&"z_frame": frame = _unzip(value)
		&"z_road":
			var raw := _unzip(value)
			var count := int(raw.size() / 28.0)
			sx = raw.slice(0, count * 4).to_float32_array()
			sz = raw.slice(count * 4, count * 8).to_float32_array()
			sw = raw.slice(count * 8, count * 12).to_float32_array()
			sh = raw.slice(count * 12, count * 16).to_float32_array()
			sa = raw.slice(count * 16, count * 20).to_float32_array()
			sc = raw.slice(count * 20, count * 24).to_int32_array()
			st = raw.slice(count * 24, count * 28).to_float32_array()
		&"z_patches":
			var flat := _unzip(value).to_float32_array()
			patches.clear()
			var i := 0
			while i < flat.size():
				var points := int(flat[i])
				var poly := PackedVector2Array()
				for k in points:
					poly.append(Vector2(flat[i + 1 + k * 2], flat[i + 2 + k * 2]))
				patches.append(poly)
				i += 1 + points * 2
		&"z_trees": tree_xf = _unzip(value).to_float32_array()
		&"z_tree_first": tree_tile_first = _unzip_ints(value)
		&"z_tree_kind": tree_kind = _unzip(value)
		&"z_vis_add": vis_add = _unzip_ints(value)
		&"z_vis_rem": vis_rem = _unzip_ints(value)
		&"z_vis_add_start": vis_add_start = _unzip_ints(value)
		&"z_vis_rem_start": vis_rem_start = _unzip_ints(value)
		_: return false
	return true
