extends GutTest
# The upgrade catalogue (UpgradeLibrary): the authored item list, the effect-
# application pipeline (step 2: baseline → upgrades), and the tuning gates.
# Slot-replacement behaviour (which needs the Save profile) lives in
# test_save_manager.gd. See todo/upgrade-catalogue.md.


func before_each() -> void:
	CarFixtures.install()
	UpgradeFixtures.install()


func after_each() -> void:
	UpgradeFixtures.restore()
	CarFixtures.restore()


func test_catalogue_is_well_formed() -> void:
	var ids := {}
	for item in UpgradeLibrary.UPGRADES:
		assert_false(ids.has(item["id"]), "item id '%s' is unique" % item["id"])
		ids[item["id"]] = true
		if item["consumable"]:
			assert_eq(String(item["slot"]), "", "consumable %s has no slot" % item["id"])
		else:
			assert_true(UpgradeLibrary.SLOTS.has(item["slot"]),
				"%s has a known slot" % item["id"])


func test_lookups() -> void:
	# Mechanism, not authored values: slot_of/by_id resolve any real catalogue
	# entry to its own slot, and degrade safely for unknown ids.
	for item in UpgradeLibrary.all():
		var expected_slot: String = "" if item["consumable"] else String(item["slot"])
		assert_eq(UpgradeLibrary.slot_of(item["id"]), expected_slot,
			"%s slots into its own authored slot" % item["id"])
	assert_eq(UpgradeLibrary.slot_of("nonexistent"), "", "unknown id has no slot")
	assert_true(UpgradeLibrary.by_id("nonexistent").is_empty(), "unknown id -> empty dict")


func test_effect_application_multiplies_and_adds_on_baseline() -> void:
	var cfg := GameConfig.new()
	cfg.peak_torque = 100.0
	cfg.mass = 1000.0
	cfg.downforce_front = 0.0
	cfg.downforce_rear = 0.0
	var car := {"installed_upgrades": ["fx_turbo_big", "fx_lightweight", "fx_aero"]}
	# Expected values are derived from each upgrade's configured effect, so this tests
	# the apply PIPELINE (right field, multiply vs add) without pinning the tunable
	# multipliers/amounts — retuning a kit's strength won't break the test.
	var turbo: Dictionary = UpgradeLibrary.by_id("fx_turbo_big")["effect"]["install_turbo"]
	var wgt: Dictionary = UpgradeLibrary.by_id("fx_lightweight")["effect"]
	var aero: Dictionary = UpgradeLibrary.by_id("fx_aero")["effect"]
	UpgradeLibrary.apply(car, cfg)
	assert_true(cfg.turbo_enabled, "installing a turbo enables it on the config")
	assert_almost_eq(cfg.turbo_boost_gain, float(turbo["turbo_boost_gain"]), 0.001, "turbo kit writes its boost gain")
	assert_almost_eq(cfg.mass, 1000.0 * float(wgt["mass_mult"]), 0.001, "weight reduction multiplies mass")
	assert_almost_eq(cfg.downforce_front, float(aero["downforce_front"]), 0.001, "aero kit adds front downforce")
	assert_almost_eq(cfg.downforce_rear, float(aero["downforce_rear"]), 0.001, "aero kit adds rear downforce")


func test_effective_meta_adjusts_power_to_weight_for_eligibility() -> void:
	# A copy of a roster entry; effective_meta should lighten mass and lift torque
	# so the derived power-to-weight rises (and never mutate the source entry).
	var entry := {"peak_torque": 200.0, "redline": 7000.0, "mass": 1000.0}
	var base_pw := CarLibrary.power_to_weight(entry)
	var car := {"installed_upgrades": ["fx_turbo_big", "fx_lightweight"]}
	var eff := UpgradeLibrary.effective_meta(car, entry)
	var boost_gain: float = float(UpgradeLibrary.by_id("fx_turbo_big")["effect"]["install_turbo"]["turbo_boost_gain"])
	var mass_mult: float = float(UpgradeLibrary.by_id("fx_lightweight")["effect"]["mass_mult"])
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


