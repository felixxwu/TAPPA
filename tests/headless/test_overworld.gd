extends GutTest
# THE OVERWORLD HUB SHELL (`scripts/overworld.gd`, `overworld.tscn`) — the drivable, life-size
# replacement for the HQ map table (docs/superpowers/specs/2026-08-17-overworld-hq-design.md).
#
# WHAT THIS FILE GUARDS, and why each half is here:
#
#   * THE COORDINATE MAPPING. `world_xz` / `map_pos_of` / `bounds_for` are the single source of
#     truth shared by the zone layer, the fog shader include and the persisted return pose. A
#     silent axis swap or a lost half-offset would mirror the whole map while every individual
#     system still looked self-consistent, so the round trip and the axis convention are pinned
#     directly on the STATIC functions with an explicitly passed size — no tunable involved.
#
#   * THE BOOT WIRING. A handful of things in `_ready` are invisible when they break: the floor
#     going into BOUNDED mode (which replaces the track corridor and switches on the coastline
#     taper), the absence of TrackProgress (it teleports a far-off-road car back to a road,
#     which out here would fight the player forever), the hub one-shots being drained, and the
#     fog globals being disarmed on the way out (global shader params outlive a scene change).
#
# COST. A life-size overworld is over the suite's whole budget by construction, so the scene
# ships a cheap path (`Overworld.load_mode = CHEAP`: tiny bounds, no disk cache, no precompute,
# no foliage/horizon/water, a 1-chunk load ring, no zones). Every test here uses it, and the
# read-only assertions SHARE ONE `before_all` instance rather than re-instancing per test —
# only the two tests that must observe a fresh boot or a teardown (`_drain_hub_one_shots`, the
# fog disarm) build their own throwaway instance.
#
# NO TUNABLE IS ASSERTED: not the shipped 4 km `overworld_size_m`, not the dwell seconds, not a
# reveal radius. Sizes come from `cheap_size_m` (test-owned) or from an explicitly passed
# argument, and reveal is asserted as AGREEMENT with the shared predicate rather than as a
# distance.
#
# Some assertions go through private methods (`_resolve_spawn_pose`, `_build_garage`, `_cheap`). That is deliberate and normal in this repo: those behaviours have no public seam,
# and each such call is flagged in a comment below.

const OVERWORLD_SCENE := "res://overworld.tscn"
const TEST_PROFILE := "user://test_overworld_profile.json"
const SaveTestHelpers = preload("res://tests/headless/save_test_helpers.gd")

# Test-owned probe positions in normalised map space, deliberately asymmetric in x and y so a
# swapped axis cannot round-trip by accident.
const PROBES := [
	Vector2(0.5, 0.5), Vector2(0.0, 0.0), Vector2(1.0, 1.0),
	Vector2(0.25, 0.75), Vector2(0.9, 0.1),
]

var _ow: Overworld = null
var _prev_load_mode: int = Overworld.LoadMode.AUTO


# ONE shared cheap boot for every read-only assertion in this file (see the cost note above).
func before_all() -> void:
	_prev_load_mode = Overworld.load_mode
	var save := SaveTestHelpers.redirect(TEST_PROFILE)
	RallyFixtures.install()
	CarFixtures.install()
	# OWN A CAR BEFORE BOOTING. The hub now opens the STARTER PICKER on boot for a profile that owns
	# nothing (`_maybe_open_starter_pick`) — correct behaviour, and it takes the car's control lock
	# and claims the screen. Every read-only assertion in this file is about a RETURNING player's
	# hub, so the profile is given a car first; the starter boot has its own test below, on its own
	# throwaway instance. Fixture car, so nothing here depends on the shipped catalogue.
	save.grant_car(String(CarFixtures.cars()[0]["id"]))
	Config.reset()
	_ow = _boot()


func after_all() -> void:
	if is_instance_valid(_ow):
		_ow.free()
	_ow = null
	# `load_mode` is STATIC — left set it would opt every later test file's overworld (and any
	# future non-headless run of the suite) into the cheap path.
	Overworld.load_mode = _prev_load_mode
	CarFixtures.restore()
	RallyFixtures.restore()
	SaveTestHelpers.cleanup(TEST_PROFILE)
	Config.reset()


# Instantiate the scene in CHEAP mode. AUTO already resolves to CHEAP under --headless, but the
# mode is set EXPLICITLY so this file does not depend on how the harness happens to launch.
# `_ready` awaits, but every yield collapses to a no-op headless, so the world is fully built by
# the time add_child returns.
func _boot() -> Overworld:
	Overworld.load_mode = Overworld.LoadMode.CHEAP
	var ow: Overworld = (load(OVERWORLD_SCENE) as PackedScene).instantiate()
	add_child(ow)
	return ow


# ==========================================================================================
# Coordinates
# ==========================================================================================

func test_map_pos_round_trips_through_world_xz() -> void:
	for size in [1.0, 300.0, 4321.0]:
		for p in PROBES:
			var back: Vector2 = Overworld.map_pos_of(Overworld.world_xz(p, size), size)
			assert_almost_eq(back.x, p.x, 1e-4, "x round trip at size %s for %s" % [size, p])
			assert_almost_eq(back.y, p.y, 1e-4, "y round trip at size %s for %s" % [size, p])


func test_world_xz_round_trips_through_map_pos_of() -> void:
	var size := 800.0
	for pos in [Vector3.ZERO, Vector3(120.0, 9.0, -340.0), Vector3(-400.0, 0.0, 400.0)]:
		var back: Vector3 = Overworld.world_xz(Overworld.map_pos_of(pos, size), size)
		assert_almost_eq(back.x, pos.x, 1e-3, "x survives the reverse trip")
		assert_almost_eq(back.z, pos.z, 1e-3, "z survives the reverse trip")
		assert_eq(back.y, 0.0, "the mapping is planar — y is not carried")


# The two conventions that would mirror or rotate the entire map if they ever flipped, while
# every consumer stayed internally consistent: the map's CENTRE is the world origin, and
# `map_pos.y` maps to world Z (never X).
func test_map_centre_is_the_world_origin_and_map_y_is_world_z() -> void:
	var size := 1000.0
	var centre := Overworld.world_xz(Vector2(0.5, 0.5), size)
	assert_almost_eq(centre.x, 0.0, 1e-4, "map centre sits on the world origin (x)")
	assert_almost_eq(centre.z, 0.0, 1e-4, "map centre sits on the world origin (z)")

	# Move only map y: world z must move, world x must not.
	var down := Overworld.world_xz(Vector2(0.5, 0.75), size)
	assert_almost_eq(down.x, 0.0, 1e-4, "map y must not leak into world x")
	assert_true(down.z > 0.0, "increasing map y increases world z, got %s" % down.z)

	# Move only map x: world x must move, world z must not.
	var across := Overworld.world_xz(Vector2(0.75, 0.5), size)
	assert_almost_eq(across.z, 0.0, 1e-4, "map x must not leak into world z")
	assert_true(across.x > 0.0, "increasing map x increases world x, got %s" % across.x)


