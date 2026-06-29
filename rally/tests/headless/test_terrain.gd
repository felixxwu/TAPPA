extends GutTest

# Tests for scripts/terrain_manager.gd / terrain_chunk.gd / terrain_layer.gd.
# height_at() is pure noise and works out-of-tree; chunk build tests add nodes.

const ManagerScript := preload("res://scripts/terrain_manager.gd")
const ChunkScript := preload("res://scripts/terrain_chunk.gd")

const SAMPLE_POINTS := [
	Vector2(0.0, 0.0), Vector2(12.5, -33.0), Vector2(-80.0, 41.5), Vector2(99.0, 99.0),
]


func _make_layer(wavelength: float, amplitude: float) -> TerrainLayer:
	var layer := TerrainLayer.new()
	layer.wavelength_m = wavelength
	layer.amplitude_m = amplitude
	return layer


# A bare TerrainManager (no focus node), not added to the tree by default.
func _make_manager(layer_list: Array[TerrainLayer], seed_value: int = 1337) -> Node3D:
	var manager := Node3D.new()
	manager.set_script(ManagerScript)
	manager.use_threaded_generation = false  # deterministic synchronous tests
	manager.focus_path = NodePath("")  # no car; tests drive focus explicitly
	manager.noise_seed = seed_value
	manager.layers = layer_list
	autofree(manager)
	return manager


func test_distant_terrain_follows_noise_and_has_no_collision() -> void:
	# The coarse far backdrop (distant_terrain.gd) samples the SAME noise as the
	# real terrain so it matches at the seam, sits `sink_m` lower across the WHOLE
	# mesh (so the detail ring always wins the overlap and nothing pokes through),
	# and is pure scenery (no collision).
	var manager = _make_manager([_make_layer(60.0, 1.5)] as Array[TerrainLayer], 1337)
	add_child_autofree(manager)  # _ready loads the 3x3 ring (no effect on the uncut backdrop)
	var dt := DistantTerrain.new()
	dt.radius_m = 50.0
	dt.cell_m = 10.0
	dt.sink_m = 1.5
	autofree(dt)
	dt.setup(manager, null)  # null focus -> centres at origin; out of tree -> no _process
	assert_not_null(dt.mesh, "distant terrain builds a mesh")
	var arrays: Array = dt.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	# per_edge = round(2*radius/cell) = 10 -> (10+1)^2 = 121 vertices.
	assert_eq(verts.size(), 121, "coarse grid has (per_edge+1)^2 vertices")
	var v := verts[60]  # an interior vertex
	assert_almost_eq(v.y, manager.height_at(v.x, v.z) - dt.sink_m, 0.001,
		"distant vertex follows the terrain noise, sunk by sink_m")
	assert_null(dt.get_node_or_null("Collision"), "distant terrain is scenery — no collision body")


func test_distant_terrain_is_full_uncut_grid_regardless_of_loaded_chunks() -> void:
	# The backdrop never holes itself: it underlaps the detail ring entirely and is
	# sunk below it, so it always covers the skybox and needs no per-crossing recut.
	# Same full index count whether or not the detail chunks are loaded.
	var full := 10 * 10 * 6  # per_edge=round(2*50/10)=10 -> 100 cells × 6 indices
	# (a) No detail chunks loaded (manager out of tree -> _ready never runs).
	var m1 = _make_manager([_make_layer(60.0, 1.5)] as Array[TerrainLayer], 1337)
	assert_eq(m1.loaded_coords().size(), 0, "no detail chunks loaded")
	var dt1 := DistantTerrain.new()
	dt1.radius_m = 50.0
	dt1.cell_m = 10.0
	autofree(dt1)
	dt1.setup(m1, null)
	assert_eq(dt1.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX].size(), full,
		"full coarse grid covers the skybox with nothing loaded")
	# (b) Full detail ring loaded -> still a full uncut grid (no hole cut).
	var m2 = _make_manager([_make_layer(60.0, 1.5)] as Array[TerrainLayer], 1337)
	add_child_autofree(m2)  # _ready builds the 3x3 ring
	assert_gt(m2.loaded_coords().size(), 0, "detail ring loaded")
	var dt2 := DistantTerrain.new()
	dt2.radius_m = 50.0
	dt2.cell_m = 10.0
	autofree(dt2)
	dt2.setup(m2, null)
	assert_eq(dt2.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX].size(), full,
		"still a full uncut grid with the detail ring loaded — no holing")


func test_is_streaming_chunks_tracks_pending_work() -> void:
	# DistantTerrain reads this to hold its rebuild until the detail ring is quiet.
	var m := _make_manager([_make_layer(60.0, 1.5)] as Array[TerrainLayer])
	m.force_main_thread_budget = true
	add_child_autofree(m)  # initial ring built synchronously (force_sync) -> idle
	assert_false(m.is_streaming_chunks(), "idle after the initial ring is built")
	# Drive far -> the new ring is queued for the budgeted pump -> streaming.
	m.update_focus(Vector3(ManagerScript.CHUNK_M * 20.0, 0, 0))
	assert_true(m.is_streaming_chunks(), "streaming while the build queue is non-empty")
	# Slicing means the queue can empty while the last chunk is still mid-build, so
	# pump until both the queue AND the active builder are done before asserting idle.
	var guard := 0
	while (not m._build_queue.is_empty() or m._active_builder != null) and guard < 1000:
		m._pump_build_queue()
		guard += 1
	assert_false(m.is_streaming_chunks(), "idle once the queue drains and the build finishes")


