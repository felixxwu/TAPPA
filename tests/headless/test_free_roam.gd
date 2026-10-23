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


# The painted road edge sits where the grip edge does, but fades over at least road_paint_fade_m so
# the blend spans several mesh vertices.
func test_the_painted_road_edge_matches_the_grip_edge_but_fades_wider() -> void:
	var s := _settings()
	var terrain := _world(s)
	var mid := s.road_half_width_m + s.road_shoulder_m * 0.5
	assert_almost_eq(terrain.paint_weight(mid), terrain.road_weight(mid), 0.001, "same edge")
	assert_eq(terrain.paint_weight(0.0), 1.0)
	var half := maxf(s.road_shoulder_m, s.road_paint_fade_m) * 0.5
	assert_gt(terrain.paint_weight(mid + half - 0.01), 0.0, "still fading out to half the paint fade")
	assert_eq(terrain.paint_weight(mid + half), 0.0)


# The wheel debris picks its look from the same surface_at the tyres read: gravel clods on the
# road, grass blades off it (free roam's roads are all loose, so nothing reads as tarmac).
func test_wheel_debris_reads_gravel_on_the_road_and_grass_off_it() -> void:
	var st := _streamer(_settings())
	var p := _road_midpoint(st.network)
	var wp := WheelParticles.new()
	add_child_autofree(wp)
	var cfg: GameConfig = Config.data
	var on_road: WheelParticles.Look = wp._look_for_surface(cfg, st.surface_at(p.x, p.y))
	var off_road: WheelParticles.Look = wp._look_for_surface(cfg, st.surface_at(p.x + 5000.0, p.y + 5000.0))
	assert_not_null(on_road, "the road throws debris")
	assert_eq(on_road.color, WheelParticles._gravel_look(cfg).color, "gravel on the road")
	assert_not_null(off_road, "the open ground throws debris")
	assert_eq(off_road.color, wp._grass_look(cfg).color, "grass off it")


# Build one chunk's mesh arrays (no attach) and return its grid colours, skirts left off.
func _baked_colors(st: TerrainStreamer, coord: Vector2i, near: bool) -> PackedColorArray:
	var job := st._new_job(coord, near, false)
	st._queue.erase(job)
	st._step(job, Time.get_ticks_usec() + 60_000_000, TerrainStreamer.Stage.UPLOAD)
	return job.colors.slice(0, job.n * job.n)


func _with_light(amount: float) -> void:
	var cfg: GameConfig = Config.data
	cfg.sun_direction = Vector3(0.0, 0.5, 1.0)
	cfg.sun_color = Color(0.5, 0.5, 0.5)
	cfg.sky_color = Color(0.5, 0.5, 0.5)
	cfg.ground_color = Color(0.3, 0.3, 0.3)
	cfg.terrain_light_amount = amount


# The island is shaded with the stage's fake light (TerrainManager.light_for_normal under the
# GameConfig sun and ambient), so a slope facing the sun is brighter than one facing away. The
# light values here are synthetic.
func test_the_ground_light_is_the_stage_terrains_light() -> void:
	_with_light(1.0)
	var st := TerrainStreamer.new()
	var cfg: GameConfig = Config.data
	var toward := Vector3(0.0, 1.0, 0.6).normalized()
	var away := Vector3(0.0, 1.0, -0.6).normalized()
	assert_eq(st.ground_light(toward), TerrainManager.light_for_normal(toward,
		cfg.sun_direction.normalized(), cfg.sun_color, cfg.sky_color, cfg.ground_color, 1.0))
	assert_gt(st.ground_light(toward).r, st.ground_light(away).r, "sunward slopes are lit brighter")
	st.free()
	Config.reset()


