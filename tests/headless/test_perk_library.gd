extends GutTest
# PerkLibrary (scripts/perk_library.gd) — the perk catalogue and its three-state gate
# (locked / purchasable / owned) — plus the Save-level purchase/equip mutators
# (buy_perk / equip_perk / unequip_perk).
#
# Per CLAUDE.md, perk *definitions* are authored data: nothing here may pin a shipped
# perk's price, threshold, or existence. Every state-machine assertion below runs
# against a SYNTHETIC roster installed via PerkLibrary.override_for_test(), never the
# shipped PERKS table — the one exception is
# test_every_unlock_stat_is_a_real_lifetime_stat, which iterates the whole shipped
# table as OPAQUE input (CLAUDE.md's own carve-out: "iterating the whole table ... is
# fine — that's the code's contract, not a dependency on any one entry").

const FX_PERKS: Array[Dictionary] = [
	{
		"id": "fx_cheap", "label": "Cheap Fixture Perk", "price": 100,
		"unlock": {"stat": "fx_stat", "threshold": 5},
	},
	{
		"id": "fx_pricey", "label": "Pricey Fixture Perk", "price": 999999,
		"unlock": {"stat": "fx_stat", "threshold": 5},
	},
	{
		"id": "fx_locked", "label": "Locked Fixture Perk", "price": 100,
		"unlock": {"stat": "fx_stat", "threshold": 1000},
	},
	{
		"id": "fx_no_gate", "label": "No-Gate Fixture Perk", "price": 100,
		"unlock": {"stat": "fx_never_written", "threshold": 0},
	},
	# Carries an EFFECT, for the equipped_effects/effect_for tests below. The EFFECTS
	# key and the GameConfig field are CODE names (a contract), not authored catalogue
	# data, so naming them here is fine; nothing below asserts the field's VALUE.
	{
		"id": "fx_effect", "label": "Effect Fixture Perk", "price": 100,
		"unlock": {"stat": "fx_stat", "threshold": 5},
		"effect_fields": {"coin_pickup_radius_mult": "perk_coin_radius_mult"},
	},
]

# The EFFECTS key / config field the fixture perk above uses, so a rename moves in one
# place.
const FX_EFFECT_KEY := "coin_pickup_radius_mult"
const FX_EFFECT_CFG_FIELD := "perk_coin_radius_mult"
const FX_EFFECT_TARGET := "coin_pickup_radius_m"

var _save: Node
var _prev_lifetime: Dictionary = {}
var _prev_money := 0
var _prev_bought: Array = []
var _prev_equipped: Array = []


func before_each() -> void:
	PerkLibrary.override_for_test(FX_PERKS)
	_save = Save
	_prev_lifetime = (_save.profile.get(_save.KEY_LIFETIME, {}) as Dictionary).duplicate(true)
	_prev_money = _save.money()
	_prev_bought = (_save.profile.get(_save.KEY_BOUGHT_PERKS, []) as Array).duplicate()
	_prev_equipped = (_save.profile.get(_save.KEY_EQUIPPED_PERKS, []) as Array).duplicate()
	_save.profile[_save.KEY_LIFETIME] = {}
	_save.profile[_save.KEY_MONEY] = 0
	_save.profile[_save.KEY_BOUGHT_PERKS] = []
	_save.profile[_save.KEY_EQUIPPED_PERKS] = []


func after_each() -> void:
	PerkLibrary.reset()
	_save.profile[_save.KEY_LIFETIME] = _prev_lifetime
	_save.profile[_save.KEY_MONEY] = _prev_money
	_save.profile[_save.KEY_BOUGHT_PERKS] = _prev_bought
	_save.profile[_save.KEY_EQUIPPED_PERKS] = _prev_equipped


# --- Locked / purchasable / owned, kept apart --------------------------------------

func test_a_perk_below_its_threshold_is_locked_not_offered() -> void:
	_save.profile[_save.KEY_LIFETIME] = {"fx_stat": 4}  # one short of "fx_cheap"'s 5
	assert_false(PerkLibrary.is_unlocked("fx_cheap", _save.profile),
		"below threshold reads as locked")
	assert_false(PerkLibrary.is_purchasable("fx_cheap", _save.profile),
		"and never purchasable while locked")


func test_crossing_the_threshold_makes_it_purchasable_not_yet_owned() -> void:
	_save.profile[_save.KEY_LIFETIME] = {"fx_stat": 5}
	assert_true(PerkLibrary.is_unlocked("fx_cheap", _save.profile))
	assert_true(PerkLibrary.is_purchasable("fx_cheap", _save.profile),
		"unlocked and not yet bought = purchasable")
	assert_false(_save.owns_perk("fx_cheap"))


