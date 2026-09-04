class_name PerkLibrary
extends RefCounted
# Docs: features/perks.md — update in the same change as this file.
# Tests: tests/headless/test_perk_library.gd — extend in the same change.
#
# THE PERK CATALOGUE (todo/roguelike-pivot.md "Perks — a straight lift from RR", stage
# 7 of todo/roguelike-pivot-plan.md). An authored content module — static, no autoload
# — mirroring CarLibrary/RallyLibrary/RegionLibrary: one Array of entry Dictionaries
# keyed by a stable "id", looked up through the shared Registry helper, with a
# Registry.Seam so a test can swap in a synthetic roster (CLAUDE.md: "never depend on
# a specific catalogue entry existing" — perk *definitions* are authored data, exactly
# like a car's stats or a rally's difficulty).
#
# THREE STATES, kept apart deliberately:
#   LOCKED       — the unlock stat (a LifetimeStats id) hasn't crossed its threshold.
#                  is_unlocked() false.
#   PURCHASABLE  — the threshold IS crossed, but the perk is not yet bought.
#                  is_purchasable() true (implies is_unlocked()).
#   OWNED        — bought (Save.KEY_BOUGHT_PERKS, via Save.buy_perk). Save.owns_perk().
# Equipping is a SEPARATE step from owning (Save.KEY_EQUIPPED_PERKS, via
# Save.equip_perk/unequip_perk), capped at GameConfig.perk_max_equipped (RR's
# PERK_MAX_EQUIPPED = 3) — an owned perk need not be equipped, and the cap is
# enforced once, in Save.equip_perk, not re-checked by every caller.
#
# NO GAMEPLAY EFFECTS YET, AND THAT IS DELIBERATE FOR THIS STAGE. RR's perks each
# carry real in-run behaviour (a coin-magnet radius, a heal rate, a damage-reduction
# fraction); this stage builds the gate/purchase/equip STATE MACHINE only — every
# perk here is inert once equipped, a plain id sitting in
# Save.profile[Save.KEY_EQUIPPED_PERKS] that nothing currently reads for gameplay.
# Wiring a real effect belongs through the SAME funnel BoostLibrary already uses
# (UpgradeLibrary.EFFECTS + a car's "boosts" seam — see that file's own header)
# rather than a second mechanism, when that lands.
#
# `unlock.stat` NAMES A LifetimeStats ID — LifetimeStats.is_known(stat) is the
# contract `test_perk_library.gd -> test_every_unlock_stat_is_a_real_lifetime_stat`
# enforces, so a typo'd stat id fails loudly instead of gating on a counter that
# never moves.
#
# PRICES AND THRESHOLDS ARE AUTHORED DATA (CLAUDE.md): nothing in tests/headless/ may
# pin a shipped price or threshold — only the RELATIONSHIP ("below threshold = locked",
# "at/above threshold and unbought = purchasable", "at most PERK_MAX_EQUIPPED
# equipped") is fair game, and those tests build their own synthetic roster via
# override_for_test() rather than reading PERKS below.
const PERKS: Array[Dictionary] = [
	{
		"id": "coin_magnet", "label": "Coin Magnet", "price": 5000,
		"description": "Wider coin pickup radius.",
		"unlock": {"stat": LifetimeStats.STAGES_CLEARED, "threshold": 8},
	},
	{
		"id": "self_healing", "label": "Self Healing", "price": 8000,
		"description": "Slowly repairs damage during a stage.",
		"unlock": {"stat": LifetimeStats.DAMAGE_TAKEN, "threshold": 300},
	},
	{
		"id": "trail_blazer", "label": "Trail Blazer", "price": 6000,
		"description": "Bigger fast-completion bonus.",
		"unlock": {"stat": LifetimeStats.MONEY_EARNED, "threshold": 5000},
	},
	{
		"id": "lucky_coins", "label": "Lucky Coins", "price": 7000,
		"description": "More coins spawn per stage.",
		"unlock": {"stat": LifetimeStats.MONEY_SPENT, "threshold": 5000},
	},
	{
		"id": "rubber_body", "label": "Rubber Body", "price": 9000,
		"description": "Takes less damage from impacts.",
		"unlock": {"stat": LifetimeStats.RUNS_FAILED, "threshold": 3},
	},
	{
		"id": "iron_will", "label": "Iron Will", "price": 12000,
		"description": "Starts each run with a head start on the clock.",
		"unlock": {"stat": LifetimeStats.REGIONS_CLEARED_TOTAL, "threshold": 2},
	},
	{
		"id": "road_scholar", "label": "Road Scholar", "price": 4000,
		"description": "A little extra money on every run's opening stage.",
		"unlock": {"stat": LifetimeStats.RUNS_STARTED, "threshold": 10},
	},
]

static var _seam := Registry.Seam.new(PERKS)

static func all() -> Array[Dictionary]:
	return _seam.all()

static func override_for_test(perks: Array[Dictionary]) -> void:
	_seam.override_for_test(perks)

static func reset() -> void:
	_seam.reset()

static func by_id(id: String) -> Dictionary:
	return Registry.by_id(all(), id)

static func label_for(id: String) -> String:
	return String(by_id(id).get("label", id))

static func description_for(id: String) -> String:
	return String(by_id(id).get("description", ""))

static func price_of(id: String) -> int:
	return int(by_id(id).get("price", 0))


# The stat id and threshold a perk's unlock gate names. {} for an unknown id.
static func unlock_of(id: String) -> Dictionary:
	return by_id(id).get("unlock", {})


# Whether `id`'s unlock stat has crossed its threshold, read off `profile`'s
# lifetime ledger. Pure — takes a profile dict rather than reaching into the Save
# autoload, so it is testable with a synthetic profile (mirrors
# RallyLibrary.engine_swaps_unlocked's own shape). False for an unknown id or one
# with no unlock block.
static func is_unlocked(id: String, profile: Dictionary) -> bool:
	var unlock := unlock_of(id)
	if unlock.is_empty():
		return false
	var stat := String(unlock.get("stat", ""))
	var threshold := int(unlock.get("threshold", 0))
	var lifetime: Dictionary = profile.get(Save.KEY_LIFETIME, {})
	return int(lifetime.get(stat, 0)) >= threshold


# Unlocked, but not yet bought — the state that puts a perk in front of the player
# with a price on it. False once bought (it moves to OWNED) and false while locked.
static func is_purchasable(id: String, profile: Dictionary) -> bool:
	if not is_unlocked(id, profile):
		return false
	return not (profile.get(Save.KEY_BOUGHT_PERKS, []) as Array).has(id)


# Display text for a locked row's gate — "Stat label: N". Falls back to the raw
# stat id if it names something LifetimeStats does not declare (a content bug this
# reads as a visible ugly label rather than a crash, which is what
# test_every_unlock_stat_is_a_real_lifetime_stat exists to catch before it ships).
static func unlock_label(id: String) -> String:
	var unlock := unlock_of(id)
	var stat := String(unlock.get("stat", ""))
	return "%s: %d" % [LifetimeStats.label_for(stat), int(unlock.get("threshold", 0))]
