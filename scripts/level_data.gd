class_name LevelData
extends RefCounted
# A level save's data and its road/terrain queries, with no nodes: LevelView builds the scene from it, and the lab's maths is pinned to it by tests/headless/fixtures/level_parity.json.

const FALLOFF := 1.0         # how far beyond the road's edge the ground blends back to its own height
const BUCKET := 20.0
const JUNCTION_TOL := 0.75   # chain ends this close to each other, or to another chain's node, make a junction
const JUNCTION_BLEND := 25.0 # road height eases to the junction's level over this many metres

var level: Dictionary
var size := 600.0               # the square's side in metres, centred on the origin
var grid_n := 0                 # the saved height grid has (grid_n+1)² samples; 0 means flat
var flat_margin: float = Config.data.level_road_flat_margin
var sx := PackedFloat32Array()  # road samples: x, z, half-width, height
var sz := PackedFloat32Array()
var sw := PackedFloat32Array()
var sh := PackedFloat32Array()
var sa := PackedFloat32Array()  # metres along the road to each sample
var sc := PackedInt32Array()    # which road chain each sample belongs to; a segment joins two samples of one chain
var junctions: Array[Vector3] = []  # (x, z, half-width) of each junction centre
var buckets := {}
var _hm := PackedFloat32Array()
var _jbuckets := {}
var _jcell := JUNCTION_BLEND


# Without `with_ground` the height grid and road are not built either: the game reads those from the bake.
func load_save(d: Dictionary, with_trees := true, with_ground := true) -> void:
	level = unpack(d, with_trees, with_ground)
	size = float(level.get("size", 600))
	_hm = level.get("heightmap", PackedFloat32Array())
	var side := roundi(sqrt(_hm.size()))
	grid_n = side - 1 if side > 1 and side * side == _hm.size() else 0
	if with_ground:
		_build_road(chains(level))


# The lab packs saves (trees as rows, the height grid as base64 int16 decimetres); this undoes it.
# Without `with_trees` the trees are left out: the game reads them from the bake and only a bake needs them here.
static func unpack(d: Dictionary, with_trees := true, with_ground := true) -> Dictionary:
	var out := d.duplicate()
	if not with_ground:
		for k in ["heightmap", "heightWebp"]:
			out.erase(k)
	if not with_trees:
		for k in ["kinds", "treesBin", "trees"]:
			out.erase(k)
	elif d.has("kinds") and d.get("treesBin") is String:
		var raw := Marshalls.base64_to_raw(d["treesBin"])
		var half := float(d.get("size", 600)) / 2.0
		var trees: Array = []
		for o in range(0, raw.size() - 6, 7):
			var s := raw[o + 5] / 100.0
			trees.append({"x": raw.decode_u16(o) / 10.0 - half, "z": raw.decode_u16(o + 2) / 10.0 - half,
				"rot": raw[o + 4] * 360.0 / 256.0, "sx": s, "sy": s, "kind": String(d["kinds"][raw[o + 6]])})
		out["trees"] = trees
		out.erase("kinds")
		out.erase("treesBin")
	elif d.has("kinds"):
		var trees: Array = []
		for row: Array in d["trees"]:
			trees.append({"x": float(row[0]), "z": float(row[1]), "rot": float(row[2]), "sx": float(row[3]),
				"sy": float(row[4]), "kind": String(d["kinds"][int(row[5])])})
		out["trees"] = trees
		out.erase("kinds")
	if not with_ground:
		return out
	var hm: Variant = d.get("heightmap")
	var hw: Variant = d.get("heightWebp")
	if hw is String:
		var img := Image.new()
		if img.load_webp_from_buffer(Marshalls.base64_to_raw(hw)) == OK:
			img.convert(Image.FORMAT_RGB8)
			var px := img.get_data()
			var floats := PackedFloat32Array()
			floats.resize(px.size() / 3)
			for i in floats.size():
				floats[i] = ((px[i * 3] << 8 | px[i * 3 + 1]) - 32768) / 10.0
			out["heightmap"] = floats
		out.erase("heightWebp")
	elif hm is String:
		var raw := Marshalls.base64_to_raw(hm)
		var floats := PackedFloat32Array()
		floats.resize(raw.size() / 2)
		for i in floats.size():
			floats[i] = raw.decode_s16(i * 2) / 10.0
		out["heightmap"] = floats
	elif hm is Array:
		out["heightmap"] = PackedFloat32Array(hm)
	return out


