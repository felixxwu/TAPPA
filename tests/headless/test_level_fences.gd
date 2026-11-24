extends GutTest
# Docs: features/level-editor.md ("Fences and hedges")
# LevelFences on a synthetic flat level with one road along z = 0.

var _data := LevelData.new()


func before_all() -> void:
	_data.load_save({"size": 600, "road": [{"x": -100.0, "z": 0.0, "w": 3.0, "m": null, "tension": 1.0},
		{"x": 100.0, "z": 0.0, "w": 3.0, "m": null, "tension": 1.0}]}, false)


func _built(fences: Array) -> LevelFences:
	var f := LevelFences.new()
	add_child_autofree(f)
	f.setup(fences, _data, func(_x: float, _z: float) -> float: return 0.0)
	return f


func _shape_count(f: LevelFences) -> int:
	var n := 0
	for b in f.bodies:
		n += b.get_child_count()
	return n


func _named(f: LevelFences, prefix: String) -> int:
	return f.meshes.filter(func(m: MeshInstance3D) -> bool: return m.name.begins_with(prefix)).size()


func test_a_fence_and_a_hedge_become_chunk_meshes_with_colliders() -> void:
	var f := _built([{"kind": "fence", "pts": [[20, 30], [40, 30]]}, {"kind": "hedge", "pts": [[20, 50], [30, 50]]}])
	assert_eq(_named(f, "Mesh"), 1, "posts and hedge share one chunk mesh")
	assert_gt(_named(f, "Net"), 0, "the netting gets its own short-range mesh")
	for m in f.meshes:
		assert_gt(m.visibility_range_end, 0.0)
	var spans := ceili(20.0 / LevelFences.POST_STEP) + ceili(10.0 / LevelFences.HEDGE_STEP)
	assert_eq(_shape_count(f), spans, "one collider per fence span and per hedge piece")


func test_chunks_split_by_distance() -> void:
	var f := _built([{"kind": "fence", "pts": [[20, 30], [30, 30]]}, {"kind": "fence", "pts": [[400, 30], [410, 30]]}])
	assert_eq(_named(f, "Mesh"), 2)


func test_a_fence_crossing_a_road_leaves_the_road_clear() -> void:
	var f := _built([{"kind": "fence", "pts": [[0, -20], [0, 20]]}, {"kind": "hedge", "pts": [[10, -20], [10, 20]]}])
	for b in f.bodies:
		for cs: CollisionShape3D in b.get_children():
			var c := cs.position
			assert_gt(absf(c.z), 1.5, "no collider sits on the carriageway")
	assert_gt(_shape_count(f), 0, "the parts away from the road remain")
	assert_lt(_shape_count(f), ceili(40.0 / LevelFences.POST_STEP) + ceili(40.0 / LevelFences.HEDGE_STEP), "the spans over the road are gone")


func test_an_empty_or_one_point_line_builds_nothing() -> void:
	var f := _built([{"kind": "fence", "pts": [[1, 1]]}])
	assert_eq(f.meshes.size(), 0)


func test_the_bake_key_ignores_fences() -> void:
	var path := "user://test_fences_key.json"
	var key := func(extra: Dictionary) -> String:
		var d := {"size": 100, "roads": []}
		d.merge(extra)
		var w := FileAccess.open(path, FileAccess.WRITE)
		w.store_string(JSON.stringify(d))
		w.close()
		return LevelBake.key_of(path)
	assert_eq(key.call({}), key.call({"fences": [{"kind": "hedge", "pts": [[0, 0], [5, 5]]}]}))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
