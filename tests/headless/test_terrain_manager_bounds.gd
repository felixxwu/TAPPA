extends GutTest
# TerrainManager's BOUNDED-WORLD seam: set_bounds/clear_bounds/has_bounds and
# apply_overworld_bounds, the coastline taper, the duck-typed chunk store,
# generate-on-miss and the LRU cap.
#
# WAS test_overworld_terrain.gd. Renamed during the roguelike pivot's hub demolition:
# the name said "overworld" because the open-world hub is what motivated writing these,
# but the SUBJECT is TerrainManager, which survives. The overworld itself is gone.
#
# TRIAGE NOTE (stage 2d): the chunk-store / generate-on-miss / LRU tests cover streaming
# that every stage run uses and must stay. The bounds tests cover TerrainManager.set_bounds
# and apply_overworld_bounds, whose only caller was the deleted overworld — decide there
# whether the bounded-world mode itself is retired, and take these with it if so.
#
# Every test here is SCENE-FREE — a bare TerrainManager built via set_script with
# `defer_initial_build` and no focus node, the cheap seam test_terrain_memory.gd uses. No
# world.tscn, no track bake, no precompute.
#
# WHY these, and why none of them pins a number: the taper distance/depth, the load radius,
# the build budget and the cache cap are all GameConfig tunables, so only their DIRECTION and
# CONSISTENCY are testable. What must hold for ANY reasonable values is:
#   - every one of these knobs is OFF by default, so the shipped stage path is untouched;
#   - the taper leaves the interior alone, drops the perimeter below the waterline, and never
#     rises on the way out (a coast, not a wall);
#   - the store is consulted before generating and offered the result afterwards, in the
#     ENCODED byte form its on-disk record uses (this was a real integration mismatch between
#     two parallel implementations, hence the permanent guard);
#   - a miss is a hole for a stage and a build for the overworld — both arms, since the stage's
#     hole is a deliberate choice, not an oversight;
#   - eviction never pulls the ground out from under a live chunk, and never fires without a cap.

const ManagerScript := preload("res://scripts/terrain_manager.gd")

const COUNT := TerrainManager.SAMPLES * TerrainManager.SAMPLES


# A duck-typed stand-in for OverworldCache: the three methods TerrainManager reaches for
# (`has` / `read` / `write`), plus a record of every call so the tests can assert the seam
# was actually used. Deliberately not the real cache — this is about the manager's side of
# the contract, and a RefCounted double touches no disk.
class FakeStore extends RefCounted:
	var records: Dictionary = {}          # coord -> {"heights":…, "l0_light":…}
	var reads: Array = []                 # coords asked for, in order
	var writes: Array = []                # [coord, heights, lights] per write

	func has(coord: Vector2i) -> bool:
		return records.has(coord)

	func read(coord: Vector2i) -> Dictionary:
		reads.append(coord)
		return records.get(coord, {})

	# `surface` is the derived-channel section the real OverworldCache stores so a read can skip
	# the road carve / region blend. Optional here exactly as it is there.
	func write(coord: Vector2i, heights: Variant, lights: Variant,
			surface: Variant = PackedFloat32Array()) -> bool:
		writes.append([coord, heights, lights])
		var rec := {"heights": heights, "l0_light": lights}
		var channels: PackedFloat32Array = surface
		if not channels.is_empty():
			rec["surface"] = channels
		records[coord] = rec
		return true


# A manager that is NOT in the tree: enough for the pure predicates (defaults, bounds,
# taper), and it never runs _ready or builds a ring.
func _bare_manager() -> TerrainManager:
	return autofree(TerrainManager.new()) as TerrainManager


# A manager in the tree (so chunk nodes can be spawned), with no focus node and no initial
# build — the test drives update_focus itself.
func _tree_manager() -> TerrainManager:
	var m := Node3D.new()
	m.set_script(ManagerScript)
	m.focus_path = NodePath("")
	m.defer_initial_build = true
	m.noise_seed = 1337
	m.light_amount = 1.0
	add_child_autofree(m)
	return m