func test_distant_terrain_defers_rebuild_until_streaming_is_idle() -> void:
	# A focus chunk crossing must NOT rebuild the coarse backdrop on a frame the
	# detail ring is still streaming — those back-to-back main-thread mesh builds are
	# the chunk-crossing hitch. The rebuild is deferred until the manager is idle.
	var m = _make_manager([_make_layer(60.0, 1.5)] as Array[TerrainLayer], 1337)
	m.force_main_thread_budget = true
	add_child_autofree(m)  # initial ring built; idle
	var focus := Node3D.new()
	add_child_autofree(focus)
	focus.global_position = Vector3.ZERO
	var dt := DistantTerrain.new()
	dt.radius_m = 50.0
	dt.cell_m = 10.0
	autofree(dt)
	dt.setup(m, focus)  # initial build at the origin
	var mesh_before := dt.mesh
	# Cross into a new chunk AND leave the manager busy streaming the new ring.
	focus.global_position = Vector3(ManagerScript.CHUNK_M * 20.0, 0, 0)
	m.update_focus(focus.global_position)
	assert_true(m.is_streaming_chunks(), "manager is streaming the new ring")
	dt._process(0.0)
	assert_eq(dt.mesh, mesh_before, "backdrop NOT rebuilt while the detail ring streams")
	# Drain the detail ring (queue AND the active sliced build) -> the next _process
	# rebuilds the backdrop.
	var guard := 0
	while (not m._build_queue.is_empty() or m._active_builder != null) and guard < 1000:
		m._pump_build_queue()
		guard += 1
	assert_false(m.is_streaming_chunks(), "streaming finished")
	# The rebuild is incremental (a few rows per _process), swapping the mesh in only
	# when complete — so step _process until the new backdrop lands.
	var guard2 := 0
	while dt.mesh == mesh_before and guard2 < 100:
		dt._process(0.0)
		guard2 += 1
	assert_ne(dt.mesh, mesh_before, "backdrop rebuilt (incrementally) once the ring is idle")


func test_distant_terrain_rebuild_is_incremental() -> void:
	# A sliced backdrop rebuild (a few rows per step) must produce the same mesh as a
	# synchronous one, and must actually take more than one step — that's what keeps a
	# re-centre from stalling a single frame.
	var m = _make_manager([_make_layer(60.0, 1.5)] as Array[TerrainLayer], 1337)
	m.light_amount = 1.0
	add_child_autofree(m)
	var dt := DistantTerrain.new()
	dt.radius_m = 50.0  # per_edge = 10 -> 11 rows
	dt.cell_m = 10.0
	autofree(dt)
	dt.setup(m, null)  # synchronous initial build at the origin
	var sync_mesh := dt.mesh
	# Incrementally rebuild around a new centre, 2 rows per step.
	dt._begin_rebuild(Vector3(500.0, 0.0, 500.0))
	var steps := 0
	while dt._building and steps < 1000:
		dt._step_rebuild(2)
		steps += 1
	assert_gt(steps, 1, "incremental rebuild takes more than one step")
	var inc_mesh := dt.mesh
	assert_ne(inc_mesh, sync_mesh, "a fresh mesh is built and swapped in on completion")
	# Compare against a synchronous rebuild at the same centre.
	dt.rebuild_around(Vector3(500.0, 0.0, 500.0))
	var ref_verts: PackedVector3Array = dt.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var inc_verts: PackedVector3Array = inc_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	assert_eq(inc_verts, ref_verts, "incremental backdrop matches the synchronous build")


func test_height_at_is_deterministic_per_seed() -> void:
	var a := _make_manager([_make_layer(60.0, 1.5)] as Array[TerrainLayer], 42)
	var b := _make_manager([_make_layer(60.0, 1.5)] as Array[TerrainLayer], 42)
	var other := _make_manager([_make_layer(60.0, 1.5)] as Array[TerrainLayer], 43)
	var any_differs := false
	for p in SAMPLE_POINTS:
		assert_eq(a.height_at(p.x, p.y), b.height_at(p.x, p.y),
			"same seed gives identical height at %s" % p)
		if not is_equal_approx(a.height_at(p.x, p.y), other.height_at(p.x, p.y)):
			any_differs = true
	assert_true(any_differs, "different seed changes heights somewhere")


func test_doubling_amplitude_doubles_height() -> void:
	var base := _make_manager([_make_layer(60.0, 1.5)] as Array[TerrainLayer])
	var doubled := _make_manager([_make_layer(60.0, 3.0)] as Array[TerrainLayer])
	for p in SAMPLE_POINTS:
		assert_almost_eq(doubled.height_at(p.x, p.y), 2.0 * base.height_at(p.x, p.y), 1e-5,
			"doubling amplitude doubles height at %s" % p)


