class_name RoadSites
extends RefCounted
# Docs: features/free-roam.md — update in the same change as this file.
# Tests: tests/headless/test_free_roam.gd — extend in the same change.
# The places that hang off the road network, planned once at boot from the whole graph
# (todo/2026-10-19-free-roam-pivot.md, decisions 30–31):
#   REST     — rest stops, one every `rest_stop_spacing_m` of road (set per region), counted
#              along the roads outward from spawn. Spawn itself is the first one.
#   LOOT     — loot spots in the middle of the road, every `loot_slot_spacing_m`, picked up by
#              driving over them. These are SLOTS: stage 7 decides which hold something.
#   DEAD_END — the clearing at the end of every road that stops (a node with one road, not spawn).
#              Each gets a payoff later.
# Rest stops and dead ends are flat round pads beside (or at the end of) their road. RoadTerrain
# flattens the ground under one to the road's height and reads it as road surface, so the car can
# pull in. A loot spot has no pad (radius 0) and leaves the ground alone.

enum Kind { REST, LOOT, DEAD_END }

# A car that moves further than this in one physics step was teleported, not driven.
const TELEPORT_M := 100.0
const GRID_M := 100.0
# Every site by the cell its centre is in, so in_box (run every physics tick) skips the rest of the island.
const BOX_CELL_M := 250.0
# Keep sites this far from a junction along the road, so a pad never sits in a fork.
const JUNCTION_CLEAR_M := 45.0
# When a site doesn't fit where it's due, how much further along the road the next try is.
const RETRY_STEP_M := 40.0

var kind := PackedInt32Array()
var pos := PackedVector2Array()      # pad centre
var anchor := PackedVector2Array()   # the road point the pad hangs off
var dir := PackedVector2Array()      # road direction at the anchor
var radius := PackedFloat32Array()
var pad_h := PackedFloat32Array()    # the pad's flat height (the road's height at the anchor)
var ring := PackedInt32Array()
var edge := PackedInt32Array()       # the road link it hangs off (-1 for spawn)
var node := PackedInt32Array()       # the junction for spawn and dead ends, else -1
var _grid := {}  # Vector2i -> PackedInt32Array
var _box_cells := {}  # Vector2i -> PackedInt32Array, by BOX_CELL_M
var _blend := 12.0  # the widest a pad's blend can reach
var _blend_min := 12.0
var _max_slope := 0.25
var _max_r := 0.0


func count() -> int:
	return kind.size()


func of_kind(k: Kind) -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in kind.size():
		if kind[i] == k:
			out.append(i)
	return out


# Plan every site. `terrain` is used for land checks and pad heights, and must not have these
# sites attached yet (its heights would read the pads being planned).
func build(s: FreeRoamSettings, net: RoadNetwork, terrain: RoadTerrain) -> void:
	_blend = s.pad_blend_max_m
	_blend_min = s.pad_blend_m
	_max_slope = s.pad_blend_max_slope
	var adj := {}
	for ei in net.edges.size():
		var e := net.edges[ei]
		if not adj.has(e.x): adj[e.x] = []
		if not adj.has(e.y): adj[e.y] = []
		adj[e.x].append(ei)
		adj[e.y].append(ei)
	# Spawn: the first rest stop, centred on the spawn junction, its direction the road out.
	_add(Kind.REST, Vector2.ZERO, Vector2.ZERO, _road_out_of_spawn(net), s.rest_stop_radius_m, terrain, -1, 0)
	# Rest stops and loot spots: breadth-first from spawn, carrying "road since the last one"
	# into each junction (the least over the ways in), so the gap along any drive is about the
	# spacing. Rest stops go first over the whole network, so loot can keep clear of them.
	for k in [Kind.REST, Kind.LOOT]:
		var carried := {0: 0.0 if k == Kind.REST else s.loot_slot_spacing_m * 0.5}
		var queue: Array[int] = [0]
		var done_edge := {}
		var head := 0
		while head < queue.size():
			var at: int = queue[head]
			head += 1
			if not adj.has(at):
				continue
			for ei: int in adj[at]:
				if done_edge.has(ei):
					continue
				done_edge[ei] = true
				var e := net.edges[ei]
				var other := e.y if e.x == at else e.x
				var pts := net.polyline(ei)
				if e.x != at:
					pts.reverse()
				var left := _place_along(k, s, net, terrain, ei, pts, float(carried[at]))
				if not carried.has(other) or left < float(carried[other]):
					carried[other] = left
				if not queue.has(other):
					queue.append(other)
	# Dead ends.
	for n: int in adj.keys():
		if n != 0 and (adj[n] as Array).size() == 1:
			var ei: int = adj[n][0]
			var e := net.edges[ei]
			var pts := net.polyline(ei)
			if e.y != n:
				pts.reverse()  # so the polyline ends at the dead end
			var end := pts[pts.size() - 1]
			var d := (end - pts[pts.size() - 2]).normalized()
			_add(Kind.DEAD_END, end, end, d, s.dead_end_radius_m, terrain, ei, n)


