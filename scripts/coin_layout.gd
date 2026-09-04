class_name CoinLayout
extends RefCounted
# Docs: features/collectables.md — update in the same change as this file.
# Tests: tests/headless/test_coin_layout.gd — extend in the same change.
#
# Pure, scene-free planner for stage coins (todo/roguelike-pivot.md decisions 13, 35,
# 36, 50 — stage 8 of todo/roguelike-pivot-plan.md). Mirrors SignLayout: given a
# generated stage's centerline + finish length, it returns one placement dict per
# coin. CoinField (the Node3D) turns these into meshes + the pickup trigger.
#
# OFF THE RACING LINE, BY CONSTRUCTION (decision 35). Every coin sits AT LEAST
# `offset_m` beyond the visible road edge (track_width / 2) — never on the
# carriageway, never reachable without leaving it. `offset_jitter_m` spreads coins
# across a band beyond that floor rather than pinning them all to one fixed line.
#
# NO SIGNPOSTING (decision 50, amending 35). This planner has no notion of "ahead" —
# it hands back plain world positions, and nothing upstream (pacenotes, HUD) is told
# about them before the car is on top of one. Do not add a warning here or anywhere
# else; the cost is accepted deliberately (see the decision).
#
# DETERMINISTIC IN (centerline, finish_len, track_width, seed_value, params) — a
# resumed run re-derives the SAME centerline from the SAME drawn event (its authored
# `seed` becomes GameConfig.track_seed, see StageConfig.apply_event_config), so
# world.gd feeding `track_seed + COIN_SEED_OFFSET` here reproduces byte-identical
# coins across a resume, exactly like TreeScatter's tree/bush/rock passes.

# Small arc-distance step used to estimate the road tangent by finite difference —
# mirrors SignLayout._tangent_at (kept local rather than shared: two four-line pure
# functions are cheaper to read than a cross-file dependency for this).
const TANGENT_EPS_M := 0.5


# Plan every coin for a stage. `params` (see GameConfig.coin_layout_params):
#   count            how many coins to place
#   offset_m         minimum lateral distance beyond the road edge
#   offset_jitter_m  extra random spread on top of offset_m
#   start_margin_m   arc-length kept clear of the start line
#   end_margin_m     arc-length kept clear of the finish
#
# Returns an Array of {"pos": Vector2, "side": int} — side is +1/-1, the road edge
# the coin sits off (no other consumer needs it; kept for tests/debugging).
static func plan(centerline: Curve2D, finish_len: float, track_width: float,
		seed_value: int, params: Dictionary) -> Array:
	var out: Array = []
	if centerline == null:
		return out
	var count := int(params.get("count", 0))
	if count <= 0 or finish_len <= 0.0:
		return out
	var start_margin: float = maxf(0.0, float(params.get("start_margin_m", 0.0)))
	var end_margin: float = maxf(0.0, float(params.get("end_margin_m", 0.0)))
	var usable := finish_len - start_margin - end_margin
	if usable <= 0.0:
		return out
	var offset_m: float = maxf(0.0, float(params.get("offset_m", 0.0)))
	var offset_jitter: float = maxf(0.0, float(params.get("offset_jitter_m", 0.0)))
	var half_w := track_width * 0.5

	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	# Stratified along the arc length: one coin per equal segment, so a run of N
	# coins spreads across the whole stage instead of clustering wherever the RNG
	# happens to land — the same reasoning TreeScatter's grid gives density.
	var segment := usable / float(count)
	for i in range(count):
		var lo := start_margin + segment * float(i)
		var arc := clampf(lo + rng.randf() * segment, 0.0, finish_len)
		var side := 1 if rng.randf() < 0.5 else -1
		var lateral := half_w + offset_m + rng.randf() * offset_jitter
		var pos := centerline.sample_baked(arc)
		var tangent := _tangent_at(centerline, arc, finish_len)
		var perp := Vector2(-tangent.y, tangent.x)
		out.append({
			"pos": pos + float(side) * perp * lateral,
			"side": side,
		})
	return out


# Unit road direction at an arc offset, by forward finite difference (backward near
# the end of the curve). Mirrors SignLayout._tangent_at.
static func _tangent_at(centerline: Curve2D, offset: float, length: float) -> Vector2:
	var pos := centerline.sample_baked(offset)
	var tangent: Vector2
	if offset + TANGENT_EPS_M <= length:
		tangent = centerline.sample_baked(offset + TANGENT_EPS_M) - pos
	else:
		tangent = pos - centerline.sample_baked(maxf(0.0, offset - TANGENT_EPS_M))
	if tangent.length() < 1e-5:
		return Vector2(0.0, 1.0)
	return tangent.normalized()
