class_name LevelTrees
extends Node3D
# The level's trees, drawn from the bake: one MultiMesh of star-tree cards per tile (up to KINDS_PER_DRAW species in one; the
# shader picks each card's texture and tint from INSTANCE_CUSTOM.r), repacked to what the camera's stretch of road can see, with collision boxes only on tiles near the car.

const SHADER := preload("res://shaders/level_tree.gdshader")
const KIND_TINT := {
	"levels/trees/sitka_spruce.png": Color(0.3, 0.38, 0.32), "levels/trees/young_spruce.png": Color(0.34, 0.42, 0.34),
	"levels/trees/birch.png": Color(0.82, 0.86, 0.72), "levels/trees/rowan.png": Color(0.82, 0.86, 0.72),
	"levels/trees/alder.png": Color(0.8, 0.86, 0.72), "levels/trees/scrub.png": Color(0.8, 0.85, 0.72),
}
const REPACKS_PER_FRAME := 3
# Species one MultiMesh can draw: level_tree.gdshader's albedo0..5. A sampler each, so kept well under WebGL2's 16 texture units.
const KINDS_PER_DRAW := 6
const STRIDE := 16  # floats per instance: the 12 of a TRANSFORM_3D, then INSTANCE_CUSTOM (r = the species' slot in the material)
const MAX_TREE_HEIGHT := 40.0


# The node a tile's collision body sits under; the car calls it, with the box's shape index, to fell a tree.
class Hitboxes extends Node3D:
	var trees: LevelTrees
	var first := 0
	var body: StaticBody3D
	var shape: BoxShape3D

	func size_factor(shape_idx: int) -> float:
		return trees.size_factor(first + shape_idx)

	func knock_down(shape_idx: int, dir: Vector3, duration: float) -> void:
		trees.knock_down(first + shape_idx, dir, duration)


class Tile:
	var index := 0
	var first := 0
	var end := 0
	var rect := Rect2()
	var mmis: Array[MultiMeshInstance3D] = []
	var run_end := PackedInt32Array()  # per MultiMesh, where its trees stop; its trees run from the previous one's end
	var slots: Array[PackedInt32Array] = []  # per MultiMesh, each species' slot in its material (-1: not in it)
	var shown_row := -2
	var hit: Hitboxes

var bake: LevelBake
var _card := Foliage._alpha_card_mesh()
var _textures: Array[Texture2D] = []  # per species
var _tints := PackedColorArray()  # per species
var _materials := {}  # "kind,kind,..." -> the ShaderMaterial drawing those species in that slot order
var _tiles := {}   # tile index -> Tile, made when the camera or car first comes near
var _fallen := {}  # tree -> true; kept for good, so a tile built again still has its felled trees down
var _fall_pose := {}  # tree -> where it lies, from the first moment it falls
var _falling: Array = []
var _dirty := {}   # tiles that need repacking whatever the row
var _queue: Array[int] = []
var _row := -2
var _cam_cell := Vector2i(-100000, -100000)
var _draw_override := 0.0  # photo mode's render: a longer draw distance for a few seconds (0: GameConfig's)


func setup(p_bake: LevelBake) -> void:
	bake = p_bake
	for kind in bake.tree_kinds:
		_tints.append(KIND_TINT.get(kind, Color(0.85, 0.85, 0.85)))
		_textures.append(LevelBake.tree_texture(kind))


# The material for one MultiMesh's species, slot i drawing kinds[i]; shared by every tile with the same species.
func _material_for(kinds: PackedInt32Array) -> ShaderMaterial:
	var key := ",".join(Array(kinds).map(func(k: int) -> String: return str(k)))
	if _materials.has(key):
		return _materials[key]
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter("base_dark", Config.data.level_ao_tree_base)
	mat.set_shader_parameter("base_height", Config.data.level_ao_tree_base_height)
	var tints: Array[Color] = []
	for slot in KINDS_PER_DRAW:
		tints.append(_tints[kinds[slot]] if slot < kinds.size() else Color.WHITE)
		if slot < kinds.size() and _textures[kinds[slot]] != null:
			mat.set_shader_parameter("albedo%d" % slot, _textures[kinds[slot]])
	mat.set_shader_parameter("tints", tints)
	_materials[key] = mat
	return mat


