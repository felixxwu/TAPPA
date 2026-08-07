extends GutTest
# TrackGenerator: a pure-2D search that chains CornerLibrary corners (corner ->
# straight -> corner) from a start frame, avoiding cell overlaps, and returns a
# centerline Curve2D plus an occupied-cell set. These tests cover the geometry
# helpers first, then the full search.


func test_frame_transform_maps_local_axes_to_world() -> void:
	# Local +Y is "forward" (the heading); local +X is "right" of it.
	var xf := TrackGenerator.frame_transform(Vector2(10.0, 5.0), Vector2(0.0, 1.0))
	assert_almost_eq(xf * Vector2(0.0, 0.0), Vector2(10.0, 5.0), Vector2(1e-4, 1e-4),
		"origin maps to the frame position")
	assert_almost_eq(xf * Vector2(0.0, 1.0), Vector2(10.0, 6.0), Vector2(1e-4, 1e-4),
		"local +Y (forward) follows the heading")
	# A vector (no translation) only rotates.
	assert_almost_eq(xf.basis_xform(Vector2(0.0, 2.0)), Vector2(0.0, 2.0), Vector2(1e-4, 1e-4),
		"basis_xform ignores translation")


func test_mirror_points_negates_x_when_flipped() -> void:
	var pts := [
		[Vector2(0.0, 0.0), Vector2(0.0, 0.0), Vector2(0.0, 3.0)],
		[Vector2(2.0, 4.0), Vector2(-1.0, -0.5), Vector2(0.0, 0.0)],
	]
	var same := TrackGenerator.mirror_points(pts, false)
	assert_almost_eq(same[1][0], Vector2(2.0, 4.0), Vector2(1e-4, 1e-4), "no flip keeps x")
	var flipped := TrackGenerator.mirror_points(pts, true)
	assert_almost_eq(flipped[1][0], Vector2(-2.0, 4.0), Vector2(1e-4, 1e-4), "flip negates pos.x")
	assert_almost_eq(flipped[1][1], Vector2(1.0, -0.5), Vector2(1e-4, 1e-4), "flip negates in_control.x")


func test_rasterize_cells_covers_width_around_a_straight() -> void:
	# A 10 m straight along +X at the origin, width 2 m -> cells within 1 m of it.
	var line := PackedVector2Array([Vector2(0.0, 0.0), Vector2(10.0, 0.0)])
	var cells := TrackGenerator.rasterize_cells(line, 2.0)
	# The cell at the centre of the line is included.
	assert_true(cells.has(Vector2i(5, 0)), "centre cell on the line is covered")
	# A cell well outside half-width (>1 m away in z) is not.
	assert_false(cells.has(Vector2i(5, 8)), "cell 4 m off the line is not covered")
	# Coverage is symmetric about the line (z just above and below).
	assert_true(cells.has(Vector2i(5, -1)), "cell just below the line is covered")


func test_exit_heading_is_unit_direction_of_last_segment() -> void:
	var poly := PackedVector2Array([Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(1.0, 3.0)])
	var h := TrackGenerator.exit_heading(poly)
	assert_almost_eq(h, Vector2(0.0, 1.0), Vector2(1e-4, 1e-4), "heading follows the last segment, normalised")


const START_POS := Vector2(0.0, 0.0)
const START_HEADING := Vector2(0.0, 1.0)
const _TGP = preload("res://scripts/track_gen_params.gd")


func _params(start_pos: Vector2, start_heading: Vector2, seed_value: int, turn_count: int, width: float, clearance := 0.0, reserve := 0.0, straightness := 0.0, runoff := 0.0) -> _TGP:
	return _TGP.of(start_pos, start_heading, seed_value, turn_count, width, clearance, reserve, straightness, runoff)


func _generate(seed_value: int, turns: int = 6, width: float = 6.0) -> Dictionary:
	return await TrackGenerator.generate(_params(START_POS, START_HEADING, seed_value, turns, width))