# A save's road chains; an older save's single `road` is one chain.
static func chains(d: Dictionary) -> Array:
	if d.has("roads"):
		return d["roads"]
	return [d["road"]] if d.has("road") else []


# The car's start: on the first road's first node, facing the second, just above the ground.
func spawn_pose(height := Callable()) -> Transform3D:
	var cs := chains(level)
	var road: Array = cs[0] if not cs.is_empty() else []
	var h := height if height.is_valid() else ground
	if road.size() < 2:
		return Transform3D(Basis(), Vector3(0, h.call(0.0, 0.0) + 1.0, 0))
	var a := Vector3(road[0]["x"], 0, road[0]["z"])
	var b := Vector3(road[1]["x"], 0, road[1]["z"])
	a.y = h.call(a.x, a.z) + 1.0
	return Transform3D(Basis.looking_at((b - a) * Vector3(1, 0, 1)), a)


# The nearest road point to `p`, facing along the road the way nearest `facing`.
func road_pose(p: Vector2, facing: Vector3, height := Callable()) -> Transform3D:
	if sx.size() < 2:
		return spawn_pose(height)
	var i := nearest_sample(p.x, p.y)
	var a := Vector2(sx[i], sz[i])
	var ab := Vector2(sx[i + 1], sz[i + 1]) - a
	var q := a + ab * clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-9), 0.0, 1.0)
	var dir := Vector3(ab.x, 0.0, ab.y).normalized()
	if dir.dot(facing) < 0.0:
		dir = -dir
	var h := height if height.is_valid() else ground
	return Transform3D(Basis.looking_at(dir, Vector3.UP), Vector3(q.x, h.call(q.x, q.y) + 1.0, q.y))


# (road weight, tarmac weight) under a wheel, as the drivetrain asks the terrain; the lab's roads are gravel.
func surface_at(x: float, z: float) -> Vector2:
	var near := nearest(x, z)
	return Vector2(1.0 - smoothstep(near.z - 0.5, near.z + 0.5, near.x), 0.0)


# The lab's ground before the road: its saved height grid, or flat.
func natural(x: float, z: float) -> float:
	if grid_n == 0:
		return 0.0
	var stride := grid_n + 1
	var cell := size / grid_n
	var fc := clampf((x + size / 2) / cell, 0.0, grid_n - 0.001)
	var fr := clampf((z + size / 2) / cell, 0.0, grid_n - 0.001)
	var c := int(fc)
	var r := int(fr)
	var i := r * stride + c
	return lerpf(lerpf(_hm[i], _hm[i + 1], fc - c), lerpf(_hm[i + stride], _hm[i + stride + 1], fc - c), fr - r)


func ground(x: float, z: float) -> float:
	var h := natural(x, z)
	var near := nearest(x, z)
	if near.x == INF:
		return h
	return near.y - 0.05 + (h - near.y + 0.05) * smoothstep(near.z + flat_margin, near.z + flat_margin + FALLOFF, near.x)


# The lab's roads: each chain's Hermite spline, smoothed road level and segment buckets as the lab's roadSamples /
# rebuildTerrain, chains concatenated (no segment joins two chains), road height pinned to the ground at each junction.
func _build_road(roads: Array) -> void:
	for arr in [sx, sz, sw, sh, sa, sc]:
		arr.clear()
	buckets.clear()
	var cs := roads.filter(func(c: Array) -> bool: return c.size() >= 2)
	junctions = _find_junctions(cs)
	for ci in cs.size():
		var road: Array = cs[ci]
		var first := sx.size()
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
				sa.append(0.0 if sx.size() == first else sa[-1] + Vector2(x - sx[-1], z - sz[-1]).length())
				sx.append(x)
				sz.append(z)
				sw.append(lerpf(p1["w"], p2["w"], t))
				sh.append(natural(x, z))
				sc.append(ci)
		for _pass in 3:  # a moving average along the road, so it rolls gently instead of copying every bump
			var hs := sh.duplicate()
			for i in range(first, hs.size()):
				var lo := maxi(first, i - 12)
				var hi := mini(hs.size() - 1, i + 12)
				var sum := 0.0
				for k in range(lo, hi + 1):
					sum += hs[k]
				sh[i] = sum / (hi - lo + 1)
	_bucket_junctions()
	var level_at := _junction_levels()
	for i in sx.size():
		var best := -1
		var best_d := JUNCTION_BLEND
		for ji in _near_junctions(sx[i], sz[i]):
			var d := Vector2(sx[i] - junctions[ji].x, sz[i] - junctions[ji].y).length()
			if d < best_d:
				best_d = d
				best = ji
		if best >= 0:
			sh[i] = lerpf(level_at[best], sh[i], smoothstep(0.0, JUNCTION_BLEND, best_d))
	bucket_samples()


