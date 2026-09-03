extends GutTest
# The reward policy (RewardSystem): the special-unlock cascade, plus the two part GATES
# it used to filter a draw pool on. See todo/reward-system.md, features/reward-system.md.
#
# THE CAR DRAW IS GONE (todo/roguelike-pivot.md decision 28), and so are its tests —
# draw_car / target_tier / tier_ceiling and the whole tier-clamp model died with prize
# rallies; car acquisition is a money shop now, not a rally-win draw. THE RANDOM UPGRADE
# DRAW WAS ALREADY GONE before this pass. Parts are won at their prize rally or bought
# with stars — and now that stars are ALSO gone (decision 21), only the "won at the rally
# that unlocks it" route survives — so nothing is left to roll for; the two GATES that
# pool used to filter on survive and are asserted directly against UpgradeLibrary below,
# since they decide what a part unlock can reach.

const CarFixtures = preload("res://tests/headless/car_fixtures.gd")
const SaveTestHelpers = preload("res://tests/headless/save_test_helpers.gd")
const TEST_PATH := "user://test_reward_system_profile.json"

# NOTE: no UpgradeFixtures here. These tests stay on the shipped table because the gate
# tests assert CATALOGUE CONTRACTS (a real rally-gated part exists and is withheld) rather
# than logic over a roster. Only the car roster below is synthetic. A new logic test is
# free to install fixtures.
var _profile_backup: Dictionary = {}


func before_each() -> void:
	CarFixtures.install()
	# The rally roster too: reveal is geometric now, so which rallies a garage can enter
	# depends on authored PIN POSITIONS. Reading the shipped map here would make these
	# tests fail the moment a designer nudges a pin — the fixture roster keeps an
	# open-class rally lit from the start, which is all the pricing checks need.
	RallyFixtures.install()
	# Some tests below assign Save.profile and grant cars through Save, which SAVES —
	# so point the autoload at a throwaway file first: without it those grants wrote
	# fixture cars straight into the developer's real profile.json.
	SaveTestHelpers.redirect(TEST_PATH)
	# Stash the (now sandboxed) profile so nothing leaks into the next test — or the next FILE.
	_profile_backup = (get_node("/root/Save").profile as Dictionary).duplicate(true)


func after_each() -> void:
	get_node("/root/Save").profile = _profile_backup
	SaveTestHelpers.cleanup(TEST_PATH)
	CarFixtures.restore()
	RallyFixtures.restore()


func _profile(completed: Array, owned: Array) -> Dictionary:
	var rallies := {}
	for rally_id in completed:
		rallies[rally_id] = {"completed": true, "best_combined_ms": 1000}
	var cars := []
	var n := 1
	for model_id in owned:
		cars.append({"instance_id": n, "model_id": model_id, "hp": 100.0,
			"installed_upgrades": [], "tuning": {}})
		n += 1
	return {"rallies": rallies, "cars": cars}


# A profile with EVERY rally on the roster won 1st. Used to force every rally gate open so
# a test can exercise the rest against the whole catalogue.
func _all_completed_profile() -> Dictionary:
	var rallies := {}
	for rally in RallyLibrary.all():
		rallies[rally["id"]] = {"completed": true, "best_combined_ms": 1000, "best_placed": 1}
	return {"rallies": rallies, "cars": []}


# --- The two part GATES ------------------------------------------------------
# These used to be asserted through the random upgrade pool (RewardSystem._eligible_parts).
# That pool is gone — parts are won at their prize rally — but the two gates it filtered on
# are very much alive: UpgradeOptions._lock_reason greys a row on exactly these.
# Asserted directly against UpgradeLibrary, which is where they always really lived.

func test_a_prerequisite_gate_opens_only_once_the_car_has_the_earlier_rung() -> void:
	# A CONTRACT test against the shipped catalogue, so it needs the shipped rally roster:
	# Big Turbo's event gate names a real special, which the fixture roster before_each
	# installs does not contain. after_each re-restores.
	RallyFixtures.restore()
	var without := {"instance_id": 1, "model_id": "mx5", "hp": 100.0,
		"installed_upgrades": [], "tuning": {}}
	assert_false(UpgradeLibrary.prerequisite_met("turbo_large", without),
		"Big Turbo is refused until this car has its prerequisite")
	var with_small := {"instance_id": 1, "model_id": "mx5", "hp": 100.0,
		"installed_upgrades": ["turbo_small"], "tuning": {}}
	assert_true(UpgradeLibrary.prerequisite_met("turbo_large", with_small),
		"and allowed once the car has Small Turbo")


