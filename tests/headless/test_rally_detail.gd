extends GutTest
# The rally-detail card's eligibility read-out (features/menus.md). _eligibility_summary
# tallies how many of the player's OWNED cars can enter a rally, built on top of
# _entry_plan so the panel agrees exactly with the green/grey map pin. These tests use
# a synthetic CarFixtures roster + hand-authored restriction dicts (never the shipped
# catalogue) and assert the COUNTING behaviour, not any tuned restriction value.

const CarFixtures = preload("res://tests/headless/car_fixtures.gd")

var _hq: Node3D


func before_all() -> void:
	CarFixtures.install()


func after_all() -> void:
	CarFixtures.restore()


func before_each() -> void:
	_hq = load("res://hq.tscn").instantiate()
	add_child_autofree(_hq)
	await get_tree().process_frame


# A minimal OwnedCar dict — just the fields effective_meta / _entry_plan read.
func _owned(model_id: String, tuning := {}, upgrades := []) -> Dictionary:
	return {"model_id": model_id, "tuning": tuning, "installed_upgrades": upgrades}


# The car's power-to-weight (hp/tonne) at full tune, derived through the SAME helpers
# the code uses — so restrictions built relative to it survive a fixture retune.
func _pw(model_id: String) -> float:
	var entry := CarLibrary.by_id(model_id)
	var meta := UpgradeLibrary.effective_meta(_owned(model_id), entry)
	return CarLibrary.power_to_weight(meta) * CarLibrary.KW_KG_TO_HP_TONNE


func test_empty_roster_counts_nothing() -> void:
	var summary: Dictionary = _hq._eligibility_summary({"restriction": {}}, [])
	assert_eq(summary["total"], 0, "no owned cars means nothing to count")
	assert_eq(summary["qualify"], 0, "and nothing qualifies")


func test_unresolved_model_is_skipped_from_total() -> void:
	# An open-class rally admits any car; a stale model_id must not be counted at all
	# (and must not slip through effective_meta({}, {}) as a phantom qualifier).
	var roster := [_owned("fx_light_rwd"), _owned("model_that_was_removed")]
	var summary: Dictionary = _hq._eligibility_summary({"restriction": {}}, roster)
	assert_eq(summary["total"], 1, "the unresolved model is skipped, not counted in total")
	assert_eq(summary["qualify"], 1, "the one real car qualifies for open class")


func test_drive_mode_restriction_counts_only_matching_cars() -> void:
	# No swap kit owned, so a car in the wrong drive mode simply can't enter.
	var rally := {"restriction": {"drive_mode": CarFixtures.RWD}}
	var roster := [
		_owned("fx_light_rwd"), _owned("fx_fwd_hatch"),
		_owned("fx_rwd_coupe"), _owned("fx_awd"),
	]
	var summary: Dictionary = _hq._eligibility_summary(rally, roster)
	assert_eq(summary["total"], 4, "every resolvable car is counted in the roster size")
	assert_eq(summary["qualify"], 2, "only the RWD cars can enter this class")
	assert_eq(summary["adjust"], 0, "none needed a tune or swap to qualify")


func test_over_cap_car_lands_in_adjust_via_detune() -> void:
	# A ceiling just under the car's power-to-weight: it's over the cap, but tuning the
	# engine down ducks it under — so it qualifies, flagged as needing a tune to fit.
	var rally := {"restriction": {"pw_max": _pw("fx_rwd_coupe") * 0.9}}
	var summary: Dictionary = _hq._eligibility_summary(rally, [_owned("fx_rwd_coupe")])
	assert_eq(summary["qualify"], 1, "a detune brings it under the cap, so it qualifies")
	assert_eq(summary["adjust"], 1, "it counts as needing a tune / swap to fit")
	assert_eq(summary["underpowered"], 0, "a car at the cap isn't underpowered")


