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
	UpgradeFixtures.install()


func after_all() -> void:
	CarFixtures.restore()
	UpgradeFixtures.restore()


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


func test_entry_plan_over_cap_car_qualifies_via_detune() -> void:
	# A ceiling just under the car's p/w: eligible only after a detune ducks it under.
	var rally := {"restriction": {"pw_max": _pw("fx_rwd_coupe") * 0.9}}
	var plan: Dictionary = _hq._entry_plan(rally, _owned("fx_rwd_coupe"))
	assert_true(plan["eligible"], "a detune qualifies it")
	assert_gt(float(plan["detune"]), 0.0, "it needs a detune to fit under the cap")


func test_below_band_floor_is_ineligible() -> void:
	# A rally whose p/w BAND floor sits above the car's MAX potential: the car is too weak
	# even fully maxed, so it can't enter (there is no eligible-but-underpowered state).
	var rally := {"restriction": {"pw_min": _pw("fx_light_rwd") * 3.0}}
	var plan: Dictionary = _hq._entry_plan(rally, _owned("fx_light_rwd"))
	assert_false(plan["eligible"], "below the band floor even at max potential → ineligible")
	var summary: Dictionary = _hq._eligibility_summary(rally, [_owned("fx_light_rwd")])
	assert_eq(summary["qualify"], 0, "and it's not counted as qualifying")


func test_floor_is_judged_at_full_potential_for_a_detuned_car() -> void:
	# The pw_min FLOOR is judged at the car's MAX potential, so a car currently DETUNED
	# below the floor is still eligible — the player can tune back up to enter. Floor just
	# under full pw; at 50% detune the car sits below it, but at full tune it clears it.
	var full_pw := _pw("fx_rwd_coupe")
	var rally := {"restriction": {"pw_min": full_pw * 0.9}}
	var owned := _owned("fx_rwd_coupe", {"engine_detune": 0.5})
	var plan: Dictionary = _hq._entry_plan(rally, owned)
	assert_true(plan["eligible"],
		"eligible: max potential (full tune) clears the floor, though the current detune is under it")


func test_floor_is_judged_with_ballast_dropped() -> void:
	# The floor is judged at max potential, which drops freely-removable ballast — so a
	# ballasted car below the floor on current stats is still eligible (shed the ballast).
	var base_pw := _pw("fx_rwd_coupe")  # full tune, no ballast
	var rally := {"restriction": {"pw_min": base_pw * 0.9}}
	var owned := _owned("fx_rwd_coupe", {}, ["fx_ballast"])
	var plan: Dictionary = _hq._entry_plan(rally, owned)
	assert_true(plan["eligible"], "eligible: dropping the removable ballast clears the floor")


func test_pin_unavailable_when_the_only_car_is_below_the_band_floor() -> void:
	# _has_eligible_car drives the green (available) vs grey (unavailable) map pin; a car
	# below the band floor even at max potential is ineligible, so the pin is unavailable,
	# same as owning no car.
	var saved: Array = Save.profile.get("cars", [])
	Save.profile["cars"] = [_owned("fx_light_rwd")]
	var high_rally := {"restriction": {"pw_min": _pw("fx_light_rwd") * 3.0}}
	assert_false(_hq._has_eligible_car(high_rally),
		"a below-floor-only roster leaves the pin unavailable")
	assert_true(_hq._has_eligible_car({"restriction": {}}),
		"the same car makes an open-class rally available")
	Save.profile["cars"] = saved
