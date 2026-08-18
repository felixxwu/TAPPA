extends GutTest
# The overworld's ROADBLOCKS (`scripts/overworld_blocks.gd`): the concrete barriers standing
# across a road whose far end is still dark, so the world says what the map says. See
# features/overworld.md → "Roadblocks".
#
# Scene-free: the road network is a pure object, the ground is an injected flat sampler, and
# the barrier runs are built as MultiMesh + StaticBody under a bare Node3D. Nothing needs a
# terrain, a car or a viewport.
#
# NOTHING here pins a tunable. The barrier module length, the render distance, the road width
# and every reveal radius on the shipped roster are values a designer retunes freely, so the
# roster is synthetic (`RallyFixtures`) and every threshold is READ from the subject (the
# network's own `width_m()`, the run's own module poses). What IS load-bearing is the fixture
# geometry: a lit seed at HQ opens the cluster, fx_gated sits outside it, and fx_open's wide
# reveal circle reaches fx_gated — so exactly one road leads into the dark, and completing
# fx_open opens it. Every test guards against passing vacuously if a pin moves.

const SaveTestHelpers = preload("res://tests/headless/save_test_helpers.gd")
const TEST_PATH := "user://test_overworld_blocks.json"

# Map->world scale for this file, arbitrary and local (overworld.gd owns the real one).
const SIZE_M := 1000.0

# The lit seed, exactly as test_overworld_map.gd uses one: HQ itself lights nothing
# (`map_hq_reveal_radius` ships at 0.0), so without a completed rally every fixture pin is dark
# and every assertion below would be vacuous. Radius chosen to reach the fixture cluster around
# the middle but NOT fx_gated at (0.50, 0.78).
const SEED_ID := "fx_seed_lit"
const SEED_REVEAL_RADIUS := 0.15


func before_each() -> void:
	RallyFixtures.install()
	SaveTestHelpers.redirect(TEST_PATH)
	var roster: Array[Dictionary] = [{
		"id": SEED_ID, "name": "Fixture Seed", "region": "home", "difficulty": 1,
		"special": false, "map_pos": RallyLibrary.HQ_MAP_POS,
		"reveal_radius": SEED_REVEAL_RADIUS, "restriction": {}, "events": [],
	}]
	roster.append_array(RallyFixtures.rallies())
	RallyLibrary.override_for_test(roster)
	_complete(SEED_ID)


func after_each() -> void:
	SaveTestHelpers.cleanup(TEST_PATH)
	RallyFixtures.restore()


# --- Helpers ------------------------------------------------------------------------------


func _complete(rally_id: String) -> void:
	var rallies: Dictionary = Save.profile[Save.KEY_RALLIES]
	rallies[rally_id] = {"completed": true, "best_placed": 1}


func _roads() -> OverworldRoads:
	var roads := OverworldRoads.new()
	roads.build(SIZE_M)
	return roads


func _blocks(roads: OverworldRoads, visuals := true) -> OverworldBlocks:
	var blocks := OverworldBlocks.new()
	add_child_autofree(blocks)
	blocks.setup({
		"roads": roads,
		"ground_at": func(_p: Vector3) -> float: return 0.0,
		"params": Config.data.barrier_render_params(),
		"visuals": visuals,
	})
	return blocks


# The edge joining two graph nodes by id, or -1 — how a test names a road without depending on
# the network's internal edge ordering.
func _edge_between(roads: OverworldRoads, id_a: String, id_b: String) -> int:
	var nodes := roads.nodes()
	var edges := roads.edges()
	for i in edges.size():
		var a := String(nodes[int(edges[i]["a"])]["id"])
		var b := String(nodes[int(edges[i]["b"])]["id"])
		if (a == id_a and b == id_b) or (a == id_b and b == id_a):
			return i
	return -1


func _lit(id: String) -> bool:
	return RallyLibrary.rally_revealed(RallyLibrary.by_id(id), Save.profile)