func test_generate_is_deterministic_per_seed() -> void:
	var a := await _generate(7)
	var b := await _generate(7)
	assert_eq(a["cells"].size(), b["cells"].size(), "same seed -> same number of cells")
	assert_eq(a["pieces"].size(), b["pieces"].size(), "same seed -> same number of pieces")


func test_generate_places_requested_corner_count() -> void:
	var r := await _generate(3, 6)
	assert_eq(r["pieces"].size(), 6, "exactly the requested number of corners are placed")
	assert_true(r["complete"], "the search completed within the cap")


func test_generate_avoids_the_reserved_start_corridor() -> void:
	# Mimics the start-line lead-in: a straight corridor reserved BEHIND the start
	# (−heading). The search must not loop the track back across it.
	var width := 6.0
	var clearance := 8.0
	var reserve := 38.0  # ahead (22) + behind (16), as world.gd passes
	var r := await TrackGenerator.generate(_params(START_POS, START_HEADING, 7, 10, width, clearance, reserve))
	assert_true(r["complete"], "still generates with a reserved start corridor")
	var coll := width + 2.0 * clearance
	var back := START_POS - START_HEADING * reserve
	var reserved := TrackGenerator.rasterize_cells(PackedVector2Array([START_POS, back]), coll)
	# Placed cells may touch the corridor only near the start (the join/emergence,
	# within the buffer); none may overlap the far corridor (a genuine loop-back).
	var far_overlaps := 0
	for cell in r["cells"]:
		if reserved.has(cell):
			var c := Vector2((cell.x + 0.5) * 0.5, (cell.y + 0.5) * 0.5)  # CELL_M = 0.5
			if c.distance_to(START_POS) > coll * 1.5:
				far_overlaps += 1
	assert_eq(far_overlaps, 0, "track never loops back into the reserved start corridor")


func test_reservation_keeps_generation_deterministic() -> void:
	var a := await TrackGenerator.generate(_params(START_POS, START_HEADING, 7, 10, 6.0, 8.0, 38.0))
	var b := await TrackGenerator.generate(_params(START_POS, START_HEADING, 7, 10, 6.0, 8.0, 38.0))
	assert_eq(a["cells"].size(), b["cells"].size(), "same inputs + reserve -> same track")
	assert_eq(a["pieces"].size(), b["pieces"].size(), "deterministic piece count with a reservation")


func test_generate_starts_at_the_spawn_frame() -> void:
	var r := await _generate(5)
	var curve: Curve2D = r["centerline"]
	assert_gt(curve.point_count, 1, "centerline has multiple points")
	assert_almost_eq(curve.get_point_position(0), START_POS, Vector2(1e-3, 1e-3),
		"centerline starts at the spawn position")


func test_generate_avoids_cell_overlap_between_pieces() -> void:
	# Each piece records the cells it added; those sets must be disjoint (the
	# search adds a cell to the occupied set only once, on the piece that claims
	# it), proving no later piece re-covers an earlier piece's cells.
	var r := await _generate(11, 8)
	var seen: Dictionary = {}
	for piece in r["pieces"]:
		for cell in piece["cells"]:
			assert_false(seen.has(cell), "cell %s claimed by exactly one piece" % cell)
			seen[cell] = true


func test_clearance_inflates_the_collision_footprint() -> void:
	# Clearance feeds the overlap test as `width + 2*clearance`: a straight whose
	# footprint is rasterized at the inflated width covers cells the bare width
	# would not, so neighbouring sections must keep that extra gap.
	var line := PackedVector2Array([Vector2(0.0, 0.0), Vector2(10.0, 0.0)])
	var bare := TrackGenerator.rasterize_cells(line, 6.0)            # half-width 3 m
	var inflated := TrackGenerator.rasterize_cells(line, 6.0 + 2.0 * 6.0)  # half-width 9 m
	assert_false(bare.has(Vector2i(5, 8)), "cell ~4 m off the line is clear at width only")
	assert_true(inflated.has(Vector2i(5, 8)), "the same cell is occupied once clearance is added")


