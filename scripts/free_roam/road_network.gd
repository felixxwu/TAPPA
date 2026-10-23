class_name RoadNetwork
extends RefCounted
# Docs: features/free-roam.md — update in the same change as this file.
# Tests: tests/headless/test_free_roam.gd — extend in the same change.
# The island's road layout, built once at world creation. Radial growth from spawn decides the
# junctions and links; each link then becomes a wiggled polyline. The terrain is built around
# these roads (RoadTerrain), so everything downstream only asks "where is the nearest road".
#
# This mirrors tools/road_network_lab.html step for step (same random stream, same noise,
# same order of decisions), so a seed builds the same roads in both. Coordinates are kept in
# 64-bit floats for that reason: Vector2 is 32-bit and would round them differently.

const GRID_M := 100.0

var node_x := PackedFloat64Array()
var node_y := PackedFloat64Array()
var edges: Array[Vector2i] = []
var total_length_m := 0.0

var seg_ax := PackedFloat64Array()
var seg_ay := PackedFloat64Array()
var seg_bx := PackedFloat64Array()
var seg_by := PackedFloat64Array()
var seg_len := PackedFloat64Array()
var seg_cum := PackedFloat64Array()  # arc length along the edge at the segment's start
var seg_edge := PackedInt32Array()
var edge_first_seg := PackedInt32Array()  # each edge's segments are contiguous from here
var edge_len := PackedFloat64Array()  # each edge's arc length
var node_degree := PackedInt32Array()  # how many edges meet at each node
var _grid := {}  # Vector2i -> PackedInt32Array of segment ids

# The answer to the last nearest() query, kept in fields so a query allocates nothing.
var hit_d := INF
var hit_qx := 0.0
var hit_qy := 0.0
var hit_s := 0.0
var hit_edge := -1
var hit_side := 0.0
var hit_dx := 1.0
var hit_dy := 0.0
var _hit_si := -1

var _s: FreeRoamSettings
var _terrain: RoadTerrain


var hit_q: Vector2:
	get: return Vector2(hit_qx, hit_qy)
var hit_dir: Vector2:
	get: return Vector2(hit_dx, hit_dy)
var nodes: PackedVector2Array:
	get:
		var out := PackedVector2Array()
		for i in node_x.size():
			out.append(Vector2(node_x[i], node_y[i]))
		return out


func build(settings: FreeRoamSettings, terrain: RoadTerrain) -> void:
	_s = settings
	_terrain = terrain
	_grow()
	_densify()
	node_degree.resize(node_x.size())
	node_degree.fill(0)
	for e in edges:
		node_degree[e.x] += 1
		node_degree[e.y] += 1


