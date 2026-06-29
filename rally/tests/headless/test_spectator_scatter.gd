extends GutTest
# SpectatorScatter: pure, seeded placement of roadside spectator groups in the
# world-XZ plane. mid_offset() picks the random mid-stage distance; members()
# lays a group out on a jittered grid (cell = separation), off the road and clear
# of trees, thinned to the requested count. Reads only in-memory data, no scene.

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

func _open_field() -> Array:
	# A group centre well away from any road/tree, so placement is unconstrained.
	return [Vector2(100, 100), {}, {}]


func test_members_count_capped_and_nonempty() -> void:
	var f := _open_field()
	var m := SpectatorScatter.members(f[0], 50, 0.5, 6.0, f[1], f[2], 0.5, 1.5, 3)
	assert_gt(m.size(), 0, "places some spectators")
	assert_lte(m.size(), 50, "never exceeds the requested count")


func test_members_deterministic() -> void:
	var f := _open_field()
	var a := SpectatorScatter.members(f[0], 40, 0.5, 6.0, f[1], f[2], 0.5, 1.5, 9)
	var b := SpectatorScatter.members(f[0], 40, 0.5, 6.0, f[1], f[2], 0.5, 1.5, 9)
	assert_eq(a, b, "same seed -> identical layout")


func test_members_within_radius() -> void:
	var center := Vector2(100, 100)
	var m := SpectatorScatter.members(center, 60, 0.5, 6.0, {}, {}, 0.5, 1.5, 4)
	for p in m:
		assert_lte(center.distance_to(p), 6.0 + 1e-3, "member stays inside the spawn disc")


func test_members_respect_separation() -> void:
	# Jittered grid (cell = separation, jitter 0.5) => no two closer than
	# (1 - 0.5) * separation. Use separation 1.0 for a clean 0.5 m floor.
	var m := SpectatorScatter.members(Vector2(100, 100), 60, 1.0, 8.0, {}, {}, 0.5, 1.5, 5)
	assert_gt(m.size(), 2, "need several to compare")
	for i in m.size():
		for j in range(i + 1, m.size()):
			assert_gt(m[i].distance_to(m[j]), 0.49, "neighbours keep ~half the separation")


func test_members_avoid_the_road() -> void:
	# Mark a band of road cells through the disc; no member may sit on one.
	var road := {}
	for cx in range(190, 220):
		for cz in range(195, 215):
			road[Vector2i(cx, cz)] = true
	var m := SpectatorScatter.members(Vector2(100, 100), 60, 0.5, 6.0, road, {}, 0.5, 1.5, 6)
	for p in m:
		assert_false(road.has(_cell_of(p)), "no spectator stands on a road cell")


func test_members_avoid_trees() -> void:
	var center := Vector2(100, 100)
	var trees := PackedVector2Array([center])  # one tree dead centre
	var grid := SpectatorScatter.build_point_grid(trees, 1.5)
	var m := SpectatorScatter.members(center, 60, 0.5, 6.0, {}, grid, 1.5, 1.5, 7)
	for p in m:
		assert_gt(center.distance_to(p), 1.5 - 1e-3, "no spectator spawns inside the tree radius")


func test_build_point_grid_buckets_points() -> void:
	var pts := PackedVector2Array([Vector2(0.1, 0.1), Vector2(0.2, 0.2), Vector2(5.0, 5.0)])
	var grid := SpectatorScatter.build_point_grid(pts, 1.0)
	assert_eq(grid[Vector2i(0, 0)].size(), 2, "two points share a cell")
	assert_eq(grid[Vector2i(5, 5)].size(), 1, "the far point is its own cell")
