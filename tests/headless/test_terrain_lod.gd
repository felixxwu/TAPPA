extends GutTest

# Tests for scripts/terrain_lod.gd — the terrain display-LOD decimation + skirt.
# LOGIC only (no tuned band distances): a coarse level must be an EXACT subsample
# of the full-res L0 grid (so it can never disagree with collision / height
# queries), and the skirt must hang below the surface it seams.

const ManagerScript := preload("res://scripts/terrain_manager.gd")


func _make_layer(wavelength: float, amplitude: float) -> TerrainLayer:
	var layer := TerrainLayer.new()
	layer.wavelength_m = wavelength
	layer.amplitude_m = amplitude
	return layer


func _make_manager() -> Node3D:
	var m := Node3D.new()
	m.set_script(ManagerScript)
	m.focus_path = NodePath("")
	m.noise_seed = 4242
	m.layers = [_make_layer(60.0, 3.0), _make_layer(15.0, 0.8)] as Array[TerrainLayer]
	autofree(m)
	return m


# A coarse level's grid vertices are exactly the L0 vertices at (x*stride, z*stride)
# — bit-identical, so the LOD surface never diverges from collision / height_at.
func test_coarse_level_is_exact_subsample() -> void:
	var m := _make_manager()
	var data: Dictionary = m.compute_chunk_data(Vector2i(3, -2))
	var full_v: PackedVector3Array = data["vertices"]
	var samples: int = ManagerScript.SAMPLES
	var per_edge := samples - 1

	for stride in TerrainLod.LOD_STRIDES:
		if stride == 1:
			continue
		assert_eq(per_edge % stride, 0, "stride %d divides SAMPLES-1" % stride)
		var n := per_edge / stride + 1
		var mesh := TerrainLod.build_level(data, stride, 0.0)  # no skirt: grid only
		var arrays := mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		assert_eq(verts.size(), n * n, "stride %d grid has n*n verts" % stride)
		for zi in n:
			for xi in n:
				var got := verts[zi * n + xi]
				var want := full_v[(zi * stride) * samples + (xi * stride)]
				assert_true(got.is_equal_approx(want),
					"stride %d vertex (%d,%d) equals its L0 sample" % [stride, xi, zi])


# The skirt adds a ring of lowered duplicate vertices (grid + skirt), each exactly
# skirt_m below its source, and only adds geometry (never removes grid verts).
func test_skirt_hangs_below_and_adds_geometry() -> void:
	var m := _make_manager()
	var data: Dictionary = m.compute_chunk_data(Vector2i(0, 0))
	var samples: int = ManagerScript.SAMPLES
	var per_edge := samples - 1
	var stride := 2
	var n := per_edge / stride + 1

	var no_skirt := TerrainLod.build_level(data, stride, 0.0)
	var with_skirt := TerrainLod.build_level(data, stride, 3.0)
	var v0: PackedVector3Array = no_skirt.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var v1: PackedVector3Array = with_skirt.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]

	# Skirt = one lowered copy per perimeter vertex (4n-4 of them).
	assert_eq(v1.size(), v0.size() + (4 * n - 4), "skirt adds a lowered ring per edge vertex")
	# The grid portion is unchanged, and every skirt vertex sits skirt_m below some
	# grid vertex sharing its XZ.
	for i in v0.size():
		assert_true(v1[i].is_equal_approx(v0[i]), "grid vertices unchanged by skirt")
	for i in range(v0.size(), v1.size()):
		var sv := v1[i]
		var matched := false
		for gv in v0:
			if absf(gv.x - sv.x) < 1e-4 and absf(gv.z - sv.z) < 1e-4 \
					and absf((gv.y - 3.0) - sv.y) < 1e-3:
				matched = true
				break
		assert_true(matched, "skirt vertex sits 3 m below a perimeter grid vertex")


# build_all yields one mesh per LOD_STRIDES level.
func test_build_all_one_mesh_per_level() -> void:
	var m := _make_manager()
	var data: Dictionary = m.compute_chunk_data(Vector2i(1, 1))
	var meshes := TerrainLod.build_all(data, 3.0)
	assert_eq(meshes.size(), TerrainLod.LOD_STRIDES.size(), "one mesh per LOD level")
	for mesh in meshes:
		assert_true(mesh is ArrayMesh, "each level is an ArrayMesh")
		assert_gt((mesh as ArrayMesh).surface_get_array_len(0), 0, "level mesh has vertices")


# --- 3.6: the lazily-built finest level -----------------------------------------

