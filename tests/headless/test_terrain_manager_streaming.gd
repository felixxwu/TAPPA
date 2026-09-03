extends GutTest
# WAS test_overworld_streaming.gd. Renamed during the roguelike pivot's hub demolition:
# it has ZERO dependency on the overworld — every test here drives TerrainManager, which
# survives. It was named for the feature that motivated it, not for its subject.
#
# THE CHUNK LIFECYCLE NET — the composition tests for TerrainManager's streaming window,
# built as the safety net for the TerrainDomain refactor (which unifies the stage CORRIDOR
# and the overworld BOUNDS behind one domain abstraction, one supply pipeline and one
# per-frame work budget).
#
# WHY THIS FILE EXISTS. The refactor's whole subject is the chunk LIFECYCLE, and nothing in
# the suite drove it: no test called `update_focus` twice, none called `_timed_process`, and
# `store_reads` had zero assertions anywhere. Individual pieces (the taper, the store seam,
# eviction) were covered in test_overworld_terrain.gd; how they COMPOSE across a moving focus
# was not. These are those composition tests.
#
# WHAT IS ASSERTED, AND WHAT IS DELIBERATELY NOT. Counters and set invariants only:
#   - `store_reads` / `stream_on_miss_builds` / `on_demand_builds` — which SUPPLY PATH ran;
#   - which coords are resident / queued / evicted — pure set arithmetic;
#   - the RELATIONSHIP between two derived budgets, never either one's value.
# Never a timing, never a byte count, never a tunable. Every radius, budget, bound and cap
# here is a SYNTHETIC value the test sets itself, so retuning `config/game_config.tres`
# cannot break any of these. Nothing reaches into an authored catalogue.
#
# ALL SCENE-FREE, using the cheap seam from test_terrain_memory.gd: a bare TerrainManager via
# `set_script` with `defer_initial_build = true` and `focus_path = ""`, driven by explicit
# `update_focus` / `_timed_process` calls. No world.tscn, no car, no track bake. Each test
# builds at most 25 chunks (load_radius 1-2 over a small synthetic bounds).

const ManagerScript := preload("res://scripts/terrain_manager.gd")

const CHUNK := TerrainManager.CHUNK_M
const COUNT := TerrainManager.SAMPLES * TerrainManager.SAMPLES


# A duck-typed stand-in for OverworldCache — the three methods TerrainManager reaches for
# (`has` / `read` / `write`) — that RECORDS every call, so a test can tell "served from the
# store" apart from "served from the resident cache" without inspecting timings.
class FakeStore extends RefCounted:
	var records: Dictionary = {}          # coord -> {"heights":…, "l0_light":…}
	var reads: Array = []                 # coords asked for, in order
	var writes: Array = []                # [coord, heights, lights] per write
	var has_calls: Array = []             # coords probed, in order

	func has(coord: Vector2i) -> bool:
		has_calls.append(coord)
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


# --- Fixtures ------------------------------------------------------------------------------

# In the tree (so chunk nodes can spawn), no focus node, no initial build: the test drives
# the focus itself. `light_amount` stays 0 — the light bake is not what these assert.
func _tree_manager() -> TerrainManager:
	var m := Node3D.new()
	m.set_script(ManagerScript)
	m.focus_path = NodePath("")
	m.defer_initial_build = true
	m.noise_seed = 4242
	add_child_autofree(m)
	return m


# A small synthetic bounded world centred on the origin. The taper is left OFF (0) — a coast
# is irrelevant to the lifecycle and costs generation time.
func _bounded(radius: int) -> TerrainManager:
	var m := _tree_manager()
	m.load_radius = radius
	m.set_bounds(Rect2(-600.0, -600.0, 1200.0, 1200.0))
	return m


# World position at the centre of chunk (cx, cz).
func _at(cx: int, cz: int) -> Vector3:
	return Vector3((cx + 0.5) * CHUNK, 0.0, (cz + 0.5) * CHUNK)


