extends GutTest
# The EFFECTS FUNNEL (UpgradeLibrary), which is all that survives of the old upgrade
# catalogue. The persistent parts model is deleted (todo/roguelike-pivot.md ->
# "What gets deleted"); what stays is the pipeline that turns a car's ACTIVE EFFECTS
# into live config and into the derived meta the UI compares builds with:
#
#   active_effects(owned)  ->  reads owned["boosts"]
#   apply(owned, cfg)      ->  writes the live GameConfig (pipeline step 2)
#   effective_meta(...)    ->  the power-to-weight view (feeds_pw rows)
#   grip_meta(...)         ->  the grip view (feeds_grip rows)
#
# In the pivot this becomes the IN-RUN BOOST applier (spec -> "Upgrades — RR's two-tier
# model"): stage 5 writes `boosts` onto the owned-car dict and every call site below is
# already wired. Nothing writes it yet, so `apply` is a no-op on a real car today — which
# is exactly why these tests build their own synthetic boosts through UpgradeFixtures
# rather than reaching for authored data that no longer exists.
#
# Per CLAUDE.md these test the FUNNEL'S LOGIC, never a tuned magnitude: the fixtures'
# numbers are arbitrary, and an assertion that pinned one would break the moment a
# designer retuned a boost.


func before_each() -> void:
	CarFixtures.install()
	Config.reset()


func after_each() -> void:
	CarFixtures.restore()
	Config.reset()


# A minimal owned-car dict: just the keys the funnel reads. Deliberately hand-built
# rather than drawn from a catalogue — per CLAUDE.md a logic test must not lean on a
# particular authored entry's identity or stats.
func _car(boost_ids: Array = []) -> Dictionary:
	var owned := {"instance_id": 1, "model_id": "fx_light_rwd"}
	if not boost_ids.is_empty():
		owned["boosts"] = UpgradeFixtures.boosts(boost_ids)
	return owned


# --- The EFFECTS table's own contract ----------------------------------------

# The guard the EFFECTS header calls for by name. An effect whose target GameConfig
# property does not exist is a SILENTLY dead effect: _cfg_set refuses the write, the boost
# reads as active, and no gameplay test fails. Catch it here instead.
func test_every_effect_target_names_a_real_config_property() -> void:
	var cfg := GameConfig.new()
	for key in UpgradeLibrary.EFFECTS:
		var desc: Dictionary = UpgradeLibrary.EFFECTS[key]
		for field in UpgradeLibrary._cfg_fields(desc):
			# An empty `field` is not a bug: the install_* / write_fields ops take their
			# targets from the boost's own authored value, not from the descriptor, so
			# there is nothing to check here for those rows. _cfg_set guards them at
			# write time instead.
			if String(field) == "":
				continue
			assert_true(field in cfg,
				"EFFECTS['%s'] writes GameConfig.%s, which does not exist" % [key, field])
		var enable := String(desc.get("enable", ""))
		if enable != "":
			assert_true(enable in cfg,
				"EFFECTS['%s'].enable names GameConfig.%s, which does not exist" % [key, enable])
		for cleared in (desc.get("clears", {}) as Dictionary):
			assert_true(cleared in cfg,
				"EFFECTS['%s'].clears names GameConfig.%s, which does not exist" % [key, cleared])


# Every effect key the fixtures author must have an EFFECTS row. A key with no row is the
# other silent-death shape: apply() selects no arm and the value is never written at all.
func test_every_fixture_effect_key_has_an_effects_row() -> void:
	for id in UpgradeFixtures.EFFECTS:
		for key in (UpgradeFixtures.EFFECTS[id] as Dictionary):
			assert_true(UpgradeLibrary.EFFECTS.has(key),
				"fixture '%s' authors effect key '%s' with no EFFECTS row" % [id, key])


# --- active_effects: the stage-5 seam ----------------------------------------

func test_a_car_with_no_boosts_has_no_active_effects() -> void:
	assert_eq(UpgradeLibrary.active_effects(_car()), [],
		"a car with no boosts key yields no effects, rather than erroring")


func test_active_effects_reads_the_boosts_key() -> void:
	var owned := _car(["fx_turbo_big", "fx_lightweight"])
	var ids: Array = []
	for e in UpgradeLibrary.active_effects(owned):
		ids.append(String((e as Dictionary)["id"]))
	assert_eq(ids, ["fx_turbo_big", "fx_lightweight"],
		"active_effects hands back the boosts in the order they were granted")


