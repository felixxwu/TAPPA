extends GutTest
# LevelStreamer: ground streamed from a baked synthetic level, with collision under the car and a wall at the square's edge.

const SIZE := 200.0

var _streamer: LevelStreamer
var _data: LevelData
var _bake: LevelBake
var _car: RigidBody3D


func before_all() -> void:
	var hm: Array = []
	hm.resize(101 * 101)
	hm.fill(0.0)
	_data = LevelData.new()
	# biomeRle: the north half (z < 0) snow, the south half forest, on the 20 x 20 grid of 10 m cells
	_data.load_save({"size": SIZE, "heightmap": hm, "biomeRle": "AcgBAMgB", "road": [
		{"x": -80.0, "z": 0.0, "w": 3.0, "m": null, "tension": 1.0}, {"x": 80.0, "z": 0.0, "w": 3.0, "m": null, "tension": 1.0}]})
	_bake = LevelBake.bake(_data)
	_streamer = LevelStreamer.new()
	_streamer.setup(_data, _bake, ShaderMaterial.new())
	add_child(_streamer)
	_car = RigidBody3D.new()
	_car.freeze = true
	add_child(_car)
	_car.global_position = Vector3(0.0, 1.0, 0.0)
	_streamer.focus = _car
	_streamer.prefill()


func after_all() -> void:
	_streamer.free()
	_car.free()


func test_collision_is_built_under_the_spawn() -> void:
	var q := PhysicsRayQueryParameters3D.create(Vector3(0.0, 20.0, 0.0), Vector3(0.0, -20.0, 0.0))
	await wait_physics_frames(2)
	var space := _streamer.get_world_3d().direct_space_state
	assert_false(space.intersect_ray(q).is_empty())


func test_height_at_matches_the_bake_at_a_grid_point() -> void:
	for p in [Vector2(0.0, 0.0), Vector2(30.0, 40.5), Vector2(-60.0, -15.0)]:
		assert_almost_eq(_streamer.height_at(p.x, p.y), _bake.height(p.x, p.y), 0.05)


func test_surface_is_road_on_the_road_and_not_in_the_field() -> void:
	assert_gt(_streamer.surface_at(0.0, 0.0).x, 0.5)
	assert_lt(_streamer.surface_at(0.0, 40.0).x, 0.5)


func test_an_edge_wall_surrounds_the_square() -> void:
	var wall := _streamer.get_node("EdgeWall") as StaticBody3D
	assert_not_null(wall)
	await wait_physics_frames(2)
	var space := _streamer.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(Vector3(SIZE, 5.0, 0.0), Vector3(0.0, 5.0, 0.0))
	assert_false(space.intersect_ray(q).is_empty(), "a ray crossing the edge hits the wall")


func test_vertex_alpha_carries_how_upright_the_ground_is() -> void:
	var job := LevelStreamer.ChunkJob.new()
	job.colors = PackedColorArray([Color(), Color()])
	job.uvs = PackedVector2Array([Vector2(), Vector2()])
	_streamer._begin_pack(job)
	_streamer._pack_vertex(job, 0, 0.0, 0.0, Vector3.UP)
	_streamer._pack_vertex(job, 1, 0.0, 0.0, Vector3(1.0, 1.0, 0.0).normalized())
	assert_almost_eq(job.colors[0].a, 1.0, 0.001)
	assert_lt(job.colors[1].a, job.colors[0].a, "a slope packs a smaller alpha, so the shader can draw it as rock")


func test_snow_follows_the_biome_mask_and_blends_across_its_edge() -> void:
	assert_almost_eq(_streamer.snow_at(0.0, -50.0), 1.0, 0.001)
	assert_almost_eq(_streamer.snow_at(0.0, 50.0), 0.0, 0.001)
	var edge := _streamer.snow_at(0.0, 0.0)
	assert_true(edge > 0.0 and edge < 1.0, "the 10 m cells blend rather than step")


