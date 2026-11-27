extends GutTest
# The live setters adaptive graphics drives (features/adaptive-graphics.md): each changes the running
# game at once, with no scene reload. Plus the frame sampler and PerfLog's per-frame totals.


class StubPool:
	extends CpuParticlePool

	func build(count: int) -> void:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = QuadMesh.new()
		mm.instance_count = count
		multimesh = mm
		_alloc_pool(count)
		_clear()

	func _hide_slot(i: int) -> void:
		_buffer[i * 12 + 7] = HIDE_Y


func before_each() -> void:
	Config.reset()


func after_each() -> void:
	Config.reset()
	PerfLog.clear_frame()


func test_particle_quality_limits_and_clears_the_pool() -> void:
	var pool: StubPool = add_child_autofree(StubPool.new())
	pool.build(8)
	for i in 8:
		pool._emit_slot(Vector3.ZERO, Vector3.ZERO, 1.0)
	pool.set_quality(0.5)
	assert_eq(pool.multimesh.visible_instance_count, 4)
	assert_eq(pool.live_count(), 4, "particles past the limit are gone")
	for i in 8:
		pool._emit_slot(Vector3.ZERO, Vector3.ZERO, 1.0)
	assert_lt(pool._next, 4, "new particles stay within the limit")
	pool.set_quality(0.0)
	assert_eq(pool.multimesh.visible_instance_count, 0, "0 draws none")
	pool.set_quality(1.0)
	assert_eq(pool.multimesh.visible_instance_count, -1, "1 draws the whole pool again")


func test_cover_reach_changes_built_tiles_and_both_fades() -> void:
	var gc: GroundCover = add_child_autofree(GroundCover.new())
	gc.material = GroundCover.make_material(10.0, 20.0)
	gc.far_material = GroundCover.make_material(10.0, 20.0, Vector2(30.0, 40.0))
	var tile := Node3D.new()
	gc.add_child(tile)
	gc.tiles[Vector2i.ZERO] = tile
	var near := MultiMeshInstance3D.new()
	near.material_override = gc.material
	var far := MultiMeshInstance3D.new()
	far.material_override = gc.far_material
	tile.add_child(near)
	tile.add_child(far)
	Config.data.ground_cover_reach = 33.0
	Config.data.ground_cover_fade_start = 11.0
	Config.data.ground_cover_fade_end = 22.0
	Config.data.ground_cover_far_reach = 44.0
	gc.refresh_reach()
	assert_almost_eq(near.visibility_range_end, 33.0 + GroundCover.TILE * 0.71, 0.01)
	assert_almost_eq(far.visibility_range_end, 44.0 + GroundCover.TILE * 0.71, 0.01)
	for mat in [gc.material, gc.far_material]:
		assert_eq(mat.get_shader_parameter("fade"), Vector2(11.0, 22.0), "near fade reaches both layers")


func test_tree_draw_distance_changes_built_tiles() -> void:
	var trees := LevelTrees.new()
	add_child_autofree(trees)
	var mat := ShaderMaterial.new()
	trees._materials["x"] = mat
	Config.data.level_tree_draw_m = 123.0
	trees.refresh_draw()
	assert_eq(float(mat.get_shader_parameter("draw_end_m")), 123.0)


func test_frame_cost_leaves_out_loading_work() -> void:
	assert_eq(FrameSampler.cost_of(10.0, 4.0), 6.0)
	assert_eq(FrameSampler.cost_of(2.0, 4.0), 0.0)


func test_budget_follows_the_fps_cap_or_sixty() -> void:
	var cap := FpsSetting.resolve()
	assert_almost_eq(FrameSampler.budget_ms(), 1000.0 / float(cap if cap > 0 else 60), 0.001)


func test_perf_log_frame_totals_clear() -> void:
	PerfLog.clear_frame()
	PerfLog.track(&"unit_frame", 300)
	PerfLog.track(&"unit_frame", 200)
	assert_eq(PerfLog.frame_us(&"unit_frame"), 500)
	PerfLog.clear_frame()
	assert_eq(PerfLog.frame_us(&"unit_frame"), 0)