# Cache every coord in the inclusive chunk rectangle, and return them.
func _cache_rect(m: TerrainManager, x0: int, x1: int, z0: int, z1: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for cz in range(z0, z1 + 1):
		for cx in range(x0, x1 + 1):
			var coord := Vector2i(cx, cz)
			m.cache_chunk(coord)
			out.append(coord)
	return out


func _cheb(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))


# --- 1. A fully resident window is a pure cache pull ---------------------------------------

# The baseline the whole streaming design rests on: when every coord the window wants is
# already resident, moving the focus around costs NO supply work at all — no store read, no
# on-miss build, no on-demand generate. If a refactor quietly re-enters the supply ladder for
# a resident coord, this is what catches it.
func test_a_fully_resident_window_never_touches_any_supply_path() -> void:
	var m := _bounded(1)
	# Everything the focus will ever want across the there-and-back move.
	_cache_rect(m, -2, 2, -1, 1)
	m.update_focus(_at(0, 0))
	assert_eq(m.loaded_coords().size(), 9, "precondition: the 3x3 window is resident")
	m.update_focus(_at(1, 0))
	m.update_focus(_at(0, 0))
	assert_eq(m.loaded_coords().size(), 9, "the window is still the 3x3 around the focus")
	assert_eq(m.store_reads, 0, "no store is attached, and none was needed")
	assert_eq(m.stream_on_miss_builds, 0, "a resident coord must never take the on-miss build")
	assert_eq(m.on_demand_builds, 0, "nor the raw on-demand generate")


# --- 2. Store-backed coords are READ, and the read goes resident ----------------------------

# The healthy supply path in a bounded world: a coord the resident cache does not hold but the
# STORE does is READ (one seek), not generated — and the read makes it resident, so crossing
# the same ground again is free. `store_reads` vs `stream_on_miss_builds` is exactly how those
# two are told apart, and until now neither had an assertion.
func test_store_backed_coords_are_read_once_and_then_served_from_the_cache() -> void:
	var store := FakeStore.new()
	# A producer fills the store for the region the consumer will walk. Separate manager, so
	# the consumer starts with a genuinely EMPTY resident cache.
	var producer := _bounded(1)
	producer.set_chunk_source(store)
	for cz in range(-1, 2):
		for cx in range(-1, 3):
			producer.chunk_data_for(Vector2i(cx, cz))
	assert_eq(store.records.size(), 12, "precondition: the store holds the walked region")

	var m := _bounded(1)
	m.set_chunk_source(store)
	assert_false(m.has_cached(Vector2i(0, 0)), "precondition: the resident cache is empty")

	m.update_focus(_at(0, 0))
	assert_gt(m.store_reads, 0, "an absent-but-stored coord is READ from the store")
	assert_eq(m.stream_on_miss_builds, 0, "a store read is not a generate")
	assert_eq(m.loaded_coords().size(), 9, "and the read chunk really spawns")

	# Cross east and back: the new column is read once, the old one is already resident.
	m.update_focus(_at(1, 0))
	m.update_focus(_at(0, 0))
	var after_first_crossing := m.store_reads

	# The SAME ground again: the first read populated the resident cache, so nothing is re-read.
	m.update_focus(_at(1, 0))
	m.update_focus(_at(0, 0))
	assert_eq(m.store_reads, after_first_crossing,
		"re-crossing ground already read must not hit the store again — the read went resident")
	assert_eq(m.stream_on_miss_builds, 0, "and no crossing ever fell through to a build")


# --- 3. The spawn budget bounds spawns ------------------------------------------------------

