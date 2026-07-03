extends GutTest
# Direct tests for the shared scatter/field helpers extracted from the tree/spectator
# code: ScatterMath (seeded hash + road-cell tests) and SpatialGrid (point/index bin
# grid + 3x3 proximity). These pin the helper CONTRACTS, not any tunable value.


# --- ScatterMath.hash01 -------------------------------------------------------

func test_hash01_in_unit_interval() -> void:
	for cx in range(-3, 4):
		for cz in range(-3, 4):
			var h := ScatterMath.hash01(cx, cz, 7, 0)
			assert_between(h, 0.0, 1.0, "hash01 is in [0, 1)")
			assert_lt(h, 1.0, "hash01 is strictly < 1")


func test_hash01_deterministic() -> void:
	assert_eq(ScatterMath.hash01(2, 5, 42, 0x9E3779B1),
		ScatterMath.hash01(2, 5, 42, 0x9E3779B1), "same inputs -> same value")


func test_hash01_decorrelated_by_seed_and_salt() -> void:
	assert_ne(ScatterMath.hash01(2, 5, 1, 0), ScatterMath.hash01(2, 5, 2, 0),
		"different seed -> different value")
	assert_ne(ScatterMath.hash01(2, 5, 1, 0), ScatterMath.hash01(2, 5, 1, 0x165667B1),
		"different salt -> different value")


# --- ScatterMath.cell_of / on_road --------------------------------------------

func test_cell_of_maps_to_rasterisation_grid() -> void:
	var cell := ScatterMath.CELL_M
	# A point just inside cell (3, -2) must map there.
	var p := Vector2((3 + 0.25) * cell, (-2 + 0.25) * cell)
	assert_eq(ScatterMath.cell_of(p), Vector2i(3, -2), "cell_of floors onto the grid")


func test_on_road_only_when_cell_present() -> void:
	var p := Vector2(1.0, 1.0)
	var road := {ScatterMath.cell_of(p): true}
	assert_true(ScatterMath.on_road(p, road), "point in a road cell is on-road")
	assert_false(ScatterMath.on_road(p + Vector2(1000, 1000), road), "point elsewhere is off-road")


# --- SpatialGrid --------------------------------------------------------------

func test_cell_key_floors() -> void:
	assert_eq(SpatialGrid.cell_key(Vector2(2.4, -0.1), 1.0), Vector2i(2, -1),
		"cell_key floors per axis")


func test_of_points_buckets_by_value() -> void:
	var pts := PackedVector2Array([Vector2(0.1, 0.1), Vector2(0.2, 0.2), Vector2(5.0, 5.0)])
	var grid := SpatialGrid.of_points(pts, 1.0)
	assert_eq(grid[Vector2i(0, 0)].size(), 2, "two points share a cell")
	assert_eq(grid[Vector2i(5, 5)].size(), 1, "the far point is its own cell")
	assert_true(grid[Vector2i(0, 0)] is PackedVector2Array, "point grid stores points")


func test_of_indices_buckets_by_index() -> void:
	var pts := PackedVector2Array([Vector2(0.1, 0.1), Vector2(0.2, 0.2), Vector2(5.0, 5.0)])
	var grid := SpatialGrid.of_indices(pts, 1.0)
	assert_eq(Array(grid[Vector2i(0, 0)]), [0, 1], "shared cell holds both indices")
	assert_eq(Array(grid[Vector2i(5, 5)]), [2], "far point's index is its own cell")


func test_builders_empty_for_nonpositive_cell() -> void:
	var pts := PackedVector2Array([Vector2(1, 1)])
	assert_eq(SpatialGrid.of_points(pts, 0.0).size(), 0, "cell 0 -> empty point grid")
	assert_eq(SpatialGrid.of_indices(pts, -1.0).size(), 0, "negative cell -> empty index grid")


func test_near_point_within_radius() -> void:
	var grid := SpatialGrid.of_points(PackedVector2Array([Vector2(10, 10)]), 2.0)
	assert_true(SpatialGrid.near_point(Vector2(10.5, 10.0), grid, 2.0, 1.0),
		"a point within radius is detected")
	assert_false(SpatialGrid.near_point(Vector2(20, 20), grid, 2.0, 1.0),
		"a distant point is not detected")


func test_near_point_false_on_empty_or_zero() -> void:
	assert_false(SpatialGrid.near_point(Vector2.ZERO, {}, 2.0, 1.0), "empty grid -> false")
	var grid := SpatialGrid.of_points(PackedVector2Array([Vector2.ZERO]), 2.0)
	assert_false(SpatialGrid.near_point(Vector2.ZERO, grid, 2.0, 0.0), "zero radius -> false")
