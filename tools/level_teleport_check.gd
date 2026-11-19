extends Node
# Measurement tool, not a test: teleports the car round the dev level and reports how fast the streamer catches up. Run:
#
#   godot --path . res://tools/level_teleport_check.tscn
#
# One line per jump, then PASS/FAIL per check. Quits by itself; the frame cap is a backstop.

const WALL_S := 240.0
const DRIVE_MPS := 30.0
const DRIVE_S := 20.0
const SEED := 20261119
const SPOTS := 20
const WINDOW_S := 2.0
const CAP_S := 10.0
const SPIKE_MS := 50.0
const FALL_M := 2.0

var _level: LevelView
var _car: VehicleBody3D
var _rows: Array[Dictionary] = []


func _ready() -> void:
	get_window().size = Vector2i(1280, 720)
	Save.save_disabled = true
	get_tree().create_timer(WALL_S).timeout.connect(func() -> void:
		print("WALL CLOCK EXIT")
		get_tree().quit(1))
	var world := (load("res://level_view.tscn") as PackedScene).instantiate()
	add_child(world)
	_level = world.get_node("Level")
	_car = world.get_node("Car")
	await _level.loaded
	for _i in 60:
		await get_tree().process_frame
	var half := _level._bake.size / 2.0
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var spots: Array[Dictionary] = []
	spots.append({"name": "first", "p": Vector2(0, 0), "road": true})
	for i in SPOTS - 4:
		spots.append({"name": "road" if i % 2 == 0 else "field", "p": Vector2(rng.randf_range(-half + 80, half - 80), rng.randf_range(-half + 80, half - 80)), "road": i % 2 == 0})
	spots.append({"name": "corner", "p": Vector2(-half + 20, -half + 20), "road": false})
	spots.append({"name": "edge", "p": Vector2(half - 4, 0), "road": false})
	spots.append({"name": "far", "p": Vector2(half * 0.9, half * 0.9), "road": true})
	spots.append({"name": "back_to_first", "p": spots[0].p, "road": true})
	for s in spots:
		await _jump(s)
	await _drive()
	_report()
	get_tree().quit()


func _jump(s: Dictionary) -> void:
	var p: Vector2 = s.p
	var xf := _level.road_pose(p, Vector3(0, 0, 1)) if s.road else Transform3D(Basis.IDENTITY, Vector3(p.x, 0, p.y))
	xf.origin.y = _level.height_at(xf.origin.x, xf.origin.z) + 1.0
	var at := Vector2(xf.origin.x, xf.origin.z)
	_car.reset_to(xf)
	var t0 := Time.get_ticks_usec()
	var last := t0
	var frames := 0
	var worst := 0.0
	var col_frame := -1
	var lod_frame := -1
	var min_gap := INF
	var settled := false
	while true:
		await get_tree().process_frame
		frames += 1
		var now := Time.get_ticks_usec()
		worst = maxf(worst, (now - last) / 1000.0)
		last = now
		var el := (now - t0) / 1e6
		var pos := _car.global_position
		min_gap = minf(min_gap, pos.y - _level.height_at(pos.x, pos.z))
		if col_frame < 0 and _ground_under(pos):
			col_frame = frames
		if lod_frame < 0 and _near_lod(Vector2(pos.x, pos.z)):
			lod_frame = frames
		settled = col_frame >= 0 and lod_frame >= 0 and _level._streamer.cover.missing(Vector2(pos.x, pos.z)).is_empty()
		if (el >= WINDOW_S and settled) or el >= CAP_S:
			break
	var pos := _car.global_position
	var trees: Array = _tree_counts(pos)
	_rows.append({"name": s.name, "at": at, "col": col_frame, "lod": lod_frame, "fell": min_gap < -FALL_M or pos.y < _level.height_at(pos.x, pos.z) - FALL_M,
		"worst": worst, "cover": _level._streamer.cover.tiles.size(), "cover_missing": _level._streamer.cover.missing(at).size(),
		"trees": trees, "elapsed": (Time.get_ticks_usec() - t0) / 1e6})
	var r := _rows[-1]
	print("%-13s (%6.0f,%6.0f) col=%3d lod=%3d fell=%s worst=%6.1fms cover=%d(missing %d) treeTiles=%d/%d hit=%d/%d t=%.1fs" % [r.name, at.x, at.y, r.col, r.lod, r.fell, r.worst, r.cover, r.cover_missing, trees[0], trees[1], trees[2], trees[3], r.elapsed])


func _ground_under(pos: Vector3) -> bool:
	var q := PhysicsRayQueryParameters3D.create(pos + Vector3(0, 3, 0), pos - Vector3(0, 60, 0))
	q.exclude = [_car.get_rid()]
	var hit := _car.get_world_3d().direct_space_state.intersect_ray(q)
	return not hit.is_empty() and absf(hit.position.y - _level.height_at(pos.x, pos.z)) < 1.5


