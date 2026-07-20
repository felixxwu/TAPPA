extends GutTest
# Logic tests for RegionLibrary. All use SYNTHETIC region + rally lists via the
# test seams (never the shipped Greek roster / textures), so retuning the catalogue
# can't break them (CLAUDE.md).

const R_A := "ra"
const R_B := "rb"
const R_C := "rc"

func _regions() -> Array[Dictionary]:
	return [
		{"id": R_A, "name": "A"},
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

func test_is_final_only_last() -> void:
	assert_false(RegionLibrary.is_final(R_A))
	assert_true(RegionLibrary.is_final(R_C))

func test_first_region_always_unlocked() -> void:
	assert_true(RegionLibrary.unlocked(R_A, _profile([])))

func test_unlock_chain_from_prev_showdown() -> void:
	# B locked until A's showdown done; C locked until B's showdown done.
	assert_false(RegionLibrary.unlocked(R_B, _profile([])))
	assert_true(RegionLibrary.unlocked(R_B, _profile(["a_sd"])))
	assert_false(RegionLibrary.unlocked(R_C, _profile(["a_sd"])))
	assert_true(RegionLibrary.unlocked(R_C, _profile(["a_sd", "b_sd"])))

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
