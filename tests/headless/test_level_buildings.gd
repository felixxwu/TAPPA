extends GutTest

const SAVE := "user://test_buildings_level.json"


func after_all() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_buildings_level.buildings.json"))


func test_each_baked_building_sits_on_the_lowest_ground_under_it_with_a_collider() -> void:
	var tri := {"p": [0, 0, 0, 1, 0, 0, 0, 3, 0], "n": [0, 0, 1, 0, 0, 1, 0, 0, 1], "uv": [0, 0, 1, 0, 0, 1], "c": [1, 1, 1, 1, 1, 1, 1, 1, 1]}
	var a := tri.duplicate()
	a.merge({"x": 10.0, "z": -5.0, "rot": 0.5, "L": 8.0, "W": 4.0})
	var f := FileAccess.open("user://test_buildings_level.buildings.json", FileAccess.WRITE)
	f.store_string(JSON.stringify([a, a]))
	f.close()
	var b := LevelBuildings.new()
	add_child_autofree(b)
	b.setup(SAVE, func(x: float, _z: float) -> float: return x)
	assert_eq(b.get_child_count(), 2)
	var body := b.get_child(0) as StaticBody3D
	assert_lt(body.position.y, 10.0 - 8.0 / 2 * cos(0.5) + 0.01, "seated at the lowest corner, not the centre")
	var box := (body.get_child(1) as CollisionShape3D).shape as BoxShape3D
	assert_almost_eq(box.size.y, 3.0, 0.001)
	var uvs: PackedVector2Array = ((body.get_child(0) as MeshInstance3D).mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_TEX_UV]
	assert_true(uvs.has(Vector2(1, 1)) and not uvs.has(Vector2(1, 0)), "texture V flipped from three.js (bottom-up) to Godot (top-down)")


func test_a_level_without_a_building_bake_builds_nothing() -> void:
	var b := LevelBuildings.new()
	add_child_autofree(b)
	b.setup("user://no_such_level.json", func(_x: float, _z: float) -> float: return 0.0)
	assert_eq(b.get_child_count(), 0)
