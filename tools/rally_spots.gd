extends Node
# Finds stretches of a level's road flat, straight and wide enough for a rally start line, and pairs them into rallies. Run:
#
#   godot --headless --path . res://tools/rally_spots.tscn -- res://tools/levels/hafren_5km.json [rallies=5]
#
# Prints the candidates, then a JSON `rallies` list and the gravel patches under each line, ready to paste into the save.

const HALF_L := 25.0        # half the start area's length along the road (the lab's zone length / 2)
const PATCH_HALF_W := 11.5  # half the start area's width across the road: the lab's footprint at a 7 m road
const MIN_HALF_W := 3.0     # the road's half-width at the line
const MAX_BEND_M := 1.2     # how far the road may stray from a straight chord over the area
const MAX_ROAD_RISE := 1.2  # road height range over the area
const MAX_GROUND_RISE := 3.0
const CLEAR_M := 40.0       # from shops, teleports, buildings and existing patches
const SPREAD_M := 250.0     # between chosen lines
const BEST_SPOTS := 8        # only the flattest few spots get lines
const ROUTE_MIN := 2500.0
const ROUTE_MAX := 7000.0


func _ready() -> void:
	var save := "res://tools/levels/hafren_5km.json"
	var want := 5
	for a in OS.get_cmdline_user_args():
		if a.begins_with("rallies="):
			want = int(a.get_slice("=", 1))
		else:
			save = a
	var level: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(save))
	var bake := load(LevelBake.bake_path(save)) as LevelBake
	var roads := bake._roads()
	var avoid: Array[Vector2] = []
	for key in ["shops", "teleports", "buildings"]:
		for p: Dictionary in level.get(key, []):
			avoid.append(Vector2(p.x, p.z))
	var cands: Array[Dictionary] = []
	var last := -1000.0
	for i in bake.sx.size():
		if i > 0 and bake.sc[i] == bake.sc[i - 1] and bake.sa[i] - last < 5.0:
			continue
		last = bake.sa[i]
		var c := _score(bake, roads, i, avoid)
		if not c.is_empty():
			cands.append(c)
	cands.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.score < b.score)
	var spots: Array[Dictionary] = []
	for c in cands:
		if spots.all(func(s: Dictionary) -> bool: return s.p.distance_to(c.p) > SPREAD_M):
			spots.append(c)
	print("%d candidate samples, %d spread spots" % [cands.size(), spots.size()])
	spots = spots.slice(0, BEST_SPOTS)
	for s in spots:
		print("  (%.0f, %.0f) half-width %.2f  bend %.2f m  road rise %.2f m  ground rise %.2f m" % [s.p.x, s.p.y, s.w, s.bend, s.road_rise, s.ground_rise])
	# a line can be one rally's finish and another's start, so each spot serves up to two rallies
	var rallies: Array = []
	var uses := {}
	var pairs: Array[Vector3] = []
	for a in spots.size():
		for b in range(a + 1, spots.size()):
			var len := _length(roads.route(spots[a].p, spots[b].p))
			if len >= ROUTE_MIN and len <= ROUTE_MAX:
				pairs.append(Vector3(a, b, len))
	pairs.sort_custom(func(x: Vector3, y: Vector3) -> bool: return x.z > y.z)
	for pr in pairs:
		var a := int(pr.x)
		var b := int(pr.y)
		if rallies.size() >= want or uses.get(a, 0) >= 2 or uses.get(b, 0) >= 2:
			continue
		uses[a] = uses.get(a, 0) + 1
		uses[b] = uses.get(b, 0) + 1
		if rallies.size() % 2 == 1:
			var t := a
			a = b
			b = t
		var r := roads.route(spots[a].p, spots[b].p)
		rallies.append({"name": _name(level, spots[a].p, rallies), "km": snappedf(pr.z / 1000.0, 0.1), "start": _end(spots[a], _towards(r, true)), "finish": _end(spots[b], _towards(r, false))})
	var patches: Array = []
	for k: int in uses:
		patches.append(_patch(_end(spots[k], spots[k].along)))
	print("RALLIES ", JSON.stringify(rallies))
	print("PATCHES ", JSON.stringify(patches))
	get_tree().quit()


