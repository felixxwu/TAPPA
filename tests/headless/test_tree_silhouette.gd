extends GutTest
# TreeSilhouette.build turns an image's alpha into a low-poly opaque silhouette
# mesh. Tested on SYNTHETIC images only (no dependency on textures/tree.png), and
# on invariants that hold for ANY threshold/epsilon — never on tuned tri counts.


func _solid_image(w: int, h: int) -> Image:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 1))
	return img


func _tri_count(mesh: ArrayMesh) -> int:
	if mesh.get_surface_count() == 0:
		return 0
	var arrays := mesh.surface_get_arrays(0)
	return (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3


func test_solid_image_fills_normalized_card_bounds() -> void:
	var mesh := TreeSilhouette.build(_solid_image(16, 32), 0.5, 2.0)
	assert_gt(_tri_count(mesh), 0, "solid image produces triangles")
	var verts := mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array
	var uvs := mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV] as PackedVector2Array
	var aabb := mesh.get_aabb()
	# A fully-opaque image spans the whole normalized card.
	assert_almost_eq(aabb.position.x, -0.5, 0.05, "left edge ~ -0.5")
	assert_almost_eq(aabb.end.x, 0.5, 0.05, "right edge ~ 0.5")
	assert_almost_eq(aabb.position.y, 0.0, 0.05, "bottom ~ 0")
	assert_almost_eq(aabb.end.y, 1.0, 0.05, "top ~ 1")
	for uv in uvs:
		assert_between(uv.x, 0.0, 1.0, "u in [0,1]")
		assert_between(uv.y, 0.0, 1.0, "v in [0,1]")
	# Cross ("+") billboard: two crossed planes, so every vertex lies on EITHER the XY
	# plane (z=0) or the ZY plane (x=0), and the second plane gives the card depth in z
	# spanning the same normalized width [-0.5, 0.5].
	for v in verts:
		assert_true(absf(v.z) < 1e-4 or absf(v.x) < 1e-4, "vertex lies on one of the crossed planes")
	assert_almost_eq(aabb.position.z, -0.5, 0.05, "cross depth front ~ -0.5")
	assert_almost_eq(aabb.end.z, 0.5, 0.05, "cross depth back ~ 0.5")


func test_two_separated_blobs_leave_a_gap_between_them() -> void:
	# Two opaque squares with a transparent column between them come back as
	# separate polygons; triangulating all of them leaves a real gap (the airy
	# "holes" mechanism), so the filled area stays well under the full card.
	var img := Image.create(30, 10, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 0))
	for y in 10:
		for x in 10:
			img.set_pixel(x, y, Color(1, 1, 1, 1))          # left blob  x:0..9
			img.set_pixel(x + 20, y, Color(1, 1, 1, 1))      # right blob x:20..29
	var mesh := TreeSilhouette.build(img, 0.5, 1.0)
	assert_gt(_tri_count(mesh), 0, "two blobs produce triangles")
	var verts := mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array
	var area := 0.0
	var min_x := INF
	var max_x := -INF
	for i in range(0, verts.size(), 3):
		var a := verts[i]; var b := verts[i + 1]; var c := verts[i + 2]
		area += absf((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)) * 0.5
	for v in verts:
		min_x = minf(min_x, v.x)
		max_x = maxf(max_x, v.x)
	assert_lt(area, 0.75, "gap between blobs stays empty (area < full card)")
	# Both blobs must be triangulated (not just the largest): the left blob
	# (x px 0..9 -> normalized ~ -0.5..-0.2) and the right (x px 20..29 -> ~0.17..0.47)
	# both contribute geometry, so the mesh spans both sides of the empty middle.
	assert_lt(min_x, -0.1, "left blob triangulated (verts on the left)")
	assert_gt(max_x, 0.2, "right blob triangulated (verts on the right)")


func test_fully_transparent_image_returns_empty_mesh() -> void:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 0))
	var mesh := TreeSilhouette.build(img, 0.5, 2.0)
	assert_eq(_tri_count(mesh), 0, "no opaque texels -> no triangles, no crash")
