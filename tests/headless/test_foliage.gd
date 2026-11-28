extends GutTest
# The star card mesh the level trees are drawn on.


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

