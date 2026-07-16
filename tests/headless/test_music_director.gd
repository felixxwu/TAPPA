extends GutTest
# MusicDirector scheduling logic, exercised WITHOUT real audio: we construct the
# node with `.new()` (never add it to the tree, so _ready/audio never runs) and
# drive advance()/seed() with synthetic `now` values and an injected bpm table.


func _make() -> MusicDirector:
	var md: MusicDirector = autofree(MusicDirector.new())
	md._bpm_override = {"a": 170.0, "b": 160.0}  # b is slower -> longer lead-in
	return md


func test_idle_director_never_fires() -> void:
	var md := _make()
	assert_eq(md.current_id, "", "starts idle")
	assert_eq(md.advance(123.0), {}, "idle -> no fire")


func test_seed_sets_current_and_first_handoff() -> void:
	var md := _make()
	md.seed_grid(5.0, "a")
	assert_eq(md.current_id, "a")
	assert_almost_eq(md.next_handoff, MusicSchedule.seed_handoff(5.0, 170.0), 0.0001)


func test_self_loop_refires_one_loop_body_apart() -> void:
	var md := _make()
	md.seed_grid(0.0, "a")
	var body := MusicSchedule.loop_body_sec(170.0)
	var lead := MusicSchedule.lead_in_sec(170.0)
	# First re-trigger fires at fire_start = next_handoff - lead_in.
	var first_fire_time := md.next_handoff - lead
	assert_eq(md.advance(first_fire_time - 0.01), {}, "not yet")
	var fire := md.advance(first_fire_time)
	assert_false(fire.is_empty(), "fires at the boundary")
	assert_eq(fire["song_id"], "a", "self-loops the same song")
	# Next fire is exactly one loop body later.
	var second_fire_time := md.next_handoff - lead
	assert_almost_eq(second_fire_time - first_fire_time, body, 0.0001,
		"re-trigger interval == one loop body")


func test_swap_is_latched_until_the_next_handoff() -> void:
	var md := _make()
	md.seed_grid(0.0, "a")
	md.requested_id = "b"  # request a swap mid-loop
	var fire_time := md.next_handoff - MusicSchedule.lead_in_sec(160.0)  # incoming bpm sets offset
	assert_eq(md.advance(fire_time - 0.01), {}, "swap does not apply mid-loop")
	assert_eq(md.current_id, "a", "still playing the old song until the handoff")
	var fire := md.advance(fire_time)
	assert_eq(fire["song_id"], "b", "swap applies at the handoff")
	assert_eq(md.current_id, "b", "current updated at the handoff")


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
	assert_eq(md.current_id, MusicLibrary.HQ_SONG, "HQ scene -> HQ song, seeded now")
	assert_eq(md.requested_id, MusicLibrary.HQ_SONG, "requested is the HQ song")
	# Moving to any non-HQ scene queues the run song WITHOUT swapping mid-loop.
	md.update_for_scene("res://main.tscn")
	assert_eq(md.requested_id, MusicLibrary.RUN_SONG, "non-HQ scene queues the run song")
	assert_eq(md.current_id, MusicLibrary.HQ_SONG, "swap is latched, not applied until the handoff")
	# Returning to the HQ scene queues the HQ song again.
	md.update_for_scene(MusicLibrary.HQ_SCENE)
	assert_eq(md.requested_id, MusicLibrary.HQ_SONG, "back in HQ -> HQ song queued again")


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
