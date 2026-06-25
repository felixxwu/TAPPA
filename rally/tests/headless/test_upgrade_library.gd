extends GutTest
# The upgrade catalogue (UpgradeLibrary): the authored item list, the effect-
# application pipeline (step 2: baseline → upgrades), and the tuning gates.
# Slot-replacement and repair-kit behaviour (which need the Save profile) live in
# test_save_manager.gd. See todo/upgrade-catalogue.md.

const UpgradeLibrary = preload("res://scripts/upgrade_library.gd")


func test_catalogue_is_well_formed() -> void:
	var ids := {}
	var consumables := 0
	for item in UpgradeLibrary.UPGRADES:
		assert_false(ids.has(item["id"]), "item id '%s' is unique" % item["id"])
		ids[item["id"]] = true
		assert_gt(item["tier"], 0, "%s has a positive tier" % item["id"])
		if item["consumable"]:
			consumables += 1
			assert_eq(String(item["slot"]), "", "consumable %s has no slot" % item["id"])
		else:
			assert_true(UpgradeLibrary.SLOTS.has(item["slot"]),
				"%s has a known slot" % item["id"])
	# Exactly one consumable: the repair kit.
	assert_eq(consumables, 1, "exactly one consumable item")
	assert_true(UpgradeLibrary.is_consumable(UpgradeLibrary.REPAIR_KIT_ID), "repair kit is consumable")


func test_lookups() -> void:
	assert_eq(UpgradeLibrary.slot_of("engine_stage1"), "engine", "engine kit slots into engine")
	assert_eq(UpgradeLibrary.slot_of(UpgradeLibrary.REPAIR_KIT_ID), "", "repair kit has no slot")
	assert_eq(UpgradeLibrary.slot_of("nonexistent"), "", "unknown id has no slot")
	assert_true(UpgradeLibrary.by_id("nonexistent").is_empty(), "unknown id -> empty dict")


func test_effect_application_multiplies_and_adds_on_baseline() -> void:
	var cfg := GameConfig.new()
	cfg.peak_torque = 100.0
	cfg.brake_torque = 1000.0
	cfg.suspension_stiffness = 10.0
	cfg.downforce_front = 0.0
	cfg.downforce_rear = 0.0
	var car := {"installed_upgrades": ["engine_stage1", "brake_kit", "suspension_kit", "aero_kit"]}
	UpgradeLibrary.apply(car, cfg)
	assert_almost_eq(cfg.peak_torque, 110.0, 0.001, "engine kit multiplies torque 1.10x")
	assert_almost_eq(cfg.brake_torque, 1200.0, 0.001, "brake kit multiplies brake torque 1.20x")
	assert_almost_eq(cfg.suspension_stiffness, 11.0, 0.001, "suspension kit multiplies stiffness 1.10x")
	assert_almost_eq(cfg.downforce_front, 0.2, 0.001, "aero kit adds front downforce")
	assert_almost_eq(cfg.downforce_rear, 0.2, 0.001, "aero kit adds rear downforce")


func test_no_upgrades_leaves_config_untouched() -> void:
	var cfg := GameConfig.new()
	cfg.peak_torque = 250.0
	UpgradeLibrary.apply({"installed_upgrades": []}, cfg)
	assert_almost_eq(cfg.peak_torque, 250.0, 0.001, "empty upgrade list is a no-op")


func test_aero_and_brake_bias_tuning_are_gated_by_upgrades() -> void:
	var bare := {"installed_upgrades": []}
	assert_false(UpgradeLibrary.aero_tuning_unlocked(bare), "aero tuning locked with no aero kit")
	assert_false(UpgradeLibrary.brake_bias_unlocked(bare), "brake bias locked with no brake kit")
	var kitted := {"installed_upgrades": ["aero_kit", "brake_kit"]}
	assert_true(UpgradeLibrary.aero_tuning_unlocked(kitted), "aero kit unlocks aero tuning")
	assert_true(UpgradeLibrary.brake_bias_unlocked(kitted), "brake kit unlocks brake bias")
