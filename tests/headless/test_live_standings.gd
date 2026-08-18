extends GutTest
# LiveStandings (scripts/live_standings.gd): the pure maths behind the permanent in-run
# standings readout — where the player's projected finishing time slots into the rival
# field, and the gap that matters. No scene, no config: every input is a number handed in.
#
# All times here are SYNTHETIC (hand-built rival times, hand-built split tables), never a
# catalogue entry or an authored tunable — these tests pin the ranking/projection LOGIC,
# which must hold for any field and any pace table.


# --- time_frac_at -------------------------------------------------------------

func test_time_frac_interpolates_between_boundaries_from_zero() -> void:
	# One turn ending at 50% progress and 40% of the leader's time. Halfway to it, the
	# leader is halfway through that span: 20%. The implicit first point is (0, 0).
	var frac := LiveStandings.time_frac_at(0.25, [0.5], [0.4])
	assert_almost_eq(frac, 0.2, 0.0001, "interpolates linearly from the (0,0) origin")
	assert_almost_eq(LiveStandings.time_frac_at(0.5, [0.5], [0.4]), 0.4, 0.0001,
		"lands exactly on the boundary's own fraction")


func test_time_frac_holds_the_tail_past_the_last_boundary() -> void:
	# Progress beyond the final turn (the run-in to the finish) can't extrapolate; the
	# last known fraction is held rather than growing past 1.
	assert_almost_eq(LiveStandings.time_frac_at(0.99, [0.5, 0.8], [0.4, 0.9]), 0.9, 0.0001,
		"past the last boundary the tail fraction holds")


func test_time_frac_reports_no_table_rather_than_guessing() -> void:
	assert_eq(LiveStandings.time_frac_at(0.5, [], []), -1.0,
		"an empty table has no answer — a plain dev boot has no rival pace at all")


func test_time_frac_survives_two_boundaries_at_the_same_progress() -> void:
	# A degenerate span (a zero-length piece) must not divide by zero; the later time wins.
	var frac := LiveStandings.time_frac_at(0.5, [0.5, 0.5], [0.3, 0.6])
	assert_true(is_finite(frac), "a zero-length span yields a finite fraction")


# --- project_total_ms (the gap-carry projection) ------------------------------

func test_a_player_exactly_on_the_leaders_pace_projects_the_leaders_time() -> void:
	# Half the leader's time gone at the boundary where the leader had used half of theirs:
	# dead level, so the projection is the leader's total.
	var projected := LiveStandings.project_total_ms(50000, 0.5, [0.5], [0.5], 100000)
	assert_eq(projected, 100000, "level on the leader projects the leader's total")


func test_time_lost_so_far_is_carried_to_the_finish() -> void:
	# 5 s down at the halfway split -> projected 5 s down at the flag. Deliberately NOT
	# an average-pace extrapolation, which would double the deficit.
	var projected := LiveStandings.project_total_ms(55000, 0.5, [0.5], [0.5], 100000)
	assert_eq(projected, 105000, "the live deficit carries forward unchanged")
	var gained := LiveStandings.project_total_ms(45000, 0.5, [0.5], [0.5], 100000)
	assert_eq(gained, 95000, "time gained carries forward too")


func test_no_projection_without_a_leader_time_or_a_table() -> void:
	assert_eq(LiveStandings.project_total_ms(50000, 0.5, [0.5], [0.5], 0), -1,
		"no leader time, no projection")
	assert_eq(LiveStandings.project_total_ms(50000, 0.5, [], [], 100000), -1,
		"no pace table, no projection")


func test_a_projection_is_never_negative() -> void:
	# A nonsense input (elapsed far below the leader's split) must not produce a
	# negative finishing time for the ranking to sort on.
	assert_true(LiveStandings.project_total_ms(0, 0.9, [0.9], [0.9], 100000) >= 0,
		"the projection floors at zero")


# --- standing (position + the gap that matters) -------------------------------

func test_position_counts_the_rivals_who_are_faster_and_includes_the_player() -> void:
	var st := LiveStandings.standing(100000, [90000, 95000, 110000])
	assert_eq(int(st["position"]), 3, "two rivals projected ahead means P3")
	assert_eq(int(st["field"]), 4, "the field counts the player as well as the rivals")
	assert_false(bool(st["leading"]), "P3 is not leading")


func test_the_gap_shown_is_to_the_car_directly_ahead() -> void:
	var st := LiveStandings.standing(100000, [90000, 95000, 110000])
	assert_eq(int(st["gap_ms"]), 5000,
		"P3 chases P2's 95 s, not the leader's 90 s — the gap is to the next position up")
	assert_true(int(st["gap_ms"]) >= 0, "the time to find is never negative")


func test_leading_reports_the_cushion_back_to_second() -> void:
	var st := LiveStandings.standing(90000, [95000, 110000])
	assert_eq(int(st["position"]), 1, "faster than every rival means P1")
	assert_true(bool(st["leading"]), "leading is flagged so the readout can word it")
	assert_eq(int(st["gap_ms"]), 5000, "the gap is the cushion held over the next car")


func test_a_tie_goes_to_the_player() -> void:
	# A rival must be STRICTLY faster to be ahead. This is what puts a run on P1 at the
	# start line, where the projection is exactly the leader's time.
	var st := LiveStandings.standing(90000, [90000, 110000])
	assert_eq(int(st["position"]), 1, "level with the leader reads as leading, not P2")


func test_unclassified_rivals_are_not_positions_to_chase() -> void:
	# A negative time is a DNF/wreck: not classified, so it is neither a place the player
	# can be behind nor a car counted in the field.
	var st := LiveStandings.standing(100000, [90000, -1, -1])
	assert_eq(int(st["position"]), 2, "only the one classified rival is ahead")
	assert_eq(int(st["field"]), 2, "DNFs don't pad the field size")


func test_an_empty_field_leaves_nothing_to_compare_against() -> void:
	var st := LiveStandings.standing(100000, [])
	assert_eq(int(st["position"]), 1, "alone out there reads as P1")
	assert_eq(int(st["field"]), 1, "a field of one is just the player")
	assert_eq(int(st["gap_ms"]), 0, "no rival, no gap")


func test_an_underivable_projection_still_yields_a_usable_standing() -> void:
	# project_total_ms returns -1 before the pace table is wired; standing() must not
	# rank on that sentinel.
	var st := LiveStandings.standing(-1, [90000, 95000])
	assert_eq(int(st["position"]), 1, "no projection yet reads as P1 rather than last")
	assert_eq(int(st["gap_ms"]), 0, "and quotes no gap it can't compute")


func test_the_field_order_handed_in_does_not_matter() -> void:
	var sorted_st := LiveStandings.standing(100000, [90000, 95000, 110000])
	var jumbled := LiveStandings.standing(100000, [110000, 90000, 95000])
	assert_eq(int(jumbled["position"]), int(sorted_st["position"]),
		"the caller's ordering is irrelevant — standing() sorts its own copy")
	assert_eq(int(jumbled["gap_ms"]), int(sorted_st["gap_ms"]), "same gap either way")
