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
	var car := {"installed_upgrades": ["turbo_large", "brake_kit", "weight_reduction", "aero_kit"]}
	# Expected values are derived from each upgrade's configured effect, so this tests
	# the apply PIPELINE (right field, multiply vs add) without pinning the tunable
	# multipliers/amounts — retuning a kit's strength won't break the test.
	var turbo: Dictionary = UpgradeLibrary.by_id("turbo_large")["effect"]["install_turbo"]
	var brk: Dictionary = UpgradeLibrary.by_id("brake_kit")["effect"]
	var wgt: Dictionary = UpgradeLibrary.by_id("weight_reduction")["effect"]
	var aero: Dictionary = UpgradeLibrary.by_id("aero_kit")["effect"]
	UpgradeLibrary.apply(car, cfg)
	assert_true(cfg.turbo_enabled, "installing a turbo enables it on the config")
	assert_almost_eq(cfg.turbo_boost_gain, float(turbo["turbo_boost_gain"]), 0.001, "turbo kit writes its boost gain")
	assert_almost_eq(cfg.brake_torque, 1000.0 * float(brk["brake_torque_mult"]), 0.001, "brake kit multiplies brake torque")
	assert_almost_eq(cfg.mass, 1000.0 * float(wgt["mass_mult"]), 0.001, "weight reduction multiplies mass")
	assert_almost_eq(cfg.downforce_front, float(aero["downforce_front"]), 0.001, "aero kit adds front downforce")
	assert_almost_eq(cfg.downforce_rear, float(aero["downforce_rear"]), 0.001, "aero kit adds rear downforce")


func test_effective_meta_adjusts_power_to_weight_for_eligibility() -> void:
	# A copy of a roster entry; effective_meta should lighten mass and lift torque
	# so the derived power-to-weight rises (and never mutate the source entry).
	var entry := {"peak_torque": 200.0, "redline": 7000.0, "mass": 1000.0}
	var base_pw := CarLibrary.power_to_weight(entry)
	var car := {"installed_upgrades": ["turbo_large", "weight_reduction"]}
	var eff := UpgradeLibrary.effective_meta(car, entry)
	var boost_gain: float = float(UpgradeLibrary.by_id("turbo_large")["effect"]["install_turbo"]["turbo_boost_gain"])
	var mass_mult: float = float(UpgradeLibrary.by_id("weight_reduction")["effect"]["mass_mult"])
	assert_almost_eq(float(eff["mass"]), 1000.0 * mass_mult, 0.001, "weight reduction lightens the meta mass")
	assert_almost_eq(float(eff["peak_torque"]), 200.0 * (1.0 + boost_gain), 0.001, "turbo rates the meta torque at peak boost")
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
		"installed_upgrades": ["turbo_large", "aero_kit", "brake_kit"],
		"disabled_upgrades": ["turbo_large", "aero_kit", "brake_kit"],
	}
	var cfg := GameConfig.new()
	cfg.peak_torque = 100.0
	UpgradeLibrary.apply(car, cfg)
	assert_almost_eq(cfg.peak_torque, 100.0, 0.001, "a disabled turbo leaves the config untouched")
	assert_false(cfg.turbo_enabled, "a disabled turbo doesn't enable itself on the config")
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


func test_turbo_upgrades_are_turbo_slot_items() -> void:
	assert_eq(UpgradeLibrary.slot_of("turbo_small"), "turbo", "small turbo is a turbo-slot item")
	assert_eq(UpgradeLibrary.slot_of("turbo_large"), "turbo", "large turbo is a turbo-slot item")
	# The old flat-multiplier stages are gone.
	assert_true(UpgradeLibrary.by_id("engine_stage1").is_empty(), "Stage 1 kit removed")
	assert_true(UpgradeLibrary.by_id("engine_stage2").is_empty(), "Stage 2 kit removed")


func test_no_supercharger_upgrade_exists() -> void:
	# Superchargers are intrinsic engine properties, never an upgrade.
	for item in UpgradeLibrary.UPGRADES:
		assert_false(String(item["id"]).contains("supercharger"), "no supercharger in the upgrade catalogue")


func test_install_turbo_writes_turbo_fields_onto_config() -> void:
	var cfg := GameConfig.new()
	assert_false(cfg.turbo_enabled, "config starts NA")
	var owned := {"installed_upgrades": ["turbo_large"], "disabled_upgrades": []}
	UpgradeLibrary.apply(owned, cfg)
	assert_true(cfg.turbo_enabled, "installing a turbo enables it on the config")
	assert_gt(cfg.turbo_boost_gain, 0.0, "the turbo upgrade sets a boost gain")