func test_generate_with_clearance_is_deterministic_and_non_overlapping() -> void:
	# generate() threads clearance through the search: still deterministic per
	# seed, and pieces still claim disjoint cells (the core overlap invariant).
	var a := await TrackGenerator.generate(_params(START_POS, START_HEADING, 11, 8, 6.0, 6.0))
	var b := await TrackGenerator.generate(_params(START_POS, START_HEADING, 11, 8, 6.0, 6.0))
	assert_eq(int(a["cells"].size()), int(b["cells"].size()),
		"same seed + clearance -> identical footprint")
	var seen: Dictionary = {}
	for piece in a["pieces"]:
		for cell in piece["cells"]:
			assert_false(seen.has(cell), "cell %s claimed by exactly one piece" % cell)
			seen[cell] = true


func test_generate_is_g1_continuous_at_joins() -> void:
	# Consecutive tessellated centerline segments never reverse direction: the
	# angle between successive segment directions stays well under 90 degrees,
	# i.e. the track has no kinks/cusps at piece joins.
	var r := await _generate(2, 8)
	var pts: PackedVector2Array = (r["centerline"] as Curve2D).tessellate()
	for i in range(2, pts.size()):
		var d0 := (pts[i - 1] - pts[i - 2])
		var d1 := (pts[i] - pts[i - 1])
		if d0.length() < 1e-4 or d1.length() < 1e-4:
			continue
		assert_gt(d0.normalized().dot(d1.normalized()), 0.0,
			"no reversal between successive segments at index %d" % i)


func test_generate_uses_both_left_and_right_flips() -> void:
	var lefts := false
	var rights := false
	for seed_value in [1, 2, 3, 4, 5]:
		for piece in (await _generate(seed_value))["pieces"]:
			if piece["flip"]:
				lefts = true
			else:
				rights = true
	assert_true(lefts and rights, "both left and right corners appear across seeds")


# Gentleness (0 = hairpin, 1 = no turn) of each library corner, by name — the same
# measure the generator biases on.
func _corner_gentleness_by_name() -> Dictionary:
	var m := {}
	for spec in CornerLibrary.CORNERS:
		m[spec["name"]] = TrackGenerator._corner_straightness(spec)
	return m


# Mean gentleness of the corners actually placed in a generated track.
func _avg_gentleness(result: Dictionary, by_name: Dictionary) -> float:
	var total := 0.0
	var n := 0
	for piece in result["pieces"]:
		if by_name.has(piece["corner"]):
			total += by_name[piece["corner"]]
			n += 1
	return total / float(maxi(n, 1))


# Which authored corner names count as a hairpin, by SHAPE — the same predicate the
# generator uses (TrackGenerator._is_hairpin over _corner_straightness), so these tests
# keep testing the rule rather than a corner's display name. Iterates the whole
# CornerLibrary table as opaque input; it never leans on one entry's identity.
func _hairpin_names() -> Dictionary:
	var out := {}
	for spec in CornerLibrary.CORNERS:
		if TrackGenerator._is_hairpin(spec):
			out[String(spec["name"])] = true
	return out


func test_generated_tracks_never_place_two_hairpins_in_a_row() -> void:
	# A 180 straight into another 180 is a switchback, not rally flow, so the DFS
	# rejects the pairing outright. Swept across seeds and both bias extremes, since
	# the ban lives in the search rather than in the candidate weighting — an unbiased
	# search is where the pairing used to show up.
	var hairpins := _hairpin_names()
	assert_gt(hairpins.size(), 0, "the corner library authors at least one hairpin shape")
	for seed_value in range(1, 16):
		for straightness in [0.0, 1.0]:
			var result := await TrackGenerator.generate(
				_params(START_POS, START_HEADING, seed_value, 12, 6.0, 0.0, 0.0, straightness))
			var pieces: Array = result["pieces"]
			for i in range(1, pieces.size()):
				var pair_is_double_hairpin := \
					hairpins.has(String(pieces[i - 1]["corner"])) \
					and hairpins.has(String(pieces[i]["corner"]))
				assert_false(pair_is_double_hairpin,
					"seed %d straightness %s: pieces %d/%d are both hairpins"
						% [seed_value, straightness, i - 1, i])


