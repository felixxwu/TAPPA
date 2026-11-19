class_name LevelView
extends Node3D
# Docs: features/level-editor.md — update in the same change as this file.
# Tests: tests/headless/test_level_view.gd — extend in the same change.
# A level saved by tools/level_editor_lab.html, built as drivable ground: the lab's terrain and road
# rebuilt at a finer grid with collision, its trees as the game's 6-card stars, and the car parked on
# the road's first node. A dev stand-in for free roam (GameConfig.dev_level_instead_of_free_roam).
# If the lab baked which trees are visible from along the road, only those near the camera's stretch are drawn.

const SIZE := 600.0     # the lab's square, metres, centred on the origin
const LAB_N := 200      # the lab's height grid has (LAB_N+1)² samples
const FALLOFF := 1.0    # how far beyond the road's edge the ground blends back to its own height
const BUCKET := 20.0
const TREE_SHADER := preload("res://shaders/level_tree.gdshader")
# Species heights, as in the lab's KINDS table; width comes from each atlas frame's aspect.
const KIND_HEIGHT := {
	"tree.png": 9.375, "tree-greece.webp": 4.0, "tree-taiga.webp": 22.5, "tree-snow.webp": 12.9,
	"tree-snow-laden.webp": 12.4, "levels/trees/sitka_spruce.png": 22.0, "levels/trees/young_spruce.png": 10.0,
	"levels/trees/birch.png": 9.0, "levels/trees/rowan.png": 5.0, "levels/trees/alder.png": 9.0,
	"levels/trees/scrub.png": 1.4,
}

const KIND_TINT := {
	"levels/trees/sitka_spruce.png": Color(0.3, 0.38, 0.32), "levels/trees/young_spruce.png": Color(0.34, 0.42, 0.34),
	"levels/trees/birch.png": Color(0.82, 0.86, 0.72), "levels/trees/rowan.png": Color(0.82, 0.86, 0.72),
	"levels/trees/alder.png": Color(0.8, 0.86, 0.72), "levels/trees/scrub.png": Color(0.8, 0.85, 0.72),
}

@export var level_path := ""
@export var material: Material  # the ground shader (level_ground.gdshader)
var grid_step := 1.5            # this mesh's grid spacing, metres

var level: Dictionary
var _hm := PackedFloat32Array()
var _sx := PackedFloat32Array()  # road samples: x, z, half-width, height
var _sz := PackedFloat32Array()
var _sw := PackedFloat32Array()
var _sh := PackedFloat32Array()
var _sa := PackedFloat32Array()  # metres along the road to each sample
var _buckets := {}
var _cols := 0
var _g := PackedFloat32Array()   # ground heights on this grid, row-major from -SIZE/2
var _rows: Array[PackedInt32Array] = []  # the lab's bake: per viewpoint row, the tree indices visible from it
var _every := 1                          # road samples between viewpoint rows
var _mms: Array[MultiMesh] = []          # one per species
var _full: Array[PackedFloat32Array] = []  # each species' every-tree transform buffer
var _tree_mm := PackedInt32Array()       # per tree: which species MultiMesh, and its instance in it
var _tree_inst := PackedInt32Array()
var _mark := PackedByteArray()
var _shown_row := -1
var _cover: GroundCover
var _car: VehicleBody3D
var _particles: WeatherField
var _recovery: RoadRecovery
var _pause: Node
var applied_fps_caps: Array[int] = []
var _tree_h := PackedFloat32Array()  # per tree: its height, which sets how easily the car fells it
var _tree_shape: BoxShape3D  # kept alive for the trees' hitboxes
var _fallen := {}
var _falling: Array = []


