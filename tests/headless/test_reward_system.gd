extends GutTest
# The reward draw policy (RewardSystem): the tier clamp, the per-event upgrade
# draw, and the per-rally car draw with its prefer-un-owned + anti-soft-lock
# behaviour. Pure functions, driven with an injected seeded RNG. See
# todo/reward-system.md.


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


# --- Car draw ----------------------------------------------------------------

func test_draw_car_prefers_unowned_at_tier() -> void:
	# Completed 2 open rallies → ceiling 2. Derive the eligible tier-2 cars from the
	# library, own every one except a target, and assert the draw always returns that
	# remaining un-owned car — robust to roster changes (no hardcoded model id). When
	# >1 car is eligible this also proves the unowned PREFERENCE (an owned alternative
	# exists yet is never picked).
	var completed := ["shakedown", "coastal_sprint"]
	var eligible: Array = RewardSystem._eligible_candidates_at_tier(2, _profile(completed, []))
	assert_false(eligible.is_empty(), "tier 2 has at least one eligible reward car to draw")
	var target: String = eligible[0]
	var owned: Array = eligible.slice(1)  # own every eligible tier-2 car but the target
	var profile := _profile(completed, owned)
	for i in 30:
		var model: Variant = RewardSystem.draw_car(2, profile, _rng(i))
		assert_eq(model, target, "draws the un-owned tier-2 car, never an owned one")


func test_draw_car_grants_duplicate_when_all_eligible_owned() -> void:
	# Own every eligible car at tier <= target so no unowned candidate remains; the
	# draw must then fall back to granting a duplicate of an owned car. Derives the
	# eligible set from the live library, so it's robust to roster / tier changes.
	var completed := ["shakedown", "coastal_sprint"]
	var eligible := {}
	for t in [1, 2]:
		for id in RewardSystem._eligible_candidates_at_tier(t, _profile(completed, [])):
			eligible[id] = true
	assert_false(eligible.is_empty(), "there are eligible reward cars to own")
	var owned: Array = eligible.keys()
	var profile := _profile(completed, owned)
	var model: Variant = RewardSystem.draw_car(2, profile, _rng(1))
	assert_true(owned.has(model), "with all eligible cars owned, draws a duplicate of an owned one")


func test_draw_car_only_returns_eligible_cars() -> void:
	var profile := _profile(["shakedown"], [])  # ceiling 1 → tier-1 car (MX-5)
	for i in 20:
		var model: Variant = RewardSystem.draw_car(1, profile, _rng(i))
		assert_not_null(model, "a tier-1 car is available early")
		var enterable := RallyLibrary.incomplete_rallies_enterable_by(
			CarLibrary.by_id(model), profile)
		assert_false(enterable.is_empty(), "granted car is eligible for an incomplete rally")


func test_draw_car_returns_null_when_nothing_eligible() -> void:
	# Every rally completed → no incomplete rally for any car to be eligible for,
	# so the anti-soft-lock filter empties every tier and draw_car declines.
	var all_ids := []
	for rally in RallyLibrary.RALLIES:
		all_ids.append(rally["id"])
	var profile := _profile(all_ids, [])
	assert_null(RewardSystem.draw_car(3, profile, _rng(1)),
		"no eligible car anywhere → draw_car returns null (caller grants an upgrade)")