func test_a_hairpin_still_gets_placed_after_a_non_hairpin() -> void:
	# Guard the ban against over-reach: it must reject only the CONSECUTIVE pairing,
	# not exile the hairpin from the corner pool altogether.
	var hairpins := _hairpin_names()
	var seen := false
	for seed_value in range(1, 16):
		for piece in (await _generate(seed_value, 12))["pieces"]:
			if hairpins.has(String(piece["corner"])):
				seen = true
				break
		if seen:
			break
	assert_true(seen, "hairpins still appear in generated tracks, just never back-to-back")


func test_hairpin_is_decided_by_shape_not_by_corner_name() -> void:
	# The rule must key off the authored GEOMETRY: a renamed hairpin, or a second
	# near-180 corner added under any other name, still counts. A gentle corner never
	# does, whatever it is called. Synthetic corners — no dependence on the catalogue.
	var u_turn := {"name": "Switchback", "points": [
		[Vector2(0.0, 0.0), Vector2(0.0, 0.0), Vector2(0.0, 11.457)],
		[Vector2(9.0, 15.0), Vector2(-4.971, 0.0), Vector2(4.971, 0.0)],
		[Vector2(18.0, 0.0), Vector2(0.0, 11.971), Vector2(0.0, 0.0)],
	]}
	# NB: distinct names matter — _corner_straightness memoises by name, so reusing a
	# name already in the catalogue would return that corner's cached value instead of
	# measuring this shape. Names are unique within a corner list, so this only bites
	# synthetic fixtures like these.
	var gentle := {"name": "TestSweeper", "points": [
		[Vector2(0.0, 0.0), Vector2(0.0, 0.0), Vector2(0.0, 18.347)],
		[Vector2(8.36, 65.854), Vector2(-5.17, -18.182), Vector2(0.0, 0.0)],
	]}
	assert_true(TrackGenerator._is_hairpin(u_turn),
		"a ~180 corner counts as a hairpin whatever it is named")
	assert_false(TrackGenerator._is_hairpin(gentle),
		"a gentle corner never counts as a hairpin")


func test_straightness_bias_produces_gentler_tracks() -> void:
	# Averaged across many seeds, a fully straightness-biased track places gentler
	# corners (and longer straights) than an unbiased one — the "easier" track knob.
	# The bias is probabilistic (a weighted shuffle), so the gentleness edge only
	# emerges in aggregate; a handful of seeds is too noisy to assert on reliably
	# (any single seed can tie or invert), hence the wide seed sweep here.
	var by_name := _corner_gentleness_by_name()
	var plain := 0.0
	var biased := 0.0
	var seeds := range(1, 21)
	for s in seeds:
		var a := await TrackGenerator.generate(_params(START_POS, START_HEADING, s, 10, 6.0, 0.0, 0.0, 0.0))
		var b := await TrackGenerator.generate(_params(START_POS, START_HEADING, s, 10, 6.0, 0.0, 0.0, 1.0))
		plain += _avg_gentleness(a, by_name)
		biased += _avg_gentleness(b, by_name)
	assert_gt(biased, plain,
		"straightness=1 yields gentler corners on average than straightness=0")


func test_straightness_generation_is_deterministic_and_complete() -> void:
	# A straightness-biased search is still seeded → identical run to run, and the bias
	# only reorders candidates so the track still completes.
	var a := await TrackGenerator.generate(_params(START_POS, START_HEADING, 7, 10, 6.0, 0.0, 0.0, 0.8))
	var b := await TrackGenerator.generate(_params(START_POS, START_HEADING, 7, 10, 6.0, 0.0, 0.0, 0.8))
	assert_eq(a["pieces"].size(), b["pieces"].size(), "same inputs + straightness -> same piece count")
	assert_eq(a["cells"].size(), b["cells"].size(), "same inputs + straightness -> same cells")
	assert_true(a["complete"], "a straightness-biased track still completes")