# The light is baked into every chunk's vertex colours, so it varies with the slope; with the
# terrain light off every vertex is just its ring's tint.
func test_chunk_vertex_colours_carry_the_shading_and_are_flat_with_it_off() -> void:
	var coords: Array[Vector2i] = [Vector2i(10, 0), Vector2i(0, 10), Vector2i(-10, 0), Vector2i(0, -10), Vector2i(7, 7), Vector2i(-7, -7)]
	_with_light(1.0)
	var lit := _streamer(_settings())
	var lo := INF
	var hi := -INF
	for c in coords:
		for col in _baked_colors(lit, c, false):
			lo = minf(lo, col.r)
			hi = maxf(hi, col.r)
	assert_gt(hi - lo, 0.05, "the baked shading varies across the hills")
	_with_light(0.0)
	var flat := _streamer(_settings())
	var cm := flat.settings.chunk_m
	for c in coords:
		var tint := flat.ring_tint_at(Vector2((c.x + 0.5) * cm, (c.y + 0.5) * cm))
		for col in _baked_colors(flat, c, false):
			assert_almost_eq(col.r, tint.r, 1e-5)
			assert_almost_eq(col.g, tint.g, 1e-5)
			assert_almost_eq(col.b, tint.b, 1e-5)
	Config.reset()


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
			# (a rest stop's pad reads as road too, so the off-road point must miss them)
			if net.hit_d > s.road_half_width_m + s.road_shoulder_m + 3.0 and st.sites.is_clear(off, s.road_shoulder_m + 1.0):
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
			if field.get("instance_positions") != null:  # site markers share the node
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


func test_foliage_crowds_the_road_and_thins_away_from_it() -> void:
	var s := _settings()
	s.far_tree_density = 0.2
	s.far_bush_density = 0.2
	var st := _prefilled(s)
	var n := 1000
	for kind in [TerrainStreamer.Plant.TREE, TerrainStreamer.Plant.BUSH]:
		var near := 0
		var far := 0
		for i in n:
			var p := Vector2(i * 3.7, i * 1.3)
			st.network.hit_d = 5.0
			near += int(st._roadside_keep(p, kind, 5.0))
			st.network.hit_d = 5.0 + s.roadside_falloff_m * 4.0
			far += int(st._roadside_keep(p, kind, 5.0))
		assert_eq(near, n, "every clear spot right by the road grows")
		assert_lt(far, n / 2, "far from the road most spots are thinned out")


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
	# The safety net (_guard_collision) makes holes 0 whatever the queue order, so it alone can't
	# catch a planner or queue regression: at auto-driver speeds the queue must keep up by itself.
	# Not exactly 0: on a loaded CI machine the 1 ms budget buys less, and an odd rush (a one-off
	# hitch) is the net doing its job. A queue that has stopped keeping collision ahead of the car
	# rushes on nearly every chunk — dozens on this route — which this still catches.
	assert_lte(int(r["rushes"]), 3, "the planner and queue kept collision ahead of the car, the safety net only an odd backstop")
	assert_gt(r["progress_m"], 150.0, "the car made real progress along the route")


# --- sites: rest stops, loot slots, dead ends -----------------------------------------------------

func _sited(s: FreeRoamSettings) -> RoadTerrain:
	var terrain := _world(s)
	var sites := RoadSites.new()
	sites.build(s, terrain.net, terrain)
	terrain.sites = sites
	return terrain


func test_spawn_is_the_first_rest_stop() -> void:
	var sites := _sited(_settings()).sites
	assert_eq(sites.kind[0], RoadSites.Kind.REST)
	assert_eq(sites.pos[0], Vector2.ZERO)


func test_every_dead_end_and_only_dead_ends_get_a_dead_end_site() -> void:
	var terrain := _sited(_settings())
	var net := terrain.net
	var degree := {}
	for e in net.edges:
		degree[e.x] = degree.get(e.x, 0) + 1
		degree[e.y] = degree.get(e.y, 0) + 1
	var expected := {}
	for n: int in degree.keys():
		if n != 0 and degree[n] == 1:
			expected[n] = true
	var found := {}
	for i in terrain.sites.of_kind(RoadSites.Kind.DEAD_END):
		found[terrain.sites.node[i]] = true
	assert_eq(found.keys().size(), expected.keys().size())
	for n in expected.keys():
		assert_true(found.has(n), "dead end at node %d has its site" % n)