# A candidate line at sample i, or {} when the area round it is too bent, steep, narrow, busy or near something else.
func _score(bake: LevelBake, roads: LevelData, i: int, avoid: Array[Vector2]) -> Dictionary:
	var p := Vector2(bake.sx[i], bake.sz[i])
	if bake.sw[i] < MIN_HALF_W:
		return {}
	for o in avoid:
		if o.distance_to(p) < CLEAR_M:
			return {}
	for poly in bake.patches:
		if LevelData.polygon_distance(poly, p.x, p.y) < CLEAR_M:
			return {}
	var ids: Array[int] = []
	var j := i
	while j > 0 and bake.sc[j - 1] == bake.sc[i] and bake.sa[i] - bake.sa[j - 1] <= HALF_L:
		j -= 1
	if bake.sa[i] - bake.sa[j] < HALF_L - 3.0:
		return {}
	while j < bake.sx.size() and bake.sc[j] == bake.sc[i] and bake.sa[j] - bake.sa[i] <= HALF_L:
		ids.append(j)
		j += 1
	if bake.sa[ids[-1]] - bake.sa[i] < HALF_L - 3.0:
		return {}
	var a := Vector2(bake.sx[ids[0]], bake.sz[ids[0]])
	var b := Vector2(bake.sx[ids[-1]], bake.sz[ids[-1]])
	var bend := 0.0
	var lo := INF
	var hi := -INF
	for k in ids:
		var q := Vector2(bake.sx[k], bake.sz[k])
		bend = maxf(bend, Geometry2D.get_closest_point_to_segment(q, a, b).distance_to(q))
		lo = minf(lo, bake.sh[k])
		hi = maxf(hi, bake.sh[k])
		if bake.sw[k] < MIN_HALF_W - 0.25 or roads.is_junction(k):
			return {}
	if bend > MAX_BEND_M or hi - lo > MAX_ROAD_RISE:
		return {}
	var along := (b - a).normalized()
	var across := Vector2(-along.y, along.x)
	var glo := INF
	var ghi := -INF
	for u in range(-5, 6):
		for v in range(-4, 5):
			var q := p + along * (HALF_L * u / 5.0) + across * (PATCH_HALF_W * v / 4.0)
			var h := bake.height(q.x, q.y)
			glo = minf(glo, h)
			ghi = maxf(ghi, h)
			if _other_road_at(roads, q, bake.sc[i]):
				return {}
	if ghi - glo > MAX_GROUND_RISE:
		return {}
	return {"p": p, "w": bake.sw[i], "along": along, "bend": bend, "road_rise": hi - lo, "ground_rise": ghi - glo,
		"score": (ghi - glo) + 2.0 * (hi - lo) + bend - (bake.sw[i] - MIN_HALF_W)}


# The route's direction leaving its start (or arriving at its end), measured over about 10 m.
func _towards(r: PackedVector2Array, at_start: bool) -> Vector2:
	var n := r.size()
	if n < 2:
		return Vector2.ZERO
	var a := r[0] if at_start else r[n - 1]
	for k in range(1, n):
		var q := r[k] if at_start else r[n - 1 - k]
		if q.distance_to(a) > 10.0 or k == n - 1:
			return (q - a).normalized() if at_start else (a - q).normalized()
	return Vector2.ZERO


# A line's place and yaw: the model's -z (the way cars leave the line) turned onto the driving direction.
func _end(s: Dictionary, drive: Vector2) -> Dictionary:
	var d: Vector2 = s.along if s.along.dot(drive) >= 0.0 else -s.along
	return {"x": snappedf(s.p.x, 0.1), "z": snappedf(s.p.y, 0.1), "yaw": snappedf(atan2(-d.x, -d.y), 0.001)}


# The gravel pad under a line: the start area's rectangle, turned with the road.
func _patch(e: Dictionary) -> Array:
	var p := Vector2(e.x, e.z)
	var fwd := Vector2(-sin(e.yaw), -cos(e.yaw))
	var side := Vector2(-fwd.y, fwd.x)
	var out := []
	for c: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		var q := p + fwd * HALF_L * c.x + side * PATCH_HALF_W * c.y
		out.append({"x": snappedf(q.x, 0.1), "z": snappedf(q.y, 0.1)})
	return out


func _length(r: PackedVector2Array) -> float:
	var len := 0.0
	for k in range(1, r.size()):
		len += r[k].distance_to(r[k - 1])
	return len


# Whether a road other than `chain` covers q (within its half-width plus a metre).
func _other_road_at(roads: LevelData, q: Vector2, chain: int) -> bool:
	for k: int in roads.buckets.get(floori(q.x / LevelData.BUCKET) * 100003 + floori(q.y / LevelData.BUCKET), []):
		if roads.sc[k] == chain:
			continue
		var a := Vector2(roads.sx[k], roads.sz[k])
		var b := Vector2(roads.sx[k + 1], roads.sz[k + 1])
		if Geometry2D.get_closest_point_to_segment(q, a, b).distance_to(q) < roads.sw[k] + 1.0:
			return true
	return false


# "<nearest teleport point> Stages", numbered when two rallies start by the same point.
func _name(level: Dictionary, p: Vector2, rallies: Array) -> String:
	var best := "Hafren"
	var best_d := INF
	for t: Dictionary in level.get("teleports", []):
		var d := p.distance_to(Vector2(t.x, t.z))
		if d < best_d:
			best_d = d
			best = String(t.name)
	var name := best + " Stages"
	var n := 2
	while rallies.any(func(r: Dictionary) -> bool: return r.name == name):
		name = "%s Stages %d" % [best, n]
		n += 1
	return name
