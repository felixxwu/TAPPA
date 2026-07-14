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
