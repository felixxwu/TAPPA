class_name OverworldRoute
# THE SAT-NAV. A route ALONG THE ROADS from where the car is to a chosen destination, as one
# world-XZ polyline the map can draw.
#
# WHY A ROUTE AND NOT A BEARING. The compass (and the map's selection ring) answer "which way is
# it, and how far" — a straight line the player cannot drive, because the overworld's roads are a
# sparse graph through forest and water. Told "it is 900 m north-east" the player still has to
# guess which junction turns toward it. A route drawn on the minimap answers the actual question:
# "which way do I turn AT THIS JUNCTION". That is why this plans over `OverworldRoads`' graph
# rather than emitting a straight segment.
#
# THE GRAPH IS TINY (one node per rally plus the garage, ~30-40 nodes, each with a handful of
# edges), so this is a plain O(V^2) Dijkstra with a linear min-scan: no heap, no allocation-heavy
# priority queue, and it re-plans in microseconds. `OverworldMap` re-plans on its ordinary refresh
# timer (0.5 s), which is what makes the route FOLLOW the car — drive past a junction and the next
# plan starts from the road you are actually on, so a wrong turn re-routes instead of stranding a
# stale line behind you.
#
# ATTACHING THE CAR. The car is almost never standing on a graph NODE, and often not even on a
# road. So the start is attached to the nearest point on the nearest EDGE, and both of that edge's
# endpoints seed Dijkstra with the along-the-polyline distance from the attach point. Without
# that, planning from the "nearest node" would send a player halfway down a road back to the
# junction behind them. The tail of the route from the attach point to the chosen endpoint is
# prepended verbatim, so the drawn line starts at the car and joins the road smoothly.
#
# HEADLESS AND PURE. Everything here is static and takes its road network as a duck-typed object
# with `nodes()` / `edges()` (the shape `OverworldRoads` publishes), so `tests/headless/
# test_overworld_route.gd` plans over a hand-built three-node network with no scene at all.

# No route. `PackedVector2Array()` is not a constant expression in GDScript, so this is a
# function rather than a const; callers treat "fewer than 2 points" as "nothing to draw".
static func _none() -> PackedVector2Array:
	return PackedVector2Array()


## Plan a road route from `from_xz` (the car, world XZ) to `to_xz` (the destination pin).
##
## Returns the world-XZ polyline `[from_xz, ...road..., to_xz]`, or an empty array when the
## network is missing/empty. The first and last points are the RAW positions, so the line visibly
## reaches the car and the pin even when either sits off the tarmac.
static func plan(roads: Object, from_xz: Vector2, to_xz: Vector2) -> PackedVector2Array:
	if roads == null or not roads.has_method("nodes") or not roads.has_method("edges"):
		return _none()
	var nodes: Array = roads.call("nodes")
	var edges: Array = roads.call("edges")
	if nodes.is_empty() or edges.is_empty():
		return _none()

	var goal := _nearest_node(nodes, to_xz)
	if goal < 0:
		return _none()

	var attach := _attach(edges, from_xz)
	if attach.is_empty():
		return _none()

	# Adjacency: node -> [{to, edge, forward}]. `forward` says whether the edge's stored polyline
	# runs from this node to the other one, so stitching never has to guess an orientation.
	var adj := {}
	for i in edges.size():
		var e: Dictionary = edges[i]
		var a := int(e.get("a", -1))
		var b := int(e.get("b", -1))
		if a < 0 or b < 0 or a >= nodes.size() or b >= nodes.size():
			continue
		var length := float(e.get("length_m", 0.0))
		if length <= 0.0:
			length = _polyline_length(e.get("points", PackedVector2Array()))
		if not adj.has(a):
			adj[a] = []
		if not adj.has(b):
			adj[b] = []
		adj[a].append({"to": b, "edge": i, "forward": true, "cost": length})
		adj[b].append({"to": a, "edge": i, "forward": false, "cost": length})

	var start_edge := int(attach["edge"])
	var seeds: Dictionary = attach["seeds"]   # node index -> metres from the attach point
	var dist := {}
	var prev := {}                            # node -> {from, edge, forward}
	for node_id in seeds:
		dist[node_id] = float(seeds[node_id])
	var done := {}

	while true:
		var best := -1
		var best_d := INF
		for node_id in dist:
			if done.has(node_id):
				continue
			if float(dist[node_id]) < best_d:
				best_d = float(dist[node_id])
				best = int(node_id)
		if best < 0 or best == goal:
			break
		done[best] = true
		for link in adj.get(best, []):
			var to := int(link["to"])
			if done.has(to):
				continue
			var d := best_d + float(link["cost"])
			if d < float(dist.get(to, INF)):
				dist[to] = d
				prev[to] = {"from": best, "edge": int(link["edge"]), "forward": bool(link["forward"])}

	if not dist.has(goal):
		return _none()

	# Walk the predecessor chain back to whichever seed node the shortest path came from, then
	# emit it forwards.
	var chain: Array[Dictionary] = []
	var at := goal
	while prev.has(at):
		var step: Dictionary = prev[at]
		chain.push_front(step)
		at = int(step["from"])
	# `at` is now the seed node the route leaves from.

	var out := PackedVector2Array([from_xz])
	_append_points(out, _attach_tail(edges[start_edge], attach, at))
	for step in chain:
		var e: Dictionary = edges[int(step["edge"])]
		var pts: PackedVector2Array = e.get("points", PackedVector2Array())
		_append_points(out, pts if bool(step["forward"]) else _reversed(pts))
	_append_points(out, PackedVector2Array([to_xz]))
	return out