# The RELATIONSHIP only — centred on the origin and `size` across. The shipped size is a
# tunable and is never asserted anywhere in this file.
func test_bounds_for_is_centred_on_the_origin_and_size_across() -> void:
	for size in [10.0, 300.0, 4000.0]:
		var rect := Overworld.bounds_for(size)
		assert_almost_eq(rect.get_center().x, 0.0, 1e-4, "centred in x at size %s" % size)
		assert_almost_eq(rect.get_center().y, 0.0, 1e-4, "centred in y at size %s" % size)
		assert_almost_eq(rect.size.x, size, 1e-4, "width is the edge length")
		assert_almost_eq(rect.size.y, size, 1e-4, "square: height is the edge length too")
		# The map's corners are the rect's corners — what world_xz(0,0)/(1,1) must land on.
		var lo := Overworld.world_xz(Vector2.ZERO, size)
		var hi := Overworld.world_xz(Vector2.ONE, size)
		assert_almost_eq(lo.x, rect.position.x, 1e-3, "map (0,0) is the rect's near corner")
		assert_almost_eq(hi.x, rect.end.x, 1e-3, "map (1,1) is the rect's far corner")


# ==========================================================================================
# The cheap boot
# ==========================================================================================

func test_scene_boots_in_cheap_mode_with_its_expected_nodes() -> void:
	assert_not_null(_ow, "the overworld scene instantiates")
	assert_true(_ow.get_node_or_null("Floor") is TerrainManager, "Floor is a TerrainManager")
	assert_not_null(_ow.get_node_or_null("Car"), "the car is fielded")
	assert_not_null(_ow.get_node_or_null("WorldEnvironment"), "the environment exists")
	assert_true(_ow.get_node_or_null("CameraManager") is CameraManager, "camera manager")
	assert_not_null(_ow.get_node_or_null("ChaseCamera"), "chase camera")
	assert_true(_ow.get_node_or_null("PauseMenu") is PauseMenu, "pause menu")
	# `cheap_size_m` is a TEST-OWNED static, not a shipped tunable, so pinning it is fair —
	# and it proves the cheap path (not the 4 km authored size) was the one taken.
	assert_almost_eq(_ow.size_m(), Overworld.cheap_size_m, 1e-4, "cheap world edge length")
	assert_almost_eq(_ow.bounds().size.x, Overworld.cheap_size_m, 1e-4, "bounds follow size_m")
	# Two caps: one for the load window, one after it — the same intent world.gd records.
	assert_eq(_ow.applied_fps_caps.size(), 2, "a loading cap and a post-load cap were applied")


# The disk chunk store is ~83 MB of user:// writes. Cheap mode (and headless) must never open
# it — a suite that did would be a disaster, not a slow test.
func test_cheap_boot_never_opens_the_disk_chunk_cache() -> void:
	assert_null(_ow._cache, "no OverworldCache in the cheap path")  # private: no public seam


# The floor in BOUNDED mode is what replaces the track corridor. Without it, chunk
# classification, the horizon build and the encoded-light free all silently degrade — nothing
# errors, the world just quietly stops being an overworld.
func test_floor_is_switched_into_bounded_mode_matching_the_overworld() -> void:
	var tm: TerrainManager = _ow.get_node("Floor")
	assert_true(tm.has_bounds(), "the terrain manager is in bounded (overworld) mode")
	var b := _ow.bounds()
	assert_almost_eq(tm.world_bounds.position.x, b.position.x, 1e-3, "bounds x agree")
	assert_almost_eq(tm.world_bounds.position.y, b.position.y, 1e-3, "bounds y agree")
	assert_almost_eq(tm.world_bounds.size.x, b.size.x, 1e-3, "bounds width agrees")
	assert_almost_eq(tm.world_bounds.size.y, b.size.y, 1e-3, "bounds height agrees")
	# A bounded world answers corridor_bounds() from the same rect, which is what the rest of
	# the terrain code queries.
	assert_almost_eq(tm.corridor_bounds().size.x, b.size.x, 1e-3, "corridor_bounds follows")


# DELIBERATELY ABSENT (overworld.gd's header): TrackProgress snaps a car that has strayed far
# from the road back onto one within seconds. In a roadless open world that fights the player
# constantly, so the scene must carry none — this is a guard against someone "fixing" the
# overworld by copying world.tscn's node list across.
func test_no_track_progress_is_present() -> void:
	assert_null(_first_track_progress(_ow), "the overworld has no TrackProgress")


func _first_track_progress(node: Node) -> Node:
	if node is TrackProgress:
		return node
	for child in node.get_children():
		var hit := _first_track_progress(child)
		if hit != null:
			return hit
	return null


# ==========================================================================================
# Fog gate and the garage exemption
# ==========================================================================================

# `position_revealed` must be the SHARED predicate, not a lookalike distance test: what looks
# lit and what is enterable are derived from the same function everywhere else (the pins, the
# eligibility query, the zone gate), and a private copy here would let them drift.
func test_position_revealed_delegates_to_the_shared_predicate() -> void:
	var rallies: Array[Dictionary] = RallyLibrary.all()
	var lit_rally: Dictionary = rallies[0]
	var profile: Dictionary = Save.profile
	var prev: Variant = profile.get(Save.KEY_RALLIES, {})
	profile[Save.KEY_RALLIES] = {String(lit_rally["id"]): {"completed": true}}

	var inside: Vector2 = lit_rally.get("map_pos", RallyLibrary.HQ_MAP_POS)
	# Far outside any plausible circle without leaning on a radius: the opposite corner of the
	# unit map from the lit pin.
	var outside := Vector2(1.0 - inside.x, 1.0 - inside.y)
	if inside.distance_to(outside) < 0.5:
		outside = Vector2(0.0, 1.0) if inside.x > 0.5 else Vector2(1.0, 0.0)

	assert_true(_ow.position_revealed(inside), "a completed rally's own pin is lit")
	assert_false(_ow.position_revealed(outside), "the far corner of the map is not lit")
	# AGREEMENT, which is the actual contract — same inputs, same answer as the shared rule.
	for p in [inside, outside, Vector2(0.5, 0.5), Vector2(0.3, 0.7)]:
		assert_eq(_ow.position_revealed(p),
			RallyLibrary.position_revealed(p, profile),
			"overworld and RallyLibrary agree at %s" % p)

	profile[Save.KEY_RALLIES] = prev


# THE GARAGE IS A BUILDING NOW, not a dwell zone.
#
# This used to assert that a garage ZONE existed and was exempt from the fog gate. That zone is
# gone: the garage became a real building you drive into (`scripts/overworld_garage.gd`), which is
# what the developer asked for, so the behaviour this pinned deliberately no longer exists. Kept
# rather than deleted, because the INVARIANT behind it still matters and is the part that would
# fail silently — the garage must be reachable from the very first entry, before anything is lit.
#
# `_build_garage()` is skipped in cheap mode (it builds meshes and colliders), so the flag is
# lowered for the call and restored immediately, with no awaits in between.
func test_the_garage_is_reachable_before_anything_is_revealed() -> void:
	# The reserved id must not collide with a roster id, or a rally pick would route to the
	# garage (or vice versa). Still true: the map labels the garage destination with it.
	for rally in RallyLibrary.all():
		assert_ne(String(rally.get("id", "")), Overworld.GARAGE_ZONE_ID,
			"the reserved garage id is not a rally id")

	_ow._cheap = false
	_ow._build_garage()
	var garage = _ow._garage
	assert_not_null(garage, "the garage building is built")
	if garage != null:
		# Reachability is the invariant: no reveal predicate gates the building, so a profile
		# with nothing lit can still drive in. Proven by asking the fog predicate about the
		# garage's own ground and showing the answer does NOT gate it.
		# Constructed, not assumed: HQ now lights a small circle of its own, so the garage's
		# ground IS lit on a fresh profile. Switch that off to build the case this test is
		# actually about — genuinely dark ground under the garage — and show the building is
		# still there. Restored immediately.
		var was := Config.data.map_hq_reveal_radius
		Config.data.map_hq_reveal_radius = 0.0
		var dark := not _ow.position_revealed(RallyLibrary.HQ_MAP_POS)
		Config.data.map_hq_reveal_radius = was
		assert_true(dark,
			"with HQ's circle off, the garage's ground is unlit (else this proves nothing)")
		assert_true(is_instance_valid(garage),
			"...and the garage exists there regardless — it is a place, not a rally")
		_ow.remove_child(garage)
		garage.free()
	_ow._garage = null
	_ow._cheap = true


