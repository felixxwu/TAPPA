extends GutTest
# Level spectator groups: spawn/despawn, placement, model assignment, facing, bake key.

func test_spawn_has_hysteresis() -> void:
	assert_true(LevelSpectators.wants_alive(false, 90.0, 100.0, 140.0))
	assert_false(LevelSpectators.wants_alive(false, 120.0, 100.0, 140.0))
	assert_true(LevelSpectators.wants_alive(true, 120.0, 100.0, 140.0))
	assert_false(LevelSpectators.wants_alive(true, 150.0, 100.0, 140.0))


func test_place_inside_radius_off_road_and_clear() -> void:
	var road := {}
	for cx in range(-60, 60):
		for cz in range(-4, 4):
			road[Vector2i(cx, cz)] = true
	var obstacle := Vector2(10, 10)
	var grid := SpectatorScatter.build_point_grid(PackedVector2Array([obstacle]), 2.0)
	var centre := Vector2(0, 0)
	var pts := LevelSpectators.place(centre, 20.0, 30, 1.0, road, grid, 2.0, 2.0, 5)
	assert_gt(pts.size(), 0)
	for p in pts:
		assert_lte(p.distance_to(centre), 20.0 + 0.001)
		assert_false(ScatterMath.on_road(p, road))
		assert_gte(p.distance_to(obstacle), 2.0)
	assert_eq(pts, LevelSpectators.place(centre, 20.0, 30, 1.0, road, grid, 2.0, 2.0, 5))


func test_models_assigned_across_all_and_stable() -> void:
	var a := LevelSpectators.assign_models(200, 4, 9)
	assert_eq(a, LevelSpectators.assign_models(200, 4, 9))
	var seen := {}
	for m in a:
		assert_true(m >= 0 and m < 4)
		seen[m] = true
	assert_eq(seen.size(), 4)
	assert_eq(LevelSpectators.assign_models(3, 1, 9), PackedInt32Array([0, 0, 0]))


func test_road_cells_follow_surface_callable() -> void:
	var cells := LevelSpectators.road_cells_near(Vector2.ZERO, 10.0, func(_x: float, z: float) -> Vector2: return Vector2(1.0 if absf(z) < 2.0 else 0.0, 0.0))
	assert_true(cells.has(ScatterMath.cell_of(Vector2(3, 0.5))))
	assert_false(cells.has(ScatterMath.cell_of(Vector2(3, 6))))


func test_face_yaw_points_model_front_at_target() -> void:
	var yaw := SpectatorGroup.face_yaw(Vector2(1, 1), Vector2(6, -4))
	var front := Basis(Vector3.UP, yaw) * Vector3.BACK
	var want := Vector3(5, 0, -5).normalized()
	assert_almost_eq(front.dot(want), 1.0, 0.001)


func test_group_with_two_models_faces_car() -> void:
	var car := Node3D.new()
	add_child_autofree(car)
	car.position = Vector3(10, 0, 0)
	var box := BoxMesh.new()
	var sphere := SphereMesh.new()
	var p := Config.data.spectator_params()
	p["face_car"] = true
	p["meshes"] = [box, sphere]
	p["models"] = PackedInt32Array([0, 1, 1])
	p["ragdoll_pool_size"] = 0
	var g := SpectatorGroup.new()
	add_child_autofree(g)
	g.setup(PackedVector2Array([Vector2(0, 0), Vector2(0, 3), Vector2(0, -3)]), car, null, {}, {}, p)
	assert_eq(g._mms.size(), 2)
	assert_eq(g._mms[0].instance_count, 1)
	assert_eq(g._mms[1].instance_count, 2)
	assert_almost_eq(g._yaw[0], PI / 2.0, 0.001)


func test_spectators_not_in_bake_key() -> void:
	var path := "user://spec_key_test.json"
	var write := func(extra: Array) -> void:
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(JSON.stringify({"roads": [], "spectators": extra}))
		f.close()
	write.call([])
	var a := LevelBake.key_of(path)
	write.call([{"x": 1, "z": 2, "r": 5, "n": 10}])
	assert_eq(LevelBake.key_of(path), a)


func _verge_road() -> Dictionary:
	var road := {}
	for cx in range(-80, 80):
		for cz in range(-4, 4):
			road[Vector2i(cx, cz)] = true
	return road