# --- Which roads are blocked ---------------------------------------------------------------


# THE gate: a road with one dark end is blocked, a road between two lit ends is not. Both
# halves are asserted in one test so it cannot pass by blocking nothing (or everything).
func test_only_a_road_leading_into_the_dark_is_blocked() -> void:
	var roads := _roads()
	var dark_road := _edge_between(roads, "fx_open", "fx_gated")
	assert_gt(dark_road, -1, "the fixture network has an fx_open->fx_gated road (else vacuous)")
	assert_true(_lit("fx_open"), "fx_open is lit by the seed (else vacuous)")
	assert_false(_lit("fx_gated"), "fx_gated is dark (else vacuous)")

	var blocked := _blocks(roads).blocked_edges()
	assert_true(blocked.has(dark_road), "the road into the dark is blocked")

	# ...and no road between two lit pins is. Derived from the same predicate, so it holds for
	# any roster: every blocked edge must have exactly one lit end.
	var nodes := roads.nodes()
	var open_roads := 0
	for i in roads.edges().size():
		var a: Dictionary = nodes[int(roads.edges()[i]["a"])]
		var b: Dictionary = nodes[int(roads.edges()[i]["b"])]
		var lit_a := bool(a.get("is_hq", false)) or _lit(String(a["id"]))
		var lit_b := bool(b.get("is_hq", false)) or _lit(String(b["id"]))
		if lit_a and lit_b:
			open_roads += 1
			assert_false(blocked.has(i), "the open road %s-%s is not blocked" % [a["id"], b["id"]])
		elif not lit_a and not lit_b:
			assert_false(blocked.has(i),
				"a road between two dark pins is unreachable, so it gets no barrier")
	assert_gt(open_roads, 0, "the network has open roads too (else the negative half is vacuous)")


# The garage carries no pin, so the roster predicate would call it dark forever and every road
# home would be barriered shut. It is exempt — the same exemption OverworldZone.always_revealed
# exists for.
func test_the_garage_end_never_blocks_a_road() -> void:
	var roads := _roads()
	var nodes := roads.nodes()
	var hq := roads.hq_index()
	assert_gt(hq, -1, "the network has a garage node (else vacuous)")
	var blocked := _blocks(roads).blocked_edges()
	var hq_roads := 0
	for i in roads.edges().size():
		var edge: Dictionary = roads.edges()[i]
		var other := -1
		if int(edge["a"]) == hq:
			other = int(edge["b"])
		elif int(edge["b"]) == hq:
			other = int(edge["a"])
		if other < 0 or not _lit(String(nodes[other]["id"])):
			continue
		hq_roads += 1
		assert_false(blocked.has(i), "the road between the garage and a lit pin is open")
	assert_gt(hq_roads, 0, "the garage is joined to a lit pin (else vacuous)")


# One run per blocked road, and nothing built for an open one.
func test_a_run_is_built_for_every_blocked_road() -> void:
	var roads := _roads()
	var blocks := _blocks(roads)
	assert_eq(blocks.run_count(), blocks.blocked_edges().size(),
		"there is exactly one run per blocked road")
	assert_gt(blocks.run_count(), 0, "and at least one road is blocked (else vacuous)")


# --- Where the run stands ------------------------------------------------------------------


# The run stands ON the carriageway (not out in a field) and on LIT ground, so the player can
# actually see it before the fog pushes him back. Placed at the frontier crossing, which is
# what makes the barrier and `Overworld._update_fog_boundary` read as one mechanism.
func test_the_run_stands_on_lit_road() -> void:
	var roads := _roads()
	var blocked := _blocks(roads).blocked_edges()
	assert_gt(blocked.size(), 0, "something is blocked (else vacuous)")
	for edge: int in blocked:
		var pos: Vector2 = (blocked[edge] as Dictionary)["pos"]
		assert_lt(roads.distance_to_road_m(pos.x, pos.y), roads.width_m(),
			"the run for edge %d sits on the road" % edge)
		var map_pos := Overworld.map_pos_of(Vector3(pos.x, 0.0, pos.y), SIZE_M)
		assert_true(RallyLibrary.position_revealed(map_pos, Save.profile),
			"the run for edge %d stands on ground the player can see" % edge)