# The boundary hitch this budget exists for: a crossing pulls in a whole ring row, and
# spawning them all in one call is that many mesh + heightfield builds on one frame. What must
# hold for ANY budget: the forced collision band is always spawned immediately (ground the car
# can touch is never a hole), everything beyond it QUEUES, each drain honours the budget, and
# the ring eventually completes.
func test_the_spawn_budget_defers_everything_beyond_the_forced_collision_band() -> void:
	var m := _bounded(2)
	m.collision_ring = 0        # synthetic: the smallest possible immediate band (the focus chunk)
	m.spawn_budget = 1
	var wanted := _cache_rect(m, -2, 2, -2, 2)
	assert_eq(wanted.size(), 25, "precondition: the 5x5 window is cached")

	# build_initial() seats the focus at the origin and reconciles — the crossing under test.
	m.build_initial()
	# `_enqueue_spawns` forces everything within `collision_ring` of the focus — the band that
	# carries live collision, i.e. the ground the car can actually stand on — then drains
	# `spawn_budget` more. Asserts the RELATIONSHIP, not the numbers. The bound is
	# `collision_ring` and not one ring wider: the extra ring cannot be touched until it has
	# itself become the collision band, which is a whole chunk of travel away, and forcing it
	# was pure per-crossing frame cost.
	var forced := m.collision_ring
	var forced_band := (2 * forced + 1) * (2 * forced + 1)
	assert_lte(m.loaded_coords().size(), forced_band + m.spawn_budget,
		"a crossing spawns the forced collision band plus at most the budget")
	assert_false(m._spawn_queue.is_empty(),
		"the rest of the ring is deferred, not built on this frame")

	# Each process tick drains exactly the budget.
	var before := m.loaded_coords().size()
	m._timed_process(0.016)
	assert_eq(m.loaded_coords().size(), before + m.spawn_budget,
		"one process tick spawns the budget and no more")

	# And the ring completes rather than stalling half-built.
	for i in 40:
		m._timed_process(0.016)
	assert_true(m._spawn_queue.is_empty(), "the deferred spawns all land eventually")
	assert_eq(m.loaded_coords().size(), wanted.size(),
		"every wanted coord is resident once the queue drains")


# THE NO-HOLE GUARANTEE, which is what bounds the forced set from below. Whatever else the
# budget defers, every chunk inside `collision_ring` of the focus must be resident the moment
# `update_focus` returns — a missing chunk there is not a cosmetic gap, it is the car falling
# through the world. Asserted across a crossing (the case where new coords enter the band) and
# with a real collision_ring, not the synthetic 0 the budget test uses.
func test_the_collision_band_is_never_a_hole_after_a_crossing() -> void:
	var m := _bounded(2)
	m.collision_ring = 1
	m.spawn_budget = 1          # tight enough that anything unforced is definitely deferred
	_cache_rect(m, -3, 3, -3, 3)
	m.build_initial()
	for cx in range(-1, 2):
		m.update_focus(_at(cx, 0))
		var focus := m.chunk_coord_for(_at(cx, 0))
		var missing: Array[Vector2i] = []
		for dz in range(-m.collision_ring, m.collision_ring + 1):
			for dx in range(-m.collision_ring, m.collision_ring + 1):
				var coord := focus + Vector2i(dx, dz)
				if not m.loaded_coords().has(coord):
					missing.append(coord)
		assert_eq(missing, [] as Array[Vector2i],
			"the collision band is complete immediately at focus %s" % focus)


# The per-frame drain must not rebuild the whole target window to answer "is this coord still
# wanted?" — the ring is a Chebyshev ball, so the test is arithmetic. Pinned as BEHAVIOUR: a
# coord that has left the ring while queued is dropped, and one still inside is built.
func test_the_drain_drops_coords_that_left_the_ring_and_keeps_those_inside() -> void:
	var m := _bounded(1)
	m.spawn_budget = 1
	_cache_rect(m, -6, 6, -6, 6)
	m.build_initial()
	# A coord far outside the ring, plus one inside it that is not resident yet.
	var far := Vector2i(5, 5)
	var near := m._last_focus_coord + Vector2i(1, 0)
	m._spawn_queue = [far] as Array[Vector2i]
	m._drain_spawn_queue(4)
	assert_false(m.loaded_coords().has(far),
		"a queued coord outside the load radius is dropped, not spawned")
	assert_true(m._spawn_queue.is_empty(), "and it leaves the queue rather than sticking")
	assert_true(m.loaded_coords().has(near),
		"precondition/contract: a coord inside the radius is resident from the reconcile")


