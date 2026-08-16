extends GutTest
# The Auto-Upgrade solver (UpgradeLibrary.auto_build_plan) — the pure "best build this
# car can have right now" rule shared by the Auto-Upgrade button and the free restore at
# the Start gate. See todo/simplified-upgrade-menu.md §4.
#
# Everything here runs against the SYNTHETIC upgrade roster (UpgradeFixtures) and
# hand-built car metas, never the shipped catalogue: the solver's contract is about
# gates, budgets and the objective, not about which parts happen to be authored.


const TEST_PATH := "user://test_auto_build.json"

var _price_before := 0
var _save: Node = null


func before_each() -> void:
	CarFixtures.install()
	UpgradeFixtures.install()
	_price_before = int(Config.data.star_cost_per_part)
	_save = SaveTestHelpers.redirect(TEST_PATH)


func after_each() -> void:
	SaveTestHelpers.cleanup(TEST_PATH)
	Config.data.star_cost_per_part = _price_before
	UpgradeFixtures.restore()
	CarFixtures.restore()


# A car meta with just the fields power-to-weight and eligibility read.
func _meta(extra := {}) -> Dictionary:
	var m := {"mass": 1200.0, "peak_torque": 300.0, "redline": 6000.0,
		"drive_mode": CarLibrary.RWD, "car_type": "hatch", "doors": 3, "country": "jp"}
	for k in extra:
		m[k] = extra[k]
	return m


func _car(installed: Array = [], disabled: Array = [], detune := 1.0) -> Dictionary:
	return {"installed_upgrades": installed.duplicate(), "disabled_upgrades": disabled.duplicate(),
		"tuning": {"engine_detune": detune}}


func _pw(car: Dictionary, meta: Dictionary) -> float:
	return CarLibrary.power_to_weight_hp_tonne(UpgradeLibrary.effective_meta(car, meta))


# The figure the solver actually optimises. merged_meta, not effective_meta — the rating
# must see tyres and downforce too.
func _rating(car: Dictionary, meta: Dictionary) -> int:
	return CarPerformance.rating(CarPerformance.merged_meta(car, meta))


# The car as the plan would leave it — the thing every "the result is legal" assertion
# below actually has to judge.
func _applied(car: Dictionary, plan: Dictionary) -> Dictionary:
	var out := car.duplicate(true)
	var installed: Array = (out["installed_upgrades"] as Array).duplicate()
	var disabled: Array = (out["disabled_upgrades"] as Array).duplicate()
	for item_id in plan["buy"]:
		installed.append(item_id)
	for item_id in (plan["buy"] as Array) + (plan["enable"] as Array):
		disabled.erase(item_id)
	for item_id in plan["strip"]:
		if not disabled.has(item_id):
			disabled.append(item_id)
	out["installed_upgrades"] = installed
	out["disabled_upgrades"] = disabled
	out["tuning"] = {"engine_detune": float(plan["detune"])}
	return out


# --- Gates and budget ---------------------------------------------------------

func test_plan_never_buys_an_undiscovered_part() -> void:
	# fx_gated is the fixture's star-gated part and would otherwise win the weight slot
	# outright; an empty profile means its rally has not been won.
	var plan := UpgradeLibrary.auto_build_plan(_car(), _meta(), {"rallies": {}}, 999)
	assert_false((plan["buy"] as Array).has("fx_gated"), "a locked part is never in the plan")
	# ... and IS bought once its gate opens, so the exclusion above is the gate talking
	# and not the solver simply ignoring the slot.
	var open := {"rallies": {UpgradeFixtures.FX_GATE_RALLY: {"completed": true}}}
	var plan2 := UpgradeLibrary.auto_build_plan(_car(), _meta(), open, 999)
	assert_true((plan2["buy"] as Array).has("fx_gated"), "an unlocked part becomes buyable")


