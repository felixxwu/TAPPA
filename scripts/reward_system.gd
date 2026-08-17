class_name RewardSystem
extends RefCounted
# The reward DRAW POLICY: what CAR the player is granted for a top-3 rally finish, and
# what PART a special event's unlock hands over. Pure functions over the authored
# libraries + the save profile — no state beyond an injected RNG, mirroring
# RallyLibrary / UpgradeLibrary (not an autoload). See todo/reward-system.md.
#
# There is no per-event random UPGRADE draw any more, and no consumables to draw: parts
# are won outright at the rally that advertises them (features/prize-rallies.md) or bought
# with stars (features/star-economy.md), and engine swapping is simply unlimited once its
# rally unlocks it. Equipment now only ever arrives by a route the player chose.
#
# Scope: this module answers WHAT to grant. It does NOT own WHEN a reward fires
# (the flow controller, features/rally-session.md) or HOW it's revealed (menus
# rig 5). draw_car returns an id; the caller delivers it via
# Save.add_item / Save.grant_car and then Save.save() — saving immediately after
# resolve is what makes the unseeded RNG savescum-proof (no re-roll on reload).

# Highest tier any reward can reach (cars top out at reward_tier 4). The
# tier-ceiling and difficulty-remap CURVES are GameConfig tunables in the final
# balance pass; the values here are placeholder defaults (deferred, per spec).
#
# TIER IS NOW A CAR-DRAW CONCEPT ONLY. Upgrades used to carry a `tier` too, walked by
# the old _parts_at_or_below, but the star gate (UpgradeLibrary.rally_gate_met) does that
# job better: tier gated by rally DIFFICULTY and had gone vestigial (every part sat at
# tier 1 bar one), whereas the gate is explicit and legible. Upgrades are no longer drawn at
# random at all — they're won or bought — so no rarity model replaces it. The car ladder below
# is untouched — it's also where the "harder rally, better prize" correlation still lives.
const MAX_TIER := 4


# --- Tier model & clamp ------------------------------------------------------

# Monotonic mapping from rallies-completed to the highest tier that can drop, so
# an early lucky win can't yield a top-tier reward. Placeholder curve.
static func tier_ceiling(completed_count: int) -> int:
	return clampi(1 + completed_count / 2, 1, MAX_TIER)


# f(difficulty) — default identity (reward tier = rally difficulty), an optional
# GameConfig remap can decouple them later.
static func _difficulty_to_tier(rally_difficulty: int) -> int:
	return rally_difficulty


# The clamped tier the CAR draw resolves at (draw_car's one caller). Exposed for tests.
static func target_tier(rally_difficulty: int, profile: Dictionary) -> int:
	var ceiling := tier_ceiling(RallyLibrary.completed_count(profile))
	return clampi(_difficulty_to_tier(rally_difficulty), 1, ceiling)


# --- Upgrade grants ----------------------------------------------------------

# Sentinel meaning "nothing was awarded this event". Callers must NOT install it, append it
# to the won list, or fire a reveal — they skip straight on to the next menu. It outlived
# the per-event draw that coined it: the reward flow still needs a "no item here" value.
const NO_REWARD := ""

