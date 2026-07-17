extends GutTest
# MusicDirector scheduling logic, exercised WITHOUT real audio: we construct the
# node with `.new()` (never add it to the tree, so _ready/audio never runs) and
# drive advance()/seed() with synthetic `now` values and an injected bpm table.


func _make() -> MusicDirector:
	var md: MusicDirector = autofree(MusicDirector.new())
	md._bpm_override = {"a": 170.0, "b": 160.0}  # b is slower -> longer lead-in
	md._segment_count_override = {"a": 4, "b": 4}  # 4 segments per song
	return md


# Fire once at exactly the next handoff's boundary and return the fire dict.
func _fire_once(md: MusicDirector) -> Dictionary:
	var t := MusicSchedule.fire_start(md.next_handoff, md._bpm_for(md.requested_song))
	return md.advance(t)


func test_idle_director_never_fires() -> void:
	var md := _make()
	assert_eq(md.current_song, "", "starts idle")
	assert_eq(md.advance(123.0), {}, "idle -> no fire")


func test_seed_starts_segment_zero_and_sets_first_handoff() -> void:
	var md := _make()
	md.seed_grid(5.0, "a")
	assert_eq(md.current_song, "a")
	assert_eq(md.current_segment, 0, "seeds at segment 0")
	assert_almost_eq(md.next_handoff, MusicSchedule.seed_handoff(5.0, 170.0), 0.0001)


func test_segments_play_in_order_and_wrap_after_the_last() -> void:
	var md := _make()
	md.seed_grid(0.0, "a")  # segment 0 sounding
	var body := MusicSchedule.loop_body_sec(170.0)
	# Four handoffs advance 0 -> 1 -> 2 -> 3 -> back to 0 (same song, no request change),
	# each one 8-bar loop body apart.
	var expected := [1, 2, 3, 0]
	for i in expected.size():
		var handoff_before := md.next_handoff
		var fire := _fire_once(md)
		assert_eq(fire["song"], "a", "stays on song a")
		assert_eq(fire["segment"], expected[i], "segment step %d in the sequence" % i)
		assert_almost_eq(md.next_handoff - handoff_before, body, 0.0001,
			"each segment is one 8-bar loop body apart")


func test_song_change_interrupts_the_sequence_at_segment_zero() -> void:
	var md := _make()
	md.seed_grid(0.0, "a")
	# Advance a couple of segments so we're mid-sequence (on segment 2).
	_fire_once(md)
	_fire_once(md)
	assert_eq(md.current_segment, 2, "mid-sequence on segment 2")
	# Request a different song mid-loop.
	md.requested_song = "b"
	var fire_time := MusicSchedule.fire_start(md.next_handoff, 160.0)  # incoming bpm sets offset
	assert_eq(md.advance(fire_time - 0.01), {}, "swap does not apply mid-loop")
	assert_eq(md.current_song, "a", "still on the old song until the handoff")
	var fire := md.advance(fire_time)
	assert_eq(fire["song"], "b", "swap applies at the handoff")
	assert_eq(fire["segment"], 0, "new song starts at segment 0, interrupting 1-2-3-4")
	assert_eq(md.current_song, "b", "current song updated at the handoff")
	assert_eq(md.current_segment, 0, "current segment reset to 0")


func test_fire_offset_is_within_the_lead_in() -> void:
	var md := _make()
	md.seed_grid(0.0, "a")
	var fire_time := md.next_handoff - MusicSchedule.lead_in_sec(170.0) + 0.03  # 30 ms late
	var fire := md.advance(fire_time)
	assert_almost_eq(fire["from_offset"], 0.03, 0.0001, "late-comp == lateness")


func test_set_volume_clamps_to_unit_range() -> void:
	var md := _make()
	var prev_disabled: bool = Save.save_disabled
	Save.save_disabled = true
	md.set_volume(1.5)
	assert_almost_eq(float(Save.get_setting(MusicDirector.SETTING_KEY, -1.0)), 1.0, 0.0001,
		"clamps above 1")
	md.set_volume(-0.5)
	assert_almost_eq(float(Save.get_setting(MusicDirector.SETTING_KEY, -1.0)), 0.0, 0.0001,
		"clamps below 0")
	Save.save_disabled = prev_disabled


func test_set_volume_persists_the_chosen_value() -> void:
	var md := _make()
	var prev_disabled: bool = Save.save_disabled
	Save.save_disabled = true
	md.set_volume(0.42)
	assert_almost_eq(float(Save.get_setting(MusicDirector.SETTING_KEY, -1.0)), 0.42, 0.0001,
		"round-trips through Save")
	Save.save_disabled = prev_disabled


func test_set_volume_can_skip_persistence() -> void:
	var md := _make()
	var prev_disabled: bool = Save.save_disabled
	Save.save_disabled = true
	Save.set_setting(MusicDirector.SETTING_KEY, 0.33)
	md.set_volume(0.9, false)  # apply live but do not persist
	assert_almost_eq(float(Save.get_setting(MusicDirector.SETTING_KEY, -1.0)), 0.33, 0.0001,
		"persist=false leaves the saved value untouched")
	Save.save_disabled = prev_disabled


func test_scene_state_seeds_hq_song_then_latches_run_song() -> void:
	var md: MusicDirector = autofree(MusicDirector.new())  # not in tree: no audio, no _ready
	# Entering the HQ scene from idle seeds + starts the HQ song immediately.
	md.update_for_scene(MusicLibrary.HQ_SCENE)
	assert_eq(md.current_song, MusicLibrary.HQ_SONG, "HQ scene -> HQ song, seeded now")
	assert_eq(md.requested_song, MusicLibrary.HQ_SONG, "requested is the HQ song")
	# Moving to any non-HQ scene queues the run song WITHOUT swapping mid-loop.
	md.update_for_scene("res://main.tscn")
	assert_eq(md.requested_song, MusicLibrary.RUN_SONG, "non-HQ scene queues the run song")
	assert_eq(md.current_song, MusicLibrary.HQ_SONG, "swap is latched, not applied until the handoff")
	# Returning to the HQ scene queues the HQ song again.
	md.update_for_scene(MusicLibrary.HQ_SCENE)
	assert_eq(md.requested_song, MusicLibrary.HQ_SONG, "back in HQ -> HQ song queued again")


func test_catch_up_after_a_stall_still_fires_aligned() -> void:
	var md := _make()
	md.seed_grid(0.0, "a")
	# Simulate a big stall: jump well past several handoffs.
	var stalled_now := md.next_handoff + MusicSchedule.loop_body_sec(170.0) * 3.0
	var fire := md.advance(stalled_now)
	# It may or may not fire on this exact frame, but the grid must be re-aligned
	# so the offset (if it fired) is a valid lead-in skip, and the next fire is in
	# the future.
	if not fire.is_empty():
		assert_lt(fire["from_offset"], MusicSchedule.lead_in_sec(170.0),
			"offset stays inside the lead-in after catch-up")
	assert_gt(md.next_handoff, stalled_now - MusicSchedule.loop_body_sec(170.0),
		"handoff re-aligned near/after now")
