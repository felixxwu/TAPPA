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
# Each segment's midpoint and half-length: no point is nearer to it than its distance from the
# midpoint less the half-length, which lets nearest_in skip most candidates cheaply.
var seg_mx := PackedFloat64Array()
var seg_my := PackedFloat64Array()
var seg_half := PackedFloat64Array()
var edge_first_seg := PackedInt32Array()  # each edge's segments are contiguous from here
var edge_len := PackedFloat64Array()  # each edge's arc length
var node_degree := PackedInt32Array()  # how many edges meet at each node
var side_road_car := {}  # a side road's dead-end node -> the car parked there
var fork_nodes := PackedInt32Array()  # genuine forks: nodes where 3+ main (not side) roads meet
var _side_edges := {}  # side road edges, as a set
var _poly_x: Array[PackedFloat64Array] = []  # every edge's polyline, kept so side roads can be added after build
var _poly_y: Array[PackedFloat64Array] = []
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


func node(i: int) -> Vector2:
	return Vector2(node_x[i], node_y[i])


func build(settings: FreeRoamSettings, terrain: RoadTerrain) -> void:
	_s = settings
	_terrain = terrain
	if _s.straight_road_m > 0.0:
		node_x = PackedFloat64Array([0.0, _s.straight_road_m])
		node_y = PackedFloat64Array([0.0, 0.0])
		edges = [Vector2i(0, 1)]
	else:
		_grow()
		_prune_dead_ends()
	node_degree.resize(node_x.size())
	node_degree.fill(0)
	for e in edges:
		node_degree[e.x] += 1
		node_degree[e.y] += 1
	_densify()


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
# run into it, ending only at the coast. A spatial grid speeds up the "is there a node near here" scan, but always picks
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
		if not _terrain.on_land(tx, ty) or _seg_leaves_island(fx, fy, tx, ty):
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


# The lab's growthPruned(): each dead end is followed back to its junction (or spawn) and the
# whole spur cut if it is no longer than prune_dead_ends_m. Repeats until nothing is cut, so a
# fork whose branches were all cut becomes a dead end itself.
func _prune_dead_ends() -> void:
	while true:
		var adj: Array[PackedInt32Array] = []
		adj.resize(node_x.size())
		for k in edges.size():
			adj[edges[k].x].append(k)
			adj[edges[k].y].append(k)
		var cut := {}
		for i in range(1, node_x.size()):
			if adj[i].size() != 1:
				continue
			var spur := PackedInt32Array()
			var cur := i
			var k := adj[i][0]
			var length := 0.0
			while true:
				spur.append(k)
				var nxt := edges[k].y if edges[k].x == cur else edges[k].x
				length += LabNoise.hyp(node_x[nxt] - node_x[cur], node_y[nxt] - node_y[cur])
				cur = nxt
				if cur == 0 or adj[cur].size() != 2:
					break
				k = adj[cur][1] if adj[cur][0] == k else adj[cur][0]
			if length <= _s.prune_dead_ends_m:
				for j in spur:
					cut[j] = true
		if cut.is_empty():
			return
		var kept_edges: Array[Vector2i] = []
		var used := {0: true}
		for k in edges.size():
			if not cut.has(k):
				kept_edges.append(edges[k])
				used[edges[k].x] = true
				used[edges[k].y] = true
		var new_index := {}
		var xs := PackedFloat64Array()
		var ys := PackedFloat64Array()
		for i in node_x.size():
			if used.has(i):
				new_index[i] = xs.size()
				xs.append(node_x[i])
				ys.append(node_y[i])
		node_x = xs
		node_y = ys
		edges.clear()
		for e in kept_edges:
			edges.append(Vector2i(new_index[e.x], new_index[e.y]))


