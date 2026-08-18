extends GutTest
# OverworldRoads — the overworld's road NETWORK. Pure geometry, no scene tree, so everything
# here is a plain object built in-process. See features/overworld.md → "Roads".
#
# The pin field is treated as OPAQUE input: nothing below names a rally, asserts an edge count
# or pins a tuned width. What is tested is the contract the callers depend on — in particular
# `approach_dirs`, which the garage uses to stand itself beside the road rather than on it.

const SIZE_M := 4000.0

var _roads: OverworldRoads


func before_all() -> void:
	_roads = OverworldRoads.new()
	_roads.build(SIZE_M)


# The garage is a node of the network like any other pin, and the placement code has to be able
# to find it without assuming where in the array it landed.
func test_the_garage_is_a_node_of_the_network() -> void:
	var i := _roads.hq_index()
	assert_gte(i, 0, "the network knows which node is the garage")
	var node: Dictionary = _roads.nodes()[i]
	assert_true(bool(node["is_hq"]), "and it is the one flagged is_hq")
	assert_eq(node["map_pos"], RallyLibrary.HQ_MAP_POS, "sitting at the HQ map position")


# One bearing per road touching the node, each a unit vector pointing AWAY from it along that
# road's own polyline. This is what makes "which side of the road is empty" answerable.
func test_approach_dirs_reports_one_unit_bearing_per_road_at_the_node() -> void:
	var i := _roads.hq_index()
	var dirs := _roads.approach_dirs(i)
	var touching := 0
	for edge in _roads.edges():
		if int(edge["a"]) == i or int(edge["b"]) == i:
			touching += 1
	assert_eq(dirs.size(), touching, "one bearing per edge meeting the node")
	assert_gt(dirs.size(), 0, "the garage is on the road network at all")
	var here: Vector2 = _roads.nodes()[i]["world"]
	for d in dirs:
		assert_almost_eq(d.length(), 1.0, 0.001, "every bearing is a unit vector")
	# Each bearing leads AWAY from the node, toward the far end of its own road: the dot with
	# the straight line to the other endpoint must be positive for a gently curved edge.
	var leads_away := 0
	for edge in _roads.edges():
		var far := -1
		if int(edge["a"]) == i:
			far = int(edge["b"])
		elif int(edge["b"]) == i:
			far = int(edge["a"])
		if far < 0:
			continue
		var straight: Vector2 = (_roads.nodes()[far]["world"] as Vector2) - here
		if straight.length() <= 0.0:
			continue
		for d in dirs:
			if d.dot(straight.normalized()) > 0.5:
				leads_away += 1
				break
	assert_eq(leads_away, touching, "every road's bearing heads off toward its far pin")


# Out-of-range indices answer empty rather than erroring — the garage asks with `hq_index()`,
# which is -1 on a network that was never built.
func test_approach_dirs_is_safe_for_a_missing_node() -> void:
	assert_eq(_roads.approach_dirs(-1).size(), 0, "a missing node has no roads")
	assert_eq(_roads.approach_dirs(9999).size(), 0, "and neither does an out-of-range one")
	var fresh := OverworldRoads.new()
	assert_eq(fresh.hq_index(), -1, "an unbuilt network has no garage node")
	assert_eq(fresh.approach_dirs(fresh.hq_index()).size(), 0, "and asking it is harmless")


# --- The allocation-free query variants -------------------------------------------------------

# `road_at_into` is the ONE implementation of the scan and `road_at` is a thin dictionary wrapper
# over it, so the two can never disagree — but that is exactly the kind of invariant a later
# "optimisation" of one path quietly breaks, and the carve reads the lean one PER VERTEX. Sampled
# across the map so both the on-road and the off-network arm are covered.
func test_road_at_into_answers_exactly_what_road_at_does() -> void:
	var probe: Array = [0.0, 0.0, 0.0, 0.0, 0.0]
	var on_road := 0
	var off_road := 0
	var half := SIZE_M * 0.5
	# Walk the first road's own polyline (guaranteed on-road samples) plus a coarse grid sweep.
	var points: Array[Vector2] = []
	var line := _roads.polyline(0)
	for i in mini(line.size(), 40):
		points.append(line[i])
	for gz in 9:
		for gx in 9:
			points.append(Vector2(-half + SIZE_M * gx / 8.0, -half + SIZE_M * gz / 8.0))
	for p in points:
		var dict := _roads.road_at(p.x, p.y)
		_roads.road_at_into(p.x, p.y, probe)
		assert_eq(probe[OverworldRoads.PROBE_ROAD_WEIGHT], dict["road_weight"],
			"road weight agrees at %s" % p)
		assert_eq(probe[OverworldRoads.PROBE_TARMAC_WEIGHT], dict["tarmac_weight"],
			"tarmac weight agrees at %s" % p)
		assert_eq(probe[OverworldRoads.PROBE_DISTANCE_M], dict["distance_m"],
			"distance agrees at %s" % p)
		assert_eq(Vector2(probe[OverworldRoads.PROBE_FOOT_X], probe[OverworldRoads.PROBE_FOOT_Y]),
			dict["foot"], "the centreline foot agrees at %s" % p)
		if float(dict["road_weight"]) > 0.0:
			on_road += 1
		else:
			off_road += 1
	assert_gt(on_road, 0, "the sample set actually covers the on-road arm")
	assert_gt(off_road, 0, "and the off-network arm")


# `has_segments_in_rect` is the cheap per-chunk reject the terrain carve runs instead of building
# and discarding an Array of segment dictionaries. It must answer precisely what the list's
# emptiness answers, or a chunk with road in it would skip the carve (a road that renders as
# grass) or a road-free chunk would pay the per-vertex loop for nothing.
func test_has_segments_in_rect_matches_the_lists_emptiness() -> void:
	var half := SIZE_M * 0.5
	var hits := 0
	var misses := 0
	var step := SIZE_M / 12.0
	for gz in 12:
		for gx in 12:
			var rect := Rect2(-half + gx * step, -half + gz * step, step, step)
			var listed := not _roads.segments_in_rect(rect).is_empty()
			assert_eq(_roads.has_segments_in_rect(rect), listed,
				"the predicate matches the list for %s" % rect)
			if listed:
				hits += 1
			else:
				misses += 1
	assert_gt(hits, 0, "the sweep covers rects that DO contain road")
	assert_gt(misses, 0, "and rects that do not")