# Each junction's road level: the mean of its roads' own smoothed levels there, so a road ending on a hillside
# meets the others halfway instead of being dragged down (or up) to the bare ground in a few metres.
func _junction_levels() -> Array[float]:
	var closest: Array[Dictionary] = []  # per junction: chain -> Vector2(distance, height) of its nearest sample
	for jn in junctions:
		closest.append({})
	for i in sx.size():
		for ji in _near_junctions(sx[i], sz[i]):
			var d := Vector2(sx[i] - junctions[ji].x, sz[i] - junctions[ji].y).length()
			if d < 3.0 and d < closest[ji].get(sc[i], Vector2(INF, 0.0)).x:
				closest[ji][sc[i]] = Vector2(d, sh[i])
	var out: Array[float] = []
	for ji in junctions.size():
		var sum := 0.0
		for v: Vector2 in closest[ji].values():
			sum += v.y
		out.append(sum / closest[ji].size() if closest[ji].size() > 0 else natural(junctions[ji].x, junctions[ji].y))
	return out


# Junction centres as (x, z, half-width): chain ends within JUNCTION_TOL of each other or of another chain's node.
func _find_junctions(cs: Array) -> Array[Vector3]:
	var ends: Array[Vector2i] = []
	for ci in cs.size():
		ends.append(Vector2i(ci, 0))
		ends.append(Vector2i(ci, cs[ci].size() - 1))
	var lab := PackedInt32Array(range(ends.size()))
	for a in ends.size():
		for b in range(a + 1, ends.size()):
			if lab[a] != lab[b] and _node_dist(cs, ends[a], ends[b]) <= JUNCTION_TOL:
				var old := lab[b]
				for k in ends.size():
					if lab[k] == old:
						lab[k] = lab[a]
	var members := {}  # cluster label -> {"chain:node" -> Vector2i}
	for a in ends.size():
		var m: Dictionary = members.get_or_add(lab[a], {})
		m["%d:%d" % [ends[a].x, ends[a].y]] = ends[a]
		for ci in cs.size():
			if ci == ends[a].x:
				continue
			for ni in cs[ci].size():
				if _node_dist(cs, ends[a], Vector2i(ci, ni)) <= JUNCTION_TOL:
					m["%d:%d" % [ci, ni]] = Vector2i(ci, ni)
	var out: Array[Vector3] = []
	for m: Dictionary in members.values():
		if m.size() < 2:
			continue
		var sum := Vector2.ZERO
		var wj := 0.0
		for ref: Vector2i in m.values():
			var node: Dictionary = cs[ref.x][ref.y]
			sum += Vector2(node["x"], node["z"])
			wj = maxf(wj, float(node["w"]))
		sum /= m.size()
		out.append(Vector3(sum.x, sum.y, wj))
	return out


func _node_dist(cs: Array, a: Vector2i, b: Vector2i) -> float:
	var na: Dictionary = cs[a.x][a.y]
	var nb: Dictionary = cs[b.x][b.y]
	return Vector2(na["x"] - nb["x"], na["z"] - nb["z"]).length()


# Junctions go in cells as wide as the farthest any of them reaches, so a point only looks at its own cell and the eight around it.
func _bucket_junctions() -> void:
	_jbuckets.clear()
	_jcell = JUNCTION_BLEND
	for jn in junctions:
		_jcell = maxf(_jcell, 3.0 * jn.z)
	for ji in junctions.size():
		var key := floori(junctions[ji].x / _jcell) * 100003 + floori(junctions[ji].y / _jcell)
		if not _jbuckets.has(key):
			_jbuckets[key] = []
		_jbuckets[key].append(ji)


# Indices of the junctions that can reach (x, z), in junction order.
func _near_junctions(x: float, z: float) -> Array:
	var out := []
	var gx := floori(x / _jcell)
	var gz := floori(z / _jcell)
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			out.append_array(_jbuckets.get((gx + dx) * 100003 + gz + dz, []))
	out.sort()
	return out


# (weight, junction half-width) of the nearest junction's influence at (x, z): 1 on the pad, 0 beyond 3 half-widths.
func junction_at(x: float, z: float) -> Vector2:
	var best := Vector2.ZERO
	for ji: int in _near_junctions(x, z):
		var jn := junctions[ji]
		var w := 1.0 - smoothstep(1.5 * jn.z, 3.0 * jn.z, Vector2(x - jn.x, z - jn.y).length())
		if w > best.x:
			best = Vector2(w, jn.z)
	return best


