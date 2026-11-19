extends GutTest
# The level-editor save driven in place of free roam (features/level-editor.md): unpacking the lab's
# save format, the ground built around the road, the trees, and the dev toggle's redirect.
# Every level here is synthetic; nothing reads the shipped Hafren save.

var _toggle: bool


func before_each() -> void:
	_toggle = Config.data.dev_level_instead_of_free_roam


func after_each() -> void:
	Config.data.dev_level_instead_of_free_roam = _toggle


# A straight road along x through the middle of a flat square, with a hill grid that's flat at `ground`.
func _level(ground := 0.0) -> Dictionary:
	var hm: Array = []
	hm.resize((LevelView.LAB_N + 1) * (LevelView.LAB_N + 1))
	hm.fill(ground)
	return {"road": [{"x": -100.0, "z": 0.0, "w": 3.0, "m": null, "tension": 1.0},
			{"x": 100.0, "z": 0.0, "w": 3.0, "m": null, "tension": 1.0}],
		"trees": [{"x": 0.0, "z": 50.0, "rot": 0.0, "sx": 1.0, "sy": 1.0, "kind": "tree.png"},
			{"x": 10.0, "z": 50.0, "rot": 90.0, "sx": 1.0, "sy": 2.0, "kind": "tree.png"}],
		"heightmap": hm}


func _built(level: Dictionary) -> LevelView:
	var view := LevelView.new()
	view.grid_step = 10.0  # coarse: the logic doesn't need the game's fine grid
	view.load_level(level)
	autofree(view)
	return view


func test_unpack_restores_trees_and_the_height_grid() -> void:
	var raw := PackedByteArray()
	raw.resize(4)
	raw.encode_s16(0, 15)
	raw.encode_s16(2, -20)
	var packed := {"kinds": ["a.png", "b.png"], "trees": [[1.5, -2.0, 30, 1.2, 0.8, 1]],
		"heightmap": Marshalls.raw_to_base64(raw)}
	var out := LevelView.unpack(packed)
	assert_eq(out["trees"][0]["kind"], "b.png")
	assert_almost_eq(float(out["trees"][0]["x"]), 1.5, 1e-6)
	assert_false(out.has("kinds"))
	assert_almost_eq(out["heightmap"][0], 1.5, 1e-6, "decimetres become metres")
	assert_almost_eq(out["heightmap"][1], -2.0, 1e-6)


func test_the_road_is_road_and_the_field_beside_it_is_not() -> void:
	var view := _built(_level())
	assert_gt(view.surface_at(0.0, 0.0).x, 0.9, "on the centreline")
	assert_lt(view.surface_at(0.0, 40.0).x, 0.01, "well off it")


func test_ground_is_pulled_to_the_road_level_and_left_alone_far_from_it() -> void:
	var view := _built(_level(10.0))
	assert_almost_eq(view.height_at(0.0, 0.0), 10.0, 0.2, "the road sits on the saved ground")
	assert_almost_eq(view.height_at(0.0, 200.0), 10.0, 0.01, "far ground is the saved grid")


func test_each_species_becomes_one_multimesh_with_every_tree() -> void:
	var view := _built(_level())
	var meshes := view.get_children().filter(func(c: Node) -> bool: return c is MultiMeshInstance3D)
	assert_eq(meshes.size(), 1)
	assert_eq((meshes[0] as MultiMeshInstance3D).multimesh.instance_count, 2)


func test_the_car_starts_on_the_first_node_facing_the_second() -> void:
	var view := _built(_level())
	var pose := view.spawn_pose()
	assert_almost_eq(pose.origin.x, -100.0, 0.01)
	assert_gt(-pose.basis.z.x, 0.99, "forward (-Z) points along the road")


func test_the_toggle_sends_world_entry_to_the_level() -> void:
	Config.data.dev_level_instead_of_free_roam = true
	Scenes.change_to(get_tree(), Scenes.FREE_ROAM)
	assert_eq(Scenes.last_blocked_path, Scenes.LEVEL_VIEW)
	Config.data.dev_level_instead_of_free_roam = false
	Scenes.change_to(get_tree(), Scenes.FREE_ROAM)
	assert_eq(Scenes.last_blocked_path, Scenes.FREE_ROAM)


func test_a_baked_level_draws_only_the_trees_seen_from_the_nearest_stretch_of_road() -> void:
	var unbaked := _built(_level())
	unbaked.show_from(Vector3(-100.0, 0.0, 0.0))
	assert_eq(_counts(unbaked), [-1], "without a bake every tree is drawn")
	var level := _level()
	level["trees"].append({"x": 20.0, "z": 50.0, "rot": 0.0, "sx": 1.0, "sy": 1.0, "kind": "tree-greece.webp"})
	var rows: Array = [[0], [2]]  # viewpoint row 0 sees tree 0, row 1 sees tree 2 (the other species), the rest nothing
	for _i in 30:
		rows.append([])
	level["visibility"] = {"key": 1, "every": 4, "rows": rows}
	var view := _built(JSON.parse_string(JSON.stringify(level)))  # through JSON, so the ids arrive as floats like a real save
	view.show_from(Vector3(-100.0, 0.0, 0.0))  # first stretch: rows 0 and 1
	assert_eq(_counts(view), [1, 1])
	view.show_from(Vector3(-94.0, 0.0, 30.0))  # ~5 samples along, beside the road: rows 1 and 2
	assert_eq(_counts(view), [0, 1])
	view.show_from(Vector3(100.0, 0.0, 0.0))  # the far end: no row there saw anything
	assert_eq(_counts(view), [0, 0])


# Each species MultiMesh's drawn-instance count, in the order they were built.
func _counts(view: LevelView) -> Array:
	var out := []
	for c in view.get_children():
		if c is MultiMeshInstance3D:
			out.append((c as MultiMeshInstance3D).multimesh.visible_instance_count)
	return out


func test_the_level_scene_arms_its_pause_menu() -> void:
	var path := "user://test_level_view_level.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(_level()))
	f.close()
	var world: Node = (load(Scenes.LEVEL_VIEW) as PackedScene).instantiate()
	world.get_node("Level").level_path = path
	add_child_autofree(world)
	await wait_physics_frames(3)
	assert_true(world.get_node("PauseMenu").is_armed(), "Esc / Start open the pause menu")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_the_flat_margin_setting_moves_where_the_ground_rises_beside_the_road() -> void:
	var level := _level()
	for node: Dictionary in level["road"]:
		node["w"] = 8.0
	var hm: Array = level["heightmap"]
	var cell := LevelView.SIZE / LevelView.LAB_N
	for r in LevelView.LAB_N + 1:
		for c in LevelView.LAB_N + 1:
			hm[r * (LevelView.LAB_N + 1) + c] = absf(r * cell - LevelView.SIZE / 2.0) * 0.5  # a valley along the road
	var saved: float = Config.data.level_road_flat_margin
	var probe_z := 10.0  # 2 m past the road's edge, on a vertex of the test's 10 m grid
	Config.data.level_road_flat_margin = 3.0
	var wide := _built(level).height_at(0.0, probe_z)
	Config.data.level_road_flat_margin = 0.0
	var none := _built(level).height_at(0.0, probe_z)
	Config.data.level_road_flat_margin = saved
	assert_lt(wide, 0.5, "inside the margin the ground stays at road height")
	assert_gt(none, 2.0, "with no margin it is back on the valley side")
