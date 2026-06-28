class_name TreeScatter
# Scatters billboard-foliage positions around each track turn. Pure + headless +
# seeded (mirrors TrackGenerator). Works in the world-XZ plane (x -> world x,
# y -> world z).
#
# Placement is a JITTERED GRID, not rejection sampling: a single global grid (cell
# size derived from the desired density) covers the turn discs, and each cell emits
# one point jittered around its centre. Spacing is therefore inherent — no candidate
# is ever compared against another, so it's O(cells) instead of the old O(N²)
# nearest-neighbour scan. The grid is global (one point per cell, shared across
# overlapping turn discs), so foliage stays evenly spaced even where turns overlap.
#
# Everything here reads ONLY the in-memory track data passed in (the generated
# `pieces` + a rasterized `road_cells` set) — it never samples the placed scene.
#
# `road_cells` must be the VISIBLE road footprint (rasterized at track_width), NOT
# the clearance-inflated collision set from TrackGenerator.generate — that one is
# track_width + 2*track_clearance wide and would push every tree metres back from the
# real road edge.

const CELL_M := TrackGenerator.CELL_M  # 0.5 m track cell grid (road rasterisation)

# Salts that decorrelate the jitter axes and the per-seed grid phase from the same
# cell+seed hash. The phase shifts the whole lattice per seed, so trees (one seed) and
# bushes (a different seed) sit on offset grids instead of stacking in the same cells.
const _JITTER_SALT := 0x6D2B79F5
const _PHASE_SALT_X := 0x27D4EB2F
const _PHASE_SALT_Z := 0x165667B1


# Centroid of a piece's rasterized cells, in world XZ.
static func turn_anchor(piece: Dictionary) -> Vector2:
	var cells: Array = piece["cells"]
	var sum := Vector2.ZERO
	for cell in cells:
		sum += Vector2((cell.x + 0.5) * CELL_M, (cell.y + 0.5) * CELL_M)
	return sum / float(maxi(cells.size(), 1))


# True if the cell containing `p` is a road cell — i.e. the tree would sit on the
# painted track. A tree in any non-road cell is allowed, so trees can land in the
# cell immediately beside the road.
static func _on_road(p: Vector2, road_cells: Dictionary) -> bool:
	var cell := Vector2i(floori(p.x / CELL_M), floori(p.y / CELL_M))
	return road_cells.has(cell)


# The scatter grid's cell size (m): chosen so that one point per cell over a disc of
# `spawn_radius_m` yields ~`trees_per_turn` points, matching the old per-turn count.
static func grid_cell_size(params: Dictionary) -> float:
	var per_turn := float(params["trees_per_turn"])
	var radius: float = params["spawn_radius_m"]
	if per_turn <= 0.0 or radius <= 0.0:
		return 0.0
	return radius * sqrt(PI / per_turn)


# A stable pseudo-random in [0, 1) for (cell, seed, axis) — order-independent (a pure
# hash, not a running RNG), so a cell's jitter doesn't depend on iteration order and a
# different seed (e.g. the bush offset) produces a different, interleaved pattern.
static func _hash01(cx: int, cz: int, seed_value: int, salt: int) -> float:
	var h := hash([cx, cz, seed_value, salt])
	return float(posmod(h, 1000003)) / 1000003.0


# The world-XZ point for grid cell (cx, cz): the cell centre, shifted by the per-seed
# lattice `phase`, plus a seeded jitter of up to ±jitter/2 of a cell in each axis. The
# uniform phase doesn't change relative spacing, so two points are still no closer than
# (1 - jitter) * cell (axis-adjacent worst case) — spacing guaranteed by construction.
static func _cell_point(cx: int, cz: int, cell: float, jitter: float, seed_value: int, phase: Vector2) -> Vector2:
	var jx := (_hash01(cx, cz, seed_value, 0) - 0.5) * jitter
	var jz := (_hash01(cx, cz, seed_value, _JITTER_SALT) - 0.5) * jitter
	return Vector2((cx + 0.5 + jx) * cell, (cz + 0.5 + jz) * cell) + phase


# The whole-lattice offset for a seed, in [0, cell) per axis — so different seeds
# (trees vs bushes) land on interleaved grids rather than the same cells.
static func _grid_phase(cell: float, seed_value: int) -> Vector2:
	return Vector2(
		_hash01(0, 0, seed_value, _PHASE_SALT_X) * cell,
		_hash01(0, 0, seed_value, _PHASE_SALT_Z) * cell)


static func scatter(pieces: Array, road_cells: Dictionary, params: Dictionary, seed_value: int) -> PackedVector2Array:
	var result := PackedVector2Array()
	var cell := grid_cell_size(params)
	if cell <= 0.0:
		return result  # trees_per_turn or radius is 0 -> nothing to place
	var radius: float = params["spawn_radius_m"]
	var jitter := clampf(float(params.get("jitter", 0.6)), 0.0, 1.0)
	var phase := _grid_phase(cell, seed_value)
	# One point per global grid cell. `used` makes overlapping turn discs share cells
	# (so a cell is never placed twice), keeping the spacing global. The ±1 cell of
	# padding covers cells whose phase-shifted point drifts into the disc.
	var used := {}
	for piece in pieces:
		var anchor := turn_anchor(piece)
		var min_cx := floori((anchor.x - radius) / cell) - 1
		var max_cx := floori((anchor.x + radius) / cell) + 1
		var min_cz := floori((anchor.y - radius) / cell) - 1
		var max_cz := floori((anchor.y + radius) / cell) + 1
		for cx in range(min_cx, max_cx + 1):
			for cz in range(min_cz, max_cz + 1):
				var key := Vector2i(cx, cz)
				if used.has(key):
					continue
				var p := _cell_point(cx, cz, cell, jitter, seed_value, phase)
				# Cluster around turns: keep the cell only if its point falls inside
				# THIS disc. If not, leave it free — a later turn's disc may claim it.
				if anchor.distance_to(p) > radius:
					continue
				used[key] = true
				if _on_road(p, road_cells):
					continue  # cell consumed but the point sits on the road: skip it
				result.append(p)
	return result