func _ready() -> void:
	var path := level_path if not level_path.is_empty() else Config.data.dev_level_path
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		push_error("LevelView: couldn't read %s" % path)
		return
	WorldRuntime.apply_fps_cap(applied_fps_caps, WorldRuntime.loading_cap(Platform.is_touch()), Platform.is_headless())
	var t0 := Time.get_ticks_msec()
	load_level(parsed)
	print("level view: %s built in %d ms" % [path, Time.get_ticks_msec() - t0])
	var env := get_parent().get_node_or_null("WorldEnvironment") as WorldEnvironment
	if env != null:
		env.environment.fog_density = Config.data.fog_density  # free roam's biome director normally sets this
	var car := get_parent().get_node_or_null("Car") as VehicleBody3D
	if car == null:
		return
	if not car.is_node_ready():
		await car.ready  # this node sits before the car, so builds first and fields the car once it exists
	if WorldSession.has_world():
		car.apply_owned(LootRules.fielded(WorldSession.active_car()))
		get_parent().get_node("CameraManager").refresh_bonnet_offset()
	car.damage.invulnerable = true
	car.reset_to(spawn_pose())
	_pause = get_parent().get_node_or_null("PauseMenu")
	await get_tree().process_frame  # the parent is still adding its children
	var marks := _add_effects(car)
	_recovery = RoadRecovery.new()
	_recovery.name = "RoadRecovery"
	_recovery.car = car
	_recovery.streamer = self
	get_parent().add_child(_recovery)
	_recovery.reset_done.connect(func(_p: Vector2) -> void: marks.break_ribbons())
	if _pause != null:
		_pause.reset_to_track_requested.connect(_recovery.reset_now)
	if not Platform.is_headless():  # nothing renders, so there is nothing to compile
		await _warm_up(car)
	WorldRuntime.apply_fps_cap(applied_fps_caps, FpsSetting.resolve(), Platform.is_headless())
	if _pause != null:
		_pause.set_input_enabled(true)  # the menu stays inert until its world says it has finished loading


func _unhandled_input(event: InputEvent) -> void:
	if _recovery != null and _pause != null and event.is_action_pressed("reset_to_road") and not event.is_echo() and _pause.is_armed():
		_recovery.reset_now()


# Where RoadRecovery puts the car: the nearest road point to `p`, facing along the road the way nearest `facing`.
func road_pose(p: Vector2, facing: Vector3) -> Transform3D:
	if _sx.size() < 2:
		return spawn_pose()
	var i := _nearest_sample(p.x, p.y)
	var a := Vector2(_sx[i], _sz[i])
	var ab := Vector2(_sx[i + 1], _sz[i + 1]) - a
	var q := a + ab * clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-9), 0.0, 1.0)
	var dir := Vector3(ab.x, 0.0, ab.y).normalized()
	if dir.dot(facing) < 0.0:
		dir = -dir
	return Transform3D(Basis.looking_at(dir, Vector3.UP), Vector3(q.x, height_at(q.x, q.y) + 1.0, q.y))


# Free roam's driving effects, set up the way free_roam.gd does; returns the tyre marks.
func _add_effects(car: VehicleBody3D) -> TireMarks:
	var look := RegionLibrary.look_of("home")
	var wheels := WheelParticles.new()
	wheels.name = "WheelParticles"
	get_parent().add_child(wheels)
	wheels.setup(car)
	wheels.apply_region_look(look)
	var dust := DustPuffs.new()
	dust.name = "DustPuffs"
	get_parent().add_child(dust)
	dust.setup(car)
	dust.apply_region_look(look)
	var smoke := EngineSmoke.new()
	smoke.name = "EngineSmoke"
	get_parent().add_child(smoke)
	smoke.setup(car)
	var marks := TireMarks.new()
	marks.name = "TireMarks"
	get_parent().add_child(marks)
	marks.setup(null, car, self, 0.0)  # no centreline: the marks follow surface_at's road weight, not a width
	var flames := ExhaustFlames.new()
	flames.name = "ExhaustFlames"
	get_parent().add_child(flames)
	flames.setup(car)
	var lamps := CarLamps.new()
	lamps.name = "CarLamps"
	get_parent().add_child(lamps)
	lamps.setup(car)
	_car = car
	_add_bush_fields(car)
	apply_weather(Config.data.dev_level_weather)
	return marks


