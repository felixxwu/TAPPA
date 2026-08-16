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
#
# TIER IS NOW A CAR-DRAW CONCEPT ONLY. Upgrades used to carry a `tier` too, walked by
# the old _parts_at_or_below, but the star gate (UpgradeLibrary.rally_gate_met) does that
# job better: tier gated by rally DIFFICULTY and had gone vestigial (every part sat at
# tier 1 bar one), whereas the gate is explicit and legible. Upgrade rarity within what's
# unlocked is now the authored `weight` (UpgradeLibrary.pool_weight). The car ladder below
# is untouched — it's also where the "harder rally, better prize" correlation still lives.
const MAX_TIER := 4

# The engine swap token's chance of dropping at the end of a non-final event, as an
# ABSOLUTE probability (0..1). Kept low — swaps are an occasional treat, not a staple.
# Placeholder; becomes a GameConfig tunable in the balance pass.
#
# It was a relative WEIGHT of 0.2 in a pool where each eligible part weighed 1.0, so with
# ~4 parts in the pool it paid out about 5% of the time. Retiring random part drops emptied
# that pool and turned the same 0.2 into a flat 20% roll — quadrupling the token economy as
# a side effect, which nobody chose. The value is restated here at the rate the weight
# actually produced; the NAME says `CHANCE` now so it cannot be read as relative again.
const ENGINE_SWAP_TOKEN_DROP_CHANCE := 0.05

# Engine swap tokens the player must hold, on top of driving a fully-maxed car,
# before a mystery box is granted instead of a normal draw (see draw_upgrade).
# A proxy for "has been driving maxed cars for a while". Placeholder; becomes a
# GameConfig tunable in the balance pass, same treatment as the weights above.
const MYSTERY_BOX_TOKEN_THRESHOLD := 3


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


# --- Upgrade draw (per event) ------------------------------------------------

# Sentinel return meaning "nothing was awarded this event". Callers must NOT install it,
# append it to the won list, or fire a reveal — they skip straight on to the next menu.
const NO_REWARD := ""

# Draw one per-event upgrade item id, or NO_REWARD ("").
#
# The old "every event always pays out" guarantee is RETIRED. The rule now:
#
#   1. While the car still has an unlocked part left to win, award it. This is the
#      common case and must never be pre-empted by the branches below.
#   2. Once the car is maxed (and, if engine swapping is unlocked, the player is
#      sitting on MYSTERY_BOX_TOKEN_THRESHOLD tokens), roll for a mystery box with
#      probability 1/(boxes_owned + 1) — see _box_chance.
#   3. Otherwise award NOTHING.
#
# Why: star-gating parts (UpgradeLibrary.rally_gate_met) makes cars read as maxed far
# earlier than the old tier ceiling did, so a draw that always paid out would degenerate
# into a mystery-box firehose. The swap token is still a legitimate low-weight entry in
# the pool, but it is no longer the always-there floor that backstopped the guarantee.
#
# Parts already fitted to `owned_car` — the car the player just drove — are excluded, so
# the draw never awards a part the car already has. That exclusion is also what dedups a
# multi-reward rally: the flow controller fits each won part before the next draw.
static func draw_upgrade(profile: Dictionary, rng: RandomNumberGenerator = null, owned_car: Dictionary = {}) -> String:
	rng = _ensure_rng(rng)
	# CONSUMABLES ONLY. Parts are no longer drawn at random: one is won outright at the
	# rally that awards it (features/prize-rallies.md) and further copies are bought with
	# stars (features/star-economy.md). Leaving parts in this pool would have undercut both
	# — why go and win a turbo, or pay for one, if it might simply fall out of the next
	# stage? — and it was the last thing in the game handing out equipment for nothing.
	#
	# What remains is the ENGINE SWAP TOKEN at its low drop chance, plus the mystery box on
	# its own gate. Those are consumables with no other renewable source, so the per-event
	# draw is still doing real work; it just no longer competes with the two deliberate
	# routes to a part.
	#
	# `_eligible_parts` is NOT retired — the MYSTERY BOX still opens onto a part, and its own
	# gate (`_box_gate_open`) is expressed in terms of it. That is a deliberate, occasional
	# reward with a reveal of its own, not a per-event drip, so it does not undercut winning
	# or buying the way a stage-by-stage drop did.
	# The BOX first, and on its own curve rather than as one weight among others: its
	# chance is 1/(boxes held + 1), so the FIRST box is certain. Folding it into a weighted
	# pool alongside "nothing" would quietly break that guarantee.
	if _box_gate_open(profile, owned_car) and rng.randf() < _box_chance(profile):
		return UpgradeLibrary.MYSTERY_BOX_ID
	if rng.randf() < ENGINE_SWAP_TOKEN_DROP_CHANCE:
		return UpgradeLibrary.ENGINE_SWAP_TOKEN_ID
	return NO_REWARD


