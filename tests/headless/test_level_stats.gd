extends GutTest


func _mmi(root: Node3D, at: Vector3, count: int, visible_count: int, range_end: float) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = BoxMesh.new()
	mm.instance_count = count
	mm.visible_instance_count = visible_count
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.custom_aabb = AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))
	mmi.visibility_range_end = range_end
	mmi.position = at
	root.add_child(mmi)


func test_tally_counts_only_multimeshes_within_their_draw_range() -> void:
	var root: Node3D = add_child_autofree(Node3D.new())
	_mmi(root, Vector3(10, 0, 0), 8, 5, 50.0)
	_mmi(root, Vector3(0, 0, 30), 4, -1, 50.0)
	_mmi(root, Vector3(200, 0, 0), 9, 9, 50.0)
	var stats: LevelStats = add_child_autofree(LevelStats.new())
	var t := stats.tally(root, Vector3.ZERO)
	var box_tris := 12
	assert_eq(t, Vector3i(2, 9, 9 * box_tris), "the far one is out of range; -1 visible means every instance")


func test_cycle_steps_off_perf_adaptive_off() -> void:
	var stats: LevelStats = add_child_autofree(LevelStats.new())
	assert_false(stats.visible)
	stats.cycle()
	assert_eq(stats.page, LevelStats.Page.PERF)
	assert_true(stats.visible)
	stats.cycle()
	assert_eq(stats.page, LevelStats.Page.ADAPTIVE)
	assert_true(stats.visible)
	stats.cycle()
	assert_false(stats.visible)


func test_adaptive_text_lists_every_setting_and_the_floor() -> void:
	var c := AdaptiveController.new()
	for id in ["alpha", "beta"]:
		var k := AdaptiveKnob.new()
		k.id = StringName(id)
		k.name = id.capitalize()
		k.levels = 3
		c.knobs.append(k)
	c.at_floor = true
	var text := LevelStats.adaptive_text(c, 16.7, 2)
	assert_string_contains(text, "Alpha")
	assert_string_contains(text, "Beta")
	assert_string_contains(text, "at floor")
	assert_string_contains(LevelStats.adaptive_text(null, 16.7, 0), "not running")


func test_frame_line_averages_the_frames_and_reports_the_slowest() -> void:
	assert_eq(LevelStats.frame_line(PackedFloat32Array([10.0, 10.0, 40.0])), "50 fps  avg 20.0 ms  worst 40.0 ms")


func test_threads_line_says_whether_threads_are_on() -> void:
	assert_eq(LevelStats.threads_line(false, 3), "threads off")
	assert_string_contains(LevelStats.threads_line(true, 3), "3")
