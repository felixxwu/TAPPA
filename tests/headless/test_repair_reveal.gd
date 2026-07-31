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


func test_the_card_reports_health_in_absolute_hp() -> void:
	# The card shows HP RESTORED, not a percentage of max: "+100 HP" says what the
	# repair actually did to the car, where "+10%" made the player do the arithmetic.
	var w := _make()
	w.reveal(_make_summary())  # 300 -> 400
	await get_tree().process_frame
	assert_eq(RepairReveal.health_gain_hp(_make_summary()), 100, "hp_after - hp_before")
	assert_string_contains(w._health_label.text, "100", "the card names the HP restored")
	assert_false(w._health_label.text.contains("%"), "and no longer shows a percentage")


func test_health_gain_hp_is_independent_of_max_hp() -> void:
	# The whole point of the change: the same 100 HP reads the same on a fragile car
	# and a tough one, where the percentage would have differed.
	var fragile := {"repaired": true, "hp_before": 100.0, "hp_after": 200.0, "max_hp": 250.0}
	var tough := {"repaired": true, "hp_before": 100.0, "hp_after": 200.0, "max_hp": 5000.0}
	assert_eq(RepairReveal.health_gain_hp(fragile), RepairReveal.health_gain_hp(tough))


func test_worth_showing_needs_at_least_the_min_health_gain() -> void:
	# A 10-point gain (300 -> 400 of 1000) clears the 2% bar.
	assert_true(RepairReveal.worth_showing(_make_summary()), "a gain at/above the min shows")
	# A sub-2% touch-up (985 -> 995 of 1000 = 1pt) stays below the bar.
	var tiny := {"repaired": true, "hp_before": 985.0, "hp_after": 995.0, "max_hp": 1000.0}
	assert_false(RepairReveal.worth_showing(tiny), "a gain below the min does not show")
	assert_false(RepairReveal.worth_showing({"repaired": false}), "no repair, no popup")