# The lab's wiggle(): each link as a seeded noise offset inside a band around its straight
# line, landing exactly on both ends. Twistiness sets how far it swings, bend length how often.
func _densify() -> void:
	var step := minf(40.0, _s.bend_length_m / 6.0)
	var all_x: Array[PackedFloat64Array] = []
	var all_y: Array[PackedFloat64Array] = []
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
		var twist := 0.0 if _s.straight_road_m > 0.0 else _s.road_twist
		var amp := minf(d * twist, 1200.0 * twist)
		var px := PackedFloat64Array()
		var py := PackedFloat64Array()
		for i in n + 1:
			var t := float(i) / n
			var env := sin(t * PI)
			var off := (LabNoise.fbm(t * d / _s.bend_length_m, 0.0, s) - 0.5) * 2.0 * amp * env
			px.append(ax + (bx - ax) * t + nx * off)
			py.append(ay + (by - ay) * t + ny * off)
		all_x.append(px)
		all_y.append(py)
	_round_corners(all_x, all_y)
	_poly_x = all_x
	_poly_y = all_y
	_flatten()


# Every polyline cut into segments, gridded for the nearest-road queries.
func _flatten() -> void:
	seg_ax.clear(); seg_ay.clear(); seg_bx.clear(); seg_by.clear()
	seg_len.clear(); seg_cum.clear(); seg_edge.clear(); edge_first_seg.clear(); edge_len.clear()
	seg_mx.clear(); seg_my.clear(); seg_half.clear()
	_grid.clear()
	total_length_m = 0.0
	var all_x := _poly_x
	var all_y := _poly_y
	for ei in edges.size():
		var px := all_x[ei]
		var py := all_y[ei]
		edge_first_seg.append(seg_ax.size())
		var cum := 0.0
		for i in px.size() - 1:
			var si := seg_ax.size()
			var length := LabNoise.hyp(px[i] - px[i + 1], py[i] - py[i + 1])
			seg_ax.append(px[i]); seg_ay.append(py[i]); seg_bx.append(px[i + 1]); seg_by.append(py[i + 1])
			seg_len.append(length); seg_cum.append(cum); seg_edge.append(ei)
			seg_mx.append((px[i] + px[i + 1]) * 0.5); seg_my.append((py[i] + py[i + 1]) * 0.5); seg_half.append(length * 0.5)
			cum += length
			for c in _cells(px[i], py[i], px[i + 1], py[i + 1], GRID_M):
				_append_to(_grid, c, si)
		edge_len.append(cum)
		total_length_m += cum
	find_forks()


# The genuine forks: every node where three or more main roads meet. A side road to a parked car
# splits its main road in two at the branch, which makes a degree-3 node too, but only two of its
# roads are main, so it is not a fork — taking it leads nowhere but the car. Rebuilt with _flatten.
func find_forks() -> void:
	fork_nodes.clear()
	var main := PackedInt32Array()
	main.resize(node_x.size())
	for ei in edges.size():
		if is_side_road(ei):
			continue
		main[edges[ei].x] += 1
		main[edges[ei].y] += 1
	for n in main.size():
		if main[n] >= 3:
			fork_nodes.append(n)


# The nearest fork within `max_d` of (x, y) (world xz), or -1.
func fork_near(x: float, y: float, max_d: float) -> int:
	var best := -1
	var best_d2 := max_d * max_d
	for n in fork_nodes:
		var d2 := (node_x[n] - x) * (node_x[n] - x) + (node_y[n] - y) * (node_y[n] - y)
		if d2 <= best_d2:
			best_d2 = d2
			best = n
	return best


func is_side_road(ei: int) -> bool:
	return _side_edges.has(ei)


# After build: each car in `cars` ([{"id": String, "ring": int}]) gets a short straight road
# branching off at right angles from a random point on a road in its ring, ending where the car is
# parked. A car whose ring has no room goes to the nearest ring that does, and if none has, the
# rules relax (shorter, then closer to other roads) so every car is always placed. No side road
# leaves the edges in `keep_clear` (the cold open's road, ColdOpen.roads_to_keep_clear).
func add_side_roads(cars: Array, keep_clear := {}) -> void:
	_add_side_roads(_poly_x, _poly_y, cars, keep_clear)
	_flatten()


