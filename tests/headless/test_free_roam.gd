extends GutTest
# The free-roam prototype (features/free-roam.md): the road layout, road-first terrain, and the
# budgeted streamer. Everything runs on a small synthetic island so the tests stay cheap and
# never depend on the shipped preset's numbers.


func _settings() -> FreeRoamSettings:
	var s := FreeRoamSettings.new()
	s.world_seed = 7
	s.island_radius_m = 3000.0
	s.near_radius = 1
	s.far_radius = 3
	s.collision_radius = 1
	return s


func _world(s: FreeRoamSettings) -> RoadTerrain:
	var net := RoadNetwork.new()
	var terrain := RoadTerrain.new()
	terrain.setup(s, net)
	net.build(s, terrain)
	return terrain


func _streamer(s: FreeRoamSettings) -> TerrainStreamer:
	var st := TerrainStreamer.new()
	st.settings = s
	var focus := Node3D.new()
	add_child_autofree(focus)
	st.focus = focus
	add_child_autofree(st)
	return st


func _road_midpoint(net: RoadNetwork) -> Vector2:
	var pts := net.polyline(0)
	return pts[floori(pts.size() * 0.5)]


# The game must build the same island as tools/road_network_lab.html, so its random stream and
# hash reproduce the lab's JavaScript bit for bit. These are that code's outputs.
func test_the_random_stream_and_hash_match_the_lab_javascript() -> void:
	var rng := LabNoise.Rng.new(7920)
	assert_eq(rng.next(), 0.16673601930961013)
	assert_eq(rng.next(), 0.82467085425741971)
	assert_eq(rng.next(), 0.20848138467408717)
	assert_eq(LabNoise.hash2(-5, 7, 123456), 0.86390039091929793)
	assert_eq(LabNoise.hash2(3, -9, 42), 0.077124340692535043)


func test_the_same_seed_builds_the_same_network() -> void:
	var a := _world(_settings()).net
	var b := _world(_settings()).net
	assert_gt(a.edges.size(), 0, "the growth must produce roads")
	assert_eq(a.node_x, b.node_x)
	assert_eq(a.node_y, b.node_y)
	assert_eq(a.edges, b.edges)


func test_every_road_lands_exactly_on_its_two_junctions() -> void:
	var net := _world(_settings()).net
	for ei in net.edges.size():
		var pts := net.polyline(ei)
		assert_almost_eq(pts[0], net.nodes[net.edges[ei].x], Vector2(0.01, 0.01))
		assert_almost_eq(pts[pts.size() - 1], net.nodes[net.edges[ei].y], Vector2(0.01, 0.01))


func test_nearest_finds_a_point_on_the_road() -> void:
	var net := _world(_settings()).net
	var p := _road_midpoint(net)
	assert_true(net.nearest(p.x, p.y, 50.0))
	assert_almost_eq(net.hit_d, 0.0, 0.01)


func test_chunk_candidates_agree_with_the_global_search() -> void:
	var s := _settings()
	var net := _world(s).net
	var center := _road_midpoint(net) + Vector2(20.0, -15.0)
	var cands := net.candidates_for(center.x, center.y, 50.0, s.mountain_dist_m)
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	for i in 40:
		var x := center.x + rng.randf_range(-35.0, 35.0)
		var y := center.y + rng.randf_range(-35.0, 35.0)
		assert_true(net.nearest(x, y, s.mountain_dist_m))
		var global_d := net.hit_d
		var global_edge := net.hit_edge
		assert_true(net.nearest_in(x, y, cands, s.mountain_dist_m))
		assert_eq(net.hit_d, global_d)
		assert_eq(net.hit_edge, global_edge, "ties resolve the same way whichever search is used")


func test_beside_the_road_the_ground_takes_the_roads_own_height() -> void:
	# Inside the flat band the terrain is the road's height at the nearest road point, so the
	# road surface never tilts sideways with the noise around it.
	var s := _settings()
	var terrain := _world(s)
	var net := terrain.net
	var m := _road_midpoint(net)
	net.nearest(m.x, m.y, 50.0)
	var q := net.hit_q
	var across := Vector2(-net.hit_dir.y, net.hit_dir.x) * s.flat_band_m * 0.4
	var none := PackedInt32Array()
	for p: Vector2 in [q, q + across, q - across]:
		var h := terrain.height(p.x, p.y, none, false)
		net.nearest(p.x, p.y, 50.0)
		var road_h := maxf(terrain.base_h(net.hit_qx, net.hit_qy), s.water_level_m + 3.0) + terrain.bump(net.hit_qx, net.hit_qy)
		assert_almost_eq(h, road_h, 0.01)


func test_zero_twist_makes_every_road_a_straight_line() -> void:
	var s := _settings()
	s.road_twist = 0.0
	var net := _world(s).net
	for ei in net.edges.size():
		var a := net.nodes[net.edges[ei].x]
		var b := net.nodes[net.edges[ei].y]
		for p in net.polyline(ei):
			assert_almost_eq(Geometry2D.get_closest_point_to_segment(p, a, b).distance_to(p), 0.0, 0.01)


