extends GutTest
# The wreck site gate picks the best-placed verge whose terrain spread fits the car's
# suspension droop budget, so a parked wreck never floats over a dip. Pure logic — no
# terrain / world generation.

const WorldScript := preload("res://scripts/world.gd")


func _cand(spread: float, tag: String) -> Dictionary:
	return {"pos2": Vector2.ZERO, "tan2": Vector2(0, 1), "top": 0.0, "spread": spread, "tag": tag}


func test_picks_first_candidate_within_budget() -> void:
	# Order = preference (nearest shoulder first). The first one that fits wins even if a
	# later one is flatter.
	var cands := [_cand(0.9, "too_steep"), _cand(0.3, "fits_first"), _cand(0.1, "flatter_but_later")]
	var chosen := WorldScript._pick_wreck_candidate(cands, 0.35)
	assert_eq(chosen["tag"], "fits_first", "first within-budget candidate is chosen, order preserved")


func test_falls_back_to_flattest_when_none_fit() -> void:
	var cands := [_cand(0.9, "a"), _cand(0.6, "flattest"), _cand(0.8, "c")]
	var chosen := WorldScript._pick_wreck_candidate(cands, 0.35)
	assert_eq(chosen["tag"], "flattest", "when none fit, the flattest is chosen")


func test_empty_returns_empty() -> void:
	assert_true(WorldScript._pick_wreck_candidate([], 0.35).is_empty(),
		"no candidates -> empty result")