# Brushing a ground-cover bush drags the car, as free roam's bushes do (BushField); one field per bush layer.
func _add_bush_fields(car: VehicleBody3D) -> void:
	if _cover == null:
		return
	var cfg: GameConfig = Config.data
	for spots: Array in GroundCover.bush_spots(_cover.cover, _cover.size, _cover.kinds):
		var field := BushField.new()
		field.name = "BushInteraction"
		add_child(field)
		field.setup(spots[0], car, float(spots[1]) * cfg.bush_hit_radius_frac, cfg.bush_drag_strength,
			cfg.bush_drag_torque, cfg.bush_min_speed_kmh / DamageModel.MPS_TO_KMH)


# The weather's particles on the chase camera and its wind; no road tint or environment look.
func apply_weather(id: String) -> void:
	var cfg: GameConfig = Config.data
	cfg.weather = id
	WindSway.push(cfg, id)
	if is_instance_valid(_particles):
		_particles.queue_free()
	_particles = null
	var entry := WeatherLibrary.by_id(id)
	var kind := String(entry.get("particles", ""))
	var cam := get_parent().get_node_or_null("ChaseCamera") as Camera3D
	if kind != "" and cam != null:
		var wind_field := String(entry.get("wind_dir", ""))
		var speed_field := String(entry.get("particle_speed", ""))
		_particles = WeatherField.spawn(cam, kind, int(cfg.get(String(entry["particle_count"]))),
			float(cfg.get(wind_field)) if wind_field != "" else 0.0,
			float(cfg.get(speed_field)) if speed_field != "" else 0.0)
	if HeadlightCone.has_headlights(cfg):
		set_process(true)
	else:
		HeadlightCone.reset()


# Compiles every effect's first-use shader (and each weather's particles) before the car can be driven.
func _warm_up(car: VehicleBody3D) -> void:
	var cover := get_tree().get_first_node_in_group("loading_screen") as LoadingScreen
	if cover == null and not Platform.is_headless():
		cover = LoadingScreen.new()
		add_child(cover)
	if cover != null:
		cover.set_title("Warming shaders…")
	car.controls_locked = true
	var cam := get_viewport().get_camera_3d()
	var point := WorldRuntime.warm_up_point(cam, car.global_position)
	var warmers := get_parent().find_children("*", "Node", true, false).filter(
		func(n: Node) -> bool: return n.has_method("warm_up") and n.has_method("clear_warm_up"))
	var fields: Array[Node] = []
	var kinds := {}
	for entry in WeatherLibrary.CONDITIONS:
		kinds[String(entry.get("particles", ""))] = true
	for kind: String in kinds:
		var field := WeatherField.spawn(cam, kind, 64, 0.0) if cam != null else null
		if field != null:
			fields.append(field)
	for n in warmers:
		n.warm_up(point)
	await get_tree().process_frame
	await get_tree().process_frame
	for n in warmers:
		if is_instance_valid(n):
			n.clear_warm_up()
	for f in fields:
		if is_instance_valid(f):
			f.queue_free()
	await WorldRuntime.look_around(self, car.global_position)
	get_parent().get_node("CameraManager").activate_current()
	car.controls_locked = false
	if cover != null:
		cover.finish()


func _exit_tree() -> void:
	HeadlightCone.reset()
	WindSway.reset()
	Config.data.weather = WeatherLibrary.DEFAULT_ID


