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

func test_repair_kit_on_full_health_car_skips_the_choice_and_finishes() -> void:
	var car: Dictionary = _save.grant_car("fx_awd")  # granted at full HP
	var id := int(car["instance_id"])
	var w := _make()
	var done := [false]
	w.finished.connect(func() -> void: done[0] = true, CONNECT_ONE_SHOT)
	w.reveal(UpgradeLibrary.REPAIR_KIT_ID, id)
	await get_tree().process_frame
	assert_false(w._choice_pending, "a full-health car shows no use-now choice")
	assert_true(done[0], "finished fires immediately when there's nothing to repair")

func test_repair_kit_on_damaged_car_offers_use_now_and_repairs() -> void:
	var car: Dictionary = _save.grant_car("fx_awd")
	var id := int(car["instance_id"])
	_save.apply_damage(id, 200.0)  # drop below full health
	_save.add_item(UpgradeLibrary.REPAIR_KIT_ID, 1, false)  # the just-won kit, already banked
	var full_hp := float(CarLibrary.by_id("fx_awd").get("max_hp", 0.0))
	assert_lt(float(_save.get_car(id)["hp"]), full_hp, "precondition: the car is damaged")
	var w := _make()
	var done := [false]
	w.finished.connect(func() -> void: done[0] = true, CONNECT_ONE_SHOT)
	w.reveal(UpgradeLibrary.REPAIR_KIT_ID, id)
	await get_tree().process_frame
	assert_true(w._choice_pending, "a damaged car opens the Repair-now/Save-it choice")
	assert_true(w._choice_box.visible, "the choice buttons are shown")
	w._apply_button.pressed.emit()
	assert_eq(float(_save.get_car(id)["hp"]), full_hp, "Repair now restores the car to full health")
	assert_eq(int(_save.profile["inventory"].get(UpgradeLibrary.REPAIR_KIT_ID, 0)), 0, "Repair now spends the kit")
	assert_true(done[0], "finished fires after the choice")

func test_repair_kit_save_it_leaves_car_damaged_and_keeps_the_kit() -> void:
	var car: Dictionary = _save.grant_car("fx_awd")
	var id := int(car["instance_id"])
	_save.apply_damage(id, 200.0)
	_save.add_item(UpgradeLibrary.REPAIR_KIT_ID, 1, false)
	var damaged_hp := float(_save.get_car(id)["hp"])
	var w := _make()
	w.reveal(UpgradeLibrary.REPAIR_KIT_ID, id)
	await get_tree().process_frame
	w._keep_button.pressed.emit()
	assert_eq(float(_save.get_car(id)["hp"]), damaged_hp, "Save it leaves the car damaged")
	assert_eq(int(_save.profile["inventory"].get(UpgradeLibrary.REPAIR_KIT_ID, 0)), 1, "Save it keeps the kit in inventory")

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