func test_a_lake_floor_lies_below_the_water() -> void:
	var s := _settings()
	var terrain := _world(s)
	var found := 0
	for x in range(-2000, 2001, 50):
		for y in range(-2000, 2001, 50):
			if terrain.is_lake(x, y) and LabNoise.hyp(x, y) < terrain.coast_r(x, y) - 500.0:
				assert_lt(terrain.height(x, y, PackedInt32Array(), false), s.water_level_m + 0.001)
				found += 1
	if found == 0:
		pass_test("no lake on this synthetic island; nothing to check")


func test_no_road_runs_through_water() -> void:
	var terrain := _world(_settings())
	for ei in terrain.net.edges.size():
		var pts := terrain.net.polyline(ei)
		for i in range(0, pts.size(), 4):
			assert_false(terrain.is_lake(pts[i].x, pts[i].y) and pts[i].length() > 900.0,
				"road point %s sits in a lake" % pts[i])


func test_the_car_reads_road_on_the_road_and_none_far_from_it() -> void:
	var s := _settings()
	var st := _streamer(s)
	var p := _road_midpoint(st.network)
	assert_almost_eq(st.surface_at(p.x, p.y).x, 1.0, 0.001)
	assert_eq(st.surface_at(p.x + 5000.0, p.y + 5000.0), Vector2.ZERO)


func test_a_frame_with_no_budget_left_advances_a_job_by_one_unit_only() -> void:
	var st := _streamer(_settings())
	st._plan()
	var job: TerrainStreamer.ChunkJob = st._queue[0]
	assert_eq(job.stage, TerrainStreamer.Stage.PREP)
	var now := Time.get_ticks_usec()
	st._run_queue(now)
	assert_eq(job.stage, TerrainStreamer.Stage.HEIGHTS, "the first unit of a frame always runs")
	assert_eq(job.cursor, 0, "nothing beyond that one unit")
	now = Time.get_ticks_usec()
	st._run_queue(now)
	assert_eq(job.cursor, 1, "an exhausted frame computes a single height sample")


func test_prefill_puts_collision_under_the_car() -> void:
	var st := _streamer(_settings())
	st.prefill()
	assert_true(st.has_collision_at(0.0, 0.0))
	assert_eq(st.queued(), 0)


func test_height_queries_on_a_loaded_chunk_read_the_drawn_surface() -> void:
	var s := _settings()
	var st := _streamer(s)
	st.prefill()
	var cs: TerrainStreamer.ChunkState = st._chunks[Vector2i.ZERO]
	assert_false(cs.near_heights.is_empty())
	var m := int(s.chunk_m / s.near_stride_m) + 3
	# on a grid vertex the answer is exactly the vertex the mesh was built from
	for g: Vector2i in [Vector2i(0, 0), Vector2i(5, 7), Vector2i(12, 3)]:
		var expected := cs.near_heights[(g.y + 1) * m + g.x + 1]
		assert_almost_eq(st.height_at(g.x * s.near_stride_m, g.y * s.near_stride_m), expected, 0.0001)
	# between vertices it stays close to the true terrain
	var x := 13.3
	var z := 21.7
	assert_almost_eq(st.height_at(x, z), st.terrain.height(x, z, PackedInt32Array(), false), 1.0)


func test_the_road_surface_read_from_a_loaded_chunk_agrees_with_the_road() -> void:
	var s := _settings()
	var st := _streamer(s)
	st.prefill()
	var net := st.network
	# a road point inside a loaded near chunk, and a point well off the road next to it
	for ei in net.edges.size():
		for p in net.polyline(ei):
			var cs: TerrainStreamer.ChunkState = st._chunks.get(st._chunk_of(p))
			if cs == null or cs.near_road_d.is_empty():
				continue
			assert_almost_eq(st.surface_at(p.x, p.y).x, 1.0, 0.001, "on the road")
			net.nearest(p.x, p.y, 50.0)
			var off := p + Vector2(-net.hit_dir.y, net.hit_dir.x) * (s.road_half_width_m + s.road_shoulder_m + 6.0)
			net.nearest(off.x, off.y, 50.0)
			if net.hit_d > s.road_half_width_m + s.road_shoulder_m + 3.0:
				assert_almost_eq(st.surface_at(off.x, off.y).x, 0.0, 0.001, "off the road")
			return
	fail_test("no road ran through a loaded near chunk")


func test_a_chunk_gathers_its_road_candidates_once_for_both_builds() -> void:
	var st := _streamer(_settings())
	st.prefill()
	var cs: TerrainStreamer.ChunkState = st._chunks[Vector2i.ZERO]
	assert_true(cs.has_cands)
	assert_false(cs.near_mesh == null or cs.far_mesh == null, "both builds ran for the spawn chunk")


func _foliage_positions(st: TerrainStreamer) -> PackedVector3Array:
	var out := PackedVector3Array()
	for c in st._chunks.values():
		var cs: TerrainStreamer.ChunkState = c
		if cs.foliage == null:
			continue
		for field in cs.foliage.get_children():
			out.append_array(field.get("instance_positions"))
	return out


