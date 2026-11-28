extends GutTest
# NeutralAssets (tools/neutral_assets.gd): the pieces that turn imported assets into neutral files, on hand-built inputs only.


func _unzip(z: PackedByteArray) -> PackedByteArray:
	var n := z.decode_u32(0)
	return z.slice(4).decompress(n, FileAccess.COMPRESSION_ZSTD) if n > 0 else PackedByteArray()


func test_dump_keeps_colour_and_texture_path() -> void:
	var sh := Shader.new()
	sh.code = "shader_type spatial;\nuniform vec4 tint : source_color;\nuniform sampler2D tex;\nvoid fragment(){ALBEDO=tint.rgb;}"
	var tex := PlaceholderTexture2D.new()
	tex.resource_path = "res://textures/some_texture.png"
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("tint", Color(1, 0.5, 0, 1))
	m.set_shader_parameter("tex", tex)
	var d := NeutralAssets.dump(m)
	assert_eq(d["shader_parameter/tint"], [1.0, 0.5, 0.0, 1.0])
	assert_eq(d["shader_parameter/tex"], "res://textures/some_texture.png")


func _mesh_node(mesh: Mesh, parent: Node) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	parent.add_child(mi)
	return mi


func _triangle() -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


func test_scene_lists_one_node_and_one_mesh() -> void:
	var root := Node3D.new()
	_mesh_node(_triangle(), root)
	var built := NeutralAssets.scene(root)
	root.free()
	assert_eq(built["header"]["nodes"].size(), 1)
	assert_eq(built["header"]["meshes"].size(), 1)
	var names := []
	for s: Array in built["sections"]:
		names.append(s[0])
	assert_true(names.has("m0.s0.vertex"))
	assert_true(names.has("m0.s0.index"))


func test_shared_mesh_is_listed_once() -> void:
	var root := Node3D.new()
	var shared := _triangle()
	_mesh_node(shared, root)
	_mesh_node(shared, root).position = Vector3(5, 0, 0)
	var built := NeutralAssets.scene(root)
	root.free()
	assert_eq(built["header"]["nodes"].size(), 2)
	assert_eq(built["header"]["meshes"].size(), 1)
	assert_eq(built["header"]["nodes"][1]["mesh"], 0)
	assert_eq(built["header"]["nodes"][1]["transform"][9], 5.0)


func test_texture_pixels_section_is_the_image_bytes() -> void:
	var img := Image.create_empty(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.25, 0.5, 0.75, 1.0))
	var built := NeutralAssets.texture(ImageTexture.create_from_image(img), ConfigFile.new())
	var pixels: Array = built["sections"][0]
	assert_eq(pixels[0], "pixels")
	assert_eq(pixels[1], img.get_data())
	assert_eq(_unzip(NeutralFile.zip(pixels[1])), img.get_data())
	assert_eq(built["header"]["format"], "RGBA8")
