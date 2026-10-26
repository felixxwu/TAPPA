extends GutTest
# BoostLibrary (scripts/boost_library.gd) — the parts catalogue free-roam loot is made of
# (features/loot.md: a part is a boost id found at a level), and its level scaling
# (magnitude_for).
#
# Per CLAUDE.md nothing here may pin a shipped magnitude (run_boost_mass_mult,
# boost_level_magnitude_step and friends are GameConfig tunables a designer retunes
# freely) — every assertion below is a CONTRACT: every catalogue entry resolves to a
# real UpgradeLibrary effect, and magnitude_for scales AWAY from the baseline in the
# direction a boost's own `level_direction` names.

func before_each() -> void:
	Config.reset()


func after_each() -> void:
	Config.reset()


# --- The catalogue's own contract, mirroring test_upgrade_library.gd's guard -----

# Every catalogue entry must name a real UpgradeLibrary.EFFECTS row — the funnel's own
# silent-death trap (an effect key with no EFFECTS row is dropped by apply() with
# nothing failing) applies here just as much as it does to a fixture.
func test_every_catalogue_effect_key_has_an_effects_row() -> void:
	for id in BoostLibrary.CATALOGUE:
		var entry: Dictionary = BoostLibrary.CATALOGUE[id]
		for effect_key in (entry["effect_fields"] as Dictionary):
			assert_true(UpgradeLibrary.EFFECTS.has(effect_key),
				"boost '%s' authors effect key '%s' with no EFFECTS row" % [id, effect_key])


# Every catalogue entry must resolve to a real GameConfig field — the OTHER silent-death
# trap (_cfg_set refuses a write to a field that doesn't exist). A dict-shaped mapping
# (turbo/supercharger — see boost_library.gd's CATALOGUE header) names several cfg
# fields at once, so its OWN values are checked rather than the dict itself.
func test_every_catalogue_cfg_field_is_a_real_config_property() -> void:
	var cfg := GameConfig.new()
	for id in BoostLibrary.CATALOGUE:
		var entry: Dictionary = BoostLibrary.CATALOGUE[id]
		for spec in (entry["effect_fields"] as Dictionary).values():
			var cfg_fields := (spec as Dictionary).values() if spec is Dictionary else [spec]
			for cfg_field in cfg_fields:
				assert_true(String(cfg_field) in cfg,
					"boost '%s' reads GameConfig.%s, which does not exist" % [id, cfg_field])


# --- Level scaling: magnitude_for ------------------------------

# A higher level pushes the magnitude further AWAY from baseline, in the direction the
# catalogue entry's own `level_direction` names — never toward it and never past a sign
# flip. Exercises every catalogue entry so a future boost's direction is checked too.
func test_a_higher_level_pushes_the_magnitude_further_in_its_authored_direction() -> void:
	Config.data.boost_level_magnitude_step = 0.1
	for id in BoostLibrary.CATALOGUE:
		var direction := int((BoostLibrary.CATALOGUE[id] as Dictionary).get("level_direction", 1))
		var lvl0 := _leveled_scalar(id, 0)
		var lvl1 := _leveled_scalar(id, 1)
		var lvl3 := _leveled_scalar(id, 3)
		if direction > 0:
			assert_gt(lvl1, lvl0, "'%s' level 1 rolls higher than level 0" % id)
			assert_gt(lvl3, lvl1, "'%s' level 3 rolls higher still than level 1" % id)
		else:
			assert_lt(lvl1, lvl0, "'%s' level 1 rolls lower than level 0" % id)
			assert_lt(lvl3, lvl1, "'%s' level 3 rolls lower still than level 1" % id)


# The one number a catalogue entry's level ladder actually moves: its first effect key's
# value, or — for a dict-shaped entry (turbo/supercharger) — its first level-scaled
# sub-field from `scaled_subfields`.
func _leveled_scalar(id: String, level: int) -> float:
	var entry: Dictionary = BoostLibrary.CATALOGUE[id]
	var effect_key := String((entry["effect_fields"] as Dictionary).keys()[0])
	var value: Variant = BoostLibrary.magnitude_for(id, level)[effect_key]
	if value is Dictionary:
		return float((value as Dictionary)[String((entry["scaled_subfields"] as Array)[0])])
	return float(value)


# A dict-shaped entry's FIXED sub-fields (the part's spool character/drag — not named in
# `scaled_subfields`) must never move with the purchased level; only the one scaled
# sub-field does. Without this a "level" on a turbo would silently also change its spool
# behaviour, which no other boost's level does.
func test_an_induction_entrys_fixed_subfields_never_scale_with_level() -> void:
	Config.data.boost_level_magnitude_step = 0.3
	for id in BoostLibrary.CATALOGUE:
		var entry: Dictionary = BoostLibrary.CATALOGUE[id]
		for effect_key in (entry["effect_fields"] as Dictionary):
			var spec: Variant = (entry["effect_fields"] as Dictionary)[effect_key]
			if not (spec is Dictionary):
				continue
			var scaled: Array = entry.get("scaled_subfields", [])
			var lvl0: Dictionary = BoostLibrary.magnitude_for(id, 0)[effect_key]
			var lvl3: Dictionary = BoostLibrary.magnitude_for(id, 3)[effect_key]
			for sub_field in (spec as Dictionary):
				if scaled.has(sub_field):
					continue
				assert_eq(float(lvl0[sub_field]), float(lvl3[sub_field]),
					"'%s's fixed sub-field '%s' does not scale with level" % [id, sub_field])