# --- 4. One budget, one source --------------------------------------------------------------

# The two per-frame budgets (chunk spawns, finest-LOD rebuilds) must be derived from the SAME
# config field in ONE place, so the streaming radius and the build budget cannot be wired up
# half-way. Asserts the relationship against a SYNTHETIC config value — not the shipped one.
func test_apply_overworld_bounds_derives_both_budgets_from_one_field() -> void:
	var m := _tree_manager()
	var cfg := GameConfig.new()
	cfg.overworld_chunk_build_budget = 3
	cfg.overworld_load_radius = 2
	m.apply_overworld_bounds(cfg, Rect2(-600.0, -600.0, 1200.0, 1200.0))
	assert_eq(m.spawn_budget, m.detail_builds_per_frame,
		"chunk spawns and finest-LOD rebuilds share one budget field")
	assert_eq(m.spawn_budget, cfg.overworld_chunk_build_budget,
		"and that budget is the one the caller passed in")
	assert_eq(m.load_radius, cfg.overworld_load_radius,
		"the streaming radius comes from the same call, not a separate wiring step")
	# The rest of the one-place seating, so a partial wire-up is visible here too.
	assert_true(m.has_bounds(), "the bounded world is declared by the same call")
	assert_false(m.stream_on_miss, "a bounded miss is a loud hole, not a silent generate")
	assert_true(m.capture_encoded_light,
		"chunks generated in play must keep their light for the store")


# --- 5. The window never leaves the domain --------------------------------------------------

# Pure set arithmetic, pinning nothing: whatever the focus and whatever the radius, every coord
# the window asks for lies inside the domain grown by the load radius. This is the invariant
# the precompute margin is sized against — if the window can reach outside it, the supply is
# undersupplied by construction and every miss beyond it is a hole.
func test_the_target_window_never_leaves_the_bounds_grown_by_the_load_radius() -> void:
	var rect := Rect2(-600.0, -600.0, 1200.0, 1200.0)
	var lo := Vector2i(floori(rect.position.x / CHUNK), floori(rect.position.y / CHUNK))
	var hi := Vector2i(floori((rect.end.x - 0.001) / CHUNK), floori((rect.end.y - 0.001) / CHUNK))
	var m := _tree_manager()
	m.set_bounds(rect)
	# A corner focus (the worst case for overrun) and a centre focus.
	var focuses: Array[Vector2i] = [lo, Vector2i(0, 0), hi]
	for radius in [1, 2]:
		m.load_radius = radius
		for f in focuses:
			var focus: Vector2i = f
			var window: Array = m.target_coords(focus)
			assert_eq(window.size(), (2 * radius + 1) * (2 * radius + 1),
				"the window is the full ring at radius %d" % radius)
			for c in window:
				var coord: Vector2i = c
				assert_between(coord.x, lo.x - radius, hi.x + radius,
					"coord %s (focus %s, r=%d) stays inside the grown domain" % [coord, focus, radius])
				assert_between(coord.y, lo.y - radius, hi.y + radius,
					"coord %s (focus %s, r=%d) stays inside the grown domain" % [coord, focus, radius])


# --- 6. Eviction spares the protected ring --------------------------------------------------

