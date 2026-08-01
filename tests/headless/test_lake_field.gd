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

func test_preview_cells_for_reflects_the_sampler_it_is_given() -> void:
	# Why this entry point exists: the loading preview's first passes sample pure
	# noise (all that exists before the road bake), but the terrain the player gets
	# has signed cliff offsets baked in, which push extra ground under water. So the
	# preview must be repaintable against a DIFFERENT, lower sampler and show more
	# water for it — that's the whole mismatch this fixes.
	var bounds := Rect2(-100, -100, 200, 200)
	var noise_like := func(_x: float, z: float) -> float:
		return 4.0 if z > 0.0 else 12.0
	# The same ground after a cliff drop: everything sits 8 m lower.
	var baked := func(x: float, z: float) -> float:
		return noise_like.call(x, z) - 8.0
	var before: Array = LakeField.preview_cells_for(noise_like, 0.0, bounds)
	var after: Array = LakeField.preview_cells_for(baked, 0.0, bounds)
	assert_eq(before[1], after[1], "same bounds -> same step, so the repaint lands on the same lattice")
	assert_gt((after[0] as PackedVector2Array).size(), (before[0] as PackedVector2Array).size(),
		"dropping the ground below the waterline floods more of the preview")

func test_preview_cells_for_empty_for_invalid_sampler() -> void:
	var out: Array = LakeField.preview_cells_for(Callable(), 0.0, Rect2(0, 0, 10, 10))
	assert_eq((out[0] as PackedVector2Array).size(), 0, "no cells without a sampler")
	assert_gt(float(out[1]), 0.0, "still returns a usable step")
