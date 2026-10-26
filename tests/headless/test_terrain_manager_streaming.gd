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
# `stream_on_miss_builds` had zero assertions anywhere. Individual pieces (eviction, the spawn
# queue) were covered elsewhere; how they COMPOSE across a moving focus was not. These are those composition tests.
#
# WHAT IS ASSERTED, AND WHAT IS DELIBERATELY NOT. Counters and set invariants only:
#   - `stream_on_miss_builds` / `on_demand_builds` — which SUPPLY PATH ran;
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


func _windowed(radius: int) -> TerrainManager:
	var m := _tree_manager()
	m.load_radius = radius
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
# already resident, moving the focus around costs NO supply work at all — no
# on-miss build, no on-demand generate. If a refactor quietly re-enters the supply ladder for
# a resident coord, this is what catches it.
func test_a_fully_resident_window_never_touches_any_supply_path() -> void:
	var m := _windowed(1)
	# Everything the focus will ever want across the there-and-back move.
	_cache_rect(m, -2, 2, -1, 1)
	m.update_focus(_at(0, 0))
	assert_eq(m.loaded_coords().size(), 9, "precondition: the 3x3 window is resident")
	m.update_focus(_at(1, 0))
	m.update_focus(_at(0, 0))
	assert_eq(m.loaded_coords().size(), 9, "the window is still the 3x3 around the focus")
	assert_eq(m.stream_on_miss_builds, 0, "a resident coord must never take the on-miss build")
	assert_eq(m.on_demand_builds, 0, "nor the raw on-demand generate")


# The guard that the whole open-world feature stays OPT-IN. A manager nobody has configured
# must behave exactly like the shipped stage terrain — this is what keeps the overworld from
# regressing a rally, and it is the first thing to check if a refactor starts sharing state
# between the two domains.
func test_a_fresh_manager_keeps_every_stage_default() -> void:
	var m := autofree(TerrainManager.new()) as TerrainManager
	assert_eq(m.load_radius, TerrainManager.RADIUS,
		"the live ring radius starts at the stage constant")
	assert_false(m.stream_on_miss, "a stage prefers a hole over a mid-drive build hitch")
