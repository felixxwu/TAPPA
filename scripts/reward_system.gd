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
# (stepping down to the nearest lower tier that has an eligible part, since not
# every tier has one) plus the repair kit as a low-weight entry. Parts already
# fitted to `owned_car` — the car the player just drove, which the podium offers
# to fit the reward onto — are excluded, so the draw never awards a part the car
# already has; with every part at/below the tier fitted, only the repair kit
# remains. Returns an item_id; the caller grants it via Save.add_item.
static func draw_upgrade(rally_difficulty: int, profile: Dictionary, rng: RandomNumberGenerator = null, owned_car: Dictionary = {}) -> String:
	rng = _ensure_rng(rng)
	var tier := target_tier(rally_difficulty, profile)
	var parts := _parts_at_or_below(tier, owned_car.get("installed_upgrades", []))
	# Weighted pool: each part weight 1.0, plus the repair kit at its low weight.
	var pool: Array = []
	for item_id in parts:
		pool.append({"id": item_id, "weight": 1.0})
	pool.append({"id": UpgradeLibrary.REPAIR_KIT_ID, "weight": REPAIR_KIT_DROP_WEIGHT})
	return _weighted_pick(pool, rng)


# Part ids at exactly `tier`, or — if that tier has no eligible part — at the
# nearest lower tier that does. Excludes consumables (the repair kit is added
# separately as a weighted entry) and any id in `exclude` (parts already fitted
# to the driven car). Empty when everything at/below the tier is excluded.
static func _parts_at_or_below(tier: int, exclude: Array = []) -> Array:
	for t in range(tier, 0, -1):
		var parts: Array = []
		for item in UpgradeLibrary.UPGRADES:
			if not item["consumable"] and int(item["tier"]) == t and not exclude.has(item["id"]):
				parts.append(item["id"])
		if not parts.is_empty():
			return parts
	return []


# --- Car draw (per rally finished top-3, including re-wins / farming) ---------

# Draw the car model id to grant for a top-3 finish. Fires on EVERY top-3
# finish — re-winning a completed rally re-grants a car (renewable supply).
# The draw is GUARANTEED: the standard pool (tier <= the ceiling) always has
# the tier-1 roster in it, so a car is always granted. Two paths:
#   * Standard: any car whose reward_tier is at or below the DRAW CEILING —
#     the higher of the GARAGE TIER (highest reward_tier among cars already
#     owned) and the tier the JUST-BEATEN RALLY'S DIFFICULTY maps to. So
#     beating a difficulty-3 rally can drop a tier-3 car even from a
#     lower-tier garage — preferring un-owned models.
#   * Unlock fallback: if the player has completed (>=1 star) every rally their
#     garage can currently enter — nothing new left to enter — grant a car that
#     opens a LOCKED rally instead: candidates eligible for the lowest-difficulty
#     still-locked rallies, preferring un-owned. This keeps a fresh rally
#     reachable after every reward.
# rally_difficulty defaults to 0 (garage tier alone governs). Returns a model_id
# (Variant only for the defensive empty-roster null); caller delivers via
# Save.grant_car.
static func draw_car(profile: Dictionary, rally_difficulty: int = 0, rng: RandomNumberGenerator = null) -> Variant:
	rng = _ensure_rng(rng)
	var pool := _unlock_candidates(profile)
	if pool.is_empty():
		var ceiling := maxi(garage_tier(profile), _difficulty_to_tier(rally_difficulty))
		pool = _cars_at_or_below_tier(ceiling)
	return _pick_prefer_unowned(pool, _owned_model_ids(profile), rng)


# The highest reward_tier among the cars the player owns — the "difficulty
# unlocked" level the standard draw pays out at. An empty garage pays tier 1.
static func garage_tier(profile: Dictionary) -> int:
	var best := 1
	for car in profile.get("cars", []):
		var meta := CarLibrary.by_id(String(car.get("model_id", "")))
		best = maxi(best, int(meta.get("reward_tier", 1)))
	return best


# CarLibrary model ids with reward_tier at or below `tier`.
static func _cars_at_or_below_tier(tier: int) -> Array:
	var out: Array = []
	for entry in CarLibrary.all():
		if int(entry.get("reward_tier", 0)) <= tier:
			out.append(entry["id"])
	return out


# The unlock-fallback pool: non-empty ONLY when the garage is stuck — no owned
# car (on its EFFECTIVE stats, so installed upgrades count) can enter any
# still-incomplete rally. Then: walk the still-locked (incomplete, showdown only
# if unlocked) rallies by difficulty ASCENDING and return every CarLibrary model
# eligible for one at the lowest difficulty ANY catalogue car can actually
# enter, so the grant opens progression in difficulty order (all tier-1/2
# beaten -> a car for a difficulty-3 rally, not 4). Stepping past a difficulty
# whose restriction bands no catalogue car fits matters: giving up there (and
# silently falling back to the standard draw) would leave the player soft-locked
# even though a grant for the next difficulty up re-opens progression.
static func _unlock_candidates(profile: Dictionary) -> Array:
	for car in profile.get("cars", []):
		var meta := UpgradeLibrary.effective_meta(car, CarLibrary.by_id(String(car.get("model_id", ""))))
		if not RallyLibrary.incomplete_rallies_enterable_by(meta, profile).is_empty():
			return []  # a new rally is already enterable — standard draw applies
	var rallies: Dictionary = profile.get("rallies", {})
	# Locked rallies grouped by difficulty, so we can walk difficulties ascending.
	var locked_by_difficulty := {}
	for rally in RallyLibrary.all():
		if rallies.get(rally["id"], {}).get("completed", false):
			continue
		if not RegionLibrary.rally_showdown_gate_open(rally, profile):
			continue
		var d := int(rally.get("difficulty", 1))
		if not locked_by_difficulty.has(d):
			locked_by_difficulty[d] = []
		locked_by_difficulty[d].append(rally)
	var difficulties: Array = locked_by_difficulty.keys()
	difficulties.sort()
	for d in difficulties:
		var out := {}
		for rally in locked_by_difficulty[d]:
			for entry in CarLibrary.all():
				if RallyLibrary.is_eligible(rally, entry):
					out[entry["id"]] = true
		if not out.is_empty():
			return out.keys()
	# Nothing is locked, or no catalogue car can enter any locked rally (a hard
	# data hole no grant can fix) — the standard draw applies.
	return []


# Uniform pick from `pool`, restricted to not-yet-owned models when any exist
# (the discovery hook); otherwise a duplicate of an owned one. Null on an empty pool.
static func _pick_prefer_unowned(pool: Array, owned: Dictionary, rng: RandomNumberGenerator) -> Variant:
	if pool.is_empty():
		return null
	var unowned: Array = []
	for model_id in pool:
		if not owned.has(model_id):
			unowned.append(model_id)
	var pick_from: Array = unowned if not unowned.is_empty() else pool
	return pick_from[rng.randi_range(0, pick_from.size() - 1)]


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
