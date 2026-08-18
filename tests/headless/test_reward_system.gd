extends GutTest
# The reward policy (RewardSystem): the tier clamp, the per-rally car draw with its
# prefer-un-owned + anti-soft-lock behaviour, and the special-unlock cascade. Pure
# functions, driven with an injected seeded RNG. See todo/reward-system.md.
#
# THE RANDOM UPGRADE DRAW IS GONE, and so are its tests. Parts are won at their prize
# rally or bought with stars, so nothing is left to roll for; the two GATES that pool used
# to filter on survive and are asserted directly against UpgradeLibrary below, since they
# now decide what the player can BUY.

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


func _rng(seed_value: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed_value
	return r
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


# A profile with EVERY rally on the roster won 1st. Used to force every star gate open so
# a test can exercise the rest of the draw against the whole catalogue — the star gate
# gets its own dedicated test rather than silently shrinking every other pool.
func _all_completed_profile() -> Dictionary:
	var rallies := {}
	for rally in RallyLibrary.all():
		rallies[rally["id"]] = {"completed": true, "best_combined_ms": 1000, "best_placed": 1}
	return {"rallies": rallies, "cars": []}


# --- Tier clamp --------------------------------------------------------------

func test_tier_ceiling_is_monotonic_and_clamped() -> void:
	var prev := 0
	for c in range(0, 20):
		var ceiling := RewardSystem.tier_ceiling(c)
		assert_gte(ceiling, prev, "ceiling never decreases as completion rises")
		assert_lte(ceiling, RewardSystem.MAX_TIER, "ceiling never exceeds MAX_TIER")
		assert_gte(ceiling, 1, "ceiling is at least 1")
		prev = ceiling


func test_target_tier_never_exceeds_ceiling() -> void:
	# Fresh profile (0 completed) -> a low ceiling clamps even a hard rally down to it.
	var fresh := _profile([], [])
	var ceiling := RewardSystem.tier_ceiling(0)
	assert_lte(RewardSystem.target_tier(4, fresh), ceiling,
		"a tier-4 rally never pays above the current ceiling")


# --- The two part GATES ------------------------------------------------------
# These used to be asserted through the random upgrade pool (RewardSystem._eligible_parts).
# That pool is gone — parts are won at their prize rally or bought with stars — but the two
# gates it filtered on are very much alive: UpgradeOptions._lock_reason greys a row on
# exactly these, so they now decide what the player can BUY rather than what can drop.
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


func test_a_star_gated_part_is_refused_until_its_event_is_won() -> void:
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


func _lowest_tier_model() -> Dictionary:
	var best: Dictionary = {}
	for entry in CarLibrary.all():
		if best.is_empty() or int(entry["reward_tier"]) < int(best["reward_tier"]):
			best = entry
	return best


func test_draw_car_clamped_by_progress_ceiling() -> void:
	# The car draw is clamped by the PROGRESS ceiling (rallies completed) — the same clamp
	# the upgrade draw uses (gameplay.md) — NOT by the garage's highest owned tier. At 0
	# completed the ceiling is tier_ceiling(0), so even beating a top-difficulty rally can't
	# drop a car above it. Synthetic open-class rally (reveal_after 0, incomplete) keeps the
	# owned car eligible — the standard-draw path this asserts.
	RallyLibrary.override_for_test([
		{"id": "r_open", "region": "home", "special": false, "restriction": {}, "difficulty": 1},
	])
	var starter := _lowest_tier_model()
	var profile := _profile([], [String(starter["id"])])
	var ceiling := RewardSystem.tier_ceiling(0)
	for i in 40:
		var model: Variant = RewardSystem.draw_car(profile, RewardSystem.MAX_TIER, _rng(i))
		var meta := CarLibrary.by_id(String(model))
		assert_false(meta.is_empty(), "draw returns a real catalogue car")
		assert_lte(int(meta["reward_tier"]), ceiling,
			"a drawn car never exceeds the progress ceiling, even off a top-difficulty rally")
	RallyLibrary.reset()


func test_draw_car_difficulty_caps_below_progress_ceiling() -> void:
	# reward tier = min(f(difficulty), progress ceiling): with LOTS completed (a high
	# progress ceiling) but a LOW-difficulty rally, the draw is still capped at the
	# difficulty tier — a soft rally never pays a top car just because progress is high.
	RallyLibrary.override_for_test([
		{"id": "r_open", "region": "home", "special": false, "restriction": {}, "difficulty": 1},
	])
	var completed: Array = []
	for n in 8:  # ids need not be real — completed_count only counts them
		completed.append("done_%d" % n)
	var starter := _lowest_tier_model()
	var profile := _profile(completed, [String(starter["id"])])
	assert_gt(RewardSystem.tier_ceiling(8), 1, "setup: the progress ceiling is above tier 1")
	for i in 40:
		var model: Variant = RewardSystem.draw_car(profile, 1, _rng(i))  # difficulty-1 rally
		var meta := CarLibrary.by_id(String(model))
		assert_false(meta.is_empty(), "draw returns a real catalogue car")
		assert_lte(int(meta["reward_tier"]), 1,
			"a difficulty-1 rally never pays above tier 1, even with a high progress ceiling")
	RallyLibrary.reset()


func test_draw_car_prefers_unowned() -> void:
	# Within the clamped pool the draw prefers un-owned models. Own every catalogue car
	# EXCEPT the highest-tier one; with a top-difficulty rally + high progress the pool
	# spans the whole roster, so the draw must always return that remaining un-owned car
	# (owned alternatives exist yet are never picked).
	RallyLibrary.override_for_test([
		{"id": "r_open", "region": "home", "special": false, "restriction": {}, "difficulty": 4},
	])
	var completed: Array = []
	for n in 8:
		completed.append("done_%d" % n)
	var pool: Array = RewardSystem._cars_at_or_below_tier(RewardSystem.MAX_TIER)
	var target := ""
	var best_tier := -1
	for id in pool:
		var t := int(CarLibrary.by_id(String(id))["reward_tier"])
		if t > best_tier:
			best_tier = t
			target = String(id)
	if target == "":
		RallyLibrary.reset()
		return  # empty roster — nothing to prove
	var owned: Array = []
	for id in pool:
		if String(id) != target:
			owned.append(String(id))
	var profile := _profile(completed, owned)
	for i in 30:
		assert_eq(RewardSystem.draw_car(profile, 4, _rng(i)), target,
			"draws the un-owned car within the clamped pool, never an owned one")
	RallyLibrary.reset()


func test_draw_car_grants_duplicate_when_everything_owned() -> void:
	# Own the whole roster: no un-owned candidate remains anywhere, so the draw
	# still grants (guaranteed reward) — a duplicate of an owned model.
	var owned: Array = []
	for entry in CarLibrary.all():
		owned.append(String(entry["id"]))
	var profile := _profile([], owned)
	var model: Variant = RewardSystem.draw_car(profile, 0, _rng(1))
	assert_true(owned.has(model), "with every car owned, draws a duplicate of an owned one")


func test_draw_car_always_grants_even_with_everything_completed() -> void:
	# Every rally completed and nothing owned — the old policy returned null
	# here; the new one must still pay a real car (guaranteed reward).
	var all_ids := []
	for rally in RallyLibrary.RALLIES:
		all_ids.append(rally["id"])
	var profile := _profile(all_ids, [])
	var model: Variant = RewardSystem.draw_car(profile, 0, _rng(1))
	assert_not_null(model, "a car is always granted, even post-completion")
	assert_false(CarLibrary.by_id(String(model)).is_empty(), "and it is a catalogue car")


# --- Map-reveal gating -------------------------------------------------------
# A rally opens when the player has lit the map out to its pin (RallyLibrary.rally_revealed),
# so these fixtures express "locked" and "open" as PIN POSITIONS: inside the starting
# circle = open, far outside every circle = dark.
#
# The starting circle belongs to the player's OPENING RALLY, not to HQ — HQ lights nothing
# (see features/map-exploration.md) — so the open fixture carries a `prize_car` and the
# profile names it as the starter. Without that pairing the whole map is dark and a test
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


# --- Duplicate-reward guards --------------------------------------------------
# The tier a draw resolves at is min(rally_difficulty, earned_ceiling), so a
# low-difficulty rally keeps drawing the low-tier pool however far the player has
# come. There are more low-difficulty rallies than low-tier cars, so that pool runs
# out and the reward becomes a car already in the garage. These two guards cover the
# step-up and the never-twice-running rule. Both use the synthetic CarFixtures roster
# and assert relations only — no authored tier or car id is pinned.

func test_an_exhausted_tier_steps_up_to_a_car_the_player_has_earned() -> void:
	# Own every car at the drawn tier, but have earned a higher one: the draw must
	# find something NEW rather than hand back a duplicate.
	RallyLibrary.override_for_test([
		{"id": "r_open", "region": "home", "special": false, "restriction": {}, "difficulty": 1},
	])
	var low_tier: Array = RewardSystem._cars_at_or_below_tier(1)
	if low_tier.size() < 1 or RewardSystem._cars_at_or_below_tier(2).size() <= low_tier.size():
		RallyLibrary.reset()
		return  # fixture roster has no higher tier to climb to; nothing to assert
	# Enough completions that tier 2 is earned (tier_ceiling = 1 + completed/2).
	var profile := _profile(["a", "b"], low_tier)
	for i in 12:
		var model: Variant = RewardSystem.draw_car(profile, 1, _rng(i))
		assert_not_null(model, "an exhausted tier still yields a grant")
		assert_false(low_tier.has(String(model)),
			"the grant climbs past the exhausted tier instead of repeating an owned car")
	RallyLibrary.reset()


func test_a_draw_does_not_repeat_the_previous_grant_when_an_alternative_exists() -> void:
	# Pool fully owned and no higher tier earned, so a duplicate is unavoidable — but
	# it must not be the SAME duplicate the player just received.
	RallyLibrary.override_for_test([
		{"id": "r_open", "region": "home", "special": false, "restriction": {}, "difficulty": 1},
	])
	var low_tier: Array = RewardSystem._cars_at_or_below_tier(1)
	if low_tier.size() < 2:
		RallyLibrary.reset()
		return  # need two owned cars for "not the previous one" to mean anything
	var profile := _profile([], low_tier)          # no completions -> no tier to climb to
	var cars: Array = profile["cars"]
	var last := String((cars[cars.size() - 1] as Dictionary)["model_id"])
	for i in 12:
		var model: Variant = RewardSystem.draw_car(profile, 1, _rng(i))
		assert_ne(String(model), last, "the draw never repeats the car granted last time")
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