# ==========================================================================================
# Fresh-boot / teardown behaviours (each pays for its own instance)
# ==========================================================================================

# `Scenes.hub_path()` sends every post-rally transition here when the flag is on, and hq.gd's
# `_build_hq` is the ONLY code that clears these one-shots. Left set they leak into the next
# genuine hq.tscn entry — which is the garage — so winning a prize car would show the present
# box the moment the player drove into their garage, and `return_to_map` would open the very
# map table the overworld replaces.
func test_stale_hub_one_shots_are_drained_on_boot() -> void:
	var prev_map := RallySession.return_to_map
	var prev_reveal := RallySession.pending_car_reveal_instance_id
	RallySession.return_to_map = true
	RallySession.pending_car_reveal_instance_id = 7

	var ow := _boot()
	assert_false(RallySession.return_to_map, "the map parade one-shot is dropped")
	assert_eq(RallySession.pending_car_reveal_instance_id, -1,
		"the pending car reveal is dropped")
	remove_child(ow)
	ow.free()

	RallySession.return_to_map = prev_map
	RallySession.pending_car_reveal_instance_id = prev_reveal


# Global shader parameters PERSIST ACROSS SCENE CHANGES and the same ground shaders draw every
# stage, so a fog amount left armed here would fog a rally stage. Same leak class that
# HeadlightCone.reset() exists for.
#
# `_exit_tree`'s clear is gated on `_headless`, so the real clear path is unreachable in a
# headless run as written; the flag is lowered on the instance (private field, flagged) so the
# production code path is what runs. Skipped gracefully where the globals are not declared.
func test_fog_globals_are_disarmed_when_the_scene_is_left() -> void:
	var declared := RenderingServer.global_shader_parameter_get_list()
	if not declared.has(StringName(Overworld.FOG_GLOBAL_AMOUNT)):
		pass_test("shader global %s is not declared in this build — nothing to disarm"
			% Overworld.FOG_GLOBAL_AMOUNT)
		return
	RenderingServer.global_shader_parameter_set(Overworld.FOG_GLOBAL_AMOUNT, 1.0)
	# If the value does not read back, this build's RenderingServer is not storing globals (it is
	# a stub under --headless on some platforms) and the assertion below could only ever pass
	# vacuously — say so rather than pretending to have checked.
	var armed: Variant = RenderingServer.global_shader_parameter_get(Overworld.FOG_GLOBAL_AMOUNT)
	if typeof(armed) != TYPE_FLOAT and typeof(armed) != TYPE_INT:
		pass_test("this build does not read back global shader parameters — nothing to assert")
		return
	# No need to touch `_headless` here: the disarm in _exit_tree is deliberately NOT gated on it,
	# precisely so the anti-leak path is the one a headless test can execute.
	var ow := _boot()
	remove_child(ow)
	ow.free()
	var after: Variant = RenderingServer.global_shader_parameter_get(Overworld.FOG_GLOBAL_AMOUNT)
	assert_eq(float(after), 0.0, "the fog master switch is off once the overworld is gone")
	# The SIZE too: `overworld_fog_at` early-outs on either, so zeroing it is a second, independent
	# no-op guarantee for every other scene — a shader that ever forgot the amount check would still
	# read no fog from a hub that has been left. (The MASK is a sampler slot with no null-shaped
	# value to write, and is deliberately left; see `_exit_tree`.)
	if declared.has(StringName(Overworld.FOG_GLOBAL_SIZE)):
		var size_after: Variant = RenderingServer.global_shader_parameter_get(
			Overworld.FOG_GLOBAL_SIZE)
		if typeof(size_after) == TYPE_FLOAT or typeof(size_after) == TYPE_INT:
			assert_eq(float(size_after), 0.0, "and the map size is disarmed with it")


# ==========================================================================================
# Where the car spawns
# ==========================================================================================

# The rule: a game START puts the player at the garage; RETURNING FROM A RALLY puts them at
# that rally. `_resolve_spawn_pose` is private (there is no public seam) and is called
# directly here, per the file header.
#
# Deliberately NOT asserting the garage's map position or any rally's — those are authored
# data. What must hold for ANY roster is the RELATIONSHIP: no return id spawns at the same
# place as the HQ, a return id spawns at that rally's own position, and both land inside the
# world.
func test_a_cold_start_spawns_at_the_garage() -> void:
	RallySession.overworld_return_rally_id = ""
	var spawn: Transform3D = _ow._resolve_spawn_pose()
	var hq_xz := Overworld.world_xz(RallyLibrary.HQ_MAP_POS, _ow.size_m())
	# OUTSIDE the garage and FACING it, on the same principle as the return spawn — the car no
	# longer materialises on top of its destination pointing at nothing. Pins the RELATIONSHIP:
	# clear of the garage pad, but nearer the garage than anything else could explain.
	var off := Vector2(spawn.origin.x - hq_xz.x, spawn.origin.z - hq_xz.z)
	assert_gt(off.length(), Config.data.overworld_pad_garage_radius_m,
		"%s — clear of the garage pad" % "a cold start spawns at the garage")
	assert_lt(off.length(), Config.data.overworld_pad_garage_radius_m * 4.0,
		"%s — but parked at it, not adrift" % "a cold start spawns at the garage")
	var fwd := -spawn.basis.z
	assert_gt(Vector2(fwd.x, fwd.z).normalized().dot(-off.normalized()), 0.99,
		"%s — and pointed at the garage" % "a cold start spawns at the garage")


func test_returning_from_a_rally_spawns_outside_that_zone_facing_it() -> void:
	var rallies := RallyLibrary.all()
	assert_gt(rallies.size(), 0, "the fixture roster has something to return from")
	var rally: Dictionary = rallies[0]
	RallySession.overworld_return_rally_id = String(rally.get("id", ""))

	var spawn: Transform3D = _ow._resolve_spawn_pose()
	var pin := Overworld.world_xz(RallyLibrary.map_pos_of(rally), _ow.size_m())

	# Guard against a VACUOUS pass: a pin sitting on the garage would make "returned from a rally"
	# and "started at the garage" the same assertion. A relationship, not a value.
	var hq_xz := Overworld.world_xz(RallyLibrary.HQ_MAP_POS, _ow.size_m())
	assert_false(Vector2(pin.x, pin.z).is_equal_approx(Vector2(hq_xz.x, hq_xz.z)),
		"the fixture rally is somewhere OTHER than the garage, so this test can fail")

	# OUTSIDE the dwell circle, not on the pin. It used to land ON the pin, which read as being
	# teleported into the middle of what you had just finished — and left the zone disarmed, since
	# OverworldZone only arms once the car has LEFT it.
	var flat := Vector2(spawn.origin.x - pin.x, spawn.origin.z - pin.z)
	assert_gt(flat.length(), Config.data.overworld_zone_radius_m,
		"the car stands outside the zone's trigger radius, so the zone is armed on arrival")

	# FACING the zone: the car's forward (-Z, hence the basis' -z column) points at the pin.
	var forward := -spawn.basis.z
	var to_pin := Vector3(pin.x - spawn.origin.x, 0.0, pin.z - spawn.origin.z).normalized()
	assert_gt(Vector2(forward.x, forward.z).normalized().dot(Vector2(to_pin.x, to_pin.z)), 0.99,
		"and it is pointed at the rally it just came back from")