func test_plan_never_breaks_the_prerequisite_ladder() -> void:
	# fx_supercharger requires fx_turbo_big on THIS car.
	var plan := UpgradeLibrary.auto_build_plan(_car(), _meta(), {"rallies": {}}, 999)
	assert_false((plan["buy"] as Array).has("fx_supercharger"),
		"a part whose prerequisite is unmet is never bought")
	var plan2 := UpgradeLibrary.auto_build_plan(
		_car(["fx_turbo_big"]), _meta(), {"rallies": {}}, 999)
	assert_true((plan2["buy"] as Array).has("fx_supercharger"),
		"with the prerequisite fitted it becomes buyable")


func test_plan_never_costs_more_than_the_balance() -> void:
	var price := int(Config.data.star_cost_per_part)
	for stars in [0, price, price * 2]:
		var plan := UpgradeLibrary.auto_build_plan(_car(), _meta(), {"rallies": {}}, stars)
		assert_true(int(plan["cost"]) <= stars,
			"a plan on %d stars costs at most %d" % [stars, stars])


func test_a_car_at_its_ceiling_yields_an_empty_plan() -> void:
	var car := _car(["fx_turbo_big", "fx_lightweight"])
	var plan := UpgradeLibrary.auto_build_plan(car, _meta(), {"rallies": {}}, 0)
	assert_eq(int(plan["cost"]), 0, "nothing to buy costs nothing")
	assert_false(bool(plan["changed"]), "a car already at its reachable ceiling is a no-op")


# --- The rating objective -----------------------------------------------------
#
# The solver scores builds by CarPerformance rating, not by power-to-weight: p/w was the
# old eligibility currency, and a solver still maximising it could pick a build the game
# now calls slower. There is no ceiling term — a Rally Challenge ceiling is an
# eligibility line its host filters against, never something the solver optimises towards.

func test_unconstrained_plan_maximises_the_rating() -> void:
	var meta := _meta()
	var car := _car()
	var plan := UpgradeLibrary.auto_build_plan(car, meta, {"rallies": {}}, 999)
	assert_true(bool(plan["changed"]), "an empty car has something to gain")
	assert_gt(_rating(_applied(car, plan), meta), _rating(car, meta),
		"the plan raises the performance rating")


# --- Ballast ------------------------------------------------------------------

func test_plan_never_fits_ballast() -> void:
	var meta := _meta()
	for car in [_car(), _car(["fx_turbo_big"]), _car(["fx_turbo_big", "fx_lightweight"])]:
		var plan := UpgradeLibrary.auto_build_plan(car, meta, {"rallies": {}}, 999)
		var touched: Array = (plan["buy"] as Array) + (plan["enable"] as Array)
		assert_false(touched.has("fx_ballast"), "ballast is never fitted")


func test_plan_strips_ballast_the_player_left_on() -> void:
	var meta := _meta()
	var car := _car(["fx_ballast"])
	var plan := UpgradeLibrary.auto_build_plan(car, meta, {"rallies": {}}, 0)
	assert_true((plan["strip"] as Array).has("fx_ballast"), "ballast is stripped")
	assert_gt(_rating(_applied(car, plan), meta), _rating(car, meta),
		"which is what makes the car faster")


# --- What Auto must not pretend to fix ---------------------------------------

func test_an_unfixable_restriction_is_named_not_planned_around() -> void:
	var plan := UpgradeLibrary.auto_build_plan(
		_car(), _meta(), {"rallies": {}}, 999, {"car_type": "supercar"})
	assert_ne(String(plan["blocked"]), "", "a wrong-car restriction is reported, not solved")


func test_drivetrain_is_fixed_when_the_kit_is_fitted() -> void:
	var restriction := {"drive_mode": CarLibrary.AWD}
	var without := UpgradeLibrary.auto_build_plan(
		_car(), _meta(), {"rallies": {}}, 0, restriction)
	assert_ne(String(without["blocked"]), "", "without the kit the drivetrain is a wrong-car report")
	var with_kit := UpgradeLibrary.auto_build_plan(
		_car(["fx_drivetrain"]), _meta(), {"rallies": {}}, 0, restriction)
	assert_eq(String(with_kit["blocked"]), "", "with the kit fitted the drivetrain is fixable")
	assert_eq(int(with_kit["drivetrain"]), CarLibrary.AWD, "and the plan switches to the demanded mode")