# The lab packs saves (trees as rows, the height grid as base64 int16 decimetres); this undoes it.
static func unpack(d: Dictionary) -> Dictionary:
	var out := d.duplicate()
	if d.has("kinds"):
		var trees: Array = []
		for row: Array in d["trees"]:
			trees.append({"x": float(row[0]), "z": float(row[1]), "rot": float(row[2]), "sx": float(row[3]),
				"sy": float(row[4]), "kind": String(d["kinds"][int(row[5])])})
		out["trees"] = trees
		out.erase("kinds")
	var hm: Variant = d.get("heightmap")
	if hm is String:
		var raw := Marshalls.base64_to_raw(hm)
		var floats := PackedFloat32Array()
		floats.resize(raw.size() / 2)
		for i in floats.size():
			floats[i] = raw.decode_s16(i * 2) / 10.0
		out["heightmap"] = floats
	elif hm is Array:
		out["heightmap"] = PackedFloat32Array(hm)
	return out


func load_level(d: Dictionary) -> void:
	level = unpack(d)
	_hm = level.get("heightmap", PackedFloat32Array())
	_build_road(level.get("road", []))
	_build_ground()
	_build_trees(level.get("trees", []))
	_build_cover()
	_rows.clear()
	_shown_row = -1
	var vis: Variant = level.get("visibility")
	if vis is Dictionary:
		_every = maxi(1, int(vis["every"]))
		for row: Array in vis["rows"]:
			_rows.append(PackedInt32Array(row))
	set_process(true)


func _process(_dt: float) -> void:
	if _car != null and HeadlightCone.has_headlights(Config.data):
		HeadlightCone.push(Config.data, _car.global_transform, _car.half_width() * 2.0 if _car.has_method("half_width") else 1.8)
	if not _falling.is_empty():
		_step_falls(_dt)
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		show_from(cam.global_position)
		if _cover != null:
			_cover.update_centre(cam.global_position)


func _build_cover() -> void:
	if _cover != null:
		_cover.queue_free()
	_cover = GroundCover.new()
	_cover.setup(level, height_at, int(SIZE))
	if _cover.has_cover():
		add_child(_cover)
		_cover.build()
	else:
		_cover.free()
		_cover = null


# Draws only the trees the bake saw from the two viewpoint rows either side of the road point nearest `pos`,
# each species' visible ones packed to the front of its MultiMesh.
func show_from(pos: Vector3) -> void:
	var r := _nearest_sample(pos.x, pos.z) / _every
	if r == _shown_row or _rows.is_empty():
		return
	_shown_row = r
	var lists: Array[PackedInt32Array] = []
	for _i in _mms.size():
		lists.append(PackedInt32Array())
	for row_i in [r, r + 1]:
		if row_i < _rows.size():
			for id in _rows[row_i]:
				if _mark[id] == 0:
					_mark[id] = 1
					lists[_tree_mm[id]].append(_tree_inst[id])
	_mark.fill(0)
	for s in _mms.size():
		var buf := PackedFloat32Array()
		for j in lists[s]:
			buf.append_array(_full[s].slice(j * 12, j * 12 + 12))
		buf.resize(_full[s].size())
		_mms[s].buffer = buf
		_mms[s].visible_instance_count = lists[s].size()


# The car's start: on the road's first node, facing the second, just above the ground.
func spawn_pose() -> Transform3D:
	var road: Array = level.get("road", [])
	if road.size() < 2:
		return Transform3D(Basis(), Vector3(0, height_at(0, 0) + 1.0, 0))
	var a := Vector3(road[0]["x"], 0, road[0]["z"])
	var b := Vector3(road[1]["x"], 0, road[1]["z"])
	a.y = height_at(a.x, a.z) + 1.0
	return Transform3D(Basis.looking_at((b - a) * Vector3(1, 0, 1)), a)


func height_at(x: float, z: float) -> float:
	var fc := clampf((x + SIZE / 2) / grid_step, 0.0, _cols - 1.001)
	var fr := clampf((z + SIZE / 2) / grid_step, 0.0, _cols - 1.001)
	var c := int(fc)
	var r := int(fr)
	var u := fc - c
	var v := fr - r
	var i := r * _cols + c
	return lerpf(lerpf(_g[i], _g[i + 1], u), lerpf(_g[i + _cols], _g[i + _cols + 1], u), v)


