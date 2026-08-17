extends GutTest
# Roadside rocks (features/rocks.md): the mesh merge, the sizing, the region density
# multiplier and the collision hitbox.
#
# Nothing here pins an authored value. No test asserts which models ship, how tall a
# rock is, what colour it is, or which region is stoniest — all of that is content a
# designer retunes in GameConfig / RegionLibrary. What IS asserted is the behaviour
# that has to hold for ANY reasonable authoring: the merge collapses to one surface,
# the colours survive as vertex data, the shader is the unshaded fake-sun one, sizes
# track the config knob, and collision appears only when asked for.

var _cfg: GameConfig
var _rock_height: float
var _rocks_per_turn: float
var _rock_sink: float


func before_each() -> void:
	_cfg = Config.data
	_rock_height = _cfg.rock_height_m
	_rocks_per_turn = _cfg.rock_groups_per_turn
	_rock_sink = _cfg.rock_sink_frac


func after_each() -> void:
	# Config.data is a shared autoload resource — put back anything a test moved, or
	# the next test file inherits it.
	_cfg.rock_height_m = _rock_height
	_cfg.rock_groups_per_turn = _rocks_per_turn
	_cfg.rock_sink_frac = _rock_sink


# The whole point of the merge: Kenney ships each rock as 2-3 primitives, and a
# MultiMesh draws every surface separately, so leaving them split would cost 2-3 draw
# calls per bin for a sub-150-triangle rock.
func test_every_rock_merges_to_a_single_surface() -> void:
	for i in range(Foliage.ROCK_SCENES.size()):
		var mesh := Foliage.rock_mesh(i)
		assert_eq(mesh.get_surface_count(), 1,
			"rock %d should merge to one surface, so one draw call per bin" % i)


# The merge moves each source primitive's material colour into vertex colours, because
# that is the only channel the shared shader reads (`* COLOR.rgb`). No colours means an
# untinted white rock, which would look like a bug rather than fail like one.
func test_merged_rocks_carry_vertex_colours() -> void:
	for i in range(Foliage.ROCK_SCENES.size()):
		var arrays := Foliage.rock_mesh(i).surface_get_arrays(0)
		var colours: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		assert_gt(verts.size(), 0, "rock %d merged to an empty mesh" % i)
		assert_eq(colours.size(), verts.size(),
			"rock %d must carry one vertex colour per vertex" % i)


# Rocks must be lit the same way the rest of the world is: unshaded (this renderer has
# no light nodes at all) with the fake sun done in-shader. Asserting the shader and the
# render mode rather than any colour keeps this true through retuning.
func test_rocks_use_the_unshaded_fake_sun_shader() -> void:
	for i in range(Foliage.ROCK_SCENES.size()):
		var mat := Foliage.rock_mesh(i).surface_get_material(0) as ShaderMaterial
		assert_not_null(mat, "rock %d has no ShaderMaterial" % i)
		if mat == null:
			continue
		assert_eq(mat.shader, Foliage.ROCK_SHADER,
			"rock %d should share the fake-sun model shader" % i)
		assert_true(mat.shader.code.contains("unshaded"),
			"the rock shader must stay unshaded — there are no light nodes in this game")
		# The sun direction has to actually reach the material, or every rock is flat.
		assert_ne(mat.get_shader_parameter("light_dir"), null,
			"rock %d never received a sun direction" % i)


# rock_height_m is THE size knob; each species scales off it. Tests the relationship,
# not the number — doubling the knob doubles every species.
func test_rock_height_scales_with_the_config_knob() -> void:
	var before: Array = []
	for i in range(Foliage.ROCK_SCENES.size()):
		before.append(Foliage.rock_height(i))
	_cfg.rock_height_m = _rock_height * 2.0
	for i in range(Foliage.ROCK_SCENES.size()):
		assert_almost_eq(Foliage.rock_height(i), float(before[i]) * 2.0, 0.001,
			"rock %d should scale with rock_height_m" % i)


# Every species must come out with real world size — a zero-height or zero-footprint
# rock is invisible and un-hittable. A sanity guard, not a pinned size.
func test_every_rock_has_usable_world_size() -> void:
	for i in range(Foliage.ROCK_SCENES.size()):
		var height := Foliage.rock_height(i)
		assert_gt(height, 0.0, "rock %d has no height" % i)
		assert_gt(TreeMeshField.xz_radius(Foliage.rock_mesh(i), height), 0.0,
			"rock %d has no footprint" % i)


# --- Region density ---------------------------------------------------------------

