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
	assert_eq(b.find_children("*", "StaticBody3D", false, false).size(), 2)
	var body := b.get_child(0) as StaticBody3D
	assert_lt(body.position.y, 10.0 - 8.0 / 2 * cos(0.5) + 0.01, "seated at the lowest corner, not the centre")
	var box := (body.get_child(0) as CollisionShape3D).shape as BoxShape3D
	assert_almost_eq(box.size.y, 3.0, 0.001)
	assert_eq(b.find_children("*", "MeshInstance3D", true, false), [b.mesh], "both drawn by one merged mesh")
	var arrays := (b.mesh.mesh as ArrayMesh).surface_get_arrays(0)
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	assert_true(uvs.has(Vector2(1, 1)) and not uvs.has(Vector2(1, 0)), "texture V flipped from three.js (bottom-up) to Godot (top-down)")
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	assert_eq(verts.size(), 6)
	assert_almost_eq(verts[0].distance_to(body.transform * Vector3.ZERO), 0.0, 0.001, "placed where its body stands")


func test_a_level_without_a_building_bake_builds_nothing() -> void:
	var b := LevelBuildings.new()
	add_child_autofree(b)
	b.setup("user://no_such_level.json", func(_x: float, _z: float) -> float: return 0.0)
	assert_eq(b.get_child_count(), 0)
	assert_null(b.mesh)


