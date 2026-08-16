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


func test_summary_names_the_qualifying_cars() -> void:
	# The panel names the qualifying cars rather than counting them, so the summary has
	# to carry one name per qualifier — and only for the cars that can actually enter.
	var rally := {"restriction": {"drive_mode": CarFixtures.RWD}}
	var roster := [_owned("fx_light_rwd"), _owned("fx_fwd_hatch"), _owned("fx_rwd_coupe")]
	var summary: Dictionary = _hq._eligibility_summary(rally, roster)
	var names: Array = summary["names"]
	assert_eq(names.size(), int(summary["qualify"]), "one name per qualifying car")
	assert_true(names.has(String(CarLibrary.by_id("fx_light_rwd").get("name", ""))),
		"a qualifying car is named")
	assert_false(names.has(String(CarLibrary.by_id("fx_fwd_hatch").get("name", ""))),
		"an ineligible car is not named")


func test_qualifying_text_lists_all_names_up_to_the_cap() -> void:
	# Exactly the cap: every name is listed and nothing is elided. Sized FROM
	# MAX_QUALIFY_NAMES rather than a literal — the cap is a display knob (it is 1 today),
	# so a hardcoded list would pin it and fail the moment it is retuned.
	var names: Array[String] = []
	for i in _hq.MAX_QUALIFY_NAMES:
		names.append("Car%d" % i)
	var text: String = _hq._qualifying_cars_text(names)
	for n in names:
		assert_true(text.contains(n), "%s is listed" % n)
	assert_false(text.contains("more"), "nothing is elided at the cap")


func test_qualifying_text_elides_the_overflow() -> void:
	var names: Array[String] = []
	for i in _hq.MAX_QUALIFY_NAMES + 2:
		names.append("Car%d" % i)
	var text: String = _hq._qualifying_cars_text(names)
	assert_true(text.contains("Car0"), "the first names are still listed")
	assert_false(text.contains("Car%d" % (_hq.MAX_QUALIFY_NAMES + 1)),
		"names past the cap are elided, not listed")
	assert_true(text.contains("+2 more"), "the elided count is reported")


func test_star_row_always_shows_and_fills_with_the_record() -> void:
	# The star row is always visible: unrun it reads as an empty row (0 earned), and a
	# placement lights the medals. Uses whatever the first roster rally is — the identity
	# is irrelevant, only the has-a-record / has-no-record branch matters.
	var rally_id := String(RallyLibrary.all()[0].get("id", ""))
	var saved: Dictionary = Save.profile["rallies"].duplicate(true)
	Save.profile["rallies"].erase(rally_id)
	_hq._selected_rally_id = rally_id
	_hq._table_ui._show_detail()
	assert_true(_hq._detail_stars.visible, "no record → still an (empty) star row")
	assert_eq(_hq._detail_stars.earned, 0, "no record → no stars lit")
	Save.profile["rallies"][rally_id] = {"best_placed": 1}
	_hq._table_ui._show_detail()
	assert_true(_hq._detail_stars.visible, "a placement shows the medals")
	assert_gt(_hq._detail_stars.earned, 0, "a placement lights at least one star")
	Save.profile["rallies"] = saved


func test_enter_button_disabled_when_no_owned_car_qualifies() -> void:
	# A rally with no eligible car for the player's roster: the Enter button must be
	# disabled, not just informationally red — tapping through led to an empty car park.
	var rally_id := String(RallyLibrary.all()[0].get("id", ""))
	var saved_cars: Array = Save.profile["cars"].duplicate(true)
	Save.profile["cars"] = []
	_hq._selected_rally_id = rally_id
	_hq._table_ui._show_detail()
	assert_true(_hq._detail_enter_button.disabled, "no owned cars → nothing can qualify")
	Save.profile["cars"] = saved_cars


func test_enter_button_enabled_when_a_car_qualifies() -> void:
	var rally_id := "fx_open"
	var saved_cars: Array = Save.profile["cars"].duplicate(true)
	Save.profile["cars"] = [_owned("fx_rwd_coupe")]
	RallyFixtures.install()
	_hq._selected_rally_id = rally_id
	_hq._table_ui._show_detail()
	assert_false(_hq._detail_enter_button.disabled, "an owned car qualifies for the open class")
	RallyFixtures.restore()
	Save.profile["cars"] = saved_cars


func test_a_car_outside_the_class_is_ineligible() -> void:
	# Entry is purely CATEGORICAL, so a car of the wrong class is simply out — there is no
	# tune, detune or upgrade that can buy its way in, and no "eligible but underpowered"
	# middle state. The restriction names a country no fixture car has, so the case holds
	# whatever the fixtures are retuned to.
	var rally := {"restriction": {"country": "__nowhere__"}}
	var plan: Dictionary = _hq._entry_plan(rally, _owned("fx_light_rwd"))
	assert_false(plan["eligible"], "outside the class → ineligible")
	var summary: Dictionary = _hq._eligibility_summary(rally, [_owned("fx_light_rwd")])
	assert_eq(summary["total"], 1, "the car is still counted in the roster size")
	assert_eq(summary["qualify"], 0, "and it's not counted as qualifying")


func test_pin_unavailable_when_no_owned_car_is_in_the_class() -> void:
	# _has_eligible_car drives the green (available) vs grey (unavailable) map pin: a
	# roster with nothing in the rally's class leaves the pin unavailable, same as owning
	# no car at all.
	var saved: Array = Save.profile.get("cars", [])
	Save.profile["cars"] = [_owned("fx_light_rwd")]
	assert_false(_hq._has_eligible_car({"restriction": {"country": "__nowhere__"}}),
		"an out-of-class-only roster leaves the pin unavailable")
	assert_true(_hq._has_eligible_car({"restriction": {}}),
		"the same car makes an open-class rally available")
	Save.profile["cars"] = saved