# Called every frame with the camera and the car: follows the viewpoint row, spreads the repacking over frames, and gives the car its nearby collision.
# `free_view` (photo mode, the camera anywhere) skips the baked road visibility and shows every tree in reach.
func update(cam_pos: Vector3, car_pos: Vector3, free_view := false) -> void:
	var row := bake.nearest_sample(cam_pos.x, cam_pos.z) / bake.vis_every if bake.has_visibility() and not free_view else -1
	var cell := Vector2i(floori(cam_pos.x / LevelBake.TREE_TILE_M), floori(cam_pos.z / LevelBake.TREE_TILE_M))
	if row != _row or cell != _cam_cell:
		_row = row
		_cam_cell = cell
		_queue_tiles_near(cam_pos)
	_update_collision(car_pos)
	_pump(REPACKS_PER_FRAME)


# How far trees are drawn: GameConfig.level_tree_draw_m, or the render override while it is set.
func draw_m() -> float:
	return _draw_override if _draw_override > 0.0 else float(Config.data.level_tree_draw_m)


# Draw trees out to `metres` (photo mode's render); 0 goes back to the configured distance. Every built
# tile takes the new range at once, and the next update queues whatever newly falls within it.
func set_draw_override(metres: float) -> void:
	_draw_override = metres
	for t: Tile in _tiles.values():
		for mmi in t.mmis:
			mmi.visibility_range_end = draw_m() + LevelBake.TREE_TILE_M
	_cam_cell = Vector2i(-100000, -100000)


# Repacks everything still waiting, at once; for the first frame and for tests.
func settle() -> void:
	_pump(1 << 30)


func tile(i: int) -> Tile:
	return _tiles.get(i)


func drawn_count() -> int:
	var n := 0
	for t: Tile in _tiles.values():
		for mmi in t.mmis:
			n += mmi.multimesh.visible_instance_count
	return n


# How big tree `idx` is for felling (TreeFall): 1 at level_tree_full_height_m and above.
func size_factor(idx: int) -> float:
	if idx < 0 or idx >= bake.tree_count():
		return 1.0
	return clampf(bake.tree_xf[idx * 12 + 5] / Config.data.level_tree_full_height_m, 0.0, 1.0)


# The car felled tree `idx`: its hitbox goes at once and the card topples along `dir`.
func knock_down(idx: int, dir: Vector3, duration: float) -> void:
	if idx < 0 or idx >= bake.tree_count() or _fallen.has(idx):
		return
	var t: Tile = _tiles.get(bake.tree_tile_at(idx))
	if t != null and t.hit != null:
		PhysicsServer3D.body_set_shape_disabled(t.hit.body.get_rid(), idx - t.first, true)
	_fallen[idx] = true
	var up := _standing(idx)
	_fall_pose[idx] = up
	_falling.append({"id": idx, "up": up, "axis": TreeFall.topple_axis(dir), "t": 0.0, "dur": maxf(duration, 0.0)})


func is_fallen(idx: int) -> bool:
	return _fallen.has(idx)


func _process(dt: float) -> void:
	if not _falling.is_empty():
		_step_falls(dt)


func _step_falls(dt: float) -> void:
	for rec: Dictionary in _falling:
		rec["t"] += dt
		var up: Transform3D = rec["up"]
		var id: int = rec["id"]
		_fall_pose[id] = Transform3D(Basis(rec["axis"], TreeFall.fall_angle(rec["t"], rec["dur"])) * up.basis, up.origin)
		_dirty[bake.tree_tile_at(id)] = true
	_falling = _falling.filter(func(r: Dictionary) -> bool: return r["t"] < r["dur"])


func _standing(idx: int) -> Transform3D:
	var f := bake.tree_xf
	var k := idx * 12
	return Transform3D(Basis(Vector3(f[k], f[k + 4], f[k + 8]), Vector3(f[k + 1], f[k + 5], f[k + 9]),
		Vector3(f[k + 2], f[k + 6], f[k + 10])), Vector3(f[k + 3], f[k + 7], f[k + 11]))