# (road weight, tarmac weight) under a wheel, as the drivetrain asks the terrain; the lab's roads are gravel.
func surface_at(x: float, z: float) -> Vector2:
	var near := _nearest(x, z)
	return Vector2(1.0 - smoothstep(near.z - 0.5, near.z + 0.5, near.x), 0.0)


# The lab's ground before the road: its saved height grid, or flat.
func _natural(x: float, z: float) -> float:
	if _hm.size() != (LAB_N + 1) * (LAB_N + 1):
		return 0.0
	var cell := SIZE / LAB_N
	var fc := clampf((x + SIZE / 2) / cell, 0.0, LAB_N - 0.001)
	var fr := clampf((z + SIZE / 2) / cell, 0.0, LAB_N - 0.001)
	var c := int(fc)
	var r := int(fr)
	var i := r * (LAB_N + 1) + c
	return lerpf(lerpf(_hm[i], _hm[i + 1], fc - c), lerpf(_hm[i + LAB_N + 1], _hm[i + LAB_N + 2], fc - c), fr - r)


# The same Hermite spline, smoothed road level and segment buckets as the lab's roadSamples / rebuildTerrain.
func _build_road(road: Array) -> void:
	for arr in [_sx, _sz, _sw, _sh, _sa]:
		arr.clear()
	_buckets.clear()
	for i in road.size() - 1:
		var p1: Dictionary = road[i]
		var p2: Dictionary = road[i + 1]
		var m1 := _tangent(road, i)
		var m2 := _tangent(road, i + 1)
		var n := maxi(2, ceili(Vector2(p2["x"] - p1["x"], p2["z"] - p1["z"]).length() / 2.0))
		for j in range(1 if i > 0 else 0, n + 1):
			var t := float(j) / n
			var t2 := t * t
			var t3 := t2 * t
			var h00 := 2 * t3 - 3 * t2 + 1
			var h10 := t3 - 2 * t2 + t
			var h01 := -2 * t3 + 3 * t2
			var h11 := t3 - t2
			var x: float = h00 * p1["x"] + h10 * m1.x + h01 * p2["x"] + h11 * m2.x
			var z: float = h00 * p1["z"] + h10 * m1.y + h01 * p2["z"] + h11 * m2.y
			_sx.append(x)
			_sz.append(z)
			_sw.append(lerpf(p1["w"], p2["w"], t))
			_sa.append(0.0 if _sa.is_empty() else _sa[-1] + Vector2(x - _sx[-2], z - _sz[-2]).length())
			_sh.append(_natural(x, z))
	for _pass in 3:  # a moving average along the road, so it rolls gently instead of copying every bump
		var hs := _sh.duplicate()
		for i in hs.size():
			var lo := maxi(0, i - 12)
			var hi := mini(hs.size() - 1, i + 12)
			var sum := 0.0
			for k in range(lo, hi + 1):
				sum += hs[k]
			_sh[i] = sum / (hi - lo + 1)
	var reach := FALLOFF + 14.0
	for i in _sx.size() - 1:
		for gx in range(floori((minf(_sx[i], _sx[i + 1]) - reach) / BUCKET), floori((maxf(_sx[i], _sx[i + 1]) + reach) / BUCKET) + 1):
			for gz in range(floori((minf(_sz[i], _sz[i + 1]) - reach) / BUCKET), floori((maxf(_sz[i], _sz[i + 1]) + reach) / BUCKET) + 1):
				var key := gx * 100003 + gz
				if not _buckets.has(key):
					_buckets[key] = []
				_buckets[key].append(i)


func _tangent(road: Array, i: int) -> Vector2:
	var n: Dictionary = road[i]
	var a: Dictionary = road[maxi(0, i - 1)]
	var b: Dictionary = road[mini(road.size() - 1, i + 1)]
	var m := Vector2((b["x"] - a["x"]) / 2.0, (b["z"] - a["z"]) / 2.0)
	if n.get("m") is Dictionary:
		m = Vector2(n["m"]["x"], n["m"]["z"])
	return m * float(n.get("tension", 1.0))


