extends GutTest
# Logic tests for RegionLibrary. All use SYNTHETIC region + rally lists via the
# test seams (never the shipped Greek roster / textures), so retuning the catalogue
# can't break them (CLAUDE.md).

const R_A := "ra"
const R_B := "rb"
const R_C := "rc"
const R_D := "rd"  # inherits R_B's look via look_from
const R_E := "re"  # authors nothing at all (no rallies, no look, no waterline)

func _regions() -> Array[Dictionary]:
	return [
		{"id": R_A, "name": "A", "water_level": -9.0},
		{
			"id": R_B, "name": "B", "grass_texture": "res://x.png",
			"tarmac_color": Color(0.5, 0.4, 0.3),
			"road_marking_color": Color(0.9, 0.8, 0.1),
		},
		{
			"id": R_C, "name": "C",
			"tree_mix": [
				{"texture": "res://a.png", "profile": "region", "weight": 0.6},
				{"texture": "res://b.png", "profile": "home", "weight": 0.4},
			],
			"spawn_bush_mesh": false,
		},
		{
			"id": R_D, "name": "D", "look_from": R_B,
			"tarmac_color": Color(0.1, 0.1, 0.1),  # own key overlays B's
		},
		{"id": R_E, "name": "E"},
	]

# rallies: each region has 1 non-showdown + 1 showdown.
func _rallies() -> Array[Dictionary]:
	return [
		{"id": "a1", "showdown": false, "region": R_A},
		{"id": "a_sd", "showdown": true, "region": R_A},
		{"id": "b1", "showdown": false, "region": R_B},
		{"id": "b_sd", "showdown": true, "region": R_B},
		{"id": "c1", "showdown": false, "region": R_C},
		{"id": "c_sd", "showdown": true, "region": R_C},
	]

func before_each() -> void:
	RegionLibrary.override_for_test(_regions())
	RallyLibrary.override_for_test(_rallies())

func after_each() -> void:
	RegionLibrary.reset()
	RallyLibrary.reset()

func _profile(completed_ids: Array) -> Dictionary:
	var rallies := {}
	for id in completed_ids:
		rallies[id] = {"completed": true}
	return {"rallies": rallies}

func test_grouping_round_trip() -> void:
	assert_eq(RegionLibrary.region_for_rally("b1").get("id", ""), R_B)
	var ids := []
	for r in RegionLibrary.rallies_in(R_B):
		ids.append(r["id"])
	assert_eq(ids, ["b1", "b_sd"])
	assert_eq(RegionLibrary.showdown_of(R_B).get("id", ""), "b_sd")

func test_all_showdowns_completed_needs_every_region() -> void:
	# N-1 of the authored showdowns done → still false; the last one flips it.
	assert_false(RegionLibrary.all_showdowns_completed(_profile([])))
	assert_false(RegionLibrary.all_showdowns_completed(_profile(["a_sd", "b_sd"])),
		"one outstanding showdown keeps credits shut")
	assert_true(RegionLibrary.all_showdowns_completed(_profile(["a_sd", "b_sd", "c_sd"])),
		"every authored showdown completed opens credits")

func test_all_showdowns_completed_skips_showdownless_regions() -> void:
	# R_D / R_E author no rallies at all — an empty region must not make credits
	# unreachable forever.
	assert_true(RegionLibrary.all_showdowns_completed(_profile(["a_sd", "b_sd", "c_sd"])),
		"a region with no authored showdown is skipped, not counted outstanding")

func test_empty_region_showdown_is_not_unlocked() -> void:
	# The vacuous-completion guard: a region with no non-showdown rallies authored
	# must NOT read as showdown-unlocked (its rally loop would pass over nothing).
	assert_false(RegionLibrary.showdown_unlocked(R_E, _profile([])),
		"an empty region's showdown never reads as unlocked")
	assert_false(RegionLibrary.showdown_unlocked("no_such_region", _profile([])),
		"an unknown region id is rejected")

func test_per_region_showdown_gate_is_independent() -> void:
	# A's showdown opens when A's non-showdown rallies are done, regardless of B/C.
	assert_false(RegionLibrary.showdown_unlocked(R_A, _profile([])))
	assert_true(RegionLibrary.showdown_unlocked(R_A, _profile(["a1"])))
	# Completing a1 does NOT open B's showdown.
	assert_false(RegionLibrary.showdown_unlocked(R_B, _profile(["a1"])))

