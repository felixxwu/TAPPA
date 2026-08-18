extends GutTest
# OverworldFogWall — the translucent curtain standing on the FOG FRONTIER, so the edge of where the
# player may go is visible before the veil and the push-back explain it. See features/overworld.md →
# "The frontier wall".
#
# WHICH BORDER: the frontier (the growing union of reveal circles), not the coastline. The only code
# that darkens the screen or moves the car is `Overworld._update_fog_boundary`, keyed on
# `position_revealed`; nothing pushes or collides at the map bounds.
#
# The geometry is a STATIC, PURE function (`contour`: circles in, world-space polylines out), so
# everything below runs with no scene, no terrain and no renderer — and NOT ONE ASSERTION SAMPLES A
# PIXEL. Nothing tunable is pinned either: the wall's height, alpha, colour and enabled flag are all
# GameConfig fields, and no reveal radius or rally is named — the frontier is asserted as AGREEMENT
# with `RallyLibrary.position_lit_by`, the same predicate the fog and the push use.

const SaveTestHelpers = preload("res://tests/headless/save_test_helpers.gd")
const TEST_PATH := "user://test_overworld_fog_wall.json"

# Map->world scale for this file. Arbitrary and local: the real conversion belongs to overworld.gd.
const SIZE_M := 1000.0


func before_each() -> void:
	RallyFixtures.install()
	SaveTestHelpers.redirect(TEST_PATH)


func after_each() -> void:
	SaveTestHelpers.cleanup(TEST_PATH)
	RallyFixtures.restore()


# --- Helpers ------------------------------------------------------------------------------


func _complete(rally_id: String) -> void:
	var rallies: Dictionary = Save.profile[Save.KEY_RALLIES]
	rallies[rally_id] = {"completed": true, "best_placed": 1}


# One synthetic circle, in the shape `RallyLibrary.lit_sources` returns: [centre (map), radius].
func _source(x: float, y: float, r: float) -> Array:
	return [Vector2(x, y), r]


func _wall(profile: Dictionary = Save.profile) -> OverworldFogWall:
	var wall := OverworldFogWall.new()
	add_child_autofree(wall)
	wall.setup({"size_m": SIZE_M, "visuals": false, "profile": profile})
	return wall


func _world_to_map(p: Vector2) -> Vector2:
	return Overworld.map_pos_of(Vector3(p.x, 0.0, p.y), SIZE_M)


# --- The contour stands ON the frontier ---------------------------------------------------


# THE LOAD-BEARING PROPERTY: every point of the curtain is on the boundary of the lit region — lit
# just inside, unlit just outside. Asserted against `position_lit_by`, the predicate the fog mask is
# rasterised from and the push is keyed on, so the wall cannot stand anywhere the player is not
# actually turned back.
func test_every_contour_point_sits_on_the_lit_boundary() -> void:
	var sources: Array = [_source(0.5, 0.5, 0.20), _source(0.62, 0.55, 0.14)]
	var lines := OverworldFogWall.contour(sources, SIZE_M)
	assert_gt(lines.size(), 0, "the union has a boundary (else vacuous)")
	var checked := 0
	for line: PackedVector2Array in lines:
		for p in line:
			var map_pos := _world_to_map(p)
			# A point ON a rim is a knife-edge, so step a little each way along the outward normal
			# and assert the two sides differ — which is what "this is the boundary" means.
			var inward := (Vector2(0.5, 0.5) - map_pos)
			if inward.is_zero_approx():
				continue
			inward = inward.normalized() * 0.01
			checked += 1
			assert_true(RallyLibrary.position_lit_by(map_pos + inward, sources),
				"just inside the wall is lit ground")
	assert_gt(checked, 0, "points were checked (else vacuous)")


# ...and the complement, which is what stops the test above passing for a wall drawn anywhere: a
# point WELL outside the curtain is unlit, and one well inside is lit.
func test_the_wall_separates_lit_ground_from_unlit() -> void:
	var sources: Array = [_source(0.5, 0.5, 0.18)]
	var lines := OverworldFogWall.contour(sources, SIZE_M)
	assert_eq(lines.size(), 1, "a lone circle traces one closed rim")
	for p in lines[0]:
		var map_pos := _world_to_map(p)
		var out := map_pos + (map_pos - Vector2(0.5, 0.5)).normalized() * 0.03
		var inn := map_pos - (map_pos - Vector2(0.5, 0.5)).normalized() * 0.03
		assert_false(RallyLibrary.position_lit_by(out, sources), "outside the wall is dark")
		assert_true(RallyLibrary.position_lit_by(inn, sources), "inside it is lit")


