extends GutTest
# RepairReveal: the between-event pit-repair popup (features/damage.md). A single
# Continue button, keyboard/gamepad navigable (MenuNav), emitting `finished` on
# dismiss. Only exercises the card's wiring, not the repair values (those live in
# Save.field_repair / GameConfig and are covered by test_save_manager).

func _make() -> RepairReveal:
	var w := RepairReveal.new()
	add_child_autofree(w)
	return w


func _make_summary() -> Dictionary:
	return {"repaired": true, "hp_before": 300.0, "hp_after": 400.0, "max_hp": 1000.0, "hp_gained": 100.0}


func test_continue_dismisses_and_emits_finished() -> void:
	var w := _make()
	var done := [false]
	w.finished.connect(func() -> void: done[0] = true, CONNECT_ONE_SHOT)
	w.reveal(_make_summary())
	await get_tree().process_frame
	w._continue_button.pressed.emit()
	assert_true(done[0], "Continue dismisses the popup")


func test_continue_is_keyboard_gamepad_focusable() -> void:
	var w := _make()
	w.reveal(_make_summary())
	await get_tree().process_frame
	# MenuNav makes the button reachable without a pointer and seats the cursor on it.
	assert_eq(w._continue_button.focus_mode, Control.FOCUS_ALL, "Continue is focusable")
	assert_true(w._continue_button.has_focus(), "the cursor is seated on Continue")


func test_the_card_reports_health_as_a_percentage() -> void:
	# The card shows PERCENTAGE POINTS of max_hp, the same unit the popup gate reads and the
	# same unit the rest of the UI shows health in. It briefly showed absolute HP instead;
	# that made the card the only place in the game quoting a raw HP figure, so the player
	# had to know their car's max to judge whether the repair mattered.
	var w := _make()
	w.reveal(_make_summary())  # 300 -> 400 of 1000
	await get_tree().process_frame
	assert_eq(RepairReveal.health_gain_pct(_make_summary()), 10, "10 points of max_hp")
	assert_string_contains(w._health_label.text, "10%", "the card names the percentage restored")
	assert_false(w._health_label.text.contains("HP"), "and not a raw HP figure")


func test_health_gain_pct_scales_with_max_hp() -> void:
	# The reason the card uses it: the SAME absolute repair is a big deal on a fragile car
	# and negligible on a tough one, and the percentage says which.
	var fragile := {"repaired": true, "hp_before": 100.0, "hp_after": 200.0, "max_hp": 250.0}
	var tough := {"repaired": true, "hp_before": 100.0, "hp_after": 200.0, "max_hp": 5000.0}
	assert_gt(RepairReveal.health_gain_pct(fragile), RepairReveal.health_gain_pct(tough),
		"the same HP gain reads as a larger share of a fragile car")


func test_worth_showing_needs_at_least_the_min_health_gain() -> void:
	# A 10-point gain (300 -> 400 of 1000) clears the 2% bar.
	assert_true(RepairReveal.worth_showing(_make_summary()), "a gain at/above the min shows")
	# A sub-2% touch-up (985 -> 995 of 1000 = 1pt) stays below the bar.
	var tiny := {"repaired": true, "hp_before": 985.0, "hp_after": 995.0, "max_hp": 1000.0}
	assert_false(RepairReveal.worth_showing(tiny), "a gain below the min does not show")
	assert_false(RepairReveal.worth_showing({"repaired": false}), "no repair, no popup")