# The run is laid ACROSS the road, spans the full carriageway, and its driver-facing side looks
# back at the approaching car. This is the whole readability claim, expressed as geometry:
#
#   * every module's length axis (local +Z) is perpendicular to the road tangent;
#   * its front face (local +X, BarrierSection's frame) points AGAINST the tangent, i.e. back
#     down the road the player is arriving along;
#   * end to end the run is at least as wide as the road.
func test_the_run_crosses_the_carriageway_facing_the_driver() -> void:
	var roads := _roads()
	var blocks := _blocks(roads)
	var edge := _edge_between(roads, "fx_open", "fx_gated")
	var plan: Dictionary = blocks.blocked_edges()[edge]
	var tangent: Vector2 = plan["tangent"]
	var field := blocks.run_for(edge) as BarrierField
	assert_not_null(field, "the blocked road has a built run")
	assert_gt(field.barrier_count, 1, "a run is several modules wide (else the span is vacuous)")

	var flat_tangent := Vector3(tangent.x, 0.0, tangent.y)
	var lo := INF
	var hi := -INF
	for xform: Transform3D in field.module_transforms:
		var length_axis: Vector3 = xform.basis.z.normalized()
		assert_almost_eq(length_axis.dot(flat_tangent), 0.0, 0.01,
			"the module's length axis crosses the road")
		assert_lt(xform.basis.x.normalized().dot(flat_tangent), 0.0,
			"the module's face looks back down the road at the driver")
		var along := Vector2(xform.origin.x, xform.origin.z).dot(Vector2(-tangent.y, tangent.x))
		lo = minf(lo, along)
		hi = maxf(hi, along)
	assert_gte(hi - lo, roads.width_m() * 0.5,
		"the run reaches across a meaningful share of the carriageway")


# THE REGRESSION THAT SHIPPED: every barrier stood UPSIDE DOWN and therefore entirely below the
# road. `BarrierSection`'s model occupies +Y only (its AABB starts at y = 0 and rises), so a basis
# whose Y column comes out pointing DOWN — which is what picking the +X and +Z axes independently
# produced — buries the whole block. Asserted as the frame contract, module by module: Y is world
# up, the basis is right-handed, and the model's own base corner sits AT the sampled ground.
func test_every_module_stands_upright_on_the_ground() -> void:
	var roads := _roads()
	var blocks := _blocks(roads)
	var built := 0
	for edge: int in blocks.blocked_edges():
		var field := blocks.run_for(edge) as BarrierField
		if field == null:
			continue
		var box := field.module_aabb(int(BarrierSection.Style.JERSEY),
			Config.data.barrier_render_params())
		assert_almost_eq(box.position.y, 0.0, 0.001,
			"the model stands on its own origin (else this test measures the wrong thing)")
		for xform: Transform3D in field.module_transforms:
			built += 1
			assert_almost_eq(xform.basis.y.dot(Vector3.UP), 1.0, 0.001, "the module's Y is world up")
			assert_gt(xform.basis.determinant(), 0.0, "...and the basis is right-handed")
			# The base corner is the module origin; the ground here is the injected flat sampler at
			# 0, so the base sits at 0 less the authored sink. Read from the config, never pinned.
			var base_y: float = (xform * Vector3(box.position.x, 0.0, 0.0)).y
			assert_almost_eq(base_y, -Config.data.barrier_sink_m, 0.001,
				"the module's foot rests on the ground, not under it")
			# ...and the model rises ABOVE that, which is the actual symptom the player reported.
			assert_gt((xform * Vector3(0.0, box.size.y, 0.0)).y, base_y,
				"the block is above the ground, not hanging below it")
	assert_gt(built, 0, "some modules were built (else vacuous)")


