class_name SpatialGrid
# A uniform 2D bin grid over the world-XZ plane (x -> world x, y -> world z): bin points
# into square cells keyed by Vector2i, then answer proximity / neighbourhood queries by
# touching only the 3x3 cells around a point instead of every point. Shared by the
# scatter / field code (SpectatorScatter tree grid, TreeMeshField bins, BushField hit
# grid, SpectatorGroup obstacle avoidance).
#
# Build with a cell size >= the largest query radius so the 3x3 neighbourhood is
# guaranteed to cover the radius. `of_points` stores the points themselves (for
# proximity tests); `of_indices` stores indices into the source array (for callers that
# key their own per-instance state off the index).


# The bin key for world-XZ point `p` at cell size `cell`.
static func cell_key(p: Vector2, cell: float) -> Vector2i:
	return Vector2i(floori(p.x / cell), floori(p.y / cell))


# Bin points by value: Vector2i -> PackedVector2Array of the points in that cell.
static func of_points(points: PackedVector2Array, cell: float) -> Dictionary:
	var grid := {}
	if cell <= 0.0:
		return grid
	for p in points:
		var key := cell_key(p, cell)
		if not grid.has(key):
			grid[key] = PackedVector2Array()
		grid[key].append(p)
	return grid


# Bin points by index: Vector2i -> PackedInt32Array of indices into `points`.
static func of_indices(points: PackedVector2Array, cell: float) -> Dictionary:
	var grid := {}
	if cell <= 0.0:
		return grid
	for i in points.size():
		var key := cell_key(points[i], cell)
		if not grid.has(key):
			grid[key] = PackedInt32Array()
		grid[key].append(i)
	return grid


# True if any point in an `of_points` grid is within `radius` of `p`. `grid` must have
# been built with cell >= radius so the 3x3 neighbourhood covers the radius.
static func near_point(p: Vector2, grid: Dictionary, cell: float, radius: float) -> bool:
	if grid.is_empty() or cell <= 0.0 or radius <= 0.0:
		return false
	var r2 := radius * radius
	var base := cell_key(p, cell)
	for ox in range(-1, 2):
		for oz in range(-1, 2):
			var arr: PackedVector2Array = grid.get(Vector2i(base.x + ox, base.y + oz), PackedVector2Array())
			for q in arr:
				if p.distance_squared_to(q) <= r2:
					return true
	return false