func test_roadside_pads_are_dry_hang_off_their_own_road_and_never_overlap() -> void:
	var terrain := _sited(_settings())
	var sites := terrain.sites
	var net := terrain.net
	assert_gt(sites.of_kind(RoadSites.Kind.REST).size(), 1)
	assert_gt(sites.of_kind(RoadSites.Kind.LOOT).size(), 0)
	for i in sites.count():
		var c := sites.pos[i]
		if sites.kind[i] != RoadSites.Kind.DEAD_END and i > 0:
			assert_false(terrain.is_water(c.x, c.y), "site %d is on dry land" % i)
			assert_true(net.nearest(c.x, c.y, 1000.0) and net.hit_edge == sites.edge[i], "site %d is nearest its own road" % i)
		for j in range(i + 1, sites.count()):
			assert_gt(c.distance_to(sites.pos[j]), sites.radius[i] + sites.radius[j] - 0.01, "sites %d and %d overlap" % [i, j])


func _region(id: String, spacing := -1.0) -> Dictionary:
	var r := {"id": id, "order": 0, "name": id}
	if spacing > 0.0:
		r["rest_stop_spacing_m"] = spacing
	return r


func test_wider_rest_stop_spacing_places_fewer_rest_stops() -> void:
	var s := _settings()
	s.ring_regions = PackedStringArray(["a"])
	var dense: Array[Dictionary] = [_region("a", 200.0)]
	RegionLibrary.override_for_test(dense)
	var n_dense := _sited(s).sites.of_kind(RoadSites.Kind.REST).size()
	var sparse: Array[Dictionary] = [_region("a", 600.0)]
	RegionLibrary.override_for_test(sparse)
	var n_sparse := _sited(s).sites.of_kind(RoadSites.Kind.REST).size()
	RegionLibrary.reset()
	assert_gt(n_dense, n_sparse)


func test_rest_stop_spacing_comes_from_the_rings_region_or_the_fallback() -> void:
	var s := _settings()
	s.ring_count = 3
	s.ring_regions = PackedStringArray(["a", "b"])
	s.rest_stop_spacing_m = 333.0
	var regions: Array[Dictionary] = [_region("a", 111.0), _region("b")]
	RegionLibrary.override_for_test(regions)
	var terrain := _world(s)
	for p in [Vector2(10, 10), Vector2(s.island_radius_m * 0.5, 0), Vector2(s.island_radius_m * 0.78, 0)]:
		var ring := terrain.ring_index(p.x, p.y)
		assert_eq(RoadSites.rest_spacing_at(s, terrain, p), [111.0, 333.0, 111.0][ring], "ring %d" % ring)
	RegionLibrary.reset()


func test_a_pad_is_flat_at_its_roads_height_and_reads_as_road() -> void:
	var terrain := _sited(_settings())
	var sites := terrain.sites
	for i in sites.count():
		if sites.kind[i] == RoadSites.Kind.LOOT:
			continue
		var c := sites.pos[i]
		assert_almost_eq(terrain.height(c.x, c.y, PackedInt32Array(), false), sites.pad_h[i], 0.001, "pad %d is flat" % i)
		assert_eq(terrain.road_weight(terrain.last_road_d), 1.0, "pad %d reads as road" % i)
		assert_false(sites.is_clear(c, 0.0), "nothing is planted on pad %d" % i)


func test_loot_sits_on_its_road_and_leaves_the_ground_alone() -> void:
	var terrain := _sited(_settings())
	var sites := terrain.sites
	var loots := sites.of_kind(RoadSites.Kind.LOOT)
	assert_gt(loots.size(), 0)
	for i in loots:
		var c := sites.pos[i]
		assert_true(terrain.net.nearest(c.x, c.y, 1000.0) and terrain.net.hit_d < 0.5, "loot %d is on the road" % i)
		for off in [Vector2.ZERO, Vector2(6, 0), Vector2(0, -9)]:
			var p: Vector2 = c + off
			if sites.pad_at(p.x, p.y) >= 0:
				continue  # inside a rest stop's or dead end's blend
			var with_sites := terrain.height(p.x, p.y, PackedInt32Array(), false)
			terrain.sites = null
			var bare := terrain.height(p.x, p.y, PackedInt32Array(), false)
			terrain.sites = sites
			assert_almost_eq(with_sites, bare, 0.001, "loot %d doesn't reshape the ground" % i)