func test_two_layers_sum_of_individual_layers() -> void:
	var seed_value := 7
	var combined := _make_manager(
		[_make_layer(60.0, 1.5), _make_layer(15.0, 0.4)] as Array[TerrainLayer], seed_value)
	var first := _make_manager([_make_layer(60.0, 1.5)] as Array[TerrainLayer], seed_value)
	# Layer i uses noise seed noise_seed + i, so the second layer alone needs seed + 1.
	var second := _make_manager([_make_layer(15.0, 0.4)] as Array[TerrainLayer], seed_value + 1)
	for p in SAMPLE_POINTS:
		assert_almost_eq(combined.height_at(p.x, p.y),
			first.height_at(p.x, p.y) + second.height_at(p.x, p.y), 1e-5,
			"stacked height is the sum of layers at %s" % p)


func test_invalid_layers_are_skipped() -> void:
	var with_invalid := _make_manager(
		[null, _make_layer(0.0, 5.0), _make_layer(60.0, 1.5)] as Array[TerrainLayer], 11)
	# The valid layer sits at index 2, so it uses noise seed 11 + 2.
	var valid_alone := _make_manager([_make_layer(60.0, 1.5)] as Array[TerrainLayer], 13)
	for p in SAMPLE_POINTS:
		assert_almost_eq(with_invalid.height_at(p.x, p.y), valid_alone.height_at(p.x, p.y), 1e-5,
			"null and zero-wavelength layers contribute nothing at %s" % p)


func test_ready_with_empty_layers_creates_defaults() -> void:
	var m := _make_manager([] as Array[TerrainLayer])
	add_child_autofree(m)  # _ready populates defaults
	assert_eq(m.layers.size(), 3, "three default layers")
	var expected := [[60.0, 1.5], [15.0, 0.4], [3.0, 0.1]]
	for i in mini(m.layers.size(), 3):
		assert_eq(m.layers[i].wavelength_m, float(expected[i][0]), "layer %d wavelength" % i)
		assert_eq(m.layers[i].amplitude_m, float(expected[i][1]), "layer %d amplitude" % i)


func test_chunk_coord_for_partitions_by_chunk_size() -> void:
	var m := _make_manager([_make_layer(60.0, 1.5)] as Array[TerrainLayer])
	var s: float = ManagerScript.CHUNK_M
	assert_eq(m.chunk_coord_for(Vector3(0, 0, 0)), Vector2i(0, 0))
	assert_eq(m.chunk_coord_for(Vector3(s * 0.5, 0, s * 0.5)), Vector2i(0, 0))
	assert_eq(m.chunk_coord_for(Vector3(s, 0, 0)), Vector2i(1, 0))
	assert_eq(m.chunk_coord_for(Vector3(-1, 0, -1)), Vector2i(-1, -1))


func test_target_coords_is_full_ring() -> void:
	var m := _make_manager([_make_layer(60.0, 1.5)] as Array[TerrainLayer])
	var ring: int = 2 * ManagerScript.RADIUS + 1
	var coords: Array = m.target_coords(Vector2i(0, 0))
	assert_eq(coords.size(), ring * ring, "(2*RADIUS+1)^2 ring around centre")
	assert_true(coords.has(Vector2i(0, 0)), "includes centre")
	assert_true(coords.has(Vector2i(ManagerScript.RADIUS, ManagerScript.RADIUS)), "includes a corner")
	assert_false(coords.has(Vector2i(ManagerScript.RADIUS + 1, 0)), "excludes just outside the ring")


func test_car_spawns_just_above_terrain() -> void:
	var scene: Node3D = load("res://main.tscn").instantiate()
	add_child_autofree(scene)
	var car := scene.get_node("Car") as VehicleBody3D
	var floor_node := scene.get_node("Floor")
	var expected: float = (
		floor_node.height_at(car.global_position.x, car.global_position.z)
		+ Config.data.spawn_clearance
	)
	assert_almost_eq(car.global_position.y, expected, 0.01,
		"car lifted to terrain height + spawn_clearance at spawn")

	# Chunk meshes must use the node-level material_override: surface_material_override/0
	# silently fails to load when the mesh is assigned at runtime (no surfaces
	# exist yet), leaving the floor with the default material.
	var center: Vector2i = floor_node.chunk_coord_for(car.global_position)
	var chunk = floor_node._chunks[center]
	var mi: MeshInstance3D = chunk.get_node("MeshInstance3D")
	assert_not_null(mi.material_override, "chunk material survives runtime mesh assignment")