func _add_side_roads(xs: Array[PackedFloat64Array], ys: Array[PackedFloat64Array], cars: Array, keep_clear: Dictionary) -> void:
	side_road_car.clear()
	_side_edges.clear()
	if cars.is_empty() or edges.is_empty() or _s.straight_road_m > 0.0:
		return
	var rng := LabNoise.Rng.new(_s.world_seed * 104729 + 7)
	var segs := PackedFloat64Array()  # ax, ay, bx, by per segment, for the clearance checks
	var grid := {}
	for ei in xs.size():
		_add_segs(segs, grid, xs[ei], ys[ei])
	var branches := PackedVector2Array()
	# [length, clearance from other roads, clearance of the branch from junctions and other branches]
	var jc := _s.side_road_junction_clear_m
	var phases := [[_s.side_road_max_m, _s.side_road_clear_m, jc], [_s.side_road_min_m, _s.side_road_clear_m, jc],
		[_s.side_road_min_m, _s.side_road_clear_m * 0.5, jc], [_s.rest_stop_radius_m * 3.0, _s.road_half_width_m * 4.0, jc],
		[_s.rest_stop_radius_m * 3.0, _s.road_half_width_m * 4.0, RoadSites.JUNCTION_CLEAR_M]]
	for car: Dictionary in cars:
		var want := clampi(int(car.get("ring", 0)), 0, _s.ring_count - 1)
		var rings := range(_s.ring_count)
		rings.sort_custom(func(a: int, b: int) -> bool: return absi(a - want) < absi(b - want) or (absi(a - want) == absi(b - want) and a < b))
		var placed := false
		for ph: Array in phases:
			var spots := _branch_spots(xs, ys, branches, keep_clear, ph[2])
			for r: int in rings:
				var list: Array = spots[r]
				for _try in mini(40, list.size()):
					var spot: Vector2i = list[floori(rng.next() * list.size())]
					var side := 1.0 if rng.next() < 0.5 else -1.0
					var px := xs[spot.x]
					var py := ys[spot.x]
					var i := spot.y
					var tx := px[i + 1] - px[i - 1]
					var ty := py[i + 1] - py[i - 1]
					var tl := LabNoise.hyp(tx, ty)
					for sd in [side, -side]:
						var nx: float = -ty / tl * sd
						var ny: float = tx / tl * sd
						if _spur_ok(px[i], py[i], nx, ny, ph[0], ph[1], segs, grid):
							_split_and_branch(xs, ys, spot.x, i, nx, ny, ph[0], String(car["id"]), segs, grid)
							branches.append(Vector2(px[i], py[i]))
							placed = true
							break
					if placed:
						break
				if placed:
					break
			if placed:
				break
		if not placed:
			push_warning("RoadNetwork: no room anywhere for car %s's side road" % car.get("id", "?"))


# Every polyline point a side road may branch from, per ring, as Vector2i(edge, point): on a main
# road not in `keep_clear`, `clear` along from both of its ends and that far from other branches.
func _branch_spots(xs: Array[PackedFloat64Array], ys: Array[PackedFloat64Array], branches: PackedVector2Array,
		keep_clear: Dictionary, clear: float) -> Array:
	var out: Array = []
	for r in _s.ring_count:
		out.append([])
	for ei in xs.size():
		if _side_edges.has(ei) or keep_clear.has(ei):
			continue
		var px := xs[ei]
		var py := ys[ei]
		var cum := PackedFloat64Array([0.0])
		for i in px.size() - 1:
			cum.append(cum[i] + LabNoise.hyp(px[i + 1] - px[i], py[i + 1] - py[i]))
		var length := cum[cum.size() - 1]
		for i in range(1, px.size() - 1):
			if cum[i] < clear or length - cum[i] < clear:
				continue
			var p := Vector2(px[i], py[i])
			var taken := false
			for b in branches:
				taken = taken or b.distance_to(p) < clear * 2.0
			if not taken:
				(out[_terrain.ring_index(px[i], py[i])] as Array).append(Vector2i(ei, i))
	return out