# A region that authors nothing gets the unremarkable middle, so adding a region never
# silently removes its rocks.
func test_rock_density_defaults_to_the_middle() -> void:
	assert_eq(RegionLibrary.rock_density({}), 1.0)


func test_rock_density_reads_the_authored_value() -> void:
	assert_almost_eq(RegionLibrary.rock_density({"rock_density": 2.5}), 2.5, 0.001)


# 0.0 is a legitimate "no rocks here"; negative is not, and would otherwise flip the
# scatter's cell maths into nonsense.
func test_rock_density_clamps_negative_to_zero() -> void:
	assert_eq(RegionLibrary.rock_density({"rock_density": -3.0}), 0.0)


# The look whitelist is what actually lets a region's density reach world.gd — a key
# missing from LOOK_KEYS is silently dropped by look_of, so the region would render
# with the default density and nobody would see an error.
func test_rock_density_survives_the_look_whitelist() -> void:
	assert_true(RegionLibrary.LOOK_KEYS.has("rock_density"),
		"rock_density must be whitelisted or look_of() drops it")


# Density multiplies the base count. Again a relationship, not a number.
func test_rock_params_scale_the_count_by_density() -> void:
	_cfg.rock_groups_per_turn = 8.0
	assert_almost_eq(float(_cfg.rock_params(1.0)["points_per_turn"]), 8.0, 0.001)
	assert_almost_eq(float(_cfg.rock_params(0.5)["points_per_turn"]), 4.0, 0.001)
	assert_almost_eq(float(_cfg.rock_params(0.0)["points_per_turn"]), 0.0, 0.001)


# Rocks are deliberately NOT on the tree params: trees are dense scenery, rocks are
# sparse obstacles, and turning the forest up must not turn the hazard field up too.
func test_rock_scatter_is_independent_of_the_tree_count() -> void:
	_cfg.rock_groups_per_turn = 5.0
	var before: float = float(_cfg.rock_params(1.0)["points_per_turn"])
	var trees_before := _cfg.trees_per_turn
	_cfg.trees_per_turn = trees_before + 50.0
	assert_almost_eq(float(_cfg.rock_params(1.0)["points_per_turn"]), before, 0.001,
		"raising trees_per_turn must not add rocks")
	_cfg.trees_per_turn = trees_before



# --- Grouping ---------------------------------------------------------------------

# Rocks scatter as clusters, not individuals: each scatter point is a GROUP ANCHOR that
# fans out into several boulders. Asserts the contract (every anchor yields at least
# min and at most max, anchor included) for ANY authored group size.
func test_cluster_expands_every_anchor_into_a_group() -> void:
	var anchors := PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(80.0, 12.0), Vector2(-40.0, 55.0),
	])
	for lo in [2, 3]:
		for hi in [4, 6]:
			var out := TreeScatter.cluster(anchors, lo, hi, 6.0, 99)
			assert_gte(out.size(), anchors.size() * lo,
				"every anchor must yield at least the minimum group size")
			assert_lte(out.size(), anchors.size() * hi,
				"no anchor may exceed the maximum group size")


# The anchor itself stays a rock, so a group is the anchor plus companions — otherwise
# the scatter's careful road/lake rejection of that exact point would be wasted.
func test_cluster_keeps_the_anchor_position() -> void:
	var anchor := Vector2(21.0, -7.0)
	var out := TreeScatter.cluster(PackedVector2Array([anchor]), 2, 4, 5.0, 7)
	assert_true(out.has(anchor), "the anchor point should survive into the group")


# "Close proximity" is the whole point: a companion must land within the group radius
# of its anchor, or the cluster stops reading as one outcrop.
func test_cluster_members_stay_within_the_group_radius() -> void:
	var anchor := Vector2(10.0, 10.0)
	var radius := 6.0
	var out := TreeScatter.cluster(PackedVector2Array([anchor]), 4, 4, radius, 3)
	for p in out:
		assert_lte(anchor.distance_to(p), radius + 0.001,
			"a group member escaped its cluster radius")


# Companions sit on a jittered RING, not a uniform disc, specifically so metre-wide
# boulders don't land on top of each other. Assert they are actually separated from the
# anchor rather than stacked on it.
func test_cluster_companions_do_not_stack_on_the_anchor() -> void:
	var anchor := Vector2(-3.0, 14.0)
	var out := TreeScatter.cluster(PackedVector2Array([anchor]), 4, 4, 8.0, 11)
	var away := 0
	for p in out:
		if anchor.distance_to(p) > 0.001:
			away += 1
	assert_eq(away, out.size() - 1,
		"every companion should be offset from the anchor, leaving only the anchor itself")


