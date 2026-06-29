class_name SpectatorScatter
# Pure, seeded placement of roadside spectator groups in the world-XZ plane
# (x -> world x, y -> world z), in the same headless/deterministic spirit as
# TreeScatter. Nothing here touches the scene — it reads only in-memory track
# data (the road_cells set and a grid of tree points), so it unit-tests cheaply.
#
# Two concerns:
#  - mid_offset(): pick the along-track distance for the random mid-stage group,
#    seeded into [frac_min, frac_max] of the baked centerline length.
#  - members(): the individual standing positions within one group — a seeded
#    jittered grid (cell = separation) over a disc, rejecting road cells and
#    points too close to a tree, then thinned to `count`. Spacing is inherent
#    (no O(n^2) neighbour scan), they stay off the carriageway, and they never
#    spawn inside a tree.

const CELL_M := TrackGenerator.CELL_M  # 0.5 m road-rasterisation grid

const _JITTER := 0.5                   # jitter as a fraction of a cell (±0.25 cell)
const _SALT_Z := 0x165667B1            # decorrelates the two jitter axes
const _SALT_PICK := 0x9E3779B1         # decorrelates the thinning shuffle


# A stable pseudo-random in [0, 1) for (cx, cz, seed, salt) — a pure hash, so a
# cell's jitter is order-independent (mirrors TreeScatter._hash01).
static func _hash01(cx: int, cz: int, seed_value: int, salt: int) -> float:
	return float(posmod(hash([cx, cz, seed_value, salt]), 1000003)) / 1000003.0


# Along-track distance (m) for the random mid-stage group: a seeded fraction of
# the baked length within [frac_min, frac_max]. Deterministic per seed.
static func mid_offset(baked_length: float, frac_min: float, frac_max: float, seed_value: int) -> float:
	var lo := clampf(minf(frac_min, frac_max), 0.0, 1.0)
	var hi := clampf(maxf(frac_min, frac_max), 0.0, 1.0)
	var t := _hash01(0, 0, seed_value, 0)
	return baked_length * (lo + (hi - lo) * t)


# True if the cell containing `p` is a road cell (same test TreeScatter uses).
static func _on_road(p: Vector2, road_cells: Dictionary) -> bool:
	return road_cells.has(Vector2i(floori(p.x / CELL_M), floori(p.y / CELL_M)))


# Build a uniform spatial grid of points (e.g. tree positions) keyed by cell, so
# _near_point() only checks a 3x3 neighbourhood instead of every point.
static func build_point_grid(points: PackedVector2Array, cell: float) -> Dictionary:
	var grid := {}
	if cell <= 0.0:
		return grid
	for p in points:
		var key := Vector2i(floori(p.x / cell), floori(p.y / cell))
		if not grid.has(key):
			grid[key] = PackedVector2Array()
		grid[key].append(p)
	return grid


# True if any gridded point is within `radius` of `p`. `grid` must have been
# built with build_point_grid(points, cell) where cell >= radius (so the 3x3
# neighbourhood is guaranteed to cover the radius).
static func _near_point(p: Vector2, grid: Dictionary, cell: float, radius: float) -> bool:
	if grid.is_empty() or cell <= 0.0 or radius <= 0.0:
		return false
	var r2 := radius * radius
	var bx := floori(p.x / cell)
	var bz := floori(p.y / cell)
	for ox in range(-1, 2):
		for oz in range(-1, 2):
			var arr: PackedVector2Array = grid.get(Vector2i(bx + ox, bz + oz), PackedVector2Array())
			for q in arr:
				if p.distance_squared_to(q) <= r2:
					return true
	return false


# Standing positions for one group, clustered in a disc of `radius` around
# `anchor`. A jittered grid with cell = `separation` makes neighbours inherently
# no closer than (1 - jitter) * separation; candidates on the road or within
# `tree_avoid_radius` of a tree are dropped, then the survivors are seeded-shuffled
# and the first `count` returned (an even spatial thinning, not a corner bias).
static func members(anchor: Vector2, count: int, separation: float, radius: float,
		road_cells: Dictionary, tree_grid: Dictionary, tree_cell: float,
		tree_avoid_radius: float, seed_value: int) -> PackedVector2Array:
	var result := PackedVector2Array()
	if count <= 0 or separation <= 0.0 or radius <= 0.0:
		return result
	var reach := int(ceil(radius / separation))
	var cands: Array[Vector2] = []
	for cx in range(-reach, reach + 1):
		for cz in range(-reach, reach + 1):
			var jx := (_hash01(cx, cz, seed_value, 0) - 0.5) * _JITTER * separation
			var jz := (_hash01(cx, cz, seed_value, _SALT_Z) - 0.5) * _JITTER * separation
			var p := anchor + Vector2(cx * separation + jx, cz * separation + jz)
			if anchor.distance_to(p) > radius:
				continue
			if _on_road(p, road_cells):
				continue
			if _near_point(p, tree_grid, tree_cell, tree_avoid_radius):
				continue
			cands.append(p)
	# Seeded shuffle (sort by a per-point hash key) so thinning to `count` keeps an
	# even spread across the disc rather than the row-major fill order.
	cands.sort_custom(func(a: Vector2, b: Vector2) -> bool:
		return _pick_key(a, seed_value) < _pick_key(b, seed_value))
	for i in mini(count, cands.size()):
		result.append(cands[i])
	return result


# Deterministic shuffle key for a candidate point.
static func _pick_key(p: Vector2, seed_value: int) -> float:
	return _hash01(int(round(p.x * 16.0)), int(round(p.y * 16.0)), seed_value, _SALT_PICK)
