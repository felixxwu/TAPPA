extends GutTest
# Logic/contract tests on synthetic dicts — NO catalogue entries, NO pinned values.

func _rally(restriction: Dictionary) -> Dictionary:
	return {"restriction": restriction}

func test_open_class_is_eligible_no_reason() -> void:
	assert_eq(RallyLibrary.ineligibility_reason(_rally({}), {}), "")

func test_wrong_drive_mode_gives_reason() -> void:
	var rally := _rally({"drive_mode": CarLibrary.RWD})
	var meta := {"drive_mode": CarLibrary.FWD}
	var reason := RallyLibrary.ineligibility_reason(rally, meta)
	assert_ne(reason, "", "a mismatched drive mode is ineligible")
	assert_true(reason.to_lower().contains("drive"), "reason names the drivetrain")

func test_reason_empty_iff_is_eligible() -> void:
	# The reason string and the bool must always agree.
	var rally := _rally({"doors_max": 2})
	var admitted := {"doors": 2}
	var rejected := {"doors": 5}
	for meta in [admitted, rejected]:
		assert_eq(RallyLibrary.ineligibility_reason(rally, meta) == "",
			RallyLibrary.is_eligible(rally, meta),
			"reason=='' agrees with is_eligible")