func _tile_cells_near(p: Vector3, reach: float) -> Array[int]:
	var out: Array[int] = []
	var n := bake.tree_tile_n
	var half := bake.size / 2
	var lo := Vector2i(clampi(floori((p.x - reach + half) / LevelBake.TREE_TILE_M), 0, n - 1), clampi(floori((p.z - reach + half) / LevelBake.TREE_TILE_M), 0, n - 1))
	var hi := Vector2i(clampi(floori((p.x + reach + half) / LevelBake.TREE_TILE_M), 0, n - 1), clampi(floori((p.z + reach + half) / LevelBake.TREE_TILE_M), 0, n - 1))
	for tz in range(lo.y, hi.y + 1):
		for tx in range(lo.x, hi.x + 1):
			out.append(tz * n + tx)
	return out


func _distance_to(t: Tile, p: Vector3) -> float:
	var dx := maxf(maxf(t.rect.position.x - p.x, p.x - t.rect.end.x), 0.0)
	var dz := maxf(maxf(t.rect.position.y - p.z, p.z - t.rect.end.y), 0.0)
	return Vector2(dx, dz).length()


func _queue_tiles_near(cam_pos: Vector3) -> void:
	var draw := draw_m()
	var found: Array[Tile] = []
	for i in _tile_cells_near(cam_pos, draw + LevelBake.TREE_TILE_M):
		var t := _tile_or_make(i)
		if t != null and _distance_to(t, cam_pos) <= draw + LevelBake.TREE_TILE_M and t.shown_row != _row:
			found.append(t)
	found.sort_custom(func(a: Tile, b: Tile) -> bool: return _distance_to(a, cam_pos) > _distance_to(b, cam_pos))
	_queue.clear()
	for t in found:
		_queue.append(t.index)


func _pump(budget: int) -> void:
	while budget > 0 and not _dirty.is_empty():
		var i: int = _dirty.keys()[0]
		_dirty.erase(i)
		if _tiles.has(i):
			_repack(_tiles[i])
		budget -= 1
	while budget > 0 and not _queue.is_empty():
		var t: Tile = _tiles[_queue.pop_back()]
		if t.shown_row != _row:
			_repack(t)
		budget -= 1


# Shows exactly the trees the two viewpoint rows round the camera's stretch of road can see (every tree if no visibility was baked), packed to the front of each MultiMesh.
func _repack(t: Tile) -> void:
	var ids := PackedInt32Array()
	if bake.has_visibility() and _row >= 0:
		ids = _union(bake.visible_in(_row, t.first, t.end), bake.visible_in(_row + 1, t.first, t.end))
	else:
		ids = PackedInt32Array(range(t.first, t.end))
	var bufs: Array[PackedFloat32Array] = []
	var counts := PackedInt32Array()
	for _r in t.mmis.size():
		bufs.append(PackedFloat32Array())
		counts.append(0)
	var run := 0
	var custom := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	for id in ids:
		while id >= t.run_end[run]:
			run += 1
		bufs[run].append_array(_pose_floats(id))
		custom[0] = t.slots[run][bake.tree_kind[id]]
		bufs[run].append_array(custom)
		counts[run] += 1
	var from := t.first
	for r in t.mmis.size():
		bufs[r].resize((t.run_end[r] - from) * STRIDE)
		t.mmis[r].multimesh.buffer = bufs[r]
		t.mmis[r].multimesh.visible_instance_count = counts[r]
		t.mmis[r].visible = counts[r] > 0
		from = t.run_end[r]
	t.shown_row = _row


func _pose_floats(id: int) -> PackedFloat32Array:
	if not _fall_pose.has(id):
		return bake.tree_xf.slice(id * 12, id * 12 + 12)
	var x: Transform3D = _fall_pose[id]
	var b := x.basis
	return PackedFloat32Array([b.x.x, b.y.x, b.z.x, x.origin.x, b.x.y, b.y.y, b.z.y, x.origin.y, b.x.z, b.y.z, b.z.z, x.origin.z])


