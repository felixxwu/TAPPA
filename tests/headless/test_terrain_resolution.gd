extends GutTest
# Per-chunk terrain resolution: classification logic + strided-build parity
# (see docs/superpowers/specs/2026-07-21-per-chunk-terrain-resolution-design.md).

const ManagerScript := preload("res://scripts/terrain_manager.gd")
const BuilderScript := preload("res://scripts/terrain_chunk_builder.gd")
const LodScript := preload("res://scripts/terrain_lod.gd")
const ChunkScript := preload("res://scripts/terrain_chunk.gd")

func _make_manager() -> TerrainManager:
	var m := Node3D.new()
	m.set_script(ManagerScript)
	m.focus_path = NodePath("")
	m.defer_initial_build = true
	m.noise_seed = 1337
	add_child_autofree(m)
	return m

func test_corridor_and_collision_bands_share_the_plus_one_derivation() -> void:
	# Both bands add the same ceil(leash/CHUNK)+1 slop on top of their base ring,
	# so they can never drift apart (the invariant collision correctness leans on).
	var m := _make_manager()
	var leash := 50.0
	var slop := m._corridor_margin(leash) - ManagerScript.RADIUS
	var coll_slop := m._collision_band_chunks(leash) - m.collision_ring
	assert_eq(slop, coll_slop, "corridor and collision bands add identical leash slop")

func test_classify_picks_finest_reachable_level() -> void:
	# A chunk on the centerline (min_dist 0) can be viewed at the finest level.
	var m := _make_manager()
	m.lod_band_ends_m = PackedFloat32Array([30.0, 70.0, 100.0, 130.0])
	m.precompute_safety_slack_m = 0.0
	var near := m._classify_chunk(0.0, 50.0, m._collision_band_chunks(50.0), true)
	assert_eq(near["l_min"], 0, "on-track chunk keeps the finest level")
	assert_true(near["full_res"], "on-track chunk is full-res")

func test_classify_prunes_fine_levels_for_far_chunk() -> void:
	# A chunk far from the centerline (well past leash+bands, outside collision band)
	# can only ever show a coarse level, and is not full-res.
	var m := _make_manager()
	m.lod_band_ends_m = PackedFloat32Array([30.0, 70.0, 100.0, 130.0])
	m.precompute_safety_slack_m = 0.0
	# closest cam dist = 300 - 50 - 0 = 250 > all band ends -> l_min = 4 (coarsest only)
	var far := m._classify_chunk(300.0, 50.0, m._collision_band_chunks(50.0), false)
	assert_eq(far["l_min"], m.lod_band_ends_m.size(), "far chunk: only the coarsest level")
	assert_false(far["full_res"], "far chunk is coarse")

func test_classify_forces_full_res_inside_collision_band() -> void:
	# A chunk whose distance alone would prune the finest level is still full-res if
	# it can enter the collision band (it must carry a 1 m heightfield for collision).
	var m := _make_manager()
	m.lod_band_ends_m = PackedFloat32Array([30.0, 70.0, 100.0, 130.0])
	m.precompute_safety_slack_m = 0.0
	var c := m._classify_chunk(90.0, 50.0, m._collision_band_chunks(50.0), true)
	assert_true(c["full_res"], "collision-band chunk is full-res regardless of LOD reach")

func _straight_centerline() -> Curve2D:
	var c := Curve2D.new()
	c.add_point(Vector2(0, 0))
	c.add_point(Vector2(300, 0))
	return c

func test_corridor_classifies_near_full_res_and_far_coarse() -> void:
	var m := _make_manager()
	m.lod_band_ends_m = PackedFloat32Array([30.0, 70.0, 100.0, 130.0])
	m.precompute_safety_slack_m = 0.0
	var coords := m.corridor_coords(_straight_centerline(), 50.0)
	assert_gt(coords.size(), 0, "corridor non-empty")
	# On-track chunk (touches z=0) is full-res; the outermost dilated chunk is coarse.
	assert_true(m.chunk_class(Vector2i(2, 0))["full_res"], "on-track chunk full-res")
	var margin := m._corridor_margin(50.0)
	var far := Vector2i(2, margin)  # top edge of the dilation band
	assert_false(m.chunk_class(far)["full_res"], "outermost corridor chunk is coarse")

