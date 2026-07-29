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


# --- feathered_ground_mesh (HQ apron / podium floor) --------------------------
#
# The mesh is a NON-UNIFORM grid: a coarse whole-plane lattice plus a fine ring of
# lines around each pad edge, so the smoothstep feather band keeps its resolution
# however coarse `subdiv` is. These assert that CONTRACT, never a vertex count or a
# particular subdivision — both are tunables (cfg.ground_subdiv_for).

# A pad centred on the origin, `half` metres to a side.
func _pad(half: float) -> Array[Rect2]:
	var pads: Array[Rect2] = [Rect2(Vector2(-half, -half), Vector2(half, half) * 2.0)]
	return pads


# The per-vertex tarmac weight (COLOR.a) at the vertex nearest world XZ `p`.
func _weight_at(mesh: ArrayMesh, p: Vector2) -> float:
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var best := -1
	var best_d := INF
	for i in verts.size():
		var d := Vector2(verts[i].x, verts[i].z).distance_squared_to(p)
		if d < best_d:
			best_d = d
			best = i
	return cols[best].a if best >= 0 else -1.0


func test_feathered_ground_mesh_surface_format() -> void:
	var mesh := MeshUtil.feathered_ground_mesh(100.0, 8, _pad(10.0), 3.0)
	assert_eq(mesh.get_surface_count(), 1, "one surface")
	assert_eq(mesh.surface_get_primitive_type(0), Mesh.PRIMITIVE_TRIANGLES)
	var fmt := mesh.surface_get_format(0)
	# The road-blend shader reads COLOR.a (tarmac weight), UV (world XZ for the grass
	# tiling) and UV2.x (pure-tarmac select); the mesh must carry all three.
	assert_true(bool(fmt & Mesh.ARRAY_FORMAT_COLOR), "per-vertex colour present")
	assert_true(bool(fmt & Mesh.ARRAY_FORMAT_TEX_UV), "UV present")
	assert_true(bool(fmt & Mesh.ARRAY_FORMAT_TEX_UV2), "UV2 present")
	assert_true(bool(fmt & Mesh.ARRAY_FORMAT_NORMAL), "normals present")
	assert_true(bool(fmt & Mesh.ARRAY_FORMAT_INDEX), "indexed")


func test_feathered_ground_mesh_spans_the_full_plane() -> void:
	var size := 100.0
	var mesh := MeshUtil.feathered_ground_mesh(size, 6, _pad(10.0), 3.0)
	var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var aabb := mesh.get_aabb()
	assert_almost_eq(aabb.position.x, -size * 0.5, 0.01, "spans to -size/2 in x")
	assert_almost_eq(aabb.end.x, size * 0.5, 0.01, "spans to +size/2 in x")
	assert_almost_eq(aabb.position.z, -size * 0.5, 0.01, "spans to -size/2 in z")
	assert_almost_eq(aabb.end.z, size * 0.5, 0.01, "spans to +size/2 in z")
	for v in verts:
		assert_almost_eq(v.y, 0.0, 1e-4, "flat floor at y = 0")


# The whole point of the subdivision: a smoothstep ramp between grass and tarmac.
# Run at a DELIBERATELY LOW subdiv — the coarse lattice alone couldn't resolve the
# band, so this is what regresses if the pad-edge refinement is ever dropped.
func test_feather_band_is_resolved_at_a_low_subdivision() -> void:
	var half := 10.0
	var feather := 3.0
	var mesh := MeshUtil.feathered_ground_mesh(200.0, 4, _pad(half), feather)
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	# Count vertices strictly inside the ramp (0 < a < 1) — several are needed for
	# the band to read as a gradient rather than a hard edge.
	var partial := 0
	for i in verts.size():
		var a := cols[i].a
		if a > 0.02 and a < 0.98:
			partial += 1
	assert_gt(partial, 8, "the feather ramp is sampled by many vertices even at subdiv 4")
	# And it lands where it should: full tarmac well inside, pure grass well outside.
	assert_almost_eq(_weight_at(mesh, Vector2.ZERO), 1.0, 1e-3, "pad centre is full tarmac")
	assert_almost_eq(_weight_at(mesh, Vector2(half + feather * 4.0, 0.0)), 0.0, 1e-3,
		"well beyond the feather band is pure grass")
	var mid := _weight_at(mesh, Vector2(half + feather * 0.5, 0.0))
	assert_between(mid, 0.02, 0.98, "mid-band vertex carries a partial tarmac weight")


func test_every_pad_is_cut_into_the_ground() -> void:
	# Two pads far apart (the podium's layout): BOTH get their tarmac plateau, and
	# the grass between them is untouched.
	var pads: Array[Rect2] = [
		Rect2(Vector2(-5.0, -5.0), Vector2(10.0, 10.0)),
		Rect2(Vector2(35.0, -5.0), Vector2(10.0, 10.0)),
	]
	var mesh := MeshUtil.feathered_ground_mesh(120.0, 8, pads, 3.0)
	assert_almost_eq(_weight_at(mesh, Vector2(0.0, 0.0)), 1.0, 1e-3, "first pad is tarmac")
	assert_almost_eq(_weight_at(mesh, Vector2(40.0, 0.0)), 1.0, 1e-3, "second pad is tarmac")
	assert_almost_eq(_weight_at(mesh, Vector2(20.0, 0.0)), 0.0, 1e-3, "grass between the pads")


func test_no_pads_leaves_pure_grass() -> void:
	var none: Array[Rect2] = []
	var mesh := MeshUtil.feathered_ground_mesh(100.0, 8, none, 3.0)
	var cols: PackedColorArray = mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	assert_gt(cols.size(), 0, "a mesh is still produced with no pads")
	for c in cols:
		assert_almost_eq(c.a, 0.0, 1e-4, "no pad means no tarmac weight anywhere")


func test_triangles_are_non_degenerate_and_face_up() -> void:
	# The pad-edge refinement inserts lines into the coarse lattice; near-duplicate
	# lines would make zero-area slivers, and a flipped winding would make the floor
	# invisible (the ps1_models shader culls back faces).
	var mesh := MeshUtil.feathered_ground_mesh(120.0, 5, _pad(9.0), 3.0)
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	assert_eq(idx.size() % 3, 0, "whole triangles")
	assert_gt(idx.size(), 0, "the plane is triangulated")
	var i := 0
	while i < idx.size():
		var a := verts[idx[i]]
		var b := verts[idx[i + 1]]
		var c := verts[idx[i + 2]]
		var n := (b - a).cross(c - a)
		if n.length() < 1e-6 or n.y >= 0.0:
			# Godot's cross for a CW-in-XZ (upward-facing) winding points -Y.
			assert_lt(n.y, 0.0, "triangle %d has area and faces up" % (i / 3))
			return
		i += 3
	pass_test("every triangle has area and faces up")
