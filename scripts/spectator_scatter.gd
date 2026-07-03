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

const _JITTER := 0.5                   # jitter as a fraction of a cell (±0.25 cell)
const _SALT_Z := 0x165667B1            # decorrelates the two jitter axes
const _SALT_PICK := 0x9E3779B1         # decorrelates the thinning shuffle


# Along-track distance (m) for the random mid-stage group: a seeded fraction of
# the baked length within [frac_min, frac_max]. Deterministic per seed.
static func mid_offset(baked_length: float, frac_min: float, frac_max: float, seed_value: int) -> float:
	var lo := clampf(minf(frac_min, frac_max), 0.0, 1.0)
	var hi := clampf(maxf(frac_min, frac_max), 0.0, 1.0)
	var t := ScatterMath.hash01(0, 0, seed_value, 0)
	return baked_length * (lo + (hi - lo) * t)


# Build a uniform spatial grid of points (e.g. tree positions) keyed by cell, so
# proximity tests only check a 3x3 neighbourhood instead of every point. Thin wrapper
# over SpatialGrid.of_points (kept as the public API world.gd + SpectatorGroup consume).
static func build_point_grid(points: PackedVector2Array, cell: float) -> Dictionary:
	return SpatialGrid.of_points(points, cell)


# Standing positions for one group, scattered over an oriented band that straddles
# the road — `half_len` along the track tangent, `half_width` to each side across it.
# Because road cells are rejected, the carriageway in the middle stays clear and the
# crowd lines BOTH verges over a stretch of track. A jittered grid (cell = separation)
# makes neighbours inherently no closer than (1 - jitter) * separation; candidates on
# the road or within `tree_avoid_radius` of a tree are dropped, then the survivors are
# seeded-shuffled and the first `count` returned (an even thinning, not a corner bias).
static func members(center: Vector2, tangent: Vector2, half_len: float, half_width: float,
		count: int, separation: float, road_cells: Dictionary, tree_grid: Dictionary,
		tree_cell: float, tree_avoid_radius: float, seed_value: int) -> PackedVector2Array:
	var result := PackedVector2Array()
	if count <= 0 or separation <= 0.0 or half_len <= 0.0 or half_width <= 0.0:
		return result
	var fwd := tangent
	if fwd.length() < 1e-5:
		fwd = Vector2(0, 1)
	fwd = fwd.normalized()
	var nrm := Vector2(-fwd.y, fwd.x)  # across-track axis
	var reach_a := int(ceil(half_len / separation))
	var reach_c := int(ceil(half_width / separation))
	var cands: Array[Vector2] = []
	for ca in range(-reach_a, reach_a + 1):
		for cc in range(-reach_c, reach_c + 1):
			var ja := (ScatterMath.hash01(ca, cc, seed_value, 0) - 0.5) * _JITTER * separation
			var jc := (ScatterMath.hash01(ca, cc, seed_value, _SALT_Z) - 0.5) * _JITTER * separation
			var along := ca * separation + ja
			var across := cc * separation + jc
			if absf(along) > half_len or absf(across) > half_width:
				continue
			var p := center + fwd * along + nrm * across
			if ScatterMath.on_road(p, road_cells):
				continue
			if SpatialGrid.near_point(p, tree_grid, tree_cell, tree_avoid_radius):
				continue
			cands.append(p)
	# Seeded shuffle (sort by a per-point hash key) so thinning to `count` keeps an
	# even spread across the band rather than the row-major fill order.
	cands.sort_custom(func(a: Vector2, b: Vector2) -> bool:
		return _pick_key(a, seed_value) < _pick_key(b, seed_value))
	for i in mini(count, cands.size()):
		result.append(cands[i])
	return result


# Deterministic shuffle key for a candidate point.
static func _pick_key(p: Vector2, seed_value: int) -> float:
	return ScatterMath.hash01(int(round(p.x * 16.0)), int(round(p.y * 16.0)), seed_value, _SALT_PICK)