func test_a_rally_gated_part_is_refused_until_its_event_is_won() -> void:
	# The gate itself, against the real catalogue: SOME part is authored behind a special,
	# and a profile that has won nothing must not be offered it. No specific id is pinned.
	RallyFixtures.restore()
	# Must be a part gated ONLY by a rally gate: an entry that also carries a
	# requires_upgrade_id would let the prerequisite explain the refusal and the rally
	# gate would go untested.
	var gated := ""
	for item in UpgradeLibrary.all():
		var id := String(item["id"])
		if UpgradeLibrary.unlocked_by_rally(id) != "" and UpgradeLibrary.requires_upgrade_id(id) == "":
			gated = id
			break
	if gated == "":
		pass_test("no purely rally-gated part authored; nothing to assert")
		return
	assert_false(UpgradeLibrary.rally_gate_met(gated, _profile([], [])),
		"a rally-gated part is refused before its event is won")
	assert_true(UpgradeLibrary.rally_gate_met(gated, _all_completed_profile()),
		"and allowed once it has been")


# --- Map-reveal gating -------------------------------------------------------
# A rally opens when the player has lit the map out to its pin (RallyLibrary.rally_revealed),
# so these fixtures express "locked" and "open" as PIN POSITIONS: inside the starting
# circle = open, far outside every circle = dark.
#
# The starting circle belongs to the player's OPENING RALLY, not to HQ — HQ lights nothing
# (see features/map-exploration.md) — so the open fixture carries a `prize_car` and the
# profile names it as the starter. This is a SYNTHETIC rally dict handed straight to
# RallyLibrary.prize_car_id(), which still reads whatever `prize_car` key it is given —
# only the SHIPPED roster's `prize_car` fields were deleted (todo/roguelike-pivot.md
# decision 28), not the accessor. Without that pairing the whole map is dark and a test
# like this passes for the wrong reason.

func test_the_eligibility_query_excludes_an_unrevealed_special() -> void:
	RallyLibrary.override_for_test([
		{"id": "r1", "region": "home", "special": false, "restriction": {},
			"prize_car": "fx_start_car", "map_pos": RallyLibrary.HQ_MAP_POS},
		{"id": "sp_far", "region": "home", "special": true, "restriction": {},
			"map_pos": RallyLibrary.HQ_MAP_POS + Vector2(0.9, 0.0)},
	])
	# Nothing completed → the far special is still dark.
	var car := {"pw": 150.0}  # synthetic; is_eligible reads restriction only
	var ids := []
	var fresh := {"rallies": {}, "starter_model_id": "fx_start_car"}
	for r in RallyLibrary.incomplete_rallies_enterable_by(car, fresh):
		ids.append(r["id"])
	assert_does_not_have(ids, "sp_far", "an unrevealed special is not enterable")
	assert_has(ids, "r1", "an ordinary revealed rally still is")
	RallyLibrary.reset()


func test_a_special_opens_once_the_map_is_lit_out_to_it() -> void:
	# r1 sits at HQ (open immediately) and the special sits just beyond HQ's own circle but
	# well inside the circle r1 lights once completed — so completing r1 is what opens it.
	var hq: Vector2 = RallyLibrary.HQ_MAP_POS
	RallyLibrary.override_for_test([
		{"id": "r1", "region": "home", "special": false, "restriction": {}, "map_pos": hq,
			"reveal_radius": 0.4},
		{"id": "sp_near", "region": "home", "special": true, "restriction": {},
			"map_pos": hq + Vector2(0.3, 0.0)},
	])
	var car := {"pw": 150.0}
	assert_false(RallyLibrary.rally_revealed(RallyLibrary.by_id("sp_near"), {"rallies": {}}),
		"dark before anything is driven")
	var profile := {"rallies": {"r1": {"completed": true, "best_placed": 1}}}
	var ids := []
	for r in RallyLibrary.incomplete_rallies_enterable_by(car, profile):
		ids.append(r["id"])
	assert_has(ids, "sp_near", "the special opens once the map is lit out to it")
	RallyLibrary.reset()


