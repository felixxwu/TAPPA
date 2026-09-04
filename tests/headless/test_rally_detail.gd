extends GutTest
# The rally-detail card's eligibility read-out (features/menus.md). RallyDetail's
# eligibility_summary tallies how many of the player's OWNED cars can enter a rally, built
# on top of entry_plan so the panel agrees exactly with the green/grey map pin. These tests
# use a synthetic CarFixtures roster + hand-authored restriction dicts (never the shipped
# catalogue) and assert the COUNTING behaviour, not any tuned restriction value.
#
# NO SCENE HOST. These used to instantiate hq.tscn and reach the same logic through
# HqController's thin wrappers (`_eligibility_summary`, `_entry_plan`, …). The hub was
# deleted in the roguelike pivot (todo/roguelike-pivot-plan.md, stage 2b) and the logic was
# already static on RallyDetail — which is exactly why rally_detail.gd was split out of the
# controller in the first place — so the tests now call it directly. That is both the honest
# subject and a lot cheaper: no 3D hub build per test. The three tests that drove the hub's
# DETAIL PANEL WIDGETS (`_detail_stars`, `_detail_enter_button`, via `_table_ui._show_detail`)
# and the one covering HqController._has_eligible_car went with the hub — their subject is
# gone, and stage 3's flat shell gets its own.

const CarFixtures = preload("res://tests/headless/car_fixtures.gd")
const SaveTestHelpers = preload("res://tests/headless/save_test_helpers.gd")
const TEST_PATH := "user://test_rally_detail_profile.json"


func before_all() -> void:
	# The tests below read Save.profile (drivetrain_swap_unlocked), so keep every write
	# off the real profile.
	SaveTestHelpers.redirect(TEST_PATH)
	CarFixtures.install()


func after_all() -> void:
	CarFixtures.restore()
	SaveTestHelpers.cleanup(TEST_PATH)


# A minimal OwnedCar dict — just the fields effective_meta / entry_plan read. `bought` is
# the car's `drivetrain_modes_bought` list: `convertible_for` gates on the target layout
# being PAID FOR (Save.drive_mode_available), so a car with an empty list is never a
# conversion candidate however wrong its stock layout is.
func _owned(model_id: String, tuning := {}, bought := []) -> Dictionary:
	return {"model_id": model_id, "tuning": tuning, "drivetrain_modes_bought": bought}


func test_empty_roster_counts_nothing() -> void:
	var summary: Dictionary = RallyDetail.eligibility_summary({"restriction": {}}, [])
	assert_eq(summary["total"], 0, "no owned cars means nothing to count")
	assert_eq(summary["qualify"], 0, "and nothing qualifies")


func test_unresolved_model_is_skipped_from_total() -> void:
	# An open-class rally admits any car; a stale model_id must not be counted at all
	# (and must not slip through effective_meta({}, {}) as a phantom qualifier).
	var roster := [_owned("fx_light_rwd"), _owned("model_that_was_removed")]
	var summary: Dictionary = RallyDetail.eligibility_summary({"restriction": {}}, roster)
	assert_eq(summary["total"], 1, "the unresolved model is skipped, not counted in total")
	assert_eq(summary["qualify"], 1, "the one real car qualifies for open class")


func test_drive_mode_restriction_counts_only_matching_cars() -> void:
	# `qualify` counts cars that can enter AS BUILT. `adjust` counts cars that CANNOT, but
	# would after a drivetrain conversion the player buys themselves — the two are DISJOINT.
	# (`adjust` used to be a subset of `qualify`, because the car park silently switched such
	# a car at the Start button and counted it as qualifying; that auto-switch is gone.)
	var rally := {"restriction": {"drive_mode": CarFixtures.RWD}}
	# The two non-RWD cars have BOUGHT the RWD layout (decision 52 made conversions a real
	# purchase — Save.buy_drive_mode). Without that they would not be convertible at all,
	# which is the point `convertible_for` enforces and what this test would otherwise
	# quietly stop measuring.
	var roster := [
		_owned("fx_light_rwd"), _owned("fx_fwd_hatch", {}, [CarFixtures.RWD]),
		_owned("fx_rwd_coupe"), _owned("fx_awd", {}, [CarFixtures.RWD]),
	]
	var summary: Dictionary = RallyDetail.eligibility_summary(rally, roster)
	assert_eq(summary["total"], 4, "every resolvable car is counted in the roster size")
	assert_eq(summary["qualify"], 2, "only the RWD cars can enter this class")
	# Derived, not pinned: whatever the fixture roster holds, every car that is not eligible
	# as built but whose only problem is the drive mode is a conversion candidate.
	var convertible := 0
	for car in roster:
		var entry: Dictionary = CarLibrary.for_owned(car)
		if entry.is_empty():
			continue
		if not RallyLibrary.is_eligible(rally, UpgradeLibrary.effective_meta(car, entry)) \
				and RallyDetail.convertible_for(rally, car, entry):
			convertible += 1
	assert_eq(summary["adjust"], convertible,
		"the non-RWD cars are counted as convertible, so the player is told what to fix")
	assert_gt(convertible, 0, "setup: the roster has a car worth converting")


func test_summary_names_the_qualifying_cars() -> void:
	# The panel names the qualifying cars rather than counting them, so the summary has
	# to carry one name per qualifier — and only for the cars that can actually enter.
	var rally := {"restriction": {"drive_mode": CarFixtures.RWD}}
	var roster := [_owned("fx_light_rwd"), _owned("fx_fwd_hatch"), _owned("fx_rwd_coupe")]
	var summary: Dictionary = RallyDetail.eligibility_summary(rally, roster)
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
	for i in RallyDetail.MAX_QUALIFY_NAMES:
		names.append("Car%d" % i)
	var text: String = RallyDetail.qualifying_cars_text(names)
	for n in names:
		assert_true(text.contains(n), "%s is listed" % n)
	assert_false(text.contains("more"), "nothing is elided at the cap")


func test_qualifying_text_elides_the_overflow() -> void:
	var names: Array[String] = []
	for i in RallyDetail.MAX_QUALIFY_NAMES + 2:
		names.append("Car%d" % i)
	var text: String = RallyDetail.qualifying_cars_text(names)
	assert_true(text.contains("Car0"), "the first names are still listed")
	assert_false(text.contains("Car%d" % (RallyDetail.MAX_QUALIFY_NAMES + 1)),
		"names past the cap are elided, not listed")
	assert_true(text.contains("+2 more"), "the elided count is reported")


func test_a_car_outside_the_class_is_ineligible() -> void:
	# Entry is purely CATEGORICAL, so a car of the wrong class is simply out — there is no
	# tune, detune or upgrade that can buy its way in, and no "eligible but underpowered"
	# middle state. The restriction names a country no fixture car has, so the case holds
	# whatever the fixtures are retuned to.
	var rally := {"restriction": {"country": "__nowhere__"}}
	var plan: Dictionary = RallyDetail.entry_plan(rally, _owned("fx_light_rwd"))
	assert_false(plan["eligible"], "outside the class → ineligible")
	var summary: Dictionary = RallyDetail.eligibility_summary(rally, [_owned("fx_light_rwd")])
	assert_eq(summary["total"], 1, "the car is still counted in the roster size")
	assert_eq(summary["qualify"], 0, "and it's not counted as qualifying")