func test_a_pads_blend_widens_to_keep_its_slope_gentle_within_bounds() -> void:
	var s := _settings()
	var sites := _sited(s).sites
	assert_eq(sites.blend_m(0.0), s.pad_blend_m, "flat land: the narrowest blend")
	var dh := s.pad_blend_max_slope * (s.pad_blend_m + s.pad_blend_max_m) * 0.5
	assert_almost_eq(sites.blend_m(-dh), dh / s.pad_blend_max_slope, 0.001, "a big gap either way widens it")
	assert_eq(sites.blend_m(1.0e6), s.pad_blend_max_m, "never wider than the max")


func test_the_ground_meets_the_land_with_no_step_where_a_pads_blend_ends() -> void:
	var terrain := _sited(_settings())
	var sites := terrain.sites
	for i in sites.count():
		var c := sites.pos[i]
		var p := c + Vector2.RIGHT * (sites.radius[i] + _settings().pad_blend_max_m + 0.01)
		if sites.pad_at(p.x, p.y) >= 0:
			continue  # inside a neighbouring pad's blend
		var with_pads := terrain.height(p.x, p.y, PackedInt32Array(), false)
		terrain.sites = null
		var bare := terrain.height(p.x, p.y, PackedInt32Array(), false)
		terrain.sites = sites
		assert_almost_eq(with_pads, bare, 0.001, "pad %d's blend has faded out fully by its reach" % i)


# --- barriers ------------------------------------------------------------------------------------

# Barrier params with the falling-land rule switched off, so every sharp bend gets its run and the
# structural rules can be checked on a small island whatever its terrain.
func _all_bends_params(s: FreeRoamSettings) -> Dictionary:
	var params := Config.data.barrier_render_params()
	params["track_width"] = s.road_half_width_m * 2.0
	params["drop_min_m"] = -1.0e6
	params["hill_tolerance_m"] = 1.0e6
	return params


func test_straight_roads_get_no_barriers() -> void:
	var s := _settings()
	s.road_twist = 0.0
	var terrain := _sited(s)
	var rb := RoadBarriers.new()
	rb.plan(s, terrain.net, terrain, terrain.sites, _all_bends_params(s))
	assert_eq(rb.modules.size(), 0)


func test_barriers_sit_on_the_outside_of_bends_in_whole_runs_clear_of_pads() -> void:
	var s := _settings()
	var terrain := _sited(s)
	var params := _all_bends_params(s)
	var rb := RoadBarriers.new()
	rb.plan(s, terrain.net, terrain, terrain.sites, params)
	assert_gt(rb.modules.size(), 0)
	var per_run := {}
	var half_w: float = params["track_width"] * 0.5
	for m: Dictionary in rb.modules:
		per_run[m["run"]] = per_run.get(m["run"], 0) + 1
		var tg: Vector2 = m["tangent"]
		var edge: Vector2 = m["pos"] + Vector2(-tg.y, tg.x) * float(m["side"]) * (half_w + float(params["road_gap_m"]))
		assert_true(terrain.sites.is_clear(edge, RoadBarriers.PAD_CLEAR_M - 0.01), "barrier clear of every pad")
	for run in per_run.keys():
		assert_true(per_run[run] >= int(params["min_run_modules"]), "run %d is long enough" % run)


func test_a_chunk_builds_its_barrier_modules_with_collision() -> void:
	var s := _settings()
	var st := TerrainStreamer.new()
	st.settings = s
	var focus := Node3D.new()
	add_child_autofree(focus)
	st.focus = focus
	add_child_autofree(st)
	st.barriers.plan(s, st.network, st.terrain, st.sites, _all_bends_params(s))
	var m: Dictionary = st.barriers.modules[0]
	var p: Vector2 = m["pos"]
	focus.position = Vector3(p.x, 0.0, p.y)
	st.prefill()
	var cs: TerrainStreamer.ChunkState = st._chunks[st._chunk_of(p)]
	var field: BarrierField = cs.foliage.get_node("Barriers")
	assert_eq(field.barrier_count, st.barriers.in_chunk(st._chunk_of(p)).size())
	assert_true(field.find_children("*", "StaticBody3D", true, false).size() > 0, "barriers are solid")