func test_every_rally_event_generates_a_complete_track_quickly() -> void:
	# Regression guard for the seed-3002 blow-up: rwd_masters event 2 once spent ~8
	# minutes (~474s) generating, because a boxed-in DFS ground its whole step budget
	# re-rasterizing every candidate's full footprint. After the fix (early-exit /
	# capsule collision + a tight per-attempt budget that bails a thrashing seed to a
	# fresh diverse restart), EVERY authored rally event must generate a COMPLETE track,
	# and the whole set must finish fast.
	#
	# The bound was ~7s when every event's turn_count sat at its original authored value.
	# Every rally-library event was later authored ~15% longer (more corners to place),
	# and DFS cost is NOT linear in turn_count — the per-attempt step budget is
	# STEPS_BASE + turn_count * STEPS_PER_TURN, and a seed closer to boxing itself in
	# backtracks more per attempt too — so the honest new baseline is ~70-80s, not ~8s,
	# with normal run-to-run variance of a few seconds either way. 180s keeps real
	# headroom above that (over 2x) while still catching a genuine return of a
	# multi-MINUTE blowup like the original. If this starts flaking near the bound
	# again after a future turn_count change, re-measure and move it — don't just
	# raise it blindly.
	Config.reset()
	var clearance: float = Config.data.track_clearance
	var t0 := Time.get_ticks_msec()
	for rally in RallyLibrary.RALLIES:
		for event in rally["events"]:
			var r := await TrackGenerator.generate(_params(
				Vector2.ZERO, Vector2(0.0, -1.0), int(event.get("seed", 0)),
				int(event.get("turn_count", 10)), RallyLibrary.event_width(event), clearance,
				0.0, RallyLibrary.event_straightness(event)))
			assert_true(r["complete"],
				"rally %s seed %d generates a complete track (no partial)" % [
					rally["id"], int(event.get("seed", 0))])
	assert_lt(Time.get_ticks_msec() - t0, 180000,
		"all rally tracks generate well under the old blow-up's ~8 min (one seed used to take ~474s)")


func test_zero_runoff_reports_no_segment() -> void:
	var r := await TrackGenerator.generate(_params(START_POS, START_HEADING, 7, 8, 6.0))
	assert_true(r.has("runoff"), "result always carries a runoff key")
	assert_true(r["runoff"].is_empty(), "no runoff requested -> no runoff segment")


func test_runoff_straight_does_not_overlap_the_track() -> void:
	var width := 6.0
	var runoff := 20.0
	var r := await TrackGenerator.generate(_params(START_POS, START_HEADING, 7, 8, width, 0.0, 0.0, 0.0, runoff))
	assert_true(r["complete"], "generates with a runoff requirement")
	assert_false(r["runoff"].is_empty(), "a completed track reports its runoff segment")
	# Re-derive the runoff start (the last corner's exit) and rasterize the straight.
	var start_exit: Vector2 = r["runoff"]["end_pos"] - r["runoff"]["heading"] * runoff
	var runoff_cells := TrackGenerator.rasterize_cells(
		PackedVector2Array([start_exit, r["runoff"]["end_pos"]]), width)
	# Cells within the join buffer of the exit are allowed to touch the last corner
	# (that's where the runoff attaches); everything beyond must be clear track.
	var buffer_sq := width * width
	for cell in runoff_cells:
		var centre := Vector2((cell.x + 0.5) * TrackGenerator.CELL_M,
			(cell.y + 0.5) * TrackGenerator.CELL_M)
		if centre.distance_squared_to(start_exit) <= buffer_sq:
			continue
		assert_false(r["cells"].has(cell),
			"runoff cell %s beyond the join must not overlap the placed track" % cell)


func test_retreat_depth_first_dead_end_undoes_one_corner() -> void:
	# n=0 (first consecutive dead end) must equal the pre-change behaviour: undo 1.
	assert_eq(TrackGenerator._retreat_depth(0, 5), 1, "first dead end undoes a single corner")
	assert_eq(TrackGenerator._retreat_depth(0, 1), 1, "still 1 even with a tiny cap")


func test_retreat_depth_is_monotonic_non_decreasing() -> void:
	# More consecutive dead ends never retreats FEWER corners.
	var cap := 100
	var prev := TrackGenerator._retreat_depth(0, cap)
	for n in range(1, 20):
		var cur := TrackGenerator._retreat_depth(n, cap)
		assert_true(cur >= prev, "retreat depth does not decrease as dead ends accumulate (n=%d)" % n)
		prev = cur