# ONE HEIGHT PER RUN, TAKEN ON THE CENTRELINE. The carve levels the carriageway across its width
# to the height at the perpendicular foot, so every module in a run belongs at the CENTRELINE
# height; sampling each module at its own offset would ask for the cross-slope the carve replaced
# and tilt the run into the road. Proven on deliberately sloping ground, where a per-module sample
# and a per-run sample give visibly different answers.
func test_a_run_is_level_at_the_centreline_height_even_on_a_slope() -> void:
	var roads := _roads()
	var slope := 0.08
	var blocks := OverworldBlocks.new()
	add_child_autofree(blocks)
	blocks.setup({
		"roads": roads,
		"ground_at": func(p: Vector3) -> float: return slope * p.x,
		"params": Config.data.barrier_render_params(),
		"visuals": true,
	})
	var edge := _edge_between(roads, "fx_open", "fx_gated")
	var plan: Dictionary = blocks.blocked_edges()[edge]
	var centre: Vector2 = plan["pos"]
	var field := blocks.run_for(edge) as BarrierField
	assert_not_null(field, "the blocked road has a run")
	assert_gt(field.module_transforms.size(), 1, "more than one module (else levelness is vacuous)")
	var expected := slope * centre.x - Config.data.barrier_sink_m
	var spread := 0.0
	for xform: Transform3D in field.module_transforms:
		assert_almost_eq(xform.origin.y, expected, 0.001,
			"every module sits at the centreline ground height")
		spread = maxf(spread, absf(xform.origin.y - expected))
	# The guard against the test proving nothing: a per-module sample WOULD have differed here.
	var half_span := roads.width_m() * 0.5
	assert_gt(slope * half_span, 0.05,
		"the slope is steep enough across the run that a per-module sample would differ")
	assert_lt(spread, 0.001, "the run is level, not stepped")


# --- Reveal takes it away ------------------------------------------------------------------


# The load-bearing lifecycle claim: when the rally at the far end lights, the barrier GOES —
# in the same session, with no scene reload. The run node is freed, not just hidden.
func test_a_revealed_rally_opens_its_road_and_frees_the_run() -> void:
	var roads := _roads()
	var blocks := _blocks(roads)
	var edge := _edge_between(roads, "fx_open", "fx_gated")
	var field := blocks.run_for(edge)
	assert_not_null(field, "the road into the dark starts blocked (else vacuous)")
	var before := blocks.run_count()

	_complete("fx_open")                    # fx_open's reveal circle reaches fx_gated
	blocks.refresh(Save.profile)
	assert_true(_lit("fx_gated"), "completing fx_open lights fx_gated")
	assert_false(blocks.blocked_edges().has(edge), "so its road is no longer blocked")
	assert_null(blocks.run_for(edge), "and the run is gone")
	assert_lt(blocks.run_count(), before, "one fewer run stands than before")
	await get_tree().process_frame
	assert_false(is_instance_valid(field), "the run node was freed, not merely detached")


# Refreshing with nothing changed must not churn: an untouched road keeps the run it already
# has, rather than freeing and rebuilding every barrier on every progress write.
func test_an_unchanged_road_keeps_its_existing_run() -> void:
	var roads := _roads()
	var blocks := _blocks(roads)
	var edge := _edge_between(roads, "fx_open", "fx_gated")
	var field := blocks.run_for(edge)
	blocks.refresh(Save.profile)
	assert_same(blocks.run_for(edge), field, "the same run node survives a no-op refresh")


# Headless / no-visuals: the plan is still resolved (so a test or a tool can ask which roads are
# closed) but nothing is built.
func test_no_nodes_are_built_with_visuals_off() -> void:
	var roads := _roads()
	var blocks := _blocks(roads, false)
	assert_gt(blocks.blocked_edges().size(), 0, "the plan still resolves")
	assert_eq(blocks.get_child_count(), 0, "and no barrier nodes exist")