# --- Free-only restore --------------------------------------------------------

func test_free_only_buys_nothing_even_at_zero_price() -> void:
	# The flag is not a budget check: a designer zeroing star_cost_per_part must not
	# silently turn a free restore into a shopping spree.
	Config.data.star_cost_per_part = 0
	var plan := UpgradeLibrary.auto_build_plan(
		_car(), _meta(), {"rallies": {}}, 999, {}, true)
	assert_true((plan["buy"] as Array).is_empty(), "free-only never buys, at any price")
	assert_eq(int(plan["cost"]), 0, "and therefore costs nothing")


func test_free_only_enables_an_owned_but_parked_part() -> void:
	var meta := _meta()
	var car := _car(["fx_turbo_big"], ["fx_turbo_big"])
	var plan := UpgradeLibrary.auto_build_plan(car, meta, {"rallies": {}}, 0, {}, true)
	assert_true((plan["enable"] as Array).has("fx_turbo_big"), "a parked part is switched on")
	assert_gt(_pw(_applied(car, plan), meta), _pw(car, meta), "which is a real gain")


func test_free_only_predicate_is_plan_difference_not_power() -> void:
	# Swapping ballast for an equivalent detune lands the same power-to-weight with more
	# grip, so a power comparison would wrongly call this car fully utilised.
	var meta := _meta()
	var car := _car(["fx_turbo_big", "fx_ballast"])
	var plan := UpgradeLibrary.auto_build_plan(car, meta, {"rallies": {}}, 0, {}, true)
	assert_true((plan["strip"] as Array).has("fx_ballast"), "the ballast comes off")
	assert_true(bool(plan["changed"]), "and the restore reports itself as worth doing")


func test_free_only_on_a_utilised_car_is_quiet() -> void:
	var car := _car(["fx_turbo_big", "fx_lightweight"])
	var plan := UpgradeLibrary.auto_build_plan(car, _meta(), {"rallies": {}}, 999, {}, true)
	assert_false(bool(plan["changed"]), "a fully-utilised car keeps the gate quiet")


# --- Committing a plan through the save --------------------------------------

func _granted(installed: Array = [], detune := 1.0) -> int:
	var car: Dictionary = _save.grant_car("fx_light_rwd")
	var id := int(car["instance_id"])
	for item_id in installed:
		car["installed_upgrades"].append(item_id)
	_save.set_engine_detune(id, detune)
	return id


func test_apply_build_plan_commits_buys_enables_and_strips() -> void:
	var id := _granted(["fx_turbo_big", "fx_ballast"])
	_save.set_upgrade_enabled(id, "fx_ballast", true)
	_save.set_upgrade_enabled(id, "fx_turbo_big", false)
	var car: Dictionary = _save.get_car(id)
	var meta := CarLibrary.by_id(String(car["model_id"]))
	var plan := UpgradeLibrary.auto_build_plan(car, meta, _save.profile as Dictionary, 0, {}, true)
	assert_true(_save.apply_build_plan(id, plan), "a plan with work in it applies")
	var after: Dictionary = _save.get_car(id)
	assert_true(UpgradeLibrary.is_enabled(after, "fx_turbo_big"), "the parked turbo is switched on")
	assert_false(UpgradeLibrary.is_enabled(after, "fx_ballast"), "the ballast is parked")


func test_apply_build_plan_ignores_a_no_op_plan() -> void:
	var id := _granted(["fx_turbo_big"])
	var car: Dictionary = _save.get_car(id)
	var plan := UpgradeLibrary.auto_build_plan(
		car, CarLibrary.by_id(String(car["model_id"])), _save.profile as Dictionary, 0, {}, true)
	assert_false(_save.apply_build_plan(id, plan), "a no-op plan applies nothing")


# There is deliberately NO auto-restore at the start gate. Switching a player's parts
# back on for them behind a loading screen is an edit they never asked for and cannot
# watch happen; the car races exactly the build they left it on. apply_build_plan below
# is still how the Auto button commits a plan the player pressed for.