# Index of the road segment nearest (x, z), the same answer as the lab's nearestRoad; far from the road it scans them all.
func _nearest_sample(x: float, z: float) -> int:
	var segs: Array = _buckets.get(floori(x / BUCKET) * 100003 + floori(z / BUCKET), [])
	if segs.is_empty():
		segs = range(_sx.size() - 1)
	var best := INF
	var best_i := 0
	for i: int in segs:
		var ax := _sx[i]
		var az := _sz[i]
		var abx := _sx[i + 1] - ax
		var abz := _sz[i + 1] - az
		var t := clampf(((x - ax) * abx + (z - az) * abz) / maxf(abx * abx + abz * abz, 1e-9), 0.0, 1.0)
		var d := Vector2(x - ax - abx * t, z - az - abz * t).length_squared()
		if d < best:
			best = d
			best_i = i
	return best_i


# Where (x, z) sits relative to the nearest road point: (signed metres across, half-width, metres along); INF across
# away from any road. Positive across is the side the lab's road mesh puts its first edge vertex.
func _road_frame(x: float, z: float) -> Vector3:
	var best := Vector3(INF, 0, 0)
	var best_d := INF
	for i: int in _buckets.get(floori(x / BUCKET) * 100003 + floori(z / BUCKET), []):
		var ax := _sx[i]
		var az := _sz[i]
		var abx := _sx[i + 1] - ax
		var abz := _sz[i + 1] - az
		var t := clampf(((x - ax) * abx + (z - az) * abz) / maxf(abx * abx + abz * abz, 1e-9), 0.0, 1.0)
		var d := Vector2(x - ax - abx * t, z - az - abz * t).length()
		if d < best_d:
			best_d = d
			best = Vector3(d if abx * (z - az) - abz * (x - ax) >= 0.0 else -d, lerpf(_sw[i], _sw[i + 1], t), lerpf(_sa[i], _sa[i + 1], t))
	return best


# Nearest road point: (distance, road height there, half-width there); distance is INF away from any road.
func _nearest(x: float, z: float) -> Vector3:
	var best := Vector3(INF, 0, 0)
	for i: int in _buckets.get(floori(x / BUCKET) * 100003 + floori(z / BUCKET), []):
		var ax := _sx[i]
		var az := _sz[i]
		var abx := _sx[i + 1] - ax
		var abz := _sz[i + 1] - az
		var t := clampf(((x - ax) * abx + (z - az) * abz) / maxf(abx * abx + abz * abz, 1e-9), 0.0, 1.0)
		var d := Vector2(x - ax - abx * t, z - az - abz * t).length()
		if d < best.x:
			best = Vector3(d, lerpf(_sh[i], _sh[i + 1], t), lerpf(_sw[i], _sw[i + 1], t))
	return best


func _ground(x: float, z: float) -> float:
	var h := _natural(x, z)
	var near := _nearest(x, z)
	if near.x == INF:
		return h
	var flat: float = Config.data.level_road_flat_margin
	return near.y - 0.05 + (h - near.y + 0.05) * smoothstep(near.z + flat, near.z + flat + FALLOFF, near.x)


