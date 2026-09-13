extends GutTest
# SkillLibrary (scripts/skill_library.gd) — the skill catalogue and its three-state gate
# (locked / purchasable / owned) — plus the Save-level purchase/equip mutators
# (buy_skill / equip_skill / unequip_skill).
#
# Per CLAUDE.md, skill *definitions* are authored data: nothing here may pin a shipped
# skill's price, threshold, or existence. Every state-machine assertion below runs
# against a SYNTHETIC roster installed via SkillLibrary.override_for_test(), never the
# shipped SKILLS table — the one exception is
# test_every_unlock_stat_is_a_real_lifetime_stat, which iterates the whole shipped
# table as OPAQUE input (CLAUDE.md's own carve-out: "iterating the whole table ... is
# fine — that's the code's contract, not a dependency on any one entry").

const FX_SKILLS: Array[Dictionary] = [
	{
		"id": "fx_cheap", "label": "Cheap Fixture Skill", "price": 100,
		"unlock": {"stat": "fx_stat", "threshold": 5},
	},
	{
		"id": "fx_pricey", "label": "Pricey Fixture Skill", "price": 999999,
		"unlock": {"stat": "fx_stat", "threshold": 5},
	},
	{
		"id": "fx_locked", "label": "Locked Fixture Skill", "price": 100,
		"unlock": {"stat": "fx_stat", "threshold": 1000},
	},
	{
		"id": "fx_no_gate", "label": "No-Gate Fixture Skill", "price": 100,
		"unlock": {"stat": "fx_never_written", "threshold": 0},
	},
	# Carries an EFFECT, for the equipped_effects/effect_for tests below. The EFFECTS
	# key and the GameConfig field are CODE names (a contract), not authored catalogue
	# data, so naming them here is fine; nothing below asserts the field's VALUE.
	{
		"id": "fx_effect", "label": "Effect Fixture Skill", "price": 100,
		"unlock": {"stat": "fx_stat", "threshold": 5},
		"effect_fields": {"coin_pickup_radius_mult": "skill_coin_radius_mult"},
	},
]

# The EFFECTS key / config field the fixture skill above uses, so a rename moves in one
# place.
const FX_EFFECT_KEY := "coin_pickup_radius_mult"
const FX_EFFECT_CFG_FIELD := "skill_coin_radius_mult"
const FX_EFFECT_TARGET := "coin_pickup_radius_m"

var _save: Node
var _prev_lifetime: Dictionary = {}
var _prev_money := 0
var _prev_bought: Array = []
var _prev_equipped: Array = []


func before_each() -> void:
	SkillLibrary.override_for_test(FX_SKILLS)
	_save = Save
	_prev_lifetime = (_save.profile.get(_save.KEY_LIFETIME, {}) as Dictionary).duplicate(true)
	_prev_money = _save.money()
	_prev_bought = (_save.profile.get(_save.KEY_BOUGHT_SKILLS, []) as Array).duplicate()
	_prev_equipped = (_save.profile.get(_save.KEY_EQUIPPED_SKILLS, []) as Array).duplicate()
	_save.profile[_save.KEY_LIFETIME] = {}
	_save.profile[_save.KEY_MONEY] = 0
	_save.profile[_save.KEY_BOUGHT_SKILLS] = []
	_save.profile[_save.KEY_EQUIPPED_SKILLS] = []


func after_each() -> void:
	SkillLibrary.reset()
	_save.profile[_save.KEY_LIFETIME] = _prev_lifetime
	_save.profile[_save.KEY_MONEY] = _prev_money
	_save.profile[_save.KEY_BOUGHT_SKILLS] = _prev_bought
	_save.profile[_save.KEY_EQUIPPED_SKILLS] = _prev_equipped


# --- Locked / purchasable / owned, kept apart --------------------------------------

func test_a_skill_below_its_threshold_is_locked_not_offered() -> void:
	_save.profile[_save.KEY_LIFETIME] = {"fx_stat": 4}  # one short of "fx_cheap"'s 5
	assert_false(SkillLibrary.is_unlocked("fx_cheap", _save.profile),
		"below threshold reads as locked")
	assert_false(SkillLibrary.is_purchasable("fx_cheap", _save.profile),
		"and never purchasable while locked")


func test_crossing_the_threshold_makes_it_purchasable_not_yet_owned() -> void:
	_save.profile[_save.KEY_LIFETIME] = {"fx_stat": 5}
	assert_true(SkillLibrary.is_unlocked("fx_cheap", _save.profile))
	assert_true(SkillLibrary.is_purchasable("fx_cheap", _save.profile),
		"unlocked and not yet bought = purchasable")
	assert_false(_save.owns_skill("fx_cheap"))