func test_chunk_builds_mesh_and_collision() -> void:
	var m := _make_manager([_make_layer(60.0, 1.5)] as Array[TerrainLayer], 21)
	add_child_autofree(m)  # _ready loads the ring around origin (no focus -> origin)
	var samples: int = ManagerScript.SAMPLES
	var ring: int = 2 * ManagerScript.RADIUS + 1
	assert_eq(m.loaded_coords().size(), ring * ring, "full ring of chunks loaded around origin")

	var chunk = m._chunks[Vector2i(0, 0)]
	var mesh := chunk.get_node("MeshInstance3D").mesh as ArrayMesh
	assert_not_null(mesh, "chunk mesh is an ArrayMesh")
	assert_eq(mesh.surface_get_array_len(0), samples * samples, "one shared vertex per grid sample (indexed mesh)")

	var col: CollisionShape3D = chunk.get_node("CollisionShape3D")
	var shape := col.shape as HeightMapShape3D
	assert_eq(shape.map_width, samples, "map_width matches sample count")
	var cell_m: float = ManagerScript.CELL_M
	assert_eq(col.scale, Vector3(cell_m, 1.0, cell_m), "collision scaled to CELL_M cells")


func test_adjacent_chunks_agree_on_shared_edge() -> void:
	# Chunk (0,0) and chunk (1,0) are side by side; their shared edge (the plane
	# x = CHUNK_M) must produce identical heights from each chunk's sampling.
	var m := _make_manager([_make_layer(60.0, 1.5), _make_layer(15.0, 0.4)] as Array[TerrainLayer], 9)
	var c0 := Vector3((0 + 0.5) * ManagerScript.CHUNK_M, 0, (0 + 0.5) * ManagerScript.CHUNK_M)
	var c1 := Vector3((1 + 0.5) * ManagerScript.CHUNK_M, 0, (0 + 0.5) * ManagerScript.CHUNK_M)
	var h0: PackedFloat32Array = m.build_heights(c0)
	var h1: PackedFloat32Array = m.build_heights(c1)
	var samples: int = ManagerScript.SAMPLES
	for zi in samples:
		var right_edge: float = h0[zi * samples + (samples - 1)]  # x = c0.x + half = 100
		var left_edge: float = h1[zi * samples + 0]               # x = c1.x - half = 100
		assert_almost_eq(left_edge, right_edge, 1e-5,
			"chunk seam heights agree at row %d" % zi)


func test_moving_focus_loads_and_unloads_chunks() -> void:
	var m := _make_manager([_make_layer(60.0, 1.5)] as Array[TerrainLayer])
	add_child_autofree(m)
	m.update_focus(Vector3.ZERO)
	assert_true(m._chunks.has(Vector2i(0, 0)), "centre chunk loaded at origin")
	var far_pos := Vector3(ManagerScript.CHUNK_M * 10.0, 0, 0)
	var far_coord: Vector2i = m.chunk_coord_for(far_pos)
	assert_false(m._chunks.has(far_coord), "far chunk not loaded")

	# Move far away: the origin chunk should unload, the new ring should load.
	m.update_focus(far_pos)
	var ring: int = 2 * ManagerScript.RADIUS + 1
	assert_eq(m.loaded_coords().size(), ring * ring, "still exactly one full ring loaded")
	assert_true(m._chunks.has(far_coord), "new centre chunk loaded")
	assert_false(m._chunks.has(Vector2i(0, 0)), "origin chunk unloaded")


func test_compute_chunk_data_shapes_and_heights() -> void:
	var m := _make_manager([_make_layer(60.0, 1.5), _make_layer(15.0, 0.4)] as Array[TerrainLayer], 21)
	var samples: int = ManagerScript.SAMPLES
	var cells := (samples - 1) * (samples - 1)
	var data: Dictionary = m.compute_chunk_data(Vector2i(0, 0))

	var verts: PackedVector3Array = data["vertices"]
	var uvs: PackedVector2Array = data["uvs"]
	var colors: PackedColorArray = data["colors"]
	var indices: PackedInt32Array = data["indices"]
	var heights: PackedFloat32Array = data["heights"]
	assert_eq(verts.size(), samples * samples, "one shared vertex per grid sample (indexed mesh)")
	assert_eq(uvs.size(), samples * samples, "one uv per shared vertex")
	assert_eq(colors.size(), samples * samples, "one colour per shared vertex")
	assert_eq(indices.size(), cells * 6, "two triangles per cell")
	assert_eq(heights.size(), samples * samples, "height array still one per sample (collision)")

	var center: Vector3 = data["center"]
	var bh: PackedFloat32Array = m.build_heights(center)
	for i in [0, samples * samples / 2, samples * samples - 1]:
		assert_almost_eq(heights[i], bh[i], 1e-5, "compute_chunk_data height %d matches build_heights" % i)