# Whether a side road from (x, y) along (nx, ny) for `length` stays on dry land, crosses no road,
# and keeps `clear` from every other road once it is that far out (nearer in, at least as far as it
# has come, so it can't run alongside or into another road).
func _spur_ok(x: float, y: float, nx: float, ny: float, length: float, clear: float,
		segs: PackedFloat64Array, grid: Dictionary) -> bool:
	var n := ceili(length / 20.0)
	for k in range(1, n + 1):
		var s := length * k / n
		var qx := x + nx * s
		var qy := y + ny * s
		if _terrain.is_water(qx, qy):
			return false
		if _nearest_seg_d(segs, grid, qx, qy, clear) < minf(s * 0.9, clear):
			return false
	return true


func _nearest_seg_d(segs: PackedFloat64Array, grid: Dictionary, x: float, y: float, max_d: float) -> float:
	var best := INF
	for gx in range(floori((x - max_d) / GRID_M), floori((x + max_d) / GRID_M) + 1):
		for gy in range(floori((y - max_d) / GRID_M), floori((y + max_d) / GRID_M) + 1):
			for si in grid.get(Vector2i(gx, gy), PackedInt32Array()):
				var a := Vector2(segs[si * 4], segs[si * 4 + 1])
				var b := Vector2(segs[si * 4 + 2], segs[si * 4 + 3])
				best = minf(best, Vector2(x, y).distance_to(Geometry2D.get_closest_point_to_segment(Vector2(x, y), a, b)))
	return best


static func _add_segs(segs: PackedFloat64Array, grid: Dictionary, px: PackedFloat64Array, py: PackedFloat64Array) -> void:
	for i in px.size() - 1:
		var si := segs.size() / 4
		segs.append_array([px[i], py[i], px[i + 1], py[i + 1]])
		for c in _cells(px[i], py[i], px[i + 1], py[i + 1], GRID_M):
			_append_to(grid, c, si)


# Edge `ei` is cut in two at its point `i`, which becomes a junction, and the side road runs from
# there to a new dead end where `car_id` is parked.
func _split_and_branch(xs: Array[PackedFloat64Array], ys: Array[PackedFloat64Array], ei: int, i: int,
		nx: float, ny: float, length: float, car_id: String, segs: PackedFloat64Array, grid: Dictionary) -> void:
	var px := xs[ei]
	var py := ys[ei]
	var mid := node_x.size()
	node_x.append(px[i])
	node_y.append(py[i])
	node_degree.append(3)
	var far := edges[ei].y
	edges[ei] = Vector2i(edges[ei].x, mid)
	xs[ei] = px.slice(0, i + 1)
	ys[ei] = py.slice(0, i + 1)
	edges.append(Vector2i(mid, far))
	xs.append(px.slice(i))
	ys.append(py.slice(i))
	var end := node_x.size()
	node_x.append(px[i] + nx * length)
	node_y.append(py[i] + ny * length)
	node_degree.append(1)
	var n := maxi(2, ceili(length / 40.0))
	var sx := PackedFloat64Array()
	var sy := PackedFloat64Array()
	for k in n + 1:
		sx.append(px[i] + nx * length * k / n)
		sy.append(py[i] + ny * length * k / n)
	_side_edges[edges.size()] = true
	edges.append(Vector2i(mid, end))
	xs.append(sx)
	ys.append(sy)
	_add_segs(segs, grid, sx, sy)
	side_road_car[end] = car_id


