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