func test_vertex_colors_carry_road_weight_in_alpha() -> void:
	var m := _make_manager([_make_layer(60.0, 1.5)] as Array[TerrainLayer], 21)
	var samples: int = ManagerScript.SAMPLES
	m.default_cell_color = Color(0.2, 0.4, 0.6)
	# A 2x2 block of fully-on-road cells around grid vertex (1,1).
	m.track_weights = {
		Vector2i(0, 0): 1.0, Vector2i(1, 0): 1.0,
		Vector2i(0, 1): 1.0, Vector2i(1, 1): 1.0,
	}
	var colors: PackedColorArray = m.vertex_colors(Vector2i(0, 0))
	# RGB is always the flat ground tint; the road blend lives in ALPHA.
	for c in colors:
		assert_eq(Color(c.r, c.g, c.b), m.default_cell_color, "rgb is the ground tint")
	# Vertex (1,1) is surrounded by all four weight-1 cells -> alpha 1 (full road).
	assert_almost_eq(colors[1 * samples + 1].a, 1.0, 0.001, "vertex inside the block -> alpha 1")
	# Vertex (0,0) touches only cell (0,0) (the other three are absent=0) -> 0.25.
	assert_almost_eq(colors[0].a, 0.25, 0.001, "corner vertex -> quarter weight")
	# A far vertex touches no weighted cell -> alpha 0 (pure ground).
	assert_almost_eq(colors[samples * samples - 1].a, 0.0, 0.001, "vertex away from road -> alpha 0")


func test_terrain_bakes_static_lighting_into_vertex_colours() -> void:
	# Steep layer so vertex normals vary and the baked shading has something to
	# shade. White tint -> a vertex's RGB IS the baked light, all grey (grey sun).
	var lit := _make_manager([_make_layer(20.0, 6.0)] as Array[TerrainLayer], 7)
	lit.default_cell_color = Color(1, 1, 1)
	lit.light_amount = 1.0
	lit.sun_dir = Vector3(0.4, 0.9, 0.35).normalized()
	lit.sun_color = Color(0.5, 0.5, 0.5)
	lit.sky_color = Color(0.5, 0.5, 0.5)
	lit.ground_color = Color(0.35, 0.35, 0.35)
	var colors: PackedColorArray = lit.compute_chunk_data(Vector2i(0, 0))["colors"]
	var lo := 1.0
	var hi := 0.0
	for c in colors:
		assert_almost_eq(c.r, c.g, 1e-5, "grey light keeps channels equal")
		lo = minf(lo, c.r)
		hi = maxf(hi, c.r)
	# Range is [ground .. sky+sun] = [0.35 .. 1.0]; the slopes must produce real
	# variation rather than a constant tint, and every value stays in range.
	assert_gt(hi - lo, 0.02, "baked shading varies across the sloped terrain")
	assert_true(lo >= 0.35 - 1e-4, "darkest vertex no darker than the ambient floor")
	assert_true(hi <= 1.0 + 1e-4, "brightest vertex stays within range")


func test_incremental_build_matches_full_build() -> void:
	# Stepping a TerrainChunkBuilder a few rows at a time must yield byte-identical
	# arrays to compute_chunk_data (which runs the same builder to completion) — this
	# is what lets the budgeted web path slice a chunk across frames without changing
	# the terrain. Lit + a baked road so every output array carries real variation.
	var m := _make_manager(
		[_make_layer(60.0, 1.5), _make_layer(15.0, 0.4)] as Array[TerrainLayer], 21)
	m.light_amount = 1.0
	var curve := Curve2D.new()  # a straight through chunk (2,-1) so road fields apply
	curve.add_point(Vector2(120.0, -30.0))
	curve.add_point(Vector2(160.0, -30.0))
	m.bake_track(curve, 6.0, 2.0, 0.5, false, 4.0)
	var coord := Vector2i(2, -1)
	var full: Dictionary = m.compute_chunk_data(coord)
	# Fresh builder, stepped 3 rows at a time to force many resumes.
	var b := TerrainChunkBuilder.new(m, coord)
	var guard := 0
	while not b.complete and guard < 10000:
		b.step(3)
		guard += 1
	assert_true(b.complete, "stepped builder reaches completion")
	var inc: Dictionary = b.data()
	for key in ["center", "heights", "vertices", "uvs", "colors", "uv2s", "indices"]:
		assert_eq(inc[key], full[key], "incremental %s matches the full build" % key)


func test_baked_light_halo_matches_per_vertex_sampling() -> void:
	# compute_chunk_data now reads each vertex's four light neighbours from a shared
	# pure-height halo instead of re-sampling the noise 4× per vertex. That must stay
	# bit-identical to the reference single-sample path (light_at -> _bake_light) at
	# interior, corner AND edge vertices (the halo extends one cell past the chunk).
	var m := _make_manager([_make_layer(20.0, 6.0)] as Array[TerrainLayer], 7)
	m.default_cell_color = Color(1, 1, 1)  # white tint -> a vertex's RGB IS the baked light
	m.light_amount = 1.0
	m.sun_dir = Vector3(0.4, 0.9, 0.35).normalized()
	m.sun_color = Color(0.5, 0.5, 0.5)
	m.sky_color = Color(0.5, 0.5, 0.5)
	m.ground_color = Color(0.35, 0.35, 0.35)
	var coord := Vector2i(0, 0)
	var colors: PackedColorArray = m.compute_chunk_data(coord)["colors"]
	var samples: int = ManagerScript.SAMPLES
	var half: float = ManagerScript.CHUNK_M / 2.0
	var center := Vector3((coord.x + 0.5) * ManagerScript.CHUNK_M, 0.0,
		(coord.y + 0.5) * ManagerScript.CHUNK_M)
	for v in [Vector2i(25, 25), Vector2i(0, 0), Vector2i(samples - 1, samples - 1),
			Vector2i(0, 30), Vector2i(samples - 1, 10)]:
		var wx: float = center.x - half + v.x * ManagerScript.CELL_M
		var wz: float = center.z - half + v.y * ManagerScript.CELL_M
		var ref: Color = m.light_at(wx, wz)  # untouched 4-sample reference path
		var c: Color = colors[v.y * samples + v.x]
		assert_almost_eq(c.r, ref.r, 1e-5, "halo light matches reference at %s (r)" % v)
		assert_almost_eq(c.g, ref.g, 1e-5, "halo light matches reference at %s (g)" % v)
		assert_almost_eq(c.b, ref.b, 1e-5, "halo light matches reference at %s (b)" % v)