func test_effective_meta_rates_turbo_at_peak_boost() -> void:
	# Synthetic meta carrying its own peak_torque so we don't depend on the catalogue.
	var base := {"peak_torque": 300.0, "redline": 7000.0, "mass": 1200.0, "engine": ""}
	var na := UpgradeLibrary.effective_meta({"installed_upgrades": [], "disabled_upgrades": []}, base)
	var turbo := UpgradeLibrary.effective_meta({"installed_upgrades": ["turbo_large"], "disabled_upgrades": []}, base)
	assert_gt(float(turbo["peak_torque"]), float(na["peak_torque"]),
		"a fitted turbo rates the car at a higher (boosted) peak torque")


func test_drivetrain_slot_is_valid() -> void:
	assert_true(UpgradeLibrary.SLOTS.has("drivetrain"), "drivetrain is a known slot")
	var kit := UpgradeLibrary.by_id("drivetrain_swap")
	assert_eq(UpgradeLibrary.slot_of("drivetrain_swap"), "drivetrain", "kit occupies the drivetrain slot")
	assert_false(bool(kit.get("consumable", false)), "kit is not a consumable")
	assert_true(bool(kit.get("effect", {}).get("unlocks_drivetrain_swap", false)), "kit carries the unlock flag")


func test_drivetrain_swap_unlocked_gate() -> void:
	var no_kit := {"installed_upgrades": [], "disabled_upgrades": []}
	var fitted := {"installed_upgrades": ["drivetrain_swap"], "disabled_upgrades": []}
	# The drivetrain kit has no enable/disable — owning it is the unlock, so a kit sitting
	# in disabled_upgrades (e.g. won but not podium-applied) is still unlocked.
	var disabled := {"installed_upgrades": ["drivetrain_swap"], "disabled_upgrades": ["drivetrain_swap"]}
	assert_false(UpgradeLibrary.drivetrain_swap_unlocked(no_kit), "no kit -> locked")
	assert_true(UpgradeLibrary.drivetrain_swap_unlocked(fitted), "owned kit -> unlocked")
	assert_true(UpgradeLibrary.drivetrain_swap_unlocked(disabled), "owned kit unlocks even if disabled")


func test_resolve_drive_override() -> void:
	var locked := {"installed_upgrades": [], "disabled_upgrades": [], "drivetrain_override": CarLibrary.FWD}
	assert_eq(UpgradeLibrary.resolve_drive_override(locked), -1, "override ignored without the kit")
	var stock := {"installed_upgrades": ["drivetrain_swap"], "disabled_upgrades": []}
	assert_eq(UpgradeLibrary.resolve_drive_override(stock), -1, "no override set -> -1 (use stock)")
	var picked := {"installed_upgrades": ["drivetrain_swap"], "disabled_upgrades": [], "drivetrain_override": CarLibrary.AWD}
	assert_eq(UpgradeLibrary.resolve_drive_override(picked), CarLibrary.AWD, "unlocked + set -> chosen mode")


func test_effective_meta_reports_override_drive_mode() -> void:
	var meta := {"engine": "", "mass": 1200.0, "peak_torque": 300.0, "redline": 6000.0,
		"drive_mode": CarLibrary.FWD}
	var owned := {"installed_upgrades": ["drivetrain_swap"], "disabled_upgrades": [],
		"drivetrain_override": CarLibrary.RWD}
	var out := UpgradeLibrary.effective_meta(owned, meta)
	assert_eq(int(out.get("drive_mode", -1)), CarLibrary.RWD, "reports the chosen mode when unlocked")
	assert_eq(int(meta["drive_mode"]), CarLibrary.FWD, "source meta is not mutated")


func test_effective_meta_keeps_stock_mode_without_kit() -> void:
	var meta := {"engine": "", "mass": 1200.0, "peak_torque": 300.0, "redline": 6000.0,
		"drive_mode": CarLibrary.FWD}
	var owned := {"installed_upgrades": [], "disabled_upgrades": [], "drivetrain_override": CarLibrary.RWD}
	var out := UpgradeLibrary.effective_meta(owned, meta)
	assert_eq(int(out.get("drive_mode", -1)), CarLibrary.FWD, "override inert without the kit")