# One-shot: the id is consumed by the read, so the NEXT boot is a plain start again. Without
# this the player would be pinned to that rally forever instead of starting from the garage.
func test_the_return_id_is_consumed_by_the_spawn() -> void:
	var rally: Dictionary = RallyLibrary.all()[0]
	RallySession.overworld_return_rally_id = String(rally.get("id", ""))
	_ow._resolve_spawn_pose()
	assert_eq(RallySession.overworld_return_rally_id, "",
		"the return id is cleared once used, so it cannot leak into a later boot")

	var spawn: Transform3D = _ow._resolve_spawn_pose()
	var hq_xz := Overworld.world_xz(RallyLibrary.HQ_MAP_POS, _ow.size_m())
	# OUTSIDE the garage and FACING it, on the same principle as the return spawn — the car no
	# longer materialises on top of its destination pointing at nothing. Pins the RELATIONSHIP:
	# clear of the garage pad, but nearer the garage than anything else could explain.
	var off := Vector2(spawn.origin.x - hq_xz.x, spawn.origin.z - hq_xz.z)
	assert_gt(off.length(), Config.data.overworld_pad_garage_radius_m,
		"%s — clear of the garage pad" % "the second boot is back to the garage")
	assert_lt(off.length(), Config.data.overworld_pad_garage_radius_m * 4.0,
		"%s — but parked at it, not adrift" % "the second boot is back to the garage")
	var fwd := -spawn.basis.z
	assert_gt(Vector2(fwd.x, fwd.z).normalized().dot(-off.normalized()), 0.99,
		"%s — and pointed at the garage" % "the second boot is back to the garage")

# A stale id (a rally removed from the roster, or a profile from another build) must not
# spawn the car at the origin or off the map — it falls back to the garage like any start.
func test_an_unknown_return_id_falls_back_to_the_garage() -> void:
	RallySession.overworld_return_rally_id = "no_such_rally_id"
	var spawn: Transform3D = _ow._resolve_spawn_pose()
	var b := _ow.bounds()
	assert_true(b.has_point(Vector2(spawn.origin.x, spawn.origin.z)),
		"an unknown id still spawns inside the world, got %s" % spawn.origin)
	var hq_xz := Overworld.world_xz(RallyLibrary.HQ_MAP_POS, _ow.size_m())
	# OUTSIDE the garage and FACING it, on the same principle as the return spawn — the car no
	# longer materialises on top of its destination pointing at nothing. Pins the RELATIONSHIP:
	# clear of the garage pad, but nearer the garage than anything else could explain.
	var off := Vector2(spawn.origin.x - hq_xz.x, spawn.origin.z - hq_xz.z)
	assert_gt(off.length(), Config.data.overworld_pad_garage_radius_m,
		"%s — clear of the garage pad" % "an unknown id falls back to the garage")
	assert_lt(off.length(), Config.data.overworld_pad_garage_radius_m * 4.0,
		"%s — but parked at it, not adrift" % "an unknown id falls back to the garage")
	var fwd := -spawn.basis.z
	assert_gt(Vector2(fwd.x, fwd.z).normalized().dot(-off.normalized()), 0.99,
		"%s — and pointed at the garage" % "an unknown id falls back to the garage")

# ==========================================================================================
# Per-car visual effects (features/overworld.md -> "Visual effects")
# ==========================================================================================
#
# The hub used to render none of the stage's surface FX, which read as "the overworld is
# missing things stages have". These pin that the port is wired — the NODES exist and the
# tyre marks are in ungated mode — not any tuning value.

func test_surface_effects_are_built() -> void:
	assert_not_null(_ow.get_node_or_null("TireMarks"), "the hub lays tyre marks")
	assert_not_null(_ow.get_node_or_null("WheelParticles"), "the hub throws wheel spray")
	assert_not_null(_ow.get_node_or_null("ExhaustFlames"), "the hub draws backfire flames")
	# The flames drive their own transform from the car (setup sets _follow_car), so they must
	# hang off the ROOT — parented to the car the offset would compose twice.
	assert_eq((_ow.get_node("ExhaustFlames") as Node).get_parent(), _ow,
		"the flames hang off the root, not the car")


func test_speed_lines_are_authored_in_the_scene() -> void:
	var lines := _ow.get_node_or_null("SpeedLines")
	assert_not_null(lines, "the hub has a SpeedLines overlay")
	if lines != null:
		assert_not_null(lines.get_node_or_null("ColorRect"), "...with its full-screen rect")
		assert_eq(lines.get("car"), _ow.get_node("Car"), "...pointed at the car")


func test_tire_marks_run_ungated() -> void:
	# There is no single centerline out here — the roads are a network — so the marks must be
	# set up with a null curve and gated by the terrain surface instead.
	var marks := _ow.get_node_or_null("TireMarks") as TireMarks
	assert_not_null(marks, "the hub lays tyre marks")
	if marks != null:
		assert_true(marks._ungated, "the hub's marks are ungated (private: no public seam)")
		assert_gt(marks.wheel_count(), 0, "...and are wired to the car's wheels")


# ==========================================================================================
# The PROGRESSIVE PRECOMPUTE — which chunks a launch is allowed to skip
# ==========================================================================================
#
# `reach_sources` / `chunk_in_reach` decide what the first-launch precompute bakes: the lit
# region, dilated so it covers everywhere the fog's SOFT push can put the car plus the terrain's
# whole streaming ring around such a point. These are STATIC and pure, so every test below runs
# with no scene, no terrain and no car.
#
# Nothing here pins a value. The margin is asserted as a PROPERTY (a point the push permits is
# baked), the size and the load radius are this file's own arguments, and the roster is whatever
# `RallyLibrary.all()` holds — the tests only ever compare the rule against itself.

# A size and a load radius chosen locally, so no shipped tunable is involved.
const REACH_SIZE_M := 1000.0
const REACH_LOAD_RADIUS := 4


# The chunk containing a map position — the coord the precompute decides about.
func _coord_of(map_pos: Vector2, size_m := REACH_SIZE_M) -> Vector2i:
	var world := Overworld.world_xz(map_pos, size_m)
	return Vector2i(floori(world.x / TerrainManager.CHUNK_M), floori(world.z / TerrainManager.CHUNK_M))


func _reach(profile: Dictionary, extra: Array[Vector2] = []) -> Array:
	return Overworld.reach_sources(profile, REACH_SIZE_M, REACH_LOAD_RADIUS, extra)