func test_near_chunks_are_planted_with_foliage_off_the_road_and_out_of_the_water() -> void:
	var s := _settings()
	s.forestiness = 1.0
	var st := _streamer(s)
	st.prefill()
	var spots := _foliage_positions(st)
	assert_gt(spots.size(), 0, "near chunks grow something")
	for p in spots:
		st.network.nearest(p.x, p.z, 50.0)
		assert_gt(st.network.hit_d, s.road_half_width_m, "nothing grows on the road")
		assert_false(st.terrain.is_lake(p.x, p.z), "nothing grows in a lake")


func test_foliage_goes_when_its_chunk_leaves_full_detail() -> void:
	var s := _settings()
	s.forestiness = 1.0
	var st := _streamer(s)
	st.prefill()
	var cs: TerrainStreamer.ChunkState = st._chunks[Vector2i.ZERO]
	assert_not_null(cs.foliage)
	st._drop_near(cs)
	assert_null(cs.foliage)


func test_the_same_chunk_plants_the_same_spots_every_time() -> void:
	var s := _settings()
	s.forestiness = 1.0
	var a := _foliage_positions(_prefilled(s))
	var b := _foliage_positions(_prefilled(s))
	assert_gt(a.size(), 0)
	a.sort()
	b.sort()
	assert_eq(a, b)


func _prefilled(s: FreeRoamSettings) -> TerrainStreamer:
	var st := _streamer(s)
	st.prefill()
	return st


func test_chunks_past_the_horizon_are_dropped_when_the_car_leaves() -> void:
	var s := _settings()
	var st := _streamer(s)
	st.prefill()
	assert_gt(st.chunk_counts().y, 0)
	st.focus.position = Vector3(s.chunk_m * (s.far_radius + 10), 0.0, 0.0)
	st._plan()
	assert_false(st._chunks.has(Vector2i.ZERO), "the spawn chunk is far behind and should be gone")


func test_the_free_roam_scene_wires_the_streamer_and_the_car() -> void:
	var scene: PackedScene = load("res://free_roam.tscn")
	var root := scene.instantiate()
	assert_true(root.get_node("Terrain") is TerrainStreamer)
	assert_true(root.get_node("Car") is VehicleBody3D)
	assert_eq((root.get_node("ChaseCamera") as Node).get("target"), root.get_node("Car"))
	root.free()


# --- the auto driver ----------------------------------------------------------------------------

func test_a_planned_route_follows_the_roads() -> void:
	var s := _settings()
	var terrain := _world(s)
	var net := terrain.net
	var route := AutoDriver.plan_route(net, 0, 1500.0, 1)
	assert_gt(route.size(), 2)
	for i in range(0, route.size() - 1):
		var mid := route[i].lerp(route[i + 1], 0.5)
		assert_true(net.nearest(mid.x, mid.y, 0.5), "route point %d lies on a road" % i)


func test_the_route_tracker_never_goes_backwards() -> void:
	var pts := PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(20, 0), Vector2(30, 0)])
	assert_eq(AutoDriver.advance(pts, 0, Vector2(15, 1)), 1)
	assert_eq(AutoDriver.advance(pts, 2, Vector2(1, 0)), 2, "a car behind its segment keeps the segment")


func test_bends_ahead_lower_the_safe_speed() -> void:
	var straight := PackedVector2Array()
	var bend := PackedVector2Array()
	for i in 20:
		straight.append(Vector2(i * 10.0, 0.0))
		bend.append(Vector2(i * 10.0, 0.0) if i < 10 else Vector2(90.0, (i - 9) * 10.0))
	var fast := AutoDriver.safe_speed(straight, AutoDriver.cumulative(straight), 0, 200.0, 6.0, 5.0)
	var slow := AutoDriver.safe_speed(bend, AutoDriver.cumulative(bend), 0, 200.0, 6.0, 5.0)
	assert_eq(fast, INF, "a straight road sets no limit")
	assert_lt(slow, 100.0)
	var closer := AutoDriver.safe_speed(bend, AutoDriver.cumulative(bend), 6, 200.0, 6.0, 5.0)
	assert_lt(closer, slow, "nearer the bend there is less room to brake")


# The streaming promise end to end: the car drives itself along the roads and is never over
# ground that has no collision yet.
func test_the_auto_driver_never_reaches_ground_without_collision() -> void:
	var root: Node3D = load("res://free_roam.tscn").instantiate()
	(root.get_node("Terrain") as TerrainStreamer).settings = _settings()
	add_child_autofree(root)
	var driver: AutoDriver = root.start_auto_drive()
	driver.route_length_m = 400.0
	driver.start(root.get_node("Car"), root.get_node("Terrain"))
	for i in 60 * 40:
		if not driver.running:
			break
		await get_tree().physics_frame
	var r := driver.report()
	assert_eq(r["holes"], 0, "the car was over a chunk with no collision")
	assert_gt(r["progress_m"], 150.0, "the car made real progress along the route")
