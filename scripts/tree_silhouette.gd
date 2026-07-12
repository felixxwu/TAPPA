class_name TreeSilhouette
# Builds a low-poly OPAQUE silhouette mesh from an image's alpha channel, so
# billboard trees can render with the cutout baked into geometry (no fragment
# discard -> early-Z works, overdraw collapses on mobile). Called once at load
# and cached by the caller. See features/trees.md and
# docs/superpowers/specs/2026-07-06-tight-cutout-billboard-trees-design.md.
#
# The feathery canopy comes back from opaque_to_polygons as MULTIPLE disconnected
# polygons (one per opaque cluster); we triangulate every one and merge them, so
# the empty space between clusters becomes real geometry gaps (the airy look).
# Fully-enclosed holes are silently filled by opaque_to_polygons (it only traces
# outer contours) — negligible for foliage.


# alpha_threshold: alpha at/above which a texel counts as opaque (higher = airier,
# more fragmented clusters). simplify_epsilon: RDP contour simplification in px
# (higher = fewer triangles). Both are rendering constants chosen by the caller.
static func build(image: Image, alpha_threshold: float, simplify_epsilon: float) -> ArrayMesh:
	var w := image.get_width()
	var h := image.get_height()
	var bm := BitMap.new()
	bm.create_from_image_alpha(image, alpha_threshold)
	var polys := bm.opaque_to_polygons(Rect2i(0, 0, w, h), simplify_epsilon)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var any := false
	for outline: PackedVector2Array in polys:
		if outline.size() < 3:
			continue
		var tris := Geometry2D.triangulate_polygon(outline)
		if tris.is_empty():
			continue  # degenerate/self-touching contour; skip it
		# Emit each triangle twice, one per plane, keeping the three verts of a
		# triangle contiguous so PRIMITIVE_TRIANGLES winds correctly. Two crossed
		# planes form a "+" (cross) billboard: the first in the XY plane, the
		# second the same silhouette rotated 90 deg about Y (into the ZY plane).
		# Both share the UV, so the same cutout shows from every horizontal angle
		# without the card having to face the camera.
		# triangulate_polygon emits three indices per triangle, so the count is always
		# a multiple of 3 — the division is exact and intentionally integer.
		@warning_ignore("integer_division")
		var tri_count := tris.size() / 3
		for plane in 2:
			for t in tri_count:
				for k in 3:
					var px := outline[tris[t * 3 + k]]
					var nx := px.x / float(w) - 0.5
					var ny := 1.0 - px.y / float(h)
					st.set_uv(Vector2(px.x / float(w), px.y / float(h)))
					if plane == 0:
						st.add_vertex(Vector3(nx, ny, 0.0))
					else:
						st.add_vertex(Vector3(0.0, ny, nx))
		any = true

	if not any:
		# No opaque area -> a 0-surface mesh. BillboardField tolerates this (it
		# skips material assignment and simply renders nothing). Unreachable with
		# the real tree texture; guards against a fully-transparent swap-in.
		return ArrayMesh.new()
	return st.commit()
