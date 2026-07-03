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