# A small bounded world centred on the origin, big enough that the origin is well inland.
func _bounded_manager() -> TerrainManager:
	var m := _tree_manager()
	m.load_radius = 1                        # a 3x3 ring: the tests only need a handful
	m.set_bounds(Rect2(-300.0, -300.0, 600.0, 600.0), 60.0, 5.0, 1.0)
	return m


# --- 1. Every open-world knob is opt-in ------------------------------------------

# The whole feature is additive: a manager nobody has configured must behave exactly like
# the shipped stage terrain. This is the guard that the overworld cannot regress a rally.
func test_fresh_manager_defaults_to_stage_behaviour() -> void:
	var m := _bare_manager()
	assert_eq(m.load_radius, TerrainManager.RADIUS,
		"the live ring radius starts at the stage constant")
	assert_false(m.stream_on_miss, "a stage prefers a hole over a mid-drive build")
	assert_eq(m.cache_cap_mb, 0.0, "no cap: the corridor cache must never lose an entry")
	assert_null(m.chunk_source, "no chunk store by default")
	assert_false(m.capture_encoded_light, "the encoded light is dead weight for a stage")
	assert_false(m.has_bounds(), "no bounded world: the track corridor is still the bounds")


# --- 2. Bounds round-trip --------------------------------------------------------

func test_set_and_clear_bounds_round_trip() -> void:
	var m := _bare_manager()
	var rect := Rect2(-120.0, -80.0, 240.0, 160.0)
	m.set_bounds(rect, 30.0, 4.0, 2.0)
	assert_true(m.has_bounds(), "a rectangle with area is a bounded world")
	assert_eq(m.world_bounds, rect, "world_bounds is what was set")
	m.clear_bounds()
	assert_false(m.has_bounds(), "cleared: back to stage behaviour")
	assert_eq(m.world_bounds.size, Vector2.ZERO, "an empty rect means unbounded")


# --- 3. The coastline taper: direction + consistency ----------------------------

# Inland the generated height is untouched; only the edge band is shaped.
func test_taper_leaves_the_map_interior_untouched() -> void:
	var m := _bare_manager()
	m.set_bounds(Rect2(-300.0, -300.0, 600.0, 600.0), 60.0, 5.0, 1.0)
	assert_eq(m.taper_height(7.25, 0.0, 0.0), 7.25,
		"the centre of the map is far from every edge — the taper must not touch it")


# What makes the edge a COAST rather than a cliff wall: at the perimeter the ground is
# below the water line, so the sea closes the map off.
func test_taper_drives_the_perimeter_below_the_waterline() -> void:
	var m := _bare_manager()
	var water := 1.0
	m.set_bounds(Rect2(-300.0, -300.0, 600.0, 600.0), 60.0, 5.0, water)
	var edges := [
		Vector2(-300.0, 0.0), Vector2(300.0, 0.0),
		Vector2(0.0, -300.0), Vector2(0.0, 300.0),
	]
	for p in edges:
		assert_lt(m.taper_height(7.25, p.x, p.y), water,
			"the ground at perimeter %s sits under the water" % p)
	# And beyond the bounds it stays under — a flat sea floor, never a rise back up.
	assert_lt(m.taper_height(7.25, -900.0, 0.0), water,
		"outside the world the shelf stays below the water")


# Walking from the centre to the edge, the ground never rises: the shoreline is a
# monotonic falloff, so there is no lip or bump for the player to catch on.
func test_taper_never_rises_on_the_way_out() -> void:
	var m := _bare_manager()
	m.set_bounds(Rect2(-300.0, -300.0, 600.0, 600.0), 60.0, 5.0, 1.0)
	var prev := INF
	for i in 61:
		var x := lerpf(0.0, -300.0, float(i) / 60.0)
		var h := m.taper_height(7.25, x, 0.0)
		assert_lte(h, prev + 1e-5,
			"height must not rise moving outward (x = %.1f)" % x)
		prev = h


