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


# --- 3.6: the lazily-built finest LOD level -------------------------------------

func _mesh_instances_of(chunk: TerrainChunk) -> Array:
	var out: Array = []
	for child in chunk.get_children():
		if child is MeshInstance3D:
			out.append(child)
	return out


# A chunk spawned from the cache still renders real ground under the car even though its
# finest level was never prebaked: the level is built on entry to the detail ring, and its
# geometry agrees with the collision heightfield it shares.
func test_lazily_built_finest_level_has_the_cached_geometry() -> void:
	var m: TerrainManager = await _baked_manager()
	assert_true(m.lazy_finest_lod, "precondition: the finest level is deferred")
	var focus := Vector3(150, 0, 0)
	m.update_focus(focus)
	m.flush_detail_queue()
	var coord := m.chunk_coord_for(focus)
	var chunk: TerrainChunk = m._chunks[coord]
	assert_true(chunk.has_finest_mesh(), "the chunk under the focus builds its finest level")
	var mesh: ArrayMesh = _mesh_instances_of(chunk)[0].mesh
	var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var samples := TerrainManager.SAMPLES
	assert_gte(verts.size(), samples * samples, "the level is the full-res grid (plus skirt)")
	# A grid vertex sits at the cached height the collision shape is built from.
	var heights: PackedFloat32Array = m._chunk_cache[coord]["heights"]
	var idx := 17 * samples + 23
	assert_almost_eq(verts[idx].y, heights[idx], 1e-4,
		"the rebuilt surface is the same heightfield collision uses")


# Spawn -> despawn -> re-spawn: the deferred level rebuilds identically each time (the
# cache entry it is rebuilt from is not consumed by the first build).
func test_finest_level_rebuilds_identically_after_a_respawn() -> void:
	var m: TerrainManager = await _baked_manager()
	var focus := Vector3(50, 0, 0)
	m.update_focus(focus)
	m.flush_detail_queue()
	var coord := m.chunk_coord_for(focus)
	var before: PackedVector3Array = \
		_mesh_instances_of(m._chunks[coord])[0].mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	m.update_focus(Vector3(50 + (TerrainManager.RADIUS + 1) * TerrainManager.CHUNK_M, 0, 0))
	m.flush_detail_queue()
	assert_false(m._chunks.has(coord), "precondition: the chunk was unloaded")
	m.update_focus(focus)
	m.flush_detail_queue()
	var chunk: TerrainChunk = m._chunks[coord]
	assert_true(chunk.has_finest_mesh(), "the re-spawned chunk rebuilds its finest level")
	assert_eq(_mesh_instances_of(chunk)[0].mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array,
		before, "the rebuilt level is identical to the first build")


# Only the detail ring keeps a built finest level; chunks loaded beyond it hold none (that
# is the whole VRAM saving), and they get it the moment the focus reaches them.
func test_finest_level_follows_the_detail_ring() -> void:
	var m: TerrainManager = await _baked_manager()
	var focus := Vector3(150, 0, 0)
	m.update_focus(focus)
	m.flush_detail_queue()
	var center := m.chunk_coord_for(focus)
	var detail := m.detail_ring()
	if detail >= TerrainManager.RADIUS:
		pass_test("every loaded chunk is inside the detail ring at these settings")
		return
	var outside := center + Vector2i(TerrainManager.RADIUS, 0)
	assert_true(m._chunks.has(outside), "precondition: the far chunk is loaded")
	assert_false(m._chunks[outside].has_finest_mesh(),
		"a chunk outside the detail ring holds no finest-level mesh")
	# Drive onto it: it now needs the detail, and gets it.
	m.update_focus(Vector3((outside.x + 0.5) * TerrainManager.CHUNK_M, 0.0, focus.z))
	m.flush_detail_queue()
	assert_true(m._chunks[outside].has_finest_mesh(),
		"entering the detail ring builds the finest level")


# An absent finest level must never be a hole: the next present level takes over the near
# band instead of starting at the finest level's cutoff.
func test_absent_finest_level_leaves_no_uncovered_near_band() -> void:
	var m: TerrainManager = await _baked_manager()
	var focus := Vector3(150, 0, 0)
	m.update_focus(focus)
	m.flush_detail_queue()
	for coord in m._chunks:
		var chunk: TerrainChunk = m._chunks[coord]
		var instances := _mesh_instances_of(chunk)
		var nearest: MeshInstance3D = null
		for mi in instances:
			if mi.mesh != null:
				nearest = mi
				break
		assert_not_null(nearest, "every loaded chunk renders at least one level")
		assert_eq(nearest.visibility_range_begin, 0.0,
			"the nearest present level covers the camera from 0 m — no gap at %s" % coord)


# The deferred build outlives free_load_only_data: the retained quantised light is NOT
# load-only data, so a chunk spawned after the frees still shades like its neighbours
# rather than falling back to flat white (and does so without tripping any sentinel).
func test_finest_level_still_builds_after_the_load_only_frees() -> void:
	var m: TerrainManager = await _baked_manager()
	m.free_load_only_data()
	var focus := Vector3(150, 0, 0)
	m.update_focus(focus)
	m.flush_detail_queue()
	var coord := m.chunk_coord_for(focus)
	var chunk: TerrainChunk = m._chunks[coord]
	assert_true(chunk.has_finest_mesh(), "the finest level still builds after the frees")
	assert_push_error_count(0, "rebuilding the finest level reads nothing that was freed")
	# Lit terrain: the baked tint must have survived, so the colours are not all white.
	var colors: PackedColorArray = \
		_mesh_instances_of(chunk)[0].mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	var tinted := false
	for c in colors:
		if absf(c.r - 1.0) > 1e-3 or absf(c.g - 1.0) > 1e-3 or absf(c.b - 1.0) > 1e-3:
			tinted = true
			break
	assert_true(tinted, "the retained baked light is applied, not lost to the frees")