func test_buying_moves_it_from_purchasable_to_owned() -> void:
	_save.profile[_save.KEY_LIFETIME] = {"fx_stat": 5}
	_save.profile[_save.KEY_MONEY] = PerkLibrary.price_of("fx_cheap")
	assert_true(_save.buy_perk("fx_cheap"))
	assert_true(_save.owns_perk("fx_cheap"), "now owned")
	assert_false(PerkLibrary.is_purchasable("fx_cheap", _save.profile),
		"an owned perk is no longer offered as purchasable")


# --- buy_perk refusals leave the profile byte-identical ----------------------------

func test_buy_perk_refuses_while_locked_and_changes_nothing() -> void:
	_save.profile[_save.KEY_LIFETIME] = {"fx_stat": 0}
	_save.profile[_save.KEY_MONEY] = 999999
	var before: Dictionary = _save.profile.duplicate(true)
	assert_false(_save.buy_perk("fx_locked"), "still locked, however much money is on hand")
	assert_eq(_save.profile, before, "a refused purchase leaves the profile untouched")


func test_buy_perk_refuses_when_unaffordable_and_changes_nothing() -> void:
	_save.profile[_save.KEY_LIFETIME] = {"fx_stat": 5}
	_save.profile[_save.KEY_MONEY] = 0
	var before: Dictionary = _save.profile.duplicate(true)
	assert_false(_save.buy_perk("fx_pricey"), "unaffordable")
	assert_eq(_save.profile, before, "a refused purchase leaves the profile untouched")


func test_buy_perk_refuses_a_second_purchase_of_the_same_perk() -> void:
	_save.profile[_save.KEY_LIFETIME] = {"fx_stat": 5}
	_save.profile[_save.KEY_MONEY] = PerkLibrary.price_of("fx_cheap") * 5
	assert_true(_save.buy_perk("fx_cheap"), "setup: first purchase succeeds")
	var money_after_first: int = _save.money()
	assert_false(_save.buy_perk("fx_cheap"), "already owned — refused")
	assert_eq(_save.money(), money_after_first, "and nothing more is spent")


func test_buy_perk_refuses_an_unknown_id() -> void:
	_save.profile[_save.KEY_MONEY] = 999999
	var before: Dictionary = _save.profile.duplicate(true)
	assert_false(_save.buy_perk("fx_does_not_exist"))
	assert_eq(_save.profile, before, "an unknown id changes nothing")


# --- Equip cap -----------------------------------------------------------------

func test_equip_refuses_a_perk_that_is_not_owned() -> void:
	assert_false(_save.equip_perk("fx_cheap"), "cannot equip what you don't own")


func test_equipping_an_owned_perk_works_and_is_reflected_in_equipped_perks() -> void:
	_save.profile[_save.KEY_LIFETIME] = {"fx_stat": 5}
	_save.profile[_save.KEY_MONEY] = PerkLibrary.price_of("fx_cheap")
	_save.buy_perk("fx_cheap")
	assert_true(_save.equip_perk("fx_cheap"))
	assert_true(_save.perk_equipped("fx_cheap"))
	assert_true(_save.equipped_perks().has("fx_cheap"))


func test_at_most_perk_max_equipped_can_be_equipped() -> void:
	# Buy every fixture perk that has a distinct id and can be unlocked/afforded, then
	# try to equip past the cap. The cap itself is GameConfig.perk_max_equipped — a
	# tunable this test reads live rather than assuming any particular number.
	var extra: Array[Dictionary] = FX_PERKS.duplicate(true)
	var cap := int(Config.data.perk_max_equipped)
	# Author one more fixture perk per cap slot (plus one to overflow it), so the test
	# holds however the cap is retuned rather than assuming it is small.
	for i in cap + 1:
		extra.append({
			"id": "fx_cap_%d" % i, "label": "Cap Fixture %d" % i, "price": 0,
			"unlock": {"stat": "fx_stat", "threshold": 0},
		})
	PerkLibrary.override_for_test(extra)
	_save.profile[_save.KEY_LIFETIME] = {"fx_stat": 5}
	_save.profile[_save.KEY_MONEY] = 0
	var equipped_count := 0
	for i in cap + 1:
		var id := "fx_cap_%d" % i
		assert_true(_save.buy_perk(id), "setup: free perk %s buys cleanly" % id)
		var ok: bool = _save.equip_perk(id)
		if ok:
			equipped_count += 1
	assert_eq(equipped_count, cap,
		"exactly perk_max_equipped perks could be equipped, not one more")
	assert_eq(_save.equipped_perks().size(), cap)


