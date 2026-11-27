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
	var job := TerrainStreamer.ChunkJob.new()
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
	var job := TerrainStreamer.ChunkJob.new()
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


func _prepped_job(streamer: LevelStreamer, coord := Vector2i.ZERO) -> TerrainStreamer.ChunkJob:
	var job := streamer._new_job(coord, TerrainStreamer.Level.MID, false)
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
	assert_eq(b.stage, TerrainStreamer.Stage.UPLOAD)
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
	assert_eq(job.stage, TerrainStreamer.Stage.DONE)
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
	var ahead := _streamer._tile_of(Vector2(TerrainStreamer.NEAR_REACH_M + 30.0, 0.0))
	var behind := _streamer._tile_of(Vector2(-TerrainStreamer.NEAR_REACH_M - 30.0, 0.0))
	assert_true(wanted.has(ahead), "the road ahead past the near reach is queued")
	assert_lt(float(wanted[ahead]), Config.data.adaptive_near_lead_s, "with a time until the car gets there")
	assert_false(wanted.has(behind), "the road behind past the reach is not")
	assert_eq(float(wanted[_streamer._tile_of(here)]), 0.0, "the tile under the car is due now")


func test_a_tile_on_the_path_that_cannot_be_built_in_time_is_overdue() -> void:
	var job := TerrainStreamer.ChunkJob.new()
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