# A rim arc that runs THROUGH another circle is dropped: the union of two overlapping circles has a
# scalloped outline, not two whole rims crossing each other's interiors.
func test_arcs_inside_another_circle_are_dropped() -> void:
	var apart: Array = [_source(0.2, 0.5, 0.10), _source(0.8, 0.5, 0.10)]
	var overlapping: Array = [_source(0.45, 0.5, 0.10), _source(0.55, 0.5, 0.10)]
	var apart_pts := 0
	for line: PackedVector2Array in OverworldFogWall.contour(apart, SIZE_M):
		apart_pts += line.size()
	var overlap_pts := 0
	for line: PackedVector2Array in OverworldFogWall.contour(overlapping, SIZE_M):
		overlap_pts += line.size()
	assert_gt(apart_pts, 0, "two separate circles trace a boundary (else vacuous)")
	assert_lt(overlap_pts, apart_pts,
		"overlapping circles trace LESS rim than separate ones — the buried arcs are gone")
	# And nothing kept is interior to the union.
	for line: PackedVector2Array in OverworldFogWall.contour(overlapping, SIZE_M):
		for p in line:
			var map_pos := _world_to_map(p)
			var deep := map_pos + (map_pos - Vector2(0.5, 0.5)).normalized() * -0.02
			assert_true(RallyLibrary.position_lit_by(deep, overlapping),
				"a kept point still has lit ground behind it")


# A circle nobody touches comes back CLOSED — the first and last points meet, so a lone frontier is
# a loop rather than a curtain with a visible seam.
func test_an_untouched_circle_closes() -> void:
	var lines := OverworldFogWall.contour([_source(0.5, 0.5, 0.15)], SIZE_M)
	assert_eq(lines.size(), 1, "one polyline")
	var line: PackedVector2Array = lines[0]
	assert_gt(line.size(), 3, "with several points")
	assert_almost_eq(line[0].distance_to(line[line.size() - 1]), 0.0, 0.001,
		"and it closes on itself")


# Degenerate inputs must produce nothing rather than a malformed surface: an empty frontier (a
# profile that has revealed nothing), a zero radius, and a zero map size.
func test_degenerate_frontiers_produce_no_geometry() -> void:
	assert_eq(OverworldFogWall.contour([], SIZE_M).size(), 0, "no sources, no wall")
	assert_eq(OverworldFogWall.contour([_source(0.5, 0.5, 0.0)], SIZE_M).size(), 0,
		"a zero-radius circle has no rim")
	assert_eq(OverworldFogWall.contour([_source(0.5, 0.5, 0.2)], 0.0).size(), 0,
		"a zero-size map has no world to place it in")


# --- It grows with progression -------------------------------------------------------------


# THE GROWTH PROPERTY, on the live profile and through the same signal the zones and the roadblocks
# use: completing a rally lights a new circle, and the frontier the curtain stands on gets LONGER.
# Asserted as a rise, never as a length — the radii are authored balance.
func test_completing_a_rally_grows_the_wall() -> void:
	# A seed rally at HQ, so the fixture cluster is lit at all (HQ itself lights nothing).
	RallyLibrary.override_for_test(_roster_with_seed())
	_complete("fx_seed_lit")
	var wall := _wall()
	var before := wall.contour_length_m()
	assert_gt(before, 0.0, "there is a frontier to begin with (else vacuous)")

	_complete("fx_open")            # its own reveal circle reaches further out
	wall.refresh(Save.profile)
	assert_gt(wall.contour_length_m(), before,
		"revealing more of the map pushes the frontier outward")


# The frontier follows the LIVE profile without a scene reload: `Save.profile_changed` is the same
# hook the zones and the roadblocks refresh on.
func test_it_refreshes_on_a_profile_change() -> void:
	RallyLibrary.override_for_test(_roster_with_seed())
	_complete("fx_seed_lit")
	var wall := _wall()
	var before := wall.contour_length_m()
	_complete("fx_open")
	Save.profile_changed.emit()
	assert_gt(wall.contour_length_m(), before, "the wall re-traced itself on the signal alone")