# Draw a per-event upgrade AND deliver it to `car_instance_id`, returning what was actually
# granted ("" / NO_REWARD when nothing was). THE one place the draw-then-grant sequence
# lives, so both flow controllers (RallySession's rally events and ChallengeSession's stages)
# stay in step: the empty-draw case, the consumable-vs-slotted split, and the disabled-on-
# award convention are each expressed once. NOTE it does not control saving: Save.add_item /
# Save.install_upgrade each persist on their own, so the caller's own Save.save() is a
# further write rather than the only one.
static func draw_and_grant_upgrade(car_instance_id: int, profile: Dictionary,
		rng: RandomNumberGenerator = null) -> String:
	var driven: Dictionary = Save.get_car(car_instance_id)
	var item_id := draw_upgrade(profile, rng, driven)
	if item_id == NO_REWARD:
		return NO_REWARD
	if UpgradeLibrary.is_consumable(item_id):
		Save.add_item(item_id, 1, false)
	else:
		# Awarded parts are fitted DISABLED — the reveal overlay enables the player's pick.
		# (A part in a HIDDEN slot overrides that inside Save.install_upgrade, since it has
		# no garage row to be enabled from.)
		Save.install_upgrade(car_instance_id, item_id, false)
	return item_id


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
# The HEADLINE is fitted ENABLED — unlike draw_and_grant_upgrade's routine parts, which land
# disabled for the player to pick between. A special's part is a milestone the reveal
# announces, so it should be doing something when the player next drives. The cascaded
# prerequisite rungs are fitted DISABLED: a ladder shares ONE slot (turbo_small /
# turbo_large / supercharger are all `slot: "turbo"`), so they are mutually exclusive
# alternatives, and the lower rungs exist only to satisfy prerequisite_met. Save's
# _enable_exclusive enforces one-enabled-per-slot anyway, so granting bottom-up and enabling
# only the headline leaves exactly the intended state.
#
# Consumables are added to the inventory instead, same split as the draw path.
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


# Every part `owned_car` could win right now. Flat — there is no tier walk any more (see
# the header note on retiring tier). Excludes consumables (added separately as weighted
# entries), `free` parts (ballast is always available, never a reward), any id in
# `exclude` (already fitted to the driven car), any item whose per-car prerequisite isn't
# fitted yet, and any item whose star gate hasn't opened.
static func _eligible_parts(profile: Dictionary, exclude: Array = [], owned_car: Dictionary = {}) -> Array:
	var parts: Array = []
	for item in UpgradeLibrary.all():
		var item_id := String(item["id"])
		if item["consumable"] or bool(item.get("free", false)):
			continue
		if exclude.has(item_id):
			continue
		if not UpgradeLibrary.prerequisite_met(item_id, owned_car):
			continue
		if not UpgradeLibrary.rally_gate_met(item_id, profile):
			continue
		parts.append(item_id)
	return parts


# --- Mystery box gating (see draw_upgrade) -----------------------------------

# True when `owned_car` has nothing left to gain right now — every part its per-car
# prerequisites and the CURRENT star gates allow is already installed.
#
# This deliberately uses the GATED pool. The old version checked the absolute tier
# ceiling rather than the progress-clamped one, so a car wasn't "maxed" merely because
# progress hadn't opened the tier up yet; the star gate reintroduces that same question
# and we answer it the other way — a car with every currently-unlocked part IS maxed.
# The accepted consequence is that cars read as maxed much earlier, so this branch is
# reached far more often, which is exactly why the always-pays-out guarantee was retired
# and the box roll self-throttles (_box_chance).
static func _car_has_nothing_left(profile: Dictionary, owned_car: Dictionary) -> bool:
	return _eligible_parts(profile, owned_car.get("installed_upgrades", []), owned_car).is_empty()


# Whether a mystery box may even be rolled for. The car is already known to be maxed.
#
# The token threshold applies ONLY once engine swapping is unlocked: before then tokens
# are inert (they can't be spent), so requiring a stack of them would gate the box on a
# currency the player has no way to use deliberately.
static func _box_gate_open(profile: Dictionary, owned_car: Dictionary) -> bool:
	if not _other_car_has_room(profile, owned_car):
		return false  # a box with nowhere to land is useless — award nothing instead
	if not RallyLibrary.engine_swaps_unlocked(profile):
		return true
	return _tokens_owned(profile) >= MYSTERY_BOX_TOKEN_THRESHOLD


# Probability of actually granting a box, given how many are already banked. The shape is
# 1 / (1 + owned/softness), with the softness a GameConfig knob
# (mystery_box_throttle; 1.0 = the plain 1/(owned+1) curve).
#
# The leading 1 is load-bearing: a literal 1/owned is undefined at zero and equals 1.0 at
# one, so the first TWO boxes would both be certain. This way the first is guaranteed and
# each one after is rarer, so boxes self-throttle instead of piling up.
static func _box_chance(profile: Dictionary) -> float:
	var softness := maxf(Config.data.mystery_box_throttle, 0.01)
	return 1.0 / (1.0 + float(_boxes_owned(profile)) / softness)