# The stage path pays NOTHING and is bit-identical: with no bounded world the taper is an
# exact identity, at any position, including well outside where a world would have been.
func test_taper_is_an_exact_no_op_without_bounds() -> void:
	var m := _bare_manager()
	for p in [Vector2.ZERO, Vector2(50.0, -20.0), Vector2(9000.0, 9000.0),
			Vector2(-9000.0, 12.0)]:
		assert_eq(m.taper_height(7.25, p.x, p.y), 7.25,
			"no bounds -> identity at %s" % p)
	# A bounded world with the taper switched off is an identity too (the documented
	# "0 taper = off" arm).
	m.set_bounds(Rect2(-300.0, -300.0, 600.0, 600.0), 0.0, 5.0, 1.0)
	assert_eq(m.taper_height(7.25, -300.0, 0.0), 7.25,
		"a zero taper distance leaves even the perimeter alone")


# --- 4/5. The chunk store seam --------------------------------------------------

# The store is consulted BEFORE generating, and a generated chunk is offered back, so a
# store is a pure speed-up: attach one and the second visit is a read, not a rebuild.
func test_chunk_data_for_consults_the_store_then_writes_back() -> void:
	var m := _bounded_manager()
	var store := FakeStore.new()
	m.set_chunk_source(store)
	var coord := Vector2i(0, 0)

	var generated := m.chunk_data_for(coord)
	assert_eq(store.reads, [coord], "the store is asked first, before any generation")
	assert_eq(store.writes.size(), 1, "the generated chunk is offered back to the store")
	assert_true(store.has(coord), "and the store now holds it")
	assert_eq((generated["heights"] as PackedFloat32Array).size(), COUNT,
		"precondition: a full-res grid was generated")

	# Second visit: served from the store, and NOT regenerated (no second write).
	var stored := m.chunk_data_for(coord)
	assert_eq(store.reads.size(), 2, "the second visit consults the store again")
	assert_eq(store.writes.size(), 1, "a store hit must not regenerate or re-write")
	assert_eq(stored["heights"] as PackedFloat32Array,
		generated["heights"] as PackedFloat32Array,
		"the stored chunk is the same ground the generated one was")


# The store is also handed the three DERIVED per-vertex channels (COLOR.a road weight, UV2.x
# tarmac weight, UV2.y region rank), so a READ can skip `_apply_road_carve` and
# `_apply_region_blend` — the two passes that made rehydrating a cached chunk cost about as much
# as generating one. What must hold is that the round trip through the store reproduces the
# generated surface EXACTLY; an approximate channel would shade a rehydrated chunk differently
# from a generated one, with a seam wherever the cache boundary happens to fall.
func test_the_store_is_handed_the_derived_surface_channels_and_they_round_trip() -> void:
	var m := _bounded_manager()
	var store := FakeStore.new()
	m.set_chunk_source(store)
	var coord := Vector2i(2, -1)

	var generated := m.chunk_data_for(coord)
	var record: Dictionary = store.records[coord]
	assert_true(record.has("surface"), "the store is offered the derived channels")
	var channels: PackedFloat32Array = record["surface"]
	assert_eq(channels.size(), COUNT * 3,
		"three channels per vertex — road weight, tarmac weight, region rank")
	assert_eq(channels, TerrainManager.surface_channels_from(generated),
		"and they are exactly what the generated dict carries")

	# Second visit: served from the store, and the surface it comes back with is the generated
	# one bit-for-bit rather than a re-derivation.
	var stored := m.chunk_data_for(coord)
	assert_eq(stored["uv2s"] as PackedVector2Array, generated["uv2s"] as PackedVector2Array,
		"a stored chunk's UV2s are the generated chunk's")
	# COLOUR needs splitting, and only the ALPHA can be exact.
	#
	# COLOR.a is the road weight — one of the three f32 channels this test is about — so it must
	# round-trip bit-for-bit. COLOR.rgb is the ground tint x the BAKED LIGHT, and the light is
	# stored as RGB8 (`l0_light`, TerrainLod.encode_lights), so a rehydrated chunk's rgb is the
	# generated value quantised to 1/255. That is pre-existing and deliberate — the light was
	# always 8-bit on disk — so asserting rgb equality here would be asserting something the
	# format has never promised. An earlier version of this test did exactly that and failed.
	var got_colors: PackedColorArray = stored["colors"]
	var want_colors: PackedColorArray = generated["colors"]
	assert_eq(got_colors.size(), want_colors.size(), "same vertex count")
	var worst_rgb := 0.0
	var alpha_mismatch := -1
	for i in want_colors.size():
		if got_colors[i].a != want_colors[i].a:
			alpha_mismatch = i
			break
		worst_rgb = maxf(worst_rgb, absf(got_colors[i].r - want_colors[i].r))
		worst_rgb = maxf(worst_rgb, absf(got_colors[i].g - want_colors[i].g))
		worst_rgb = maxf(worst_rgb, absf(got_colors[i].b - want_colors[i].b))
	assert_eq(alpha_mismatch, -1,
		"every COLOR.a (the stored road weight) round-trips exactly")
	# One 8-bit step, with a little slack for the tint multiply — enough to catch a channel that
	# came back re-derived or missing, which is what this guards.
	assert_lt(worst_rgb, 2.0 / 255.0,
		"COLOR.rgb comes back within the light's 8-bit storage precision (worst %.5f)" % worst_rgb)