func test_retreat_depth_never_exceeds_cap() -> void:
	for n in range(0, 50):
		assert_true(TrackGenerator._retreat_depth(n, 4) <= 4, "retreat depth is clamped to the cap (n=%d)" % n)


func test_retreat_depth_treats_sub_one_cap_as_one() -> void:
	# A degenerate cap (< 1) must not produce a zero/negative undo.
	assert_eq(TrackGenerator._retreat_depth(3, 0), 1, "cap of 0 clamps up to 1")
	assert_eq(TrackGenerator._retreat_depth(3, -5), 1, "negative cap clamps up to 1")


func test_on_progress_does_not_change_result() -> void:
	# Determinism: the returned track is identical with and without the callback.
	var plain := await TrackGenerator.generate(_params(START_POS, START_HEADING, 7, 6, 6.0))
	var noop := func(_pts: PackedVector2Array) -> void: pass
	var withcb: Dictionary = await TrackGenerator.generate(
		_params(START_POS, START_HEADING, 7, 6, 6.0, 0.0, 0.0, 0.0, 0.0), noop)
	assert_eq(withcb["complete"], plain["complete"], "completion unchanged by on_progress")
	assert_eq(withcb["pieces"].size(), plain["pieces"].size(), "piece count unchanged by on_progress")
	assert_eq(str(withcb["cells"].keys()), str(plain["cells"].keys()),
		"occupied cells unchanged by on_progress (determinism preserved)")


func test_on_progress_receives_valid_partial_polylines() -> void:
	var snaps: Array = []
	var cb := func(pts: PackedVector2Array) -> void: snaps.append(pts.duplicate())
	await TrackGenerator.generate(_params(START_POS, START_HEADING, 7, 6, 6.0, 0.0, 0.0, 0.0, 0.0), cb)
	assert_gt(snaps.size(), 0, "on_progress fires at least once during a search")
	for pts in snaps:
		assert_true(pts is PackedVector2Array, "each snapshot is a PackedVector2Array")
		assert_gt(pts.size(), 0, "each snapshot has at least the start point")
		assert_almost_eq(pts[0], START_POS, Vector2(1e-4, 1e-4), "snapshot starts at the search start pos")


func test_generate_stays_synchronous_without_callback() -> void:
	# generate() is a coroutine, but with no on_progress it never suspends —
	# awaiting it returns the fully-built track dict the same frame.
	var result: Dictionary = await TrackGenerator.generate(_params(START_POS, START_HEADING, 7, 6, 6.0))
	assert_true(result.has("centerline"), "returns the full track dict with no on_progress")
	assert_true(result.has("pieces"), "result includes the placed pieces")


# --- Hot-path rewrites (todo/mobile-web-performance.md §2.3/§2.4) ---------------
# These cover the BEHAVIOUR the optimisations must preserve, not their speed.

func test_rasterize_cells_matches_a_brute_force_distance_scan() -> void:
	# rasterize_cells now scans each segment's bounding box with a point-to-segment
	# distance test. Its contract is unchanged: a cell is in the set iff its centre is
	# within half-width of the polyline. Checked against an independent brute-force
	# sweep of every cell in a generous box around a bent polyline.
	var line := PackedVector2Array([Vector2(0.0, 0.0), Vector2(8.0, 0.0), Vector2(8.0, 6.0)])
	var width := 3.0
	var half := width / 2.0
	var cells := TrackGenerator.rasterize_cells(line, width)
	var cell_m := TrackGenerator.CELL_M
	for cz in range(-8, 20):
		for cx in range(-8, 24):
			var centre := Vector2((cx + 0.5) * cell_m, (cz + 0.5) * cell_m)
			var nearest := INF
			for i in range(1, line.size()):
				nearest = minf(nearest, sqrt(TrackGenerator._point_seg_dist_sq(centre, line[i - 1], line[i])))
			var expected := nearest <= half
			assert_eq(cells.has(Vector2i(cx, cz)), expected,
				"cell %s inclusion matches the distance test" % Vector2i(cx, cz))


