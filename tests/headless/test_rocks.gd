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
var _rock_sink: float


func before_each() -> void:
	_cfg = Config.data
	_rock_height = _cfg.rock_height_m
	_rock_sink = _cfg.rock_sink_frac


func after_each() -> void:
	# Config.data is a shared autoload resource — put back anything a test moved, or
	# the next test file inherits it.
	_cfg.rock_height_m = _rock_height
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


# The look whitelist is what actually lets a region's density through — a key
# missing from LOOK_KEYS is silently dropped by look_of, so the region would render
# with the default density and nobody would see an error.
func test_rock_density_survives_the_look_whitelist() -> void:
	assert_true(RegionLibrary.LOOK_KEYS.has("rock_density"),
		"rock_density must be whitelisted or look_of() drops it")


class _FlatGround:
	func height_at(_x: float, _z: float) -> float:
		return 0.0


# Spawn one rock field on flat ground under an autofreed host.
func _spawn(points: PackedVector2Array, index := 0, with_collision := true) -> TreeMeshField:
	var host := Node3D.new()
	add_child_autofree(host)
	return Foliage.spawn_rocks(host, points, _FlatGround.new(), index, with_collision,
		120.0, 15.0)


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


# --- Deep snow buries props ----------------------------------------------------

# A deep-snow ground is raised in the terrain VERTEX SHADER only. Props stay seated on the
# collision height underneath, so they read as buried in the snow (Felix's call, 2026-10-30).
func test_deep_snow_does_not_lift_props() -> void:
	var depth_before := _cfg.deep_snow_depth_m
	_cfg.deep_snow_depth_m = 0.0
	var flat_y: float = _spawn(PackedVector2Array([Vector2(6.0, 6.0)])).instance_positions[0].y
	_cfg.deep_snow_depth_m = 0.4
	var snow_y: float = _spawn(PackedVector2Array([Vector2(6.0, 6.0)])).instance_positions[0].y
	_cfg.deep_snow_depth_m = depth_before
	assert_almost_eq(snow_y, flat_y, 0.0001, "props sit at the same height with or without deep snow")
