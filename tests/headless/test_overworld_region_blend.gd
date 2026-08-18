extends GutTest
# SPATIAL REGION BLENDING for the overworld ground (features/overworld.md -> "Region blending").
#
# The ground does not restyle when the car crosses a region line: a canonical region RANK is baked
# into every terrain vertex's UV2.y at generation time (TerrainManager._apply_region_blend), which
# the ground shader decodes two ways: COLOUR through the all-regions rank->look LUT
# (Overworld.region_look_lut), so a chunk of ANY region paints in its own tint, and the ground
# TEXTURE through the two-slot pair Overworld._push_region_pair uploads (a texture sampler cannot
# live in a uniform array). So the change arrives on the ground ahead of the car, at the fixed boundary.
#
# Every test here is SCENE-FREE and renderer-free: a bare TerrainManager (the seam
# test_overworld_terrain.gd uses) plus the two pure pieces — Overworld.RegionBlendSource and the
# static Overworld.region_pair_of.
#
# WHAT IS PINNED, and what deliberately is not. The blend WIDTH, the falloff shape and every
# region's authored look are tunables / authored content, so nothing here asserts a distance, a
# width or a named region. What must hold for ANY reasonable values is:
#   - the baked field resolves to region A's rank deep inside A, region B's deep inside B, and
#     something strictly between at the frontier, moving monotonically from one to the other
#     (DIRECTION and MONOTONICITY, never a band width);
#   - it is a pure function of position: the same coord twice is identical, and a cache round trip
#     (rehydrating stored heights) reproduces it exactly;
#   - with no region source attached the channel is never touched, so a stage chunk is unchanged —
#     the opt-in guard, exactly like the road carve's;
#   - the uploaded pair is the two STRONGEST regions, deterministically chosen;
#   - a point where THREE regions meet resolves to two, without error;
#   - the colour LUT covers EVERY region, ascends, and agrees with the baked ranks (the fix for
#     distant ground painting as the wrong region).
#
# The roster is synthetic and its region ids are invented (`fx_*`): RegionLibrary is authored
# content, and OverworldRegion reads only each rally's `region` tag and `map_pos`, so a fabricated
# roster exercises the real code without depending on a shipped region existing.

const ManagerScript := preload("res://scripts/terrain_manager.gd")

# World edge length the test's map uses. Small, so a handful of chunks covers it.
const SIZE_M := 600.0

const WEST := "fx_west"
const EAST := "fx_east"
const NORTH := "fx_north"


func after_each() -> void:
	RallyLibrary.reset()


# One synthetic pin. Only `id`, `region` and `map_pos` are read by OverworldRegion.
static func _pin(rally_id: String, region_id: String, map_pos: Vector2) -> Dictionary:
	return {
		"id": rally_id, "name": rally_id, "region": region_id, "map_pos": map_pos,
		"difficulty": 1, "special": false, "restriction": {}, "events": [],
	}


# Two regions split left/right, with the frontier down the middle of the map.
func _install_two_regions() -> void:
	var roster: Array[Dictionary] = [
		_pin("fx_w", WEST, Vector2(0.2, 0.5)),
		_pin("fx_e", EAST, Vector2(0.8, 0.5)),
	]
	RallyLibrary.override_for_test(roster)


# Three regions meeting at one point — the junction two shader slots cannot express.
func _install_three_regions() -> Vector2:
	var junction := Vector2(0.5, 0.5)
	var radius := 0.25
	var roster: Array[Dictionary] = []
	for i in 3:
		var angle := TAU * float(i) / 3.0
		var offset := Vector2(cos(angle), sin(angle)) * radius
		var region_id := [WEST, EAST, NORTH][i] as String
		roster.append(_pin("fx_%d" % i, region_id, junction + offset))
	RallyLibrary.override_for_test(roster)
	return junction


func _blend_source() -> Overworld.RegionBlendSource:
	return Overworld.RegionBlendSource.new(OverworldRegion.new(), SIZE_M)