# Eviction is NOT lossless — once a coord leaves the cache, height_at / light_at / surface_at
# fall back to raw noise — so it must stay strictly outside the built window plus one chunk of
# hysteresis, or a coord the very next reconcile wants is thrown away a frame early. The
# there-and-back below is the observable consequence: it must cost nothing.
func test_eviction_never_takes_a_coord_inside_the_protected_ring() -> void:
	var store := FakeStore.new()
	var m := _bounded(1)
	m.set_chunk_source(store)          # attached from the start, so caching also fills the store
	var near := _cache_rect(m, -2, 2, -1, 1)
	var far := _cache_rect(m, 10, 12, 10, 10)
	assert_eq(m.store_reads, 0, "precondition: caching generates, it does not count as a read")
	m.update_focus(_at(0, 0))          # seats the focus before any eviction can measure from it

	m.cache_cap_mb = 0.000001          # below any single chunk: eviction takes everything it may
	var evicted := m.evict_to_cap()
	assert_gt(evicted, 0, "an over-cap cache must evict something")
	var keep := m.load_radius + 1
	for c in near:
		var coord: Vector2i = c
		if _cheb(coord, Vector2i(0, 0)) <= keep:
			assert_true(m.has_cached(coord),
				"coord %s is inside the protected ring (<= load_radius + 1) and may not be evicted"
					% coord)
	for c in far:
		var coord: Vector2i = c
		assert_false(m.has_cached(coord),
			"coord %s is far outside the window — that is what eviction is for" % coord)

	# The consequence: a there-and-back across the window boundary re-uses the spared cache and
	# never goes back to the store.
	var reads_before := m.store_reads
	m.update_focus(_at(1, 0))
	m.update_focus(_at(0, 0))
	assert_eq(m.store_reads, reads_before,
		"the hysteresis ring kept everything the crossing wanted — no store round trip")


# --- 7. A bounded miss is a loud hole, never a silent generate -------------------------------

# The deliberate choice a bounded world makes: a coord that is missing with no store to serve
# it leaves a HOLE and says so, rather than costing a mid-drive build hitch. Two halves matter
# — nothing is built, and the error fires ONCE PER COORD however many times the focus revisits
# it (a crossing re-visits the same coords every frame, so per-frame logging would itself be
# the cost). `assert_push_error_count` is the repo idiom here because several coords miss at
# once and a bare `assert_push_error` would consume only one.
func test_a_bounded_miss_holes_loudly_once_per_coord_and_builds_nothing() -> void:
	var m := _bounded(1)
	# Non-empty cache holding nothing the window wants: an EMPTY cache would take the
	# editor/on-demand branch instead, which is a different arm entirely.
	m.cache_chunk(Vector2i(30, 30))
	assert_false(m.has_cached(Vector2i(0, 0)), "precondition: every window coord is a miss")
	assert_null(m.chunk_source, "precondition: no store can serve the miss")

	m.update_focus(_at(0, 0))
	m.update_focus(_at(1, 0))
	m.update_focus(_at(0, 0))
	m.update_focus(_at(1, 0))

	assert_eq(m.stream_on_miss_builds, 0, "a bounded miss must never silently generate")
	assert_eq(m.on_demand_builds, 0, "nor take the raw on-demand branch")
	assert_eq(m.loaded_coords().size(), 0, "the miss is left as a hole, deliberately")
	assert_gt(m._logged_misses.size(), 0, "precondition: coords really did miss")
	assert_push_error_count(m._logged_misses.size(),
		"exactly one error per missed coord, however often the focus revisits it")


# --- 8. Stage defaults are untouched ---------------------------------------------------------

# The guard that the whole open-world feature stays OPT-IN. A manager nobody has configured
# must behave exactly like the shipped stage terrain — this is what keeps the overworld from
# regressing a rally, and it is the first thing to check if a refactor starts sharing state
# between the two domains.
func test_a_fresh_manager_keeps_every_stage_default() -> void:
	var m := autofree(TerrainManager.new()) as TerrainManager
	assert_eq(m.load_radius, TerrainManager.RADIUS,
		"the live ring radius starts at the stage constant")
	assert_eq(m.spawn_budget, 0,
		"no spawn budget: a stage spawns the whole ring row in one call, as it always did")
	assert_false(m.stream_on_miss, "a stage prefers a hole over a mid-drive build hitch")
	assert_null(m.chunk_source, "no chunk store")
	assert_false(m.has_bounds(), "no bounded world: the track corridor is still the bounds")
	assert_eq(m.height_quantum, 0.0, "no lattice snap: stage heights are the raw generated ones")