func test_a_chunk_with_bushes_can_be_brushed_by_the_car() -> void:
	var s := _settings()
	var st := _prefilled(s)
	for c in st._chunks.values():
		var cs: TerrainStreamer.ChunkState = c
		if cs.foliage != null and cs.foliage.has_node("BushInteraction"):
			assert_eq(cs.foliage.get_node("BushInteraction")._car, st.focus, "the bush field watches the car")
			return
	pending("no near chunk on this island grew bushes")


# A sample-at-a-time stage that can't fit its next sample ends the frame there. It used to report
# "carry on", and the queue spun on it until the deadline, burning the whole budget for nothing.
func test_a_stage_that_runs_out_of_frame_ends_the_frame_instead_of_spinning() -> void:
	var st := _streamer(_settings())
	st._plan()
	st._peak_us["heights"] = 1.0e9  # no sample will ever look as if it fits
	var start := Time.get_ticks_usec()
	st._run_queue(start + 200_000)
	assert_lt(Time.get_ticks_usec() - start, 100_000, "returned long before the 200 ms deadline")


# --- collision always under the car --------------------------------------------------------------

# A near build stops once its collision is in and goes back in the queue to plant. Running straight
# on into its trees kept the next chunk's collision waiting, and a fast car outran its collision
# and fell through the world.
func test_no_chunk_plants_foliage_before_every_planned_collision_is_built() -> void:
	var st := _streamer(_settings())
	st._plan()
	var want_col: Array[Vector2i] = []
	for coord: Vector2i in st._chunks:
		var cs: TerrainStreamer.ChunkState = st._chunks[coord]
		if cs.near_job != null and cs.near_job.with_collision:
			want_col.append(coord)
	assert_gt(want_col.size(), 1, "several chunks want collision around the car")
	var planted := false
	for frame in 20000:
		if st.queued() == 0:
			break
		st._run_queue(Time.get_ticks_usec() + 1000)
		for coord: Vector2i in st._chunks:
			if (st._chunks[coord] as TerrainStreamer.ChunkState).foliage == null:
				continue
			planted = true
			for c in want_col:
				assert_not_null((st._chunks[c] as TerrainStreamer.ChunkState).body,
					"chunk %s planted while %s still had no collision" % [coord, c])
				if (st._chunks[c] as TerrainStreamer.ChunkState).body == null:
					return
	if not planted:
		pending("no near chunk on this island planted anything")


# The safety net: the car over a chunk with no collision yet gets it built at once, over budget.
func test_a_car_over_ground_with_no_collision_gets_it_built_at_once() -> void:
	var s := _settings()
	var st := _streamer(s)
	st.focus.position = Vector3(s.chunk_m * 5.5, 0.0, s.chunk_m * -3.5)
	assert_false(st.has_collision_at(st.focus.position.x, st.focus.position.z))
	st._guard_collision()
	assert_true(st.has_collision_at(st.focus.position.x, st.focus.position.z))
	assert_eq(st.stat_rushes, 1)
	st._guard_collision()
	assert_eq(st.stat_rushes, 1, "nothing to rush once the collision is there")


func test_cancelled_jobs_leave_the_queue_at_the_next_plan() -> void:
	var s := _settings()
	var st := _streamer(s)
	st._plan()
	st.focus.position = Vector3(s.chunk_m * (s.far_radius + 10), 0.0, 0.0)
	st._plan()
	for job in st._queue:
		assert_false(job.cancelled, "a dropped chunk's job is still queued")


# A car that has fallen through the ground is put back however fast it is falling.
func test_a_car_far_below_the_ground_counts_as_fallen_out_of_the_world() -> void:
	var st := _streamer(_settings())
	var body := VehicleBody3D.new()
	add_child_autofree(body)
	var rec := RoadRecovery.new()
	autofree(rec)
	rec.car = body
	rec.streamer = st
	var ground := st.height_at(10.0, 10.0)
	body.global_position = Vector3(10.0, ground + 1.0, 10.0)
	assert_false(rec.fell_out_of_world())
	body.global_position = Vector3(10.0, ground - Config.data.recovery_void_depth_m - 1.0, 10.0)
	assert_true(rec.fell_out_of_world())


# --- review fixes: jumps, planting ground, markers, queue order ----------------------------------

