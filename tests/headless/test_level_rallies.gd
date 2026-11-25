extends GutTest
# Level rallies: only the active rally's start and finish lines show, with crowds beside them; the save's rally ends sit on gravel pads.

const SAVE := "res://tools/levels/hafren_5km.json"

var _was := ""


func before_each() -> void:
	_was = LevelRallies.active


func after_each() -> void:
	LevelRallies.active = _was


func _rally(name: String, at: Vector2) -> Dictionary:
	return {"name": name, "start": {"x": at.x, "z": at.y, "yaw": 0.3}, "finish": {"x": at.x + 500.0, "z": at.y, "yaw": -1.2}}


func test_only_the_active_rally_shows_its_two_lines() -> void:
	var r := LevelRallies.new()
	add_child_autofree(r)
	LevelRallies.active = ""
	r.setup([_rally("A", Vector2.ZERO), _rally("B", Vector2(0, 900))], Callable(), null)
	assert_eq(r.get_child_count(), 0)
	LevelRallies.active = "B"
	r.show_active()
	await get_tree().process_frame
	assert_eq(r.get_child_count(), 2)
	var xs := [r.get_child(0).position.x, r.get_child(1).position.x]
	assert_true(500.0 in xs and 0.0 in xs)
	assert_eq(r.get_child(0).position.z, 900.0)
	LevelRallies.active = "nope"
	r.show_active()
	await get_tree().process_frame
	assert_eq(r.get_child_count(), 0)


func test_line_turned_to_its_yaw_on_the_ground() -> void:
	var line := LevelRallies.line_model({"x": 3.0, "z": 4.0, "yaw": 1.1}, LevelRallies.MODELS[0], func(_x: float, _z: float) -> float: return 7.5)
	assert_almost_eq(line.rotation.y, 1.1, 1e-5)
	assert_eq(line.position, Vector3(3.0, 7.5, 4.0))
	assert_gt(line.get_child_count(), 0, "the model loads")
	line.free()


func test_model_pick_is_stable_and_from_the_pool() -> void:
	for name in ["A", "Long Rally Name", ""]:
		for end in ["start", "finish"]:
			assert_eq(LevelRallies.model_for(name, end), LevelRallies.model_for(name, end))
			assert_has(LevelRallies.MODELS, LevelRallies.model_for(name, end))
	for path: String in LevelRallies.MODELS:
		assert_true(ResourceLoader.exists(path), path)


func test_crowds_flank_the_line_and_skip_the_start_control() -> void:
	var e := {"x": 100.0, "z": -50.0, "yaw": 0.7}
	var groups := LevelRallies.crowd_groups(e)
	assert_gt(groups.size(), 0)
	var basis := Basis(Vector3.UP, 0.7)
	var sides := {}
	for g: Dictionary in groups:
		var local := basis.inverse() * Vector3(g.x - 100.0, 0.0, g.z + 50.0)
		assert_almost_eq(absf(local.x), LevelRallies.CROWD_SIDE_M, 1e-3)
		assert_true(local.z < LevelRallies.CONTROL_ZONE.x or local.z > LevelRallies.CONTROL_ZONE.y)
		assert_lte(absf(local.z), LevelRallies.AREA_HALF_L)
		sides[signf(local.x)] = true
	assert_eq(sides.size(), 2, "both sides of the road")


func test_extra_spectator_groups_replace_without_touching_the_saves() -> void:
	var s := LevelSpectators.new()
	add_child_autofree(s)
	var own := [{"x": 0.0, "z": 0.0, "r": 5.0, "n": 3}]
	s.setup(own, null, null, null)
	s.set_extra([{"x": 1.0, "z": 1.0, "r": 2.0, "n": 1}, {"x": 2.0, "z": 2.0, "r": 2.0, "n": 1}])
	assert_eq(s.groups.size(), 3)
	s.set_extra([])
	assert_eq(s.groups, own)
	assert_eq(own.size(), 1)


func test_every_rally_end_in_the_save_stands_on_a_gravel_pad() -> void:
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(SAVE))
	var patches := LevelData.parse_patches(d.get("gravelPatches", []))
	var names := {}
	for r: Dictionary in d.get("rallies", []):
		assert_false(names.has(r.name), "rally names are unique")
		names[r.name] = true
		for end in ["start", "finish"]:
			var e: Dictionary = r[end]
			var inside := patches.any(func(p: PackedVector2Array) -> bool: return LevelData.polygon_distance(p, e.x, e.z) < 0.0)
			assert_true(inside, "%s %s on a pad" % [r.name, end])


func test_rallies_are_left_out_of_the_bake_key() -> void:
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(SAVE))
	var path := "user://rally_key_test.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(d))
	f.close()
	var before := LevelBake.key_of(path)
	d["rallies"] = []
	f = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(d))
	f.close()
	assert_eq(LevelBake.key_of(path), before)
	DirAccess.remove_absolute(path)


func test_collider_keeps_standing_triangles_and_drops_flat_paint() -> void:
	var model := Node3D.new()
	var tall := MeshInstance3D.new()
	tall.mesh = BoxMesh.new()
	tall.position.y = 1.0
	model.add_child(tall)
	var paint := MeshInstance3D.new()
	paint.mesh = PlaneMesh.new()
	model.add_child(paint)
	var body := LevelRallies.collider(model)
	var shape := (body.get_child(0) as CollisionShape3D).shape as ConcavePolygonShape3D
	assert_eq(shape.get_faces().size(), tall.mesh.get_faces().size(), "only the box above the road is solid")
	body.free()
	model.free()