func test_stock_eligible_but_weak_car_flags_underpowered() -> void:
	# A ceiling far above the car's power-to-weight: eligible as-is, but well under the
	# class power recommendation (< 75% of the cap) — a non-blocking underpower warning.
	var rally := {"restriction": {"pw_max": _pw("fx_light_rwd") * 3.0}}
	var summary: Dictionary = _hq._eligibility_summary(rally, [_owned("fx_light_rwd")])
	assert_eq(summary["qualify"], 1, "it's under the cap, so it qualifies stock")
	assert_eq(summary["adjust"], 0, "no tune or swap was needed")
	assert_eq(summary["underpowered"], 1, "but it's far below the class power recommendation")


func test_entry_plan_flags_a_weak_stock_eligible_car_as_underpowered() -> void:
	var rally := {"restriction": {"pw_max": _pw("fx_light_rwd") * 3.0}}
	var plan: Dictionary = _hq._entry_plan(rally, _owned("fx_light_rwd"))
	assert_true(plan["eligible"], "under the cap, so it can enter")
	assert_true(plan["underpowered"], "but far under the ceiling — flagged underpowered")


func test_entry_plan_detuned_car_is_not_underpowered() -> void:
	# A detune that just ducks the cap leaves the car near the ceiling, not underpowered.
	var rally := {"restriction": {"pw_max": _pw("fx_rwd_coupe") * 0.9}}
	var plan: Dictionary = _hq._entry_plan(rally, _owned("fx_rwd_coupe"))
	assert_true(plan["eligible"], "a detune qualifies it")
	assert_gt(float(plan["detune"]), 0.0, "it needs a detune to fit")
	assert_false(plan["underpowered"], "detuned to just under the cap isn't underpowered")


func test_underpower_is_judged_at_full_potential_not_current_detune() -> void:
	# The car is strong at full tune; only its CURRENT detune makes it look weak. Since
	# the player can always tune back to 100%, it must NOT be branded underpowered.
	var full_pw := _pw("fx_rwd_coupe")
	# Ceiling = 1.2x full pw → recommendation (75%) = 0.9x full pw. At full tune the car
	# (pw = full_pw) clears it; detuned to 50% (pw = 0.5x) it would fall under.
	var rally := {"restriction": {"pw_max": full_pw * 1.2}}
	var owned := _owned("fx_rwd_coupe", {"engine_detune": 0.5})
	var plan: Dictionary = _hq._entry_plan(rally, owned)
	assert_true(plan["eligible"], "under the cap at its current detune, so eligible")
	assert_false(plan["underpowered"], "judged at full potential (100% tune), not the current detune")


func test_ballast_does_not_make_a_car_read_underpowered() -> void:
	# Adding heavy ballast lowers p/w, but the player can always shed it — so a ballasted
	# car must not be branded underpowered / made ineligible. Underpower is judged at the
	# car's max achievable p/w (ballast removed), not its current ballasted state.
	var base_pw := _pw("fx_rwd_coupe")  # full tune, no ballast
	# Cap at the car's base p/w: with ballast it's comfortably under (eligible) and would
	# look underpowered on current stats; ballast removed it's right at the ceiling.
	var rally := {"restriction": {"pw_max": base_pw}}
	var owned := _owned("fx_rwd_coupe", {}, ["ballast_large"])
	var plan: Dictionary = _hq._entry_plan(rally, owned)
	assert_true(plan["eligible"], "ballasted car sits under the cap → eligible")
	assert_false(plan["underpowered"], "removing the ballast restores power → not underpowered")


func test_pin_unavailable_when_only_eligible_cars_are_underpowered() -> void:
	# _has_eligible_car drives the green (available) vs grey (unavailable) map pin; an
	# underpowered-only roster must leave the pin unavailable, same as owning no car.
	var saved: Array = Save.profile.get("cars", [])
	Save.profile["cars"] = [_owned("fx_light_rwd")]
	var weak_rally := {"restriction": {"pw_max": _pw("fx_light_rwd") * 3.0}}
	assert_false(_hq._has_eligible_car(weak_rally),
		"an underpowered-only roster leaves the pin unavailable")
	assert_true(_hq._has_eligible_car({"restriction": {}}),
		"the same car makes an open-class rally available")
	Save.profile["cars"] = saved
