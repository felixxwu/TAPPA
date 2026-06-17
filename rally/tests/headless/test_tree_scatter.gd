extends GutTest
# TreeScatter: picks deterministic 2D world-XZ tree positions around each track
# turn. A candidate is rejected only if its cell IS a road cell (so trees can
# spawn right up to the road edge but never on it) or if it is too close to an
# already-placed tree, with bounded retries.

const TreeScatter = preload("res://scripts/tree_scatter.gd")
const TrackGenerator = preload("res://scripts/track_generator.gd")

const PARAMS := {
	"trees_per_turn": 10,
	"spawn_radius_m": 25.0,
	"min_tree_dist_m": 4.0,
	"max_retries": 8,
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

func _nearest_road(pos: Vector2, road: Dictionary) -> float:
	var best := INF
	for cell in road:
		var centre := Vector2((cell.x + 0.5) * TreeScatter.CELL_M, (cell.y + 0.5) * TreeScatter.CELL_M)
		best = min(best, pos.distance_to(centre))
	return best

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
	assert_ne(a, b, "different seed -> different positions")

func test_no_tree_lands_on_a_road_cell() -> void:
	var t := _track()
	var road := _road_cells(t)
	var trees := TreeScatter.scatter(t["pieces"], road, PARAMS, 7)
	assert_gt(trees.size(), 0, "should place some trees")
	for pos in trees:
		assert_false(road.has(_cell_of(pos)), "no tree sits on a road cell")

func test_trees_can_hug_the_road_edge() -> void:
	# The whole point of the membership test: at least one tree spawns right up
	# against the road (within ~1 cell of a road cell centre), not metres back.
	var t := _track()
	var road := _road_cells(t)
	var trees := TreeScatter.scatter(t["pieces"], road, PARAMS, 7)
	var closest := INF
	for pos in trees:
		closest = min(closest, _nearest_road(pos, road))
	assert_lt(closest, 1.5, "some tree spawns right up to the road edge")

func test_respects_tree_spacing() -> void:
	var t := _track()
	var road := _road_cells(t)
	var trees := TreeScatter.scatter(t["pieces"], road, PARAMS, 7)
	for i in trees.size():
		for j in range(i + 1, trees.size()):
			assert_gte(trees[i].distance_to(trees[j]), PARAMS["min_tree_dist_m"],
				"trees must be >= min_tree_dist_m apart")

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

func test_count_bound() -> void:
	var t := _track()
	var road := _road_cells(t)
	var trees := TreeScatter.scatter(t["pieces"], road, PARAMS, 7)
	assert_lte(trees.size(), PARAMS["trees_per_turn"] * t["pieces"].size(),
		"count <= trees_per_turn * turns")

func test_impossible_constraints_return_quickly() -> void:
	# A tiny disc whose every cell is marked road: every candidate is rejected,
	# so nothing is placed and the call returns immediately (no hang).
	var t := _track()
	# Mark each piece's anchor cell (and its 8 neighbours) as road, so the tiny
	# disc around the anchor has nowhere off-road to land.
	var road: Dictionary = {}
	for piece in t["pieces"]:
		var a := TreeScatter.turn_anchor(piece)
		var ac := _cell_of(a)
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				road[Vector2i(ac.x + dx, ac.y + dz)] = true
	var hard := PARAMS.duplicate()
	hard["spawn_radius_m"] = 0.05
	var trees := TreeScatter.scatter(t["pieces"], road, hard, 7)
	assert_eq(trees.size(), 0, "all candidates on-road -> places nothing, no hang")