func _chunk_d(st: TerrainStreamer, coord: Vector2i, p: Vector2) -> float:
	var cm := st.settings.chunk_m
	return ((Vector2(coord) + Vector2(0.5, 0.5)) * cm).distance_to(p) / cm


# A medium jump (a respawn or a rest-stop travel) leaves the old chunks past the horizon but still
# inside the square that is dropped whole. They must still shed their near mesh, foliage and
# collision, and their queued near / plant / collision jobs must be cancelled rather than run by
# the prefill at their old priorities.
func test_a_jump_past_the_horizon_sheds_full_detail_and_collision_behind_it() -> void:
	var s := _settings()
	s.forestiness = 1.0
	var st := _streamer(s)
	st.prefill()
	assert_not_null((st._chunks[Vector2i.ZERO] as TerrainStreamer.ChunkState).body)
	# One chunk loses its full detail and the planner queues it again: a live near job.
	var redo: TerrainStreamer.ChunkState = st._chunks[Vector2i(0, 1)]
	st._drop_near(redo)
	st._drop_collision(redo)
	st._plan()
	var stale: TerrainStreamer.ChunkJob = redo.near_job
	assert_not_null(stale, "the planner queued the chunk's near build again")
	var dest := Vector2(s.chunk_m * (s.far_radius + 1.5), 0.0)
	st.prefill_at(dest)
	assert_true(st._chunks.has(Vector2i.ZERO), "the spawn chunk is past the horizon but not yet dropped whole")
	for coord: Vector2i in st._chunks:
		var cs: TerrainStreamer.ChunkState = st._chunks[coord]
		var d := _chunk_d(st, coord, dest)
		if d > s.near_radius + 1.5:
			assert_null(cs.near_mesh, "chunk %s (%.1f chunks away) kept its near mesh" % [coord, d])
			assert_null(cs.foliage, "chunk %s kept its foliage" % coord)
		if d > s.collision_radius + 1.5:
			assert_null(cs.body, "chunk %s (%.1f chunks away) kept its collision" % [coord, d])
	if stale != null:
		assert_true(stale.cancelled, "the stale near job was cancelled, not run by the prefill")
		assert_eq(stale.stage, TerrainStreamer.Stage.PREP, "and never ran")


# Planting reads the exact terrain height outside its own chunk, never whatever mesh the neighbour
# happens to have loaded, and its own chunk's drawn surface inside it.
func test_planting_heights_do_not_depend_on_the_neighbours_load_state() -> void:
	var s := _settings()
	var st := _streamer(s)
	st.prefill()
	var cs: TerrainStreamer.ChunkState = st._chunks[Vector2i.ZERO]
	var spill := Vector2(s.chunk_m + 5.3, s.chunk_m * 0.5 + 0.7)  # in the +x neighbour
	var inside := Vector2(17.3, 40.1)
	var exact := st.terrain.height(spill.x, spill.y, PackedInt32Array(), false)
	var g := st._ground_for(Vector2i.ZERO, cs)
	assert_almost_eq(g.height_at(spill.x, spill.y), exact, 0.001, "with the neighbour at full detail")
	assert_almost_eq(g.height_at(inside.x, inside.y), st.height_at(inside.x, inside.y), 0.0001, "inside: the drawn surface")
	var nb: TerrainStreamer.ChunkState = st._chunks[Vector2i(1, 0)]
	st._drop_near(nb)  # the neighbour back to its 16 m far mesh
	assert_almost_eq(st._ground_for(Vector2i.ZERO, cs).height_at(spill.x, spill.y), exact, 0.001, "with the neighbour at far detail")
	st._chunks.erase(Vector2i(1, 0))  # and with nothing loaded there at all
	assert_almost_eq(st._ground_for(Vector2i.ZERO, cs).height_at(spill.x, spill.y), exact, 0.001, "with nothing loaded next door")
	if nb.far_mesh != null:
		nb.far_mesh.queue_free()


func _any_item(_i: int) -> Dictionary:
	return {"kind": "rumour", "id": "test"}


