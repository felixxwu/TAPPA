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

func before_each() -> void:
	RegionLibrary.override_for_test(_regions())

func after_each() -> void:
	RegionLibrary.reset()

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


# --- The shipped roster's own contract ------------------------------------------
#
# Reads the REAL RegionLibrary (not the synthetic fixture above), so it drops the
# override this file installs in before_each — the narrow exception CLAUDE.md allows
# for iterating the whole table as opaque input. It does NOT pin any region's actual
# `water_level` number (that would be a tunable-value test); it only asserts the
# RELATIONSHIP the "lakes" region is designed around: its waterline must sit clearly
# above every other region's, whatever those numbers happen to be tuned to.
func test_lakes_region_has_a_higher_water_level_than_every_other_region() -> void:
	RegionLibrary.reset()  # the SHIPPED roster is this test's subject
	var lakes_level := RegionLibrary.water_level_of("home_coast")
	assert_true(RegionLibrary.has_water_level("home_coast"), "the lakes region authors a waterline")
	var found_another := false
	for region in RegionLibrary.all():
		var id := String(region.get("id", ""))
		if id == "home_coast":
			continue
		if not RegionLibrary.has_water_level(id):
			continue
		found_another = true
		assert_gt(lakes_level, RegionLibrary.water_level_of(id),
			"lakes' water_level must sit clearly above %s's" % id)
	assert_true(found_another, "the roster has at least one other region to compare against")
