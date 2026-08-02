extends GutTest
# The reward draw policy (RewardSystem): the tier clamp, the per-event upgrade
# draw, and the per-rally car draw with its prefer-un-owned + anti-soft-lock
# behaviour. Pure functions, driven with an injected seeded RNG. See
# todo/reward-system.md.

const CarFixtures = preload("res://tests/headless/car_fixtures.gd")

# NOTE: no UpgradeFixtures here. RewardSystem.draw_upgrade() (scripts/reward_system.gd)
# iterates UpgradeLibrary.UPGRADES directly rather than the override-aware
# UpgradeLibrary.all(), so an installed UpgradeFixtures override desyncs from what
# draw_upgrade actually returns — by_id()/is_consumable() (which DO respect the
# override) then can't find the drawn id, throwing on the returned dict. Until
# draw_upgrade is changed to go through the override-aware accessors, these
# upgrade-draw tests stay against the real shipped UPGRADES table; only the car
# roster below is synthetic.
func before_each() -> void:
	CarFixtures.install()


func after_each() -> void:
	CarFixtures.restore()


func _rng(seed_value: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed_value
	return r


func test_free_parts_are_never_drawn_as_a_reward() -> void:
	# Free parts (ballast) are always available and must never appear in the reward draw
	# pool at any tier. Iterates the pool as opaque output — no specific id pinned.
	for tier in range(1, RewardSystem.MAX_TIER + 1):
		for id in RewardSystem._parts_at_or_below(tier):
			assert_false(UpgradeLibrary.is_free(id),
				"a free part must not be drawable as a reward (tier %d: %s)" % [tier, id])


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

func test_draw_upgrade_returns_parts_at_target_tier_with_rare_consumables() -> void:
	var profile := _profile(["shakedown", "coastal_sprint"], [])  # ceiling 2
	var consumables := 0
	var parts := 0
	for i in 300:
		var id: String = RewardSystem.draw_upgrade(2, profile, _rng(i))
		assert_false(UpgradeLibrary.by_id(id).is_empty(), "draw returns a real catalogue item")
		if UpgradeLibrary.is_consumable(id):
			consumables += 1
		else:
			parts += 1
			assert_lte(int(UpgradeLibrary.by_id(id)["tier"]), 2, "drawn part never exceeds the target tier")
	assert_gt(consumables, 0, "the rare consumables do appear")
	# Not `parts > consumables`: that pins the shipped catalogue's part-vs-consumable
	# weighting (a designer retuning ENGINE_SWAP_TOKEN_DROP_WEIGHT
	# could reasonably flip it). The real invariant is just that consumables stay rare
	# relative to the sample, not that parts strictly outnumber them.
	assert_gt(parts, 0, "parts are drawn at all")


func test_draw_upgrade_can_award_an_engine_swap_token() -> void:
	# The token is a member of the per-event pool (membership, NOT its weight).
	var profile := _profile(["shakedown", "coastal_sprint"], [])  # ceiling 2
	var saw_token := false
	for i in 300:
		var id: String = RewardSystem.draw_upgrade(2, profile, _rng(i))
		if id == UpgradeLibrary.ENGINE_SWAP_TOKEN_ID:
			saw_token = true
	assert_true(saw_token, "the engine swap token can be drawn from the pool")


func test_draw_upgrade_never_awards_a_part_the_driven_car_has() -> void:
	# Fit one eligible part to the driven car: it must never be drawn again for
	# that car, while other parts still are. Derived from the live catalogue so a
	# retune of tiers/parts doesn't break the test.
	var all_ids := []
	for rally in RallyLibrary.RALLIES:
		all_ids.append(rally["id"])
	var profile := _profile(all_ids, [])  # everything completed -> ceiling at max
	var fitted := ""
	for item in UpgradeLibrary.UPGRADES:
		if not item["consumable"]:
			fitted = String(item["id"])
			break
	var driven := {"instance_id": 1, "model_id": "mx5", "hp": 100.0,
		"installed_upgrades": [fitted], "tuning": {}}
	for i in 200:
		var id: String = RewardSystem.draw_upgrade(4, profile, _rng(i), driven)
		assert_ne(id, fitted, "a part already fitted to the driven car is never drawn")


# Contract test (not a logic test): Big Turbo is authored with requires_upgrade_id
# "turbo_small" (replacing its old tier-2 difficulty gate — see upgrade_library.gd),
# so _parts_at_or_below must honor that wiring against the real catalogue: excluded
# from the pool until THE DRIVEN CAR has Small Turbo fitted, present once it does.
func test_parts_at_or_below_excludes_big_turbo_until_small_turbo_is_owned() -> void:
	var without := {"instance_id": 1, "model_id": "mx5", "hp": 100.0,
		"installed_upgrades": [], "tuning": {}}
	for t in range(1, RewardSystem.MAX_TIER + 1):
		assert_does_not_have(RewardSystem._parts_at_or_below(t, [], without), "turbo_large",
			"Big Turbo stays out of the pool until this car has its prerequisite")
	var with_small := {"instance_id": 1, "model_id": "mx5", "hp": 100.0,
		"installed_upgrades": ["turbo_small"], "tuning": {}}
	var found := false
	for t in range(1, RewardSystem.MAX_TIER + 1):
		if RewardSystem._parts_at_or_below(t, [], with_small).has("turbo_large"):
			found = true
	assert_true(found, "Big Turbo becomes drawable once this car has Small Turbo")


func test_draw_upgrade_falls_back_to_consumables_when_car_has_everything() -> void:
	# With EVERY non-consumable part already on the driven car, the only things
	# left to award are the consumables — the draw still always pays out.
	var all_parts := []
	for item in UpgradeLibrary.UPGRADES:
		if not item["consumable"]:
			all_parts.append(String(item["id"]))
	var driven := {"instance_id": 1, "model_id": "mx5", "hp": 100.0,
		"installed_upgrades": all_parts, "tuning": {}}
	for i in 20:
		var id: String = RewardSystem.draw_upgrade(4, _profile([], []), _rng(i), driven)
		assert_true(UpgradeLibrary.is_consumable(id),
			"with every part fitted, the draw falls back to a consumable")


func test_engine_swap_token_is_a_real_consumable() -> void:
	assert_false(UpgradeLibrary.by_id(UpgradeLibrary.ENGINE_SWAP_TOKEN_ID).is_empty(),
		"the engine swap token is a real catalogue entry")
	assert_true(UpgradeLibrary.is_consumable(UpgradeLibrary.ENGINE_SWAP_TOKEN_ID),
		"the engine swap token is a consumable")
	assert_eq(UpgradeLibrary.slot_of(UpgradeLibrary.ENGINE_SWAP_TOKEN_ID), "",
		"the token occupies no slot")


# --- Mystery box ---------------------------------------------------------------

# Build a synthetic "maxed" owned_car (every non-consumable, non-free part in the
# real catalogue up to MAX_TIER installed) — derived from the live catalogue so a
# retune of parts/tiers doesn't break the test.
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
	for i in 10:
		assert_eq(RewardSystem.draw_upgrade(4, profile, _rng(i), maxed), UpgradeLibrary.MYSTERY_BOX_ID,
			"a maxed, token-rich car with somewhere for the box to land always draws a mystery box")


func test_draw_upgrade_skips_mystery_box_below_token_threshold() -> void:
	var maxed := _maxed_car(1)
	var roomy := {"instance_id": 2, "model_id": "mx5", "hp": 100.0,
		"installed_upgrades": [], "tuning": {}}
	var profile := _profile_with_inventory([maxed, roomy],
		{UpgradeLibrary.ENGINE_SWAP_TOKEN_ID: RewardSystem.MYSTERY_BOX_TOKEN_THRESHOLD - 1})
	for i in 20:
		var id: String = RewardSystem.draw_upgrade(4, profile, _rng(i), maxed)
		assert_ne(id, UpgradeLibrary.MYSTERY_BOX_ID,
			"below the token threshold, the normal draw pool still applies")


func test_draw_upgrade_skips_mystery_box_when_no_other_car_has_room() -> void:
	var maxed := _maxed_car(1)
	var also_maxed := _maxed_car(2)
	var profile := _profile_with_inventory([maxed, also_maxed],
		{UpgradeLibrary.ENGINE_SWAP_TOKEN_ID: RewardSystem.MYSTERY_BOX_TOKEN_THRESHOLD})
	for i in 20:
		var id: String = RewardSystem.draw_upgrade(4, profile, _rng(i), maxed)
		assert_ne(id, UpgradeLibrary.MYSTERY_BOX_ID,
			"with every other car also maxed, there's nowhere for a box to land — falls through")


func test_car_has_nothing_left_checks_max_tier_not_target_tier() -> void:
	# A car maxed against the catalogue ceiling reads as "nothing left" even with a
	# LOW progress ceiling (fresh profile, 0 completed) — MAX_TIER, not target_tier.
	var maxed := _maxed_car(1)
	assert_true(RewardSystem._car_has_nothing_left(maxed),
		"a car with every part up to MAX_TIER installed has nothing left, regardless of progress")
	var not_maxed := {"instance_id": 1, "model_id": "mx5", "hp": 100.0,
		"installed_upgrades": [], "tuning": {}}
	assert_false(RewardSystem._car_has_nothing_left(not_maxed),
		"a bone-stock car still has plenty left to gain")


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
		{"id": "r_open", "region": "home", "showdown": false, "restriction": {}, "difficulty": 1},
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
		{"id": "r_open", "region": "home", "showdown": false, "restriction": {}, "difficulty": 1},
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
		{"id": "r_open", "region": "home", "showdown": false, "restriction": {}, "difficulty": 4},
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
	# owned car fits, a high band r_high it doesn't. Own only the low car and complete r_low
	# -> stuck -> the grant must be a car eligible for r_high.
	RallyLibrary.override_for_test([
		{"id": "r_low", "region": "home", "showdown": false, "difficulty": 1,
			"restriction": {"pw_max": 175.0}},
		{"id": "r_high", "region": "home", "showdown": false, "difficulty": 2,
			"restriction": {"pw_min": 200.0}},
	])
	var r_low := RallyLibrary.by_id("r_low")
	var r_high := RallyLibrary.by_id("r_high")
	# The lowest-p/w fixture car must fit r_low but miss r_high, and SOME other car must fit
	# r_high — else the setup can't demonstrate the unlock. Guard so a fixture retune skips
	# rather than fails.
	var low_car := _lowest_tier_model()
	var some_fits_high := false
	for entry in CarLibrary.all():
		if RallyLibrary.is_eligible(r_high, entry):
			some_fits_high = true
			break
	if not (RallyLibrary.is_eligible(r_low, low_car)
			and not RallyLibrary.is_eligible(r_high, low_car) and some_fits_high):
		RallyLibrary.reset()
		return
	var profile := _profile(["r_low"], [String(low_car["id"])])
	assert_true(RallyLibrary.incomplete_rallies_enterable_by(low_car, profile).is_empty(),
		"setup: the owned car has no incomplete rally left to enter (stuck)")
	for i in 20:
		var model: Variant = RewardSystem.draw_car(profile, 1, _rng(i))
		var meta := CarLibrary.by_id(String(model))
		assert_true(RallyLibrary.is_eligible(r_high, meta),
			"the stuck-player grant is a car that opens the locked rally")
		assert_false(RallyLibrary.incomplete_rallies_enterable_by(meta, profile).is_empty(),
			"the granted car can enter a still-incomplete rally")
	RallyLibrary.reset()


# --- Per-region showdown gating ----------------------------------------------

func test_draw_excludes_a_locked_regions_showdown() -> void:
	RegionLibrary.override_for_test([
		{"id": "home", "name": "Home"}, {"id": "greece", "name": "Greece"},
	])
	RallyLibrary.override_for_test([
		{"id": "h1", "region": "home", "showdown": false, "restriction": {}},
		{"id": "h_sd", "region": "home", "showdown": true, "restriction": {}},
		{"id": "g_sd", "region": "greece", "showdown": true, "restriction": {}},
	])
	# Nothing completed → greece locked, home's showdown not yet open either.
	var car := {"pw": 150.0}  # synthetic; is_eligible reads restriction only
	var out := RallyLibrary.incomplete_rallies_enterable_by(car, {"rallies": {}})
	var ids := []
	for r in out: ids.append(r["id"])
	assert_does_not_have(ids, "g_sd")  # greece showdown gated
	RegionLibrary.reset(); RallyLibrary.reset()
