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
# EFFECTS ARE WIRED (decision 51). Each entry's `effect_fields` maps an
# UpgradeLibrary.EFFECTS key onto the GameConfig field its magnitude is read from —
# the SAME shape BoostLibrary.CATALOGUE uses, deliberately, because it walks the SAME
# funnel: world.gd::_field_car merges `equipped_effects` into the fielded car's
# `boosts` list, and UpgradeLibrary.apply does the rest. Decision 51 requires exactly
# this ("the seam is UpgradeLibrary.EFFECTS + a car's boosts list; do not build a
# parallel modifier path"), so a perk that wants a new kind of effect adds an EFFECTS
# row + a GameConfig field, never a bespoke read at some call site.
#
# WHERE EACH PERK ACTUALLY LANDS — the field is the contract, the number is tunable:
#   coin_magnet   coin_pickup_radius_m   CoinField reads it live every physics tick
#   self_healing  damage_regen_hp_per_s  DamageModel.regen, on the damage tick
#   rubber_body   impact_ref_hp_loss     DamageModel.hp_loss_for_speed's reference
#   trail_blazer  run_fast_bonus_money   RegionRunMode.stage_money's time-saved bonus
#   lucky_coins   coins_per_stage        CoinLayout.plan's count, via coin_layout_params
#   iron_will     run_target_pace_base   RegionRunMode.target_pace, every stage
#   road_scholar  run_stage_money_base   RegionRunMode.stage_money's completion term
# All seven are GLOBAL config fields with no per-car re-seed, which is why each of
# their EFFECTS rows carries `reseed` — see UpgradeLibrary._reseed_globals.
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
		"effect_fields": {"coin_pickup_radius_mult": "perk_coin_radius_mult"},
	},
	{
		"id": "self_healing", "label": "Self Healing", "price": 8000,
		"description": "Slowly repairs damage while driving.",
		"unlock": {"stat": LifetimeStats.DAMAGE_TAKEN, "threshold": 300},
		"effect_fields": {"damage_regen_set": "perk_heal_hp_per_s"},
	},
	{
		"id": "trail_blazer", "label": "Trail Blazer", "price": 6000,
		"description": "Bigger fast-completion bonus.",
		"unlock": {"stat": LifetimeStats.MONEY_EARNED, "threshold": 5000},
		"effect_fields": {"fast_bonus_money_mult": "perk_fast_bonus_mult"},
	},
	{
		"id": "lucky_coins", "label": "Lucky Coins", "price": 7000,
		"description": "More coins spawn per stage.",
		"unlock": {"stat": LifetimeStats.MONEY_SPENT, "threshold": 5000},
		"effect_fields": {"coin_count_mult": "perk_coin_count_mult"},
	},
	{
		"id": "rubber_body", "label": "Rubber Body", "price": 9000,
		"description": "Takes less damage from impacts.",
		"unlock": {"stat": LifetimeStats.RUNS_FAILED, "threshold": 3},
		"effect_fields": {"impact_damage_mult": "perk_damage_mult"},
	},
	{
		"id": "iron_will", "label": "Iron Will", "price": 12000,
		# REWORDED with the wiring (it used to promise "a head start on the clock").
		# There is no run-wide clock to start ahead of — the timer is a PER-STAGE target
		# (decision 11, RegionRunMode.stage_target_ms), so the honest effect is a more
		# generous target on every stage, which is what run_target_pace_base moves.
		"description": "Every stage's target time is more generous.",
		"unlock": {"stat": LifetimeStats.REGIONS_CLEARED_TOTAL, "threshold": 2},
		"effect_fields": {"target_pace_add": "perk_target_pace_add"},
	},
	{
		"id": "road_scholar", "label": "Road Scholar", "price": 4000,
		# REWORDED with the wiring, same reason as iron_will: the payout it moves
		# (run_stage_money_base) is the base of EVERY stage clear, not a first-stage
		# special case — and singling out stage 1 would need a call-site branch, i.e.
		# exactly the parallel modifier path decision 51 rules out.
		"description": "Every stage clear pays a little more.",
		"unlock": {"stat": LifetimeStats.RUNS_STARTED, "threshold": 10},
		"effect_fields": {"stage_money_base_add": "perk_stage_money_add"},
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


# --- The effects seam (decision 51) -------------------------------------------

# The `effect` dict `id` resolves to RIGHT NOW, read live off Config.data field by
# field — never cached, so an inspector retune lands on the next stage boot. {} for an
# unknown id, and for an entry with no `effect_fields` (a catalogue entry may exist
# before its effect does; a missing effect must degrade to "does nothing", not error).
# Mirrors BoostLibrary.magnitude_for's shape exactly — same funnel, same contract.
static func effect_for(id: String) -> Dictionary:
	var fields: Dictionary = by_id(id).get("effect_fields", {})
	if fields.is_empty():
		return {}
	var cfg: GameConfig = Config.data
	var out := {}
	for effect_key in fields:
		out[effect_key] = float(cfg.get(String(fields[effect_key])))
	return out


# Every EQUIPPED perk's effect, in the exact shape UpgradeLibrary.active_effects reads
# ({"id": String, "effect": Dictionary}) so world.gd can append it straight onto the
# fielded car's `boosts` list.
#
# OWNED **AND** EQUIPPED. The cap (GameConfig.perk_max_equipped) is enforced once, in
# Save.equip_perk, but the ownership cross-check is repeated here on purpose: an
# equipped list that outlived its purchase (a hand-edited save, a schema migration, a
# refund path added later) must not quietly hand out a free effect. A perk with no
# `effect_fields` yet contributes nothing rather than an empty entry.
#
# Pure in `profile` — no Save read — so a synthetic profile exercises it with no
# autoload state, the same way is_unlocked/is_purchasable do.
static func equipped_effects(profile: Dictionary) -> Array:
	var bought: Array = profile.get(Save.KEY_BOUGHT_PERKS, [])
	var out: Array = []
	for id in (profile.get(Save.KEY_EQUIPPED_PERKS, []) as Array):
		var perk_id := String(id)
		if not bought.has(perk_id):
			continue
		var effect := effect_for(perk_id)
		if effect.is_empty():
			continue
		out.append({"id": perk_id, "effect": effect})
	return out
