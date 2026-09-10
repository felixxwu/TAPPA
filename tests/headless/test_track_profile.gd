extends GutTest
# The track's VERTICAL channel (TrackProfile): the crest that turns the dead-straight
# "Jump" corner into a bump a fast car leaves the ground over.
#
# Everything here is LOGIC, not balance. The crest height and span are GameConfig
# tunables (jump_height_m / jump_span_m) and the authored Jump curve is catalogue data,
# so nothing below pins a chosen value — the tests assert the properties that must hold
# for ANY reasonable crest: it joins the road at grade, it is a no-op when absent, the
# plan tracks the Jump pieces, and launch_speed really is the speed at which gravity
# stops holding the car down.

const H := 2.5      # arbitrary non-default crest, to prove nothing keys off the config
const SPAN := 40.0

# One synthetic crest, so no test depends on a generated track or an authored value.
func _crest(center := 100.0, h := H, span := SPAN) -> Array:
	return [{"center_m": center, "height_m": h, "span_m": span}]


func test_crest_is_zero_outside_its_span() -> void:
	# The crest is self-contained: outside its own span it must contribute nothing at
	# all, or it would silently lift the neighbouring corners' road.
	var jumps := _crest()
	assert_eq(TrackProfile.offset_at(0.0, jumps), 0.0, "far before the crest")
	assert_eq(TrackProfile.offset_at(100.0 - SPAN, jumps), 0.0, "one span before the centre")
	assert_eq(TrackProfile.offset_at(100.0 + SPAN, jumps), 0.0, "one span past the centre")
	assert_eq(TrackProfile.offset_at(500.0, jumps), 0.0, "far after the crest")


func test_crest_peaks_at_its_centre() -> void:
	var jumps := _crest()
	assert_almost_eq(TrackProfile.offset_at(100.0, jumps), H, 1e-4, "apex is the full height")
	# Symmetric, and strictly below the apex either side of it.
	var before := TrackProfile.offset_at(90.0, jumps)
	var after := TrackProfile.offset_at(110.0, jumps)
	assert_almost_eq(before, after, 1e-4, "the crest is symmetric about its centre")
	assert_lt(before, H, "the shoulder sits below the apex")
	assert_gt(before, 0.0, "the shoulder is still raised")


func test_crest_joins_the_road_at_grade() -> void:
	# THE load-bearing property, and the reason the profile is a raised cosine rather
	# than anything simpler: the crest must reach zero in both VALUE and SLOPE at each
	# end. A non-zero slope there would put a visible kink — and a physics step — in the
	# road where the jump meets the ordinary terrain-following surface either side.
	var jumps := _crest()
	var eps := 0.01
	for end_s in [100.0 - SPAN / 2.0, 100.0 + SPAN / 2.0]:
		assert_almost_eq(TrackProfile.offset_at(end_s, jumps), 0.0, 1e-6,
			"height is zero at the crest end")
		var inside: float = TrackProfile.offset_at(
			end_s + (eps if end_s < 100.0 else -eps), jumps)
		# Slope = rise/run just inside the end. A cosine's is second-order small there,
		# so a genuine kink (a linear ramp, a parabola) would fail this by orders of
		# magnitude while the cosine passes comfortably.
		assert_lt(absf(inside) / eps, 1e-3, "slope is flat at the crest end (%s)" % end_s)


func test_an_absent_or_degenerate_crest_is_a_free_no_op() -> void:
	# Most stages draw no jump at all, and offset_at is called PER ROAD VERTEX, so the
	# empty case must be exactly zero rather than approximately so.
	assert_eq(TrackProfile.offset_at(100.0, []), 0.0, "no jumps at all")
	assert_eq(TrackProfile.offset_at(100.0, _crest(100.0, 0.0, SPAN)), 0.0, "zero height")
	assert_eq(TrackProfile.offset_at(100.0, _crest(100.0, H, 0.0)), 0.0, "zero span")


func test_multiple_crests_each_apply_at_their_own_centre() -> void:
	var jumps: Array = _crest(100.0) + _crest(400.0)
	assert_almost_eq(TrackProfile.offset_at(100.0, jumps), H, 1e-4, "first crest")
	assert_almost_eq(TrackProfile.offset_at(400.0, jumps), H, 1e-4, "second crest")
	assert_eq(TrackProfile.offset_at(250.0, jumps), 0.0, "the gap between them is flat")


# --- launch_speed: the physics contract, not a tuned number ------------------------

func test_launch_speed_is_the_speed_gravity_stops_holding_the_car_down() -> void:
	# launch_speed is a closed form, (span/PI) * sqrt(g / 2h). This test does NOT pin
	# that expression — it re-derives the threshold straight from the crest geometry the
	# terrain actually bakes: a car goes airborne when v^2 * kappa > g, so the honest
	# check is that launch_speed equals sqrt(g / kappa) for the apex curvature measured
	# numerically off offset_at. If the profile shape and the formula ever drift apart,
	# this fails — which is the whole point, since the shape is what the car drives on.
	var jumps := _crest()
	var eps := 0.05
	var second_derivative: float = (
		TrackProfile.offset_at(100.0 - eps, jumps)
		- 2.0 * TrackProfile.offset_at(100.0, jumps)
		+ TrackProfile.offset_at(100.0 + eps, jumps)
	) / (eps * eps)
	var kappa := absf(second_derivative)   # the road is near-flat at the apex, so y'' is the curvature
	assert_gt(kappa, 0.0, "the apex actually curves (else this test asserts nothing)")
	var expected := sqrt(TrackProfile.GRAVITY / kappa)
	assert_almost_eq(TrackProfile.launch_speed(H, SPAN), expected, expected * 0.01,
		"launch speed matches sqrt(g / apex curvature)")