func test_terrain_lighting_off_keeps_flat_tint() -> void:
	# light_amount 0 -> the bake is a no-op white multiply, RGB is the raw tint.
	var flat := _make_manager([_make_layer(20.0, 6.0)] as Array[TerrainLayer], 7)
	flat.default_cell_color = Color(0.2, 0.4, 0.6)
	flat.light_amount = 0.0
	var colors: PackedColorArray = flat.compute_chunk_data(Vector2i(0, 0))["colors"]
	for c in colors:
		assert_almost_eq(c.r, 0.2, 1e-5, "r is the flat tint when unlit")
		assert_almost_eq(c.g, 0.4, 1e-5, "g is the flat tint when unlit")
		assert_almost_eq(c.b, 0.6, 1e-5, "b is the flat tint when unlit")


func test_threaded_generation_loads_ring() -> void:
	var m := _make_manager([_make_layer(60.0, 1.5)] as Array[TerrainLayer])
	m.use_threaded_generation = true
	add_child_autofree(m)  # _ready builds the origin ring synchronously
	var ring: int = 2 * ManagerScript.RADIUS + 1
	var ring_count := ring * ring
	assert_eq(m.loaded_coords().size(), ring_count, "origin ring built synchronously at ready")

	# Drive far away -> the new ring is requested on worker threads.
	var far_pos := Vector3(ManagerScript.CHUNK_M * 20.0, 0, 0)
	var far_coord: Vector2i = m.chunk_coord_for(far_pos)
	m.update_focus(far_pos)
	assert_eq(m._pending.size(), ring_count, "full ring of chunks requested for the new ring")
	assert_eq(m.loaded_coords().size(), 0, "old ring freed; new ring not yet integrated")

	# Wait for the workers, then integrate (cap is 1/frame, so pump until drained).
	for coord in m._pending.keys():
		WorkerThreadPool.wait_for_task_completion(m._pending[coord])
	var guard := 0
	while not m._pending.is_empty() and guard < 100:
		m._integrate_ready()
		guard += 1
	assert_eq(m.loaded_coords().size(), ring_count, "all requested chunks integrated")
	assert_true(m._chunks.has(far_coord), "centre of the new ring loaded")


func test_integrate_discards_out_of_ring_results() -> void:
	# A worker result that finished after its coord left the ring must be
	# discarded (not spawned) and its pending slot released.
	var m := _make_manager([_make_layer(60.0, 1.5)] as Array[TerrainLayer])
	add_child_autofree(m)  # synchronous; loads origin ring, _last_focus_coord = (0,0)
	var stale := Vector2i(99, 99)  # far outside the loaded ring around origin
	m._pending[stale] = 0
	m._results[stale] = m.compute_chunk_data(stale)
	var before: int = m.loaded_coords().size()
	m._integrate_ready()
	assert_false(m._chunks.has(stale), "out-of-ring result discarded, not spawned")
	assert_false(m._pending.has(stale), "pending slot released for discarded result")
	assert_eq(m.loaded_coords().size(), before, "no extra chunk added")


func test_defer_initial_build_skips_ring_until_called() -> void:
	var m := _make_manager([_make_layer(60.0, 1.5)] as Array[TerrainLayer], 21)
	m.defer_initial_build = true
	add_child_autofree(m)  # _ready must NOT build the ring when deferred
	assert_eq(m.loaded_coords().size(), 0, "no chunks built when deferred")
	m.build_initial()
	var ring: int = 2 * ManagerScript.RADIUS + 1
	assert_eq(m.loaded_coords().size(), ring * ring, "build_initial builds the full ring")


func test_smooth_ramp_is_one_inside_zero_outside_half_at_mid() -> void:
	assert_eq(ManagerScript.smooth_ramp(0.5, 3.0, 4.5), 1.0, "fully road at/inside inner")
	assert_eq(ManagerScript.smooth_ramp(5.0, 3.0, 4.5), 0.0, "terrain at/beyond outer")
	# Band midpoint d = 3.75: raw = 0.5 -> smoothstep 0.5*0.5*(3-2*0.5) = 0.5.
	assert_almost_eq(ManagerScript.smooth_ramp(3.75, 3.0, 4.5), 0.5, 0.001, "smoothstep is 0.5 at band mid")