func _tangent(road: Array, i: int) -> Vector2:
	var n: Dictionary = road[i]
	var a: Dictionary = road[maxi(0, i - 1)]
	var b: Dictionary = road[mini(road.size() - 1, i + 1)]
	var m := Vector2((b["x"] - a["x"]) / 2.0, (b["z"] - a["z"]) / 2.0)
	if n.get("m") is Dictionary:
		m = Vector2(n["m"]["x"], n["m"]["z"])
	return m * float(n.get("tension", 1.0))


# Index of the road segment nearest (x, z), the same answer as the lab's nearestRoad; far from the road it scans them all.
func nearest_sample(x: float, z: float) -> int:
	var segs: Array = buckets.get(floori(x / BUCKET) * 100003 + floori(z / BUCKET), [])
	if segs.is_empty():
		segs = range(sx.size() - 1).filter(func(i: int) -> bool: return sc[i] == sc[i + 1])
	var best := INF
	var best_i := 0
	for i: int in segs:
		var ax := sx[i]
		var az := sz[i]
		var abx := sx[i + 1] - ax
		var abz := sz[i + 1] - az
		var t := clampf(((x - ax) * abx + (z - az) * abz) / maxf(abx * abx + abz * abz, 1e-9), 0.0, 1.0)
		var d := Vector2(x - ax - abx * t, z - az - abz * t).length_squared()
		if d < best:
			best = d
			best_i = i
	return best_i


# Where (x, z) sits relative to the nearest road point: (signed metres across, half-width, metres along, junction
# weight); INF across away from any road. Positive across is the side the lab's road mesh puts its first edge vertex.
# Inside a junction the half-width eases to the junction's, so the edge doesn't jump where two roads' frames meet.
func road_frame(x: float, z: float) -> Vector4:
	var best := Vector3(INF, 0, 0)
	var best_d := INF
	for i: int in buckets.get(floori(x / BUCKET) * 100003 + floori(z / BUCKET), []):
		var ax := sx[i]
		var az := sz[i]
		var abx := sx[i + 1] - ax
		var abz := sz[i + 1] - az
		var t := clampf(((x - ax) * abx + (z - az) * abz) / maxf(abx * abx + abz * abz, 1e-9), 0.0, 1.0)
		var d := Vector2(x - ax - abx * t, z - az - abz * t).length()
		if d < best_d:
			best_d = d
			best = Vector3(d if abx * (z - az) - abz * (x - ax) >= 0.0 else -d, lerpf(sw[i], sw[i + 1], t), lerpf(sa[i], sa[i + 1], t))
	var jn := junction_at(x, z)
	if best.x != INF:
		best.y = lerpf(best.y, jn.y, jn.x)
	return Vector4(best.x, best.y, best.z, jn.x)


# Nearest road point: (distance, road height there, half-width there); distance is INF away from any road.
func nearest(x: float, z: float) -> Vector3:
	var best := Vector3(INF, 0, 0)
	for i: int in buckets.get(floori(x / BUCKET) * 100003 + floori(z / BUCKET), []):
		var ax := sx[i]
		var az := sz[i]
		var abx := sx[i + 1] - ax
		var abz := sz[i + 1] - az
		var t := clampf(((x - ax) * abx + (z - az) * abz) / maxf(abx * abx + abz * abz, 1e-9), 0.0, 1.0)
		var d := Vector2(x - ax - abx * t, z - az - abz * t).length()
		if d < best.x:
			best = Vector3(d, lerpf(sh[i], sh[i + 1], t), lerpf(sw[i], sw[i + 1], t))
	return best


# Files each same-chain road segment under every bucket it can reach; the road queries read only these.
func bucket_samples() -> void:
	buckets.clear()
	var reach := FALLOFF + 14.0
	for i in sx.size() - 1:
		if sc[i] != sc[i + 1]:
			continue
		for gx in range(floori((minf(sx[i], sx[i + 1]) - reach) / BUCKET), floori((maxf(sx[i], sx[i + 1]) + reach) / BUCKET) + 1):
			for gz in range(floori((minf(sz[i], sz[i + 1]) - reach) / BUCKET), floori((maxf(sz[i], sz[i + 1]) + reach) / BUCKET) + 1):
				var key := gx * 100003 + gz
				if not buckets.has(key):
					buckets[key] = []
				buckets[key].append(i)