# THE SAFETY PROPERTY, and the one that can hurt the player: the fog is a soft push, so the car
# may legitimately stand up to FOG_HARD_MARGIN_M outside the lit region, and the terrain then
# streams a `load_radius` ring of chunks AROUND it. Every one of those must already be baked —
# this project chose loud holes over generate-on-miss, so a gap is a visible hole and a
# fall-through under a moving car. Asserted symbolically against the constants, never as a number.
func test_everywhere_the_fog_push_permits_is_in_reach() -> void:
	var lit := Vector2(0.5, 0.5)
	var profile := {Save.KEY_RALLIES: {}}
	var sources := _reach(profile, [lit] as Array[Vector2])
	# The furthest the car can be from lit ground, plus the furthest chunk the streamer then wants.
	var stray_m: float = Overworld.FOG_HARD_MARGIN_M \
		+ float(REACH_LOAD_RADIUS + 1) * TerrainManager.CHUNK_M
	var stray_map := stray_m / REACH_SIZE_M
	# The array is TYPED and the loop variable annotated: an untyped `for` over an untyped literal
	# makes `dir` a Variant, which makes `dir * stray_map` a Variant, which makes the `:=` below
	# uninferable — a PARSE error that stops GUT collecting this whole file and aborts the run.
	var dirs: Array[Vector2] = [Vector2(1.0, 0.0), Vector2(-1.0, 0.0), Vector2(0.0, 1.0),
		Vector2(0.0, -1.0), Vector2(0.7, 0.7).normalized()]
	for dir: Vector2 in dirs:
		var out: Vector2 = lit + dir * stray_map
		assert_true(Overworld.chunk_in_reach(_coord_of(out), sources, REACH_SIZE_M),
			"the chunk %s the push allows is baked" % dir)


# ...but not the whole map: something has to be deferred, or the change does nothing. The far
# corner of the map from a single lit point is out of reach.
func test_far_ground_is_deferred() -> void:
	var lit := Vector2(0.2, 0.2)
	var sources := _reach({Save.KEY_RALLIES: {}}, [lit] as Array[Vector2])
	assert_false(Overworld.chunk_in_reach(_coord_of(Vector2(0.95, 0.95)), sources, REACH_SIZE_M),
		"the opposite corner of the map is not baked yet")


# The garage is fog-EXEMPT rather than lit (`map_hq_reveal_radius` ships at 0), so a naive "bake
# what is lit" would hole around the player's own garage — the exact wait this change is about.
func test_the_garage_is_always_in_reach() -> void:
	var sources := Overworld.reach_sources({Save.KEY_RALLIES: {}}, REACH_SIZE_M, REACH_LOAD_RADIUS,
		[RallyLibrary.HQ_MAP_POS] as Array[Vector2])
	assert_true(Overworld.chunk_in_reach(_coord_of(RallyLibrary.HQ_MAP_POS), sources, REACH_SIZE_M),
		"the ground under the garage is baked with nothing lit at all")


# A lit rally's own ground is baked — the reach set is built from the SHARED lit predicate, so
# anywhere the player can enter is ground that exists.
func test_a_lit_rally_is_in_reach() -> void:
	var rallies: Array[Dictionary] = RallyLibrary.all()
	if rallies.is_empty():
		pending("no roster to reason about")
		return
	var rally: Dictionary = rallies[0]
	var pin := RallyLibrary.map_pos_of(rally)
	var profile := {Save.KEY_RALLIES: {String(rally["id"]): {"completed": true}}}
	assert_true(RallyLibrary.rally_revealed(rally, profile),
		"the completed rally is revealed (else vacuous)")
	assert_true(Overworld.chunk_in_reach(_coord_of(pin), _reach(profile), REACH_SIZE_M),
		"and its own ground is baked")


# PROGRESSION ONLY EVER GROWS THE SET. Each launch bakes what is newly in reach and never has to
# un-bake anything, which is what makes the disk cache append-only and needs no invalidation.
func test_progress_only_grows_the_reach_set() -> void:
	var rallies: Array[Dictionary] = RallyLibrary.all()
	if rallies.is_empty():
		pending("no roster to reason about")
		return
	var before := _reach({Save.KEY_RALLIES: {}}, [RallyLibrary.HQ_MAP_POS] as Array[Vector2])
	var done := {}
	for rally in rallies:
		done[String(rally["id"])] = {"completed": true}
	var after := _reach({Save.KEY_RALLIES: done}, [RallyLibrary.HQ_MAP_POS] as Array[Vector2])

	var grew := false
	# Every coord across the map: what was baked before is still baked, and something new is.
	for z in range(-12, 13):
		for x in range(-12, 13):
			var coord := Vector2i(x, z)
			var was := Overworld.chunk_in_reach(coord, before, REACH_SIZE_M)
			var now := Overworld.chunk_in_reach(coord, after, REACH_SIZE_M)
			if was:
				assert_true(now, "coord %s stays in reach once progress is made" % coord)
			elif now:
				grew = true
	assert_true(grew, "completing the roster brings new ground in reach (else vacuous)")


# ==========================================================================================
# The RALLY-DETAIL CARD — the confirmation step between arriving and racing
# ==========================================================================================
#
# Driving into a zone must NOT start anything: it opens the shared `RallyDetail` card and the
# player starts the rally from there. These tests run against the cheap instance (no zone layer),
# driving the host seam `_on_zone_activated` directly — which is exactly what the zone layer emits.

func _press(action: String) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = action
	e.pressed = true
	return e


# A REAL gamepad button event for `action`, taken from whatever button the project binds — so a
# controller press is proven to reach the handler without pinning the button index.
func _gamepad_press(action: String) -> InputEventJoypadButton:
	for e in InputMap.action_get_events(action):
		if e is InputEventJoypadButton:
			var press := (e as InputEventJoypadButton).duplicate() as InputEventJoypadButton
			press.pressed = true
			press.pressure = 1.0
			return press
	return null


func _nav_of(root: Node) -> MenuNav:
	for child in root.get_children():
		if child is MenuNav:
			return child as MenuNav
	return null


func _a_rally_id() -> String:
	var all: Array[Dictionary] = RallyLibrary.all()
	return String(all[0]["id"]) if not all.is_empty() else ""


# Open the card the way a zone does, from a known-clean starting state.
func _open_card() -> String:
	_ow._close_rally_detail()
	var id := _a_rally_id()
	Scenes.last_blocked_path = ""
	RallySession.pending_rally_pick_id = ""
	_ow._on_zone_activated(id)
	return id


func after_each() -> void:
	# Leave the SHARED instance clean: the card and the picker each hold the car's control lock and
	# a screen claim, and the picker also hides the car and freezes it.
	if is_instance_valid(_ow):
		if _ow.picker_open():
			_ow._picker.close()
		_ow._close_rally_detail()


# THE BEHAVIOUR THE USER ASKED FOR: arriving shows the card and starts nothing.
func test_activating_a_zone_opens_the_card_and_starts_nothing() -> void:
	var id := _open_card()
	assert_true(_ow.rally_detail_open(), "driving into a zone opens the rally card")
	assert_eq(_ow.rally_detail_id(), id, "...for the rally whose zone fired")
	assert_true(_ow._detail_ui.layer.visible, "...and the card is actually on screen")
	# NOTHING started: no scene transition was even attempted (Scenes.block_real_changes records
	# the destination a production build would have loaded), and no pick was queued.
	assert_eq(Scenes.last_blocked_path, "", "no scene change was attempted")
	assert_eq(RallySession.pending_rally_pick_id, "", "and no rally pick was queued")
	# The car is held while the card is up — the same treatment the full map gets.
	assert_true(bool(_ow.get_node("Car").get("controls_locked")),
		"the car does not drive off while the player reads the card")