# build_all(..., from_level) leaves the finer levels unbuilt (null) and still returns one
# slot per level, so the level index stays the array index.
func test_build_all_from_level_leaves_finer_levels_unbuilt() -> void:
	var m := _make_manager()
	var data: Dictionary = m.compute_chunk_data(Vector2i(1, 1))
	var meshes := TerrainLod.build_all(data, 3.0, 1)
	assert_eq(meshes.size(), TerrainLod.LOD_STRIDES.size(), "one slot per LOD level")
	assert_null(meshes[0], "the finest level is deferred, not built")
	for i in range(1, meshes.size()):
		assert_true(meshes[i] is ArrayMesh, "level %d is still prebaked" % i)


# The quantised light round-trips closely enough to be invisible, and an unlit chunk
# encodes to nothing at all.
func test_encode_decode_lights_round_trips() -> void:
	var src := PackedColorArray([
		Color(0, 0, 0), Color(1, 1, 1), Color(0.25, 0.5, 0.75), Color(1.4, 0.1, 1.9)])
	var back := TerrainLod.decode_lights(TerrainLod.encode_lights(src))
	assert_eq(back.size(), src.size(), "one colour back per colour in")
	var tol := TerrainLod.LIGHT_ENCODE_SCALE / 255.0
	for i in src.size():
		assert_almost_eq(back[i].r, src[i].r, tol, "r round-trips within one quantisation step")
		assert_almost_eq(back[i].g, src[i].g, tol, "g round-trips within one quantisation step")
		assert_almost_eq(back[i].b, src[i].b, tol, "b round-trips within one quantisation step")
	assert_eq(TerrainLod.encode_lights(PackedColorArray()).size(), 0, "unlit encodes to nothing")
	assert_eq(TerrainLod.decode_lights(PackedByteArray()).size(), 0, "nothing decodes to unlit")


# The whole safety argument for deferring level 0: rebuilding it later from what the cache
# KEEPS (heights + center + the quantised light + the live track fields) reproduces the
# mesh the precompute would have prebaked — same vertices, UVs, UV2s and (bar the light
# quantisation) the same vertex colours. If this drifted, collision and the coarser levels
# would disagree with the ground the player sees.
func test_build_finest_reproduces_the_prebaked_level_zero() -> void:
	var m := _make_manager()
	m.light_amount = 1.0
	var coord := Vector2i(2, -1)
	var data: Dictionary = m.compute_chunk_data(coord)
	var prebaked := TerrainLod.build_level(data, 1, 3.0)
	# What the chunk cache still holds after the prebake + the load-only frees.
	var kept := {
		"center": data["center"],
		"heights": data["heights"],
		"l0_light": TerrainLod.encode_lights(data["lights"]),
	}
	var lazy := TerrainLod.build_finest(m, coord, kept, 3.0)
	assert_not_null(lazy, "the finest level rebuilds from the retained data")

	var a := prebaked.surface_get_arrays(0)
	var b := lazy.surface_get_arrays(0)
	assert_eq((b[Mesh.ARRAY_INDEX] as PackedInt32Array), (a[Mesh.ARRAY_INDEX] as PackedInt32Array),
		"same triangles")
	var av: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
	var bv: PackedVector3Array = b[Mesh.ARRAY_VERTEX]
	assert_eq(bv.size(), av.size(), "same vertex count (grid + skirt)")
	var auv: PackedVector2Array = a[Mesh.ARRAY_TEX_UV]
	var buv: PackedVector2Array = b[Mesh.ARRAY_TEX_UV]
	var auv2: PackedVector2Array = a[Mesh.ARRAY_TEX_UV2]
	var buv2: PackedVector2Array = b[Mesh.ARRAY_TEX_UV2]
	var ac: PackedColorArray = a[Mesh.ARRAY_COLOR]
	var bc: PackedColorArray = b[Mesh.ARRAY_COLOR]
	var tol := TerrainLod.LIGHT_ENCODE_SCALE / 255.0
	var bad := 0
	for i in av.size():
		if not bv[i].is_equal_approx(av[i]) or not buv[i].is_equal_approx(auv[i]) \
				or not buv2[i].is_equal_approx(auv2[i]) \
				or absf(bc[i].r - ac[i].r) > tol or absf(bc[i].g - ac[i].g) > tol \
				or absf(bc[i].b - ac[i].b) > tol or absf(bc[i].a - ac[i].a) > 1e-5:
			bad += 1
	assert_eq(bad, 0, "every lazily-rebuilt vertex matches the prebaked one")


# A coarse chunk has no full-res heights, so there is nothing to rebuild level 0 from —
# say so loudly rather than meshing garbage.
func test_build_finest_without_heights_is_loud() -> void:
	var m := _make_manager()
	assert_null(TerrainLod.build_finest(m, Vector2i(0, 0), {"center": Vector3.ZERO}, 3.0),
		"no heights -> no mesh")
	assert_push_error("cannot lazily build the finest LOD level")