# The prebake existed to keep chunk spawns cheap, so the deferred build must not put a
# whole boundary crossing's worth of mesh building on one frame: entering chunks queue up
# and the drain honours its per-frame limit.
func test_entering_chunks_queue_instead_of_building_all_at_once() -> void:
	var m: TerrainManager = await _baked_manager()
	m.update_focus(Vector3(50, 0, 0))
	m.flush_detail_queue()
	assert_true(m._detail_queue.is_empty(), "precondition: the ring is fully detailed")
	# Cross into the next chunk: a new column enters the detail ring.
	m.update_focus(Vector3(50 + TerrainManager.CHUNK_M, 0, 0))
	var queued := m._detail_queue.size()
	if queued == 0:
		pass_test("no chunk entered the detail ring at these settings")
		return
	m._drain_detail_queue(1)
	assert_eq(m._detail_queue.size(), queued - 1,
		"one build per drain step — the rest wait for later frames")
	m.flush_detail_queue()
	assert_true(m._detail_queue.is_empty(), "the flush clears the backlog")
	for coord in m._chunks:
		var chunk: TerrainChunk = m._chunks[coord]
		if chunk.is_finest_deferred():
			var d := maxi(absi(coord.x - m._last_focus_coord.x),
				absi(coord.y - m._last_focus_coord.y))
			assert_eq(chunk.has_finest_mesh(), d <= m.detail_ring(),
				"chunk %s holds its finest level iff it is inside the detail ring" % coord)


# --- The initial ring: built ONCE, from the cache, and lazy like every other chunk ----
#
# `defer_initial_build` used to only stop _ready from building the ring — _process was
# still free to run during the host's loading yields, find an empty cache, and take
# _reconcile's on-demand branch for all (2*RADIUS+1)^2 coords. That work was thrown away
# (set_track re-setup()s loaded chunks after the carve, and the precompute caches the same
# coords again) and, worse, an on-demand chunk builds every LOD level itself, so the ring
# the player actually stands on never joined the lazy finest-LOD path.

func _focused_manager() -> TerrainManager:
	var m := _make_manager()
	var focus := Node3D.new()
	focus.name = "Focus"
	add_child_autofree(focus)
	focus.global_position = Vector3.ZERO
	m.focus_path = m.get_path_to(focus)
	return m


func test_deferred_ring_is_not_built_by_process_before_build_initial() -> void:
	var m := _focused_manager()
	# The host's loading frames: _process ticks with no corridor cache yet.
	for i in 5:
		m._timed_process(0.016)
	assert_eq(m.loaded_coords().size(), 0,
		"_process must not create the deferred ring — build_initial() owns it")
	assert_eq(m.on_demand_builds, 0,
		"and it must not compute chunk data from raw noise behind the host's back")


func test_initial_ring_comes_from_the_corridor_cache() -> void:
	var m := _focused_manager()
	var line := _straight_centerline()
	# Loading frames run before the bake and before the precompute, exactly as they do
	# during world.gd's staged generation.
	for i in 3:
		m._timed_process(0.016)
	await m.bake_track(line, 7.0, 3.0)
	m.precompute_corridor(line, 25.0)
	m.build_initial()
	assert_gt(m.loaded_coords().size(), 0, "precondition: build_initial built the ring")
	assert_eq(m.on_demand_builds, 0,
		"every initial-ring chunk is a cache pull — no duplicate compute")
	for coord in m.loaded_coords():
		assert_true(m.has_cached(coord), "ring chunk %s came from the cache" % coord)
	# And _process keeps serving from the cache once it is allowed to run again.
	m._timed_process(0.016)
	assert_eq(m.on_demand_builds, 0, "_process after build_initial still hits the cache")


func test_initial_ring_participates_in_the_lazy_finest_path() -> void:
	var m := _focused_manager()
	var line := _straight_centerline()
	for i in 3:
		m._timed_process(0.016)
	await m.bake_track(line, 7.0, 3.0)
	m.precompute_corridor(line, 25.0)
	m.build_initial()
	var checked := 0
	for coord in m._chunks:
		if not bool(m.chunk_class(coord)["full_res"]):
			continue  # coarse chunks prune their fine levels for good
		var chunk: TerrainChunk = m._chunks[coord]
		assert_true(chunk.is_finest_deferred(),
			"initial-ring chunk %s must be the deferrable kind, like any later chunk" % coord)
		var d := maxi(absi(coord.x - m._last_focus_coord.x), absi(coord.y - m._last_focus_coord.y))
		assert_eq(chunk.has_finest_mesh(), d <= m.detail_ring(),
			"chunk %s holds its finest level iff it is inside the detail ring" % coord)
		checked += 1
	assert_gt(checked, 0, "precondition: the ring contains full-res chunks")