# A refresh that reaches a chunk before its queued marker spawn has run, then the spawn itself,
# must leave exactly one marker. A second "Loot%d" was renamed "@Loot%d@N" and never removed.
func test_a_loot_refresh_during_planting_leaves_exactly_one_marker() -> void:
	var s := _settings()
	var st := _streamer(s)
	var loots := st.sites.of_kind(RoadSites.Kind.LOOT)
	assert_gt(loots.size(), 0)
	var i: int = loots[0]
	var p := st.sites.pos[i]
	st.focus.position = Vector3(p.x, 0.0, p.y)
	st.loot_query = _any_item
	st.prefill()
	var coord := st._chunk_of(p)
	var cs: TerrainStreamer.ChunkState = st._chunks[coord]
	assert_not_null(cs.foliage.get_node_or_null("Loot%d" % i), "the crate is there")
	# The chunk's marker spawn, queued again as a planting job would have it...
	var job := TerrainStreamer.ChunkJob.new()
	job.coord = coord
	st._queue_site_markers(job, st._ground_for(coord, cs))
	# ...with a refresh landing before it runs.
	st.refresh_loot_markers()
	for k in job.spawns.size():
		if job.spawn_kinds[k] == "spawn_markers":
			job.spawns[k].call(cs.foliage)
	assert_eq(_crates(cs.foliage, i), 1, "exactly one crate for the site")
	# and a pickup clears it
	st.loot_query = Callable()
	st.refresh_loot_markers()
	assert_eq(_crates(cs.foliage, i), 0, "no crate after the pickup")
	var post := cs.foliage.get_node_or_null("Site%d" % i)
	assert_true(post == null or post.is_queued_for_deletion(), "and nothing left standing in its place")


# Live crates for loot site `i`, counting any Godot renamed to dodge a clash ("@Loot7@2").
func _crates(parent: Node, i: int) -> int:
	var count := 0
	for child in parent.get_children():
		var n := String(child.name)
		if not child.is_queued_for_deletion() and (n == "Loot%d" % i or n.begins_with("@Loot%d@" % i)):
			count += 1
	return count


# Vegetation off thins out trees, bushes and rocks only: the planting stage still dresses the chunk
# with its site markers (and barriers, crowds and loot, which spawn from the same stage).
func test_vegetation_off_still_spawns_the_site_dressing() -> void:
	var was := Config.data.vegetation_enabled
	Config.data.vegetation_enabled = false
	var s := _settings()
	s.forestiness = 1.0
	var st := _prefilled(s)
	Config.data.vegetation_enabled = was
	var cs: TerrainStreamer.ChunkState = st._chunks[st._chunk_of(st.sites.pos[0])]
	assert_not_null(cs.foliage, "the spawn chunk was dressed")
	if cs.foliage != null:
		assert_not_null(cs.foliage.get_node_or_null("Site0"), "the spawn rest stop has its cabin")
	assert_eq(_foliage_positions(st).size(), 0, "no trees, bushes or rocks")


# A rest stop's cabin stands back from the road on its pad, door towards the road, is solid, and
# its doorway glows once the rest stop is lit.
func test_a_rest_stops_cabin_faces_the_road_and_glows_once_lit() -> void:
	var s := _settings()
	var st := _streamer(s)
	var i := -1
	for r: int in st.sites.of_kind(RoadSites.Kind.REST):
		if st.sites.anchor[r] != st.sites.pos[r]:
			i = r
			break
	assert_gt(i, -1, "a rest stop beside its road")
	if i < 0:
		return
	st.focus.position = Vector3(st.sites.pos[i].x, 0.0, st.sites.pos[i].y)
	st.prefill()
	var cs: TerrainStreamer.ChunkState = st._chunks[st._chunk_of(st.sites.pos[i])]
	var cabin := cs.foliage.get_node_or_null("Site%d" % i) as Node3D
	assert_not_null(cabin, "the rest stop has its cabin")
	if cabin == null:
		return
	var c := st.sites.pos[i]
	var a := st.sites.anchor[i]
	var at := Vector2(cabin.position.x, cabin.position.z)
	assert_gte((at - c).dot(c - a), 0.0, "on the far side of the pad from the road")
	assert_almost_eq(at.distance_to(c), Config.data.rest_stop_cabin_back_m, 0.01, "set back by the configured distance")
	var door := cabin.basis.z
	assert_gt(Vector2(door.x, door.z).dot(a - at), 0.0, "its door faces the road")
	var body := cabin.get_node_or_null("Body") as StaticBody3D
	assert_not_null(body, "it is solid")
	if body != null:
		assert_true(body.is_in_group(DamageModel.OBSTACLE_GROUP), "and hitting it costs HP")
	var inside := cabin.find_child("Interior", true, false) as MeshInstance3D
	assert_not_null(inside, "the model keeps its interior")
	if inside == null:
		return
	assert_null(inside.material_override, "dark before it is lit")
	st.rest_lit_query = func(_s: int) -> bool: return true
	st.refresh_site_marker(i)
	assert_not_null(inside.material_override, "glowing once lit")


