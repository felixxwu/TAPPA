extends GutTest
# TreeScatter: deterministic 2D world-XZ foliage positions around each track turn,
# placed on a global JITTERED GRID (one seeded point per cell, cell size derived from
# the target density). Spacing is inherent — two points are never closer than
# (1 - jitter) x cell — so there's no O(N²) neighbour scan. A point is dropped only if
# its cell sits on the road. Reads only the in-memory track data, never the scene.


const PARAMS := {
	"trees_per_turn": 10,
	"spawn_radius_m": 25.0,
	"jitter": 0.6,
}

const _TGP = preload("res://scripts/track_gen_params.gd")


func _params(start_pos: Vector2, start_heading: Vector2, seed_value: int, turn_count: int, width: float, clearance := 0.0, reserve := 0.0, straightness := 0.0, runoff := 0.0) -> _TGP:
	return _TGP.of(start_pos, start_heading, seed_value, turn_count, width, clearance, reserve, straightness, runoff)


# A small track gives a known cell set + anchors. Width 6, clearance 8 -> the
# returned "cells" are the clearance-inflated (22 m) collision set.
func _track() -> Dictionary:
	return await TrackGenerator.generate(_params(Vector2(0, 0), Vector2(0, 1), 3, 6, 6.0, 8.0))

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
	var t := await _track()
	var road := _road_cells(t)
	var a := TreeScatter.scatter(t["pieces"], road, PARAMS, 42)
	var b := TreeScatter.scatter(t["pieces"], road, PARAMS, 42)
	assert_eq(a, b, "same seed -> identical positions")


func test_different_seed_differs() -> void:
	var t := await _track()
	var road := _road_cells(t)
	var a := TreeScatter.scatter(t["pieces"], road, PARAMS, 1)
	var b := TreeScatter.scatter(t["pieces"], road, PARAMS, 2)
	assert_ne(a, b, "different seed -> different positions (e.g. trees vs bushes)")


func test_no_tree_lands_on_a_road_cell() -> void:
	var t := await _track()
	var road := _road_cells(t)
	var trees := TreeScatter.scatter(t["pieces"], road, PARAMS, 7)
	assert_gt(trees.size(), 0, "should place some trees")
	for pos in trees:
		assert_false(road.has(_cell_of(pos)), "no tree sits on a road cell")


func test_grid_guarantees_minimum_spacing() -> void:
	# The jittered grid's hard floor: no two points closer than (1 - jitter) * cell.
	var t := await _track()
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
	var t := await _track()
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
	var t := await _track()
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
	var t := await _track()
	var road := _road_cells(t)
	var off := PARAMS.duplicate()
	off["trees_per_turn"] = 0
	assert_eq(TreeScatter.scatter(t["pieces"], road, off, 7).size(), 0,
		"a zero target disables foliage")


# --- Forest patches (per-event forestiness gate) ----------------------------

func test_forestiness_one_is_unfiltered() -> void:
	# forestiness 1.0 (the default for trees-everywhere / bushes) skips the noise gate
	# entirely, so it matches the plain default call.
	var t := await _track()
	var road := _road_cells(t)
	var default_call := TreeScatter.scatter(t["pieces"], road, PARAMS, 7)
	var explicit := TreeScatter.scatter(t["pieces"], road, PARAMS, 7, 1.0, 300.0)
	assert_eq(explicit, default_call, "forestiness 1.0 == unfiltered (trees everywhere)")
	assert_gt(explicit.size(), 0, "and it still places trees")


func test_forestiness_zero_places_no_trees() -> void:
	var t := await _track()
	var road := _road_cells(t)
	var none := TreeScatter.scatter(t["pieces"], road, PARAMS, 7, 0.0, 300.0)
	assert_eq(none.size(), 0, "forestiness 0 -> no trees anywhere")


