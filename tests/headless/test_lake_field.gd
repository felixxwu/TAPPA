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