# --- apply(): boosts -> live config ------------------------------------------

func test_apply_is_a_no_op_without_boosts() -> void:
	var cfg := GameConfig.new()
	var before: float = cfg.shift_time
	UpgradeLibrary.apply(_car(), cfg)
	assert_eq(cfg.shift_time, before, "an un-boosted car leaves the config untouched")


func test_the_set_op_writes_an_absolute_value() -> void:
	var cfg := GameConfig.new()
	UpgradeLibrary.apply(_car(["fx_gearbox"]), cfg)
	assert_eq(cfg.shift_time, float(UpgradeFixtures.EFFECTS["fx_gearbox"]["shift_time_set"]),
		"a 'set' effect replaces the baseline outright rather than scaling it")


func test_the_mult_op_scales_the_baseline() -> void:
	var cfg := GameConfig.new()
	var base: float = cfg.mass
	UpgradeLibrary.apply(_car(["fx_lightweight"]), cfg)
	assert_lt(cfg.mass, base, "a mass_mult below 1 makes the car lighter")

	var heavier := GameConfig.new()
	UpgradeLibrary.apply(_car(["fx_ballast"]), heavier)
	assert_gt(heavier.mass, base, "and one above 1 makes it heavier")


func test_the_add_op_accumulates_over_the_baseline() -> void:
	var cfg := GameConfig.new()
	var base: int = cfg.downforce_front
	UpgradeLibrary.apply(_car(["fx_aero"]), cfg)
	assert_gt(cfg.downforce_front, base, "an 'add' effect stacks on top of the baseline")


func test_two_boosts_of_the_same_op_compound() -> void:
	var one := GameConfig.new()
	UpgradeLibrary.apply(_car(["fx_lightweight"]), one)
	var both := GameConfig.new()
	UpgradeLibrary.apply(_car(["fx_lightweight", "fx_ballast"]), both)
	assert_ne(one.mass, both.mass,
		"a second mass effect compounds on the first rather than replacing it")


func test_installing_an_induction_sets_its_enable_flag() -> void:
	var cfg := GameConfig.new()
	UpgradeLibrary.apply(_car(["fx_turbo_big"]), cfg)
	assert_true(cfg.turbo_enabled, "installing a turbo switches its physics on")
	assert_gt(cfg.turbo_boost_gain, 0.0, "and seats the gain the boost authored")


# The pair of effects that must cancel each other. A car cannot be running a turbo AND a
# blower: whichever is applied last has to clear the other's enable flag AND the belt gain
# that switches its physics on, or the car quietly runs both.
func test_an_induction_clears_the_one_it_replaces() -> void:
	var cfg := GameConfig.new()
	UpgradeLibrary.apply(_car(["fx_supercharger", "fx_turbo_big"]), cfg)
	assert_true(cfg.turbo_enabled, "the turbo applied last is the one running")
	assert_false(cfg.supercharger_enabled, "and the blower it replaced is switched off")
	assert_eq(cfg.supercharger_boost_gain, 0.0,
		"its belt gain is cleared too — the enable flag alone leaves the physics on")

	var other := GameConfig.new()
	UpgradeLibrary.apply(_car(["fx_turbo_big", "fx_supercharger"]), other)
	assert_true(other.supercharger_enabled, "and the cancellation works the other way round")
	assert_false(other.turbo_enabled)


func test_the_write_fields_op_splats_its_fields_with_no_enable_flag() -> void:
	var cfg := GameConfig.new()
	UpgradeLibrary.apply(_car(["fx_nitrous"]), cfg)
	assert_gt(cfg.nitrous_boost_gain, 0.0, "nitrous writes its own config fields directly")
	assert_gt(cfg.nitrous_tank_seconds, 0.0)


# The one row whose META spelling and LIVE-CONFIG spelling differ: one tire_compound
# coefficient standing for a per-axle pair. Both axles must move, or the tuning slider's
# front/rear balance silently stops meaning anything.
func test_a_cfg_fields_effect_writes_every_field_it_names() -> void:
	var cfg := GameConfig.new()
	var front: float = cfg.wheel_friction_slip_front
	var rear: float = cfg.wheel_friction_slip_rear
	UpgradeLibrary.apply(_car(["fx_tires"]), cfg)
	assert_gt(cfg.wheel_friction_slip_front, front, "the front axle is scaled")
	assert_gt(cfg.wheel_friction_slip_rear, rear, "and so is the rear")


# --- effective_meta: the power-to-weight view --------------------------------

