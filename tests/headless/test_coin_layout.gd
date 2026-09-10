extends GutTest
# CoinLayout (scripts/coin_layout.gd) — the pure planner that places stage coins
# (todo/roguelike-pivot.md decisions 13, 35, 36, 50 — decision 35 REVERSED by
# explicit user request, see features/collectables.md). No scene, no generated
# track: a synthetic straight centerline is enough to check the placement CONTRACT —
# on the carriageway, spread scaling with the configured fraction, inside the stage
# margins, and reproducible from a seed — without depending on TrackGenerator's
# real output.

const TrackFixtures = preload("res://tests/headless/track_fixtures.gd")

const TRACK_WIDTH := 6.0
const LENGTH := 1000.0


func _centerline() -> Curve2D:
	return TrackFixtures.straight(LENGTH)["centerline"] as Curve2D


func _params(count := 5, lane_spread_frac := 0.6,
		start_margin := 40.0, end_margin := 40.0) -> Dictionary:
	return {
		"count": count, "lane_spread_frac": lane_spread_frac,
		"start_margin_m": start_margin, "end_margin_m": end_margin,
	}


func test_places_exactly_the_requested_count() -> void:
	var layout := CoinLayout.plan(_centerline(), LENGTH, TRACK_WIDTH, 1, _params(6))
	assert_eq(layout.size(), 6)


func test_zero_or_negative_count_places_nothing() -> void:
	assert_eq(CoinLayout.plan(_centerline(), LENGTH, TRACK_WIDTH, 1, _params(0)).size(), 0)
	assert_eq(CoinLayout.plan(_centerline(), LENGTH, TRACK_WIDTH, 1, _params(-3)).size(), 0)


func test_margins_that_consume_the_whole_stage_place_nothing() -> void:
	# start_margin + end_margin >= finish_len leaves no usable arc length at all.
	var params := _params(4, 0.6, LENGTH, LENGTH)
	assert_eq(CoinLayout.plan(_centerline(), LENGTH, TRACK_WIDTH, 1, params).size(), 0)


func test_every_coin_sits_within_the_carriageway() -> void:
	# Decision 35 (reversed) — the whole mechanic now. A straight track's
	# perpendicular is pure +/-X, so the lateral distance is just abs(pos.x).
	var layout := CoinLayout.plan(_centerline(), LENGTH, TRACK_WIDTH, 7,
		_params(8, 0.8))
	assert_gt(layout.size(), 0, "setup: some coins were placed")
	var half_w := TRACK_WIDTH * 0.5
	for entry in layout:
		var pos: Vector2 = entry["pos"]
		assert_true(absf(pos.x) <= half_w + 0.001,
			"a coin never sits beyond the visible road edge")


func test_zero_spread_places_coins_exactly_on_the_centerline() -> void:
	# Sanity guard, not a pinned value (CLAUDE.md): 0 spread collapses to exactly
	# the centerline (lateral == 0), not a fudge factor.
	var layout := CoinLayout.plan(_centerline(), LENGTH, TRACK_WIDTH, 3, _params(4, 0.0))
	for entry in layout:
		var pos: Vector2 = entry["pos"]
		assert_almost_eq(absf(pos.x), 0.0, 0.001)


func test_larger_spread_fraction_allows_wider_lateral_offsets() -> void:
	# Sanity guard on the RELATIONSHIP, not a pinned magnitude: a bigger fraction
	# widens the band coins can land in (up to the road edge), it never shrinks it.
	var narrow := CoinLayout.plan(_centerline(), LENGTH, TRACK_WIDTH, 3, _params(10, 0.2))
	var wide := CoinLayout.plan(_centerline(), LENGTH, TRACK_WIDTH, 3, _params(10, 1.0))
	var narrow_max := 0.0
	for entry in narrow:
		var pos: Vector2 = entry["pos"]
		narrow_max = maxf(narrow_max, absf(pos.x))
	var wide_max := 0.0
	for entry in wide:
		var pos: Vector2 = entry["pos"]
		wide_max = maxf(wide_max, absf(pos.x))
	assert_true(wide_max >= narrow_max,
		"the wider spread fraction's coins reach at least as far from the centerline")


func test_coins_stay_within_the_start_and_end_margins() -> void:
	var start_margin := 50.0
	var end_margin := 80.0
	var layout := CoinLayout.plan(_centerline(), LENGTH, TRACK_WIDTH, 11,
		_params(10, 0.6, start_margin, end_margin))
	assert_gt(layout.size(), 0, "setup: some coins were placed")
	for entry in layout:
		var pos: Vector2 = entry["pos"]
		# The straight track runs from z=0 to z=-LENGTH, so arc length == -pos.z.
		var arc := -pos.y
		assert_true(arc >= start_margin - 0.01, "no coin sits in the opening straight")
		assert_true(arc <= LENGTH - end_margin + 0.01, "no coin sits in the closing straight")


func test_coins_spread_across_the_stage_rather_than_clustering() -> void:
	# Stratified sampling (one coin per equal arc segment): the first and last coin
	# should land on opposite ends of the usable stage, not next to each other.
	var layout := CoinLayout.plan(_centerline(), LENGTH, TRACK_WIDTH, 5, _params(6))
	var arcs: Array[float] = []
	for entry in layout:
		var pos: Vector2 = entry["pos"]
		arcs.append(-pos.y)
	arcs.sort()
	assert_gt(arcs[arcs.size() - 1] - arcs[0], LENGTH * 0.5,
		"coins span at least half the usable stage length")


func test_same_seed_reproduces_the_same_layout() -> void:
	# THE DETERMINISM CONTRACT a resumed run depends on (world.gd seeds this off
	# cfg.track_seed, which a resume re-derives byte-identical from the same drawn
	# event) — same inputs must give the same coins, every field.
	var a := CoinLayout.plan(_centerline(), LENGTH, TRACK_WIDTH, 424242, _params(7))
	var b := CoinLayout.plan(_centerline(), LENGTH, TRACK_WIDTH, 424242, _params(7))
	assert_eq(a.size(), b.size())
	for i in a.size():
		var pa: Vector2 = a[i]["pos"]
		var pb: Vector2 = b[i]["pos"]
		assert_eq(pa, pb, "coin %d lands at the exact same position both times" % i)
		assert_eq(a[i]["side"], b[i]["side"])


func test_different_seeds_place_different_layouts() -> void:
	var a := CoinLayout.plan(_centerline(), LENGTH, TRACK_WIDTH, 1, _params(6))
	var b := CoinLayout.plan(_centerline(), LENGTH, TRACK_WIDTH, 2, _params(6))
	var identical := true
	for i in mini(a.size(), b.size()):
		var pa: Vector2 = a[i]["pos"]
		var pb: Vector2 = b[i]["pos"]
		if pa != pb:
			identical = false
			break
	assert_false(identical, "a different seed rolls a different layout")