func test_snowy_ground_is_drawn_white_and_raised_off_the_road_only() -> void:
	var job := LevelStreamer.ChunkJob.new()
	job.colors = PackedColorArray([Color(), Color(), Color()])
	job.uvs = PackedVector2Array([Vector2(), Vector2(), Vector2()])
	_streamer._begin_pack(job)
	_streamer._pack_vertex(job, 0, 0.0, -50.0, Vector3.UP)
	_streamer._pack_vertex(job, 1, 0.0, 0.0, Vector3.UP)
	_streamer._pack_vertex(job, 2, 0.0, 50.0, Vector3.UP)
	assert_almost_eq(job.uvs[0].x, 1.0, 0.001, "snow off the road")
	assert_gt(job.uvs[0].y, 0.0, "snow off the road is drawn raised")
	assert_almost_eq(job.uvs[1].y, 0.0, 0.001, "the road itself is never raised")
	assert_eq(job.uvs[2], Vector2.ZERO, "forest is neither white nor raised")


func test_cover_sits_on_the_baked_ground_even_where_only_coarse_terrain_is_loaded() -> void:
	var p := Vector2(90.0, 90.0)
	assert_eq(_streamer.cover.height_fn.call(p.x, p.y), _bake.height(p.x, p.y))


func _prepped_job(streamer: LevelStreamer, coord := Vector2i.ZERO) -> LevelStreamer.ChunkJob:
	var job := streamer._new_job(coord, LevelStreamer.Level.MID, false)
	streamer._queue.erase(job)
	streamer._prep(job)
	return job


func _fresh_streamer() -> LevelStreamer:
	var s := LevelStreamer.new()
	s.setup(_data, _bake, ShaderMaterial.new())
	add_child(s)
	return s


func test_a_threaded_build_matches_the_same_build_on_the_main_thread() -> void:
	var a := _prepped_job(_streamer)
	var b := _prepped_job(_streamer)
	_streamer._begin_pack(a)
	_streamer._build_job(a)
	_streamer._dispatch_build(b)
	assert_eq(_streamer._inflight.size(), 1)
	_streamer._collect_build(b)
	assert_eq(_streamer._inflight.size(), 0)
	assert_eq(b.stage, LevelStreamer.Stage.UPLOAD)
	assert_eq(b.verts, a.verts)
	assert_eq(b.colors, a.colors)
	assert_eq(b.uvs, a.uvs)
	assert_eq(b.uv2s, a.uv2s)


func test_a_cancelled_build_is_dropped_and_never_attached() -> void:
	var job := _prepped_job(_streamer)
	_streamer._dispatch_build(job)
	job.cancelled = true
	_streamer._collect_build(job)
	assert_eq(_streamer._inflight.size(), 0)
	assert_eq(job.stage, LevelStreamer.Stage.DONE)
	assert_null(job.mesh)


func test_freeing_a_streamer_with_builds_in_flight_is_safe() -> void:
	var s := _fresh_streamer()
	for x in 3:
		s._dispatch_build(_prepped_job(s, Vector2i(x, 0)))
	remove_child(s)
	s.free()
	assert_true(true, "no crash waiting on the workers")


func test_with_threaded_building_off_nothing_is_dispatched_and_the_ground_still_builds() -> void:
	var was := Config.data.threaded_chunk_build
	Config.data.threaded_chunk_build = false
	var s := _fresh_streamer()
	var car := RigidBody3D.new()
	car.freeze = true
	add_child(car)
	car.global_position = Vector3(0.0, 1.0, 0.0)
	s.focus = car
	s.prefill()
	Config.data.threaded_chunk_build = was
	assert_eq(s._inflight.size(), 0)
	assert_true(s.has_collision_at(0.0, 0.0), "built synchronously")
	s.free()
	car.free()


func test_tiles_ahead_of_a_fast_car_are_wanted_before_they_are_in_reach() -> void:
	var here := Vector2.ZERO
	var wanted := _streamer.wanted_near_tiles(here, Vector2(40.0, 0.0))
	var ahead := _streamer._tile_of(Vector2(LevelStreamer.NEAR_REACH_M + 30.0, 0.0))
	var behind := _streamer._tile_of(Vector2(-LevelStreamer.NEAR_REACH_M - 30.0, 0.0))
	assert_true(wanted.has(ahead), "the road ahead past the near reach is queued")
	assert_lt(float(wanted[ahead]), Config.data.adaptive_near_lead_s, "with a time until the car gets there")
	assert_false(wanted.has(behind), "the road behind past the reach is not")
	assert_eq(float(wanted[_streamer._tile_of(here)]), 0.0, "the tile under the car is due now")