# The store's light contract is the RGB8-ENCODED byte form (what lands on disk), not a
# PackedColorArray — and a record read back in that form must be rehydrated, not rejected.
# This exact mismatch was a live integration bug between the manager and the cache, so it
# is worth pinning permanently.
func test_store_light_contract_is_the_encoded_byte_form() -> void:
	var m := _bounded_manager()
	var store := FakeStore.new()
	m.set_chunk_source(store)
	assert_true(m.capture_encoded_light,
		"attaching a store arms the encoded-light capture, or the store poisons itself")
	var coord := Vector2i(1, 0)
	m.chunk_data_for(coord)

	var written: Array = store.writes[0]
	assert_true(written[1] is PackedFloat32Array, "heights go over as a float grid")
	assert_true(written[2] is PackedByteArray,
		"light goes over ENCODED — a PackedColorArray is not the store's contract")
	assert_false((written[2] as PackedByteArray).is_empty(),
		"a lit manager must not persist a light-less record")

	# Read back: the byte array under `l0_light` is decoded into the builder's shape rather
	# than being treated as an unusable record.
	var rehydrated := m.chunk_data_for(coord)
	assert_false(rehydrated.is_empty(), "an l0_light byte record is accepted, not rejected")
	assert_eq((rehydrated["lights"] as PackedColorArray).size(), COUNT,
		"the encoded bytes are rehydrated back to per-vertex light")


# --- 6. stream_on_miss: both arms ----------------------------------------------

