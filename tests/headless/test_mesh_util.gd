extends GutTest
# PS1Material.unshaded builds the flat, unshaded, nearest-filtered material the
# world uses; the optional flags toggle vertex-colour albedo and albedo texture.


func test_unshaded_defaults() -> void:
	var mat := PS1Material.unshaded()
	assert_not_null(mat)
	assert_eq(mat.shading_mode, BaseMaterial3D.SHADING_MODE_UNSHADED)
	assert_eq(mat.texture_filter, BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS)
	assert_false(mat.vertex_color_use_as_albedo, "vertex colour off by default")
	assert_null(mat.albedo_texture, "no albedo texture by default")


func test_unshaded_vertex_color_flag() -> void:
	var mat := PS1Material.unshaded(null, true)
	assert_true(mat.vertex_color_use_as_albedo)


func test_unshaded_albedo_texture() -> void:
	var tex := PlaceholderTexture2D.new()
	var mat := PS1Material.unshaded(tex)
	assert_eq(mat.albedo_texture, tex)


# --- apply_visibility_range (shared world-prop distance cull) ------------------

func test_apply_visibility_range_covers_the_whole_subtree() -> void:
	# A root MeshInstance3D with a nested MeshInstance3D + a plain Node in between.
	var root := MeshInstance3D.new()
	var mid := Node3D.new()
	var leaf := MeshInstance3D.new()
	root.add_child(mid)
	mid.add_child(leaf)
	var touched := MeshUtil.apply_visibility_range(root, 80.0, 15.0)
	assert_eq(touched, 2, "both GeometryInstance3Ds (root + leaf) are touched, the Node3D is skipped")
	assert_almost_eq(root.visibility_range_end, 80.0, 1e-4, "root end set")
	assert_almost_eq(leaf.visibility_range_end, 80.0, 1e-4, "nested leaf end set")
	assert_almost_eq(leaf.visibility_range_end_margin, 15.0, 1e-4, "nested leaf fade set")
	assert_eq(leaf.visibility_range_fade_mode, GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF,
		"self-fade so the cull dithers rather than pops")
	root.free()


func test_apply_visibility_range_noop_when_uncapped() -> void:
	# end <= 0 means "no limit": leave visibility_range_end at its default 0.
	var root := MeshInstance3D.new()
	var touched := MeshUtil.apply_visibility_range(root, 0.0, 10.0)
	assert_eq(touched, 0, "nothing touched when uncapped")
	assert_almost_eq(root.visibility_range_end, 0.0, 1e-4, "end left at the unlimited default")
	root.free()