func polyline(ei: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	var first := edge_first_seg[ei]
	var last := edge_first_seg[ei + 1] if ei + 1 < edge_first_seg.size() else seg_ax.size()
	for si in range(first, last):
		out.append(Vector2(seg_ax[si], seg_ay[si]))
	if last > first:
		out.append(Vector2(seg_bx[last - 1], seg_by[last - 1]))
	return out


# The lab's growth(): branches step outward from spawn, fork, and join existing road when they
# run into it. A spatial grid speeds up the "is there a node near here" scan, but always picks
# the lowest-numbered match, which is what the lab's linear scan does.
func _grow() -> void:
	var rng := LabNoise.Rng.new(_s.world_seed * 7919 + 1)
	node_x = PackedFloat64Array([0.0])
	node_y = PackedFloat64Array([0.0])
	edges.clear()
	var node_grid := {}
	var edge_grid := {}
	var edge_set := {}
	_append_to(node_grid, _cell(0.0, 0.0, _s.node_spacing_m), 0)
	var heads_at := PackedInt32Array()
	var heads_ang := PackedFloat64Array()
	for i in _s.roads_from_spawn:
		heads_at.append(0)
		heads_ang.append(float(i) / _s.roads_from_spawn * PI * 2.0 + rng.next())
	var head := 0
	var guard := 0
	while head < heads_at.size() and guard < 5000:
		guard += 1
		var at := heads_at[head]
		var h_ang := heads_ang[head]
		head += 1
		var fx := node_x[at]
		var fy := node_y[at]
		var out_ang := atan2(fy, fx)
		var ang := h_ang + _rad(_s.heading_jitter_deg) * (rng.next() * 2.0 - 1.0)
		if at != 0:
			ang += atan2(sin(out_ang - ang), cos(out_ang - ang)) * _s.outward_pull
		var tx := fx + cos(ang) * _s.segment_m
		var ty := fy + sin(ang) * _s.segment_m
		if _terrain.is_water(tx, ty) or _seg_hits_water(fx, fy, tx, ty):
			continue
		var near := _lowest_node_within(node_grid, tx, ty, at)
		var crosses := _crosses_edge(edge_grid, fx, fy, tx, ty, at, -1)
		if near >= 0 or crosses:
			# The branch ran into existing road: join it (a loop) or end here.
			if near >= 0 and rng.next() < _s.join_chance and not edge_set.has(_edge_key(at, near)) \
					and not _crosses_edge(edge_grid, fx, fy, node_x[near], node_y[near], at, near):
				_add_edge(edge_grid, edge_set, at, near)
			continue
		node_x.append(tx)
		node_y.append(ty)
		var idx := node_x.size() - 1
		_append_to(node_grid, _cell(tx, ty, _s.node_spacing_m), idx)
		_add_edge(edge_grid, edge_set, at, idx)
		if rng.next() < _s.fork_chance:
			heads_at.append(idx); heads_ang.append(ang + _rad(_s.fork_angle_deg))
			heads_at.append(idx); heads_ang.append(ang - _rad(_s.fork_angle_deg))
		else:
			heads_at.append(idx); heads_ang.append(ang)


# The lab's wiggle(): each link as a seeded noise offset inside a band around its straight
# line, landing exactly on both ends. Twistiness sets how far it swings, bend length how often.
func _densify() -> void:
	seg_ax.clear(); seg_ay.clear(); seg_bx.clear(); seg_by.clear()
	seg_len.clear(); seg_cum.clear(); seg_edge.clear(); edge_first_seg.clear(); edge_len.clear()
	_grid.clear()
	total_length_m = 0.0
	var step := minf(40.0, _s.bend_length_m / 6.0)
	for ei in edges.size():
		var ax := node_x[edges[ei].x]
		var ay := node_y[edges[ei].x]
		var bx := node_x[edges[ei].y]
		var by := node_y[edges[ei].y]
		var d := LabNoise.hyp(ax - bx, ay - by)
		# the small epsilon keeps a length that divides exactly from flipping on last-digit rounding
		var n := maxi(2, ceili(d / step - 1e-9))
		var nx := -(by - ay) / d
		var ny := (bx - ax) / d
		var s := floori(LabNoise.hash2(floori(ax + bx + 0.5), floori(ay + by + 0.5), _s.world_seed) * 1e6)
		var amp := minf(d * _s.road_twist, 1200.0 * _s.road_twist)
		var px := PackedFloat64Array()
		var py := PackedFloat64Array()
		for i in n + 1:
			var t := float(i) / n
			var env := sin(t * PI)
			var off := (LabNoise.fbm(t * d / _s.bend_length_m, 0.0, s) - 0.5) * 2.0 * amp * env
			px.append(ax + (bx - ax) * t + nx * off)
			py.append(ay + (by - ay) * t + ny * off)
		edge_first_seg.append(seg_ax.size())
		var cum := 0.0
		for i in n:
			var si := seg_ax.size()
			var length := LabNoise.hyp(px[i] - px[i + 1], py[i] - py[i + 1])
			seg_ax.append(px[i]); seg_ay.append(py[i]); seg_bx.append(px[i + 1]); seg_by.append(py[i + 1])
			seg_len.append(length); seg_cum.append(cum); seg_edge.append(ei)
			cum += length
			for c in _cells(px[i], py[i], px[i + 1], py[i + 1], GRID_M):
				_append_to(_grid, c, si)
		edge_len.append(cum)
		total_length_m += cum


# How far along edge `ei` the point at arc length `s` is from the nearer end that is a junction
# (three or more roads meeting); INF when neither end is one. Road paint is kept out of junctions.
func junction_gap(ei: int, s: float) -> float:
	if ei < 0 or ei >= edges.size():
		return INF
	var gap := INF
	if node_degree[edges[ei].x] >= 3:
		gap = s
	if node_degree[edges[ei].y] >= 3:
		gap = minf(gap, edge_len[ei] - s)
	return maxf(gap, 0.0)


# Nearest road point within `max_d`, searching the segment grid ring by ring. Equal distances
# go to the lower-numbered segment (as in the lab), so the answer never depends on search order.
func nearest(x: float, y: float, max_d: float) -> bool:
	hit_d = INF
	_hit_si = -1
	var gx := floori(x / GRID_M)
	var gy := floori(y / GRID_M)
	for r in ceili(max_d / GRID_M) + 1:
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var cell: Variant = _grid.get(Vector2i(gx + dx, gy + dy))
				if cell != null:
					for si in cell as PackedInt32Array:
						_consider(si, x, y)
		if hit_d < r * GRID_M:
			break
	return hit_d <= max_d


# Nearest road point among a pre-gathered candidate list (see candidates_for).
func nearest_in(x: float, y: float, cands: PackedInt32Array, max_d: float) -> bool:
	hit_d = INF
	_hit_si = -1
	for si in cands:
		_consider(si, x, y)
	return hit_d <= max_d


# Every segment that can be the nearest road for any point within `half_diag` of the centre:
# if the centre's nearest road is D away, no point in the area has its nearest road further
# than D + 2·half_diag from the centre. Gathered once per chunk so per-sample queries stay small.
func candidates_for(cx: float, cy: float, half_diag: float, max_d: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	if not nearest(cx, cy, max_d + half_diag):
		return out
	var reach := hit_d + 2.0 * half_diag
	var seen := {}
	for c in _cells(cx - reach, cy - reach, cx + reach, cy + reach, GRID_M):
		var cell: Variant = _grid.get(c)
		if cell == null:
			continue
		for si in cell as PackedInt32Array:
			if seen.has(si):
				continue
			seen[si] = true
			if _seg_dist(si, cx, cy) <= reach:
				out.append(si)
	return out


func _seg_dist(si: int, x: float, y: float) -> float:
	var ax := seg_ax[si]
	var ay := seg_ay[si]
	var abx := seg_bx[si] - ax
	var aby := seg_by[si] - ay
	var l2 := abx * abx + aby * aby
	var t := maxf(0.0, minf(1.0, ((x - ax) * abx + (y - ay) * aby) / (l2 if l2 != 0.0 else 1.0)))
	return LabNoise.hyp(x - (ax + abx * t), y - (ay + aby * t))


func _consider(si: int, x: float, y: float) -> void:
	var ax := seg_ax[si]
	var ay := seg_ay[si]
	var abx := seg_bx[si] - ax
	var aby := seg_by[si] - ay
	var l2 := abx * abx + aby * aby
	var t := maxf(0.0, minf(1.0, ((x - ax) * abx + (y - ay) * aby) / (l2 if l2 != 0.0 else 1.0)))
	var qx := ax + abx * t
	var qy := ay + aby * t
	var d := LabNoise.hyp(x - qx, y - qy)
	# near-ties (where two roads share a junction point) go to the lower segment, so rounding never decides
	if d < hit_d - 1e-9 or (absf(d - hit_d) <= 1e-9 and si < _hit_si):
		var length := seg_len[si] if seg_len[si] != 0.0 else 1.0
		hit_d = d
		_hit_si = si
		hit_qx = qx
		hit_qy = qy
		hit_s = seg_cum[si] + seg_len[si] * t
		hit_edge = seg_edge[si]
		hit_side = signf(abx * (y - ay) - aby * (x - ax))
		hit_dx = abx / length
		hit_dy = aby / length


func _seg_hits_water(ax: float, ay: float, bx: float, by: float) -> bool:
	var n := ceili(LabNoise.hyp(ax - bx, ay - by) / 60.0 - 1e-9)
	for i in range(1, n):
		if _terrain.is_water(ax + (bx - ax) * i / n, ay + (by - ay) * i / n):
			return true
	return false


func _lowest_node_within(grid: Dictionary, x: float, y: float, exclude: int) -> int:
	var r := _s.node_spacing_m
	var c := _cell(x, y, r)
	var best := -1
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var cell: Variant = grid.get(c + Vector2i(dx, dy))
			if cell == null:
				continue
			for i in cell as PackedInt32Array:
				if i != exclude and (best < 0 or i < best) and LabNoise.hyp(node_x[i] - x, node_y[i] - y) < r:
					best = i
	return best


# The lab's segsCross: a proper crossing only; touching at an end does not count.
static func _segs_cross(ax: float, ay: float, bx: float, by: float, cx: float, cy: float, dx: float, dy: float) -> bool:
	return _orient(ax, ay, bx, by, cx, cy) * _orient(ax, ay, bx, by, dx, dy) < 0.0 \
		and _orient(cx, cy, dx, dy, ax, ay) * _orient(cx, cy, dx, dy, bx, by) < 0.0


static func _orient(px: float, py: float, qx: float, qy: float, rx: float, ry: float) -> float:
	return signf((qx - px) * (ry - py) - (qy - py) * (rx - px))


func _crosses_edge(grid: Dictionary, ax: float, ay: float, bx: float, by: float, ex1: int, ex2: int) -> bool:
	for c in _cells(ax, ay, bx, by, _s.segment_m):
		var cell: Variant = grid.get(c)
		if cell == null:
			continue
		for ei in cell as PackedInt32Array:
			var e := edges[ei]
			if e.x == ex1 or e.y == ex1 or e.x == ex2 or e.y == ex2:
				continue
			if _segs_cross(ax, ay, bx, by, node_x[e.x], node_y[e.x], node_x[e.y], node_y[e.y]):
				return true
	return false


func _add_edge(grid: Dictionary, edge_set: Dictionary, a: int, b: int) -> void:
	edges.append(Vector2i(a, b))
	edge_set[_edge_key(a, b)] = true
	for c in _cells(node_x[a], node_y[a], node_x[b], node_y[b], _s.segment_m):
		_append_to(grid, c, edges.size() - 1)


static func _rad(deg: float) -> float:
	return deg * PI / 180.0


static func _cell(x: float, y: float, cell_m: float) -> Vector2i:
	return Vector2i(floori(x / cell_m), floori(y / cell_m))


# Packed arrays are values in GDScript: appending to one fetched from a Dictionary changes a
# copy, so the result has to be written back.
static func _append_to(grid: Dictionary, key: Vector2i, value: int) -> void:
	var arr: PackedInt32Array = grid.get(key, PackedInt32Array())
	arr.append(value)
	grid[key] = arr


static func _edge_key(a: int, b: int) -> Vector2i:
	return Vector2i(mini(a, b), maxi(a, b))


static func _cells(ax: float, ay: float, bx: float, by: float, cell_m: float) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for gx in range(floori(minf(ax, bx) / cell_m), floori(maxf(ax, bx) / cell_m) + 1):
		for gy in range(floori(minf(ay, by) / cell_m), floori(maxf(ay, by) / cell_m) + 1):
			out.append(Vector2i(gx, gy))
	return out