# Rounds off every bend sharper than max_corner_turn_deg by cutting the corner: the point becomes
# two points a quarter of the way along its two segments, which about halves the bend, repeated
# until none is too sharp. Where exactly two links meet, the cut spans both and the node moves to
# its middle; spawn, junctions and dead ends stay put.
func _round_corners(xs: Array[PackedFloat64Array], ys: Array[PackedFloat64Array]) -> void:
	var max_turn := _rad(_s.max_corner_turn_deg)
	var ends := {}  # node -> [[edge, true if the edge starts there], ...]
	for ei in edges.size():
		for at_start in [true, false]:
			var nd := edges[ei].x if at_start else edges[ei].y
			if nd != 0 and node_degree[nd] == 2:
				ends[nd] = ends.get(nd, []) + [[ei, at_start]]
	for _pass in 6:
		var cut_any := false
		for ei in xs.size():
			var px := xs[ei]
			var py := ys[ei]
			var ox := PackedFloat64Array([px[0]])
			var oy := PackedFloat64Array([py[0]])
			for i in range(1, px.size() - 1):
				if _turn(px[i - 1], py[i - 1], px[i], py[i], px[i + 1], py[i + 1]) > max_turn:
					ox.append(px[i] + (px[i - 1] - px[i]) * 0.25)
					oy.append(py[i] + (py[i - 1] - py[i]) * 0.25)
					ox.append(px[i] + (px[i + 1] - px[i]) * 0.25)
					oy.append(py[i] + (py[i + 1] - py[i]) * 0.25)
					cut_any = true
				else:
					ox.append(px[i])
					oy.append(py[i])
			ox.append(px[px.size() - 1])
			oy.append(py[py.size() - 1])
			xs[ei] = ox
			ys[ei] = oy
		for nd in ends:
			var a: Array = ends[nd][0]
			var b: Array = ends[nd][1]
			var ia := 1 if a[1] else xs[a[0]].size() - 2
			var ib := 1 if b[1] else xs[b[0]].size() - 2
			var x := node_x[nd]
			var y := node_y[nd]
			var ax := xs[a[0]][ia]
			var ay := ys[a[0]][ia]
			var bx := xs[b[0]][ib]
			var by := ys[b[0]][ib]
			if _turn(ax, ay, x, y, bx, by) <= max_turn:
				continue
			var cax := x + (ax - x) * 0.25
			var cay := y + (ay - y) * 0.25
			var cbx := x + (bx - x) * 0.25
			var cby := y + (by - y) * 0.25
			node_x[nd] = (cax + cbx) * 0.5
			node_y[nd] = (cay + cby) * 0.5
			_move_end(xs, ys, a[0], a[1], cax, cay, node_x[nd], node_y[nd])
			_move_end(xs, ys, b[0], b[1], cbx, cby, node_x[nd], node_y[nd])
			cut_any = true
		if not cut_any:
			return


# Replaces the end of edge `ei` with a corner point `c` followed by the moved node `m`.
static func _move_end(xs: Array[PackedFloat64Array], ys: Array[PackedFloat64Array], ei: int, at_start: bool,
		cx: float, cy: float, mx: float, my: float) -> void:
	var px := xs[ei]
	var py := ys[ei]
	if at_start:
		px[0] = mx
		py[0] = my
		px.insert(1, cx)
		py.insert(1, cy)
	else:
		px[px.size() - 1] = cx
		py[py.size() - 1] = cy
		px.append(mx)
		py.append(my)
	xs[ei] = px
	ys[ei] = py


# How sharply the road turns at b, coming from a and going on to c (radians, 0 = straight on).
static func _turn(ax: float, ay: float, bx: float, by: float, cx: float, cy: float) -> float:
	var ux := bx - ax
	var uy := by - ay
	var vx := cx - bx
	var vy := cy - by
	return absf(atan2(ux * vy - uy * vx, ux * vx + uy * vy))


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
	if _grid.is_empty():
		return false
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
		# a segment whose nearest possible point is already further than the best found can't win
		# (nor tie: the margin keeps near-ties in, so the answer is the full scan's)
		var mx := x - seg_mx[si]
		var my := y - seg_my[si]
		var reach := hit_d + seg_half[si] + 1e-6
		if mx * mx + my * my > reach * reach:
			continue
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
	# nearest the centre first, so a search through them finds a close road early and can skip
	# the rest (nearest_in); the order never changes its answer
	var by_d := Array(out)
	by_d.sort_custom(func(a: int, b: int) -> bool: return _seg_dist(a, cx, cy) < _seg_dist(b, cx, cy))
	return PackedInt32Array(by_d)


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


# Only the sea stops a road: lakes are driven through and filled in behind it (RoadTerrain.fill_cut_lakes).
func _seg_leaves_island(ax: float, ay: float, bx: float, by: float) -> bool:
	var n := ceili(LabNoise.hyp(ax - bx, ay - by) / 60.0 - 1e-9)
	for i in range(1, n):
		if not _terrain.on_land(ax + (bx - ax) * i / n, ay + (by - ay) * i / n):
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
