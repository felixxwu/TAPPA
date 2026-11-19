extends GutTest


func test_every_style_builds_a_grounded_mesh() -> void:
	for style in LogPile.STYLE_NAMES.size():
		var mi := LogPile.build(3, style)
		var aabb := mi.mesh.get_aabb()
		assert_gt(mi.mesh.get_surface_count(), 0)
		assert_almost_eq(aabb.position.y, 0.0, 0.1, "pile rests on the ground")
		mi.free()


func test_same_seed_is_deterministic() -> void:
	var a := LogPile.build(7, LogPile.Style.STACK)
	var b := LogPile.build(7, LogPile.Style.STACK)
	assert_eq(a.mesh.get_aabb(), b.mesh.get_aabb())
	a.free()
	b.free()


func test_extra_sections_sit_side_by_side_not_end_to_end() -> void:
	var one := LogPile.build(5, LogPile.Style.STACK, 4, 8, 4.0, 0.16, 1)
	var two := LogPile.build(5, LogPile.Style.STACK, 4, 8, 4.0, 0.16, 2)
	var a := one.mesh.get_aabb()
	var b := two.mesh.get_aabb()
	assert_gt(b.size.x, a.size.x * 1.8, "a second section widens the pile")
	assert_lt(b.size.z, a.size.z * 1.2, "the logs stay one length long")
	one.free()
	two.free()
