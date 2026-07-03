extends GutTest
# The upgrade catalogue (UpgradeLibrary): the authored item list, the effect-
# application pipeline (step 2: baseline → upgrades), and the tuning gates.
# Slot-replacement and repair-kit behaviour (which need the Save profile) live in
# test_save_manager.gd. See todo/upgrade-catalogue.md.


func before_each() -> void:
	CarFixtures.install()


func after_each() -> void:
	CarFixtures.restore()


func test_catalogue_is_well_formed() -> void:
	var ids := {}
	for item in UpgradeLibrary.UPGRADES:
		assert_false(ids.has(item["id"]), "item id '%s' is unique" % item["id"])
		ids[item["id"]] = true
		assert_gt(item["tier"], 0, "%s has a positive tier" % item["id"])
		if item["consumable"]:
			assert_eq(String(item["slot"]), "", "consumable %s has no slot" % item["id"])
		else:
			assert_true(UpgradeLibrary.SLOTS.has(item["slot"]),
				"%s has a known slot" % item["id"])
	assert_true(UpgradeLibrary.is_consumable(UpgradeLibrary.REPAIR_KIT_ID), "repair kit is consumable")


func test_lookups() -> void:
	# Mechanism, not authored values: slot_of/by_id resolve any real catalogue
	# entry to its own slot, and degrade safely for unknown ids.
	for item in UpgradeLibrary.UPGRADES:
		var expected_slot: String = "" if item["consumable"] else String(item["slot"])
		assert_eq(UpgradeLibrary.slot_of(item["id"]), expected_slot,
			"%s slots into its own authored slot" % item["id"])
	assert_eq(UpgradeLibrary.slot_of("nonexistent"), "", "unknown id has no slot")
	assert_true(UpgradeLibrary.by_id("nonexistent").is_empty(), "unknown id -> empty dict")


func test_effect_application_multiplies_and_adds_on_baseline() -> void:
	var cfg := GameConfig.new()
	cfg.peak_torque = 100.0
	cfg.brake_torque = 1000.0
	cfg.mass = 1000.0
	cfg.downforce_front = 0.0
	cfg.downforce_rear = 0.0
	var car := {"installed_upgrades": ["engine_stage1", "brake_kit", "weight_reduction", "aero_kit"]}
	# Expected values are derived from each upgrade's configured effect, so this tests
	# the apply PIPELINE (right field, multiply vs add) without pinning the tunable
	# multipliers/amounts — retuning a kit's strength won't break the test.
	var eng: Dictionary = UpgradeLibrary.by_id("engine_stage1")["effect"]
	var brk: Dictionary = UpgradeLibrary.by_id("brake_kit")["effect"]
	var wgt: Dictionary = UpgradeLibrary.by_id("weight_reduction")["effect"]
	var aero: Dictionary = UpgradeLibrary.by_id("aero_kit")["effect"]
	UpgradeLibrary.apply(car, cfg)
	assert_almost_eq(cfg.peak_torque, 100.0 * float(eng["peak_torque_mult"]), 0.001, "engine kit multiplies torque")
	assert_almost_eq(cfg.brake_torque, 1000.0 * float(brk["brake_torque_mult"]), 0.001, "brake kit multiplies brake torque")
	assert_almost_eq(cfg.mass, 1000.0 * float(wgt["mass_mult"]), 0.001, "weight reduction multiplies mass")
	assert_almost_eq(cfg.downforce_front, float(aero["downforce_front"]), 0.001, "aero kit adds front downforce")
	assert_almost_eq(cfg.downforce_rear, float(aero["downforce_rear"]), 0.001, "aero kit adds rear downforce")


func test_effective_meta_adjusts_power_to_weight_for_eligibility() -> void:
	# A copy of a roster entry; effective_meta should lighten mass and lift torque
	# so the derived power-to-weight rises (and never mutate the source entry).
	var entry := {"peak_torque": 200.0, "redline": 7000.0, "mass": 1000.0}
	var base_pw := CarLibrary.power_to_weight(entry)
	var car := {"installed_upgrades": ["engine_stage1", "weight_reduction"]}
	var eff := UpgradeLibrary.effective_meta(car, entry)
	var eng_mult: float = float(UpgradeLibrary.by_id("engine_stage1")["effect"]["peak_torque_mult"])
	var mass_mult: float = float(UpgradeLibrary.by_id("weight_reduction")["effect"]["mass_mult"])
	assert_almost_eq(float(eff["mass"]), 1000.0 * mass_mult, 0.001, "weight reduction lightens the meta mass")
	assert_almost_eq(float(eff["peak_torque"]), 200.0 * eng_mult, 0.001, "engine kit raises the meta torque")
	assert_gt(CarLibrary.power_to_weight(eff), base_pw, "upgrades raise the effective power-to-weight")
	assert_almost_eq(float(entry["mass"]), 1000.0, 0.001, "source entry is left untouched")
	# No upgrades is a faithful copy.
	var bare := UpgradeLibrary.effective_meta({"installed_upgrades": []}, entry)
	assert_almost_eq(CarLibrary.power_to_weight(bare), base_pw, 0.001, "no upgrades -> baseline pw")