func test_edge_homes_hug_verge_off_road_and_spaced() -> void:
	var road := _verge_road()
	var members := PackedVector2Array()
	for k in 8:
		members.append(Vector2(-6 + k * 1.5, 6.0 + (k % 3) * 0.7))
	var homes := LevelSpectators.edge_homes(members, road, 0.75, 1.5)
	var nearest := 1e9
	for h in homes:
		assert_false(ScatterMath.on_road(h, road))
		nearest = minf(nearest, h.y - 2.0)
	assert_lte(nearest, 0.75 + ScatterMath.CELL_M + 0.001)
	for i in homes.size():
		for j in range(i + 1, homes.size()):
			assert_gte(homes[i].distance_to(homes[j]), 1.5 - 0.001)
	assert_eq(homes, LevelSpectators.edge_homes(members, road, 0.75, 1.5))


func test_edge_homes_member_with_no_room_stays() -> void:
	var road := _verge_road()
	var members := PackedVector2Array([Vector2(0, 2.0 + 0.25 + 0.75), Vector2(0, 3.2)])
	var homes := LevelSpectators.edge_homes(members, road, 0.75, 1.5)
	assert_eq(homes[1], members[1])


func test_edge_homes_without_road_keeps_members() -> void:
	var members := PackedVector2Array([Vector2(1, 1)])
	assert_eq(LevelSpectators.edge_homes(members, {}, 0.75, 1.5), members)


class _NobodyPlaced extends LevelSpectators:
	var tries := 0
	func _place_job(job: Dictionary) -> void:
		tries += 1
		job["members"] = PackedVector2Array()

	func settle_refresh(at: Vector2) -> void:
		refresh(at)
		while not _pending.is_empty():
			_collect_placed()


func test_a_group_that_places_nobody_is_not_retried_until_the_car_leaves() -> void:
	var s := _NobodyPlaced.new()
	add_child_autofree(s)
	s.groups = [{"x": 0.0, "z": 0.0, "r": 5.0, "n": 3}]
	s.settle_refresh(Vector2.ZERO)
	s.settle_refresh(Vector2.ZERO)
	assert_eq(s.tries, 1)
	s.settle_refresh(Vector2(Config.data.level_spectator_despawn_m + 1.0, 0.0))
	s.settle_refresh(Vector2.ZERO)
	assert_eq(s.tries, 2, "coming back tries again")
	assert_eq(s.live_count(), 0)


func _steer_group(n: int) -> SpectatorGroup:
	var car := Node3D.new()
	add_child_autofree(car)
	var p := Config.data.spectator_params()
	p["meshes"] = [BoxMesh.new()]
	p["models"] = PackedInt32Array(range(n)).duplicate()
	p["models"].fill(0)
	p["ragdoll_pool_size"] = 0
	var homes := PackedVector2Array()
	for i in n:
		homes.append(Vector2(i * 0.3, (i % 3) * 0.2))
	var g := SpectatorGroup.new()
	add_child_autofree(g)
	g.setup(homes, car, null, {}, {}, p)
	return g


func _steer_inputs(g: SpectatorGroup) -> Dictionary:
	var p := g._p
	var r: float = p["separation_m"]
	return {"car": Vector2(1.0, 0.5), "step": 0.05, "max_speed": p["max_speed_mps"], "accel": p["accel_mps2"],
		"sep_grid": SpectatorGroup.build_separation_grid(g._pos, g._upright, r), "sep_radius": r,
		"flee_radius": p["flee_radius_m"], "w_flee": p["w_flee"], "road_probe": p["road_probe_m"], "w_road": p["w_road"],
		"tree_cell": p["tree_cell_m"], "tree_avoid": p["tree_avoid_m"], "w_obstacle": p["w_obstacle"],
		"w_separation": p["w_separation"], "dead_zone": p["anchor_dead_zone_m"], "w_anchor": p["w_anchor"]}


func test_wide_steering_matches_steering_members_one_by_one() -> void:
	var g := _steer_group(12)
	var k := _steer_inputs(g)
	g._steer_wide(k)
	var wide := g._nvel.duplicate()
	var one := _steer_group(12)
	one._nvel.resize(12)
	for i in 12:
		one._steer_member(i, _steer_inputs(one))
	assert_eq(wide, one._nvel)