# "Enter Rally — choose car" — SUPERSEDED BEHAVIOUR, deliberately re-pinned.
#
# This used to assert that Enter queued `pending_rally_pick_id` and left for `hq.tscn`'s car park.
# The user has since asked for the pick to happen IN THE HUB ("I don't want the player to be moved
# to a different scene where they select their car"), so that contract is gone by request. Design
# decision D3's intent survives — there is still a pick — only its venue moved.
#
# The valuable half of the old test is kept: Enter does something specific and does not silently
# no-op. And the new assertions add a regression guard for a decision made on purpose —
# `pending_rally_pick_id` must stay EMPTY, because setting it makes
# `hq.gd::_maybe_redirect_to_overworld` refuse to send the player back here.
func test_the_cards_enter_button_opens_the_picker_in_place() -> void:
	var id := _open_card()
	# Through the BUTTON's own signal, so the wiring is what is under test, not just the callback.
	_ow._detail_ui.enter_button.pressed.emit()
	assert_true(_ow.picker_open(), "Enter opens the car picker in the hub")
	assert_eq(Scenes.last_blocked_path, "", "no scene change was attempted")
	assert_eq(RallySession.pending_rally_pick_id, "",
		"and the HQ hand-off flag stays empty — setting it would stop the HQ redirecting back")
	# The card is HIDDEN, not closed: its open flag still holds the dwell latch, the map veto and
	# the control lock, so cancelling the picker can put the same card back untouched.
	assert_true(_ow.rally_detail_open(), "the card is still the open state behind the picker")
	assert_false(_ow._detail_ui.layer.visible, "...but it is off screen while the picker is up")
	assert_true(bool(_ow.get_node("Car").get("controls_locked")), "the car is still held")
	assert_eq(id, _ow.rally_detail_id(), "the picker is showing cars for the card's rally")


# Cancelling the picker puts the SAME card back up, with nothing else disturbed — the one-step-back
# cancel target, and the reason the card is hidden rather than closed.
func test_cancelling_the_picker_returns_to_the_card() -> void:
	var id := _open_card()
	_ow._detail_ui.enter_button.pressed.emit()
	assert_true(_ow.picker_open(), "the picker is up (else vacuous)")
	_ow._picker.close()
	assert_false(_ow.picker_open(), "the picker closes")
	assert_true(_ow.rally_detail_open(), "and the card is back")
	assert_true(_ow._detail_ui.layer.visible, "...on screen")
	assert_eq(_ow.rally_detail_id(), id, "...still showing the same rally")
	assert_eq(Scenes.last_blocked_path, "", "nothing was started")


# Confirming in the picker is what starts the rally now — and the WIRING is what this file can
# safely assert: `RallySession.start_rally` generates a track per event and is a coroutine, so
# actually invoking the host's handler here would either block the suite generating stages or (worse)
# park a coroutine that resumes inside a LATER test and leaks a live rally session into it.
#
# So the split is deliberate: the picker's own contract — `started` carries the right rally and the
# chosen car, and the live car is not re-fielded — is asserted at its seam in
# test_overworld_picker.gd, and what is pinned HERE is that the hub is listening to it, and to the
# other two outcomes. Without this, a renamed handler would silently disconnect the whole flow and
# every test above would still pass (the picker would open and then do nothing at all).
func test_the_host_is_wired_to_every_picker_outcome() -> void:
	var picker := _ow._picker
	assert_not_null(picker, "the hub built a picker")
	assert_true(picker.started.is_connected(_ow._on_picker_started),
		"confirming a rally car reaches the hub's start handler")
	assert_true(picker.closed.is_connected(_ow._on_picker_closed),
		"cancelling reaches the hub, which puts the card back")
	assert_true(picker.granted.is_connected(_ow._on_picker_granted),
		"a starter grant reaches the hub, which re-fields the live car")


# BACK PUTS THE PLAYER BACK BEHIND THE WHEEL, having started nothing — by keyboard and by pad.
func test_back_closes_the_card_and_hands_control_back() -> void:
	for use_pad in [false, true]:
		var id := _open_card()
		assert_true(_ow.rally_detail_open(), "the card is up for %s (else vacuous)" % id)
		var nav := _nav_of(_ow._detail_ui.page)
		assert_not_null(nav, "the card has a MenuNav")
		var event: InputEvent = _gamepad_press("menu_back") if use_pad else _press("menu_back")
		assert_not_null(event, "menu_back is bound for this device")
		nav._unhandled_input(event)
		assert_false(_ow.rally_detail_open(), "back closes the card (pad: %s)" % use_pad)
		assert_false(_ow._detail_ui.layer.visible, "...and takes it off screen")
		assert_false(bool(_ow.get_node("Car").get("controls_locked")),
			"...and gives the car back to the player")
		assert_eq(Scenes.last_blocked_path, "", "...without starting anything")
		assert_eq(RallySession.pending_rally_pick_id, "", "...and without queuing a pick")


# KEYBOARD + GAMEPAD NAVIGABLE, per CLAUDE.md. The shared card ships every button FOCUS_NONE
# (the HQ drives it from its own input handler and has no cursor), so the overworld's copy is only
# navigable because `MenuNav.attach` flips them — assert that it did, that exactly one nav exists,
# that the cursor is ON SCREEN when the card opens (the "built while hidden" focus-death trap: the
# grab is deferred to the visibility change, not done at build time), and that WASD moves it.
func test_the_card_is_keyboard_and_gamepad_navigable() -> void:
	_open_card()
	await get_tree().process_frame
	var page := _ow._detail_ui.page
	var buttons := page.find_children("*", "Button", true, false)
	assert_gt(buttons.size(), 1, "the card has more than one button (else nav is vacuous)")
	for button in buttons:
		assert_eq((button as Button).focus_mode, Control.FOCUS_ALL,
			"%s is reachable by the focus cursor" % (button as Button).text)
	var navs := 0
	for child in page.get_children():
		if child is MenuNav:
			navs += 1
	assert_eq(navs, 1, "exactly one MenuNav drives the card")
	var first := page.get_viewport().gui_get_focus_owner()
	assert_not_null(first, "the cursor is on screen the moment the card opens")
	assert_true(page.is_ancestor_of(first as Node), "...and it is on the card, not behind it")
	# The two footer buttons sit side by side, so left/right is the axis that must work.
	_nav_of(page)._unhandled_input(_press("menu_left"))
	assert_ne(page.get_viewport().gui_get_focus_owner(), first, "WASD moves the cursor")


# TWO MODAL OWNERS OF ONE SCREEN. The card and the full map both claim the screen and both take
# the car's control lock, so M must not open a map over the card.
func test_the_map_cannot_open_over_the_card() -> void:
	assert_true(_ow._map_toggle_allowed(), "the map opens normally (else vacuous)")
	_open_card()
	assert_false(_ow._map_toggle_allowed(), "M is vetoed while the card is up")
	_ow._close_rally_detail()
	assert_true(_ow._map_toggle_allowed(), "...and allowed again once it closes")


# LOCK OWNERSHIP. `controls_locked` has three independent owners in this hub, so the card must
# only ever release a lock IT took — otherwise closing it would hand control back to a player who
# is supposed to be held by the loading path or the map.
func test_the_card_never_releases_someone_elses_control_lock() -> void:
	var car := _ow.get_node("Car")
	car.set("controls_locked", true)   # stand in for the map / the loading path holding it
	_open_card()
	assert_true(bool(car.get("controls_locked")), "the card leaves the existing lock in place")
	_ow._close_rally_detail()
	assert_true(bool(car.get("controls_locked")),
		"and closing the card does not clear a lock it did not take")
	car.set("controls_locked", false)


