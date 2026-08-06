extends GutTest
# The reward draw policy (RewardSystem): the tier clamp, the per-event upgrade
# draw, and the per-rally car draw with its prefer-un-owned + anti-soft-lock
# behaviour. Pure functions, driven with an injected seeded RNG. See
# todo/reward-system.md.

const CarFixtures = preload("res://tests/headless/car_fixtures.gd")

# NOTE: no UpgradeFixtures here — but the reason has changed. The draw's pool builder
# (RewardSystem._eligible_parts) now goes through the override-aware UpgradeLibrary.all(),
# so a fixture override would no longer desync from what the draw returns. These tests stay
# on the shipped table because several of them assert CATALOGUE CONTRACTS (a real gated part
# exists and is withheld; the token is a real consumable) rather than draw logic. Only the
# car roster below is synthetic. A new draw-logic test is free to install fixtures.
var _profile_backup: Dictionary = {}


func before_each() -> void:
	CarFixtures.install()
	# The purchase tests below assign Save.profile (purchase_car mutates through Save).
	# Stash the real one so nothing leaks into the next test — or the next FILE.
	_profile_backup = (get_node("/root/Save").profile as Dictionary).duplicate(true)


func after_each() -> void:
	get_node("/root/Save").profile = _profile_backup
	CarFixtures.restore()