func test_max_potential_meta_undoes_detune_and_drops_ballast() -> void:
	# max_potential_meta reports the car's BEST achievable power-to-weight: it undoes any
	# engine detune AND removes mass-adding ballast (a free, always-removable part), so a
	# currently-gimped car still reads at its true potential wherever a ceiling is wanted.
	var meta := CarLibrary.by_id("fx_light_rwd")
	var gimped := {"model_id": "fx_light_rwd", "tuning": {"engine_detune": 0.5},
		"installed_upgrades": ["fx_ballast"], "disabled_upgrades": []}
	var cur := UpgradeLibrary.effective_meta(gimped, meta.duplicate())
	var maxed := UpgradeLibrary.max_potential_meta(gimped, meta.duplicate())
	assert_gt(CarLibrary.power_to_weight(maxed), CarLibrary.power_to_weight(cur),
		"max potential (full tune, no ballast) beats the current gimped power-to-weight")
	# It reaches at least an un-gimped car (full tune, no ballast), and now goes FURTHER:
	# the ceiling fits the best part in every slot from the whole catalogue, including parts
	# the car doesn't own and parts still behind a star gate. That's the point — with the
	# good parts gated, fitted hardware would badly understate what a car can become.
	var clean := UpgradeLibrary.effective_meta(
		{"model_id": "fx_light_rwd", "tuning": {}, "installed_upgrades": [], "disabled_upgrades": []},
		meta.duplicate())
	assert_gt(CarLibrary.power_to_weight(maxed), CarLibrary.power_to_weight(clean),
		"the ceiling fits catalogue parts the car does not own, so it beats a bare clean car")


func test_rally_gate_met_defaults_open_and_closes_only_on_an_authored_gate() -> void:
	# The central new predicate, tested directly rather than through the draw. An ungated
	# part is always available; a gated one flips on its rally being recorded complete.
	var unwon := {"rallies": {}}
	var won := {"rallies": {UpgradeFixtures.FX_GATE_RALLY: {"completed": true, "best_placed": 1}}}
	assert_true(UpgradeLibrary.rally_gate_met("fx_lightweight", unwon),
		"a part with no authored gate is always available")
	assert_false(UpgradeLibrary.rally_gate_met("fx_gated", unwon),
		"a gated part is withheld until its rally is won")
	assert_true(UpgradeLibrary.rally_gate_met("fx_gated", won),
		"and becomes available once it is")
	assert_false(UpgradeLibrary.rally_gate_met("fx_gated",
		{"rallies": {UpgradeFixtures.FX_GATE_RALLY: {"completed": false}}}),
		"merely attempting the rally is not enough — completed means a top-3 finish")


func test_a_fitted_part_keeps_applying_while_its_gate_is_closed() -> void:
	# Pinned deliberately: the star gate governs EARNING a part, never keeping one. apply()
	# walks installed_upgrades and never consults the gate, so a gate closing behind the
	# player (or a profile that never opened it) must not retroactively uninstall anything.
	var cfg := GameConfig.new()
	var baseline := cfg.mass
	var car := {"model_id": "fx_light_rwd", "tuning": {},
		"installed_upgrades": ["fx_gated"], "disabled_upgrades": []}
	assert_false(UpgradeLibrary.rally_gate_met("fx_gated", {"rallies": {}}),
		"setup: the part's gate is shut")
	UpgradeLibrary.apply(car, cfg)
	assert_lt(cfg.mass, baseline, "an already-fitted part still takes effect")


func test_max_potential_meta_fits_one_part_per_slot() -> void:
	# Slot exclusivity must hold in the ceiling too: stacking two turbo-slot parts would
	# report a power the car could never actually reach.
	var meta := CarLibrary.by_id("fx_light_rwd")
	var car := {"model_id": "fx_light_rwd", "tuning": {}, "installed_upgrades": [], "disabled_upgrades": []}
	var seen := {}
	for item_id in UpgradeLibrary._best_part_per_slot(car, meta.duplicate()):
		var slot := UpgradeLibrary.slot_of(String(item_id))
		assert_false(seen.has(slot), "at most one part per slot in the ceiling (%s)" % slot)
		seen[slot] = true


func test_no_upgrades_leaves_config_untouched() -> void:
	var cfg := GameConfig.new()
	cfg.peak_torque = 250.0
	UpgradeLibrary.apply({"installed_upgrades": []}, cfg)
	assert_almost_eq(cfg.peak_torque, 250.0, 0.001, "empty upgrade list is a no-op")