func test_a_tile_on_the_path_that_cannot_be_built_in_time_is_overdue() -> void:
	var job := LevelStreamer.ChunkJob.new()
	job.tile = true
	job.eta_s = 0.0
	_streamer._queue.append(job)
	_streamer._plan_us = Time.get_ticks_usec()
	assert_true(_streamer.near_overdue())
	job.cancelled = true
	assert_false(_streamer.near_overdue(), "a cancelled one is not waited for")
	_streamer._queue.erase(job)


func test_rolling_onto_a_tile_without_full_detail_counts_a_miss() -> void:
	var before := _streamer.stat_near_misses
	_streamer._miss_tile = Vector2i(1 << 20, 0)
	_streamer._count_near_miss()
	assert_eq(_streamer.stat_near_misses, before, "the spawn's tile was built by the prefill")
	_streamer._tiles.erase(_streamer._tile_of(Vector2.ZERO))
	_streamer._miss_tile = Vector2i(1 << 20, 0)
	_streamer._count_near_miss()
	assert_eq(_streamer.stat_near_misses, before + 1)
	_streamer.prefill()


func test_shrinking_the_rings_frees_detail_at_once() -> void:
	var mid0 := _streamer.settings.mid_radius
	var far0 := _streamer.settings.far_radius
	var before := _streamer.chunk_counts()
	_streamer.apply_rings(0.0, 0)
	assert_lt(_streamer.chunk_counts().x, before.x, "mid meshes outside the smaller ring are gone without the car moving")
	_streamer.apply_rings(mid0, far0)
	_streamer.prefill()


# A streamer with small rings round a plain Node3D focus at the origin, for the scheduler tests below.
func _small(horizon_m := 0.0) -> LevelStreamer:
	var st := LevelStreamer.new()
	st.setup(_data, _bake, ShaderMaterial.new())
	st.settings.mid_radius = 1
	st.settings.far_radius = 3
	st.settings.horizon_radius_m = horizon_m
	add_child_autofree(st)
	var focus := Node3D.new()
	add_child_autofree(focus)
	st.focus = focus
	return st


func _has_collision(st: LevelStreamer, c: Vector2i) -> bool:
	for t in st._tiles_of_chunk(c):
		var ts: LevelStreamer.TileState = st._tiles.get(t)
		if ts == null or ts.body == null:
			return false
	return true


func _chunk_d(st: LevelStreamer, coord: Vector2i, p: Vector2) -> float:
	var cm := st.settings.chunk_m
	return ((Vector2(coord) + Vector2(0.5, 0.5)) * cm).distance_to(p) / cm


func test_cutting_a_hole_in_a_coarse_mesh_leaves_its_stored_arrays_alone() -> void:
	var st := _small()
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	for z in 3:
		for x in 3:
			verts.append(Vector3(x, 0.0, z))
			colors.append(Color.WHITE)
			uvs.append(Vector2.ZERO)
			uv2s.append(Vector2.ZERO)
	st._coarse_mesh([verts, colors, uvs, uv2s], 3, 1, 2, 1, 1.0)
	assert_eq(verts.size(), 9, "skirt vertices belong to the new mesh alone")


func test_a_frame_with_no_budget_left_advances_a_job_by_one_unit_only() -> void:
	var was := Config.data.threaded_chunk_build
	Config.data.threaded_chunk_build = false
	var st := _small()
	st._plan()
	var job: LevelStreamer.ChunkJob = st._queue[0]
	assert_eq(job.stage, LevelStreamer.Stage.PREP)
	st._run_queue(Time.get_ticks_usec())
	assert_eq(job.stage, LevelStreamer.Stage.HEIGHTS, "the first unit of a frame always runs")
	assert_eq(job.cursor, 0, "nothing beyond that one unit")
	st._run_queue(Time.get_ticks_usec())
	Config.data.threaded_chunk_build = was
	assert_eq(job.cursor, 1, "an exhausted frame computes a single height sample")