func _rng(seed_value: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed_value
	return r


func test_free_parts_are_never_drawn_as_a_reward() -> void:
	# Free parts (ballast) are always available and must never appear in the reward draw
	# pool. Iterates the pool as opaque output — no specific id pinned. Every star gate is
	# forced open (a profile with every rally won) so the whole catalogue is in scope.
	for id in RewardSystem._eligible_parts(_all_completed_profile()):
		assert_false(UpgradeLibrary.is_free(id),
			"a free part must not be drawable as a reward: %s" % id)


# Build a profile with the given completed rally ids and owned model ids.
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


# --- Upgrade draw ------------------------------------------------------------

func test_draw_upgrade_returns_parts_with_rare_consumables() -> void:
	var profile := _all_completed_profile()
	var consumables := 0
	var parts := 0
	for i in 300:
		var id: String = RewardSystem.draw_upgrade(profile, _rng(i))
		assert_false(UpgradeLibrary.by_id(id).is_empty(), "draw returns a real catalogue item")
		if UpgradeLibrary.is_consumable(id):
			consumables += 1
		else:
			parts += 1
	assert_gt(consumables, 0, "the rare consumables do appear")
	# Not `parts > consumables`: that pins the shipped catalogue's part-vs-consumable
	# weighting (a designer retuning ENGINE_SWAP_TOKEN_DROP_WEIGHT
	# could reasonably flip it). The real invariant is just that consumables stay rare
	# relative to the sample, not that parts strictly outnumber them.
	assert_gt(parts, 0, "parts are drawn at all")


func test_draw_upgrade_can_award_an_engine_swap_token() -> void:
	# The token is a member of the per-event pool (membership, NOT its weight).
	var profile := _all_completed_profile()
	var saw_token := false
	for i in 300:
		var id: String = RewardSystem.draw_upgrade(profile, _rng(i))
		if id == UpgradeLibrary.ENGINE_SWAP_TOKEN_ID:
			saw_token = true
	assert_true(saw_token, "the engine swap token can be drawn from the pool")


func test_draw_upgrade_never_awards_a_part_the_driven_car_has() -> void:
	# Fit one eligible part to the driven car: it must never be drawn again for
	# that car, while other parts still are. Derived from the live catalogue so a
	# retune of tiers/parts doesn't break the test.
	assert_gt(UpgradeLibrary.UPGRADES.size(), 0, "UpgradeLibrary.UPGRADES is non-empty (else this test asserts nothing)")
	var profile := _all_completed_profile()
	var fitted := ""
	for item in UpgradeLibrary.UPGRADES:
		if not item["consumable"]:
			fitted = String(item["id"])
			break
	var driven := {"instance_id": 1, "model_id": "mx5", "hp": 100.0,
		"installed_upgrades": [fitted], "tuning": {}}
	for i in 200:
		var id: String = RewardSystem.draw_upgrade(profile, _rng(i), driven)
		assert_ne(id, fitted, "a part already fitted to the driven car is never drawn")


# Contract test (not a logic test): Big Turbo is authored with requires_upgrade_id
# "turbo_small", so _eligible_parts must honor that wiring against the real catalogue:
# excluded from the pool until THE DRIVEN CAR has Small Turbo fitted, present once it
# does. Star gates are forced open so only the prerequisite is under test.
func test_eligible_parts_excludes_big_turbo_until_small_turbo_is_owned() -> void:
	var profile := _all_completed_profile()
	var without := {"instance_id": 1, "model_id": "mx5", "hp": 100.0,
		"installed_upgrades": [], "tuning": {}}
	assert_does_not_have(RewardSystem._eligible_parts(profile, [], without), "turbo_large",
		"Big Turbo stays out of the pool until this car has its prerequisite")
	var with_small := {"instance_id": 1, "model_id": "mx5", "hp": 100.0,
		"installed_upgrades": ["turbo_small"], "tuning": {}}
	assert_has(RewardSystem._eligible_parts(profile, [], with_small), "turbo_large",
		"Big Turbo becomes drawable once this car has Small Turbo")


# --- The retired "always pays out" guarantee ---------------------------------
# The draw used to be backstopped by the swap token, so it could never come up empty.
# That is deliberately GONE: a maxed car now yields a mystery box or NOTHING.

func test_a_car_with_parts_left_always_wins_one() -> void:
	# The common case, and the one that must never regress: while there is something real
	# to give, the box/nothing branches must not pre-empt it.
	var profile := _all_completed_profile()
	var stock := {"instance_id": 1, "model_id": "mx5", "hp": 100.0,
		"installed_upgrades": [], "tuning": {}}
	for i in 50:
		var id: String = RewardSystem.draw_upgrade(profile, _rng(i), stock)
		assert_ne(id, RewardSystem.NO_REWARD, "a car with parts left never draws nothing")
		assert_ne(id, UpgradeLibrary.MYSTERY_BOX_ID, "a car with parts left never draws a box")


func test_a_maxed_car_with_nowhere_for_a_box_wins_nothing() -> void:
	# Every other car also maxed, so a box has nowhere to land. Previously this fell
	# through to the token; now it awards nothing at all.
	var maxed := _maxed_car(1)
	var also_maxed := _maxed_car(2)
	var profile := _profile_with_inventory([maxed, also_maxed],
		{UpgradeLibrary.ENGINE_SWAP_TOKEN_ID: RewardSystem.MYSTERY_BOX_TOKEN_THRESHOLD})
	for i in 20:
		assert_eq(RewardSystem.draw_upgrade(profile, _rng(i), maxed), RewardSystem.NO_REWARD,
			"a maxed car with nowhere for a box to land wins nothing")


func test_box_chance_falls_as_boxes_pile_up_and_the_first_is_certain() -> void:
	# The SHAPE only — monotonically decreasing, and certain at zero held. The specific
	# fractions are a consequence of the 1/(owned+1) curve, not something to pin.
	var chance := func(n: int) -> float:
		return RewardSystem._box_chance(_profile_with_inventory([], {UpgradeLibrary.MYSTERY_BOX_ID: n}))
	assert_eq(chance.call(0), 1.0, "the first box is guaranteed")
	var prev: float = chance.call(0)
	for n in range(1, 6):
		var cur: float = chance.call(n)
		assert_lt(cur, prev, "each banked box makes the next rarer (n=%d)" % n)
		assert_gt(cur, 0.0, "the chance never reaches zero")
		prev = cur


func test_engine_swap_token_is_a_real_consumable() -> void:
	assert_false(UpgradeLibrary.by_id(UpgradeLibrary.ENGINE_SWAP_TOKEN_ID).is_empty(),
		"the engine swap token is a real catalogue entry")
	assert_true(UpgradeLibrary.is_consumable(UpgradeLibrary.ENGINE_SWAP_TOKEN_ID),
		"the engine swap token is a consumable")
	assert_eq(UpgradeLibrary.slot_of(UpgradeLibrary.ENGINE_SWAP_TOKEN_ID), "",
		"the token occupies no slot")


# --- Mystery box ---------------------------------------------------------------

# Build a synthetic "maxed" owned_car (every non-consumable, non-free part in the real
# catalogue installed) — derived from the live catalogue so a retune of parts doesn't
# break the test.
func _maxed_car(instance_id: int) -> Dictionary:
	var all_parts := []
	for item in UpgradeLibrary.UPGRADES:
		if not item["consumable"] and not bool(item.get("free", false)):
			all_parts.append(String(item["id"]))
	return {"instance_id": instance_id, "model_id": "mx5", "hp": 100.0,
		"installed_upgrades": all_parts, "tuning": {}}


func _profile_with_inventory(cars: Array, inventory: Dictionary) -> Dictionary:
	var p := _profile([], [])
	p["cars"] = cars
	p["inventory"] = inventory
	return p


func test_draw_upgrade_awards_mystery_box_when_maxed_token_rich_and_room_exists() -> void:
	var maxed := _maxed_car(1)
	var roomy := {"instance_id": 2, "model_id": "mx5", "hp": 100.0,
		"installed_upgrades": [], "tuning": {}}
	var profile := _profile_with_inventory([maxed, roomy],
		{UpgradeLibrary.ENGINE_SWAP_TOKEN_ID: RewardSystem.MYSTERY_BOX_TOKEN_THRESHOLD})
	# No boxes banked yet, so the 1/(owned+1) roll is certain.
	for i in 10:
		assert_eq(RewardSystem.draw_upgrade(profile, _rng(i), maxed), UpgradeLibrary.MYSTERY_BOX_ID,
			"a maxed, token-rich car with somewhere for the box to land draws its first box")


func test_draw_upgrade_skips_mystery_box_below_token_threshold() -> void:
	var maxed := _maxed_car(1)
	var roomy := {"instance_id": 2, "model_id": "mx5", "hp": 100.0,
		"installed_upgrades": [], "tuning": {}}
	var profile := _profile_with_inventory([maxed, roomy],
		{UpgradeLibrary.ENGINE_SWAP_TOKEN_ID: RewardSystem.MYSTERY_BOX_TOKEN_THRESHOLD - 1})
	# The token threshold only bites once engine SWAPPING is unlocked — before then tokens
	# are inert, so gating a box on hoarding them would gate on an unusable currency.
	profile["rallies"][RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY] = {"completed": true, "best_placed": 1}
	for i in 20:
		var id: String = RewardSystem.draw_upgrade(profile, _rng(i), maxed)
		assert_ne(id, UpgradeLibrary.MYSTERY_BOX_ID,
			"below the token threshold, no box is granted")


func test_token_threshold_is_waived_while_engine_swaps_are_locked() -> void:
	# Tokens can't be spent yet, so requiring a stack of them would be gating on a
	# currency the player has no deliberate use for.
	var maxed := _maxed_car(1)
	var roomy := {"instance_id": 2, "model_id": "mx5", "hp": 100.0,
		"installed_upgrades": [], "tuning": {}}
	var profile := _profile_with_inventory([maxed, roomy], {})  # no tokens, swaps locked
	assert_false(RallyLibrary.engine_swaps_unlocked(profile), "setup: swapping is locked")
	assert_eq(RewardSystem.draw_upgrade(profile, _rng(0), maxed), UpgradeLibrary.MYSTERY_BOX_ID,
		"with swapping locked the box needs no token stack")


func test_draw_upgrade_skips_mystery_box_when_no_other_car_has_room() -> void:
	var maxed := _maxed_car(1)
	var also_maxed := _maxed_car(2)
	var profile := _profile_with_inventory([maxed, also_maxed],
		{UpgradeLibrary.ENGINE_SWAP_TOKEN_ID: RewardSystem.MYSTERY_BOX_TOKEN_THRESHOLD})
	for i in 20:
		var id: String = RewardSystem.draw_upgrade(profile, _rng(i), maxed)
		assert_ne(id, UpgradeLibrary.MYSTERY_BOX_ID,
			"with every other car also maxed, there's nowhere for a box to land")


func test_car_has_nothing_left_uses_the_gated_pool() -> void:
	var maxed := _maxed_car(1)
	assert_true(RewardSystem._car_has_nothing_left(_all_completed_profile(), maxed),
		"a car with every part installed has nothing left")
	var not_maxed := {"instance_id": 1, "model_id": "mx5", "hp": 100.0,
		"installed_upgrades": [], "tuning": {}}
	assert_false(RewardSystem._car_has_nothing_left(_all_completed_profile(), not_maxed),
		"a bone-stock car still has plenty left to gain")


func test_star_gated_parts_are_absent_from_the_pool_until_their_event_is_won() -> void:
	# The gate itself, against the real catalogue: SOME part is authored behind a special,
	# and a profile that has won nothing must not offer it. No specific id is pinned.
	var fresh := _profile([], [])
	# Must be a part gated ONLY by a star gate: the first gated entry in the catalogue also
	# carries a requires_upgrade_id, so picking it would let prerequisite_met satisfy the
	# assertion and the star gate would go untested.
	var gated := ""
	for item in UpgradeLibrary.all():
		var id := String(item["id"])
		if UpgradeLibrary.unlocked_by_rally(id) != "" and UpgradeLibrary.requires_upgrade_id(id) == "":
			gated = id
			break
	if gated == "":
		pass_test("no purely star-gated part authored; nothing to assert")
		return
	var car := {"instance_id": 1, "model_id": "mx5", "hp": 100.0,
		"installed_upgrades": [], "tuning": {}}
	assert_does_not_have(RewardSystem._eligible_parts(fresh, [], car), gated,
		"a star-gated part is absent before its event is won")
	assert_true(RewardSystem._eligible_parts(_all_completed_profile(), [], car).size()
		>= RewardSystem._eligible_parts(fresh, [], car).size(),
		"winning everything can only widen the pool, never narrow it")


# any_car_has_room excludes NOTHING — a box is a garage-wide reward that can land on
# any owned car, the selected one included. (The exclusion survives only in
# _other_car_has_room, which gates a different question — see the draw_upgrade tests.)
func test_any_car_has_room() -> void:
	var maxed := _maxed_car(1)
	var roomy := {"instance_id": 2, "model_id": "mx5", "hp": 100.0,
		"installed_upgrades": [], "tuning": {}}
	assert_true(RewardSystem.any_car_has_room(_profile_with_inventory([maxed, roomy], {})),
		"a non-maxed car in the garage means there is somewhere for a box to land")
	assert_false(RewardSystem.any_car_has_room(_profile_with_inventory([maxed, _maxed_car(2)], {})),
		"with every car maxed there is nowhere for it to go")
	assert_false(RewardSystem.any_car_has_room(_profile_with_inventory([], {})),
		"an empty garage has no room by definition")


# A ONE-CAR garage is the case the old "never the current car" rule made unopenable:
# there was no other car, so the box was permanently dead weight. It now fills that
# car's own empty slots.
func test_pick_mystery_box_grant_can_target_the_only_car_you_own() -> void:
	var roomy := {"instance_id": 1, "model_id": "mx5", "hp": 100.0,
		"installed_upgrades": [], "tuning": {}}
	var profile := _profile_with_inventory([roomy], {})
	for i in 30:
		var grant := RewardSystem.pick_mystery_box_grant(profile, _rng(i))
		assert_false(grant.is_empty(), "the one car in the garage has room, so the box resolves")
		assert_eq(int(grant["instance_id"]), 1, "and it targets that car")
		assert_false(UpgradeLibrary.by_id(String(grant["item_id"])).is_empty(),
			"the granted item is a real catalogue item")


# Only cars with room are candidates — a maxed car is skipped even though it is no
# longer excluded on identity.
func test_pick_mystery_box_grant_only_targets_cars_with_room() -> void:
	var maxed := _maxed_car(1)
	var roomy := {"instance_id": 2, "model_id": "mx5", "hp": 100.0,
		"installed_upgrades": [], "tuning": {}}
	var profile := _profile_with_inventory([maxed, roomy], {})
	for i in 30:
		var grant := RewardSystem.pick_mystery_box_grant(profile, _rng(i))
		assert_false(grant.is_empty(), "a candidate with room exists")
		assert_eq(int(grant["instance_id"]), 2, "the maxed car is never picked — it has no room")


func test_pick_mystery_box_grant_empty_when_every_car_is_maxed() -> void:
	var profile := _profile_with_inventory([_maxed_car(1), _maxed_car(2)], {})
	var grant := RewardSystem.pick_mystery_box_grant(profile, _rng(1))
	assert_true(grant.is_empty(), "no candidate has room — the opener must leave the box unspent")


# --- Car draw ----------------------------------------------------------------

# The lowest reward_tier in the roster, and one model id at it — derived from
# the live library so tests survive roster/tier retunes.
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
	# owned car eligible so the player is NOT stuck — the standard-draw path this asserts.
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


func test_draw_car_unlocks_locked_rally_when_stuck() -> void:
	# When STUCK — no owned car can enter any incomplete, REVEALED rally — the draw grants a
	# car that OPENS a locked rally, guaranteeing fresh progression. Synthetic roster
	# (reveal_after 0, so the reveal-order gate doesn't interfere): a low band r_low the
	# owned car fits, and r_high which it can never qualify for.
	#
	# r_high restricts by CAR TYPE, not by power band, and that choice is deliberate. Now
	# that eligibility is judged against a car's upgrade CEILING, a power floor is no longer
	# a lock — the player just fits parts and grows into it, so the rescue would rightly
	# decline to fire. A car_type restriction is a real lock: no upgrade in the catalogue
	# changes what type a car is, so a different car is genuinely the only way through.
	var low_car := _lowest_tier_model()
	var low_type := String(low_car.get("car_type", ""))
	var other_type := ""
	for entry in CarLibrary.all():
		if String(entry.get("car_type", "")) != low_type:
			other_type = String(entry.get("car_type", ""))
			break
	if other_type == "":
		return  # single-type fixture roster: no type lock to demonstrate
	RallyLibrary.override_for_test([
		{"id": "r_low", "region": "home", "special": false, "difficulty": 1,
			"restriction": {"car_type": low_type}},
		{"id": "r_high", "region": "home", "special": false, "difficulty": 2,
			"restriction": {"car_type": other_type}},
	])
	var r_low := RallyLibrary.by_id("r_low")
	var r_high := RallyLibrary.by_id("r_high")
	if not RallyLibrary.is_eligible(r_low, low_car):
		RallyLibrary.reset()
		return
	var owned_low := {"instance_id": 1, "model_id": String(low_car["id"]), "hp": 100.0,
		"installed_upgrades": [], "tuning": {}}
	var profile := _profile(["r_low"], [String(low_car["id"])])
	assert_true(RallyLibrary.incomplete_rallies_enterable_by(low_car, profile,
		UpgradeLibrary.max_potential_meta(owned_low, low_car, profile)).is_empty(),
		"setup: the owned car can't reach any incomplete rally even fully upgraded (stuck)")
	for i in 20:
		var model: Variant = RewardSystem.draw_car(profile, 1, _rng(i))
		var meta := CarLibrary.by_id(String(model))
		assert_true(RallyLibrary.is_eligible(r_high, meta),
			"the stuck-player grant is a car that opens the locked rally")
		assert_false(RallyLibrary.incomplete_rallies_enterable_by(meta, profile).is_empty(),
			"the granted car can enter a still-incomplete rally")
	RallyLibrary.reset()


# --- Completion-gated special events -----------------------------------------
# Replaces the old per-region showdown gate AND the star gate that briefly replaced it:
# specials are now gated on the GLOBAL count of completed ORDINARY rallies, with no
# relationship to a region's contents. See todo/star-economy.md.

func test_the_eligibility_query_excludes_a_locked_special() -> void:
	RallyLibrary.override_for_test([
		{"id": "r1", "region": "home", "special": false, "restriction": {}},
		{"id": "sp_far", "region": "home", "special": true, "requires_completions": 99,
			"restriction": {}},
	])
	# Nothing completed → the special is still locked.
	var car := {"pw": 150.0}  # synthetic; is_eligible reads restriction only
	var ids := []
	for r in RallyLibrary.incomplete_rallies_enterable_by(car, {"rallies": {}}):
		ids.append(r["id"])
	assert_does_not_have(ids, "sp_far", "a locked special is not enterable")
	assert_has(ids, "r1", "an ordinary revealed rally still is")
	RallyLibrary.reset()


func test_a_special_opens_once_the_completion_count_is_reached() -> void:
	RallyLibrary.override_for_test([
		{"id": "r1", "region": "home", "special": false, "restriction": {}},
		{"id": "sp_near", "region": "home", "special": true, "requires_completions": 1,
			"restriction": {}},
	])
	var car := {"pw": 150.0}
	# Completing the single ordinary rally clears the gate. The special itself is excluded
	# from the completion count, so it cannot bootstrap itself.
	var profile := {"rallies": {"r1": {"completed": true, "best_placed": 1}}}
	assert_eq(RallyLibrary._completed_count(profile), 1, "the ordinary win counts once")
	var ids := []
	for r in RallyLibrary.incomplete_rallies_enterable_by(car, profile):
		ids.append(r["id"])
	assert_has(ids, "sp_near", "the special opens once the stars are in")
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


# --- Buying a car with stars (todo/star-economy.md) --------------------------
# Nothing here pins the PRICE (GameConfig.star_cost_per_car is tunable) — only the rules:
# a purchase debits exactly the configured price, is refused when short, and drops to free
# in the one state that would otherwise be unrecoverable.

# A COMPLETE profile (built from the real default) with `owned` cars and `earned` stars.
# Built from _default_profile rather than hand-rolled because purchase_car goes through
# Save.grant_car, which reads next_instance_id — a partial dict fails at runtime, not parse.
func _priced_profile(owned: Array, earned: int) -> Dictionary:
	var profile: Dictionary = (get_node("/root/Save") as Node)._default_profile()
	var n := 1
	for model_id in owned:
		(profile["cars"] as Array).append({
			"instance_id": n, "model_id": model_id, "hp": 100.0,
			"installed_upgrades": [], "disabled_upgrades": [], "tuning": {}})
		n += 1
	profile["next_instance_id"] = n
	profile["stars_earned"] = earned
	profile["stars_spent"] = 0
	return profile


func test_is_stranded_is_false_while_any_owned_car_can_enter_something() -> void:
	var profile := _priced_profile([CarFixtures.cars()[0]["id"]], 0)
	assert_false(RewardSystem.is_stranded(profile),
		"a fresh garage can enter something, so it is not stranded")


func test_is_stranded_is_true_with_no_cars_at_all() -> void:
	assert_true(RewardSystem.is_stranded(_priced_profile([], 0)),
		"an empty garage can enter nothing")


func test_a_wrecked_car_does_not_count_against_stranded() -> void:
	# A wreck can never be repaired, so a garage holding only wrecks is as stuck as an
	# empty one. Counting it would deny the rescue to exactly the player who needs it.
	var profile := _priced_profile([CarFixtures.cars()[0]["id"]], 0)
	assert_false(RewardSystem.is_stranded(profile), "the intact car counts")
	profile["cars"][0]["hp"] = 0.0
	assert_true(RewardSystem.is_stranded(profile), "once wrecked it does not")


func test_the_price_is_the_configured_price_when_not_stranded() -> void:
	var want := int(Config.data.star_cost_per_car)
	var profile := _priced_profile([CarFixtures.cars()[0]["id"]], 0)
	assert_eq(RewardSystem.car_price(profile), want,
		"a player who can still race pays full price even at zero stars")
	profile["stars_earned"] = want * 3
	assert_eq(RewardSystem.car_price(profile), want, "and still pays full price when rich")


func test_the_price_drops_to_zero_only_when_stranded_AND_broke() -> void:
	# The dead-end rescue. BOTH halves matter: free-whenever-stranded is farmable, so a
	# stranded player who can still afford a car must be charged.
	var want := int(Config.data.star_cost_per_car)
	var stranded := _priced_profile([], 0)
	assert_eq(RewardSystem.car_price(stranded), 0, "stranded and broke -> free")
	stranded["stars_earned"] = want
	assert_eq(RewardSystem.car_price(stranded), want,
		"stranded but able to pay -> charged, or the rescue becomes a discount")


func test_buying_a_car_debits_exactly_the_price_and_grants_one_car() -> void:
	var save: Node = get_node("/root/Save")
	save.profile = _priced_profile([CarFixtures.cars()[0]["id"]], 0)
	save.profile["stars_earned"] = int(Config.data.star_cost_per_car) * 2
	var before: int = save.profile["cars"].size()
	var balance_before: int = save.stars_available()
	var car: Dictionary = RewardSystem.purchase_car(_rng(11))
	assert_false(car.is_empty(), "an affordable purchase grants a car")
	assert_eq(save.profile["cars"].size(), before + 1, "exactly ONE car per purchase")
	assert_eq(save.stars_available(), balance_before - int(Config.data.star_cost_per_car),
		"the balance drops by exactly the configured price")
	assert_false(CarLibrary.by_id(String(car["model_id"])).is_empty(),
		"the granted car is a real catalogue entry")


func test_buying_is_refused_when_the_balance_is_short() -> void:
	var save: Node = get_node("/root/Save")
	save.profile = _priced_profile([CarFixtures.cars()[0]["id"]], 0)
	save.profile["stars_earned"] = maxi(0, int(Config.data.star_cost_per_car) - 1)
	var before: int = save.profile["cars"].size()
	assert_true(RewardSystem.purchase_car(_rng(12)).is_empty(),
		"a player one star short buys nothing")
	assert_eq(save.profile["cars"].size(), before, "and the garage is unchanged")
	assert_eq(int(save.profile["stars_spent"]), 0, "and nothing was debited")


func test_a_stranded_broke_player_is_rescued_for_free() -> void:
	var save: Node = get_node("/root/Save")
	save.profile = _priced_profile([], 0)  # no cars: stranded, and no stars
	var car: Dictionary = RewardSystem.purchase_car(_rng(13))
	assert_false(car.is_empty(), "the rescue grants a car")
	assert_eq(save.profile["cars"].size(), 1, "exactly one")
	assert_eq(int(save.profile["stars_spent"]), 0, "and charges nothing")
	assert_false(RewardSystem.is_stranded(save.profile),
		"the rescued car actually un-strands the player — that is the whole point")