func test_unequip_frees_a_slot_for_another_perk() -> void:
	var cap := int(Config.data.perk_max_equipped)
	var extra: Array[Dictionary] = []
	for i in cap + 1:
		extra.append({
			"id": "fx_slot_%d" % i, "label": "Slot Fixture %d" % i, "price": 0,
			"unlock": {"stat": "fx_stat", "threshold": 0},
		})
	PerkLibrary.override_for_test(extra)
	_save.profile[_save.KEY_LIFETIME] = {"fx_stat": 1}
	for i in cap:
		_save.buy_perk("fx_slot_%d" % i)
		_save.equip_perk("fx_slot_%d" % i)
	assert_eq(_save.equipped_perks().size(), cap, "setup: full")
	_save.buy_perk("fx_slot_%d" % cap)
	assert_false(_save.equip_perk("fx_slot_%d" % cap), "setup: the cap refuses one more")
	assert_true(_save.unequip_perk("fx_slot_0"), "freeing a slot")
	assert_true(_save.equip_perk("fx_slot_%d" % cap),
		"and now the freed slot can take another perk")


# --- The unlock-gate vocabulary contract -------------------------------------------
# Iterates the WHOLE shipped table as opaque input (CLAUDE.md's carve-out) — this is
# the catalogue's contract, not a dependency on any one entry: every unlock.stat must
# name a real LifetimeStats id, or the gate is checking a counter that can never move.
func test_every_unlock_stat_is_a_real_lifetime_stat() -> void:
	PerkLibrary.reset()  # the SHIPPED table for this one test — see the header note
	for perk in PerkLibrary.all():
		var unlock: Dictionary = (perk as Dictionary).get("unlock", {})
		var stat := String(unlock.get("stat", ""))
		assert_true(LifetimeStats.is_known(stat),
			"perk '%s' unlocks on stat '%s', which LifetimeStats does not declare"
				% [(perk as Dictionary).get("id", "?"), stat])
	# after_each() re-overrides with FX_PERKS regardless, so no restore needed here.


# --- The effects seam (decision 51) --------------------------------------------------

# The same guard test_boost_library.gd runs on the boost catalogue, for the same reason:
# an effect key with no EFFECTS row is DROPPED by UpgradeLibrary.apply — the perk reads
# as equipped, the config is untouched, and no gameplay test fails. Whole shipped table
# as opaque input.
func test_every_authored_effect_key_has_an_effects_row() -> void:
	PerkLibrary.reset()
	for perk in PerkLibrary.all():
		var fields: Dictionary = (perk as Dictionary).get("effect_fields", {})
		for effect_key in fields:
			assert_true(UpgradeLibrary.EFFECTS.has(effect_key),
				"perk '%s' authors effect '%s' with no EFFECTS row"
					% [(perk as Dictionary).get("id", "?"), effect_key])


# The other half of the same failure: a magnitude read from a GameConfig field that does
# not exist resolves to null, which float() turns into 0.0 — a silently dead perk.
func test_every_authored_magnitude_names_a_real_config_field() -> void:
	PerkLibrary.reset()
	var cfg := GameConfig.new()
	for perk in PerkLibrary.all():
		var fields: Dictionary = (perk as Dictionary).get("effect_fields", {})
		for effect_key in fields:
			var field := String(fields[effect_key])
			assert_true(field in cfg,
				"perk '%s' reads GameConfig.%s, which does not exist"
					% [(perk as Dictionary).get("id", "?"), field])


# DECISION 51'S OWN BAR: a perk whose description promises an effect it does not have is
# a visible defect. Every shipped perk must carry one — the state machine shipping ahead
# of the effects (stage 7) is exactly what this pass closed.
func test_every_shipped_perk_carries_an_effect() -> void:
	PerkLibrary.reset()
	for perk in PerkLibrary.all():
		var fields: Dictionary = (perk as Dictionary).get("effect_fields", {})
		assert_false(fields.is_empty(),
			"perk '%s' has no effect_fields — it would sit inert while its description promises otherwise"
				% (perk as Dictionary).get("id", "?"))