# One mesh over the whole square: height from _ground, simple sun shading baked into COLOR.rgb, trimesh collision.
# The road is painted per pixel by level_ground.gdshader from each vertex's place on the road (_road_frame), so its
# edge is a smooth line instead of following the 1.5 m triangles.
func _build_ground() -> void:
	_cols = int(SIZE / grid_step) + 1
	_g.resize(_cols * _cols)
	var frames := PackedVector3Array()  # each vertex's _road_frame
	frames.resize(_cols * _cols)
	for r in _cols:
		for c in _cols:
			var x := c * grid_step - SIZE / 2
			var z := r * grid_step - SIZE / 2
			_g[r * _cols + c] = _ground(x, z)
			var f := _road_frame(x, z)
			frames[r * _cols + c] = f if f.x != INF else Vector3(1000.0, 1.0, 0.0)
	var sun := Vector3(-1.0, 1.4, 0.6).normalized()
	var cov := GroundCover.decode_cover(level)
	var cover_tints := GroundCover.tints(level.get("coverKinds", {}))
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	for r in _cols:
		for c in _cols:
			var x := c * grid_step - SIZE / 2
			var z := r * grid_step - SIZE / 2
			var hx := _g[r * _cols + mini(c + 1, _cols - 1)] - _g[r * _cols + maxi(c - 1, 0)]
			var hz := _g[mini(r + 1, _cols - 1) * _cols + c] - _g[maxi(r - 1, 0) * _cols + c]
			var nrm := Vector3(-hx, 2.0 * grid_step, -hz).normalized()
			var light := 0.55 + 0.45 * maxf(nrm.dot(sun), 0.0)
			verts.append(Vector3(x, _g[r * _cols + c], z))
			normals.append(nrm)
			var tint := GroundCover.ground_multiplier(cov, int(SIZE), cover_tints, x, z)
			var f := frames[r * _cols + c]
			var d := absf(f.x) - f.y  # metres beyond the road's edge
			# fades over a few metres so this per-vertex colour never shows the triangles at the road's edge
			var grass := Color(0.95, 1.25, 0.72).lerp(Color.WHITE, 1.0 - smoothstep(-1.0, 2.0, d))
			colors.append(Color(light * tint.r * grass.r, light * tint.g * grass.g, light * tint.b * grass.b, 0.0))
			# the slack covers how far |across| can dip between two vertices; see level_ground.gdshader
			uvs.append(Vector2(f.x, absf(f.x) - grid_step))
			uv2s.append(Vector2(f.y, f.z))
	var idx := PackedInt32Array()
	for r in _cols - 1:
		for c in _cols - 1:
			var i := r * _cols + c
			idx.append_array([i, i + 1, i + _cols, i + 1, i + _cols + 1, i + _cols])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.name = "Ground"
	mi.mesh = mesh
	mi.material_override = material
	add_child(mi)
	var body := StaticBody3D.new()
	body.name = "GroundBody"
	var shape := CollisionShape3D.new()
	shape.shape = mesh.create_trimesh_shape()
	body.add_child(shape)
	add_child(body)


