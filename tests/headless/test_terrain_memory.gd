extends GutTest
# The terrain memory cluster: what the chunk cache and the track bake KEEP versus
# what they drop, and the sentinels that make a wrong post-free read loud.
# See todo/mobile-web-performance.md 1.6 / 1.7 / 2.7 and features/terrain.md.
#
# All logic/behaviour assertions — nothing here pins a byte count, a cache size in
# MB or any GameConfig tunable; those scale with the authored terrain settings.

const ManagerScript := preload("res://scripts/terrain_manager.gd")
const ChunkScript := preload("res://scripts/terrain_chunk.gd")


func _make_manager() -> TerrainManager:
	var m := Node3D.new()
	m.set_script(ManagerScript)
	m.focus_path = NodePath("")
	m.defer_initial_build = true
	m.noise_seed = 1337
	add_child_autofree(m)
	return m


func _straight_centerline() -> Curve2D:
	var c := Curve2D.new()
	c.add_point(Vector2(0, 0))
	c.add_point(Vector2(300, 0))
	return c


# A precomputed manager with a road baked in, so the flatten/surface fields are real.
func _baked_manager() -> TerrainManager:
	var m := _make_manager()
	m.light_amount = 1.0
	var line := _straight_centerline()
	await m.bake_track(line, 7.0, 3.0)
	m.precompute_corridor(line, 25.0)
	return m


func _collision_of(chunk: TerrainChunk) -> CollisionShape3D:
	for child in chunk.get_children():
		if child is CollisionShape3D:
			return child
	return null


# --- 1.6: the dead mesh-source arrays -------------------------------------------

func test_cache_drops_mesh_source_arrays_but_keeps_heights() -> void:
	var m: TerrainManager = await _baked_manager()
	var data: Dictionary = m._chunk_cache[Vector2i(1, 0)]
	for key in TerrainManager.DEAD_AFTER_PREBAKE:
		assert_false(data.has(key),
			"%s is consumed by the LOD prebake and must not stay resident" % key)
	assert_eq((data["heights"] as PackedFloat32Array).size(),
		TerrainManager.SAMPLES * TerrainManager.SAMPLES,
		"heights stay — collision and height_at read them every frame")
	assert_false((data["lod_meshes"] as Array).is_empty(),
		"the prebaked meshes are what make dropping the source arrays safe")


func test_spawned_chunk_from_cache_still_has_correct_collision_and_height() -> void:
	var m: TerrainManager = await _baked_manager()
	m.update_focus(Vector3(150, 0, 0))
	var coord := m.chunk_coord_for(Vector3(150, 0, 0))
	var chunk: TerrainChunk = m._chunks[coord]
	var shape := _collision_of(chunk).shape as HeightMapShape3D
	assert_not_null(shape, "a full-res cached chunk still builds its heightfield")
	var heights: PackedFloat32Array = m._chunk_cache[coord]["heights"]
	assert_eq(shape.map_data, heights, "collision heightfield is the cached grid")
	# And the mesh survived: the prebaked LOD meshes are still assigned.
	var meshed := 0
	for child in chunk.get_children():
		if child is MeshInstance3D and child.mesh != null:
			meshed += 1
	assert_gt(meshed, 0, "the chunk still renders from its prebaked LOD meshes")
	# height_at on a grid vertex equals the cached sample it was built from.
	var wx := coord.x * TerrainManager.CHUNK_M + 10.0
	var wz := coord.y * TerrainManager.CHUNK_M + 20.0
	assert_almost_eq(m.height_at(wx, wz),
		heights[20 * TerrainManager.SAMPLES + 10], 1e-5,
		"height_at still resolves against the cached grid after the frees")


func test_chunk_can_be_despawned_and_respawned_from_cache() -> void:
	var m: TerrainManager = await _baked_manager()
	m.update_focus(Vector3(50, 0, 0))
	var coord := m.chunk_coord_for(Vector3(50, 0, 0))
	var before: PackedFloat32Array = \
		(_collision_of(m._chunks[coord]).shape as HeightMapShape3D).map_data
	# Drive further along the track (staying inside the corridor, so no cache miss)
	# until the chunk falls outside the ring, then come back.
	m.update_focus(Vector3(50 + (TerrainManager.RADIUS + 1) * TerrainManager.CHUNK_M, 0, 0))
	assert_false(m._chunks.has(coord), "precondition: the chunk was unloaded")
	m.update_focus(Vector3(50, 0, 0))
	assert_true(m._chunks.has(coord), "the chunk re-spawns from cache after unloading")
	var after: PackedFloat32Array = \
		(_collision_of(m._chunks[coord]).shape as HeightMapShape3D).map_data
	assert_eq(after, before, "the re-spawned chunk is identical — the cache is reusable")