func test_a_tire_part_multiplies_BOTH_axle_grips_on_the_live_config() -> void:
	# The one effect row whose meta spelling and live-config spelling differ: `tire_compound`
	# on a car's meta, the per-axle wheel_friction_slip_* PAIR on the config
	# (UpgradeLibrary._cfg_fields). Both axles must move, or fitting tyres would silently
	# re-balance the car front-to-rear as well as grip it up. Multiplied (not set) so the
	# grip_balance tuning slider, which runs after, still shifts them about this baseline.
	var cfg := GameConfig.new()
	cfg.wheel_friction_slip_front = 0.9
	cfg.wheel_friction_slip_rear = 0.7
	var mult := float(UpgradeLibrary.by_id("fx_tires")["effect"]["tire_grip_mult"])
	UpgradeLibrary.apply({"installed_upgrades": ["fx_tires"]}, cfg)
	assert_almost_eq(cfg.wheel_friction_slip_front, 0.9 * mult, 0.001, "front axle grip multiplied")
	assert_almost_eq(cfg.wheel_friction_slip_rear, 0.7 * mult, 0.001, "rear axle grip multiplied")


func test_a_gearbox_part_sets_an_absolute_shift_time() -> void:
	# The "set" op REPLACES the baseline rather than scaling it, so what the car brought to
	# the slot must not survive. Asserted from two different baselines — one slower than the
	# kit and one faster — because a multiplier would land on two different answers while a
	# set lands on the same one. The expected figure is read from the catalogue, so retuning
	# the kit can't break this.
	var want := float(UpgradeLibrary.by_id("fx_gearbox")["effect"]["shift_time_set"])
	for baseline in [0.4, want * 0.5]:
		var cfg := GameConfig.new()
		cfg.shift_time = baseline
		UpgradeLibrary.apply({"installed_upgrades": ["fx_gearbox"]}, cfg)
		assert_almost_eq(cfg.shift_time, want, 0.0001,
			"the kit's own shift time replaces a %.2fs baseline outright" % baseline)


func test_grip_parts_move_grip_meta_and_are_invisible_to_eligibility() -> void:
	# THE safeguard that keeps grip_meta and effective_meta separate: a wing or a set of
	# tyres must show up on a grip readout and must NOT move power-to-weight, because p/w is
	# what a rally's band is judged on — otherwise fitting tyres could lock a car out of
	# events it could previously enter. Derived from the fixtures' own effects, so retuning
	# either part can't break it.
	var entry := {"peak_torque": 200.0, "redline": 7000.0, "mass": 1000.0,
		"weight_front": 0.5, "tire_compound": 0.9,
		"wheel_width_front": 0.225, "wheel_width_rear": 0.225}
	var car := {"installed_upgrades": ["fx_tires", "fx_aero"], "disabled_upgrades": [], "tuning": {}}
	var eff := UpgradeLibrary.effective_meta(car, entry)
	var grip := UpgradeLibrary.grip_meta(car, entry)
	var bare := UpgradeLibrary.effective_meta({"installed_upgrades": [], "tuning": {}}, entry)
	assert_almost_eq(CarLibrary.power_to_weight(eff), CarLibrary.power_to_weight(bare), 0.001,
		"grip parts leave power-to-weight — and therefore rally eligibility — alone")
	assert_almost_eq(float(eff.get("tire_compound", 0.0)), float(entry["tire_compound"]), 0.001,
		"effective_meta does not fold the compound multiplier in")
	var tire_mult := float(UpgradeLibrary.by_id("fx_tires")["effect"]["tire_grip_mult"])
	var aero: Dictionary = UpgradeLibrary.by_id("fx_aero")["effect"]
	assert_almost_eq(float(grip["tire_compound"]), float(entry["tire_compound"]) * tire_mult, 0.001,
		"grip_meta multiplies the compound (the mult arm)")
	assert_almost_eq(float(grip["downforce_front"]), float(aero["downforce_front"]), 0.001,
		"grip_meta still adds downforce (the add arm)")
	# And the figure the Simple page's Grip row draws actually rises — at any speed for the
	# tyres, and the downforce term needs a speed to exist at all.
	assert_gt(CarLibrary.max_lateral_g(grip, Config.data, 50.0),
		CarLibrary.max_lateral_g(bare, Config.data, 50.0),
		"the grip figure rises once tyres and a wing are fitted")
	assert_almost_eq(float(entry["tire_compound"]), 0.9, 0.001, "the source entry is left untouched")