func test_height_queries_on_a_loaded_tile_read_the_drawn_surface() -> void:
	var st := _small()
	var s := st.settings
	st.prefill()
	var ts: LevelStreamer.TileState = st._tiles[Vector2i.ZERO]
	assert_false(ts.near_heights.is_empty())
	var m := int(s.near_tile_m / s.near_stride_m) + 3
	for g: Vector2i in [Vector2i(0, 0), Vector2i(5, 7), Vector2i(12, 3)]:
		var expected: float = ts.near_heights[(g.y + 1) * m + g.x + 1]
		assert_almost_eq(st.height_at(g.x * s.near_stride_m, g.y * s.near_stride_m), expected, 0.0001)
	assert_almost_eq(st.height_at(13.3, 21.7), _bake.height(13.3, 21.7), 1.0)


func test_the_near_tiles_are_exactly_those_within_the_reach_of_the_car() -> void:
	var st := _small()
	var tm := st.settings.near_tile_m
	for p: Vector2 in [Vector2(0.3, 0.2) * tm, Vector2(-1.4, 2.6) * tm, Vector2(5.5, -3.49) * tm]:
		var got := st.near_tiles_of(p)
		assert_true(got.has(st._tile_of(p)), "the car's own tile")
		for tz in range(-12, 12):
			for tx in range(-12, 12):
				var t := st._tile_of(p) + Vector2i(tx, tz)
				assert_eq(got.has(t), st._tile_gap(t, p) <= LevelStreamer.NEAR_REACH_M, "tile %s" % t)


func test_near_detail_covers_only_its_tiles_and_the_coarse_mesh_leaves_a_hole_there() -> void:
	var st := _small()
	st.prefill()
	var block := st.near_tiles_of(Vector2.ZERO)
	for t: Vector2i in st._tiles:
		var ts: LevelStreamer.TileState = st._tiles[t]
		assert_eq(ts.near_mesh != null, block.has(t), "tile %s near mesh only in the block" % t)
		if ts.near_mesh == null:
			continue
		var cs: LevelStreamer.ChunkState = st._chunks[st._chunk_of_tile(t)]
		var tpc := st._tiles_per_chunk()
		var local := t - st._chunk_of_tile(t) * tpc
		assert_eq(cs.hole_mesh, cs.mid_mesh, "the chunk's drawn mesh is the mid one")
		assert_true(cs.hole_mask & (1 << (local.y * tpc + local.x)) != 0, "with a hole where tile %s is" % t)


func test_dropping_a_near_tile_recuts_its_hole_as_a_budgeted_unit() -> void:
	var st := _small()
	st.prefill()
	var t := st._tile_of(Vector2.ZERO)
	var cs: LevelStreamer.ChunkState = st._chunks[st._chunk_of_tile(t)]
	var mask := cs.hole_mask
	st._drop_near_tile(t, st._tiles[t])
	assert_eq(cs.hole_mask, mask, "the planner leaves the mesh rebuild to the queue")
	st._run_queue(Time.get_ticks_usec() + 60_000_000)
	assert_ne(cs.hole_mask, mask, "the queue fills the hole")
	assert_true(st._est.has("holes"), "and the scheduler measured it")


func test_a_mesh_with_no_near_tiles_over_it_is_not_built_twice() -> void:
	var st := _small()
	var coord := Vector2i(3, 3)
	st._chunk(coord)
	var job := st._new_job(coord, LevelStreamer.Level.FAR, false)
	st._step(job, Time.get_ticks_usec() + 60_000_000, LevelStreamer.Stage.COLLIDE)
	assert_eq(st._chunks[coord].far_mesh.mesh, job.mesh, "the uploaded mesh stays in place")