# Same seed, same clusters — the scatter is a pure hash, and world generation is
# reproducible from cfg.track_seed.
func test_cluster_is_deterministic_for_a_seed() -> void:
	var anchors := PackedVector2Array([Vector2(4.0, 9.0), Vector2(-22.0, 3.0)])
	var a := TreeScatter.cluster(anchors, 2, 4, 6.0, 1234)
	var b := TreeScatter.cluster(anchors, 2, 4, 6.0, 1234)
	assert_eq(a, b, "the same seed must produce the same clusters")


# An inverted min/max is an authoring slip, not a reason to produce nothing.
func test_cluster_survives_an_inverted_group_range() -> void:
	var out := TreeScatter.cluster(PackedVector2Array([Vector2.ZERO]), 4, 2, 5.0, 5)
	assert_eq(out.size(), 4, "max below min should degrade to a fixed group size")


func test_cluster_of_nothing_is_nothing() -> void:
	assert_eq(TreeScatter.cluster(PackedVector2Array(), 2, 4, 6.0, 1).size(), 0)


# Spawn one rock field on a flat terrain under an autofreed host. The terrain is freed
# here rather than in each test, so a test can never leak one by forgetting.
func _spawn(points: PackedVector2Array, index := 0, with_collision := true) -> TreeMeshField:
	var host := Node3D.new()
	add_child_autofree(host)
	var terrain := TerrainManager.flat()
	var field := Foliage.spawn_rocks(host, points, terrain, index, with_collision,
		120.0, 15.0)
	terrain.free()
	return field


# --- Collision --------------------------------------------------------------------

# The thing that makes a rock a rock rather than scenery: you can hit it. The field
# builds ONE StaticBody for the whole scatter (N shapes on one body), so assert the
# body exists and is in the group the damage model reads.
func test_spawned_rocks_carry_a_collision_body() -> void:
	var field := _spawn(PackedVector2Array([
		Vector2(10.0, 10.0), Vector2(20.0, 24.0), Vector2(-14.0, 6.0),
	]))
	var body := field.get_node_or_null("Collision") as StaticBody3D
	assert_not_null(body, "rocks spawned with collision should own a Collision body")
	if body != null:
		assert_true(body.is_in_group(DamageModel.OBSTACLE_GROUP),
			"the rock body must be an obstacle, or hitting it costs nothing")


# Rocks are buried by a fraction of their own height so they read as embedded in the
# ground rather than balanced on it. Asserts the RELATIONSHIP (a positive fraction sinks
# the field, zero does not), never the authored depth.
func test_sink_fraction_buries_the_rocks_and_their_hitboxes() -> void:
	var points := PackedVector2Array([Vector2(6.0, 6.0)])
	var sunk_before := _cfg.rock_sink_frac

	_cfg.rock_sink_frac = 0.0
	var flat_y: float = _spawn(points).instance_positions[0].y

	_cfg.rock_sink_frac = 0.25
	var sunk := _spawn(points)
	var sunk_y: float = sunk.instance_positions[0].y
	assert_lt(sunk_y, flat_y, "a positive sink fraction must bury the rocks")
	# Proportional to the rock, so resizing cannot leave them floating or swallowed.
	assert_almost_eq(flat_y - sunk_y, Foliage.rock_height(0) * 0.25, 0.001,
		"the sink depth should be that fraction of the rock's own height")

	# The hitbox is placed from the same buried position, so it cannot drift from the
	# mesh — this is why the sink is a build parameter rather than a node offset.
	assert_not_null(sunk.get_node_or_null("Collision"))

	_cfg.rock_sink_frac = sunk_before


# The decorative callers (and the no-collision path generally) must be able to opt out
# without the field inventing a hitbox.
func test_rocks_can_spawn_without_collision() -> void:
	var field := _spawn(PackedVector2Array([Vector2(8.0, 8.0)]), 0, false)
	assert_null(field.get_node_or_null("Collision"),
		"with_collision false must not build a body")


# An empty scatter is normal (a region can author density 0, or every point can land in
# a lake) and must not build a body or crash.
func test_empty_rock_scatter_builds_nothing() -> void:
	var field := _spawn(PackedVector2Array())
	assert_null(field.get_node_or_null("Collision"))


# --- Integration ------------------------------------------------------------------