# The world X of a normalised map X, at SIZE_M — the same conversion Overworld.world_xz does.
static func _world_x(map_x: float) -> float:
	return Overworld.world_xz(Vector2(map_x, 0.5), SIZE_M).x


# A manager in the tree with no focus node and no initial build: enough to run
# compute_chunk_data, and it never spawns a ring.
func _manager() -> TerrainManager:
	var m := Node3D.new()
	m.set_script(ManagerScript)
	m.focus_path = NodePath("")
	m.defer_initial_build = true
	m.noise_seed = 4242
	m.light_amount = 1.0
	add_child_autofree(m)
	return m as TerrainManager


static func _uv2_ys(data: Dictionary) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var uv2s: PackedVector2Array = data.get("uv2s", PackedVector2Array())
	for uv in uv2s:
		out.append(uv.y)
	return out


# --- 1. The baked field: direction and monotonicity -----------------------------------

# Deep inside a region the field IS that region's rank (the blend collapses and the ground is
# painted by one slot alone); at the frontier it sits strictly between the two. That is the whole
# claim: "region A here, region B there, and a transition at the line between them".
func test_rank_is_region_a_inside_a_region_b_inside_b_and_between_at_the_frontier() -> void:
	_install_two_regions()
	var src := _blend_source()
	var rank_west := src.rank_of(WEST)
	var rank_east := src.rank_of(EAST)
	assert_ne(rank_west, rank_east, "two regions must get separable ranks, or nothing can blend")

	var deep_west := src.region_rank_at(_world_x(0.05), 0.0)
	var deep_east := src.region_rank_at(_world_x(0.95), 0.0)
	var frontier := src.region_rank_at(_world_x(0.5), 0.0)
	assert_almost_eq(deep_west, rank_west, 0.001, "deep inside the west region: the west rank")
	assert_almost_eq(deep_east, rank_east, 0.001, "deep inside the east region: the east rank")
	assert_between(frontier, minf(rank_west, rank_east) + 0.001,
		maxf(rank_west, rank_east) - 0.001,
		"on the frontier the field is strictly between the two ranks — a blend, not a snap")


# Crossing from one region to the other the field never doubles back. Monotonicity is what makes
# the shader's inverse-lerp a well-behaved 0->1 factor; a non-monotonic field would paint the
# boundary twice.
func test_rank_moves_monotonically_from_one_region_to_the_other() -> void:
	_install_two_regions()
	var src := _blend_source()
	# Direction-agnostic: measure progress from the west rank towards the east rank, so the test
	# holds whichever way the (alphabetical) rank assignment happens to fall.
	var rank_west := src.rank_of(WEST)
	var span := src.rank_of(EAST) - rank_west
	var previous := -1.0
	for step in 21:
		var map_x := 0.05 + 0.9 * float(step) / 20.0
		var t := (src.region_rank_at(_world_x(map_x), 0.0) - rank_west) / span
		assert_between(t, -0.001, 1.001, "the field never leaves the two regions' ranks")
		assert_true(t >= previous - 0.001,
			"the field never doubles back on the way across (step %d)" % step)
		previous = t
	assert_almost_eq(previous, 1.0, 0.001, "the far end has fully arrived in the second region")


# --- 2. Purity: the same position always bakes the same number -------------------------

func test_baked_channel_is_a_pure_function_of_position() -> void:
	_install_two_regions()
	var m := _manager()
	m.set_region_source(_blend_source())
	var coord := Vector2i(1, 0)
	var first := _uv2_ys(m.compute_chunk_data(coord))
	var second := _uv2_ys(m.compute_chunk_data(coord))
	assert_false(first.is_empty(), "the chunk has vertices to bake into")
	assert_eq(first, second, "the same coord computed twice bakes an identical channel")


# A chunk that comes BACK from the store (heights only) must re-derive the same channel, or the
# ground would change look depending on whether the chunk was generated or rehydrated.
func test_baked_channel_survives_a_cache_round_trip() -> void:
	_install_two_regions()
	var m := _manager()
	m.set_region_source(_blend_source())
	var coord := Vector2i(-1, 2)
	var generated := m.compute_chunk_data(coord)
	var rehydrated := m._rehydrate_chunk_data(
		coord, generated["heights"], generated.get("lights", PackedColorArray()))
	assert_eq(_uv2_ys(rehydrated), _uv2_ys(generated),
		"a rehydrated chunk carries the same region field as the generated one")


