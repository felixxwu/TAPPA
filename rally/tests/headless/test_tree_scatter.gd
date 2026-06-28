extends GutTest
# TreeScatter: deterministic 2D world-XZ foliage positions around each track turn,
# placed on a global JITTERED GRID (one seeded point per cell, cell size derived from
# the target density). Spacing is inherent — two points are never closer than
# (1 - jitter) x cell — so there's no O(N²) neighbour scan. A point is dropped only if
# its cell sits on the road. Reads only the in-memory track data, never the scene.

const TreeScatter = preload("res://scripts/tree_scatter.gd")
const TrackGenerator = preload("res://scripts/track_generator.gd")

const PARAMS := {
	"trees_per_turn": 10,
	"spawn_radius_m": 25.0,
	"jitter": 0.6,
}

# A small track gives a known cell set + anchors. Width 6, clearance 8 -> the
# returned "cells" are the clearance-inflated (22 m) collision set.
func _track() -> Dictionary:
	return TrackGenerator.generate(Vector2(0, 0), Vector2(0, 1), 3, 6, 6.0, 8.0)

# The VISIBLE road footprint (rasterized at the real track width), which is what
# scatter rejects against — not the inflated collision set in result["cells"].
func _road_cells(t: Dictionary) -> Dictionary:
	return TrackGenerator.rasterize_cells((t["centerline"] as Curve2D).tessellate(), 6.0)

func _cell_of(p: Vector2) -> Vector2i:
	return Vector2i(floori(p.x / TreeScatter.CELL_M), floori(p.y / TreeScatter.CELL_M))


func test_turn_anchor_is_centroid_of_cell_centres() -> void:
	var piece := { "cells": [Vector2i(0, 0), Vector2i(0, 2)] }
	# centres: (0.25,0.25) and (0.25,1.25) -> mean (0.25,0.75)
	assert_almost_eq(TreeScatter.turn_anchor(piece), Vector2(0.25, 0.75),
		Vector2(1e-4, 1e-4), "anchor is mean of cell centres")


func test_deterministic_for_same_seed() -> void:
	var t := _track()
	var road := _road_cells(t)
	var a := TreeScatter.scatter(t["pieces"], road, PARAMS, 42)
	var b := TreeScatter.scatter(t["pieces"], road, PARAMS, 42)
	assert_eq(a, b, "same seed -> identical positions")


func test_different_seed_differs() -> void:
	var t := _track()
	var road := _road_cells(t)
	var a := TreeScatter.scatter(t["pieces"], road, PARAMS, 1)
	var b := TreeScatter.scatter(t["pieces"], road, PARAMS, 2)
	assert_ne(a, b, "different seed -> different positions (e.g. trees vs bushes)")


func test_no_tree_lands_on_a_road_cell() -> void:
	var t := _track()
	var road := _road_cells(t)
	var trees := TreeScatter.scatter(t["pieces"], road, PARAMS, 7)
	assert_gt(trees.size(), 0, "should place some trees")
	for pos in trees:
		assert_false(road.has(_cell_of(pos)), "no tree sits on a road cell")


func test_grid_guarantees_minimum_spacing() -> void:
	# The jittered grid's hard floor: no two points closer than (1 - jitter) * cell.
	var t := _track()
	var road := _road_cells(t)
	var trees := TreeScatter.scatter(t["pieces"], road, PARAMS, 7)
	var cell := TreeScatter.grid_cell_size(PARAMS)
	var min_spacing: float = (1.0 - PARAMS["jitter"]) * cell
	assert_gt(trees.size(), 1, "need at least two trees to compare")
	for i in trees.size():
		for j in range(i + 1, trees.size()):
			assert_gte(trees[i].distance_to(trees[j]), min_spacing - 0.01,
				"trees are at least (1 - jitter) * cell apart")


func test_within_spawn_radius_of_some_anchor() -> void:
	var t := _track()
	var road := _road_cells(t)
	var trees := TreeScatter.scatter(t["pieces"], road, PARAMS, 7)
	var anchors: Array[Vector2] = []
	for piece in t["pieces"]:
		anchors.append(TreeScatter.turn_anchor(piece))
	for pos in trees:
		var ok := false
		for anchor in anchors:
			if pos.distance_to(anchor) <= PARAMS["spawn_radius_m"]:
				ok = true
				break
		assert_true(ok, "tree must be within spawn_radius_m of some anchor")


func test_density_in_a_reasonable_band() -> void:
	# The grid yields roughly trees_per_turn points per (non-overlapping) disc — not an
	# exact count, but bounded above by the cells a disc's bounding box can hold.
	var t := _track()
	var road := _road_cells(t)
	var trees := TreeScatter.scatter(t["pieces"], road, PARAMS, 7)
	var cell := TreeScatter.grid_cell_size(PARAMS)
	# Cells a disc's bounding box can hold (incl. the ±1 padding scatter adds).
	var per_bbox := int(ceil(2.0 * PARAMS["spawn_radius_m"] / cell)) + 4
	var max_cells: int = t["pieces"].size() * per_bbox * per_bbox
	assert_gt(trees.size(), 0, "places some trees")
	assert_lte(trees.size(), max_cells, "count bounded by the grid cells the discs cover")


func test_zero_target_places_nothing() -> void:
	# trees_per_turn = 0 (scene_helpers' "no foliage" mode) yields an empty set.
	var t := _track()
	var road := _road_cells(t)
	var off := PARAMS.duplicate()
	off["trees_per_turn"] = 0
	assert_eq(TreeScatter.scatter(t["pieces"], road, off, 7).size(), 0,
		"a zero target disables foliage")


func test_all_on_road_places_nothing() -> void:
	# Every reachable cell marked road -> every point is rejected, nothing placed.
	var t := _track()
	# Mark a wide road band around each anchor so the disc has nowhere off-road to land.
	var road: Dictionary = {}
	for piece in t["pieces"]:
		var a := TreeScatter.turn_anchor(piece)
		var ac := _cell_of(a)
		for dz in range(-60, 61):
			for dx in range(-60, 61):
				road[Vector2i(ac.x + dx, ac.y + dz)] = true
	var tiny := PARAMS.duplicate()
	tiny["spawn_radius_m"] = 5.0
	assert_eq(TreeScatter.scatter(t["pieces"], road, tiny, 7).size(), 0,
		"all candidates on-road -> places nothing")