# A NON-EMPTY cache plus a coord it does not hold is the interesting case (an empty cache
# takes the editor/on-demand branch instead). With the flag off — every stage — the miss is
# deliberately left as a hole; with it on — the overworld — it is built.
func test_stream_on_miss_fills_the_hole_only_when_enabled() -> void:
	var m := _bounded_manager()
	# Seed the cache with a chunk far from where the focus will be, so the cache is
	# non-empty but holds nothing the ring wants.
	m.cache_chunk(Vector2i(20, 20))
	assert_false(m.has_cached(Vector2i(0, 0)), "precondition: the ring's coords are misses")

	m.stream_on_miss = false
	m.update_focus(Vector3.ZERO)
	assert_eq(m.loaded_coords().size(), 0,
		"with the flag off a miss stays a hole — no mid-drive build hitch")
	assert_eq(m.stream_on_miss_builds, 0, "and nothing was built")
	# ...and it says so LOUDLY. A bounded world precomputes every in-bounds coord, so a miss is
	# always a bug — a silent hole would be a worse outcome than the hitch it replaced, because
	# nothing would tell you the cache was undersupplied. This error is the intended behaviour,
	# not noise: it is why generate-on-miss was turned off for the overworld.
	# One error per missed coord, and no more: the ring wants several and each is logged exactly
	# once (`_logged_misses` is the once-per-coord guard, which matters because a crossing
	# re-visits the same coords).
	assert_push_error_count(m._logged_misses.size(),
		"a bounded miss is loud, once per coord")

	m.stream_on_miss = true
	m.update_focus(Vector3.ZERO)
	assert_gt(m.loaded_coords().size(), 0,
		"with the flag on the miss is filled — an open world may not show holes")
	assert_gt(m.stream_on_miss_builds, 0, "the fallback recorded its builds")
	assert_true(m.has_cached(Vector2i(0, 0)),
		"a streamed chunk goes through the cache, like a precomputed one")


# --- 7. Eviction ----------------------------------------------------------------

# No cap is the stage default, and there the corridor cache must never lose an entry.
func test_eviction_is_inert_without_a_cap() -> void:
	var m := _bounded_manager()
	m.cache_chunk(Vector2i(0, 0))
	m.cache_chunk(Vector2i(20, 20))
	assert_eq(m.cache_cap_mb, 0.0, "precondition: no cap is set")
	assert_eq(m.evict_to_cap(), 0, "without a cap nothing is ever evicted")
	assert_true(m.has_cached(Vector2i(0, 0)), "the cache is untouched")
	assert_true(m.has_cached(Vector2i(20, 20)), "the cache is untouched")


# The hard safety rule: eviction stays strictly outside the built window, so it can never
# pull the meshes or the collision heightfield out from under a chunk the player is on.
func test_eviction_spares_the_built_window_and_takes_the_far_chunks() -> void:
	var m := _bounded_manager()
	m.stream_on_miss = true
	m.update_focus(Vector3.ZERO)                  # builds + caches the 3x3 ring
	var live: Array = m.loaded_coords().duplicate()
	assert_gt(live.size(), 0, "precondition: the ring is built")
	var far := Vector2i(20, 20)
	m.cache_chunk(far)
	assert_true(m.has_cached(far), "precondition: a far chunk is cached")

	# A cap below any single chunk's size: eviction must still refuse everything inside the
	# window and take only what is outside it.
	m.cache_cap_mb = 0.000001
	assert_gt(m.evict_to_cap(), 0, "an over-cap cache evicts something")
	assert_false(m.has_cached(far), "the far, un-spawned chunk is what goes")
	for coord in live:
		assert_true(m.has_cached(coord),
			"live chunk %s keeps its cached data — eviction may never strand a node" % coord)


# --- 8. The bounded world's surface --------------------------------------------

# Inside a bounded world there is no bake_track, so track_weights / track_surface are empty
# and a dictionary read would answer 0 by accident. surface_at must answer from the declared
# constant instead — and go back to the bake dictionaries once the bounds are cleared.
func test_surface_at_answers_from_bounds_surface_inside_a_bounded_world() -> void:
	var m := _bare_manager()
	m.set_bounds(Rect2(-300.0, -300.0, 600.0, 600.0), 60.0, 5.0, 1.0)
	m.bounds_surface = Vector2(0.25, 0.75)
	for p in [Vector2.ZERO, Vector2(123.0, -45.0), Vector2(-299.0, 299.0)]:
		assert_eq(m.surface_at(p.x, p.y), m.bounds_surface,
			"a bounded world has one declared surface, at %s" % p)
	m.clear_bounds()
	assert_eq(m.surface_at(0.0, 0.0), Vector2.ZERO,
		"unbounded and unbaked, surface_at is back to reading the (empty) bake fields")
