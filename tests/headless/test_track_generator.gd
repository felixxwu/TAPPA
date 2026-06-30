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


func _generate(seed_value: int, turns: int = 6, width: float = 6.0) -> Dictionary:
	return TrackGenerator.generate(START_POS, START_HEADING, seed_value, turns, width)


func test_generate_is_deterministic_per_seed() -> void:
	var a := _generate(7)
	var b := _generate(7)
	assert_eq(a["cells"].size(), b["cells"].size(), "same seed -> same number of cells")
	assert_eq(a["pieces"].size(), b["pieces"].size(), "same seed -> same number of pieces")


func test_generate_places_requested_corner_count() -> void:
	var r := _generate(3, 6)
	assert_eq(r["pieces"].size(), 6, "exactly the requested number of corners are placed")
	assert_true(r["complete"], "the search completed within the cap")


func test_generate_avoids_the_reserved_start_corridor() -> void:
	# Mimics the start-line lead-in: a straight corridor reserved BEHIND the start
	# (−heading). The search must not loop the track back across it.
	var width := 6.0
	var clearance := 8.0
	var reserve := 38.0  # ahead (22) + behind (16), as world.gd passes
	var r := TrackGenerator.generate(START_POS, START_HEADING, 7, 10, width, clearance, reserve)
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
	var a := TrackGenerator.generate(START_POS, START_HEADING, 7, 10, 6.0, 8.0, 38.0)
	var b := TrackGenerator.generate(START_POS, START_HEADING, 7, 10, 6.0, 8.0, 38.0)
	assert_eq(a["cells"].size(), b["cells"].size(), "same inputs + reserve -> same track")
	assert_eq(a["pieces"].size(), b["pieces"].size(), "deterministic piece count with a reservation")


func test_generate_starts_at_the_spawn_frame() -> void:
	var r := _generate(5)
	var curve: Curve2D = r["centerline"]
	assert_gt(curve.point_count, 1, "centerline has multiple points")
	assert_almost_eq(curve.get_point_position(0), START_POS, Vector2(1e-3, 1e-3),
		"centerline starts at the spawn position")


func test_generate_avoids_cell_overlap_between_pieces() -> void:
	# Each piece records the cells it added; those sets must be disjoint (the
	# search adds a cell to the occupied set only once, on the piece that claims
	# it), proving no later piece re-covers an earlier piece's cells.
	var r := _generate(11, 8)
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
	var a := TrackGenerator.generate(START_POS, START_HEADING, 11, 8, 6.0, 6.0)
	var b := TrackGenerator.generate(START_POS, START_HEADING, 11, 8, 6.0, 6.0)
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
	var r := _generate(2, 8)
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
		for piece in _generate(seed_value)["pieces"]:
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
		var a := TrackGenerator.generate(START_POS, START_HEADING, s, 10, 6.0, 0.0, 0.0, 0.0)
		var b := TrackGenerator.generate(START_POS, START_HEADING, s, 10, 6.0, 0.0, 0.0, 1.0)
		plain += _avg_gentleness(a, by_name)
		biased += _avg_gentleness(b, by_name)
	assert_gt(biased, plain,
		"straightness=1 yields gentler corners on average than straightness=0")


func test_straightness_generation_is_deterministic_and_complete() -> void:
	# A straightness-biased search is still seeded → identical run to run, and the bias
	# only reorders candidates so the track still completes.
	var a := TrackGenerator.generate(START_POS, START_HEADING, 7, 10, 6.0, 0.0, 0.0, 0.8)
	var b := TrackGenerator.generate(START_POS, START_HEADING, 7, 10, 6.0, 0.0, 0.0, 0.8)
	assert_eq(a["pieces"].size(), b["pieces"].size(), "same inputs + straightness -> same piece count")
	assert_eq(a["cells"].size(), b["cells"].size(), "same inputs + straightness -> same cells")
	assert_true(a["complete"], "a straightness-biased track still completes")


func test_every_rally_event_generates_a_complete_track_quickly() -> void:
	# Regression guard for the seed-3002 blow-up: rwd_masters event 2 once spent ~8
	# minutes (~474s) generating, because a boxed-in DFS ground its whole step budget
	# re-rasterizing every candidate's full footprint. After the fix (early-exit /
	# capsule collision + a tight per-attempt budget that bails a thrashing seed to a
	# fresh diverse restart), EVERY authored rally event must generate a COMPLETE track,
	# and the whole set must finish fast. The time bound is generous (the suite runs in
	# ~7s now) but still catches any regression back toward minutes.
	Config.reset()
	var clearance: float = Config.data.track_clearance
	var t0 := Time.get_ticks_msec()
	for rally in RallyLibrary.RALLIES:
		for event in rally["events"]:
			var r := TrackGenerator.generate(
				Vector2.ZERO, Vector2(0.0, -1.0), int(event.get("seed", 0)),
				int(event.get("turn_count", 10)), RallyLibrary.event_width(event), clearance,
				0.0, RallyLibrary.event_straightness(event))
			assert_true(r["complete"],
				"rally %s seed %d generates a complete track (no partial)" % [
					rally["id"], int(event.get("seed", 0))])
	assert_lt(Time.get_ticks_msec() - t0, 60000,
		"all rally tracks generate in well under a minute (one seed used to take ~8 min)")
