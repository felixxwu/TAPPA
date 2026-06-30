class_name RewardSystem
extends RefCounted
# The reward DRAW POLICY: what the player is granted after an event (an upgrade
# item) and after finishing a rally top-3 (a car). Pure functions over the
# authored libraries + the save profile — no state beyond an injected RNG,
# mirroring RallyLibrary / UpgradeLibrary (not an autoload). See
# todo/reward-system.md.
#
# Scope: this module answers WHAT to grant. It does NOT own WHEN a reward fires
# (the flow controller, features/rally-session.md) or HOW it's revealed (menus
# rig 5). The draw functions return an id; the caller delivers it via
# Save.add_item / Save.grant_car and then Save.save() — saving immediately after
# resolve is what makes the unseeded RNG savescum-proof (no re-roll on reload).

# Highest tier any reward can reach (cars top out at reward_tier 4). The
# tier-ceiling and difficulty-remap CURVES are GameConfig tunables in the final
# balance pass; the values here are placeholder defaults (deferred, per spec).
const MAX_TIER := 4

# The repair kit's weight in the per-event upgrade pool, relative to a part's
# weight of 1.0. Kept low — repairs are rare (gameplay.md). Placeholder; becomes
# a GameConfig tunable (repair_kit_drop_weight) in the balance pass.
const REPAIR_KIT_DROP_WEIGHT := 0.5


# --- Tier model & clamp ------------------------------------------------------

# Monotonic mapping from rallies-completed to the highest tier that can drop, so
# an early lucky win can't yield a top-tier reward. Placeholder curve.
static func tier_ceiling(completed_count: int) -> int:
	return clampi(1 + completed_count / 2, 1, MAX_TIER)


# f(difficulty) — default identity (reward tier = rally difficulty), an optional
# GameConfig remap can decouple them later.
static func _difficulty_to_tier(rally_difficulty: int) -> int:
	return rally_difficulty


# The clamped target tier a draw resolves at. Exposed for UI/tests.
static func target_tier(rally_difficulty: int, profile: Dictionary) -> int:
	var ceiling := tier_ceiling(RallyLibrary.completed_count(profile))
	return clampi(_difficulty_to_tier(rally_difficulty), 1, ceiling)


# --- Upgrade draw (per event) ------------------------------------------------

# Draw one per-event upgrade item id. Pool = parts at the clamped target tier
# (stepping down to the nearest lower tier that has authored parts, since not
# every tier has one) plus the repair kit as a low-weight entry. Returns an
# item_id; the caller grants it via Save.add_item.
static func draw_upgrade(rally_difficulty: int, profile: Dictionary, rng: RandomNumberGenerator = null) -> String:
	rng = _ensure_rng(rng)
	var tier := target_tier(rally_difficulty, profile)
	var parts := _parts_at_or_below(tier)
	# Weighted pool: each part weight 1.0, plus the repair kit at its low weight.
	var pool: Array = []
	for item_id in parts:
		pool.append({"id": item_id, "weight": 1.0})
	pool.append({"id": UpgradeLibrary.REPAIR_KIT_ID, "weight": REPAIR_KIT_DROP_WEIGHT})
	return _weighted_pick(pool, rng)


# Part ids at exactly `tier`, or — if that tier has no authored part — at the
# nearest lower tier that does. Excludes consumables (the repair kit is added
# separately as a weighted entry).
static func _parts_at_or_below(tier: int) -> Array:
	for t in range(tier, 0, -1):
		var parts: Array = []
		for item in UpgradeLibrary.UPGRADES:
			if not item["consumable"] and int(item["tier"]) == t:
				parts.append(item["id"])
		if not parts.is_empty():
			return parts
	return []


# --- Car draw (per rally finished top-3, including re-wins / farming) ---------

# Draw a car model id to grant for a top-3 finish, or null if no car is
# warranted (caller should grant a high-tier upgrade instead). Fires on EVERY
# top-3 finish — re-winning a completed rally re-grants a car (renewable supply),
# still clamped by the tier ceiling. Returns a model_id; caller delivers via
# Save.grant_car.
static func draw_car(rally_difficulty: int, profile: Dictionary, rng: RandomNumberGenerator = null) -> Variant:
	rng = _ensure_rng(rng)
	var tier := target_tier(rally_difficulty, profile)
	# Step down through tiers until one has a candidate that passes the
	# anti-soft-lock filter (eligible for >=1 still-incomplete rally).
	for t in range(tier, 0, -1):
		var eligible := _eligible_candidates_at_tier(t, profile)
		if eligible.is_empty():
			continue
		# Prefer un-owned models (the discovery hook); fall back to a duplicate.
		var owned := _owned_model_ids(profile)
		var unowned: Array = []
		for model_id in eligible:
			if not owned.has(model_id):
				unowned.append(model_id)
		var pick_from: Array = unowned if not unowned.is_empty() else eligible
		return pick_from[rng.randi_range(0, pick_from.size() - 1)]
	# No eligible car at any tier (player owns everything useful): grant nothing;
	# the caller pays out a high-tier upgrade instead.
	return null


# CarLibrary model ids at `tier` that stay eligible for at least one still-
# incomplete rally (the anti-soft-lock quality filter).
static func _eligible_candidates_at_tier(tier: int, profile: Dictionary) -> Array:
	var out: Array = []
	for entry in CarLibrary.CARS:
		if int(entry.get("reward_tier", 0)) != tier:
			continue
		if not RallyLibrary.incomplete_rallies_enterable_by(entry, profile).is_empty():
			out.append(entry["id"])
	return out


static func _owned_model_ids(profile: Dictionary) -> Dictionary:
	var owned := {}
	for car in profile.get("cars", []):
		owned[car.get("model_id", "")] = true
	return owned


# --- Helpers -----------------------------------------------------------------

# Unseeded RNG for real play (randomized so successive grants vary); tests inject
# a seeded rng for reproducibility. Savescum-safety comes from the caller saving
# immediately after a grant resolves, not from a seed.
static func _ensure_rng(rng: RandomNumberGenerator) -> RandomNumberGenerator:
	if rng == null:
		rng = RandomNumberGenerator.new()
		rng.randomize()
	return rng


# Pick one id from [{id, weight}, ...] proportional to weight.
static func _weighted_pick(pool: Array, rng: RandomNumberGenerator) -> String:
	var total := 0.0
	for entry in pool:
		total += float(entry["weight"])
	var roll := rng.randf() * total
	for entry in pool:
		roll -= float(entry["weight"])
		if roll <= 0.0:
			return entry["id"]
	return pool[pool.size() - 1]["id"]  # float-rounding guard
