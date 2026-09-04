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
]

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