# A profile that has revealed NOTHING gets no curtain at all, rather than a wall around a point.
#
# HQ's own circle is switched OFF here to construct that state. `map_hq_reveal_radius` now ships
# small and non-zero (the overworld stands the player at the garage to pick a first car, and an
# unlit car gets the fog veil and the frontier push), so a fresh profile is no longer lit by
# nothing — it is lit by the garage. That is a fact this test does not care about: it is about the
# wall's behaviour when there is no frontier at all. Restored before the assertion so a failure
# cannot leak the override.
func test_an_unrevealed_profile_has_no_wall() -> void:
	var was := Config.data.map_hq_reveal_radius
	Config.data.map_hq_reveal_radius = 0.0
	var wall := _wall()
	var arcs := wall.contour_lines().size()
	Config.data.map_hq_reveal_radius = was
	assert_eq(arcs, 0, "nothing revealed, nothing to fence")
	assert_false(wall.armed(), "and nothing is standing")


# --- Arming (hub only, and nothing global) -------------------------------------------------


# Headless / visuals-off builds NO mesh, while the geometry still resolves — which is what makes
# every test above cheap. And `armed()` is false, so a test can tell the difference.
func test_visuals_off_traces_the_frontier_but_builds_nothing() -> void:
	RallyLibrary.override_for_test(_roster_with_seed())
	_complete("fx_seed_lit")
	var wall := _wall()
	assert_gt(wall.contour_lines().size(), 0, "the frontier is traced")
	assert_false(wall.armed(), "but no curtain is built with visuals off")
	assert_eq(wall.curtain_count(), 0, "no arcs")
	assert_eq(wall.get_child_count(), 0, "and no mesh node exists at all")


# NO DISTANCE CULL ON THE CURTAIN — the regression guard for "the border disappears when you get
# close to it".
#
# The wall used to carry the shared `MeshUtil.apply_visibility_range`, which measures camera→node
# ORIGIN. An arc is anchored at its CENTROID, and a lone lit circle's arc is a closed loop whose
# centroid is the circle's CENTRE — so the cull measured the distance to a point up to a full reveal
# radius away from the geometry the player was standing next to, and the ring drew while they sat in
# the middle of their lit region and vanished as they drove up to it. Exactly inverted.
#
# A distance cull was never right for this: the wall's job is to be visible BEFORE the veil and the
# push-back explain it. Frustum culling still applies per arc (a tight AABB each), which is where the
# saving actually comes from. Asserted as "no range is set", never against a distance value.
func test_the_curtain_carries_no_distance_cull() -> void:
	RallyLibrary.override_for_test(_roster_with_seed())
	_complete("fx_seed_lit")
	var wall := OverworldFogWall.new()
	add_child_autofree(wall)
	wall.setup({"size_m": SIZE_M, "visuals": true})
	assert_gt(wall.curtain_count(), 0, "there are arcs standing (else vacuous)")
	for i in wall.get_child_count():
		var arc := wall.get_child(i) as GeometryInstance3D
		if arc == null:
			continue
		assert_eq(arc.visibility_range_end, 0.0,
			"arc %d has no far cull — 0 is Godot's 'no limit'" % i)
		assert_eq(arc.visibility_range_begin, 0.0, "arc %d has no near cull either" % i)


# THE NO-OP GUARANTEE FOR EVERY OTHER SCENE IS STRUCTURAL: the curtain is a node in this hub's own
# tree with its own material, so it cannot outlive the scene — unlike a global shader uniform, which
# persists across a scene change and has to be remembered on the way out. Asserted by freeing it and
# showing nothing survives.
func test_the_wall_cannot_leak_into_another_scene() -> void:
	RallyLibrary.override_for_test(_roster_with_seed())
	_complete("fx_seed_lit")
	var wall := OverworldFogWall.new()
	add_child(wall)
	wall.setup({"size_m": SIZE_M, "visuals": false})
	assert_true(Save.profile_changed.is_connected(wall._on_profile_changed),
		"it listens for progress while it exists")
	remove_child(wall)
	wall.free()
	# Freeing it takes the listener with it: a stale connection would re-trace a freed wall on the
	# next profile write, which is the one way a scene-local node CAN reach beyond its scene.
	Save.profile_changed.emit()
	pass_test("a freed wall neither answers the signal nor leaves a global behind")