func test_look_of_returns_only_present_overrides() -> void:
	assert_eq(RegionLibrary.look_of(R_A), {})  # no overrides authored
	var look := RegionLibrary.look_of(R_B)
	assert_eq(look.get("grass_texture", ""), "res://x.png")
	assert_false(look.has("sky_panorama"))

func test_look_of_surfaces_color_overrides() -> void:
	# tarmac_color / road_marking_color are whitelisted look keys: a region that
	# authors them has them surfaced by look_of (synthetic values, not the shipped
	# catalogue), and a region that doesn't leaves them absent so callers fall back.
	var look := RegionLibrary.look_of(R_B)
	assert_true(look.has("tarmac_color"), "authored tarmac_color is surfaced")
	assert_true(look.has("road_marking_color"), "authored road_marking_color is surfaced")
	assert_eq(look["tarmac_color"], Color(0.5, 0.4, 0.3))
	assert_eq(look["road_marking_color"], Color(0.9, 0.8, 0.1))
	# A region that authors neither leaves both out — callers use their fallback.
	var bare := RegionLibrary.look_of(R_A)
	assert_false(bare.has("tarmac_color"))
	assert_false(bare.has("road_marking_color"))

func test_look_from_inherits_parent_block_and_own_keys_win() -> void:
	var parent := RegionLibrary.look_of(R_B)
	var child := RegionLibrary.look_of(R_D)
	# Inherited: a parent key the child doesn't author comes through unchanged.
	assert_eq(child.get("grass_texture", ""), parent.get("grass_texture", ""),
		"the inheriting region resolves its parent's look")
	assert_eq(child.get("road_marking_color"), parent.get("road_marking_color"))
	# Overlaid: the child's own key wins over the parent's.
	assert_eq(child.get("tarmac_color"), Color(0.1, 0.1, 0.1),
		"the inheriting region's own key overrides the parent's")
	assert_ne(child.get("tarmac_color"), parent.get("tarmac_color"))
	# The plumbing key never leaks into the look dict world.gd consumes.
	assert_false(child.has("look_from"), "look_from is not a look key")

func test_water_level_is_per_region_and_optional() -> void:
	# A region that authors a waterline reports it; one that doesn't is
	# distinguishable, so callers can fall through to the GameConfig baseline.
	assert_true(RegionLibrary.has_water_level(R_A))
	assert_eq(RegionLibrary.water_level_of(R_A), -9.0,
		"the authored waterline is surfaced")
	assert_false(RegionLibrary.has_water_level(R_B),
		"a region authoring no waterline is distinguishable")
	assert_false(RegionLibrary.has_water_level("no_such_region"))
	# water_level is deliberately NOT inherited through look_from.
	assert_false(RegionLibrary.has_water_level(R_D),
		"look_from does not inherit the waterline")

func test_tree_mix_defaults_when_unauthored() -> void:
	# A region with no tree_mix falls back to the single default home tree at 100%.
	var mix := RegionLibrary.tree_mix(RegionLibrary.look_of(R_A))
	assert_eq(mix, RegionLibrary.DEFAULT_TREE_MIX,
		"an unauthored region uses the default single-tree mix")

func test_tree_mix_returns_authored_split() -> void:
	var mix := RegionLibrary.tree_mix(RegionLibrary.look_of(R_C))
	assert_eq(mix.size(), 2, "the authored two-species split is surfaced")
	# Weights sum to the whole (the split covers everything) — a contract, not a value.
	var total := 0.0
	for e in mix:
		total += float(e["weight"])
	assert_almost_eq(total, 1.0, 0.0001, "authored mix weights cover the whole")

func test_spawns_bush_mesh_defaults_true_and_honours_override() -> void:
	assert_true(RegionLibrary.spawns_bush_mesh(RegionLibrary.look_of(R_A)),
		"a region that authors nothing keeps the bushes")
	assert_false(RegionLibrary.spawns_bush_mesh(RegionLibrary.look_of(R_C)),
		"spawn_bush_mesh = false suppresses the bush pass")
