class_name RewardSystem
extends RefCounted
# Docs: features/reward-system.md — update in the same change as this file.
# Tests: tests/headless/test_reward_system.gd — extend in the same change.
# What's left of the reward DRAW POLICY after todo/roguelike-pivot.md decisions 21 and
# the prize-rallies deletion: what PART a special event's unlock hands over.
#
# EVERYTHING ELSE THAT USED TO LIVE HERE IS GONE:
#   - The CAR draw (draw_car, tier_ceiling, _difficulty_to_tier, target_tier, MAX_TIER,
#     highest_owned_tier, _cars_at_or_below_tier, _pick_prefer_unowned, _all_owned,
#     _last_granted_model_id, _owned_model_ids, _ensure_rng) died with prize rallies
#     (decision 28 — car acquisition is a money shop now, not a rally-win draw).
#   - stars_available_in died with the star ledger (decision 21 — see
#     Save._default_profile()'s "Star ledger: DELETED" note).
# grant_special_unlock survives because it is PARTS-MODEL machinery, not prize/star
# machinery: it hands over the UpgradeLibrary part a special's unlock gates, cascading
# down UpgradeLibrary's own prerequisite chain. That gate (UpgradeLibrary.rally_gate_met,
# unlocked_by_rally) is untouched by this wave — it belongs to the parts model, a later
# wave's territory — so this function is left exactly as it was.
#
# Scope now: this module answers WHAT PART a special hands over. It does NOT own WHEN a
# reward fires or HOW it's revealed — those live at the call site (currently
# Save._grant_rally_prizes, the dev cheat's mirror of the real award path).

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
