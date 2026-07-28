extends GutTest
# LakeField renders a single flat water plane (terrain occludes it where it's above
# the level — no per-lake geometry). submerged_cells is the pure helper the 2D
# previews use to mark below-water ground.

const LakeField = preload("res://scripts/lake_field.gd")

func test_build_makes_one_water_plane() -> void:
	var lf := LakeField.new()
	add_child_autofree(lf)
	var cfg := GameConfig.new()
	lf.build(-0.5, cfg)
	var meshes: Array = []
	for c in lf.get_children():
		if c is MeshInstance3D:
			meshes.append(c)
	assert_eq(meshes.size(), 1, "one water plane")
	assert_almost_eq((meshes[0] as MeshInstance3D).position.y, -0.5, 0.001,
		"plane sits at the water level")

func test_water_plane_has_a_ready_shader_material() -> void:
	# The surface detail tile is a committed asset (not a NoiseTexture2D baked at
	# load — see lake_field.gd), so the material is fully wired the moment build()
	# returns: shader present, tile present and non-empty.
	var lf := LakeField.new()
	add_child_autofree(lf)
	lf.build(0.0, GameConfig.new())
	var mi := lf.get_child(0) as MeshInstance3D
	var mat := mi.material_override as ShaderMaterial
	assert_not_null(mat, "water plane uses a ShaderMaterial")
	assert_not_null(mat.shader, "shader is loaded")
	var tex: Texture2D = mat.get_shader_parameter("water_tex")
	assert_not_null(tex, "water tile is assigned")
	assert_gt(tex.get_width(), 0, "water tile has real pixels")
	assert_gt(tex.get_height(), 0, "water tile has real pixels")
	assert_false(tex is NoiseTexture2D,
		"water tile is a committed asset, not baked at load")

func test_submerged_cells_marks_below_water_ground() -> void:
	# Synthetic water: everything with z > 5 is underwater.
	var sampler := func(x: float, z: float) -> float:
		return -10.0 if z > 5.0 else 10.0
	var cells := LakeField.submerged_cells(sampler, 0.0, Rect2(-10, -10, 40, 40), 1.0)
	assert_gt(cells.size(), 0, "found submerged cells")
	for c in cells:
		assert_gt(c.y, 5.0, "every marked cell is in the underwater region")

func test_submerged_cells_empty_for_invalid_sampler() -> void:
	var cells := LakeField.submerged_cells(Callable(), 0.0, Rect2(0, 0, 10, 10), 1.0)
	assert_eq(cells.size(), 0, "no cells without a sampler")