func test_collide_and_cells_extra_set_is_treated_as_occupied() -> void:
	# The `extra` parameter replaced a full duplicate() of the occupancy dictionary in
	# the runoff check: cells passed there must collide exactly as if they were in
	# `occupied`. Probe a straight far from the frame position so the join buffer
	# (which legitimately allows touching near the entry) can't mask the result.
	var line := PackedVector2Array([Vector2(100.0, 0.0), Vector2(140.0, 0.0)])
	var width := 6.0
	var footprint := TrackGenerator.rasterize_cells(line, width)
	var clean := TrackGenerator._collide_and_cells(line, width, {}, {}, Vector2.ZERO)
	assert_false(clean["collides"], "nothing occupied -> no collision")
	var via_extra := TrackGenerator._collide_and_cells(line, width, {}, {}, Vector2.ZERO, null, footprint)
	assert_true(via_extra["collides"], "a cell in `extra` collides")
	var via_occupied := TrackGenerator._collide_and_cells(line, width, footprint, {}, Vector2.ZERO)
	assert_eq(via_extra["collides"], via_occupied["collides"],
		"`extra` and `occupied` are tested identically")


func test_corner_straightness_is_memoised_to_the_same_value() -> void:
	# Memoising must not change the value: a second call returns the first one, and it
	# still agrees with the freshly tessellated shape.
	assert_gt(CornerLibrary.CORNERS.size(), 0, "CornerLibrary.CORNERS is non-empty (else this test asserts nothing)")
	for spec in CornerLibrary.CORNERS:
		var first := TrackGenerator._corner_straightness(spec)
		var second := TrackGenerator._corner_straightness(spec)
		assert_eq(first, second, "memoised value is stable for '%s'" % spec["name"])
		var poly := CornerLibrary.build_curve(spec).tessellate()
		var angle := absf(Vector2(0.0, 1.0).angle_to(TrackGenerator.exit_heading(poly)))
		assert_almost_eq(first, clampf(1.0 - angle / PI, 0.0, 1.0), 1e-9,
			"memo agrees with the corner's actual heading change ('%s')" % spec["name"])


