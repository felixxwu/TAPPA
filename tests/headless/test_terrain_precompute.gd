extends GutTest
# Precomputed-corridor terrain: region math, cache behaviour, cache-first
# height/light lookups (see docs/superpowers/specs/2026-07-03-precomputed-terrain-design.md).

const ManagerScript := preload("res://scripts/terrain_manager.gd")


func _make_manager() -> TerrainManager:
	var m := Node3D.new()
	m.set_script(ManagerScript)
	m.focus_path = NodePath("")
	m.defer_initial_build = true
	m.noise_seed = 1337
	add_child_autofree(m)
	return m


# A straight 300 m track along +X starting at the origin. Straight spans
# tessellate to just their endpoints — the exact case corridor sub-sampling
# must handle.
func _straight_centerline() -> Curve2D:
	var c := Curve2D.new()
	c.add_point(Vector2(0, 0))
	c.add_point(Vector2(300, 0))
	return c


func test_corridor_covers_ring_everywhere_within_leash() -> void:
	var m := _make_manager()
	var leash := 25.0
	var coords: Array[Vector2i] = m.corridor_coords(_straight_centerline(), leash)
	var lookup := {}
	for c in coords:
		lookup[c] = true
	# For car positions sampled along the track and across the leash band
	# (including the leash edge + a tick of overshoot at speed), EVERY coord of
	# the loaded ring must be in the corridor — the invariant the runtime cache
	# relies on.
	var overshoot := 2.0  # ~50 m/s * one 1/60 physics tick, generous
	for xi in range(0, 301, 10):
		for dz in [-(leash + overshoot), 0.0, leash + overshoot]:
			var car := Vector3(xi, 0.0, dz)
			for ring_coord in m.target_coords(m.chunk_coord_for(car)):
				assert_true(lookup.has(ring_coord),
					"ring coord %s for car at %s must be precomputed" % [ring_coord, car])


func test_corridor_covers_straight_span_interiors() -> void:
	# Regression guard for the tessellate()-endpoints-only trap: the middle of a
	# long straight is covered, not just its ends.
	var m := _make_manager()
	var coords: Array[Vector2i] = m.corridor_coords(_straight_centerline(), 25.0)
	var lookup := {}
	for c in coords:
		lookup[c] = true
	assert_true(lookup.has(Vector2i(3, 0)), "chunk mid-straight (x=150..200 m) covered")


func test_corridor_has_no_duplicates() -> void:
	var m := _make_manager()
	var coords: Array[Vector2i] = m.corridor_coords(_straight_centerline(), 25.0)
	var seen := {}
	for c in coords:
		assert_false(seen.has(c), "coord %s appears once" % c)
		seen[c] = true


func test_cached_chunk_data_matches_fresh_compute() -> void:
	var m := _make_manager()
	m.precompute_corridor(_straight_centerline(), 25.0)
	var coord := Vector2i(1, 0)
	assert_true(m.has_cached(coord), "corridor chunk cached")
	var fresh: Dictionary = m.compute_chunk_data(coord)
	var cached: Dictionary = m._chunk_cache[coord]
	for key in fresh:
		assert_eq(cached[key], fresh[key], "cached %s byte-identical to fresh compute" % key)


func test_ring_spawns_from_cache_without_recompute() -> void:
	var m := _make_manager()
	m.precompute_corridor(_straight_centerline(), 25.0)
	m.update_focus(Vector3(75, 0, 0))
	# All ring chunks exist immediately (no threading, no queueing, no
	# frame-spreading — the cache made them instant).
	var ring: int = 2 * ManagerScript.RADIUS + 1
	assert_eq(m.loaded_coords().size(), ring * ring, "full ring spawned synchronously from cache")


func test_cache_miss_with_populated_cache_spawns_no_chunk() -> void:
	var m := _make_manager()
	m.precompute_corridor(_straight_centerline(), 25.0)
	# Teleport far outside the corridor: every ring coord misses. Prefer a HOLE over a
	# mid-drive build hitch — the manager spawns nothing and logs each miss once.
	m.update_focus(Vector3(5000, 0, 5000))
	assert_eq(m.loaded_coords().size(), 0, "cache miss spawns no chunk (hole, not hitch)")
	# Re-crossing the same missing region must not re-log (once per coord).
	m.update_focus(Vector3(5050, 0, 5000))
	assert_push_error_count(m._logged_misses.size(),
		"each missing coord logged at most once")