func test_holes_leave_out_the_covered_cells_and_hang_skirts_round_them() -> void:
	var st := _small()
	st.prefill()
	var cs: LevelStreamer.ChunkState = st._chunks[Vector2i.ZERO]
	var tpc := st._tiles_per_chunk()
	var n := int(st.settings.chunk_m / st.settings.mid_stride_m) + 1
	var per_tile := int(st.settings.near_tile_m / st.settings.mid_stride_m)
	var whole := st._coarse_mesh(cs.mid_arrays, n, per_tile, tpc, 0, 6.0)
	var holed := st._coarse_mesh(cs.mid_arrays, n, per_tile, tpc, 1, 6.0)
	var whole_idx: PackedInt32Array = whole.surface_get_arrays(0)[Mesh.ARRAY_INDEX]
	var holed_idx: PackedInt32Array = holed.surface_get_arrays(0)[Mesh.ARRAY_INDEX]
	@warning_ignore("integer_division")
	var covered := (n - 1) * (n - 1) / (tpc * tpc)
	@warning_ignore("integer_division")
	var skirt_edges := 2 * ((n - 1) / tpc)  # the hole's two inner sides
	@warning_ignore("integer_division")
	var border_edges := 2 * ((n - 1) / tpc)  # the chunk-border skirt segments beside the covered tile
	assert_eq(holed_idx.size(), whole_idx.size() - covered * 6 + skirt_edges * 12 - border_edges * 12)


func test_collision_built_from_the_mid_grid_is_rebuilt_from_the_near_grid() -> void:
	var st := _small()
	st.prefill()
	var t := st._tile_of(Vector2.ZERO)
	var ts: LevelStreamer.TileState = st._tiles[t]
	assert_eq(ts.body_level, LevelStreamer.Level.NEAR, "under the car, collision is at full detail")
	# Back to mid-grid collision, as a tile the car drives onto before its near mesh is in.
	st._drop_near_tile(t, ts)
	ts.body.free()
	ts.body = null
	st._collide_tile(t)
	assert_eq(ts.body_level, LevelStreamer.Level.MID)
	var mid_body: StaticBody3D = ts.body
	st._plan()
	st._run_all()
	assert_eq(ts.body_level, LevelStreamer.Level.NEAR, "the near build redoes it")
	assert_ne(ts.body, mid_body)


func test_a_slow_frame_never_raises_the_budget_floor_past_its_cap() -> void:
	var st := _small()
	st.spare_us = 0.0
	var cap_s := 1.0 / st.settings.budget_floor_fps
	assert_eq(st.budget_us(cap_s * 3.0), st.budget_us(cap_s), "a frame three times as long gets no more")
	assert_lt(st.budget_us(cap_s * 0.5), st.budget_us(cap_s), "a quicker frame still gets its share")
	st.spare_us = 1.0e6
	assert_eq(st.budget_us(cap_s), int(st.spare_us * st.settings.budget_fraction), "real spare time still counts in full")


func test_the_mid_band_narrows_to_the_sides_and_behind_as_the_car_speeds_up() -> void:
	var st := _small()
	var fast := Vector2(0.0, st.settings.mid_squash_speed_mps * 2.0)
	assert_almost_eq(st.squashed_distance(Vector2(30.0, 40.0), Vector2.ZERO), 50.0, 1e-4, "a stopped car's band is round")
	assert_almost_eq(st.squashed_distance(Vector2(0.0, 100.0), fast), 100.0, 1e-4, "it reaches as far ahead at speed")
	assert_gt(st.squashed_distance(Vector2(100.0, 0.0), fast), 100.0, "but less far to the side")
	assert_gt(st.squashed_distance(Vector2(0.0, -100.0), fast), 100.0, "and behind")


func test_chunks_past_the_horizon_are_dropped_when_the_car_leaves() -> void:
	var st := _small()
	st.prefill()
	assert_gt(st.chunk_counts().y, 0)
	st.focus.position = Vector3(st.settings.chunk_m * (st.settings.far_radius + 10), 0.0, 0.0)
	st._plan()
	assert_false(st._chunks.has(Vector2i.ZERO), "the spawn chunk is far behind and should be gone")


# The horizon: every block in reach gets one mesh, drawn with the cells cut out whose chunk draws its own far or mid mesh.
func _horizon_streamer() -> LevelStreamer:
	var st := _small(96.0 * (3 + 12))
	st.settings.horizon_block_chunks = 9  # 81 cells: more than an int bit mask holds
	return st


func _horizon_count(st: LevelStreamer) -> int:
	var c := 0
	for hs: LevelStreamer.HorizonState in st._horizon.values():
		c += int(hs.mesh != null)
	return c