func test_buying_moves_it_from_purchasable_to_owned() -> void:
	_save.profile[_save.KEY_LIFETIME] = {"fx_stat": 5}
	_save.profile[_save.KEY_MONEY] = SkillLibrary.price_of("fx_cheap")
	assert_true(_save.buy_skill("fx_cheap"))
	assert_true(_save.owns_skill("fx_cheap"), "now owned")
	assert_false(SkillLibrary.is_purchasable("fx_cheap", _save.profile),
		"an owned skill is no longer offered as purchasable")


# --- buy_skill refusals leave the profile byte-identical ----------------------------

func test_buy_skill_refuses_while_locked_and_changes_nothing() -> void:
	_save.profile[_save.KEY_LIFETIME] = {"fx_stat": 0}
	_save.profile[_save.KEY_MONEY] = 999999
	var before: Dictionary = _save.profile.duplicate(true)
	assert_false(_save.buy_skill("fx_locked"), "still locked, however much money is on hand")
	assert_eq(_save.profile, before, "a refused purchase leaves the profile untouched")


func test_buy_skill_refuses_when_unaffordable_and_changes_nothing() -> void:
	_save.profile[_save.KEY_LIFETIME] = {"fx_stat": 5}
	_save.profile[_save.KEY_MONEY] = 0
	var before: Dictionary = _save.profile.duplicate(true)
	assert_false(_save.buy_skill("fx_pricey"), "unaffordable")
	assert_eq(_save.profile, before, "a refused purchase leaves the profile untouched")


func test_buy_skill_refuses_a_second_purchase_of_the_same_skill() -> void:
	_save.profile[_save.KEY_LIFETIME] = {"fx_stat": 5}
	_save.profile[_save.KEY_MONEY] = SkillLibrary.price_of("fx_cheap") * 5
	assert_true(_save.buy_skill("fx_cheap"), "setup: first purchase succeeds")
	var money_after_first: int = _save.money()
	assert_false(_save.buy_skill("fx_cheap"), "already owned — refused")
	assert_eq(_save.money(), money_after_first, "and nothing more is spent")


func test_buy_skill_refuses_an_unknown_id() -> void:
	_save.profile[_save.KEY_MONEY] = 999999
	var before: Dictionary = _save.profile.duplicate(true)
	assert_false(_save.buy_skill("fx_does_not_exist"))
	assert_eq(_save.profile, before, "an unknown id changes nothing")


# --- Equip cap -----------------------------------------------------------------

func test_equip_refuses_a_skill_that_is_not_owned() -> void:
	assert_false(_save.equip_skill("fx_cheap"), "cannot equip what you don't own")


func test_equipping_an_owned_skill_works_and_is_reflected_in_equipped_skills() -> void:
	_save.profile[_save.KEY_LIFETIME] = {"fx_stat": 5}
	_save.profile[_save.KEY_MONEY] = SkillLibrary.price_of("fx_cheap")
	_save.buy_skill("fx_cheap")
	assert_true(_save.equip_skill("fx_cheap"))
	assert_true(_save.skill_equipped("fx_cheap"))
	assert_true(_save.equipped_skills().has("fx_cheap"))


func test_at_most_skill_max_equipped_can_be_equipped() -> void:
	# Buy every fixture skill that has a distinct id and can be unlocked/afforded, then
	# try to equip past the cap. The cap itself is GameConfig.skill_max_equipped — a
	# tunable this test reads live rather than assuming any particular number.
	var extra: Array[Dictionary] = FX_SKILLS.duplicate(true)
	var cap := int(Config.data.skill_max_equipped)
	# Author one more fixture skill per cap slot (plus one to overflow it), so the test
	# holds however the cap is retuned rather than assuming it is small.
	for i in cap + 1:
		extra.append({
			"id": "fx_cap_%d" % i, "label": "Cap Fixture %d" % i, "price": 0,
			"unlock": {"stat": "fx_stat", "threshold": 0},
		})
	SkillLibrary.override_for_test(extra)
	_save.profile[_save.KEY_LIFETIME] = {"fx_stat": 5}
	_save.profile[_save.KEY_MONEY] = 0
	var equipped_count := 0
	for i in cap + 1:
		var id := "fx_cap_%d" % i
		assert_true(_save.buy_skill(id), "setup: free skill %s buys cleanly" % id)
		var ok: bool = _save.equip_skill(id)
		if ok:
			equipped_count += 1
	assert_eq(equipped_count, cap,
		"exactly skill_max_equipped skills could be equipped, not one more")
	assert_eq(_save.equipped_skills().size(), cap)