# boost_for's effect dict is exactly what UpgradeLibrary.apply()'s install_induction arm
# splats onto a live config — every sub-key it names must be a real GameConfig field.
func test_an_induction_boosts_effect_dict_targets_real_config_fields() -> void:
	var cfg := GameConfig.new()
	for id in BoostLibrary.CATALOGUE:
		var entry: Dictionary = BoostLibrary.CATALOGUE[id]
		for effect_key in (entry["effect_fields"] as Dictionary):
			if not ((entry["effect_fields"] as Dictionary)[effect_key] is Dictionary):
				continue
			var sub: Dictionary = BoostLibrary.magnitude_for(id, 0)[effect_key]
			for target_field in sub:
				assert_true(String(target_field) in cfg,
					"'%s' installs %s, which does not exist on GameConfig" % [id, target_field])


# The sanity guard: however aggressively a designer sets the step (or however high the
# level climbs), the scale never crosses zero or flips the magnitude's sign — CLAUDE.md
# allows a guard against a truly broken value even though it forbids pinning a tuned one.
func test_level_scale_never_crosses_zero_however_extreme_the_step() -> void:
	Config.data.boost_level_magnitude_step = 5.0
	assert_gt(BoostLibrary.level_scale(50, -1), 0.0,
		"an extreme negative-direction climb still yields a positive scale")
	assert_gt(BoostLibrary.level_scale(50, 1), 0.0,
		"an extreme positive-direction climb still yields a positive scale")


# A "mult" (or "mult_floor" — same ratio semantics before any clamp; magnitude_for never
# applies the floor, only apply()/effective_meta() do) boost's base magnitude must push
# the SAME WAY its level ladder does: a lightweight kit whose mass_mult_floor sat above
# 1.0 would make the car heavier while its levels made it lighter. A relationship, not a
# pinned number — any sane tuning satisfies it, and a magnitude of exactly 1.0 (a boost
# that does nothing) is genuinely broken.
func test_a_multiplier_boosts_base_magnitude_pushes_the_way_its_levels_do() -> void:
	for id in BoostLibrary.CATALOGUE:
		var direction := int((BoostLibrary.CATALOGUE[id] as Dictionary).get("level_direction", 1))
		for effect_key in BoostLibrary.magnitude_for(id, 0):
			var desc: Dictionary = UpgradeLibrary.EFFECTS.get(effect_key, {})
			var op := String(desc.get("op", "mult"))
			if op != "mult" and op != "mult_floor":
				continue
			var magnitude := float(BoostLibrary.magnitude_for(id, 0)[effect_key])
			assert_ne(magnitude, 1.0, "'%s' actually changes %s" % [id, effect_key])
			if direction > 0:
				assert_gt(magnitude, 1.0,
					"'%s' raises %s, matching its +1 level_direction" % [id, effect_key])
			else:
				assert_lt(magnitude, 1.0,
					"'%s' lowers %s, matching its -1 level_direction" % [id, effect_key])


#
# region_run_mode.gd feeds this arbitrary ids — the boost catalogue's own ids plus a
# "drivetrain:<mode>" pseudo-id — so these tests deliberately use a synthetic pool
# rather than CATALOGUE.keys(), proving the function makes no assumption about what
# an id "means".

# --- label_for -------------------------------------------------------------------

func test_label_for_is_never_blank_for_a_real_id() -> void:
	for id in BoostLibrary.CATALOGUE:
		assert_false(BoostLibrary.label_for(id).is_empty(),
			"boost '%s' has no display label" % id)


func test_blurb_for_is_never_blank_for_a_real_id() -> void:
	for id in BoostLibrary.CATALOGUE.keys():
		assert_false(BoostLibrary.blurb_for(id).is_empty(), "%s has no blurb" % id)


func test_label_for_falls_back_to_the_id_when_unknown() -> void:
	assert_eq(BoostLibrary.label_for("ghost_boost"), "ghost_boost")


# Regression: picking the turbo/supercharger boost mid-run used to enable the physics
# (turbo_enabled/supercharger_enabled + a non-zero *_boost_gain) but leave the audio
# gain fields untouched, so a car whose stock engine authors zero gain for them (i.e.
# every non-turbo/non-blown catalogue engine) ran completely silent despite the part
# being genuinely fitted and doing real work. install_turbo/install_supercharger's
# effect dict must carry the audio gains too, and installing both — a real twincharger
# (features/forced-induction.md → "Turbo and supercharger STACK") — must leave both
# audible at once rather than one clobbering the other's gain.
func test_installing_turbo_and_supercharger_boosts_together_leaves_both_audible() -> void:
	var cfg := GameConfig.new()
	var owned_car := {"boosts": [{"id": "turbo", "effect": BoostLibrary.magnitude_for("turbo", 0)},
		{"id": "supercharger", "effect": BoostLibrary.magnitude_for("supercharger", 0)}]}
	UpgradeLibrary.apply(owned_car, cfg)
	assert_true(cfg.turbo_enabled)
	assert_true(cfg.supercharger_enabled)
	assert_gt(cfg.engine_turbo_whistle_gain, 0.0,
		"a mid-run turbo boost must give the whistle layer a real gain, not the stock engine's zero")
	assert_gt(cfg.engine_supercharger_whine_gain, 0.0,
		"a mid-run supercharger boost must give the whine layer a real gain, not the stock engine's zero")