func _union(a: PackedInt32Array, b: PackedInt32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	var i := 0
	var j := 0
	while i < a.size() or j < b.size():
		var v := a[i] if j >= b.size() or (i < a.size() and a[i] <= b[j]) else b[j]
		if (i < a.size() and a[i] == v):
			i += 1
		if (j < b.size() and b[j] == v):
			j += 1
		out.append(v)
	return out


func _tile_or_make(i: int) -> Tile:
	if _tiles.has(i):
		return _tiles[i]
	var first := bake.tree_tile_first[i]
	var end := bake.tree_tile_first[i + 1]
	if first == end:
		return null
	var t := Tile.new()
	t.index = i
	t.first = first
	t.end = end
	var n := bake.tree_tile_n
	var origin := Vector2((i % n) * LevelBake.TREE_TILE_M - bake.size / 2, (i / n) * LevelBake.TREE_TILE_M - bake.size / 2)
	t.rect = Rect2(origin, Vector2.ONE * LevelBake.TREE_TILE_M)
	var low := INF
	var high := -INF
	for id in range(first, end):
		low = minf(low, bake.tree_xf[id * 12 + 7])
		high = maxf(high, bake.tree_xf[id * 12 + 7])
	var aabb := AABB(Vector3(origin.x, low - 1.0, origin.y), Vector3(LevelBake.TREE_TILE_M, high - low + MAX_TREE_HEIGHT, LevelBake.TREE_TILE_M))
	# The tile's trees run species by species; each MultiMesh takes the next KINDS_PER_DRAW species' runs.
	var from := first
	while from < end:
		var kinds := PackedInt32Array()
		var slots := PackedInt32Array()
		slots.resize(bake.tree_kinds.size())
		slots.fill(-1)
		var to := from
		while to < end and (slots[bake.tree_kind[to]] >= 0 or kinds.size() < KINDS_PER_DRAW):
			if slots[bake.tree_kind[to]] < 0:
				slots[bake.tree_kind[to]] = kinds.size()
				kinds.append(bake.tree_kind[to])
			to += 1
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = _card
		mm.instance_count = to - from  # filled by _repack before anything is shown
		mm.visible_instance_count = 0
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Trees_%d_%d" % [i, t.mmis.size()]
		mmi.multimesh = mm
		mmi.material_override = _material_for(kinds)
		mmi.custom_aabb = aabb
		mmi.visibility_range_end = draw_m() + LevelBake.TREE_TILE_M
		add_child(mmi)
		t.mmis.append(mmi)
		t.run_end.append(to)
		t.slots.append(slots)
		from = to
	_tiles[i] = t
	return t


# Collision exists only on tiles within level_tree_collision_m of the car, and goes once the car is twice as far; one tile is built per frame.
func _update_collision(car_pos: Vector3) -> void:
	var near: float = Config.data.level_tree_collision_m
	for t: Tile in _tiles.values():
		if t.hit != null and _distance_to(t, car_pos) > near * 2.0:
			t.hit.free()
			t.hit = null
	for i in _tile_cells_near(car_pos, near):
		var t := _tile_or_make(i)
		if t != null and t.hit == null and _distance_to(t, car_pos) <= near:
			if t.shown_row != _row:
				_repack(t)
			_build_hitboxes(t)
			return


func _build_hitboxes(t: Tile) -> void:
	var cfg: GameConfig = Config.data
	var ground := PackedVector3Array()
	for id in range(t.first, t.end):
		ground.append(Vector3(bake.tree_xf[id * 12 + 3], bake.tree_xf[id * 12 + 7] + 0.2, bake.tree_xf[id * 12 + 11]))
	var h := Hitboxes.new()
	h.name = "Hit_%d" % t.index
	h.trees = self
	h.first = t.first
	add_child(h)
	h.shape = ObstacleBody.build(h, ground, cfg.tree_collision_radius_m, cfg.tree_collision_height_m)
	h.body = h.get_node("Collision")
	for id in range(t.first, t.end):
		if _fallen.has(id):
			PhysicsServer3D.body_set_shape_disabled(h.body.get_rid(), id - t.first, true)
	t.hit = h