static func _boxes_owned(profile: Dictionary) -> int:
	return int(profile.get("inventory", {}).get(UpgradeLibrary.MYSTERY_BOX_ID, 0))


# Engine swap tokens held, read straight off `profile` (this module never
# touches the Save autoload) the same way Save.engine_swap_tokens_owned() does,
# tolerating a missing inventory key.
static func _tokens_owned(profile: Dictionary) -> int:
	return int(profile.get("inventory", {}).get(UpgradeLibrary.ENGINE_SWAP_TOKEN_ID, 0))


# True if some OTHER owned car (not `owned_car`) still has room for an upgrade.
# This one KEEPS the exclusion, because it gates a different question: whether to
# hand out a mystery box AS the reward for a car that has nothing left to gain
# (draw_upgrade). That car is by definition full, so a box is only worth awarding
# if some other car can receive it.
static func _other_car_has_room(profile: Dictionary, owned_car: Dictionary) -> bool:
	var current_instance_id := int(owned_car.get("instance_id", -1))
	for car in profile.get(Save.KEY_CARS, []):
		if int(car.get("instance_id", -1)) == current_instance_id:
			continue
		if not _car_has_nothing_left(profile, car):
			return true
	return false


# Whether ANY owned car still has room for an upgrade — i.e. there's somewhere for a
# mystery box to land. Used by the HQ garage row's "Mystery Box" button to gate itself,
# re-checked at open-time (the garage can change between grant and open, e.g. a car
# sold).
#
# NO car is excluded, including the currently selected one. Boxes used to be won BY a
# maxed-out car through the rally reward loop, so "the car it came from" was full by
# construction and gifting to it would have been a no-op — hence the old
# any_other_car_has_room. Boxes now also arrive from the online Rally Challenge
# (ChallengeSession._COMPLETION_REWARD), where they're tied to no car at all, so that
# assumption no longer holds and excluding the selected car just made boxes dead
# weight for a one-car garage.
static func any_car_has_room(profile: Dictionary) -> bool:
	for car in profile.get(Save.KEY_CARS, []):
		if not _car_has_nothing_left(profile, car):
			return true
	return false


# Resolve what a mystery box grants: a uniformly random owned car among those with a
# non-empty eligible pool, then a uniformly random item from that car's pool.
# Returns {} when NO car has room (the opener then leaves the box unspent) — a pure
# resolve, no Save mutation; the caller (Save) performs the actual consume/install.
#
# EVERY owned car is a candidate, the currently selected one included — see
# any_car_has_room for why the old "not the car it came from" exclusion is gone. With
# one car in the garage the box now fills that car's empty slots instead of being
# permanently unopenable.
static func pick_mystery_box_grant(profile: Dictionary, rng: RandomNumberGenerator = null) -> Dictionary:
	rng = _ensure_rng(rng)
	var candidates: Array = []
	for car in profile.get(Save.KEY_CARS, []):
		if not _eligible_parts(profile, car.get("installed_upgrades", []), car).is_empty():
			candidates.append(car)
	if candidates.is_empty():
		return {}
	var recipient: Dictionary = candidates[rng.randi_range(0, candidates.size() - 1)]
	var parts := _eligible_parts(profile, recipient.get("installed_upgrades", []), recipient)
	var item_id: String = parts[rng.randi_range(0, parts.size() - 1)]
	return {"instance_id": int(recipient.get("instance_id", -1)), "item_id": item_id}


# --- Car draw (per rally finished top-3, including re-wins / farming) ---------

# Draw the car model id to grant for a top-3 finish. Fires on EVERY top-3
# finish — re-winning a completed rally re-grants a car (renewable supply).
# The draw is GUARANTEED: the pool (tier <= the ceiling) always has the tier-1
# roster in it, so a car is always granted. Any car whose reward_tier is at or
# below the DRAW CEILING — clamp(f(rally difficulty), 1, tier_ceiling(rallies
# completed)), the same progress clamp the per-event upgrade draw uses
# (gameplay.md). So a higher-difficulty rally pays a better car, but only up to
# the tier the player's progress has earned — a lucky early win can't drop a top
# car. Prefers un-owned.
# rally_difficulty defaults to 0 (garage tier alone governs). Returns a model_id
# (Variant only for the defensive empty-roster null); caller delivers via
# Save.grant_car.
static func draw_car(profile: Dictionary, rally_difficulty: int = 0, rng: RandomNumberGenerator = null) -> Variant:
	rng = _ensure_rng(rng)
	# gameplay.md's progress clamp: reward tier = f(difficulty), capped by the
	# progress ceiling (rallies completed), so a lucky early win at a higher-difficulty
	# rally still can't drop a car above the player's earned tier. This is the SAME
	# clamp. (The per-event UPGRADE draw no longer uses a tier at all — see the note on
	# MAX_TIER — so this is now the car ladder's own clamp.) Cars deliberately don't key
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