func test_apply_data_without_meshes_or_source_arrays_errors_and_keeps_collision() -> void:
	# The landmine 1.6 disarms: apply_data's build_all fallback would read arrays the
	# cache no longer holds. It must complain loudly instead of building garbage — and
	# still produce collision, which only needs `heights`.
	var m: TerrainManager = await _baked_manager()
	var coord := Vector2i(1, 0)
	var stripped: Dictionary = (m._chunk_cache[coord] as Dictionary).duplicate()
	stripped["lod_meshes"] = []
	var chunk: TerrainChunk = ChunkScript.new()
	add_child_autofree(chunk)
	chunk.apply_data(m, coord, stripped)
	assert_push_error("no prebaked lod_meshes")
	assert_not_null(_collision_of(chunk).shape,
		"collision only needs heights, so it still builds")


# --- 1.7: the baked lights + its sentinel ---------------------------------------

func test_light_at_serves_baked_light_before_the_free() -> void:
	var m: TerrainManager = await _baked_manager()
	var baked: PackedColorArray = m._chunk_cache[Vector2i(1, 0)]["lights"]
	var at_vertex: Color = m.light_at(TerrainManager.CHUNK_M + 10.0, 10.0)
	assert_almost_eq(at_vertex.r, baked[10 * TerrainManager.SAMPLES + 10].r, 0.01,
		"before the free, light_at is the baked value")


func test_freeing_lights_makes_a_later_light_at_loud() -> void:
	var m: TerrainManager = await _baked_manager()
	m.free_load_only_data()
	for data in m._chunk_cache.values():
		assert_false(data.has("lights"), "baked light is dropped from every cached chunk")
	var _ignored: Color = m.light_at(TerrainManager.CHUNK_M + 10.0, 10.0)
	# The whole point of the sentinel: this call silently returned a live-noise
	# re-bake before, and now says so.
	assert_push_error("after the baked terrain light was freed")


# --- 2.7: the bake dictionaries -------------------------------------------------

func test_surface_at_survives_the_bake_field_free() -> void:
	var m: TerrainManager = await _baked_manager()
	var on_road := m.surface_at(150.0, 0.0)
	var off_road := m.surface_at(150.0, 400.0)
	assert_gt(on_road.x, 0.0, "precondition: the sampled point is on the road")
	m.free_load_only_data()
	assert_eq(m.surface_at(150.0, 0.0), on_road,
		"track_weights/track_surface must survive — surface_at drives per-tick grip")
	assert_eq(m.surface_at(150.0, 400.0), off_road, "off-track grip is unchanged too")


func test_bake_fields_freed_once_the_corridor_is_complete() -> void:
	var m: TerrainManager = await _baked_manager()
	assert_true(m.corridor_complete(), "precondition: every corridor chunk is cached")
	assert_false(m.road_blend.is_empty(), "precondition: the road bake produced fields")
	m.free_load_only_data()
	assert_true(m.road_heights.is_empty(), "road_heights is chunk-build-only data")
	assert_true(m.road_blend.is_empty(), "road_blend is chunk-build-only data")
	assert_true(m.cliff_offsets.is_empty(), "cliff_offsets is chunk-build-only data")


func test_incomplete_corridor_keeps_the_bake_fields() -> void:
	# The editor / on-demand path never precomputes, so the fields are still live
	# input for the next chunk build and must NOT be freed.
	var m := _make_manager()
	await m.bake_track(_straight_centerline(), 7.0, 3.0)
	assert_false(m.corridor_complete(), "no corridor was precomputed")
	m.free_load_only_data()
	assert_false(m.road_blend.is_empty(),
		"without a complete corridor the bake fields stay — chunks still need them")


func test_on_demand_rebuild_still_flattens_after_the_gate_fired() -> void:
	# A manager whose corridor completed and freed its fields can still serve the
	# empty-cache on-demand build path once a fresh bake restores them.
	var m: TerrainManager = await _baked_manager()
	m.free_load_only_data()
	var line := _straight_centerline()
	await m.bake_track(line, 7.0, 3.0)
	assert_false(m.road_blend.is_empty(), "a re-bake restores the fields")
	m._chunk_cache.clear()
	m.update_focus(Vector3(150, 0, 0))
	var coord := m.chunk_coord_for(Vector3(150, 0, 0))
	assert_true(m._chunks.has(coord), "the empty-cache on-demand build path still works")
	# And the rebuilt geometry is genuinely FLATTENED, not raw noise: a vertex a few
	# metres off the centerline must sit at lerp(noise, road height, blend).
	var zi := 3
	var road_v := Vector2i(coord.x * (TerrainManager.SAMPLES - 1), zi)
	assert_true(m.road_blend.has(road_v),
		"precondition: vertex %s is inside the road band" % road_v)
	var heights: PackedFloat32Array = m.compute_chunk_data(coord)["heights"]
	var wx := float(road_v.x)
	var expected := lerpf(m._noise_height_at(wx, float(zi)),
		m.road_heights[road_v], m.road_blend[road_v])
	assert_almost_eq(heights[zi * TerrainManager.SAMPLES], expected, 1e-4,
		"the on-demand rebuild still applies the road flatten")