# One MultiMesh of the game's star-tree cards (Foliage._alpha_card_mesh) per species.
func _build_trees(trees: Array) -> void:
	var by_kind := {}
	var slot := {}
	_mms.clear()
	_full.clear()
	_tree_mm.resize(trees.size())
	_tree_inst.resize(trees.size())
	_mark.resize(trees.size())
	_mark.fill(0)
	_tree_h.resize(trees.size())
	_fallen.clear()
	_falling.clear()
	var ground := PackedVector3Array()
	ground.resize(trees.size())
	for ti in trees.size():
		var kind: String = trees[ti]["kind"]
		if not by_kind.has(kind):
			slot[kind] = by_kind.size()  # the species MultiMeshes are made in this same first-seen order
			by_kind[kind] = []
		_tree_mm[ti] = slot[kind]
		_tree_inst[ti] = by_kind[kind].size()
		by_kind[kind].append(ti)
	var card := Foliage._alpha_card_mesh()
	for kind: String in by_kind:
		var tex_path := ("res://tools/" if "/" in kind else "res://textures/") + kind
		var tex: Texture2D = load(tex_path) if ResourceLoader.exists(tex_path) else null
		var aspect := 1.0
		var mat := ShaderMaterial.new()
		mat.shader = TREE_SHADER
		mat.set_shader_parameter("tint", KIND_TINT.get(kind, Color(0.85, 0.85, 0.85)))
		if tex != null:
			aspect = tex.get_width() / 6.0 / tex.get_height()
			mat.set_shader_parameter("albedo", tex)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = card
		var list: Array = by_kind[kind]
		mm.instance_count = list.size()
		var h0: float = KIND_HEIGHT.get(kind, 8.0)
		var full := PackedFloat32Array()  # MultiMesh's own layout: 12 floats per instance, the basis rows each followed by the origin
		for ti: int in list:
			var t: Dictionary = trees[ti]
			var h: float = h0 * t["sy"]
			_tree_h[ti] = h
			ground[ti] = Vector3(t["x"], height_at(t["x"], t["z"]), t["z"])
			var w: float = h0 * aspect * t["sx"]
			var b := Basis(Vector3.UP, deg_to_rad(t["rot"])).scaled(Vector3(w, h, w))
			var o := Vector3(t["x"], height_at(t["x"], t["z"]) - 0.2, t["z"])
			full.append_array([b.x.x, b.y.x, b.z.x, o.x, b.x.y, b.y.y, b.z.y, o.y, b.x.z, b.y.z, b.z.z, o.z])
		mm.buffer = full
		_mms.append(mm)
		_full.append(full)
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Trees_" + kind.get_file().get_basename()
		mmi.multimesh = mm
		mmi.material_override = mat
		add_child(mmi)
	var old := get_node_or_null("Collision")
	if old != null:
		old.free()
	var cfg: GameConfig = Config.data
	# shape index == tree index, which is how the car's knock_down / size_factor calls name a tree
	_tree_shape = ObstacleBody.build(self, ground, cfg.tree_collision_radius_m, cfg.tree_collision_height_m)


# How big tree `idx` is for felling (TreeFall): 1 at level_tree_full_height_m and above.
func size_factor(idx: int) -> float:
	if idx < 0 or idx >= _tree_h.size():
		return 1.0
	return clampf(_tree_h[idx] / Config.data.level_tree_full_height_m, 0.0, 1.0)


# The car felled tree `idx`: its hitbox goes at once and the card topples along `dir`.
func knock_down(idx: int, dir: Vector3, duration: float) -> void:
	var body := get_node_or_null("Collision") as StaticBody3D
	if body == null or idx < 0 or idx >= _tree_h.size() or _fallen.has(idx):
		return
	PhysicsServer3D.body_set_shape_disabled(body.get_rid(), idx, true)
	_fallen[idx] = true
	var f := _full[_tree_mm[idx]]
	var k := _tree_inst[idx] * 12
	var up := Transform3D(Basis(Vector3(f[k], f[k + 4], f[k + 8]), Vector3(f[k + 1], f[k + 5], f[k + 9]),
		Vector3(f[k + 2], f[k + 6], f[k + 10])), Vector3(f[k + 3], f[k + 7], f[k + 11]))
	_falling.append({"id": idx, "up": up, "axis": TreeFall.topple_axis(dir), "t": 0.0, "dur": maxf(duration, 0.0)})


func is_fallen(idx: int) -> bool:
	return _fallen.has(idx)


func _step_falls(dt: float) -> void:
	for rec: Dictionary in _falling:
		rec["t"] += dt
		var up: Transform3D = rec["up"]
		var b := Basis(rec["axis"], TreeFall.fall_angle(rec["t"], rec["dur"])) * up.basis
		var id: int = rec["id"]
		var s := _tree_mm[id]
		var k := _tree_inst[id] * 12
		var f := _full[s]
		var o := up.origin
		var vals := [b.x.x, b.y.x, b.z.x, o.x, b.x.y, b.y.y, b.z.y, o.y, b.x.z, b.y.z, b.z.z, o.z]
		for i in 12:
			f[k + i] = vals[i]
		_full[s] = f
		if _rows.is_empty():
			_mms[s].set_instance_transform(_tree_inst[id], Transform3D(b, o))
	_falling = _falling.filter(func(r: Dictionary) -> bool: return r["t"] < r["dur"])
	_shown_row = -1  # show_from repacks the baked view from the updated transforms
