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


func _buildings_with_lines(seeds: Array) -> LevelBuildings:
	var entry := {"kind": "start_line", "texts": [], "p": [0, 0, 0, 1, 0, 0, 0, 3, 0], "n": [0, 0, 1, 0, 0, 1, 0, 0, 1], "uv": [0, 0, 1, 0, 0, 1], "c": [1, 1, 1, 1, 1, 1, 1, 1, 1]}
	var list := []
	for s: int in seeds:
		var e := entry.duplicate()
		e.seed = s
		list.append(e)
	var f := FileAccess.open("user://test_rallies_level.buildings.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(list))
	f.close()
	var b := LevelBuildings.new()
	add_child_autofree(b)
	b.setup("user://test_rallies_level.json", func(_x: float, _z: float) -> float: return 0.0)
	return b


func after_all() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_rallies_level.buildings.json"))


func test_only_the_active_rally_shows_its_two_lines() -> void:
	var r := LevelRallies.new()
	add_child_autofree(r)
	LevelRallies.active = ""
	r.setup([_rally("A", Vector2.ZERO), _rally("B", Vector2(0, 900))], Callable(), null, _buildings_with_lines([1, 2]))
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


func test_line_is_one_mesh_turned_to_its_yaw_on_the_ground() -> void:
	var b := _buildings_with_lines([9])
	var line := LevelRallies.line_model({"x": 3.0, "z": 4.0, "yaw": 1.1}, b.start_lines[9], func(_x: float, _z: float) -> float: return 7.5)
	assert_almost_eq(line.rotation.y, 1.1, 1e-5)
	assert_eq(line.position, Vector3(3.0, 7.5, 4.0))
	assert_eq(line.find_children("*", "MeshInstance3D", true, false).size(), 1, "one draw call")
	assert_eq(line.find_children("*", "CollisionShape3D", true, false).size(), 1)
	line.free()


func test_variant_pick_is_stable_and_from_the_baked_seeds() -> void:
	assert_eq(LevelRallies.variant_for("A", "start", []), -1)
	var seeds := [21, 5, 12]
	for name in ["A", "Long Rally Name", ""]:
		for end in ["start", "finish"]:
			var v := LevelRallies.variant_for(name, end, seeds)
			assert_eq(v, LevelRallies.variant_for(name, end, seeds.duplicate()))
			assert_has(seeds, v)


func test_every_rally_end_in_the_shipped_level_has_a_baked_line_to_draw() -> void:
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(SAVE))
	var baked := LevelBuildings.parse_bin(FileAccess.get_file_as_bytes(SAVE.replace(".json", ".buildings.bin")))
	var seeds := baked.filter(func(e: Dictionary) -> bool: return e.get("kind", "") == "start_line").map(func(e: Dictionary) -> int: return int(e.seed))
	if not d.get("rallies", []).is_empty():
		assert_false(seeds.is_empty(), "re-run tools/bake_buildings.js")
	for r: Dictionary in d.get("rallies", []):
		for end in ["start", "finish"]:
			assert_has(seeds, LevelRallies.variant_for(r.name, end, seeds))


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