func test_bake_track_weights_inside_band_outside() -> void:
	var m := _make_manager([_make_layer(20.0, 3.0)] as Array[TerrainLayer], 5)
	var curve := Curve2D.new()
	curve.add_point(Vector2(0.0, 0.0))
	curve.add_point(Vector2(20.0, 0.0))
	m.bake_track(curve, 2.0, 2.0)  # inner = width/2 = 1.0, outer = 3.0
	var on := Vector2i(roundi(10.0 / ManagerScript.CELL_M), 0)  # world (10, 0)
	assert_almost_eq(m.road_blend[on], 1.0, 1e-4, "vertex on the road has full weight")
	assert_almost_eq(m.road_heights[on], m.height_at(10.0, 0.0), 0.1, "road height sampled from terrain")
	# World (10, 2): d = 2.0 sits between inner 1.0 and outer 3.0 -> partial weight.
	# (Landing mid-band needs a grid vertex inside the band; widened above so 1 m
	# cells have one.)
	var band := Vector2i(roundi(10.0 / ManagerScript.CELL_M), roundi(2.0 / ManagerScript.CELL_M))
	assert_true(m.road_blend.has(band), "band vertex present")
	assert_gt(m.road_blend[band], 0.0, "band weight > 0")
	assert_lt(m.road_blend[band], 1.0, "band weight < 1")
	var far := Vector2i(roundi(10.0 / ManagerScript.CELL_M), roundi(4.0 / ManagerScript.CELL_M))  # (10, 4)
	assert_false(m.road_blend.has(far), "vertex beyond the band is absent")
	assert_gt(m.track_weights.size(), 0, "per-cell colour weights baked too")


func test_bake_track_surface_split_and_surface_at() -> void:
	# A 40 m straight along +X. 50% tarmac, gravel-first: gravel near the start,
	# tarmac near the end, with the switch ~halfway. surface_at reports both the
	# road weight (1 on road) and the tarmac weight at a world XZ.
	var m := _make_manager([_make_layer(20.0, 3.0)] as Array[TerrainLayer], 5)
	var curve := Curve2D.new()
	curve.add_point(Vector2(0.0, 0.0))
	curve.add_point(Vector2(40.0, 0.0))
	m.bake_track(curve, 4.0, 2.0, 0.5, false, 4.0)  # 50% tarmac, gravel first
	assert_gt(m.track_surface.size(), 0, "per-cell tarmac weights baked")
	assert_eq(m.track_surface.size(), m.track_weights.size(), "tarmac keyed like road weights")
	# On the road near the start = gravel (tarmac weight ~0); near the end = tarmac (~1).
	var start: Vector2 = m.surface_at(2.0, 0.0)
	var finish: Vector2 = m.surface_at(38.0, 0.0)
	assert_almost_eq(start.x, 1.0, 1e-4, "on the road at the start")
	assert_almost_eq(finish.x, 1.0, 1e-4, "on the road at the end")
	assert_lt(start.y, 0.1, "start is gravel (low tarmac weight)")
	assert_gt(finish.y, 0.9, "end is tarmac (high tarmac weight)")
	# Off the road entirely: both weights zero (grass / gravel defaults).
	var off: Vector2 = m.surface_at(2.0, 50.0)
	assert_eq(off.x, 0.0, "off-road has no road weight")
	assert_eq(off.y, 0.0, "off-road has no tarmac weight")


func test_compute_chunk_data_bakes_tarmac_into_uv2() -> void:
	# track_surface (per-cell tarmac weight) is averaged into the mesh UV2.x so the
	# shader can fade gravel -> tarmac. A fully-tarmac cell cluster -> UV2.x ~1.
	var m := _make_manager([_make_layer(20.0, 3.0)] as Array[TerrainLayer], 5)
	m.track_surface = {
		Vector2i(9, 0): 1.0, Vector2i(10, 0): 1.0,
		Vector2i(9, -1): 1.0, Vector2i(10, -1): 1.0,
	}
	var data: Dictionary = m.compute_chunk_data(Vector2i(0, 0))
	assert_true(data.has("uv2s"), "chunk data carries uv2s")
	var uv2s: PackedVector2Array = data["uv2s"]
	# Vertex (xi=10, zi=0) is surrounded by the four tarmac cells above -> ~1.
	assert_almost_eq(uv2s[0 * ManagerScript.SAMPLES + 10].x, 1.0, 1e-4, "tarmac vertex UV2.x = 1")
	# A vertex far from any surface cell averages no cells -> 0 (gravel default).
	assert_eq(uv2s[25 * ManagerScript.SAMPLES + 25].x, 0.0, "off-surface vertex UV2.x = 0")