func test_unequip_frees_a_slot_for_another_skill() -> void:
	var cap := int(Config.data.skill_max_equipped)
	var extra: Array[Dictionary] = []
	for i in cap + 1:
		extra.append({
			"id": "fx_slot_%d" % i, "label": "Slot Fixture %d" % i, "price": 0,
			"unlock": {"stat": "fx_stat", "threshold": 0},
		})
	SkillLibrary.override_for_test(extra)
	_save.profile[_save.KEY_LIFETIME] = {"fx_stat": 1}
	for i in cap:
		_save.buy_skill("fx_slot_%d" % i)
		_save.equip_skill("fx_slot_%d" % i)
	assert_eq(_save.equipped_skills().size(), cap, "setup: full")
	_save.buy_skill("fx_slot_%d" % cap)
	assert_false(_save.equip_skill("fx_slot_%d" % cap), "setup: the cap refuses one more")
	assert_true(_save.unequip_skill("fx_slot_0"), "freeing a slot")
	assert_true(_save.equip_skill("fx_slot_%d" % cap),
		"and now the freed slot can take another skill")


# --- The unlock-gate vocabulary contract -------------------------------------------
# Iterates the WHOLE shipped table as opaque input (CLAUDE.md's carve-out) — this is
# the catalogue's contract, not a dependency on any one entry: every unlock.stat must
# name a real LifetimeStats id, or the gate is checking a counter that can never move.
func test_every_unlock_stat_is_a_real_lifetime_stat() -> void:
	SkillLibrary.reset()  # the SHIPPED table for this one test — see the header note
	for skill in SkillLibrary.all():
		var unlock: Dictionary = (skill as Dictionary).get("unlock", {})
		var stat := String(unlock.get("stat", ""))
		assert_true(LifetimeStats.is_known(stat),
			"skill '%s' unlocks on stat '%s', which LifetimeStats does not declare"
				% [(skill as Dictionary).get("id", "?"), stat])
	# after_each() re-overrides with FX_SKILLS regardless, so no restore needed here.

# Every shipped skill's gate must render IMPERATIVELY ("take 300 damage") — a stat
# declared without a "goal" template silently falls back to the stats page's read-out
# form ("Damage taken: 300"), which this test exists to catch at the table level
# rather than as a shipped wording bug.
func test_every_unlock_stat_has_an_imperative_goal_phrase() -> void:
	SkillLibrary.reset()  # the SHIPPED table for this one test — see the header note
	for skill in SkillLibrary.all():
		var unlock: Dictionary = (skill as Dictionary).get("unlock", {})
		var stat := String(unlock.get("stat", ""))
		var threshold := int(unlock.get("threshold", 0))
		var read_out_form := "%s: %d" % [LifetimeStats.label_for(stat), threshold]
		assert_ne(SkillLibrary.unlock_label(String((skill as Dictionary).get("id", ""))),
			read_out_form,
			("skill '%s' gates on stat '%s', which has no goal template — its gate would "
				+ "fall back to the read-out form") % [(skill as Dictionary).get("id", "?"), stat])


# --- The effects seam (decision 51) --------------------------------------------------

# The same guard test_boost_library.gd runs on the boost catalogue, for the same reason:
# an effect key with no EFFECTS row is DROPPED by UpgradeLibrary.apply — the skill reads
# as equipped, the config is untouched, and no gameplay test fails. Whole shipped table
# as opaque input.
func test_every_authored_effect_key_has_an_effects_row() -> void:
	SkillLibrary.reset()
	for skill in SkillLibrary.all():
		var fields: Dictionary = (skill as Dictionary).get("effect_fields", {})
		for effect_key in fields:
			assert_true(UpgradeLibrary.EFFECTS.has(effect_key),
				"skill '%s' authors effect '%s' with no EFFECTS row"
					% [(skill as Dictionary).get("id", "?"), effect_key])


# The other half of the same failure: a magnitude read from a GameConfig field that does
# not exist resolves to null, which float() turns into 0.0 — a silently dead skill.
func test_every_authored_magnitude_names_a_real_config_field() -> void:
	SkillLibrary.reset()
	var cfg := GameConfig.new()
	for skill in SkillLibrary.all():
		var fields: Dictionary = (skill as Dictionary).get("effect_fields", {})
		for effect_key in fields:
			var field := String(fields[effect_key])
			assert_true(field in cfg,
				"skill '%s' reads GameConfig.%s, which does not exist"
					% [(skill as Dictionary).get("id", "?"), field])