# A rest stop's crowd gathers between its cabin's door and the road, off the road, and is live:
# with the car in among them they scatter from it.
func test_a_rest_stops_crowd_gathers_at_the_cabin_door_and_scatters_from_the_car() -> void:
	var s := _settings()
	var st := _streamer(s)
	var i := -1
	for r: int in st.sites.of_kind(RoadSites.Kind.REST):
		if st.sites.anchor[r] != st.sites.pos[r]:
			i = r
			break
	assert_gt(i, -1, "a rest stop beside its road")
	if i < 0:
		return
	var c := st.sites.pos[i]
	st.focus.position = Vector3(c.x, 0.0, c.y)
	st.prefill()
	var cs: TerrainStreamer.ChunkState = st._chunks[st._chunk_of(c)]
	var crowd := cs.foliage.get_node_or_null("Crowd%d" % i) as SpectatorGroup
	var cabin := cs.foliage.get_node_or_null("Site%d" % i) as Node3D
	assert_not_null(crowd, "the rest stop has a live crowd")
	if crowd == null or cabin == null:
		return
	var at := Vector2(cabin.position.x, cabin.position.z)
	var door := Vector2(cabin.basis.z.x, cabin.basis.z.z)
	var road := st._road_cells_near(at, 40.0)
	var centre := Vector2.ZERO
	for p: Vector2 in crowd._pos:
		assert_gt((p - at).dot(door), TerrainStreamer.CABIN_WALLS.end.z, "in front of the cabin's door wall")
		assert_false(ScatterMath.on_road(p, road), "off the road")
		centre += p
	centre /= crowd._pos.size()
	var spread_before := _mean_distance(crowd, centre)
	st.focus.position = Vector3(centre.x, 0.0, centre.y)  # the car pulls up among them
	for _k in 90:
		await get_tree().physics_frame
	assert_gt(_mean_distance(crowd, centre), spread_before + 0.1, "they back away from the car")


# Mean distance from `from` of the crowd's members still standing.
func _mean_distance(crowd: SpectatorGroup, from: Vector2) -> float:
	var sum := 0.0
	var n := 0
	for k in crowd._pos.size():
		if crowd._upright[k] == 1:
			sum += crowd._pos[k].distance_to(from)
			n += 1
	return sum / maxf(n, 1)


# Planting never beats a collision or near-mesh build, and a far mesh filling a gap in the horizon
# interleaves with planting by distance (far_lead_chunks) instead of waiting behind all of it.
func test_far_gaps_interleave_with_planting_but_never_beat_near_work() -> void:
	var s := _settings()
	s.far_lead_chunks = 2.0
	var st := TerrainStreamer.new()
	st.settings = s
	autofree(st)
	var hole := TerrainStreamer.ChunkState.new()
	var plant_d := 1.0
	var plant := plant_d + TerrainStreamer.PLANT_PRIORITY
	assert_lt(st._far_priority(hole, plant_d + s.far_lead_chunks - 0.1), plant, "a nearer horizon gap goes first")
	assert_gt(st._far_priority(hole, plant_d + s.far_lead_chunks + 0.1), plant, "a further one waits")
	var near_tier_worst := s.near_radius + 0.75 - 100.0
	assert_gt(st._far_priority(hole, 0.0), near_tier_worst, "never ahead of a near mesh or collision")
	hole.near_mesh = MeshInstance3D.new()
	assert_gt(st._far_priority(hole, 0.0), s.far_radius + 0.5 + TerrainStreamer.PLANT_PRIORITY,
		"a far mesh hidden under a near one waits behind all planting")
	hole.near_mesh.free()
