extends GutTest
# The reward draw policy (RewardSystem): the tier clamp, the per-event upgrade
# draw, and the per-rally car draw with its prefer-un-owned + anti-soft-lock
# behaviour. Pure functions, driven with an injected seeded RNG. See
# todo/reward-system.md.

const CarFixtures = preload("res://tests/headless/car_fixtures.gd")


func before_each() -> void:
	CarFixtures.install()


func after_each() -> void:
	CarFixtures.restore()


func _rng(seed_value: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed_value
	return r


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

func test_draw_upgrade_returns_parts_at_target_tier_with_rare_repair() -> void:
	var profile := _profile(["shakedown", "coastal_sprint"], [])  # ceiling 2
	var repair := 0
	var parts := 0
	for i in 300:
		var id: String = RewardSystem.draw_upgrade(2, profile, _rng(i))
		assert_false(UpgradeLibrary.by_id(id).is_empty(), "draw returns a real catalogue item")
		if id == UpgradeLibrary.REPAIR_KIT_ID:
			repair += 1
		else:
			parts += 1
			assert_lte(int(UpgradeLibrary.by_id(id)["tier"]), 2, "drawn part never exceeds the target tier")
	assert_gt(repair, 0, "the repair kit does appear")
	assert_gt(parts, repair, "parts dominate the pool over the rare repair kit")


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


func test_draw_upgrade_falls_back_to_repair_kit_when_car_has_everything() -> void:
	# With EVERY non-consumable part already on the driven car, the only thing
	# left to award is the repair kit — the draw still always pays out.
	var all_parts := []
	for item in UpgradeLibrary.UPGRADES:
		if not item["consumable"]:
			all_parts.append(String(item["id"]))
	var driven := {"instance_id": 1, "model_id": "mx5", "hp": 100.0,
		"installed_upgrades": all_parts, "tuning": {}}
	for i in 20:
		var id: String = RewardSystem.draw_upgrade(4, _profile([], []), _rng(i), driven)
		assert_eq(id, UpgradeLibrary.REPAIR_KIT_ID,
			"with every part fitted, the draw falls back to the repair kit")


# --- Car draw ----------------------------------------------------------------

# The lowest reward_tier in the roster, and one model id at it — derived from
# the live library so tests survive roster/tier retunes.
func _lowest_tier_model() -> Dictionary:
	var best: Dictionary = {}
	for entry in CarLibrary.all():
		if best.is_empty() or int(entry["reward_tier"]) < int(best["reward_tier"]):
			best = entry
	return best


func test_draw_car_never_exceeds_garage_tier() -> void:
	# Own only a lowest-tier car (everything incomplete → not stuck, standard
	# path): the draw pays at or below the garage tier, never off the beaten
	# rally's difficulty.
	var starter := _lowest_tier_model()
	var profile := _profile([], [String(starter["id"])])
	var ceiling := RewardSystem.garage_tier(profile)
	for i in 30:
		var model: Variant = RewardSystem.draw_car(profile, _rng(i))
		var meta := CarLibrary.by_id(String(model))
		assert_false(meta.is_empty(), "draw returns a real catalogue car")
		assert_lte(int(meta["reward_tier"]), ceiling,
			"a drawn car never exceeds the highest tier already in the garage")


func test_draw_car_prefers_unowned_within_garage_tier() -> void:
	# Own every model at or below the garage tier EXCEPT one target: the draw
	# must always return that remaining un-owned car (proves the preference —
	# owned alternatives exist yet are never picked).
	var starter := _lowest_tier_model()
	var seed_profile := _profile([], [String(starter["id"])])
	var pool: Array = RewardSystem._cars_at_or_below_tier(RewardSystem.garage_tier(seed_profile))
	var target := ""
	for id in pool:
		if String(id) != String(starter["id"]):
			target = String(id)
			break
	if target == "":
		return  # degenerate 1-car tier; no owned/un-owned distinction to prove
	var owned: Array = []
	for id in pool:
		if String(id) != target:
			owned.append(String(id))
	var profile := _profile([], owned)
	for i in 30:
		assert_eq(RewardSystem.draw_car(profile, _rng(i)), target,
			"draws the un-owned car at/below the garage tier, never an owned one")


func test_draw_car_grants_duplicate_when_everything_owned() -> void:
	# Own the whole roster: no un-owned candidate remains anywhere, so the draw
	# still grants (guaranteed reward) — a duplicate of an owned model.
	var owned: Array = []
	for entry in CarLibrary.all():
		owned.append(String(entry["id"]))
	var profile := _profile([], owned)
	var model: Variant = RewardSystem.draw_car(profile, _rng(1))
	assert_true(owned.has(model), "with every car owned, draws a duplicate of an owned one")


func test_draw_car_always_grants_even_with_everything_completed() -> void:
	# Every rally completed and nothing owned — the old policy returned null
	# here; the new one must still pay a real car (guaranteed reward).
	var all_ids := []
	for rally in RallyLibrary.RALLIES:
		all_ids.append(rally["id"])
	var profile := _profile(all_ids, [])
	var model: Variant = RewardSystem.draw_car(profile, _rng(1))
	assert_not_null(model, "a car is always granted, even post-completion")
	assert_false(CarLibrary.by_id(String(model)).is_empty(), "and it is a catalogue car")


func test_draw_car_unlocks_lowest_difficulty_rally_when_stuck() -> void:
	# Build a STUCK profile from the live library: own one car, complete every
	# rally it can enter, leave the rest (which it cannot enter) locked. The
	# draw must then grant a car eligible for one of the LOWEST-difficulty
	# locked rallies — guaranteeing a new rally opens up.
	var stuck_car: Dictionary = {}
	for entry in CarLibrary.all():
		for rally in RallyLibrary.RALLIES:
			if not rally["showdown"] and not RallyLibrary.is_eligible(rally, entry):
				stuck_car = entry
				break
		if not stuck_car.is_empty():
			break
	if stuck_car.is_empty():
		return  # roster/restrictions currently admit every car everywhere — nothing to test
	var completed := []
	for rally in RallyLibrary.RALLIES:
		if not rally["showdown"] and RallyLibrary.is_eligible(rally, stuck_car):
			completed.append(rally["id"])
	var profile := _profile(completed, [String(stuck_car["id"])])
	# Sanity: the setup really is stuck (no incomplete rally enterable).
	assert_true(RallyLibrary.incomplete_rallies_enterable_by(stuck_car, profile).is_empty(),
		"setup: the owned car has no incomplete rally left to enter")
	# The lowest difficulty among the locked (incomplete, showdown-gated) rallies
	# that at least one catalogue car can actually enter — a locked rally whose
	# restriction band no car fits can't be opened by ANY grant, so the draw steps
	# past it to the next difficulty up rather than giving up (anti-soft-lock).
	var sd := RallyLibrary.showdown_unlocked(profile)
	var lowest := 0
	for rally in RallyLibrary.RALLIES:
		if completed.has(rally["id"]) or (rally["showdown"] and not sd):
			continue
		var any_eligible := false
		for entry in CarLibrary.all():
			if RallyLibrary.is_eligible(rally, entry):
				any_eligible = true
				break
		if not any_eligible:
			continue
		var d := int(rally["difficulty"])
		lowest = d if lowest == 0 else mini(lowest, d)
	if lowest == 0:
		return  # no locked rally admits any car at all — nothing a grant could open
	for i in 20:
		var model: Variant = RewardSystem.draw_car(profile, _rng(i))
		var meta := CarLibrary.by_id(String(model))
		var opens_lowest := false
		for rally in RallyLibrary.RALLIES:
			if completed.has(rally["id"]) or (rally["showdown"] and not sd):
				continue
			if int(rally["difficulty"]) == lowest and RallyLibrary.is_eligible(rally, meta):
				opens_lowest = true
				break
		assert_true(opens_lowest,
			"the stuck-player grant enters a locked rally at the LOWEST openable locked difficulty")
		# And the grant really re-opens progression.
		assert_false(RallyLibrary.incomplete_rallies_enterable_by(meta, profile).is_empty(),
			"the granted car can enter a still-incomplete rally")