func _near_lod(p: Vector2) -> bool:
	var st := _level._streamer
	for t in st.near_tiles_of(p):
		var ts = st._tiles.get(t)
		if ts == null or ts.near_mesh == null:
			return false
	var under = st._tiles.get(st._tile_of(p))
	return under != null and under.body != null and under.body_level == st.Level.NEAR


func _tree_counts(pos: Vector3) -> Array:
	var tr: LevelTrees = _level._trees
	var near: float = Config.data.level_tree_collision_m
	var draw: float = Config.data.level_tree_draw_m
	var drawn := 0
	var drawn_want := 0
	var hit := 0
	var hit_want := 0
	for i in tr._tile_cells_near(pos, draw):
		var t: LevelTrees.Tile = tr.tile(i)
		if t == null:
			continue
		drawn += 1
		drawn_want += 1
		if tr._distance_to(t, pos) <= near:
			hit_want += 1
			if t.hit != null:
				hit += 1
	return [drawn, drawn_want, hit, hit_want]


func _report() -> void:
	var col_ok := true
	var fell_ok := true
	var lod_ok := true
	var spike_ok := true
	var cover_ok := true
	var hit_ok := true
	for r in _rows:
		col_ok = col_ok and r.col >= 0
		fell_ok = fell_ok and not r.fell
		lod_ok = lod_ok and r.lod >= 0
		spike_ok = spike_ok and r.worst < SPIKE_MS
		cover_ok = cover_ok and r.cover_missing == 0
		hit_ok = hit_ok and r.trees[2] == r.trees[3]
	print("SUMMARY collision-under-car %s | no-fall %s | near-LOD reached %s | worst frame < %d ms %s | cover complete %s | tree collision %s" % [
		_pf(col_ok), _pf(fell_ok), _pf(lod_ok), SPIKE_MS, _pf(spike_ok), _pf(cover_ok), _pf(hit_ok)])


func _pf(ok: bool) -> String:
	return "PASS" if ok else "FAIL"


# Drives the car along a straight line at DRIVE_MPS for DRIVE_S (pose set each frame) and prints the frame-time spread.
func _drive() -> void:
	var start := _level.road_pose(Vector2(-900, -300), Vector3(1, 0, 0))
	var dir := Vector3(start.basis.z * -1.0).normalized()
	dir.y = 0.0
	dir = dir.normalized()
	var pos := start.origin
	_car.reset_to(start)
	for _i in 120:
		await get_tree().process_frame
	var times: Array[float] = []
	var gaps := {"min": 999.0, "min_ahead": 999.0, "frames40": 0, "frames70": 0, "pending_max": 0, "frames": 0}
	var last := Time.get_ticks_usec()
	var t0 := last
	while (Time.get_ticks_usec() - t0) / 1e6 < DRIVE_S:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var dt := (now - last) / 1e6
		last = now
		times.append(dt * 1000.0)
		_gap_sample(Vector2(pos.x, pos.z), Vector2(dir.x, dir.z), gaps)
		pos += dir * DRIVE_MPS * dt
		var xf := Transform3D(start.basis, pos)
		xf.origin.y = _level.height_at(pos.x, pos.z) + 1.0
		_car.reset_to(xf)
		_car.linear_velocity = dir * DRIVE_MPS
	print("NEARGAP min=%.1fm min_ahead=%.1fm frames<40m=%d frames<70m=%d of %d, pending near tiles max=%d" % [gaps.min, gaps.min_ahead, gaps.frames40, gaps.frames70, gaps.frames, gaps.pending_max])
	times.sort()
	var sum := 0.0
	for v in times:
		sum += v
	print("DRIVE %.0f m/s %.0f m: frames=%d avg=%.2fms p95=%.2fms p99=%.2fms max=%.2fms" % [DRIVE_MPS, DRIVE_MPS * DRIVE_S, times.size(), sum / times.size(), times[int(times.size() * 0.95)], times[int(times.size() * 0.99)], times[-1]])


func _gap_sample(here: Vector2, fwd: Vector2, g: Dictionary) -> void:
	var st := _level._streamer
	var pending := 0
	for t in st.near_tiles_of(here):
		var ts = st._tiles.get(t)
		if ts == null or ts.near_mesh == null:
			pending += 1
	var best := 999.0
	var ahead := 999.0
	for a in 72:
		var d := Vector2.from_angle(a * TAU / 72.0)
		for r in range(1, 71, 2):
			var q := here + d * r
			var ts = st._tiles.get(st._tile_of(q))
			if ts == null or ts.near_mesh == null:
				best = minf(best, r)
				if d.dot(fwd) > 0.85:
					ahead = minf(ahead, r)
				break
	g.min = minf(g.min, best)
	g.min_ahead = minf(g.min_ahead, ahead)
	g.frames += 1
	g.pending_max = maxi(g.pending_max, pending)
	if best < 40.0:
		g.frames40 += 1
	if best < 70.0:
		g.frames70 += 1
