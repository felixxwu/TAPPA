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
		{"id": R_B, "name": "B", "grass_texture": "res://x.png"},
		{"id": R_C, "name": "C"},
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