func test_launch_speed_responds_to_shape_the_way_the_physics_demands() -> void:
	# Directional, not numeric — true for any reasonable crest. The second one is the
	# counter-intuitive half worth pinning: a LONGER crest of the same height is a
	# HARDER launch to trigger, because it is gentler, not bigger.
	assert_lt(TrackProfile.launch_speed(H * 2.0, SPAN), TrackProfile.launch_speed(H, SPAN),
		"a taller crest launches at a LOWER speed")
	assert_gt(TrackProfile.launch_speed(H, SPAN * 2.0), TrackProfile.launch_speed(H, SPAN),
		"a longer crest launches at a HIGHER speed")
	assert_eq(TrackProfile.launch_speed(0.0, SPAN), INF, "a flat crest never launches")
	assert_eq(TrackProfile.launch_speed(H, 0.0), INF, "a spanless crest never launches")


# --- plan: turning generated pieces into crests -----------------------------------

# A straight centerline long enough to hold the pieces below, so plan()'s
# get_closest_offset has something real to measure against.
func _straight_centerline(length := 600.0) -> Curve2D:
	var c := Curve2D.new()
	c.add_point(Vector2.ZERO)
	c.add_point(Vector2(0.0, length))
	return c


func _piece(corner: String, entry_y: float, straight := 0.0) -> Dictionary:
	return {
		"corner": corner,
		"entry_pos": Vector2(0.0, entry_y),
		"entry_heading": Vector2(0.0, 1.0),
		"straight": straight,
	}


func test_plan_emits_one_crest_per_jump_piece_and_none_for_other_corners() -> void:
	var pieces := [
		_piece("3", 0.0, 20.0),
		_piece(TrackProfile.CORNER_NAME, 100.0, 30.0),
		_piece("Hairpin", 250.0, 10.0),
		_piece(TrackProfile.CORNER_NAME, 350.0, 0.0),
	]
	var jumps := TrackProfile.plan(_straight_centerline(), pieces, H, SPAN)
	assert_eq(jumps.size(), 2, "only the Jump pieces produce a crest")
	# The crest sits inside its own piece: the corner starts after the connecting
	# straight, and the crest is centred half a piece further on.
	assert_almost_eq(float(jumps[0]["center_m"]),
		100.0 + 30.0 + TrackProfile.PIECE_LENGTH_M / 2.0, 1.0, "first crest centre")
	assert_almost_eq(float(jumps[1]["center_m"]),
		350.0 + TrackProfile.PIECE_LENGTH_M / 2.0, 1.0, "second crest centre")


func test_plan_clamps_the_span_inside_the_jump_piece() -> void:
	# The crest's zero-slope ends must land inside the Jump piece, or a mis-set config
	# knob would bleed the bump into the neighbouring corners' road grade.
	var pieces := [_piece(TrackProfile.CORNER_NAME, 100.0)]
	var jumps := TrackProfile.plan(_straight_centerline(), pieces,
		H, TrackProfile.PIECE_LENGTH_M * 10.0)
	assert_eq(jumps.size(), 1, "the jump is still planned")
	assert_almost_eq(float(jumps[0]["span_m"]), TrackProfile.PIECE_LENGTH_M, 1e-4,
		"an over-long span is clamped to the piece")


func test_plan_is_empty_when_there_is_nothing_to_raise() -> void:
	var pieces := [_piece(TrackProfile.CORNER_NAME, 100.0)]
	var line := _straight_centerline()
	assert_eq(TrackProfile.plan(line, pieces, 0.0, SPAN).size(), 0, "zero height plans nothing")
	assert_eq(TrackProfile.plan(line, pieces, H, 0.0).size(), 0, "zero span plans nothing")
	assert_eq(TrackProfile.plan(line, [_piece("3", 0.0)], H, SPAN).size(), 0, "no Jump piece")
	assert_eq(TrackProfile.plan(null, pieces, H, SPAN).size(), 0, "no centerline")
	assert_eq(TrackProfile.plan(Curve2D.new(), pieces, H, SPAN).size(), 0, "degenerate centerline")


# --- the name/geometry contract with the corner catalogue --------------------------

func test_corner_name_matches_a_real_authored_corner() -> void:
	# TrackGenerator's no-consecutive-jumps rule and TrackProfile.plan both key on this
	# NAME (deliberately — a jump's identity is its vertical profile, which its 2D curve
	# cannot express). The cost of a name-keyed rule is that a rename silently disables
	# it, so this is the guard that makes the rename fail loudly instead.
	var found := false
	for spec in CornerLibrary.CORNERS:
		if String(spec["name"]) == TrackProfile.CORNER_NAME:
			found = true
			break
	assert_true(found, "TrackProfile.CORNER_NAME '%s' is a real CornerLibrary corner"
		% TrackProfile.CORNER_NAME)


func test_piece_length_matches_the_authored_jump_curve() -> void:
	# plan() centres the crest at PIECE_LENGTH_M / 2 into the piece and clamps its span
	# to PIECE_LENGTH_M, both of which are only correct while this constant equals the
	# authored curve's real length. Re-author the curve without the constant and the
	# crest drifts off-centre — hence pinning the two together rather than the value.
	for spec in CornerLibrary.CORNERS:
		if String(spec["name"]) != TrackProfile.CORNER_NAME:
			continue
		var curve := CornerLibrary.build_curve(spec)
		assert_almost_eq(curve.get_baked_length(), TrackProfile.PIECE_LENGTH_M, 0.5,
			"PIECE_LENGTH_M tracks the authored Jump curve length")
		return
	fail_test("no '%s' corner in CornerLibrary" % TrackProfile.CORNER_NAME)