func test_forestiness_only_keeps_trees_above_the_noise_threshold() -> void:
	# A short wavelength so the forest noise varies across the small test track.
	var t := await _track()
	var road := _road_cells(t)
	var forestiness := 0.5
	var wavelength := 15.0
	var some := TreeScatter.scatter(t["pieces"], road, PARAMS, 7, forestiness, wavelength)
	var full := TreeScatter.scatter(t["pieces"], road, PARAMS, 7, 1.0, wavelength)
	assert_lte(some.size(), full.size(), "gating never adds trees")
	# Every placed tree must sit where the forest noise clears (1 - forestiness).
	var noise := TreeScatter.make_forest_noise(7, wavelength)
	for p in some:
		assert_gt(TreeScatter.forest_density(noise, p), 1.0 - forestiness,
			"a forest-gated tree is above the (1 - forestiness) threshold")


func test_forestiness_is_monotonic() -> void:
	# Raising forestiness only ever keeps a superset (lower threshold), so the count
	# grows monotonically from 0 (bare) up to the full unfiltered scatter.
	var t := await _track()
	var road := _road_cells(t)
	var w := 15.0
	var bare := TreeScatter.scatter(t["pieces"], road, PARAMS, 7, 0.0, w).size()
	var mid := TreeScatter.scatter(t["pieces"], road, PARAMS, 7, 0.5, w).size()
	var full := TreeScatter.scatter(t["pieces"], road, PARAMS, 7, 1.0, w).size()
	assert_eq(bare, 0, "0 forestiness is bare")
	assert_lte(mid, full, "more forestiness never removes forest")
	assert_gte(mid, bare, "more forestiness never removes forest")
	assert_gt(full, 0, "full forestiness has trees")


func test_all_on_road_places_nothing() -> void:
	# Every reachable cell marked road -> every point is rejected, nothing placed.
	var t := await _track()
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


# --- partition_by_weight: the per-region tree species split -------------------

func _sample_positions() -> PackedVector2Array:
	# A spread of distinct points (distinct 0.5 m cells) to partition.
	var pts := PackedVector2Array()
	for i in range(400):
		pts.append(Vector2(float(i) * 3.0, float(i % 7) * 5.0))
	return pts

func test_partition_covers_all_points_once() -> void:
	# Every input point lands in exactly one group; nothing is dropped or duplicated.
	var pts := _sample_positions()
	var groups := TreeScatter.partition_by_weight(pts, [0.7, 0.3], 42)
	assert_eq(groups.size(), 2, "one group per weight")
	assert_eq(groups[0].size() + groups[1].size(), pts.size(),
		"partition is a cover: total across groups equals input count")

func test_partition_is_deterministic_per_seed() -> void:
	var pts := _sample_positions()
	var a := TreeScatter.partition_by_weight(pts, [0.7, 0.3], 42)
	var b := TreeScatter.partition_by_weight(pts, [0.7, 0.3], 42)
	assert_eq(a[0], b[0], "same seed reproduces the same split")
	assert_eq(a[1], b[1], "same seed reproduces the same split")

func test_partition_weight_shifts_the_split() -> void:
	# A heavier weight on a species claims (roughly) more points than a lighter one —
	# tested only as an ordering, never a pinned ratio.
	var pts := _sample_positions()
	var groups := TreeScatter.partition_by_weight(pts, [0.8, 0.2], 42)
	assert_gt(groups[0].size(), groups[1].size(),
		"the heavier-weighted species gets more points")

func test_partition_single_species_takes_everything() -> void:
	var pts := _sample_positions()
	var groups := TreeScatter.partition_by_weight(pts, [1.0], 42)
	assert_eq(groups.size(), 1, "one group")
	assert_eq(groups[0].size(), pts.size(), "the only species gets every point")

func test_partition_zero_weights_fall_back_to_first_group() -> void:
	var pts := _sample_positions()
	var groups := TreeScatter.partition_by_weight(pts, [0.0, 0.0], 42)
	assert_eq(groups[0].size(), pts.size(), "degenerate all-zero weights -> first group")
	assert_eq(groups[1].size(), 0, "the second group is empty")