# Grant the part a SPECIAL event unlocks to the car that just won it, cascading down the
# prerequisite ladder so the award is actually usable (todo/special-unlock-reveal.md).
#
# A special's gate opens the part for the whole garage (UpgradeLibrary.rally_gate_met), but
# the part itself also has a PER-CAR prerequisite: turbo_large needs turbo_small fitted to
# THIS car, and supercharger needs turbo_large. Awarding
# the headline part to a car that lacks the chain would hand over something it can't run, so
# the missing rungs are granted too — silently, since the reveal names only the headline.
#
# Returns the ids granted, HEADLINE FIRST, or [] when nothing was (the car already has it, or
# `item_id` is empty/unknown).
#
# The HEADLINE is fitted ENABLED — a special's part is a milestone the reveal
# announces, so it should be doing something when the player next drives. The cascaded
# prerequisite rungs are fitted DISABLED: a ladder shares ONE slot (turbo_small /
# turbo_large / supercharger are all `slot: "turbo"`), so they are mutually exclusive
# alternatives, and the lower rungs exist only to satisfy prerequisite_met. Save's
# _enable_exclusive enforces one-enabled-per-slot anyway, so granting bottom-up and enabling
# only the headline leaves exactly the intended state.
#
# A consumable is added to the inventory instead of being fitted. Nothing in the shipped
# catalogue is one any more, but the branch is cheap insurance against a future consumable
# being wired to a special's unlock.
static func grant_special_unlock(car_instance_id: int, item_id: String) -> Array:
	if item_id == "" or UpgradeLibrary.by_id(item_id).is_empty():
		return []
	var driven: Dictionary = Save.get_car(car_instance_id)
	if driven.is_empty():
		return []
	# Already fitted to this car: grant NOTHING and report nothing, so the caller can still
	# announce the unlock (the gate is garage-wide news) without a misleading "you got X".
	# Returning a partial cascade here would leave granted[0] naming a prerequisite rather
	# than the headline the reveal is about.
	if (driven.get("installed_upgrades", []) as Array).has(item_id):
		return []
	# Walk DOWN the prerequisite chain collecting what this car is missing. Guarded against a
	# cycle in authored data (a bad requires_upgrade_id pair would otherwise spin forever).
	var chain: Array = []
	var seen := {}
	var cursor := item_id
	while cursor != "" and not seen.has(cursor):
		seen[cursor] = true
		chain.append(cursor)
		cursor = UpgradeLibrary.requires_upgrade_id(cursor)
	var installed: Array = driven.get("installed_upgrades", [])
	var granted: Array = []
	# Bottom-up so each rung's prerequisite is in place before the rung above it lands.
	for i in range(chain.size() - 1, -1, -1):
		var id := String(chain[i])
		if installed.has(id):
			continue  # already on this car — nothing to grant, and not a failure
		if UpgradeLibrary.is_consumable(id):
			Save.add_item(id, 1, false)
		else:
			# i == 0 is the headline (chain[0]); everything above it in the loop is a
			# prerequisite rung, which stays parked.
			Save.install_upgrade(car_instance_id, id, i == 0)
		granted.append(id)
	if granted.is_empty():
		return []
	# Headline first: the caller shows granted[0] and the cascade stays implementation detail.
	granted.reverse()
	return granted


# --- Car draw (per rally finished top-3, including re-wins / farming) ---------

# Draw the car model id to grant for a top-3 finish. Fires on EVERY top-3
# finish — re-winning a completed rally re-grants a car (renewable supply).
# The draw is GUARANTEED: the pool (tier <= the ceiling) always has the tier-1
# roster in it, so a car is always granted. Any car whose reward_tier is at or
# below the DRAW CEILING — clamp(f(rally difficulty), 1, tier_ceiling(rallies
# completed)), gameplay.md's progress clamp. So a higher-difficulty rally pays a
# better car, but only up to the tier the player's progress has earned — a lucky early win can't drop a top
# car. Prefers un-owned.
# rally_difficulty defaults to 0 (garage tier alone governs). Returns a model_id
# (Variant only for the defensive empty-roster null); caller delivers via
# Save.grant_car.
static func draw_car(profile: Dictionary, rally_difficulty: int = 0, rng: RandomNumberGenerator = null) -> Variant:
	rng = _ensure_rng(rng)
	# gameplay.md's progress clamp: reward tier = f(difficulty), capped by the
	# progress ceiling (rallies completed), so a lucky early win at a higher-difficulty
	# rally still can't drop a car above the player's earned tier. This is the SAME
	# clamp. (Upgrades don't use a tier at all any more — see the note on MAX_TIER —
	# so this is now the car ladder's own clamp.) Cars deliberately don't key
	# off the garage's highest owned tier, which let one d2 win open the whole roster.
	var earned := tier_ceiling(RallyLibrary.completed_count(profile))
	var ceiling := target_tier(rally_difficulty, profile)
	var pool := _cars_at_or_below_tier(ceiling)
	# EXHAUSTED-TIER STEP-UP. The tier is min(difficulty, earned), so a difficulty-1
	# rally always draws the tier-1 pool however far the player has come — and there
	# are far more low-difficulty rallies than low-tier cars, so that pool runs out
	# and every later win hands back a car already in the garage. When that happens,
	# climb toward the tier the player has actually EARNED until something new
	# appears. This never exceeds the earned ceiling, so the progress clamp
	# (gameplay.md — a lucky early win can't drop a car above your tier) still holds;
	# it only stops an exhausted pool turning a win into a no-op reward.
	var owned_ids := _owned_model_ids(profile)
	while ceiling < earned and _all_owned(pool, owned_ids):
		ceiling += 1
		pool = _cars_at_or_below_tier(ceiling)
	# Avoid handing out the same model twice running when there is any alternative —
	# back-to-back duplicates read as a broken reward even when a duplicate is the
	# only honest outcome.
	return _pick_prefer_unowned(pool, _owned_model_ids(profile), rng,
		_last_granted_model_id(profile))


