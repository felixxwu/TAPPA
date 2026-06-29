extends GutTest
# SpectatorScatter: pure, seeded placement of roadside spectator groups in the
# world-XZ plane. mid_offset() picks the random mid-stage distance; members() lays
# a group out over an oriented band that STRADDLES the road (so the crowd lines both
# verges), on a jittered grid (cell = separation), off the road and clear of trees,
# thinned to the requested count. Reads only in-memory data, no scene.

const SpectatorScatter = preload("res://scripts/spectator_scatter.gd")

const CELL := 0.5  # SpectatorScatter.CELL_M


func _cell_of(p: Vector2) -> Vector2i:
	return Vector2i(floori(p.x / CELL), floori(p.y / CELL))


# --- mid_offset ---------------------------------------------------------------

func test_mid_offset_within_fraction_band() -> void:
	var baked := 1000.0
	for s in range(20):
		var off := SpectatorScatter.mid_offset(baked, 0.30, 0.70, s)
		assert_between(off, 300.0, 700.0, "mid group lands in [30%%, 70%%] for seed %d" % s)


func test_mid_offset_deterministic() -> void:
	assert_eq(SpectatorScatter.mid_offset(1000.0, 0.3, 0.7, 7),
		SpectatorScatter.mid_offset(1000.0, 0.3, 0.7, 7), "same seed -> same offset")


func test_mid_offset_varies_with_seed() -> void:
	var a := SpectatorScatter.mid_offset(1000.0, 0.3, 0.7, 1)
	var b := SpectatorScatter.mid_offset(1000.0, 0.3, 0.7, 2)
	assert_ne(a, b, "different seed -> different mid offset")


# --- members ------------------------------------------------------------------
# Conventions for these tests: centre (100,100), tangent +Z, so the across-track
# axis is the world normal (-1, 0). half_len/half_width are 15 x 11 (a 30x22 band).

const CENTER := Vector2(100, 100)
const TANGENT := Vector2(0, 1)
const NRM := Vector2(-1, 0)  # SpectatorScatter uses (-tangent.y, tangent.x)
const HALF_LEN := 15.0
const HALF_WIDTH := 11.0


func _open(count: int, seed_value: int, road := {}, grid := {}) -> PackedVector2Array:
	return SpectatorScatter.members(CENTER, TANGENT, HALF_LEN, HALF_WIDTH, count, 0.5,
		road, grid, 1.5, 1.5, seed_value)


func test_members_count_capped_and_nonempty() -> void:
	var m := _open(50, 3)
	assert_gt(m.size(), 0, "places some spectators")
	assert_lte(m.size(), 50, "never exceeds the requested count")


func test_members_deterministic() -> void:
	assert_eq(_open(40, 9), _open(40, 9), "same seed -> identical layout")


func test_members_within_band() -> void:
	for p in _open(80, 4):
		var along: float = (p - CENTER).dot(TANGENT)
		var across: float = (p - CENTER).dot(NRM)
		assert_lte(absf(along), HALF_LEN + 1e-3, "member stays within the band length")
		assert_lte(absf(across), HALF_WIDTH + 1e-3, "member stays within the band width")


func test_members_span_both_sides_of_the_road() -> void:
	# With no road carved out, the band straddles the centre, so members appear on
	# BOTH sides of it along the across-track axis.
	var m := _open(80, 4)
	var min_across := INF
	var max_across := -INF
	for p in m:
		var across: float = (p - CENTER).dot(NRM)
		min_across = minf(min_across, across)
		max_across = maxf(max_across, across)
	assert_lt(min_across, 0.0, "some spectators on one side of the track")
	assert_gt(max_across, 0.0, "some spectators on the other side")


func test_members_respect_separation() -> void:
	# Jittered grid (cell = separation, jitter 0.5) => no two closer than
	# (1 - 0.5) * separation. Use separation 1.0 for a clean 0.5 m floor.
	var m := SpectatorScatter.members(CENTER, TANGENT, HALF_LEN, HALF_WIDTH, 60, 1.0,
		{}, {}, 0.5, 1.5, 5)
	assert_gt(m.size(), 2, "need several to compare")
	for i in m.size():
		for j in range(i + 1, m.size()):
			assert_gt(m[i].distance_to(m[j]), 0.49, "neighbours keep ~half the separation")


func test_members_avoid_the_road() -> void:
	# A central road band through the area; no member may sit on a road cell.
	var road := {}
	for cx in range(190, 220):
		for cz in range(170, 230):
			road[Vector2i(cx, cz)] = true
	var m := _open(80, 6, road)
	assert_gt(m.size(), 0, "still places spectators on the verges")
	for p in m:
		assert_false(road.has(_cell_of(p)), "no spectator stands on a road cell")


func test_members_avoid_trees() -> void:
	var trees := PackedVector2Array([CENTER])  # one tree dead centre
	var grid := SpectatorScatter.build_point_grid(trees, 1.5)
	for p in _open(80, 7, {}, grid):
		assert_gt(CENTER.distance_to(p), 1.5 - 1e-3, "no spectator spawns inside the tree radius")


func test_build_point_grid_buckets_points() -> void:
	var pts := PackedVector2Array([Vector2(0.1, 0.1), Vector2(0.2, 0.2), Vector2(5.0, 5.0)])
	var grid := SpectatorScatter.build_point_grid(pts, 1.0)
	assert_eq(grid[Vector2i(0, 0)].size(), 2, "two points share a cell")
	assert_eq(grid[Vector2i(5, 5)].size(), 1, "the far point is its own cell")