# THE READ FAST PATH. A store may keep the three DERIVED channels (COLOR.a, UV2.x, UV2.y)
# alongside the heights, which lets a read skip `_apply_road_carve` and `_apply_region_blend`
# entirely — the two passes that made rehydrating a cached chunk cost as much as it did. That is
# only sound if the stored channels reproduce the generated surface EXACTLY, so this compares the
# fast path against BOTH references: the generated chunk, and the recompute path it replaces.
func test_stored_surface_channels_reproduce_the_generated_surface_exactly() -> void:
	_install_two_regions()
	var m := _manager()
	m.set_region_source(_blend_source())
	var coord := Vector2i(2, -1)
	var generated := m.compute_chunk_data(coord)
	var channels := TerrainManager.surface_channels_from(generated)
	assert_eq(channels.size(), (generated["uv2s"] as PackedVector2Array).size() * 3,
		"precondition: three channels per vertex were extracted")
	var heights: PackedFloat32Array = generated["heights"]
	var lights: PackedColorArray = generated.get("lights", PackedColorArray())
	var fast := m._rehydrate_chunk_data(coord, heights, lights, channels)
	var slow := m._rehydrate_chunk_data(coord, heights, lights)
	assert_eq(fast["uv2s"] as PackedVector2Array, generated["uv2s"] as PackedVector2Array,
		"the stored channels reproduce the generated UV2s bit-for-bit")
	assert_eq(fast["colors"] as PackedColorArray, generated["colors"] as PackedColorArray,
		"and the generated colours, RGB baked light included")
	assert_eq(fast["uv2s"] as PackedVector2Array, slow["uv2s"] as PackedVector2Array,
		"the fast path and the recompute path agree, so the section is a pure speed-up")
	assert_eq(fast["colors"] as PackedColorArray, slow["colors"] as PackedColorArray,
		"colours likewise")


# The channels are OPTIONAL, and a wrong-sized array must fall back to recomputing rather than
# splice garbage into the mesh — the fast path can never be a correctness dependency.
func test_a_mis_sized_channel_array_falls_back_to_recomputing() -> void:
	_install_two_regions()
	var m := _manager()
	m.set_region_source(_blend_source())
	var coord := Vector2i(0, 3)
	var generated := m.compute_chunk_data(coord)
	var heights: PackedFloat32Array = generated["heights"]
	var lights: PackedColorArray = generated.get("lights", PackedColorArray())
	var truncated := TerrainManager.surface_channels_from(generated).slice(0, 30)
	assert_eq(_uv2_ys(m._rehydrate_chunk_data(coord, heights, lights, truncated)),
		_uv2_ys(generated),
		"a short channel array is ignored and the region field is re-derived")


# --- 3. The opt-in guard: a stage is untouched -----------------------------------------

func test_a_fresh_manager_has_no_region_source() -> void:
	assert_null((autofree(TerrainManager.new()) as TerrainManager).region_source,
		"region blending is opt-in; a stage never attaches a region field")


func test_without_a_region_source_the_channel_is_untouched() -> void:
	_install_two_regions()
	var m := _manager()
	var data := m.compute_chunk_data(Vector2i(1, 0))
	var ys := _uv2_ys(data)
	assert_false(ys.is_empty(), "the chunk has vertices")
	for y in ys:
		if y != 0.0:
			fail_test("a stage chunk's UV2.y must stay exactly as the builder wrote it (0)")
			return
	assert_true(true, "every vertex kept the builder's UV2.y")


