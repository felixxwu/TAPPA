extends GutTest
# BillboardField.size_factor(idx) exposes the per-instance size jitter the felling /
# plough-through path reads. Logic only — no tuned values pinned. Built against a
# synthetic position list + a bare terrain (height is irrelevant: size_factor is a
# pure hash of the instance XZ).

const TEX := preload("res://textures/tree.png")


func _build_field(size_min: float) -> BillboardField:
	var terrain := TerrainManager.new()
	terrain.focus_path = NodePath("")
	add_child_autofree(terrain)
	var field := BillboardField.new()
	add_child_autofree(field)
	var positions := PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(20, 0)])
	var mesh := Foliage.tree_silhouette_mesh(TEX)
	field.build(positions, terrain, Vector2(5, 5), TEX, 1.0, 4.0, true,
		200.0, 10.0, 0.0, mesh, true, size_min)
	return field


func test_size_factor_in_jitter_range_and_matches_internal() -> void:
	var field := _build_field(0.3)
	for i in field.instance_positions.size():
		var f := field.size_factor(i)
		assert_true(f >= 0.3 - 1e-6 and f <= 1.0 + 1e-6, "factor within [min,1]")
		assert_almost_eq(f, field._size_factor(field.instance_positions[i]), 1e-6,
			"accessor matches the internal hashed factor")


func test_size_factor_is_one_when_jitter_disabled() -> void:
	var field := _build_field(1.0)
	for i in field.instance_positions.size():
		assert_almost_eq(field.size_factor(i), 1.0, 1e-6, "jitter disabled -> full size")


func test_size_factor_bad_index_is_one() -> void:
	var field := _build_field(0.3)
	assert_almost_eq(field.size_factor(-1), 1.0, 1e-6, "negative index -> 1.0")
	assert_almost_eq(field.size_factor(9999), 1.0, 1e-6, "out-of-range index -> 1.0")


# The opaque billboard material must carry the shared sun/ambient uniforms so trees
# take the same light model as the terrain. Contract only — we assert the params are
# present/populated (wiring didn't drop them), never their tunable values.
func test_opaque_material_has_sun_uniforms() -> void:
	var field := _build_field(1.0)
	var mat := field.render_mesh.surface_get_material(0) as ShaderMaterial
	assert_not_null(mat, "opaque field builds a ShaderMaterial")
	for p in ["sun_dir", "sun_color", "sky_color", "ground_color", "light_amount"]:
		assert_ne(mat.get_shader_parameter(p), null, "material sets uniform '%s'" % p)