# Walk a link from its start, `since` metres after the last site of this kind; place one each time
# the gap reaches the spacing (for a rest stop, the spacing of the ring there), never within
# JUNCTION_CLEAR_M of either end: a site due too near the start waits for the clear stretch, and
# one due too near the end carries over to the next link. Returns the gap left at the far end.
func _place_along(k: Kind, s: FreeRoamSettings, net: RoadNetwork, terrain: RoadTerrain, ei: int,
		pts: PackedVector2Array, since: float) -> float:
	var cum := PackedFloat64Array([0.0])
	for i in pts.size() - 1:
		cum.append(cum[i] + pts[i].distance_to(pts[i + 1]))
	var length := cum[cum.size() - 1]
	var last := -since
	var guard := 0
	while guard < 1000:
		guard += 1
		var spacing := rest_spacing_at(s, terrain, _at(pts, cum, clampf(last, 0.0, length))) if k == Kind.REST \
			else s.loot_slot_spacing_m
		var at_s := maxf(last + spacing, JUNCTION_CLEAR_M)
		if at_s > length - JUNCTION_CLEAR_M:
			break
		var p := _at(pts, cum, at_s)
		var d := (_at(pts, cum, minf(at_s + 1.0, length)) - _at(pts, cum, maxf(at_s - 1.0, 0.0))).normalized()
		var ok := false
		if k == Kind.REST:
			ok = _try_roadside(k, s, net, terrain, ei, p, d, s.rest_stop_radius_m)
		elif not _near_site(p, s.rest_stop_radius_m + 40.0) and not terrain.is_water(p.x, p.y):
			_add(k, p, p, d, 0.0, terrain, ei, -1)
			ok = true
		# no room here (water, another road, a rest stop): try again a little further on
		last = at_s if ok else at_s - spacing + RETRY_STEP_M
	return length - last


static func _at(pts: PackedVector2Array, cum: PackedFloat64Array, arc: float) -> Vector2:
	var i := cum.bsearch(arc) - 1
	i = clampi(i, 0, pts.size() - 2)
	var seg := cum[i + 1] - cum[i]
	return pts[i].lerp(pts[i + 1], clampf((arc - cum[i]) / maxf(seg, 1e-6), 0.0, 1.0))


# A pad beside the road at `p`, on whichever side (hash first, then the other) is dry land and
# nearest to this road rather than another. False when neither side fits.
func _try_roadside(k: Kind, s: FreeRoamSettings, net: RoadNetwork, terrain: RoadTerrain, ei: int,
		p: Vector2, d: Vector2, r: float) -> bool:
	var normal := Vector2(-d.y, d.x)
	var first := 1.0 if ScatterMath.hash01(floori(p.x), floori(p.y), s.world_seed, 77 + k) < 0.5 else -1.0
	for side in [first, -first]:
		var c: Vector2 = p + normal * side * (s.road_half_width_m + r * 0.6)
		if terrain.is_water(c.x, c.y) or _near_site(c, r + 10.0):
			continue
		if not net.nearest(c.x, c.y, r + s.road_half_width_m + s.road_shoulder_m + 2.0) or net.hit_edge != ei:
			continue  # another road is as near: this pad would sit across it
		_add(k, c, p, d, r, terrain, ei, -1)
		return true
	return false


# The way the (first) road leaves spawn, so the car starts driving off along it with the cabin
# behind it (back). Vector2.RIGHT when no road leaves spawn.
static func _road_out_of_spawn(net: RoadNetwork) -> Vector2:
	for ei in net.edges.size():
		var e := net.edges[ei]
		if e.x != 0 and e.y != 0:
			continue
		var pl := net.polyline(ei)
		if pl.size() < 2:
			continue
		var out := pl[1] - pl[0] if e.x == 0 else pl[pl.size() - 2] - pl[pl.size() - 1]
		if out != Vector2.ZERO:
			return out.normalized()
	return Vector2.RIGHT


# The way from site `i`'s road to the back of its pad, where its cabin stands: away from the
# road for a roadside pad, and back down the road out for spawn, whose pad sits on its junction.
func back(i: int) -> Vector2:
	if anchor[i] != pos[i]:
		return (pos[i] - anchor[i]).normalized()
	return -dir[i] if dir[i] != Vector2.ZERO else Vector2.UP