func test_aero_tuning_is_gated_by_the_aero_upgrade() -> void:
	var bare := {"installed_upgrades": []}
	assert_false(UpgradeLibrary.aero_tuning_unlocked(bare), "aero tuning locked with no aero kit")
	var kitted := {"installed_upgrades": ["fx_aero"]}
	assert_true(UpgradeLibrary.aero_tuning_unlocked(kitted), "aero kit unlocks aero tuning")


func test_disabled_upgrades_are_inert_everywhere() -> void:
	# A part toggled off in the upgrades menu stays fitted but contributes nothing:
	# no config effect, no effective-meta shift, no tuning gate.
	var car := {
		"installed_upgrades": ["fx_turbo_big", "fx_aero", "fx_lightweight"],
		"disabled_upgrades": ["fx_turbo_big", "fx_aero", "fx_lightweight"],
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
	# enabled_upgrades reflects the toggle; re-enabling brings the part back.
	assert_eq(UpgradeLibrary.enabled_upgrades(car).size(), 0, "everything disabled -> nothing enabled")
	car["disabled_upgrades"] = []
	assert_eq(UpgradeLibrary.enabled_upgrades(car).size(), 3, "clearing the toggles re-enables the parts")
	assert_true(UpgradeLibrary.aero_tuning_unlocked(car), "a re-enabled aero kit unlocks aero tuning again")


func test_install_supercharger_writes_blower_fields_and_clears_the_turbo() -> void:
	var cfg := GameConfig.new()
	# Start from a turbo'd baseline: the blower shares the slot, so fitting it must
	# take the turbo sim OFF rather than stacking both forced-induction paths.
	cfg.turbo_enabled = true
	cfg.turbo_boost_gain = 0.5
	var owned := {"installed_upgrades": ["fx_supercharger"], "disabled_upgrades": []}
	UpgradeLibrary.apply(owned, cfg)
	assert_true(cfg.supercharger_enabled, "installing a blower enables it on the config")
	assert_gt(cfg.supercharger_boost_gain, 0.0, "the blower upgrade sets a belt boost gain")
	assert_gt(cfg.supercharger_parasitic_coef, 0.0, "and an rpm-scaled belt drag")
	assert_false(cfg.turbo_enabled, "a blower replaces the turbo instead of stacking with it")


func test_install_turbo_clears_the_blower_the_other_way_round() -> void:
	# The exclusivity is SYMMETRIC (EFFECTS[*].clears), not just blower-clears-turbo:
	# fitting a turbo onto a baseline that carries belt boost must cancel it, or the two
	# torque multipliers would stack.
	var cfg := GameConfig.new()
	cfg.supercharger_enabled = true
	cfg.supercharger_boost_gain = 0.9
	var owned := {"installed_upgrades": ["fx_turbo_big"], "disabled_upgrades": []}
	UpgradeLibrary.apply(owned, cfg)
	assert_true(cfg.turbo_enabled, "the turbo is fitted")
	assert_eq(cfg.supercharger_boost_gain, 0.0, "and the blower's belt boost is cancelled")
	assert_false(cfg.supercharger_enabled, "including its audio flag")


func test_effective_meta_rates_the_blower_at_peak_boost() -> void:
	var base := {"peak_torque": 300.0, "redline": 7000.0, "mass": 1200.0, "engine": ""}
	var na := UpgradeLibrary.effective_meta({"installed_upgrades": [], "disabled_upgrades": []}, base)
	var blown := UpgradeLibrary.effective_meta(
		{"installed_upgrades": ["fx_supercharger"], "disabled_upgrades": []}, base)
	assert_gt(float(blown["peak_torque"]), float(na["peak_torque"]),
		"a fitted blower rates the car at a higher (boosted) peak torque")


func test_install_turbo_writes_turbo_fields_onto_config() -> void:
	var cfg := GameConfig.new()
	assert_false(cfg.turbo_enabled, "config starts NA")
	var owned := {"installed_upgrades": ["fx_turbo_big"], "disabled_upgrades": []}
	UpgradeLibrary.apply(owned, cfg)
	assert_true(cfg.turbo_enabled, "installing a turbo enables it on the config")
	assert_gt(cfg.turbo_boost_gain, 0.0, "the turbo upgrade sets a boost gain")


func test_effective_meta_rates_turbo_at_peak_boost() -> void:
	# Synthetic meta carrying its own peak_torque so we don't depend on the catalogue.
	var base := {"peak_torque": 300.0, "redline": 7000.0, "mass": 1200.0, "engine": ""}
	var na := UpgradeLibrary.effective_meta({"installed_upgrades": [], "disabled_upgrades": []}, base)
	var turbo := UpgradeLibrary.effective_meta({"installed_upgrades": ["fx_turbo_big"], "disabled_upgrades": []}, base)
	assert_gt(float(turbo["peak_torque"]), float(na["peak_torque"]),
		"a fitted turbo rates the car at a higher (boosted) peak torque")


func test_drivetrain_slot_is_valid() -> void:
	assert_true(UpgradeLibrary.SLOTS.has("drivetrain"), "drivetrain is a known slot")
	var kit := UpgradeLibrary.by_id("fx_drivetrain")
	assert_eq(UpgradeLibrary.slot_of("fx_drivetrain"), "drivetrain", "kit occupies the drivetrain slot")
	assert_false(bool(kit.get("consumable", false)), "kit is not a consumable")
	assert_true(bool(kit.get("effect", {}).get("unlocks_drivetrain_swap", false)), "kit carries the unlock flag")


func test_drivetrain_swap_unlocked_gate() -> void:
	var no_kit := {"installed_upgrades": [], "disabled_upgrades": []}
	var fitted := {"installed_upgrades": ["fx_drivetrain"], "disabled_upgrades": []}
	# The drivetrain kit has no enable/disable — owning it is the unlock, so a kit sitting
	# in disabled_upgrades (e.g. won but not podium-applied) is still unlocked.
	var disabled := {"installed_upgrades": ["fx_drivetrain"], "disabled_upgrades": ["fx_drivetrain"]}
	assert_false(UpgradeLibrary.drivetrain_swap_unlocked(no_kit), "no kit -> locked")
	assert_true(UpgradeLibrary.drivetrain_swap_unlocked(fitted), "owned kit -> unlocked")
	assert_true(UpgradeLibrary.drivetrain_swap_unlocked(disabled), "owned kit unlocks even if disabled")


func test_resolve_drive_override() -> void:
	var locked := {"installed_upgrades": [], "disabled_upgrades": [], "drivetrain_override": CarLibrary.FWD}
	assert_eq(UpgradeLibrary.resolve_drive_override(locked), -1, "override ignored without the kit")
	var stock := {"installed_upgrades": ["fx_drivetrain"], "disabled_upgrades": []}
	assert_eq(UpgradeLibrary.resolve_drive_override(stock), -1, "no override set -> -1 (use stock)")
	var picked := {"installed_upgrades": ["fx_drivetrain"], "disabled_upgrades": [], "drivetrain_override": CarLibrary.AWD}
	assert_eq(UpgradeLibrary.resolve_drive_override(picked), CarLibrary.AWD, "unlocked + set -> chosen mode")


func test_effective_meta_reports_override_drive_mode() -> void:
	var meta := {"engine": "", "mass": 1200.0, "peak_torque": 300.0, "redline": 6000.0,
		"drive_mode": CarLibrary.FWD}
	var owned := {"installed_upgrades": ["fx_drivetrain"], "disabled_upgrades": [],
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


# --- Prerequisite gate (requires_upgrade_id) ----------------------------------
# The mechanism that replaced Big Turbo's old difficulty/tier gate: an item can
# name another item as a prerequisite, and is only reward-eligible for a car
# that already has that prerequisite fitted (per-car, not garage-wide).
# Synthetic entries throughout —
# see CLAUDE.md: never pin logic tests to a specific catalogue id.

func test_prerequisite_met_is_true_with_no_requirement() -> void:
	UpgradeLibrary.override_for_test([
		{"id": "fx_plain", "name": "Plain", "slot": "aero", "tier": 1, "consumable": false, "effect": {}},
	])
	assert_true(UpgradeLibrary.prerequisite_met("fx_plain", {}),
		"an item with no requires_upgrade_id is always prerequisite-eligible")


func test_prerequisite_met_requires_the_prereq_to_be_owned() -> void:
	UpgradeLibrary.override_for_test([
		{"id": "fx_small", "name": "Small", "slot": "turbo", "tier": 1, "consumable": false, "effect": {}},
		{"id": "fx_big", "name": "Big", "slot": "turbo", "tier": 1, "consumable": false,
			"requires_upgrade_id": "fx_small", "effect": {}},
	])
	var without_prereq := {"instance_id": 1, "model_id": "m", "installed_upgrades": []}
	assert_false(UpgradeLibrary.prerequisite_met("fx_big", without_prereq),
		"gated until the prerequisite is fitted to this car")
	var with_prereq := {"instance_id": 1, "model_id": "m", "installed_upgrades": ["fx_small"]}
	assert_true(UpgradeLibrary.prerequisite_met("fx_big", with_prereq),
		"eligible once the prerequisite is fitted to this car")


# The gate is per-car: another car in the garage owning the prerequisite does
# NOT unlock the gated item for a car that lacks it.
func test_prerequisite_is_not_satisfied_by_another_car_in_the_garage() -> void:
	UpgradeLibrary.override_for_test([
		{"id": "fx_small", "name": "Small", "slot": "turbo", "tier": 1, "consumable": false, "effect": {}},
		{"id": "fx_big", "name": "Big", "slot": "turbo", "tier": 1, "consumable": false,
			"requires_upgrade_id": "fx_small", "effect": {}},
	])
	var bare_car := {"instance_id": 2, "model_id": "m2", "installed_upgrades": []}
	assert_false(UpgradeLibrary.prerequisite_met("fx_big", bare_car),
		"a sibling car owning the prerequisite doesn't unlock it for this one")
	assert_false(UpgradeLibrary.prerequisite_met("fx_big", {}),
		"an empty car dict owns nothing")


# --- fitted_nitrous_id (the HQ car-stats readout) -----------------------------
# Synthetic entries throughout — see CLAUDE.md: never pin logic tests to a specific
# catalogue id.

func test_fitted_nitrous_id_is_empty_with_nothing_installed() -> void:
	UpgradeLibrary.override_for_test([
		{"id": "fx_nitrous", "name": "Fixture Nitrous", "slot": "nitrous", "consumable": false, "effect": {}},
	])
	assert_eq(UpgradeLibrary.fitted_nitrous_id({"installed_upgrades": []}), "",
		"nothing installed -> no nitrous")
	assert_eq(UpgradeLibrary.fitted_nitrous_id({}), "", "an empty car dict owns nothing")


func test_fitted_nitrous_id_returns_the_installed_and_enabled_rung() -> void:
	UpgradeLibrary.override_for_test([
		{"id": "fx_nitrous", "name": "Fixture Nitrous", "slot": "nitrous", "consumable": false, "effect": {}},
	])
	var car := {"installed_upgrades": ["fx_nitrous"], "disabled_upgrades": []}
	assert_eq(UpgradeLibrary.fitted_nitrous_id(car), "fx_nitrous",
		"an installed, enabled nitrous-slot item is reported fitted")


func test_fitted_nitrous_id_ignores_a_disabled_rung() -> void:
	UpgradeLibrary.override_for_test([
		{"id": "fx_nitrous", "name": "Fixture Nitrous", "slot": "nitrous", "consumable": false, "effect": {}},
	])
	var car := {"installed_upgrades": ["fx_nitrous"], "disabled_upgrades": ["fx_nitrous"]}
	assert_eq(UpgradeLibrary.fitted_nitrous_id(car), "",
		"installed but toggled off does not count as fitted")


# The ladder shape (features/nitrous.md): several rungs can be INSTALLED on one car at
# once (each grant keeps the one below it so the prerequisite chain holds), but only one
# is ever ENABLED — the readout must name that one, not just the first installed.
func test_fitted_nitrous_id_picks_the_enabled_rung_not_the_first_installed() -> void:
	UpgradeLibrary.override_for_test([
		{"id": "fx_nitrous", "name": "Fixture Nitrous", "slot": "nitrous", "consumable": false, "effect": {}},
		{"id": "fx_nitrous_big", "name": "Fixture Big Nitrous", "slot": "nitrous",
			"requires_upgrade_id": "fx_nitrous", "consumable": false, "effect": {}},
	])
	var car := {
		"installed_upgrades": ["fx_nitrous", "fx_nitrous_big"],
		"disabled_upgrades": ["fx_nitrous"],  # the ladder's older rung, parked
	}
	assert_eq(UpgradeLibrary.fitted_nitrous_id(car), "fx_nitrous_big",
		"the enabled (highest) rung is reported, even though it was installed second")


# A part in a DIFFERENT slot must never be mistaken for nitrous, however it's enabled.
func test_fitted_nitrous_id_ignores_other_slots() -> void:
	UpgradeLibrary.override_for_test([
		{"id": "fx_turbo", "name": "Fixture Turbo", "slot": "turbo", "consumable": false, "effect": {}},
	])
	var car := {"installed_upgrades": ["fx_turbo"], "disabled_upgrades": []}
	assert_eq(UpgradeLibrary.fitted_nitrous_id(car), "",
		"a fitted part in another slot is not reported as nitrous")


func test_a_surface_dependent_compound_reaches_both_the_config_and_the_grip_meta() -> void:
	# The surface-dependent tyre rows (features/drivetrain-and-tires.md) have to land in
	# TWO places to work: on the live config, which the driving physics reads, and on
	# grip_meta, which is what the lap-time model is handed for the AI field. A part that
	# reached only the first would give the player an advantage the rivals never see.
	# Derived from the fixture's own effect, so retuning it can't break this.
	var eff: Dictionary = UpgradeLibrary.by_id("fx_snow_tires")["effect"]
	var car := {"installed_upgrades": ["fx_snow_tires"]}
	var cfg := GameConfig.new()
	UpgradeLibrary.apply(car, cfg)
	assert_almost_eq(cfg.tire_snow_grip_mult, float(eff["tire_snow_grip_mult"]), 1e-6,
		"the snow bonus lands on the live config")
	assert_almost_eq(cfg.tire_tarmac_grip_mult, float(eff["tire_tarmac_grip_mult"]), 1e-6,
		"the tarmac penalty lands on the live config")
	var meta := UpgradeLibrary.grip_meta(car, {"tire_compound": 1.0, "mass": 1000.0})
	assert_almost_eq(float(meta["tire_snow_grip_mult"]), float(eff["tire_snow_grip_mult"]), 1e-6,
		"the snow bonus is mirrored onto grip_meta")
	assert_almost_eq(float(meta["tire_tarmac_grip_mult"]), float(eff["tire_tarmac_grip_mult"]), 1e-6,
		"the tarmac penalty is mirrored onto grip_meta")


func test_a_surface_dependent_compound_never_moves_power_to_weight() -> void:
	# Same rule the flat compound and the aero kit follow: rubber must never change
	# which rallies a car may enter. effective_meta is what eligibility is judged on.
	var plain := UpgradeLibrary.effective_meta({"installed_upgrades": []},
		{"tire_compound": 1.0, "mass": 1000.0, "peak_torque": 200.0, "redline": 6000.0})
	var shod := UpgradeLibrary.effective_meta({"installed_upgrades": ["fx_snow_tires"]},
		{"tire_compound": 1.0, "mass": 1000.0, "peak_torque": 200.0, "redline": 6000.0})
	assert_almost_eq(float(shod["mass"]), float(plain["mass"]), 1e-6, "mass is untouched")
	assert_almost_eq(float(shod["peak_torque"]), float(plain["peak_torque"]), 1e-6,
		"peak torque is untouched")


func test_a_car_with_no_surface_compound_leaves_the_multipliers_neutral() -> void:
	# 1.0 is the identity the whole mechanism rests on, and the reason no other part
	# in the catalogue needed an entry. A flat-compound tyre must not disturb it.
	var cfg := GameConfig.new()
	UpgradeLibrary.apply({"installed_upgrades": ["fx_tires"]}, cfg)
	assert_almost_eq(cfg.tire_snow_grip_mult, 1.0, 1e-6, "flat rubber leaves the snow term at 1")
	assert_almost_eq(cfg.tire_tarmac_grip_mult, 1.0, 1e-6, "flat rubber leaves the tarmac term at 1")
	var meta := UpgradeLibrary.grip_meta({"installed_upgrades": ["fx_tires"]},
		{"tire_compound": 1.0, "mass": 1000.0})
	assert_almost_eq(float(meta.get("tire_snow_grip_mult", 1.0)), 1.0, 1e-6,
		"and reads as 1 off the meta, present or absent")
