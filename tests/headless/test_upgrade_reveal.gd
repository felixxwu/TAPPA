extends GutTest
# UpgradeReveal: the shared slot-spin + Apply/Keep reward card (features/menus.md).
# Headless -> the slot resolves instantly, so the choice/finish is reachable at once.

const CarFixtures = preload("res://tests/headless/car_fixtures.gd")

var _save: Node

func before_each() -> void:
	Config.reset()
	CarFixtures.install()
	_save = get_node("/root/Save")
	_save.profile_path = "user://test_upgrade_reveal_profile.json"
	_save.save_disabled = false
	_save.load_or_new()

func after_each() -> void:
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	Config.reset()
	CarFixtures.restore()

func _make() -> UpgradeReveal:
	var w := UpgradeReveal.new()
	add_child_autofree(w)
	return w

func test_slottable_part_offers_apply_which_enables_it() -> void:
	var car: Dictionary = _save.grant_car("fx_awd")
	var id := int(car["instance_id"])
	_save.install_upgrade(id, "brake_kit", false)  # reward loop fitted it disabled
	var w := _make()
	var done := [false]
	w.finished.connect(func() -> void: done[0] = true, CONNECT_ONE_SHOT)
	w.reveal("brake_kit", id)
	await get_tree().process_frame
	assert_true(w._choice_pending, "a slottable part opens the Apply/Keep choice")
	assert_true(w._choice_box.visible, "the choice buttons are shown")
	w._apply_button.pressed.emit()
	assert_true(UpgradeLibrary.is_enabled(_save.get_car(id), "brake_kit"), "Apply enables the part")
	assert_false(w._choice_pending, "the choice resolves once picked")
	assert_true(done[0], "finished fires after the choice")

func test_keep_leaves_the_part_disabled() -> void:
	var car: Dictionary = _save.grant_car("fx_awd")
	var id := int(car["instance_id"])
	_save.install_upgrade(id, "brake_kit", false)
	var w := _make()
	w.reveal("brake_kit", id)
	await get_tree().process_frame
	w._keep_button.pressed.emit()
	assert_false(UpgradeLibrary.is_enabled(_save.get_car(id), "brake_kit"), "Keep leaves the part disabled")

func test_repair_kit_skips_the_choice_and_finishes() -> void:
	var car: Dictionary = _save.grant_car("fx_awd")
	var id := int(car["instance_id"])
	var w := _make()
	var done := [false]
	w.finished.connect(func() -> void: done[0] = true, CONNECT_ONE_SHOT)
	w.reveal(UpgradeLibrary.REPAIR_KIT_ID, id)
	await get_tree().process_frame
	assert_false(w._choice_pending, "a consumable shows no Apply/Keep choice")
	assert_true(done[0], "finished fires immediately for a consumable")

func test_drivetrain_kit_installs_enabled_without_choice() -> void:
	var car: Dictionary = _save.grant_car("fx_awd")
	var id := int(car["instance_id"])
	_save.install_upgrade(id, "drivetrain_swap", false)
	var w := _make()
	w.reveal("drivetrain_swap", id)
	await get_tree().process_frame
	assert_false(w._choice_pending, "the drivetrain kit skips Apply/Keep")
	assert_true(UpgradeLibrary.is_enabled(_save.get_car(id), "drivetrain_swap"),
		"the drivetrain kit installs enabled")
