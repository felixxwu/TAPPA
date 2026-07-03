class_name ScatterMath
# Shared seeded-hash + road-cell helpers for the scatter / field code (TreeScatter,
# SpectatorScatter, SpectatorGroup, ...). Everything here works in the world-XZ plane
# (x -> world x, y -> world z) on the same 0.5 m rasterisation grid the track uses.
#
# `hash01` is a pure, order-independent pseudo-random in [0, 1) for a (cell, seed, salt)
# tuple — it does NOT advance any RNG, so a cell's value never depends on iteration
# order and a different seed (e.g. trees vs bushes) yields a different, interleaved
# pattern. `cell_of` / `on_road` map a point onto the road-rasterisation grid.

const CELL_M := TrackGenerator.CELL_M  # 0.5 m road-rasterisation grid (owned by TrackGenerator)


# A stable pseudo-random in [0, 1) for (cx, cz, seed, salt) — a pure hash, not a
# running RNG, so it is order-independent.
static func hash01(cx: int, cz: int, seed_value: int, salt: int) -> float:
	return float(posmod(hash([cx, cz, seed_value, salt]), 1000003)) / 1000003.0


# The road-grid cell containing world-XZ point `p`.
static func cell_of(p: Vector2) -> Vector2i:
	return Vector2i(floori(p.x / CELL_M), floori(p.y / CELL_M))


# True if the cell containing `p` is a road cell (i.e. `p` sits on the painted track).
static func on_road(p: Vector2, road_cells: Dictionary) -> bool:
	return road_cells.has(cell_of(p))