# The stage path must be byte-identical with and without the feature COMPILED IN — the strongest
# form of that check available here: the same coord, one manager with no region source, produces
# the same mesh arrays as its own repeat, and its uv2s differ from a region-baked one only in y.
func test_region_bake_touches_only_the_y_channel() -> void:
	_install_two_regions()
	var coord := Vector2i(0, 1)
	var plain := _manager().compute_chunk_data(coord)
	var blended_manager := _manager()
	blended_manager.set_region_source(_blend_source())
	var blended := blended_manager.compute_chunk_data(coord)
	var plain_uv2s: PackedVector2Array = plain["uv2s"]
	var blended_uv2s: PackedVector2Array = blended["uv2s"]
	assert_eq(plain["heights"], blended["heights"], "the bake never moves a height")
	assert_eq(plain["colors"], blended["colors"], "the bake never touches the road weight")
	assert_eq(plain_uv2s.size(), blended_uv2s.size(), "same vertex count")
	for i in plain_uv2s.size():
		if plain_uv2s[i].x != blended_uv2s[i].x:
			fail_test("the bake must leave the tarmac weight in UV2.x alone (vertex %d)" % i)
			return
	assert_true(true, "UV2.x is untouched; only UV2.y carries the region rank")


# --- 4. The uploaded pair ---------------------------------------------------------------

func test_region_pair_picks_the_two_strongest_regions() -> void:
	var pair := Overworld.region_pair_of({WEST: 0.2, EAST: 0.55, NORTH: 0.25})
	assert_eq(String(pair["a"]), EAST, "slot A is the strongest region")
	assert_eq(String(pair["b"]), NORTH, "slot B is the second strongest")
	assert_true(float(pair["weight_a"]) >= float(pair["weight_b"]),
		"the pair is ordered by weight")
	assert_between(float(pair["weight_a"]) + float(pair["weight_b"]), 0.0, 1.0,
		"two weights out of a set summing to 1 cannot themselves exceed 1")


func test_region_pair_of_a_single_region_has_no_second_slot() -> void:
	var pair := Overworld.region_pair_of({WEST: 1.0})
	assert_eq(String(pair["a"]), WEST, "the only region is slot A")
	assert_eq(String(pair["b"]), "", "there is nothing to blend towards")
	assert_eq(float(pair["weight_b"]), 0.0, "and no weight for a slot that does not exist")


# Equal weights must not let dictionary ordering decide the pair, or the ground could flip between
# two equally-close regions frame to frame.
func test_region_pair_is_deterministic_when_weights_tie() -> void:
	var first := Overworld.region_pair_of({WEST: 0.5, EAST: 0.5})
	var second := Overworld.region_pair_of({EAST: 0.5, WEST: 0.5})
	assert_eq(String(first["a"]), String(second["a"]), "slot A does not follow insertion order")
	assert_eq(String(first["b"]), String(second["b"]), "nor does slot B")


# --- 5. The three-region junction --------------------------------------------------------

# Two shader slots cannot express three looks. The documented behaviour is to take the two
# strongest and let the third fall to whichever slot it is nearer — what must NOT happen is an
# error, an empty slot or a value outside the field's range.
func test_a_three_region_junction_resolves_to_two() -> void:
	var junction := _install_three_regions()
	var region := OverworldRegion.new()
	var weights := region.region_weights_at(junction)
	assert_eq(weights.size(), 3, "the fixture really does put three regions at this point")

	var pair := Overworld.region_pair_of(weights)
	var id_a := String(pair["a"])
	var id_b := String(pair["b"])
	assert_ne(id_a, "", "a junction still resolves a slot A")
	assert_ne(id_b, "", "and a slot B")
	assert_ne(id_a, id_b, "the two slots are different regions")
	assert_true(float(pair["weight_b"]) > 0.0, "both uploaded regions really contribute here")

	var src := Overworld.RegionBlendSource.new(region, SIZE_M)
	var rank := src.region_rank_at(
		Overworld.world_xz(junction, SIZE_M).x, Overworld.world_xz(junction, SIZE_M).z)
	assert_between(rank, 0.0, 1.0, "the baked field stays in range at a junction")