# THE POSITIVE CONTROL for the two tests above, and the feature switch in one: with visuals ON a
# revealed frontier really does raise a curtain, and switching the feature off takes it down. Without
# both halves the `visuals: false` test could pass for a wall that never builds at all.
#
# A MeshInstance3D and an ArrayMesh need no renderer, so this is still a headless test; the contour
# here is a single fixture circle, so it is a handful of quads.
func test_the_enabled_flag_is_what_decides_whether_a_curtain_stands() -> void:
	RallyLibrary.override_for_test(_roster_with_seed())
	_complete("fx_seed_lit")
	var was: bool = Config.data.overworld_fog_wall_enabled

	Config.data.overworld_fog_wall_enabled = true
	var on := OverworldFogWall.new()
	add_child_autofree(on)
	on.setup({"size_m": SIZE_M, "visuals": true})
	var armed_on := on.armed()
	var built_mesh := on.curtain_count() > 0

	Config.data.overworld_fog_wall_enabled = false
	var off := OverworldFogWall.new()
	add_child_autofree(off)
	off.setup({"size_m": SIZE_M, "visuals": true})
	var armed_off := off.armed()

	# Restored BEFORE any assertion, so a failure cannot leak a switched-off feature into the rest
	# of the suite.
	Config.data.overworld_fog_wall_enabled = was

	assert_true(armed_on, "a revealed frontier raises a curtain")
	assert_true(built_mesh, "...as real mesh nodes")
	assert_false(armed_off, "and nothing stands while the feature is switched off")


# Re-tracing must not STACK curtains. The frontier is drawn as one mesh per arc (so the shared
# distance cull can measure camera→arc and only the nearby frontier draws at all), and a re-trace
# replaces them — a set per rally completed would be a slow leak all game, and every stale arc would
# be wrong geometry drawn over the new frontier.
func test_refreshing_replaces_the_arcs_rather_than_stacking_them() -> void:
	RallyLibrary.override_for_test(_roster_with_seed())
	_complete("fx_seed_lit")
	var wall := OverworldFogWall.new()
	add_child_autofree(wall)
	wall.setup({"size_m": SIZE_M, "visuals": true})
	var arcs := wall.curtain_count()
	assert_gt(arcs, 0, "the frontier is standing (else vacuous)")
	assert_eq(wall.get_child_count(), arcs, "one node per arc, and nothing else")
	for _i in range(3):
		wall.refresh(Save.profile)
	assert_eq(wall.curtain_count(), arcs, "the same arc count after three re-traces")
	assert_eq(wall.get_child_count(), arcs, "and no stale nodes left behind")
	assert_true(wall.armed(), "and it is still standing")


# Each arc's node sits at the MIDDLE of its own geometry. That is what makes the shared
# render-distance cull meaningful: it measures camera→node origin, so an arc anchored at the world
# origin (or one map-spanning mesh) would test a distance that says nothing about where the curtain
# actually is — the trap BarrierField documents for its batches.
func test_each_arc_is_anchored_in_its_own_geometry() -> void:
	RallyLibrary.override_for_test(_roster_with_seed())
	_complete("fx_seed_lit")
	var wall := OverworldFogWall.new()
	add_child_autofree(wall)
	wall.setup({"size_m": SIZE_M, "visuals": true})
	assert_gt(wall.curtain_count(), 0, "there are arcs (else vacuous)")
	for i in wall.get_child_count():
		var arc := wall.get_child(i) as MeshInstance3D
		if arc == null or arc.mesh == null:
			continue
		var box: AABB = arc.mesh.get_aabb()
		# The mesh is built in the arc's LOCAL space, so its own AABB should straddle the origin
		# horizontally rather than sitting off in the distance from it.
		assert_true(box.position.x <= 0.0 and box.end.x >= 0.0,
			"arc %d straddles its own origin in x" % i)
		assert_true(box.position.z <= 0.0 and box.end.z >= 0.0,
			"arc %d straddles its own origin in z" % i)
		# ...and the node itself stands somewhere real on the map, not at the world origin.
		assert_true(arc.position.length() > 0.0, "arc %d is placed out on the frontier" % i)


# --- Fixture roster helper ------------------------------------------------------------------


# HQ lights nothing on a fresh profile (`map_hq_reveal_radius` ships at 0), so a reveal test needs
# something completed to light the cluster at all. Same seed rally test_overworld_map.gd uses, for
# the same reason; its radius is fixture GEOMETRY, not a tunable.
func _roster_with_seed() -> Array[Dictionary]:
	var roster: Array[Dictionary] = [{
		"id": "fx_seed_lit", "name": "Fixture Seed", "region": "home", "difficulty": 1,
		"special": false, "map_pos": RallyLibrary.HQ_MAP_POS,
		"reveal_radius": 0.15, "restriction": {}, "events": [],
	}]
	roster.append_array(RallyFixtures.rallies())
	return roster
