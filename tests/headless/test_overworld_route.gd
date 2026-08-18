extends GutTest
# The SAT-NAV planner (`scripts/overworld_route.gd`). See features/overworld.md → "Wayfinding".
#
# Every network here is HAND-BUILT — four nodes and a couple of edges in the duck-typed shape
# `OverworldRoads` publishes (`nodes()` / `edges()`). Nothing reaches into the real road builder or
# the shipped roster: the planner's contract is "shortest path along the polylines you gave me",
# and a synthetic network is the only way to know what the right answer IS. No assertion pins a
# tunable — the geometry below is the test's own input, not authored content.


# A stub road network. `nodes` is [Vector2 world], `links` is [[a, b]] (straight edges) or
# [[a, b, PackedVector2Array bend]] for an edge with intermediate points.
class FakeRoads:
	extends RefCounted

	var _nodes: Array[Dictionary] = []
	var _edges: Array[Dictionary] = []

	func _init(node_positions: Array, links: Array) -> void:
		for i in node_positions.size():
			_nodes.append({"id": "n%d" % i, "world": node_positions[i], "is_hq": i == 0})
		for link in links:
			var a := int(link[0])
			var b := int(link[1])
			var pts := PackedVector2Array([_nodes[a]["world"]])
			if link.size() > 2:
				for q in link[2]:
					pts.append(q)
			pts.append(_nodes[b]["world"])
			var length := 0.0
			for i in range(pts.size() - 1):
				length += pts[i].distance_to(pts[i + 1])
			_edges.append({"a": a, "b": b, "points": pts, "length_m": length, "tarmac": 0.0})

	func nodes() -> Array[Dictionary]:
		return _nodes

	func edges() -> Array[Dictionary]:
		return _edges


# A straight chain 0 -- 1 -- 2 along +x, plus a long way round 0 -- 3 -- 2 through +z.
func _chain() -> FakeRoads:
	return FakeRoads.new(
		[Vector2(0, 0), Vector2(100, 0), Vector2(200, 0), Vector2(100, 500)],
		[[0, 1], [1, 2], [0, 3], [3, 2]])


# Is `p` on the polyline (within a metre)? The planner's output must be drivable road, so "the
# route passes through here" is the assertion that matters, not an index into the array.
func _touches(points: PackedVector2Array, p: Vector2) -> bool:
	for i in range(points.size() - 1):
		if Geometry2D.get_closest_point_to_segment(p, points[i], points[i + 1]).distance_to(p) <= 1.0:
			return true
	return false


# --- The contract ---------------------------------------------------------------------------


# The point of the whole file: the drawn line starts AT THE CAR and ends AT THE PIN, whatever the
# roads do in between. Without both ends the player cannot tell which end is theirs.
func test_the_route_starts_at_the_car_and_ends_at_the_destination() -> void:
	var car := Vector2(10.0, 30.0)
	var dest := Vector2(200.0, 12.0)
	var route := OverworldRoute.plan(_chain(), car, dest)
	assert_gt(route.size(), 1, "a connected network must yield a route")
	assert_almost_eq(route[0].distance_to(car), 0.0, 0.001, "route starts at the car")
	assert_almost_eq(route[route.size() - 1].distance_to(dest), 0.0, 0.001,
			"route ends at the destination")


# It follows the ROADS. A straight line from the car to a destination on the far side of the bend
# would miss the intermediate node entirely — that is exactly the useless bearing the sat-nav
# exists to replace.
func test_the_route_runs_through_the_junction_rather_than_straight_at_the_pin() -> void:
	var route := OverworldRoute.plan(_chain(), Vector2(0, 0), Vector2(200, 0))
	assert_true(_touches(route, Vector2(100, 0)), "the route uses the middle junction")


# The SHORT way, not merely A way. Both branches reach node 2; the detour through node 3 is five
# times longer, so a planner that is not actually shortest-path would show it.
func test_the_route_takes_the_shorter_of_two_branches() -> void:
	var route := OverworldRoute.plan(_chain(), Vector2(0, 0), Vector2(200, 0))
	assert_false(_touches(route, Vector2(100, 500)), "the long way round is not chosen")
	assert_lt(OverworldRoute.length_m(route), 400.0, "the route is the short branch")


# A car parked halfway along an edge must NOT be sent back to the junction behind it. This is the
# attach-to-the-nearest-edge rule, and it is what stops the sat-nav opening with a U-turn.
func test_a_car_partway_along_an_edge_carries_on_forwards() -> void:
	var route := OverworldRoute.plan(_chain(), Vector2(150, 5), Vector2(200, 0))
	assert_false(_touches(route, Vector2(100, 0)),
			"a car past the junction is not sent back to it")
	assert_lt(OverworldRoute.length_m(route), 120.0, "the route is the short remaining stretch")


# An edge's intermediate points are real road: the route must trace the bend, not cut the corner,
# or the line on the minimap crosses ground the car cannot drive.
func test_the_route_traces_an_edges_bend() -> void:
	var bend := Vector2(50, 80)
	var roads := FakeRoads.new([Vector2(0, 0), Vector2(100, 0)],
			[[0, 1, PackedVector2Array([bend])]])
	var route := OverworldRoute.plan(roads, Vector2(0, 0), Vector2(100, 0))
	assert_true(_touches(route, bend), "the route follows the polyline's bend")


# No network, no route — and no crash. The map is built before the roads exist in some hosts, and
# a half-built overworld must not take the whole scene down.
func test_a_missing_or_empty_network_plans_nothing() -> void:
	assert_eq(OverworldRoute.plan(null, Vector2.ZERO, Vector2.ONE).size(), 0,
			"no roads object plans nothing")
	assert_eq(OverworldRoute.plan(FakeRoads.new([], []), Vector2.ZERO, Vector2.ONE).size(), 0,
			"an empty network plans nothing")


# A destination on an ISLAND — reachable by no edge — must not produce a route that teleports
# across the water. The planner falls back to the nearest node it can reach... which is on the
# player's own component, so the honest answer is "no route", not a straight line.
func test_a_disconnected_destination_yields_no_route() -> void:
	var roads := FakeRoads.new(
		[Vector2(0, 0), Vector2(100, 0), Vector2(900, 900), Vector2(1000, 900)],
		[[0, 1], [2, 3]])
	var route := OverworldRoute.plan(roads, Vector2(0, 0), Vector2(950, 900))
	# The goal node (2 or 3) sits on the far component, so Dijkstra never reaches it.
	assert_eq(route.size(), 0, "an unreachable destination plans nothing")


# The quoted number is the DRIVEN distance. A route that doubles back must measure longer than the
# straight line, or the footer under-promises the drive.
func test_route_length_measures_the_road_not_the_crow_flight() -> void:
	var bend := Vector2(50, 300)
	var roads := FakeRoads.new([Vector2(0, 0), Vector2(100, 0)],
			[[0, 1, PackedVector2Array([bend])]])
	var route := OverworldRoute.plan(roads, Vector2(0, 0), Vector2(100, 0))
	assert_gt(OverworldRoute.length_m(route), 100.0,
			"the road length exceeds the straight-line distance")


# No duplicated vertices where two edges meet: `draw_polyline` fattens a repeated point into a
# blob at every junction, which on the minimap reads as a string of beads rather than a route.
func test_the_route_has_no_repeated_points() -> void:
	var route := OverworldRoute.plan(_chain(), Vector2(0, 0), Vector2(200, 0))
	for i in range(route.size() - 1):
		assert_gt(route[i].distance_to(route[i + 1]), 0.001,
				"consecutive route points are distinct")
