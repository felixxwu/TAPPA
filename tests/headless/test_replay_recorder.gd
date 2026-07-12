extends "res://tests/headless/sim_test.gd"

func _make_recorder() -> ReplayRecorder:
	var rec := ReplayRecorder.new()
	add_child_autofree(rec)
	rec.setup(_car)
	return rec

func test_records_frames_while_running() -> void:
	await setup_settled_car()
	var rec := _make_recorder()
	rec.start()
	assert_true(rec.recording, "recorder should be running after start()")
	_car.ai_controlled = true
	_car.ai_throttle = 1.0
	await _wait_physics(40)
	rec.stop()
	assert_false(rec.recording, "recorder stops on stop()")
	assert_gt(rec.frame_count(), 0, "should have captured frames")

func test_timestamps_are_monotonic() -> void:
	await setup_settled_car()
	var rec := _make_recorder()
	rec.start()
	_car.ai_controlled = true
	_car.ai_throttle = 1.0
	await _wait_physics(40)
	rec.stop()
	var last := -1.0
	for i in rec.frame_count():
		var f := rec.sample_at(rec.sample_at_index_t(i))
		assert_gt(f["t"], last, "frame t must strictly increase")
		last = f["t"]

func test_sample_interpolates_between_frames() -> void:
	await setup_settled_car()
	var rec := _make_recorder()
	# Hand-inject two frames so interpolation is deterministic (no physics).
	rec._push_test_frame(0.0, Vector3.ZERO)
	rec._push_test_frame(1.0, Vector3(10, 0, 0))
	var mid := rec.sample_at(0.5)
	assert_almost_eq(mid["xform"].origin.x, 5.0, 0.01, "origin lerps at t=0.5")

func test_empty_recording_is_noop() -> void:
	await setup_settled_car()
	var rec := _make_recorder()
	assert_eq(rec.frame_count(), 0)
	assert_eq(rec.sample_at(0.0), {}, "empty recorder returns {}")