func test_a_baked_shop_stands_on_the_ground_with_a_collider_text_and_a_place_in_the_one_mesh() -> void:
	var tri := {"p": [0, 0, 0, 1, 0, 0, 0, 3, 0], "n": [0, 0, 1, 0, 0, 1, 0, 0, 1], "uv": [0, 0, 1, 0, 0, 1], "c": [1, 1, 1, 1, 1, 1, 1, 1, 1]}
	var house := tri.duplicate()
	house.merge({"x": 10.0, "z": -5.0, "rot": 0.0, "L": 8.0, "W": 4.0})
	var shop := tri.duplicate()
	shop.merge({"kind": "shop", "shop": 3, "x": 1.0, "z": 2.0, "yaw": 0.5, "box": [-1.0, 2.0, -3.0, 3.0, 4.0],
		"texts": [{"text": "Sign", "color": "#b02a1a", "w": 0.5, "h": 0.2, "p": [1.0, 2.0, 3.0], "q": [0, 0, 0, 1]}]})
	var f := FileAccess.open("user://test_buildings_level.buildings.json", FileAccess.WRITE)
	f.store_string(JSON.stringify([house, shop]))
	f.close()
	var b := LevelBuildings.new()
	add_child_autofree(b)
	b.setup(SAVE, func(_x: float, _z: float) -> float: return 7.0)
	var built: Dictionary = b.shops[3]
	var body: StaticBody3D = built.body
	assert_eq(body.position, Vector3(1.0, 7.0, 2.0), "seated on the ground at its origin")
	assert_almost_eq(body.rotation.y, 0.5, 0.0001)
	var shape := body.find_children("*", "CollisionShape3D", false, false)[0] as CollisionShape3D
	assert_eq((shape.shape as BoxShape3D).size, Vector3(3.0, 4.0, 6.0), "over the building's box")
	assert_eq(shape.position, Vector3(0.5, 2.0, 0.0))
	assert_eq((body.find_children("*", "Label3D", false, false)[0] as Label3D).text, "Sign", "text drawn by the game")
	assert_eq(((b.mesh.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(), 6, "house and shop share one surface")
	assert_eq(b.boxes.size(), 2, "the shop's footprint is stamped like a building's")


func test_every_shop_with_a_model_in_the_shipped_level_has_a_baked_entry() -> void:
	var lv: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(Config.data.level_path))
	var baked := LevelBuildings.parse_bin(FileAccess.get_file_as_bytes(Config.data.level_path.replace(".json", ".buildings.bin")))
	var have := baked.filter(func(e: Dictionary) -> bool: return e.get("kind", "") == "shop").map(func(e: Dictionary) -> int: return int(e.shop))
	var shops: Array = lv.get("shops", [])
	for i in shops.size():
		if shops[i].get("model") is Dictionary and shops[i]["model"].has("seed"):
			assert_true(i in have, "%s is baked (re-run tools/bake_buildings.js)" % shops[i].get("name", "a shop"))


func _line_entry(seed: int) -> Dictionary:
	return {"kind": "start_line", "seed": seed, "texts": [{"text": "START", "color": "#ffffff", "w": 1.0, "h": 0.3, "p": [0, 2, 0], "q": [0, 0, 0, 1]}],
		"p": [0, 0, 0, 1, 0, 0, 0, 3, 0, 0, 0, 0, 1, 0, 0, 0, 0.1, 0], "n": [0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1],
		"uv": [0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1], "c": [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]}


func test_a_baked_start_line_is_its_own_surface_with_a_collider_over_only_what_stands_up() -> void:
	var f := FileAccess.open("user://test_buildings_level.buildings.json", FileAccess.WRITE)
	f.store_string(JSON.stringify([_line_entry(4)]))
	f.close()
	var b := LevelBuildings.new()
	add_child_autofree(b)
	b.setup(SAVE, func(_x: float, _z: float) -> float: return 0.0)
	assert_null(b.mesh, "not part of the always-on merged mesh")
	assert_eq(b.get_child_count(), 0)
	var line: Dictionary = b.start_lines[4]
	var am: ArrayMesh = line.mesh
	assert_eq(am.get_surface_count(), 1)
	assert_eq(am.surface_get_material(0), b.material, "the buildings' material")
	assert_eq((am.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(), 6)
	assert_eq((line.shape as ConcavePolygonShape3D).get_faces().size(), 3, "the flat triangle is not solid")
	assert_eq(line.texts.size(), 1)


func _pack(entries: Array) -> PackedByteArray:
	var meta := []
	var floats := PackedFloat32Array()
	for e: Dictionary in entries:
		var m := e.duplicate()
		for k in ["p", "n", "uv", "c"]:
			floats.append_array(PackedFloat32Array(m[k]))
			m.erase(k)
		m["np"] = e.p.size()
		meta.append(m)
	var head := JSON.stringify(meta).to_utf8_buffer()
	while (4 + head.size()) % 4 != 0:
		head.append(32)
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u32(0, head.size())
	out.append_array(head)
	out.append_array(floats.to_byte_array())
	return out


func test_a_binary_bake_loads_into_the_same_mesh_and_colliders_as_json() -> void:
	var tri := {"p": [0, 0, 0, 1, 0, 0, 0, 3, 0], "n": [0, 0, 1, 0, 0, 1, 0, 0, 1], "uv": [0, 0, 1, 0, 0, 1], "c": [1, 1, 1, 1, 1, 1, 1, 1, 1]}
	var a := tri.duplicate()
	a.merge({"x": 10.0, "z": -5.0, "rot": 0.5, "L": 8.0, "W": 4.0})
	var shop := tri.duplicate()
	shop.merge({"kind": "shop", "shop": 3, "x": 1.0, "z": 2.0, "yaw": 0.5, "box": [-1.0, 2.0, -3.0, 3.0, 4.0], "texts": []})
	var parsed := LevelBuildings.parse_bin(_pack([a, shop]))
	assert_eq(parsed.size(), 2)
	assert_eq((parsed[0].p as PackedFloat32Array).size(), 9)
	assert_eq(parsed[1].uv, PackedFloat32Array([0, 0, 1, 0, 0, 1]))
	assert_eq(int(parsed[1].shop), 3)
	var f := FileAccess.open("user://test_buildings_level.buildings.bin", FileAccess.WRITE)
	f.store_buffer(_pack([a, shop]))
	f.close()
	var b := LevelBuildings.new()
	add_child_autofree(b)
	b.setup(SAVE, func(_x: float, _z: float) -> float: return 0.0)
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_buildings_level.buildings.bin"))
	assert_eq(b.find_children("*", "StaticBody3D", false, false).size(), 2)
	assert_true(b.shops.has(3))
	assert_eq(((b.mesh.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(), 6)
