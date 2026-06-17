class_name TreeScatter
# Scatters billboard-tree positions around each track turn. Pure + headless +
# seeded (mirrors TrackGenerator). Works in the world-XZ plane (x -> world x,
# y -> world z). Rejects a candidate only if its cell IS a road cell (so trees
# can spawn right up to the road edge but never on it) or if it is too close to
# an already-placed tree, retrying up to max_retries before skipping.
#
# `road_cells` must be the VISIBLE road footprint (rasterized at track_width),
# NOT the clearance-inflated collision set from TrackGenerator.generate — that
# one is track_width + 2*track_clearance wide and would push every tree metres
# back from the real road edge.

const CELL_M := TrackGenerator.CELL_M  # 0.5 m track cell grid


# Centroid of a piece's rasterized cells, in world XZ.
static func turn_anchor(piece: Dictionary) -> Vector2:
	var cells: Array = piece["cells"]
	var sum := Vector2.ZERO
	for cell in cells:
		sum += Vector2((cell.x + 0.5) * CELL_M, (cell.y + 0.5) * CELL_M)
	return sum / float(maxi(cells.size(), 1))


# True if the cell containing `p` is a road cell — i.e. the tree would sit on
# the painted track. A tree in any non-road cell is allowed, so trees can land
# in the cell immediately beside the road (right up to the edge).
static func _on_road(p: Vector2, road_cells: Dictionary) -> bool:
	var cell := Vector2i(floori(p.x / CELL_M), floori(p.y / CELL_M))
	return road_cells.has(cell)


static func scatter(pieces: Array, road_cells: Dictionary, params: Dictionary, seed_value: int) -> PackedVector2Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value + 0x7EE  # offset so trees don't visually track corner choices
	var trees := PackedVector2Array()
	var per_turn: int = params["trees_per_turn"]
	var radius: float = params["spawn_radius_m"]
	var min_tree: float = params["min_tree_dist_m"]
	var max_retries: int = params["max_retries"]
	for piece in pieces:
		var anchor := turn_anchor(piece)
		for _t in per_turn:
			for _attempt in (max_retries + 1):
				# Uniform-in-disc sample.
				var r := radius * sqrt(rng.randf())
				var theta := rng.randf() * TAU
				var cand := anchor + Vector2(cos(theta), sin(theta)) * r
				if _on_road(cand, road_cells):
					continue
				var clash := false
				for placed in trees:
					if cand.distance_to(placed) < min_tree:
						clash = true
						break
				if clash:
					continue
				trees.append(cand)
				break  # placed this tree; move to the next
	return trees