# THE STARTER PICK. A profile that owns nothing gets the picker on boot — the pick that used to
# live behind hq.tscn's title screen — and a profile that owns a car must NOT (that would take the
# control lock and claim the screen from a returning player every time they entered the hub).
#
# Driven through the decision function rather than by booting a second world: the boot call site is
# one line, and the two DIRECTIONS are the whole behaviour. The shipped car catalogue is restored
# for the duration, because `CarLibrary.STARTER_MODEL_IDS` is shipped content by definition — this
# asserts only that a pick was OFFERED, never which cars are in it.
func test_the_starter_pick_opens_only_for_a_profile_that_owns_nothing() -> void:
	# Owning a car (which before_all arranged) must refuse.
	assert_gt(Save.selected_instance_id(), -1, "the profile owns a car (else vacuous)")
	assert_false(_ow._maybe_open_starter_pick(), "a returning player is not shown a starter pick")
	assert_false(_ow.picker_open(), "...and nothing claims the screen")

	# Now the fresh-profile case, with the real catalogue back so the shipped pool resolves.
	var cars_was: Array = Save.profile[Save.KEY_CARS]
	var selected_was: Variant = Save.profile.get("selected_instance_id", -1)
	CarFixtures.restore()
	Save.profile[Save.KEY_CARS] = []
	Save.profile["selected_instance_id"] = -1
	var opened := _ow._maybe_open_starter_pick()
	var locked := bool(_ow.get_node("Car").get("controls_locked"))
	if opened:
		_ow._picker.close()
	# Restore before asserting, so a failure cannot leak a carless profile into the next test.
	Save.profile[Save.KEY_CARS] = cars_was
	Save.profile["selected_instance_id"] = selected_was
	CarFixtures.install()

	assert_true(opened, "a profile with no car is asked to choose one")
	assert_true(locked, "...and the car is held while they choose, so it cannot be driven off")
	assert_false(_ow.picker_open(), "the picker was closed again by this test")
	assert_false(bool(_ow.get_node("Car").get("controls_locked")),
		"...and closing it handed the car back")


# THE STARTER PICK LAUNCHES THE OPENING RALLY, the way the old HQ does (`hq.gd::_confirm_starter`):
# the player who just chose their first car is dropped into the event that AWARDS it rather than left
# parked in a hub with nothing behind them. `RallyLibrary.opening_rally_id_for(model_id)` names it.
#
# WHAT IS ASSERTED HERE IS THE FALLBACK BRANCH, and the split is deliberate for the same reason the
# rally start's is: the launching branch ends in `RallySession.start_rally`, an awaited coroutine that
# generates a track per event — invoking it from a test either blocks the suite or parks a coroutine
# that resumes inside a LATER test and leaks a live rally session into it. So the branch that STARTS
# is covered by the lookup below plus the wiring test above; the branch that does NOT is exercised
# for real here.
#
# The fixture roster awards no cars at all (no `prize_car` on any fixture rally), which is exactly
# the empty case, so this runs it end to end.
func test_a_granted_starter_with_no_opening_rally_stays_in_the_hub() -> void:
	var owned := Save.selected_car()
	assert_false(owned.is_empty(), "the profile owns a car (else vacuous)")
	assert_eq(RallyLibrary.opening_rally_id_for(String(owned["model_id"])), "",
		"no fixture rally awards this car — this is the empty branch")
	Scenes.last_blocked_path = ""
	_ow._on_picker_granted(int(owned["instance_id"]))
	assert_eq(Scenes.last_blocked_path, "",
		"with no opening rally the hub does not try to start one")
	assert_false(_ow.picker_open(), "and the picker is closed either way")


# ...and the lookup the launching branch turns on really does resolve when a rally awards the car.
# Asserted on the pure function, over a roster this test authors, so it names no shipped content and
# never reaches the awaited start.
func test_the_opening_rally_lookup_finds_the_rally_that_awards_the_car() -> void:
	var owned := Save.selected_car()
	var model_id := String(owned.get("model_id", ""))
	var roster: Array[Dictionary] = [{
		"id": "awards_it", "name": "Awards It", "region": "home", "difficulty": 1,
		"special": false, "map_pos": RallyLibrary.HQ_MAP_POS, "restriction": {},
		"prize_car": model_id, "events": [],
	}]
	roster.append_array(RallyFixtures.rallies())
	RallyLibrary.override_for_test(roster)
	assert_eq(RallyLibrary.opening_rally_id_for(model_id), "awards_it",
		"the opening rally is the one whose prize IS this car")
	RallyFixtures.install()   # put the plain fixture roster back for the next test


# A destination that is NOT a rally keeps the old direct route rather than showing an empty card.
# Nothing reaches this today (the garage is a building, and the zone layer only builds zones from
# roster entries), which is exactly why it is asserted: the payload shape still admits it.
func test_a_non_rally_activation_still_routes_straight_through() -> void:
	Scenes.last_blocked_path = ""
	RallySession.pending_rally_pick_id = ""
	_ow._on_zone_activated({"rally_id": Overworld.GARAGE_ZONE_ID, "kind": "garage"})
	assert_false(_ow.rally_detail_open(), "no rally card is shown for a non-rally destination")
	assert_eq(Scenes.last_blocked_path, Scenes.HQ, "it routes straight through as before")
	RallySession.pending_rally_pick_id = ""
	Scenes.last_blocked_path = ""


# THE RETURN SPAWN IS WALKED ONTO THE ROAD, and stays outside the zone while it happens.
#
# `return_pose_for` picks the right DISTANCE from the pin but lands wherever that direction happens
# to be — verge included. The snap walks the road serving that zone outward from the pin instead, so
# the point is on the centreline AND clear of the dwell circle by construction. A plain "nearest road
# point" cannot promise the second: the nearest point to a spot beside a zone is usually back inside
# it, which is exactly the case this walk exists to avoid.
#
# Tests the WALK directly (it is static and pure), so no roads, no terrain and no car are needed.
func test_the_walk_returns_a_point_the_requested_distance_along_a_road() -> void:
	# A straight 100 m road along +X, as two points.
	var straight := PackedVector2Array([Vector2(0.0, 0.0), Vector2(100.0, 0.0)])
	var at30: Vector2 = Overworld._walk_polyline(straight, true, 30.0)
	assert_almost_eq(at30.x, 30.0, 0.001, "walking 30 m from the start lands 30 m along")
	assert_almost_eq(at30.y, 0.0, 0.001, "and stays on the road")

	# From the OTHER end, the same distance measures back from the far point.
	var from_end: Vector2 = Overworld._walk_polyline(straight, false, 30.0)
	assert_almost_eq(from_end.x, 70.0, 0.001, "walking from the far end measures back along it")

	# A dog-leg: the walk must follow the road's length, not the straight line between its ends.
	var bent := PackedVector2Array([Vector2(0.0, 0.0), Vector2(10.0, 0.0), Vector2(10.0, 90.0)])
	var round_corner: Vector2 = Overworld._walk_polyline(bent, true, 40.0)
	assert_almost_eq(round_corner.x, 10.0, 0.001, "past the corner, it is on the second leg")
	assert_almost_eq(round_corner.y, 30.0, 0.001, "having spent 10 m on the first leg")

	# A road SHORTER than the gap cannot place the car clear of the zone, and says so rather than
	# returning its far end — the caller falls back to the geometric pose instead of standing the
	# player somewhere arbitrary.
	assert_eq(Overworld._walk_polyline(straight, true, 500.0), Vector2.INF,
		"a road too short to clear the zone reports no answer")