func test_compute_chunk_data_blends_road_height() -> void:
	var m := _make_manager([_make_layer(20.0, 3.0)] as Array[TerrainLayer], 5)
	var v_full := Vector2i(10, 0)  # chunk (0,0) local (xi=10, zi=0)
	var v_half := Vector2i(12, 0)  # local (xi=12, zi=0)
	m.road_heights = { v_full: 50.0, v_half: 50.0 }
	m.road_blend = { v_full: 1.0, v_half: 0.5 }
	var data: Dictionary = m.compute_chunk_data(Vector2i(0, 0))
	var heights: PackedFloat32Array = data["heights"]
	var verts: PackedVector3Array = data["vertices"]
	assert_almost_eq(heights[10], 50.0, 1e-4, "full-weight vertex fully flattened (collision)")
	assert_almost_eq(verts[10].y, 50.0, 1e-4, "full-weight vertex fully flattened (mesh)")
	# Sample (xi=12, zi=0) -> world x = 12*CELL_M, z = 0; blended halfway to 50.
	var bx := 12.0 * ManagerScript.CELL_M
	var expected := lerpf(m.height_at(bx, 0.0), 50.0, 0.5)
	assert_almost_eq(heights[12], expected, 1e-3, "band vertex height blended halfway")


func test_set_track_bakes_fields_and_rebuilds_loaded_chunks() -> void:
	var m := _make_manager([_make_layer(20.0, 3.0)] as Array[TerrainLayer], 5)
	add_child_autofree(m)  # ring built in _ready (not deferred in tests)
	var curve := Curve2D.new()  # a straight through chunk (0,0) (world [0,50])
	curve.add_point(Vector2(5.0, 5.0))
	curve.add_point(Vector2(45.0, 5.0))
	m.set_track(curve, 6.0, 1.5)
	assert_gt(m.road_blend.size(), 0, "set_track baked road blend weights")
	assert_gt(m.track_weights.size(), 0, "set_track baked road weights")
	var chunk = m._chunks[Vector2i(0, 0)]
	var colors: PackedColorArray = (chunk.get_node("MeshInstance3D").mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	var has_road := false
	for c in colors:
		if c.a > 0.99:  # full road weight baked into the vertex-colour alpha
			has_road = true
			break
	assert_true(has_road, "rebuilt chunk carries full road weight (alpha 1) where fully on-road")


func test_budgeted_generation_spreads_builds_across_frames() -> void:
	# The web export builds chunks on a frame-budgeted main-thread queue (see
	# _use_budgeted_generation). force_main_thread_budget drives that path on desktop.
	var m := _make_manager([_make_layer(60.0, 1.5)] as Array[TerrainLayer])
	m.force_main_thread_budget = true
	add_child_autofree(m)  # _ready builds the origin ring synchronously (force_sync)
	var ring: int = 2 * ManagerScript.RADIUS + 1
	var ring_count := ring * ring
	assert_eq(m.loaded_coords().size(), ring_count, "origin ring built synchronously at ready")

	# Drive far away: the old ring frees and the new ring is QUEUED, not built yet.
	var far_pos := Vector3(ManagerScript.CHUNK_M * 20.0, 0, 0)
	var far_coord: Vector2i = m.chunk_coord_for(far_pos)
	m.update_focus(far_pos)
	assert_eq(m.loaded_coords().size(), 0, "old ring freed; new ring not built on the crossing tick")
	assert_eq(m._build_queue.size(), ring_count, "full new ring queued for the budgeted pump")

	# A chunk is many more rows than one frame's budget, so a single pump completes
	# NO chunk — it only advances the first chunk partway (that's the slicing).
	m._pump_build_queue()
	assert_eq(m.loaded_coords().size(), 0, "one pump doesn't finish a whole chunk (row-sliced)")
	assert_false(m._active_builder == null, "a chunk build is in progress across frames")

	# Pump until the queue drains AND the active build finishes -> the whole ring lands.
	var guard := 0
	while (not m._build_queue.is_empty() or m._active_builder != null) and guard < 1000:
		m._pump_build_queue()
		guard += 1
	assert_eq(m.loaded_coords().size(), ring_count, "all queued chunks eventually built")
	assert_true(m._chunks.has(far_coord), "centre of the new ring loaded")


func test_budgeted_pump_skips_coords_that_left_the_ring() -> void:
	# A coord queued then driven out of the ring before the pump reaches it is
	# discarded, not built.
	var m := _make_manager([_make_layer(60.0, 1.5)] as Array[TerrainLayer])
	m.force_main_thread_budget = true
	add_child_autofree(m)
	# Queue a ring far away without pumping.
	var far_pos := Vector3(ManagerScript.CHUNK_M * 20.0, 0, 0)
	m.update_focus(far_pos)
	assert_gt(m._build_queue.size(), 0, "new ring queued")
	# Jump somewhere else entirely before the pump runs: the queued coords are now
	# out of the ring and must be skipped.
	var other_pos := Vector3(0, 0, ManagerScript.CHUNK_M * 40.0)
	m.update_focus(other_pos)
	var guard := 0
	while (not m._build_queue.is_empty() or m._active_builder != null) and guard < 1000:
		m._pump_build_queue()
		guard += 1
	var ring: int = 2 * ManagerScript.RADIUS + 1
	assert_eq(m.loaded_coords().size(), ring * ring, "only the current ring is built")
	assert_true(m._chunks.has(m.chunk_coord_for(other_pos)), "current focus chunk loaded")