func test_the_horizon_draws_every_block_in_reach_with_the_far_chunks_cut_out() -> void:
	var st := _horizon_streamer()
	var s := st.settings
	st.prefill()
	assert_eq(st._queue.size(), 0)
	var bm := s.chunk_m * s.horizon_block_chunks
	var cells := s.horizon_block_chunks * s.horizon_block_chunks
	var far_out := 0
	for b: Vector2i in st._horizon:
		var hs: LevelStreamer.HorizonState = st._horizon[b]
		assert_not_null(hs.mesh, "block %s in reach has a mesh" % b)
		assert_eq(hs.cut, st.horizon_cut(b), "block %s is cut for the chunks loaded now" % b)
		assert_eq(hs.mesh.visible, hs.cut.count(1) < cells, "a wholly covered block is hidden")
		if hs.cut.is_empty():
			far_out += 1
	assert_gt(far_out, 0, "blocks past the far level draw whole")
	for bz in range(-12, 12):
		for bx in range(-12, 12):
			var b := Vector2i(bx, bz)
			if LevelStreamer._dist_to_rect(Vector2.ZERO, Rect2(Vector2(b) * bm, Vector2(bm, bm))) <= s.horizon_radius_m:
				assert_true(st._horizon.has(b), "block %s is in reach" % b)
	for coord: Vector2i in st._chunks:
		var cs: LevelStreamer.ChunkState = st._chunks[coord]
		var b := st.horizon_block_of_chunk(coord)
		if cs.far_mesh == null or not st._horizon.has(b):
			continue
		var local := coord - b * s.horizon_block_chunks
		assert_eq(st._horizon[b].cut[local.y * s.horizon_block_chunks + local.x], 1,
			"chunk %s's cell is cut out of block %s" % [coord, b])


func test_a_horizon_cell_fills_back_in_when_its_chunk_goes() -> void:
	var st := _horizon_streamer()
	var s := st.settings
	st.prefill()
	var coord := Vector2i(1 << 20, 0)
	for c: Vector2i in st._chunks:
		if st._chunks[c].far_mesh != null and st._horizon.has(st.horizon_block_of_chunk(c)):
			coord = c
			break
	assert_true(st._chunks.has(coord), "some chunk with a far mesh lies in a horizon block")
	if not st._chunks.has(coord):
		return
	var b := st.horizon_block_of_chunk(coord)
	var local := coord - b * s.horizon_block_chunks
	var cell := local.y * s.horizon_block_chunks + local.x
	var hs: LevelStreamer.HorizonState = st._horizon[b]
	assert_eq(hs.cut[cell], 1)
	st._drop_chunk(coord, st._chunks[coord])
	assert_eq(hs.cut[cell], 1, "the planner leaves the recut to the queue")
	st._run_queue(Time.get_ticks_usec() + 60_000_000)
	assert_true(hs.cut.is_empty() or hs.cut[cell] == 0, "the queue draws the horizon there again")
	assert_true(st._est.has("horizon_holes"), "and the scheduler measured it")


func test_horizon_blocks_go_when_the_car_leaves_and_none_are_built_with_it_off() -> void:
	var st := _horizon_streamer()
	var s := st.settings
	st.prefill()
	assert_true(st._horizon.has(Vector2i.ZERO))
	assert_gt(_horizon_count(st), 0)
	st.focus.position = Vector3(s.horizon_radius_m * 3.0, 0.0, 0.0)
	st._plan()
	assert_false(st._horizon.has(Vector2i.ZERO), "the spawn block is far behind and should be gone")
	s.horizon_radius_m = 0.0
	st._plan()
	assert_eq(st._horizon.size(), 0, "turned off, every block goes")


func test_a_stage_that_runs_out_of_frame_ends_the_frame_instead_of_spinning() -> void:
	var was := Config.data.threaded_chunk_build
	Config.data.threaded_chunk_build = false
	var st := _small()
	st._plan()
	st._peak_us["heights"] = 1.0e9  # no sample will ever look as if it fits
	var start := Time.get_ticks_usec()
	st._run_queue(start + 200_000)
	Config.data.threaded_chunk_build = was
	assert_lt(Time.get_ticks_usec() - start, 100_000, "returned long before the 200 ms deadline")