func test_chunk_class_defaults_full_res_when_unknown() -> void:
	var m := _make_manager()
	var cls := m.chunk_class(Vector2i(999, 999))
	assert_true(cls["full_res"], "unknown coord defaults to full-res (safe)")
	assert_eq(cls["l_min"], 0, "unknown coord keeps all levels")

func test_strided_build_matches_decimated_full_res_with_cliffs() -> void:
	# A strided build must be bit-identical to decimating the full-res grid at the
	# same stride — heights, uvs, colours AND lighting — even with cliffs baked (the
	# case that catches a neighbour sample that forgets the cliff offset).
	var m := _make_manager()
	m.light_amount = 1.0
	# Bake a synthetic cliff on the global vertices covering the test chunk + halo.
	m.cliff_offsets = {}
	for gz in range(-2, 60):
		for gx in range(-2, 60):
			m.cliff_offsets[Vector2i(gx, gz)] = 2.5 if (gx / 5) % 2 == 0 else 0.0
	var coord := Vector2i(0, 0)
	var stride := 5
	var full := BuilderScript.new(m, coord, 1)
	full.build()
	var full_data := full.data()
	var strided := BuilderScript.new(m, coord, stride)
	strided.build()
	var sd := strided.data()
	var per_edge: int = TerrainManager.SAMPLES - 1
	var n: int = per_edge / stride + 1
	assert_eq(sd["grid_n"], n, "strided grid edge length")
	var fh: PackedFloat32Array = full_data["heights"]
	var sh: PackedFloat32Array = sd["heights"]
	var fl: PackedColorArray = full_data["lights"]
	var sl: PackedColorArray = sd["lights"]
	var fuv: PackedVector2Array = full_data["uvs"]
	var suv: PackedVector2Array = sd["uvs"]
	var fc: PackedColorArray = full_data["colors"]
	var sc: PackedColorArray = sd["colors"]
	for zi in n:
		for xi in n:
			var fidx := (zi * stride) * TerrainManager.SAMPLES + (xi * stride)
			var sidx := zi * n + xi
			assert_almost_eq(sh[sidx], fh[fidx], 1e-4,
				"strided height == decimated full-res at (%d,%d)" % [xi, zi])
			assert_almost_eq(sl[sidx].r, fl[fidx].r, 1e-4,
				"strided light == decimated full-res at (%d,%d)" % [xi, zi])
			assert_almost_eq(suv[sidx].x, fuv[fidx].x, 1e-4, "strided uv.x matches")
			assert_almost_eq(sc[sidx].a, fc[fidx].a, 1e-4, "strided colour alpha matches")

func test_build_levels_from_nulls_pruned_and_builds_kept() -> void:
	var m := _make_manager()
	var l_min := 2
	var meshes := LodScript.build_levels_from(m, Vector2i(0, 0), l_min, 3.0)
	assert_eq(meshes.size(), LodScript.LOD_STRIDES.size(), "one slot per LOD level")
	for i in meshes.size():
		if i < l_min:
			assert_null(meshes[i], "pruned fine level %d is null" % i)
		else:
			assert_true(meshes[i] is ArrayMesh, "kept level %d is a mesh" % i)
			assert_gt(meshes[i].get_surface_count(), 0, "kept level %d has a surface" % i)

