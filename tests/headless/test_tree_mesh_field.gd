extends GutTest
# TreeMeshField uses a single uniform instance_scale, so every tree reports full size.


func test_size_factor_is_always_one() -> void:
	var field := TreeMeshField.new()
	add_child_autofree(field)
	assert_almost_eq(field.size_factor(0), 1.0, 1e-6, "uniform mesh trees are full size")
	assert_almost_eq(field.size_factor(-1), 1.0, 1e-6, "bad index still 1.0")