# --- 6. The all-regions colour LUT --------------------------------------------------------
#
# THE BUG THIS GUARDS. Ranks are assigned by SORTED ID, so they bear no relation to geography, and
# the shader only ever holds two region parameter slots. Decoding COLOUR against that pair clamped
# every chunk belonging to a third region onto whichever of the two sat nearer in rank — so distant
# ground painted as a region it was not, and the mis-assignment changed as the pair followed the
# car. The fix is a table of EVERY region's colours, uploaded once, indexed by the same baked rank.
#
# Nothing here asserts an authored colour or a rank VALUE: the fixture regions author no look at
# all, so what is checked is the table's SHAPE — one entry per region, ascending, aligned with
# rank_of, and the documented fallback for a region that authors nothing.

func test_the_colour_lut_holds_every_region_not_just_a_pair() -> void:
	_install_three_regions()
	var src := _blend_source()
	var lut := Overworld.region_look_lut(src, GameConfig.new())
	assert_eq(int(lut["count"]), src.ids().size(),
		"the LUT covers every ranked region, so no region's ground borrows another's colours")
	var ranks: PackedFloat32Array = lut["ranks"]
	var tints: PackedColorArray = lut["tints"]
	var tarmacs: PackedColorArray = lut["tarmacs"]
	assert_eq(ranks.size(), int(lut["count"]), "one rank per entry")
	assert_eq(tints.size(), int(lut["count"]), "one tint per entry")
	assert_eq(tarmacs.size(), int(lut["count"]), "one tarmac colour per entry")


# The shader brackets the baked rank by walking the table in order, so the ranks MUST ascend and
# MUST be the same numbers the bake writes — otherwise it would pick the wrong pair of entries.
func test_the_colour_lut_is_sorted_and_agrees_with_the_baked_ranks() -> void:
	_install_three_regions()
	var src := _blend_source()
	var lut := Overworld.region_look_lut(src, GameConfig.new())
	var ranks: PackedFloat32Array = lut["ranks"]
	var ids := src.ids()
	for i in ranks.size():
		assert_almost_eq(ranks[i], src.rank_of(String(ids[i])), 0.0001,
			"LUT entry %d carries that region's own baked rank" % i)
		if i > 0:
			assert_true(ranks[i] > ranks[i - 1],
				"the table ascends, which is what the shader's bracket search relies on")


# A region authoring neither key must land on the config baseline — the same fallback slot A uses,
# so the two paths cannot disagree about what "authors nothing" looks like.
func test_a_region_authoring_no_colours_falls_back_to_the_config_baseline() -> void:
	_install_two_regions()
	var cfg := GameConfig.new()
	var src := _blend_source()
	var lut := Overworld.region_look_lut(src, cfg)
	var tints: PackedColorArray = lut["tints"]
	var tarmacs: PackedColorArray = lut["tarmacs"]
	for i in int(lut["count"]):
		assert_eq(tints[i], cfg.terrain_tint, "an unauthored tint is the config's")
		assert_eq(tarmacs[i], cfg.tarmac_color, "an unauthored tarmac colour is the config's")


func test_the_colour_lut_is_empty_without_a_region_source() -> void:
	var lut := Overworld.region_look_lut(null, GameConfig.new())
	assert_eq(int(lut["count"]), 0,
		"no rank field means no LUT, and the shader falls back to the single-region uniforms")


# The shader arrays are fixed-length, so a roster that outgrows them must truncate rather than
# overrun. (region_look_lut also pushes a warning; the behaviour that matters is the bound.)
func test_the_colour_lut_is_capped_at_the_shader_array_length() -> void:
	var roster: Array[Dictionary] = []
	var wanted := Overworld.REGION_LUT_MAX + 3
	for i in wanted:
		roster.append(_pin("fx_%d" % i, "fx_region_%02d" % i,
			Vector2(float(i + 1) / float(wanted + 1), 0.5)))
	RallyLibrary.override_for_test(roster)
	var src := _blend_source()
	assert_eq(src.ids().size(), wanted, "the fixture really does exceed the shader's table")
	var lut := Overworld.region_look_lut(src, GameConfig.new())
	assert_eq(int(lut["count"]), Overworld.REGION_LUT_MAX,
		"the table never exceeds the uniform array the shader declares")