# Everything above tests the pieces in isolation, which a silently-disconnected
# _build_rocks would still pass. This one builds the REAL world and asserts rocks
# actually reached it, with hitboxes.
#
# Built once in before_all, not per test: a full world generation is ~15 s
# (features/testing.md), and building it inside a test body also attributes every
# script-compile warning in the project to that test, which GUT counts as a failure.
var _world: Node = null


func before_all() -> void:
	Config.reset()
	var cfg: GameConfig = Config.data
	cfg.track_turn_count = 1
	cfg.trees_per_turn = 0        # trees/bushes are not what this asserts
	_world = load("res://main.tscn").instantiate()
	add_child(_world)
	# The rock fields are added during the awaited generation chain, so poll for them
	# rather than guessing a frame count.
	for _i in range(600):
		await wait_frames(1)
		if _rock_fields().size() > 0:
			break


func after_all() -> void:
	if _world != null:
		_world.free()
		_world = null
	Config.reset()


# Every rock field currently on the stage. A species whose partition drew no points is
# deliberately not spawned at all, so the set is whatever actually made it.
func _rock_fields() -> Array:
	var out: Array = []
	if _world == null:
		return out
	for i in range(Foliage.ROCK_SCENES.size()):
		var field := _world.get_node_or_null("Rocks%d" % i)
		if field != null:
			out.append(field)
	return out


func test_rocks_reach_a_generated_stage_with_collision() -> void:
	var fields := _rock_fields()
	assert_gt(fields.size(), 0,
		"no rock field reached the stage — _build_rocks is not wired into generation")
	var with_bodies := 0
	for f in fields:
		var field := f as TreeMeshField
		if field.instance_positions.size() > 0 \
				and field.get_node_or_null("Collision") != null:
			with_bodies += 1
	assert_gt(with_bodies, 0, "rock fields spawned but none carried a collision body")


# A species that draws no points must not leave an EMPTY field behind. test_smoke asserts
# every foliage field has at least one bin, so a bin-less rock field breaks an invariant
# well away from this file — assert it here too, where the cause is obvious.
func test_no_rock_field_is_empty() -> void:
	for f in _rock_fields():
		var field := f as TreeMeshField
		assert_gt(field.bin_count, 0,
			"%s was spawned with no bins — skip empty species instead" % field.name)
		assert_gt(field.instance_positions.size(), 0,
			"%s was spawned with no rocks in it" % field.name)


# The clustering is what makes rocks arrive in groups on a REAL stage, not just in the
# pure helper: with 2-4 per anchor, a stage carrying rocks at all should carry more of
# them than it has clusters. Counts rocks, asserts nothing about where they landed.
func test_a_generated_stage_carries_grouped_rocks() -> void:
	var total := 0
	for f in _rock_fields():
		total += (f as TreeMeshField).instance_positions.size()
	assert_gte(total, Config.data.rock_group_min,
		"a stage with rocks should carry at least one whole group")


# --- Deep-snow ground lift ---------------------------------------------------------

# A deep-snow stage raises the off-road ground in the terrain VERTEX SHADER, which
# TerrainManager.height_at (what every scatter seats props from) knows nothing about.
# Props must be lifted to match, or they sit buried under the snow that is drawn.
func test_deep_snow_lifts_props_onto_the_drawn_ground() -> void:
	var depth_before := _cfg.deep_snow_depth_m

	_cfg.deep_snow_depth_m = 0.0
	assert_eq(Foliage.visual_ground_lift(), 0.0,
		"a stage without deep snow must not lift anything")
	var flat_y: float = _spawn(PackedVector2Array([Vector2(6.0, 6.0)])).instance_positions[0].y

	_cfg.deep_snow_depth_m = 0.4
	assert_almost_eq(Foliage.visual_ground_lift(), 0.4, 0.0001,
		"the lift should equal the snow the shader raises the ground by")
	var snow_y: float = _spawn(PackedVector2Array([Vector2(6.0, 6.0)])).instance_positions[0].y
	assert_almost_eq(snow_y - flat_y, 0.4, 0.001,
		"props on a snow stage should rise by exactly the visual snow depth")

	_cfg.deep_snow_depth_m = depth_before


# Guards the sign. A negative authored depth would push props further UNDER the ground,
# which is the failure this whole helper exists to prevent.
func test_visual_ground_lift_never_pushes_props_down() -> void:
	var depth_before := _cfg.deep_snow_depth_m
	_cfg.deep_snow_depth_m = -1.0
	assert_eq(Foliage.visual_ground_lift(), 0.0)
	_cfg.deep_snow_depth_m = depth_before