func test_cache_chunk_coarse_has_meshes_but_no_full_res_grid() -> void:
	var m := _make_manager()
	m.lod_band_ends_m = PackedFloat32Array([30.0, 70.0, 100.0, 130.0])
	m.precompute_safety_slack_m = 0.0
	m.set_corridor(m.corridor_coords(_straight_centerline(), 50.0))
	var far := Vector2i(2, m._corridor_margin(50.0))
	assert_false(m.chunk_class(far)["full_res"], "precondition: far coord is coarse")
	m.cache_chunk(far)
	var data: Dictionary = m._chunk_cache[far]
	assert_true(data.get("coarse", false), "coarse chunk flagged")
	var h: PackedFloat32Array = data.get("heights", PackedFloat32Array())
	assert_eq(h.size(), 0, "coarse chunk carries no full-res heights")
	assert_true(data.has("center"), "coarse chunk still carries center (apply_data needs it)")
	var l_min: int = m.chunk_class(far)["l_min"]
	if l_min > 0:
		assert_null(data["lod_meshes"][0], "finest level pruned when l_min > 0")
	assert_true(data["lod_meshes"][l_min] is ArrayMesh, "kept level built")

func test_cache_chunk_full_res_unchanged() -> void:
	var m := _make_manager()
	m.set_corridor(m.corridor_coords(_straight_centerline(), 50.0))
	m.cache_chunk(Vector2i(2, 0))  # on-track -> full-res
	var data: Dictionary = m._chunk_cache[Vector2i(2, 0)]
	assert_false(data.get("coarse", false), "on-track chunk is full-res")
	assert_eq((data["heights"] as PackedFloat32Array).size(),
		TerrainManager.SAMPLES * TerrainManager.SAMPLES, "full-res grid present")

func test_apply_data_skips_null_levels_and_builds_no_collision_for_coarse() -> void:
	var m := _make_manager()
	m.lod_band_ends_m = PackedFloat32Array([30.0, 70.0, 100.0, 130.0])
	m.precompute_safety_slack_m = 0.0
	m.set_corridor(m.corridor_coords(_straight_centerline(), 50.0))
	var far := Vector2i(2, m._corridor_margin(50.0))
	m.cache_chunk(far)
	var chunk = ChunkScript.new()
	add_child_autofree(chunk)
	chunk.apply_data(m, far, m._chunk_cache[far])
	var l_min: int = m.chunk_class(far)["l_min"]
	var present := 0
	for mi in chunk.get_children():
		if mi is MeshInstance3D and mi.mesh != null:
			present += 1
	assert_eq(present, LodScript.LOD_STRIDES.size() - l_min, "only kept levels have a mesh")
	var coll := chunk.get_node("CollisionShape3D")
	assert_null(coll.shape, "coarse chunk has no collision shape")

func test_height_at_over_coarse_chunk_uses_noise_fallback() -> void:
	var m := _make_manager()
	m.lod_band_ends_m = PackedFloat32Array([30.0, 70.0, 100.0, 130.0])
	m.precompute_safety_slack_m = 0.0
	m.set_corridor(m.corridor_coords(_straight_centerline(), 50.0))
	var far := Vector2i(2, m._corridor_margin(50.0))
	m.cache_chunk(far)
	var wx := (far.x + 0.5) * TerrainManager.CHUNK_M
	var wz := (far.y + 0.5) * TerrainManager.CHUNK_M
	assert_almost_eq(m.height_at(wx, wz), m._noise_height_at(wx, wz), 1e-5,
		"coarse chunk: height_at falls back to pure noise (no crash, no cached grid)")

func test_reconcile_does_not_build_on_real_play_miss() -> void:
	var m := _make_manager()
	m.precompute_corridor(_straight_centerline(), 25.0)
	var before: int = m.integrations_total
	m.update_focus(Vector3(8000, 0, 8000))
	assert_eq(m.integrations_total, before, "no chunk integrated on a real-play miss")
	assert_eq(m.loaded_coords().size(), 0, "real-play miss leaves a hole (no spawn)")
	# Each missing coord logs once — declare them expected so GUT doesn't fail the test.
	assert_push_error_count(m._logged_misses.size(), "one push_error per missing coord")