func _add(k: Kind, c: Vector2, a: Vector2, d: Vector2, r: float, terrain: RoadTerrain, ei: int, n: int) -> void:
	var i := kind.size()
	kind.append(k)
	pos.append(c)
	anchor.append(a)
	dir.append(d)
	radius.append(r)
	pad_h.append(terrain.height(a.x, a.y, PackedInt32Array(), false))
	ring.append(terrain.ring_index(c.x, c.y))
	edge.append(ei)
	node.append(n)
	_max_r = maxf(_max_r, r)
	var cell := Vector2i(floori(c.x / BOX_CELL_M), floori(c.y / BOX_CELL_M))
	var in_cell: PackedInt32Array = _box_cells.get(cell, PackedInt32Array())
	in_cell.append(i)
	_box_cells[cell] = in_cell
	if r <= 0.0:
		return  # no pad, so nothing for the terrain or planting to look up
	var reach := r + _blend
	for gx in range(floori((c.x - reach) / GRID_M), floori((c.x + reach) / GRID_M) + 1):
		for gy in range(floori((c.y - reach) / GRID_M), floori((c.y + reach) / GRID_M) + 1):
			var key := Vector2i(gx, gy)
			var list: PackedInt32Array = _grid.get(key, PackedInt32Array())
			list.append(i)
			_grid[key] = list


static func rest_spacing_at(s: FreeRoamSettings, terrain: RoadTerrain, p: Vector2) -> float:
	var region := BiomeDirector.region_of(s, terrain.ring_index(p.x, p.y))
	return maxf(50.0, RegionLibrary.rest_stop_spacing_of(region, s.rest_stop_spacing_m))


func _near_site(p: Vector2, d: float) -> bool:
	for i in kind.size():
		if pos[i].distance_to(p) < d + radius[i]:
			return true
	return false


# The site whose pad (plus its blend skirt) covers `p`, nearest first; -1 when none.
func pad_at(x: float, y: float) -> int:
	var list: PackedInt32Array = _grid.get(Vector2i(floori(x / GRID_M), floori(y / GRID_M)), PackedInt32Array())
	var best := -1
	var best_t := INF
	for i in list:
		var d := Vector2(x, y).distance_to(pos[i]) - radius[i]
		if d < _blend and d < best_t:
			best_t = d
			best = i
	return best


# How far `p` is outside site `i`'s flat pad (negative inside).
func outside(i: int, x: float, y: float) -> float:
	return Vector2(x, y).distance_to(pos[i]) - radius[i]


# The nearest site the car's path from `a` to `b` (this frame's travel) came within reach of — its
# pad radius plus `margin` from its centre — among those `want(i)` accepts; -1 if none. Swept, so a
# fast car can't skip over a site between two frames. A rest stop's pad sits beside its road, so a
# margin of the road's full width means driving past on either lane counts.
func reached(a: Vector2, b: Vector2, margin: float, want: Callable) -> int:
	var lo := Vector2(minf(a.x, b.x), minf(a.y, b.y)) - Vector2.ONE * (margin + 50.0)
	var hi := Vector2(maxf(a.x, b.x), maxf(a.y, b.y)) + Vector2.ONE * (margin + 50.0)
	var best := -1
	var best_d := INF
	for i in in_box(lo.x, lo.y, hi.x, hi.y):
		var d := pos[i].distance_to(Geometry2D.get_closest_point_to_segment(pos[i], a, b))
		if d <= radius[i] + margin and d < best_d and want.call(i):
			best = i
			best_d = d
	return best


# How far either side of a pad's centre the whole road beside it reaches past the pad's edge: the
# reach margin for drive-past pickups and rest stops (see reached).
static func road_margin(s: FreeRoamSettings) -> float:
	return s.road_half_width_m * 2.0 + s.road_shoulder_m


# How wide a pad's blend back to the land is, given the height gap `dh` it has to cover there.
func blend_m(dh: float) -> float:
	return clampf(absf(dh) / maxf(_max_slope, 0.001), _blend_min, _blend)


# Every site whose pad touches the axis-aligned box.
func in_box(x0: float, y0: float, x1: float, y1: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	for cx in range(floori((x0 - _max_r) / BOX_CELL_M), floori((x1 + _max_r) / BOX_CELL_M) + 1):
		for cy in range(floori((y0 - _max_r) / BOX_CELL_M), floori((y1 + _max_r) / BOX_CELL_M) + 1):
			for i in _box_cells.get(Vector2i(cx, cy), PackedInt32Array()):
				var c := pos[i]
				var r := radius[i]
				if c.x + r >= x0 and c.x - r <= x1 and c.y + r >= y0 and c.y - r <= y1:
					out.append(i)
	out.sort()
	return out


# True when `p` is at least `margin` clear of every pad.
func is_clear(p: Vector2, margin: float) -> bool:
	var list: PackedInt32Array = _grid.get(Vector2i(floori(p.x / GRID_M), floori(p.y / GRID_M)), PackedInt32Array())
	for i in list:
		if p.distance_to(pos[i]) < radius[i] + margin:
			return false
	return true