# effect_for re-reads Config.data every call rather than caching at load, so an inspector
# retune lands on the next stage boot. Asserts the RELATIONSHIP (the returned magnitude
# tracks the field), never a shipped number.
func test_effect_for_reads_the_config_field_live() -> void:
	var cfg: GameConfig = Config.data
	var original: float = cfg.get(FX_EFFECT_CFG_FIELD)
	cfg.set(FX_EFFECT_CFG_FIELD, 2.0)
	assert_eq(PerkLibrary.effect_for("fx_effect"), {FX_EFFECT_KEY: 2.0})
	cfg.set(FX_EFFECT_CFG_FIELD, 3.0)
	assert_eq(PerkLibrary.effect_for("fx_effect"), {FX_EFFECT_KEY: 3.0},
		"effect_for cached the magnitude instead of re-reading Config.data")
	cfg.set(FX_EFFECT_CFG_FIELD, original)


func test_effect_for_is_empty_for_an_unknown_id() -> void:
	assert_eq(PerkLibrary.effect_for("fx_nonexistent"), {})


# A perk with no effect_fields yet degrades to "does nothing" rather than erroring.
func test_effect_for_is_empty_for_a_perk_with_no_effect() -> void:
	assert_eq(PerkLibrary.effect_for("fx_cheap"), {})


func test_owned_but_unequipped_contributes_no_effect() -> void:
	_save.profile[_save.KEY_BOUGHT_PERKS] = ["fx_effect"]
	_save.profile[_save.KEY_EQUIPPED_PERKS] = []
	assert_eq(PerkLibrary.equipped_effects(_save.profile), [])


# The ownership cross-check equipped_effects repeats on purpose: an equipped list that
# outlived its purchase (a hand-edited save, a future refund path) must not hand out a
# free effect.
func test_equipped_but_unowned_contributes_no_effect() -> void:
	_save.profile[_save.KEY_BOUGHT_PERKS] = []
	_save.profile[_save.KEY_EQUIPPED_PERKS] = ["fx_effect"]
	assert_eq(PerkLibrary.equipped_effects(_save.profile), [])


# The shape is the contract: UpgradeLibrary.active_effects reads {"id", "effect"} entries,
# so this is what lets world.gd append perks straight onto the fielded car's boosts list.
func test_equipped_and_owned_yields_an_active_effect_entry() -> void:
	_save.profile[_save.KEY_BOUGHT_PERKS] = ["fx_effect"]
	_save.profile[_save.KEY_EQUIPPED_PERKS] = ["fx_effect"]
	var effects := PerkLibrary.equipped_effects(_save.profile)
	assert_eq(effects.size(), 1)
	var entry: Dictionary = effects[0]
	assert_eq(String(entry.get("id", "")), "fx_effect")
	assert_eq((entry.get("effect", {}) as Dictionary).keys(), [FX_EFFECT_KEY])


# THE END-TO-END SEAM, and the bug _reseed_globals exists to prevent. The perk's target is
# a GLOBAL config field with no per-car re-seed, so applying the same effect set twice —
# which is what a second stage boot does — must land on the SAME number, not compound.
func test_applying_the_same_perk_twice_does_not_compound() -> void:
	var cfg := GameConfig.new()
	var owned := {"boosts": [{"id": "fx_effect", "effect": {FX_EFFECT_KEY: 2.0}}]}
	UpgradeLibrary.apply(owned, cfg)
	var once: float = cfg.get(FX_EFFECT_TARGET)
	UpgradeLibrary.apply(owned, cfg)
	assert_almost_eq(float(cfg.get(FX_EFFECT_TARGET)), once, 1e-4,
		"a perk effect on a global field compounded across applies")
	# ...and it did MOVE the field in the first place, or the assertion above is vacuous.
	var authored := float(Config.authored_value(FX_EFFECT_TARGET, 0.0))
	assert_almost_eq(once, authored * 2.0, 1e-4)


# The other half of reseed: un-equipping gives the authored number back. Nothing else
# re-seeds these fields, so without the pre-pass the last multiplier would stick forever.
func test_unequipping_restores_the_authored_value() -> void:
	var cfg := GameConfig.new()
	UpgradeLibrary.apply({"boosts": [{"id": "fx_effect", "effect": {FX_EFFECT_KEY: 2.0}}]}, cfg)
	UpgradeLibrary.apply({"boosts": []}, cfg)
	assert_almost_eq(float(cfg.get(FX_EFFECT_TARGET)),
		float(Config.authored_value(FX_EFFECT_TARGET, 0.0)), 1e-4)