## Total length of a planned polyline, metres. Used for the map's "X m by road" readout, which is
## the honest number — the straight-line distance under-reads a route around a lake by a lot.
static func length_m(points: PackedVector2Array) -> float:
	return _polyline_length(points)


# --- Internals ------------------------------------------------------------------------------


# The nearest point on the whole network to `p`, as
# `{edge, point, seeds: {node -> metres along the polyline to that node}}`.
static func _attach(edges: Array, p: Vector2) -> Dictionary:
	var best_edge := -1
	var best_seg := -1
	var best_point := Vector2.ZERO
	var best_d := INF
	for i in edges.size():
		var pts: PackedVector2Array = edges[i].get("points", PackedVector2Array())
		for s in range(pts.size() - 1):
			var q := Geometry2D.get_closest_point_to_segment(p, pts[s], pts[s + 1])
			var d := q.distance_squared_to(p)
			if d < best_d:
				best_d = d
				best_edge = i
				best_seg = s
				best_point = q
	if best_edge < 0:
		return {}
	var e: Dictionary = edges[best_edge]
	var pts: PackedVector2Array = e.get("points", PackedVector2Array())
	var to_a := best_point.distance_to(pts[best_seg])
	for s in range(best_seg):
		to_a += pts[s].distance_to(pts[s + 1])
	var to_b := best_point.distance_to(pts[best_seg + 1])
	for s in range(best_seg + 1, pts.size() - 1):
		to_b += pts[s].distance_to(pts[s + 1])
	return {
		"edge": best_edge, "seg": best_seg, "point": best_point,
		"seeds": {int(e.get("a", 0)): to_a, int(e.get("b", 0)): to_b},
	}


# The stretch of the attach edge between the attach point and the seed node the route leaves
# from — the bit that gets the car onto the graph.
static func _attach_tail(edge: Dictionary, attach: Dictionary, seed_node: int) -> PackedVector2Array:
	var pts: PackedVector2Array = edge.get("points", PackedVector2Array())
	var seg := int(attach["seg"])
	var point: Vector2 = attach["point"]
	var out := PackedVector2Array([point])
	if seed_node == int(edge.get("a", 0)):
		for s in range(seg, -1, -1):
			out.append(pts[s])
	else:
		for s in range(seg + 1, pts.size()):
			out.append(pts[s])
	return out


static func _nearest_node(nodes: Array, p: Vector2) -> int:
	var best := -1
	var best_d := INF
	for i in nodes.size():
		var w: Vector2 = nodes[i].get("world", Vector2.ZERO)
		var d := w.distance_squared_to(p)
		if d < best_d:
			best_d = d
			best = i
	return best


# Append, skipping a point that repeats the current tail — consecutive edges share their junction
# node, and a duplicated vertex makes `draw_polyline` emit a fat blob at every junction.
static func _append_points(out: PackedVector2Array, pts: PackedVector2Array) -> void:
	for q in pts:
		if out.size() > 0 and out[out.size() - 1].distance_squared_to(q) < 0.0001:
			continue
		out.append(q)


static func _reversed(pts: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in range(pts.size() - 1, -1, -1):
		out.append(pts[i])
	return out


static func _polyline_length(pts: PackedVector2Array) -> float:
	var total := 0.0
	for i in range(pts.size() - 1):
		total += pts[i].distance_to(pts[i + 1])
	return total
