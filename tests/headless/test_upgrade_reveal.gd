extends GutTest
# UpgradeReveal: the shared slot-spin reward card (features/menus.md). Normal
# parts are a single "Next" step (granted fitted-disabled, no Apply/Keep — the
# player enables them later in the upgrades menu); a repair kit still offers an
# Apply/Keep choice (Repair now / Save it) when the driven car is below full
# health. Headless -> the slot resolves instantly, so finish/choice is reachable
# at once.

const CarFixtures = preload("res://tests/headless/car_fixtures.gd")
const UpgradeFixtures = preload("res://tests/headless/upgrade_fixtures.gd")

var _save: Node

func before_each() -> void:
	Config.reset()
	CarFixtures.install()
	UpgradeFixtures.install()
	_save = get_node("/root/Save")
	_save.profile_path = "user://test_upgrade_reveal_profile.json"
	_save.save_disabled = false
	_save.load_or_new()

func after_each() -> void:
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	Config.reset()
	UpgradeFixtures.restore()
	CarFixtures.restore()

func _make() -> UpgradeReveal:
	var w := UpgradeReveal.new()
	add_child_autofree(w)
	return w

func test_slottable_part_reveal_leaves_it_fitted_disabled_and_finishes() -> void:
	var car: Dictionary = _save.grant_car("fx_awd")
	var id := int(car["instance_id"])
	_save.install_upgrade(id, "fx_brakes", false)  # reward loop fitted it disabled
	var w := _make()
	var done := [false]
	w.finished.connect(func() -> void: done[0] = true, CONNECT_ONE_SHOT)
	w.reveal("fx_brakes", id)
	await get_tree().process_frame
	assert_false(w._choice_pending, "a normal part is one 'Next' step, no Apply/Keep choice")
	assert_false(w._choice_box.visible, "no choice buttons are shown")
	assert_true(_save.get_car(id)["installed_upgrades"].has("fx_brakes"), "the part stays fitted")
	assert_false(UpgradeLibrary.is_enabled(_save.get_car(id), "fx_brakes"),
		"the part stays disabled — enabled later in the upgrades menu")
	assert_true(done[0], "finished fires immediately")

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
	_save.install_upgrade(id, "fx_drivetrain", false)
	var w := _make()
	w.reveal("fx_drivetrain", id)
	await get_tree().process_frame
	assert_false(w._choice_pending, "the drivetrain kit skips Apply/Keep")
	assert_true(UpgradeLibrary.is_enabled(_save.get_car(id), "fx_drivetrain"),
		"the drivetrain kit installs enabled")
