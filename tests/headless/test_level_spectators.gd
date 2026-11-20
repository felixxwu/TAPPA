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
	func _spawn(_i: int, _g: Dictionary) -> SpectatorGroup:
		tries += 1
		return null


func test_a_group_that_places_nobody_is_not_retried_until_the_car_leaves() -> void:
	var s := _NobodyPlaced.new()
	add_child_autofree(s)
	s.groups = [{"x": 0.0, "z": 0.0, "r": 5.0, "n": 3}]
	s.refresh(Vector2.ZERO)
	s.refresh(Vector2.ZERO)
	assert_eq(s.tries, 1)
	s.refresh(Vector2(Config.data.level_spectator_despawn_m + 1.0, 0.0))
	s.refresh(Vector2.ZERO)
	assert_eq(s.tries, 2, "coming back tries again")
	assert_eq(s.live_count(), 0)