# DECISION 51'S OWN BAR: a skill whose description promises an effect it does not have is
# a visible defect. Every shipped skill must carry one — the state machine shipping ahead
# of the effects (stage 7) is exactly what this pass closed.
func test_every_shipped_skill_carries_an_effect() -> void:
	SkillLibrary.reset()
	for skill in SkillLibrary.all():
		var fields: Dictionary = (skill as Dictionary).get("effect_fields", {})
		assert_false(fields.is_empty(),
			"skill '%s' has no effect_fields — it would sit inert while its description promises otherwise"
				% (skill as Dictionary).get("id", "?"))


# effect_for re-reads Config.data every call rather than caching at load, so an inspector
# retune lands on the next stage boot. Asserts the RELATIONSHIP (the returned magnitude
# tracks the field), never a shipped number.
func test_effect_for_reads_the_config_field_live() -> void:
	var cfg: GameConfig = Config.data
	var original: float = cfg.get(FX_EFFECT_CFG_FIELD)
	cfg.set(FX_EFFECT_CFG_FIELD, 2.0)
	assert_eq(SkillLibrary.effect_for("fx_effect"), {FX_EFFECT_KEY: 2.0})
	cfg.set(FX_EFFECT_CFG_FIELD, 3.0)
	assert_eq(SkillLibrary.effect_for("fx_effect"), {FX_EFFECT_KEY: 3.0},
		"effect_for cached the magnitude instead of re-reading Config.data")
	cfg.set(FX_EFFECT_CFG_FIELD, original)


func test_effect_for_is_empty_for_an_unknown_id() -> void:
	assert_eq(SkillLibrary.effect_for("fx_nonexistent"), {})


# A skill with no effect_fields yet degrades to "does nothing" rather than erroring.
func test_effect_for_is_empty_for_a_skill_with_no_effect() -> void:
	assert_eq(SkillLibrary.effect_for("fx_cheap"), {})


func test_owned_but_unequipped_contributes_no_effect() -> void:
	_save.profile[_save.KEY_BOUGHT_SKILLS] = ["fx_effect"]
	_save.profile[_save.KEY_EQUIPPED_SKILLS] = []
	assert_eq(SkillLibrary.equipped_effects(_save.profile), [])


# The ownership cross-check equipped_effects repeats on purpose: an equipped list that
# outlived its purchase (a hand-edited save, a future refund path) must not hand out a
# free effect.
func test_equipped_but_unowned_contributes_no_effect() -> void:
	_save.profile[_save.KEY_BOUGHT_SKILLS] = []
	_save.profile[_save.KEY_EQUIPPED_SKILLS] = ["fx_effect"]
	assert_eq(SkillLibrary.equipped_effects(_save.profile), [])


# The shape is the contract: UpgradeLibrary.active_effects reads {"id", "effect"} entries,
# so this is what lets world.gd append skills straight onto the fielded car's boosts list.
func test_equipped_and_owned_yields_an_active_effect_entry() -> void:
	_save.profile[_save.KEY_BOUGHT_SKILLS] = ["fx_effect"]
	_save.profile[_save.KEY_EQUIPPED_SKILLS] = ["fx_effect"]
	var effects := SkillLibrary.equipped_effects(_save.profile)
	assert_eq(effects.size(), 1)
	var entry: Dictionary = effects[0]
	assert_eq(String(entry.get("id", "")), "fx_effect")
	assert_eq((entry.get("effect", {}) as Dictionary).keys(), [FX_EFFECT_KEY])


# THE END-TO-END SEAM, and the bug _reseed_globals exists to prevent. The skill's target is
# a GLOBAL config field with no per-car re-seed, so applying the same effect set twice —
# which is what a second stage boot does — must land on the SAME number, not compound.
func test_applying_the_same_skill_twice_does_not_compound() -> void:
	var cfg := GameConfig.new()
	var owned := {"boosts": [{"id": "fx_effect", "effect": {FX_EFFECT_KEY: 2.0}}]}
	UpgradeLibrary.apply(owned, cfg)
	var once: float = cfg.get(FX_EFFECT_TARGET)
	UpgradeLibrary.apply(owned, cfg)
	assert_almost_eq(float(cfg.get(FX_EFFECT_TARGET)), once, 1e-4,
		"a skill effect on a global field compounded across applies")
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