# How often each corner comes out FIRST in the candidate draw — i.e. the corner the
# search tries before any other, which is what the weighting actually controls. Sampled
# off _candidates directly rather than off generated tracks: it is the same code path the
# DFS consumes, but thousands of draws cost milliseconds instead of thousands of searches,
# and no collision/backtracking noise sits between the weights and the measurement.
func _first_pick_counts(corners: Array, straightness: float, samples: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 90210
	var counts := {}
	for spec in corners:
		counts[String(spec["name"])] = 0
	for _i in samples:
		var first: Dictionary = TrackGenerator._candidates(corners, rng, straightness)[0]
		var picked := String(corners[first["corner_index"]]["name"])
		counts[picked] += 1
	return counts


# The rarity multiplier the generator resolves for each authored corner, by name —
# read through the generator's own accessor so the tests below follow a retune of
# CORNER_WEIGHTS instead of pinning the chosen numbers.
func _corner_multipliers(corners: Array) -> Dictionary:
	var out := {}
	for i in corners.size():
		out[String(corners[i]["name"])] = TrackGenerator._candidate_weight_multiplier(
			corners, { "corner_index": i, "flip": false, "straight": 0.0 })
	return out


func test_corner_weights_name_real_corners() -> void:
	# CORNER_WEIGHTS is keyed by corner NAME (rarity is an authoring choice about one
	# shape, not something its curve expresses), which means a rename would silently drop
	# that corner back to its full, unweighted share. Fail loudly here instead.
	var authored := {}
	for spec in CornerLibrary.CORNERS:
		authored[String(spec["name"])] = true
	assert_gt(TrackGenerator.CORNER_WEIGHTS.size(), 0,
		"CORNER_WEIGHTS is non-empty (else the tests below assert nothing)")
	for name in TrackGenerator.CORNER_WEIGHTS:
		assert_true(authored.has(String(name)),
			"CORNER_WEIGHTS key '%s' is a real CornerLibrary corner" % name)


func test_corner_weights_shape_the_draw_with_no_straightness_bias() -> void:
	# The multipliers must apply to EVERY track, so they have to bite at straightness 0 —
	# where the draw used to be a plain unbiased shuffle. With the straightness factor at
	# 1 for every candidate, a corner's weight IS its multiplier, so its expected share of
	# first picks is mult / sum(mult): an exact prediction derived from the table (not from
	# the chosen numbers), which a retune follows automatically.
	var corners := TrackGenerator._turn_corners()
	var mult := _corner_multipliers(corners)
	var total := 0.0
	for name in mult:
		total += float(mult[name])
	var samples := 4000
	var counts := _first_pick_counts(corners, 0.0, samples)
	for name in counts:
		var expected := float(mult[name]) / total
		var observed := float(counts[name]) / float(samples)
		# 25% relative band: ~3 sigma for the rarest corner at this sample count, so the
		# assertion tracks the weights without turning sampling noise into a failure.
		assert_almost_eq(observed, expected, expected * 0.25,
			"'%s' is drawn first at its weighted share (%.3f expected)" % [name, expected])


func test_corner_weights_never_exclude_a_corner() -> void:
	# Rarity is not exclusion: even the most heavily down-weighted shape has to keep
	# turning up, at both bias extremes, or the DFS would lose the fallback it needs when
	# nothing gentler fits (and the CORNER_WEIGHT_MIN floor would be doing nothing).
	var corners := TrackGenerator._turn_corners()
	for straightness in [0.0, 1.0]:
		var counts := _first_pick_counts(corners, straightness, 4000)
		for name in counts:
			assert_gt(int(counts[name]), 0,
				"'%s' is still drawn first sometimes at straightness %s" % [name, straightness])


func test_down_weighted_corners_are_rarer_than_full_weight_ones() -> void:
	# The ordering that the multipliers exist to create, stated without reference to any
	# particular value: anything the table marks down is drawn less than anything it
	# leaves alone, and a smaller multiplier is rarer than a larger one. Measured at
	# straightness 0 — the only setting where corners are comparable on weight alone,
	# since above it the straightness bias also sorts them by sharpness.
	var corners := TrackGenerator._turn_corners()
	var mult := _corner_multipliers(corners)
	var counts := _first_pick_counts(corners, 0.0, 4000)
	var down := 0
	for a in counts:
		for b in counts:
			if float(mult[a]) >= float(mult[b]):
				continue
			down += 1
			assert_lt(int(counts[a]), int(counts[b]),
				"'%s' (weight %s) is drawn less often than '%s' (weight %s)"
					% [a, mult[a], b, mult[b]])
	assert_gt(down, 0, "at least one corner is down-weighted relative to another")


func test_candidate_order_is_a_deterministic_permutation() -> void:
	# The weighted draw now sorts an index permutation with an explicit (key, index)
	# tie-break instead of dictionaries, so the order must be fully determined by the
	# seed — and must still contain every candidate exactly once.
	var corners := TrackGenerator._turn_corners()
	var expected := corners.size() * 2 * TrackGenerator.STRAIGHT_OPTIONS_M.size()
	for straightness in [0.0, 0.5, 1.0]:
		var a_rng := RandomNumberGenerator.new()
		a_rng.seed = 4242
		var b_rng := RandomNumberGenerator.new()
		b_rng.seed = 4242
		var a := TrackGenerator._candidates(corners, a_rng, straightness)
		var b := TrackGenerator._candidates(corners, b_rng, straightness)
		assert_eq(a.size(), expected, "every (corner, flip, straight) candidate is present")
		var seen: Dictionary = {}
		for i in a.size():
			var c: Dictionary = a[i]
			var id := "%d/%s/%f" % [c["corner_index"], c["flip"], c["straight"]]
			assert_false(seen.has(id), "candidate %s appears once" % id)
			seen[id] = true
			assert_eq(str(b[i]), str(c), "same seed -> same order at index %d" % i)