func test_effective_meta_uses_swapped_engine_torque() -> void:
	# A twingo running a V8: effective_meta seeds torque from the CURRENT
	# engine, so the figure matches the swapped engine's library torque (mechanism,
	# not a pinned number — derived from EngineLibrary).
	var meta := CarLibrary.by_id("fx_light_rwd").duplicate()
	var v8 := "fx_v8"
	var owned := {"model_id": "fx_light_rwd", "swapped_engine": v8, "installed_upgrades": [], "tuning": {}}
	var eff := UpgradeLibrary.effective_meta(owned, meta)
	assert_almost_eq(float(eff["peak_torque"]), float(EngineLibrary.by_id(v8)["peak_torque"]), 0.001,
		"torque seeded from the swapped engine")
	# And total mass changed by the engine mass delta.
	var expected_mass := EngineSwap.recompute_mass(
		float(CarLibrary.by_id("fx_light_rwd")["mass"]),
		float(EngineLibrary.by_id(CarLibrary.by_id("fx_light_rwd")["engine"])["mass"]),
		float(EngineLibrary.by_id(v8)["mass"]))
	assert_almost_eq(float(eff["mass"]), expected_mass, 0.001, "mass recomputed for the swapped engine")


func test_effective_meta_applies_detune_to_torque() -> void:
	var meta := CarLibrary.by_id("fx_light_rwd").duplicate()
	var full := UpgradeLibrary.effective_meta({"model_id": "fx_light_rwd", "tuning": {}}, meta)
	var half := UpgradeLibrary.effective_meta({"model_id": "fx_light_rwd", "tuning": {"engine_detune": 0.5}}, meta.duplicate())
	assert_almost_eq(float(half["peak_torque"]), float(full["peak_torque"]) * 0.5, 0.001,
		"detune halves the torque feeding power-to-weight")
	assert_lt(CarLibrary.power_to_weight(half), CarLibrary.power_to_weight(full),
		"a detuned car has lower power-to-weight")


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


func test_disabled_upgrades_are_inert_everywhere() -> void:
	# A part toggled off in the upgrades menu stays fitted but contributes nothing:
	# no config effect, no effective-meta shift, no tuning gate.
	var car := {
		"installed_upgrades": ["engine_stage1", "aero_kit", "brake_kit"],
		"disabled_upgrades": ["engine_stage1", "aero_kit", "brake_kit"],
	}
	var cfg := GameConfig.new()
	cfg.peak_torque = 100.0
	UpgradeLibrary.apply(car, cfg)
	assert_almost_eq(cfg.peak_torque, 100.0, 0.001, "a disabled engine kit leaves the config untouched")
	var entry := {"peak_torque": 200.0, "redline": 7000.0, "mass": 1000.0}
	var eff := UpgradeLibrary.effective_meta(car, entry)
	assert_almost_eq(float(eff["peak_torque"]), 200.0, 0.001, "a disabled part doesn't shift effective stats")
	assert_false(UpgradeLibrary.aero_tuning_unlocked(car), "a disabled aero kit doesn't unlock aero tuning")
	assert_false(UpgradeLibrary.brake_bias_unlocked(car), "a disabled brake kit doesn't unlock brake bias")
	# enabled_upgrades reflects the toggle; re-enabling brings the part back.
	assert_eq(UpgradeLibrary.enabled_upgrades(car).size(), 0, "everything disabled -> nothing enabled")
	car["disabled_upgrades"] = []
	assert_eq(UpgradeLibrary.enabled_upgrades(car).size(), 3, "clearing the toggles re-enables the parts")
	assert_true(UpgradeLibrary.aero_tuning_unlocked(car), "a re-enabled aero kit unlocks aero tuning again")