# The highest reward_tier among the cars in the garage, or 0 for an empty one.
# Used by the wreck safety net to size its replacement against what the player had
# actually worked up to, rather than always paying out at the bottom of the ladder.
static func highest_owned_tier(profile: Dictionary) -> int:
	var best := 0
	for car in profile.get(Save.KEY_CARS, []):
		var entry := CarLibrary.for_owned(car)
		best = maxi(best, int(entry.get("reward_tier", 0)))
	return best


# CarLibrary model ids with reward_tier at or below `tier`.
static func _cars_at_or_below_tier(tier: int) -> Array:
	var out: Array = []
	for entry in CarLibrary.all():
		if int(entry.get("reward_tier", 0)) <= tier:
			out.append(entry["id"])
	return out


# --- Spending stars ----------------------------------------------------------
# Cars are NOT bought. They are won at the rally that advertises them
# (features/prize-rallies.md), so what the player owns is exactly what they went out and
# won — which is what keeps the per-rally `restriction` bands meaningful and gives the dark
# map something worth exploring toward.
#
# The retired API was `car_price` / `purchase_car` / `stars_available_in`'s pricing role,
# plus the present box on the HQ map and `GameConfig.star_cost_per_car`. The soft-lock
# rescue that once rode along with it (a price-0 car when stranded, then an unlock-draw
# fallback) is gone too: entry requirements are purely categorical, so no build can be
# too slow to enter anything, and reachability is a CONTENT invariant proven over the map
# (test_every_starter_car_can_enter_something_on_a_fresh_profile and the roster's
# reachability closure) rather than a runtime rescue.
#
# What stars buy instead: repairs and copies of discovered parts — see
# features/star-economy.md.


# The spendable balance held by `profile`. Mirrors Save.stars_available() but reads the dict
# it is given, keeping this whole module pure over a profile the way draw_car already is.
static func stars_available_in(profile: Dictionary) -> int:
	return maxi(0, int(profile.get("stars_earned", 0)) - int(profile.get("stars_spent", 0)))



# Uniform pick from `pool`, restricted to not-yet-owned models when any exist
# (the discovery hook); otherwise a duplicate of an owned one. Null on an empty pool.
# `avoid` is the model granted LAST time: it is dropped from the candidates whenever
# doing so still leaves something to pick, so a player never sees the same car twice
# running while any alternative exists. It is a preference, never a hard filter — a
# single-entry pool still grants that car rather than returning null.
static func _pick_prefer_unowned(pool: Array, owned: Dictionary, rng: RandomNumberGenerator,
		avoid: String = "") -> Variant:
	if pool.is_empty():
		return null
	var unowned: Array = []
	for model_id in pool:
		if not owned.has(model_id):
			unowned.append(model_id)
	var pick_from: Array = unowned if not unowned.is_empty() else pool
	if avoid != "" and pick_from.size() > 1 and pick_from.has(avoid):
		var without: Array = pick_from.duplicate()
		without.erase(avoid)
		pick_from = without
	return pick_from[rng.randi_range(0, pick_from.size() - 1)]


# True when every model in `pool` is already in the garage — the condition that makes
# a draw from it a guaranteed duplicate (see draw_car's exhausted-tier step-up).
static func _all_owned(pool: Array, owned: Dictionary) -> bool:
	for model_id in pool:
		if not owned.has(model_id):
			return false
	return not pool.is_empty()


# The most recently granted car model, or "" for an empty garage. grant_car appends,
# so the last entry is the newest — no extra state to persist or migrate.
static func _last_granted_model_id(profile: Dictionary) -> String:
	var cars: Array = profile.get(Save.KEY_CARS, [])
	if cars.is_empty():
		return ""
	return String((cars[cars.size() - 1] as Dictionary).get("model_id", ""))


static func _owned_model_ids(profile: Dictionary) -> Dictionary:
	var owned := {}
	for car in profile.get(Save.KEY_CARS, []):
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
