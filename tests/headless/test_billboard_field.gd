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


# Each tree cutout mode draws with its own shader; the alpha ones on a plain card, not the
# traced silhouette.
func test_each_tree_cutout_mode_picks_its_shader_and_mesh() -> void:
	var shaders := [BillboardField.BILLBOARD_OPAQUE_SHADER, BillboardField.BILLBOARD_ALPHA_SHADER,
		BillboardField.BILLBOARD_BLEND_SHADER]
	var was: int = Config.data.tree_cutout_mode
	Config.data.tree_cutout_mode = 0
	var opaque_mesh := Foliage.tree_silhouette_mesh(TEX)
	for mode in 3:
		Config.data.tree_cutout_mode = mode
		var field := _build_field(1.0)
		var mat := field.render_mesh.surface_get_material(0) as ShaderMaterial
		assert_eq(mat.shader, shaders[mode], "mode %d draws with its shader" % mode)
		assert_eq(field.render_mesh == opaque_mesh, mode == 0, "mode %d: traced silhouette only when opaque" % mode)
	Config.data.tree_cutout_mode = was


func test_alpha_card_mesh_is_a_star_of_distinct_atlas_frames() -> void:
	var arrays := Foliage._alpha_card_mesh().surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var n := Foliage.STAR_CARDS
	assert_eq(verts.size(), n * 6, "six vertices per card")
	var frames := {}
	var yaws := {}
	for c in n:
		var mid := 0.0
		for k in 6:
			mid += uvs[c * 6 + k].x / 6.0
		var card_frame := int(floor(mid * n))
		for k in 6:
			var i := c * 6 + k
			assert_between(uvs[i].x * n, float(card_frame) - 1e-3, float(card_frame + 1) + 1e-3, "a card samples exactly one frame")
			assert_almost_eq(verts[i].dot(normals[i]), 0.0, 1e-3, "card lies in its own plane")
			assert_almost_eq(normals[i].y, 0.0, 1e-3, "card is vertical")
			assert_between(verts[i].y, 0.0, 1.0, "card spans base to top")
		frames[card_frame] = true
		yaws[snappedf(atan2(normals[c * 6].x, normals[c * 6].z), 0.01)] = true
	assert_eq(frames.size(), n, "every card uses a different frame")
	assert_eq(yaws.size(), n, "every card faces a different direction")


func test_instance_yaw_is_deterministic_and_varies() -> void:
	var field := _build_field(1.0)
	var seen := {}
	for p in field.instance_positions:
		assert_eq(field._yaw(p), field._yaw(p), "same position -> same yaw")
		assert_almost_eq((field._upright_basis(p).y).length(), field._instance_scale(p).y, 1e-5,
			"yaw leaves the height scale intact")
		seen[field._yaw(p)] = true
	assert_gt(seen.size(), 1, "yaw differs across the stand")