func test_a_car_over_ground_with_no_collision_gets_it_built_at_once() -> void:
	var st := _small()
	var p := Vector2(st.settings.chunk_m * 5.5, st.settings.chunk_m * -3.5)
	st.focus.position = Vector3(p.x, 0.0, p.y)
	assert_false(st.has_collision_at(p.x, p.y))
	st._guard_collision()
	assert_true(st.has_collision_at(p.x, p.y))
	assert_false(st._rush_collision(st._tile_of(p)), "nothing to rush once the collision is there")


func test_cancelled_jobs_leave_the_queue_at_the_next_plan() -> void:
	var st := _small()
	st._plan()
	st.focus.position = Vector3(st.settings.chunk_m * (st.settings.far_radius + 10), 0.0, 0.0)
	st._plan()
	for job in st._queue:
		assert_false(job.cancelled, "a dropped chunk's job is still queued")


# A jump of a few hundred metres (a teleport) leaves the old chunks past the far ring but inside the square dropped whole:
# they must still shed their near and mid meshes and collision, and their queued jobs must be cancelled, not run.
func test_a_jump_past_the_horizon_sheds_full_detail_and_collision_behind_it() -> void:
	var st := _small()
	var s := st.settings
	st.prefill()
	assert_true(_has_collision(st, Vector2i.ZERO))
	var redo: LevelStreamer.ChunkState = st._chunks[Vector2i(0, 1)]
	st._drop_mid(redo)
	st._drop_collision(redo)
	st._plan()
	var stale: LevelStreamer.ChunkJob = redo.mid_job
	assert_not_null(stale, "the planner queued the chunk's mid build again")
	var dest := Vector2(s.chunk_m * (s.far_radius + 1.5), 0.0)
	st.focus.position = Vector3(dest.x, 0.0, dest.y)
	st.prefill()
	assert_true(st._chunks.has(Vector2i.ZERO), "the spawn chunk is past the horizon but not yet dropped whole")
	for coord: Vector2i in st._chunks:
		var cs: LevelStreamer.ChunkState = st._chunks[coord]
		var d := _chunk_d(st, coord, dest)
		if d > s.mid_radius + 1.5:
			assert_null(cs.mid_mesh, "chunk %s (%.1f chunks away) kept its mid mesh" % [coord, d])
		for t in st._tiles_of_chunk(coord):
			var ts: LevelStreamer.TileState = st._tiles.get(t)
			if ts == null:
				continue
			if d > LevelStreamer.NEAR_KEEP_CHUNKS:
				assert_null(ts.body, "chunk %s (%.1f chunks away) kept its collision" % [coord, d])
			if d > s.mid_radius + 1.5:
				assert_null(ts.near_mesh, "chunk %s kept a near tile" % coord)
	if stale != null:
		assert_true(stale.cancelled, "the stale mid job was cancelled, not run by the prefill")
		assert_eq(stale.stage, LevelStreamer.Stage.PREP, "and never ran")


func test_a_far_gap_never_beats_near_work_and_a_hidden_far_mesh_waits_at_its_distance() -> void:
	var st := _small()
	var hole := LevelStreamer.ChunkState.new()
	assert_gt(st._far_priority(hole, 0.0), st.settings.mid_radius + 0.75 - 100.0, "never ahead of a near mesh or collision")
	hole.mid_mesh = MeshInstance3D.new()
	assert_eq(st._far_priority(hole, 2.0), 2.0, "a far mesh under a finer one waits at its distance")
	hole.mid_mesh.free()


func test_a_coarse_chunk_fully_under_near_tiles_draws_nothing_not_even_a_border_skirt() -> void:
	var st := _small()
	var n := 9
	var src := [PackedVector3Array(), PackedColorArray(), PackedVector2Array(), PackedVector2Array()]
	for i in n * n + st._perimeter(n).size():
		src[0].append(Vector3.ZERO)
		src[1].append(Color.WHITE)
		src[2].append(Vector2.ZERO)
		src[3].append(Vector2.ZERO)
	assert_eq(st._coarse_mesh(src, n, 4, 2, 0b1111, 6.0).get_surface_count(), 0, "all four tiles covered")
	assert_eq(st._coarse_mesh(src, n, 4, 2, 0b0111, 6.0).get_surface_count(), 1, "one tile uncovered still draws")