# THE LAUNCH SPAWN IS THE RESOLVED GARAGE, NOT THE DECLARED DEFAULT.
#
# `_hq_map_pos` starts life holding `RallyLibrary.HQ_MAP_POS` and is overwritten in `_ready` with the
# profile-derived garage position. `_default_spawn_map_pos` returns it and `return_pose_for` offsets
# away from it — so if either is read BEFORE that assignment, the car is placed relative to the map
# centre while the garage and the entire road network sit beside the player's first-car rally. That
# happened: the launch spawn landed in the grass, nowhere near a road.
#
# This asserts the two agree after boot. It is only DISCRIMINATING for a profile whose garage has
# actually moved (a recorded starter with a resolvable first-car rally) — with no starter both sides
# are the centre and it passes trivially — so it also reports which case it ran, rather than looking
# like a stronger guard than it is.
func test_the_launch_spawn_uses_the_resolved_garage_position() -> void:
	var resolved := RallyLibrary.hq_map_pos(Save.profile, _ow.size_m())
	assert_eq(_ow._default_spawn_map_pos(), resolved,
		"the launch spawn is the garage position the roads and pads were built from")

	if resolved.is_equal_approx(RallyLibrary.HQ_MAP_POS):
		# Not a failure — this fixture profile has no starter, so the garage IS the centre. Say so,
		# because the assertion above cannot tell a correct read from a stale one in that case.
		pending("fixture profile keeps the garage at the centre; ordering not exercised")


# THE BOOT VALUES ARE UNSET BY CONSTRUCTION — the guard that makes the ordering above enforceable
# rather than merely observed. See features/overworld.md -> "Every boot value is resolved in one
# preamble, before anything reads it".
#
# The bug class this closes: a member declared with a PLAUSIBLE default answers successfully when
# read too early, so the boot continues with a coherent but wrong world instead of failing. That
# shipped three times in one session. `_size_m` declared 4000.0 while the shipped map is 1000, and
# `_hq_map_pos` declared the map centre — both are exactly the readings a too-early caller cannot
# distinguish from a real one.
#
# Asserted on a scene that has NOT entered the tree, so `_ready` has not run: this is the state any
# early reader would see. No tunable is pinned — the claim is "not a usable value", for any sentinel
# and any shipped size. (The `assert()`s in `size_m()`/`bounds()` are the other half of this guard
# and cannot be tested directly: a failing GDScript assert aborts the process rather than raising
# something catchable, so the declaration state is the testable surface.)
func test_boot_values_are_unset_until_ready_resolves_them() -> void:
	var fresh: Overworld = load(OVERWORLD_SCENE).instantiate()
	# NOT add_child'd on purpose — entering the tree is what runs _ready.
	assert_eq(fresh._size_m, 0.0,
		"world size is unset before _ready, not a plausible default a caller could use")
	assert_true(fresh._bounds.size.x <= 0.0,
		"world bounds are empty before _ready, so an early read fails closed")
	assert_eq(fresh._hq_map_pos, Vector2.INF,
		"the garage position is unset before _ready rather than defaulting to the map centre")
	fresh.free()


# ==========================================================================================
# THE PER-FRAME STAGE SEQUENCE — ONE definition, not two
# ==========================================================================================
#
# `_process` used to carry an INLINED, TIMED copy of the per-frame stage sequence, with
# `_process_stages` holding an untimed copy of the same thing and a comment asking whoever
# added a stage to remember to add it to both. A stage added to one silently did not run on
# the other path. There is now one sequence; the spike timing is a side-channel written into
# it (`_spike_us`) rather than a second copy of the calls.
#
# These tests are the guard on that. They go through private members — the per-frame sequence
# has no public seam — and they assert only SIDE EFFECTS that must hold for any budgets, never
# an interval or a budget value.

# Every stage's own bookkeeping moves when the single sequence runs. The two countdowns belong
# to stages at OPPOSITE ends of it (region look first, cache eviction second-to-last), so both
# moving is evidence the whole sequence ran rather than a prefix of it.
func test_process_stages_runs_every_stage_of_the_sequence() -> void:
	var region_before: int = _ow._region_countdown
	var evict_before: int = _ow._evict_countdown
	_ow._process_stages(Config.data, 0.016)  # private: the per-frame sequence has no public seam
	assert_eq(_ow._region_countdown, region_before - 1, "the region-look stage ticked")
	assert_eq(_ow._evict_countdown, evict_before - 1, "the cache-eviction stage ticked")


# _process must DELEGATE to that one sequence rather than repeating it. Same observable move,
# driven through the real per-frame entry point.
func test_process_drives_the_same_single_sequence() -> void:
	var region_before: int = _ow._region_countdown
	var evict_before: int = _ow._evict_countdown
	_ow._process(0.016)
	assert_eq(_ow._region_countdown, region_before - 1, "_process ticked the region-look stage")
	assert_eq(_ow._evict_countdown, evict_before - 1, "_process ticked the eviction stage")


# The spike-log timing rides the SAME sequence: with the diagnostic armed, every stage boundary
# is stamped, in order. This is what makes "add a stage and it is timed too" automatic instead
# of a comment asking someone to remember. The array is preallocated and only written when the
# log is on, so the shipping path allocates nothing — the test restores the flag either way.
func test_arming_the_spike_log_times_every_stage_boundary_in_order() -> void:
	var was_log: bool = _ow._spike_log
	_ow._spike_log = true
	# Zero the stamps first so a filled slot can only have come from this call.
	for i in _ow._spike_us.size():
		_ow._spike_us[i] = 0
	_ow._process_stages(Config.data, 0.016)
	var stamps := _ow._spike_us
	_ow._spike_log = was_log
	assert_gt(stamps.size(), 1, "there is a stamp per stage boundary")
	for i in stamps.size():
		assert_gt(stamps[i], 0, "stage boundary %d was stamped" % i)
		if i > 0:
			assert_true(stamps[i] >= stamps[i - 1],
				"boundary %d is not before boundary %d" % [i, i - 1])


# With the diagnostic OFF, nothing is written — the per-frame path must not pay for a
# diagnostic nobody asked for.
func test_the_shipping_path_records_no_timing() -> void:
	var was_log: bool = _ow._spike_log
	_ow._spike_log = false
	for i in _ow._spike_us.size():
		_ow._spike_us[i] = 0
	_ow._process_stages(Config.data, 0.016)
	var untouched := true
	for i in _ow._spike_us.size():
		untouched = untouched and _ow._spike_us[i] == 0
	_ow._spike_log = was_log
	assert_true(untouched, "no clock reads are recorded when the spike log is off")


# THE ANTI-DUPLICATION PIN. Each per-frame stage must be CALLED from exactly one place in
# overworld.gd — that is the property whose absence was the bug. A source scan is the only way
# to assert "there is no second copy of the sequence"; behaviour alone cannot see a copy that
# runs on a path the test did not take.
func test_each_per_frame_stage_is_called_from_exactly_one_place() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/overworld.gd")
	assert_false(src.is_empty(), "the source is readable")
	for call_text in ["_apply_region_look(car_map_pos())", "_update_fog_boundary(delta)",
			"_update_zones(delta)", "evict_to_cap()"]:
		assert_eq(src.count(call_text), 1,
			"'%s' is called from exactly one place — a second copy of the per-frame sequence is the bug this guards" % call_text)
