extends GutTest
# MusicSchedule is pure timing math for the loop scheduler. Tests assert
# RELATIONSHIPS that hold for any bpm — never a specific second-count or bpm.


func test_lead_in_and_loop_body_are_in_the_authored_bar_ratio() -> void:
	# lead-in is 8 bars, main loop is 32 bars -> loop body is exactly 4x lead-in,
	# for ANY bpm.
	for bpm in [120.0, 160.0, 174.0]:
		assert_almost_eq(
			MusicSchedule.loop_body_sec(bpm),
			MusicSchedule.lead_in_sec(bpm) * 4.0,
			0.0001,
			"loop body == 4x lead-in at %s bpm" % bpm)


func test_faster_incoming_song_fires_later() -> void:
	# The core tempo-change correction: a faster incoming song has a shorter
	# lead-in, so it must START LATER for the same handoff.
	var handoff := 100.0
	var slow := MusicSchedule.fire_start(handoff, 160.0)
	var fast := MusicSchedule.fire_start(handoff, 170.0)
	assert_gt(fast, slow, "faster incoming bpm -> later fire_start")


func test_advance_handoff_is_constant_interval_for_same_bpm() -> void:
	var bpm := 170.0
	var h0 := 50.0
	var h1 := MusicSchedule.advance_handoff(h0, bpm)
	var h2 := MusicSchedule.advance_handoff(h1, bpm)
	assert_almost_eq(h1 - h0, h2 - h1, 0.0001, "same-bpm interval is constant")
	assert_almost_eq(h1 - h0, MusicSchedule.loop_body_sec(bpm), 0.0001,
		"interval == one loop body")


func test_seed_handoff_places_first_handoff_after_lead_in_plus_loop_body() -> void:
	var bpm := 170.0
	var play_now := 3.0
	var expected := play_now + MusicSchedule.lead_in_sec(bpm) + MusicSchedule.loop_body_sec(bpm)
	assert_almost_eq(MusicSchedule.seed_handoff(play_now, bpm), expected, 0.0001)


func test_late_by_clamps_into_the_lead_in_window() -> void:
	var bpm := 170.0
	var start := 10.0
	# On time -> zero.
	assert_almost_eq(MusicSchedule.late_by(start, start, bpm), 0.0, 0.0001)
	# Slightly late -> the actual lateness.
	assert_almost_eq(MusicSchedule.late_by(start + 0.02, start, bpm), 0.02, 0.0001)
	# Never negative.
	assert_almost_eq(MusicSchedule.late_by(start - 5.0, start, bpm), 0.0, 0.0001)
	# Never past the lead-in (would skip into the main loop).
	assert_lt(MusicSchedule.late_by(start + 999.0, start, bpm),
		MusicSchedule.lead_in_sec(bpm), "clamped below lead-in length")


func test_catch_up_advances_past_an_overshot_handoff() -> void:
	var bpm := 170.0
	var handoff := 10.0
	var now := 10.0 + MusicSchedule.loop_body_sec(bpm) * 2.5  # blew past ~2 handoffs
	var fixed := MusicSchedule.catch_up(handoff, now, bpm)
	# fire_start must now be at most one lead-in in the past, so clamped late-comp
	# stays valid.
	var fs := MusicSchedule.fire_start(fixed, bpm)
	assert_lte(now - fs, MusicSchedule.lead_in_sec(bpm) + 0.0001,
		"catch_up keeps late within the lead-in window")


func test_catch_up_is_a_noop_before_the_handoff() -> void:
	var bpm := 170.0
	var handoff := 100.0
	var now := 60.0  # still before the handoff
	assert_almost_eq(MusicSchedule.catch_up(handoff, now, bpm), handoff, 0.0001)