# --- grant_special_unlock (todo/special-unlock-reveal.md) ---------------------
# A synthetic three-rung ladder in ONE slot, so nothing here depends on the authored
# catalogue or on which real rally gates what.
func _install_ladder() -> void:
	var upgrades: Array[Dictionary] = [
		{"id": "r1", "name": "Rung One", "slot": "s", "consumable": false, "cost": 0},
		{"id": "r2", "name": "Rung Two", "slot": "s", "consumable": false, "cost": 0,
			"requires_upgrade_id": "r1"},
		{"id": "r3", "name": "Rung Three", "slot": "s", "consumable": false, "cost": 0,
			"requires_upgrade_id": "r2"},
	]
	UpgradeLibrary.override_for_test(upgrades)


# Awarding a rung two steps up the ladder grants the rungs beneath it too, so the award is
# actually usable. Asserted as the RELATIONSHIP (the prerequisite is satisfied), not as a
# list of ids, so re-authoring the ladders keeps the test true.
func test_granting_a_high_rung_cascades_its_prerequisites() -> void:
	_install_ladder()
	var owned: Dictionary = Save.grant_car("fx_light_rwd")
	var id := int(owned["instance_id"])

	var granted := RewardSystem.grant_special_unlock(id, "r3")
	assert_eq(String(granted[0]), "r3", "the headline is reported first, cascade behind it")
	var car: Dictionary = Save.get_car(id)
	assert_true(UpgradeLibrary.prerequisite_met("r3", car),
		"the cascade satisfies the awarded rung's prerequisite")
	assert_true(UpgradeLibrary.prerequisite_met("r2", car),
		"and every rung beneath it, so the chain is unbroken")
	UpgradeLibrary.reset()


# Only the headline runs. A ladder shares one slot, so enabling a lower rung as well would
# be contradictory — they are alternatives, not stacking parts.
func test_only_the_headline_is_enabled() -> void:
	_install_ladder()
	var owned: Dictionary = Save.grant_car("fx_light_rwd")
	var id := int(owned["instance_id"])
	RewardSystem.grant_special_unlock(id, "r3")
	var car: Dictionary = Save.get_car(id)
	var disabled: Array = car.get("disabled_upgrades", [])
	assert_false(disabled.has("r3"), "the headline is enabled on award")
	assert_true(disabled.has("r1"), "the cascaded rungs stay parked")
	assert_true(disabled.has("r2"), "including the one directly beneath the headline")
	UpgradeLibrary.reset()


# A rung with no prerequisite terminates immediately — the walk must not loop or over-grant.
func test_granting_a_bottom_rung_grants_only_itself() -> void:
	_install_ladder()
	var owned: Dictionary = Save.grant_car("fx_light_rwd")
	var granted := RewardSystem.grant_special_unlock(int(owned["instance_id"]), "r1")
	assert_eq(granted.size(), 1, "a rung with no prerequisite grants just itself")
	UpgradeLibrary.reset()


# Already fitted: grant nothing and report nothing, so the caller can still announce the
# gate without claiming the player was handed something. Reporting a partial cascade here
# would leave the reveal naming a prerequisite instead of the headline.
func test_granting_a_part_the_car_already_has_reports_nothing() -> void:
	_install_ladder()
	var owned: Dictionary = Save.grant_car("fx_light_rwd")
	var id := int(owned["instance_id"])
	RewardSystem.grant_special_unlock(id, "r3")
	assert_true(RewardSystem.grant_special_unlock(id, "r3").is_empty(),
		"a second award of the same part reports nothing granted")
	UpgradeLibrary.reset()


# A cycle in authored data (a bad requires_upgrade_id pair) must not hang the walk. This is
# the guard that keeps a data mistake from freezing the game at a podium.
func test_a_prerequisite_cycle_terminates() -> void:
	var upgrades: Array[Dictionary] = [
		{"id": "a", "name": "A", "slot": "s", "consumable": false, "cost": 0,
			"requires_upgrade_id": "b"},
		{"id": "b", "name": "B", "slot": "s", "consumable": false, "cost": 0,
			"requires_upgrade_id": "a"},
	]
	UpgradeLibrary.override_for_test(upgrades)
	var owned: Dictionary = Save.grant_car("fx_light_rwd")
	var granted := RewardSystem.grant_special_unlock(int(owned["instance_id"]), "a")
	assert_eq(granted.size(), 2, "the walk visits each rung once and stops")
	UpgradeLibrary.reset()