func test_wide_steering_is_off_below_the_member_threshold_and_with_the_toggle_off() -> void:
	var g := _steer_group(4)
	var saved_min: int = Config.data.threaded_spectator_min_members
	var saved_on: bool = Config.data.threaded_spectators
	Config.data.threaded_spectators = true
	Config.data.threaded_spectator_min_members = 5
	assert_false(g._wide_ok())
	Config.data.threaded_spectator_min_members = 4
	assert_eq(g._wide_ok(), OS.has_feature("threads"))
	Config.data.threaded_spectators = false
	assert_false(g._wide_ok())
	Config.data.threaded_spectator_min_members = saved_min
	Config.data.threaded_spectators = saved_on


func _pooled_group(pool: CrowdPool, at: Array, models: Array) -> SpectatorGroup:
	var p := Config.data.spectator_params()
	p["pool"] = pool
	p["meshes"] = [BoxMesh.new(), SphereMesh.new()]
	p["models"] = PackedInt32Array(models)
	p["ragdoll_pool_size"] = 0
	var g := SpectatorGroup.new()
	add_child_autofree(g)
	g.setup(PackedVector2Array(at), null, null, {}, {}, p)
	return g


func _pool() -> CrowdPool:
	var host := Node3D.new()
	add_child_autofree(host)
	return CrowdPool.new(host, [BoxMesh.new(), SphereMesh.new()] as Array[Mesh])


func test_groups_share_one_multimesh_per_model() -> void:
	var pool := _pool()
	var a := _pooled_group(pool, [Vector2(0, 0), Vector2(5, 0)], [0, 1])
	var b := _pooled_group(pool, [Vector2(50, 0), Vector2(55, 0)], [0, 1])
	assert_eq(a._mms.size(), 0)
	assert_eq(a._pool, b._pool)
	assert_eq(pool.model_count(), 2)
	assert_ne(a._slot[0], b._slot[0])
	assert_gte(pool.multimesh(0).instance_count, 2)


func test_members_write_their_own_slots() -> void:
	var pool := _pool()
	var a := _pooled_group(pool, [Vector2(0, 0), Vector2(5, 0)], [0, 0])
	var b := _pooled_group(pool, [Vector2(50, 0)], [0])
	assert_almost_eq(pool.slot_xf(0, a._slot[1]).origin.x, 5.0, 0.001)
	assert_almost_eq(pool.slot_xf(0, b._slot[0]).origin.x, 50.0, 0.001)
	a._pos[0] = Vector2(9, 0)
	a._write_instance(0)
	assert_almost_eq(pool.slot_xf(0, a._slot[0]).origin.x, 9.0, 0.001)
	assert_almost_eq(pool.slot_xf(0, a._slot[1]).origin.x, 5.0, 0.001)
	assert_almost_eq(pool.slot_xf(0, b._slot[0]).origin.x, 50.0, 0.001)


func test_despawned_group_releases_slots_for_reuse() -> void:
	var pool := _pool()
	var a := _pooled_group(pool, [Vector2(0, 0), Vector2(5, 0)], [0, 0])
	var slots := [a._slot[0], a._slot[1]]
	var free_before := pool.free_count(0)
	remove_child(a)
	assert_eq(pool.free_count(0), free_before + 2)
	for s in slots:
		assert_eq(pool.slot_xf(0, s).basis, Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO))
	var cap := pool.multimesh(0).instance_count
	var b := _pooled_group(pool, [Vector2(20, 0), Vector2(25, 0)], [0, 0])
	assert_eq(pool.multimesh(0).instance_count, cap)
	assert_true(b._slot[0] in slots and b._slot[1] in slots)
	a.free()


func test_growth_keeps_existing_transforms() -> void:
	var pool := _pool()
	var a := _pooled_group(pool, [Vector2(7, 0)], [0])
	var big: Array = []
	for k in 100:
		big.append(Vector2(100 + k, 0))
	var models: Array = []
	models.resize(100)
	models.fill(0)
	_pooled_group(pool, big, models)
	assert_almost_eq(pool.slot_xf(0, a._slot[0]).origin.x, 7.0, 0.001)