func test_empty_cache_builds_on_demand_without_error() -> void:
	# Editor / tests path: no precompute ever ran -> on-demand builds stay silent.
	var m := _make_manager()
	m.update_focus(Vector3.ZERO)
	var ring: int = 2 * ManagerScript.RADIUS + 1
	assert_eq(m.loaded_coords().size(), ring * ring, "on-demand ring without cache")


func test_seed_change_invalidates_and_refills_cache() -> void:
	var m := _make_manager()
	m.precompute_corridor(_straight_centerline(), 25.0)
	m.update_focus(Vector3.ZERO)
	var before: float = m.height_at(10.0, 40.0)  # off-road point, pure noise height
	m.noise_seed = 4242  # setter runs _rebuild_loaded
	assert_true(m.has_cached(Vector2i(0, 0)), "cache refilled for the stored corridor")
	var after: float = m.height_at(10.0, 40.0)
	assert_ne(before, after, "cached heights reflect the new seed, not stale data")


func test_height_at_serves_flattened_road_height_from_cache() -> void:
	var m := _make_manager()
	var center := _straight_centerline()
	await m.set_track(center, 8.0, 4.0)
	m.precompute_corridor(center, 25.0)
	# Directly on the road centerline the terrain is flattened to the baked road
	# height; the cache carries that, the raw noise does not.
	var x := 100.0
	var cached_h: float = m.height_at(x, 0.0)
	var noise_h: float = m._noise_height_at(x, 0.0)
	var vidx := Vector2i(roundi(x / TerrainManager.CELL_M), 0)
	assert_true(m.road_blend.has(vidx), "test point is on the baked road")
	var road_h: float = m.road_heights[vidx]
	assert_almost_eq(cached_h, road_h, 0.01,
		"height_at returns the flattened (visible/collidable) height on the road")
	# Only meaningful if flattening actually moved this vertex:
	if absf(noise_h - road_h) > 0.02:
		assert_ne(cached_h, noise_h, "cache-first differs from pure noise where flattened")


func test_height_at_matches_cached_grid_exactly_on_vertices() -> void:
	var m := _make_manager()
	m.precompute_corridor(_straight_centerline(), 25.0)
	var coord := Vector2i(1, 0)
	var data: Dictionary = m._chunk_cache[coord]
	var heights: PackedFloat32Array = data["heights"]
	# Grid vertex (xi=10, zi=20) world position:
	var wx := coord.x * TerrainManager.CHUNK_M + 10.0 * TerrainManager.CELL_M
	var wz := coord.y * TerrainManager.CHUNK_M + 20.0 * TerrainManager.CELL_M
	assert_almost_eq(m.height_at(wx, wz), heights[20 * TerrainManager.SAMPLES + 10], 1e-5,
		"on a grid vertex the bilinear lookup equals the cached sample")


func test_height_at_falls_back_to_noise_outside_corridor() -> void:
	var m := _make_manager()
	m.precompute_corridor(_straight_centerline(), 25.0)
	var x := 9000.0
	assert_almost_eq(m.height_at(x, 9000.0), m._noise_height_at(x, 9000.0), 1e-6,
		"outside the corridor height_at silently serves pure noise (backdrop territory)")


func test_light_at_serves_from_cache_when_lit() -> void:
	var m := _make_manager()
	m.light_amount = 1.0
	m.precompute_corridor(_straight_centerline(), 25.0)
	var lgt: Color = m.light_at(60.0, 10.0)
	assert_true(lgt.r >= 0.0 and lgt.r <= 2.0, "sane light tint from cache")
	# Cache-first must agree with the baked per-vertex light on a grid vertex:
	var data: Dictionary = m._chunk_cache[Vector2i(1, 0)]
	var lights: PackedColorArray = data["lights"]
	var baked: Color = lights[10 * TerrainManager.SAMPLES + 10]
	var at_vertex: Color = m.light_at(1.0 * TerrainManager.CHUNK_M + 10.0, 10.0)
	assert_almost_eq(at_vertex.r, baked.r, 0.01, "light_at matches the baked vertex light")