func _stitch_job(st: LevelStreamer, stitch: int) -> LevelStreamer.ChunkJob:
	var job := LevelStreamer.ChunkJob.new()
	job.stride = st.settings.near_stride_m
	job.n = int(st.settings.near_tile_m / job.stride) + 1
	job.halo = 1
	var m := job.n + 2
	job.heights.resize(m * m)
	job.verts.resize(job.n * job.n)
	for i in m * m:
		job.heights[i] = sin(i * 0.7) * 3.0
	for i in job.n * job.n:
		@warning_ignore("integer_division")
		job.verts[i] = Vector3(0.0, job.heights[(i / job.n + 1) * m + i % job.n + 1], 0.0)
	job.stitch = stitch
	return job


func test_a_stitched_edge_follows_the_mid_line_and_other_edges_are_untouched() -> void:
	var st := _small()
	var job := _stitch_job(st, 0b0001)
	var before := job.verts.duplicate()
	st._stitch(job.verts, job.heights, job.n, job.halo, job.stride, job.stitch)
	var n := job.n
	var r := roundi(st.settings.mid_stride_m / job.stride)
	var m := n + 2
	for j in n:
		@warning_ignore("integer_division")
		var j0 := j / r * r
		var j1 := mini(j0 + r, n - 1)
		var h0 := job.heights[(j0 + 1) * m + 1]
		var h1 := job.heights[(j1 + 1) * m + 1]
		assert_almost_eq(job.verts[j * n].y, lerpf(h0, h1, float(j - j0) / r), 0.0001, "west edge vertex %d" % j)
	for j in n:
		assert_eq(job.verts[j * n + n - 1], before[j * n + n - 1], "east edge")
		assert_eq(job.verts[j], before[j], "south edge")
	for i in n * n:
		if (i % n) * job.stride >= LevelStreamer.STITCH_BLEND_M:
			assert_eq(job.verts[i], before[i], "outside the blend")


func test_an_edge_is_stitched_only_where_no_near_neighbour_is_coming() -> void:
	var st := _small()
	var t := Vector2i(5, 5)
	assert_eq(st._stitch_mask(t), 0b1111)
	st._tile(t + Vector2i(1, 0)).near_mesh = MeshInstance3D.new()
	assert_eq(st._stitch_mask(t), 0b1101)
	st._tile(t + Vector2i(0, 1)).near_job = LevelStreamer.ChunkJob.new()
	assert_eq(st._stitch_mask(t), 0b0101)
	st._tile(t + Vector2i(1, 0)).near_mesh.free()


func test_the_build_hook_sees_every_built_mesh_once_and_changes_nothing() -> void:
	var seen := []
	LevelStreamer.on_chunk_built = func(level: int, coord: Vector2i, n: int, mask: int, arrays: Array) -> void:
		seen.append([level, coord, n, arrays])
	var hooked := _small()
	hooked.prefill()
	LevelStreamer.on_chunk_built = Callable()
	var plain := _small()
	plain.prefill()
	var built := 0
	for ts: LevelStreamer.TileState in hooked._tiles.values():
		built += int(ts.near_mesh != null)
	for st: LevelStreamer.ChunkState in hooked._chunks.values():
		built += int(st.mid_mesh != null) + int(st.far_mesh != null)
	assert_gt(built, 0)
	assert_eq(seen.size(), built, "one call per built mesh")
	for s: Array in seen:
		var n: int = s[2]
		assert_eq((s[3][Mesh.ARRAY_VERTEX] as PackedVector3Array).size(), n * n + 4 * (n - 1), "grid plus skirt")
	for t: Vector2i in hooked._tiles:
		if hooked._tiles[t].near_mesh != null:
			assert_eq(hooked._tiles[t].near_arrays[0], plain._tiles[t].near_arrays[0], "same ground with the hook set")


func test_streaming_reports_the_finer_perf_keys() -> void:
	var s := LevelStreamer.new()
	s.setup(_data, _bake, ShaderMaterial.new())
	add_child(s)
	s.focus = _car
	PerfLog.begin_capture()
	s.prefill()
	var report := PerfLog.end_capture(1)
	s.free()
	assert_true(report.has("stream_mesh"), "mesh uploads are tracked")