func test_effective_meta_of_an_empty_meta_is_empty() -> void:
	assert_eq(UpgradeLibrary.effective_meta(_car(), {}), {},
		"no meta in, no meta out — callers pass {} for an unknown car")


func test_effective_meta_mirrors_a_feeds_pw_effect() -> void:
	var meta := {"mass": 1200.0, "peak_torque": 400.0, "redline": 6000.0}
	var boosted := UpgradeLibrary.effective_meta(_car(["fx_lightweight"]), meta)
	assert_lt(float(boosted["mass"]), float(meta["mass"]),
		"a feeds_pw effect reaches the derived meta, not just the live config")
	assert_eq(meta["mass"], 1200.0, "and the caller's dict is not mutated")


# Nitrous is deliberately feeds_pw FALSE: it is a per-stage resource, not a permanent power
# level, so a bottle the player empties in one stage must never read as a permanent gain
# anywhere a build is compared or displayed.
func test_a_non_feeds_pw_effect_stays_out_of_the_meta() -> void:
	var meta := {"mass": 1200.0, "peak_torque": 400.0, "redline": 6000.0}
	var boosted := UpgradeLibrary.effective_meta(_car(["fx_nitrous"]), meta)
	assert_eq(boosted, meta, "nitrous changes the config but not the power-to-weight view")


# --- grip_meta: the grip view ------------------------------------------------

func test_grip_meta_mirrors_a_feeds_grip_effect() -> void:
	var meta := {"mass": 1200.0, "peak_torque": 400.0, "redline": 6000.0,
		"tire_compound": 1.0}
	var boosted := UpgradeLibrary.grip_meta(_car(["fx_tires"]), meta)
	assert_gt(float(boosted["tire_compound"]), float(meta["tire_compound"]),
		"a feeds_grip effect reaches the grip view")


# The surface-dependent compound trades in BOTH directions — better on snow, worse on
# tarmac. A one-way assertion would let a sign error through.
func test_a_surface_compound_trades_in_both_directions() -> void:
	var meta := {"mass": 1200.0, "peak_torque": 400.0, "redline": 6000.0,
		"tire_compound": 1.0, "tire_snow_grip_mult": 1.0, "tire_tarmac_grip_mult": 1.0}
	var boosted := UpgradeLibrary.grip_meta(_car(["fx_snow_tires"]), meta)
	assert_gt(float(boosted["tire_snow_grip_mult"]), 1.0, "snow grip goes up")
	assert_lt(float(boosted["tire_tarmac_grip_mult"]), 1.0, "and tarmac grip pays for it")


func test_a_non_feeds_grip_effect_stays_out_of_the_grip_view() -> void:
	var meta := {"mass": 1200.0, "peak_torque": 400.0, "redline": 6000.0,
		"tire_compound": 1.0}
	var boosted := UpgradeLibrary.grip_meta(_car(["fx_gearbox"]), meta)
	assert_eq(float(boosted["tire_compound"]), float(meta["tire_compound"]),
		"a gearbox does not change the tyres")


# --- Drive mode --------------------------------------------------------------

func test_stock_drive_mode_comes_from_the_car() -> void:
	var owned := _car()
	assert_eq(UpgradeLibrary.stock_drive_mode(owned),
		int(CarLibrary.for_owned(owned).get("drive_mode", CarLibrary.RWD)),
		"the stock layout is the car's own authored drive_mode")


func test_no_stored_override_resolves_to_stock() -> void:
	assert_eq(UpgradeLibrary.resolve_drive_override(_car()), -1,
		"-1 means 'use the car's authored layout'")


# A conversion is a run-scoped mid-run upgrade now (RunSession.choose_drivetrain), not a
# purchase — resolve_drive_override just range-checks the stored value, with no separate
# gate, since world.gd::_field_car is the only legitimate writer of the field.
func test_a_stored_override_is_honoured() -> void:
	var owned := _car()
	var stock := UpgradeLibrary.stock_drive_mode(owned)
	var other := CarLibrary.AWD if stock != CarLibrary.AWD else CarLibrary.FWD
	owned["drivetrain_override"] = other
	assert_eq(UpgradeLibrary.resolve_drive_override(owned), other,
		"a valid stored override is honoured")


func test_an_out_of_range_override_is_inert() -> void:
	var owned := _car()
	owned["drivetrain_override"] = 99
	assert_eq(UpgradeLibrary.resolve_drive_override(owned), -1,
		"a value outside the DriveMode enum resolves to stock")
