extends GutTest
# The reward draw policy (RewardSystem): the tier clamp, the per-event upgrade
# draw, and the per-rally car draw with its prefer-un-owned + anti-soft-lock
# behaviour. Pure functions, driven with an injected seeded RNG. See
# todo/reward-system.md.

const RewardSystem = preload("res://scripts/reward_system.gd")
const RallyLibrary = preload("res://scripts/rally_library.gd")
const UpgradeLibrary = preload("res://scripts/upgrade_library.gd")
const CarLibrary = preload("res://scripts/car_library.gd")


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
			"immortal": false, "installed_upgrades": [], "tuning": {}})
		n += 1
	return {"rallies": rallies, "cars": cars}


# --- Tier clamp --------------------------------------------------------------

func test_tier_ceiling_is_monotonic_and_clamped() -> void:
	var prev := 0
	for c in range(0, 20):
		var ceil := RewardSystem.tier_ceiling(c)
		assert_gte(ceil, prev, "ceiling never decreases as completion rises")
		assert_lte(ceil, RewardSystem.MAX_TIER, "ceiling never exceeds MAX_TIER")
		assert_gte(ceil, 1, "ceiling is at least 1")
		prev = ceil


func test_target_tier_never_exceeds_ceiling() -> void:
	# Fresh profile (0 completed) → ceiling 1, so even a hard rally clamps to 1.
	var fresh := _profile([], [])
	assert_eq(RewardSystem.target_tier(4, fresh), 1, "early-game ceiling clamps a tier-4 rally to 1")
	# With enough progress the ceiling rises and the rally difficulty shows through.
	var progressed := _profile(["shakedown", "coastal_sprint"], [])  # completed 2 → ceiling 2
	assert_eq(RewardSystem.target_tier(2, progressed), 2, "tier-2 rally pays tier 2 once unlocked")
	assert_eq(RewardSystem.target_tier(4, progressed), 2, "still clamped to the ceiling")


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
			assert_eq(int(UpgradeLibrary.by_id(id)["tier"]), 2, "drawn part is at the target tier")
	assert_gt(repair, 0, "the repair kit does appear")
	assert_gt(parts, repair, "parts dominate the pool over the rare repair kit")


# --- Car draw ----------------------------------------------------------------

func test_draw_car_prefers_unowned_at_tier() -> void:
	# Completed 2 open rallies → ceiling 2; tier-2 cars are RS3 and Mustang, both
	# still eligible for an incomplete rally. Own the RS3, not the Mustang.
	var profile := _profile(["shakedown", "coastal_sprint"], ["rs3"])
	for i in 30:
		var model: Variant = RewardSystem.draw_car(2, profile, _rng(i))
		assert_eq(model, "mustang", "draws the un-owned tier-2 car, never the owned one")


func test_draw_car_grants_duplicate_when_all_eligible_owned() -> void:
	var profile := _profile(["shakedown", "coastal_sprint"], ["rs3", "mustang"])
	var model: Variant = RewardSystem.draw_car(2, profile, _rng(1))
	assert_true(model == "rs3" or model == "mustang", "falls back to a duplicate of an owned car")


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
