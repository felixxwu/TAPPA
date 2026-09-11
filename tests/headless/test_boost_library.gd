extends GutTest
# BoostLibrary (scripts/boost_library.gd) — the in-run boost catalogue and its
# seeded draw (todo/roguelike-pivot.md -> "Upgrades — RR's two-tier model", stage 5
# of todo/roguelike-pivot-plan.md), plus the stage 6 meta-level scaling
# (magnitude_for / effect_for / current_effect_text).
#
# Per CLAUDE.md nothing here may pin a shipped magnitude (run_boost_mass_mult,
# boost_level_magnitude_step and friends are GameConfig tunables a designer retunes
# freely) — every assertion below is a CONTRACT: the draw is deterministic and
# repeat-free, every catalogue entry resolves to a real UpgradeLibrary effect,
# magnitude_for scales AWAY from the baseline in the direction a boost's own
# `level_direction` names, and effect_for reads the purchased level LIVE off Save
# rather than baking one in.

var _prev_boost_levels: Dictionary = {}


func before_each() -> void:
	Config.reset()
	# effect_for now reads Save.boost_level, so isolate each test from whatever level
	# another test file left behind (and restore it after, since Save is a shared
	# autoload rather than a fixture this file owns).
	_prev_boost_levels = (Save.profile.get(Save.KEY_BOOST_LEVELS, {}) as Dictionary).duplicate(true)
	Save.profile[Save.KEY_BOOST_LEVELS] = {}


func after_each() -> void:
	Config.reset()
	Save.profile[Save.KEY_BOOST_LEVELS] = _prev_boost_levels


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


# --- boost_for / effect_for: the shape the funnel reads --------------------------

func test_boost_for_returns_the_shape_active_effects_reads() -> void:
	var id: String = BoostLibrary.CATALOGUE.keys()[0]
	var b := BoostLibrary.boost_for(id)
	assert_eq(String(b.get("id", "")), id)
	assert_true(b.has("effect"))
	assert_false((b["effect"] as Dictionary).is_empty(), "a real id resolves a real effect")


func test_boost_for_is_empty_for_an_unknown_id() -> void:
	assert_eq(BoostLibrary.boost_for("not_a_real_boost"), {},
		"an unknown id degrades to nothing rather than erroring")


# THE relationship, not a magnitude: effect_for reads its value LIVE off Config.data,
# so retuning the field in the inspector changes the very next draw. Uses an
# arbitrary override, never the shipped default.
func test_effect_for_reads_its_magnitude_live_off_config() -> void:
	Config.data.run_boost_mass_mult = 0.42
	var effect: Dictionary = BoostLibrary.effect_for("lightweight")
	assert_eq(float(effect["mass_mult"]), 0.42,
		"the boost's magnitude is whatever GameConfig currently says, not a baked constant")


# --- The meta seam (stage 6): magnitude_for / effect_for / current_effect_text -----

# LEVEL 0 IS ALWAYS A NO-OP. Whatever step a designer authors, an id with no purchased
# level rolls the bare GameConfig magnitude unchanged — this is what keeps the test above
# (and every stage-5 boost-pick test) valid without knowing about levels at all.
func test_magnitude_for_at_level_zero_matches_the_unleveled_baseline() -> void:
	Config.data.boost_level_magnitude_step = 0.5  # an aggressive step, to prove 0 still no-ops
	for id in BoostLibrary.CATALOGUE:
		var baseline := BoostLibrary.magnitude_for(id, 0)
		var live := BoostLibrary.effect_for(id)  # Save has no purchased level in this test
		assert_eq(baseline, live,
			"'%s' at level 0 matches what effect_for resolves with nothing purchased" % id)


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
# value, or — for a dict-shaped entry (turbo/supercharger) — the sub-field named by
# `display_subfield`, the one sub-field `scaled_subfields` marks as level-scaled.
func _leveled_scalar(id: String, level: int) -> float:
	var entry: Dictionary = BoostLibrary.CATALOGUE[id]
	var effect_key := String((entry["effect_fields"] as Dictionary).keys()[0])
	var value: Variant = BoostLibrary.magnitude_for(id, level)[effect_key]
	if value is Dictionary:
		return float((value as Dictionary)[String(entry.get("display_subfield", ""))])
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
			var b := BoostLibrary.boost_for(id)
			var sub: Dictionary = (b["effect"] as Dictionary)[effect_key]
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


# effect_for is what BoostLibrary.draw actually hands to a live pick — this is the
# integration point: a level purchased on Save changes what the NEXT draw rolls.
func test_effect_for_scales_with_the_purchased_level_on_save() -> void:
	Config.data.boost_level_magnitude_step = 0.2
	Save.profile[Save.KEY_BOOST_LEVELS] = {"grip": 4}
	var levelled := BoostLibrary.effect_for("grip")
	var unlevelled := BoostLibrary.magnitude_for("grip", 0)
	assert_ne(levelled, unlevelled,
		"a purchased level changes what the next pick rolls for that boost")
	assert_eq(levelled, BoostLibrary.magnitude_for("grip", 4),
		"effect_for resolves exactly the level Save has on record")


# WHAT THE SHOP CARD SAYS A BOOST DOES. The figure is the boost's effect ON THE CAR at a
# given level, NOT how far that level pushed the magnitude — see current_effect_text's own
# header for why the latter is wrong (it renders every un-upgraded boost as "+0%", i.e. as
# doing nothing). So the contract at level 0 is the opposite of a no-op: the bare
# GameConfig magnitude still has to read as a real effect.
func test_current_effect_text_at_level_zero_still_reports_a_real_effect() -> void:
	Config.data.boost_level_magnitude_step = 0.3  # a level step must not be what makes it non-zero
	for id in BoostLibrary.CATALOGUE:
		var text := BoostLibrary.current_effect_text(id, 0)
		assert_ne(text, "", "'%s' at level 0 has something to say" % id)
		assert_ne(text, "+0%", "'%s' at level 0 does not claim to do nothing" % id)


# A "mult" boost's base magnitude must push the SAME WAY its level ladder does: a
# lightweight kit whose mass_mult sat above 1.0 would make the car heavier while its
# levels made it lighter. A relationship, not a pinned number — any sane tuning satisfies
# it, and a magnitude of exactly 1.0 (a boost that does nothing) is genuinely broken.
func test_a_multiplier_boosts_base_magnitude_pushes_the_way_its_levels_do() -> void:
	for id in BoostLibrary.CATALOGUE:
		var direction := int((BoostLibrary.CATALOGUE[id] as Dictionary).get("level_direction", 1))
		for effect_key in BoostLibrary.magnitude_for(id, 0):
			var desc: Dictionary = UpgradeLibrary.EFFECTS.get(effect_key, {})
			if String(desc.get("op", "mult")) != "mult":
				continue
			var magnitude := float(BoostLibrary.magnitude_for(id, 0)[effect_key])
			assert_ne(magnitude, 1.0, "'%s' actually changes %s" % [id, effect_key])
			if direction > 0:
				assert_gt(magnitude, 1.0,
					"'%s' raises %s, matching its +1 level_direction" % [id, effect_key])
			else:
				assert_lt(magnitude, 1.0,
					"'%s' lowers %s, matching its -1 level_direction" % [id, effect_key])


# A multiplier boost reads as a signed percentage, and the sign follows level_direction
# (which the test above pins to the magnitude's own side of 1.0).
func test_a_multiplier_boost_reads_as_a_signed_percentage() -> void:
	for id in BoostLibrary.CATALOGUE:
		if not _is_pure_mult(id):
			continue
		var direction := int((BoostLibrary.CATALOGUE[id] as Dictionary).get("level_direction", 1))
		var text := BoostLibrary.current_effect_text(id, 0)
		assert_true(text.ends_with("%"), "'%s' is expressed as a percentage" % id)
		if direction > 0:
			assert_true(text.begins_with("+"), "'%s' shows a '+' sign" % id)
		else:
			assert_true(text.begins_with("-"), "'%s' shows a '-' sign" % id)


# An "add" or "set" boost has no baseline to be a percentage OF (downforce stacks on the
# car's own; shift time replaces it), so it reports an absolute figure carrying the
# catalogue entry's authored unit instead — never a fabricated percentage. Induction
# entries (turbo/supercharger) are their OWN third shape — see the dedicated test below —
# so they're excluded here rather than made to satisfy "has a unit, no percentage".
func test_an_additive_or_set_boost_reads_as_an_absolute_figure_with_its_unit() -> void:
	var checked := 0
	for id in BoostLibrary.CATALOGUE:
		if _is_pure_mult(id) or _is_induction(id):
			continue
		var unit := String((BoostLibrary.CATALOGUE[id] as Dictionary).get("unit", ""))
		assert_ne(unit, "", "'%s' authors a display unit for its non-mult effect" % id)
		var text := BoostLibrary.current_effect_text(id, 0)
		assert_false(text.contains("%"),
			"'%s' does not invent a percentage it has no baseline for" % id)
		assert_true(text.ends_with(unit), "'%s' carries its unit (%s)" % [id, unit])
		checked += 1
	assert_gt(checked, 0, "the catalogue still has a non-mult entry for this to cover")


# A higher purchased level moves the reported figure — the level ladder has to be visible
# on the card, or buying a level tells the player nothing.
func test_current_effect_text_changes_with_the_purchased_level() -> void:
	Config.data.boost_level_magnitude_step = 0.1
	for id in BoostLibrary.CATALOGUE:
		assert_ne(BoostLibrary.current_effect_text(id, 1), BoostLibrary.current_effect_text(id, 3),
			"'%s' level 1 and level 3 read as different figures" % id)


# The aero kit drives BOTH axles off one GameConfig field, so the two effect keys resolve
# to the same number — the card shows that figure once, not twice.
func test_an_entry_driving_several_effect_keys_off_one_field_shows_one_figure() -> void:
	for id in BoostLibrary.CATALOGUE:
		var magnitude := BoostLibrary.magnitude_for(id, 0)
		if magnitude.size() < 2:
			continue
		var distinct := {}
		for effect_key in magnitude:
			distinct[float(magnitude[effect_key])] = true
		if distinct.size() > 1:
			continue  # genuinely different numbers SHOULD both be shown
		assert_false(BoostLibrary.current_effect_text(id, 0).contains("/"),
			"'%s' de-duplicates its identical per-key figures" % id)


func test_current_effect_text_is_blank_for_an_unknown_id() -> void:
	assert_eq(BoostLibrary.current_effect_text("not_a_real_boost", 2), "")


# current_effect_text_for reads Save.boost_level live, same integration contract as
# effect_for.
func test_current_effect_text_for_reads_the_purchased_level_on_save() -> void:
	Config.data.boost_level_magnitude_step = 0.2
	Save.profile[Save.KEY_BOOST_LEVELS] = {"grip": 3}
	assert_eq(BoostLibrary.current_effect_text_for("grip"), BoostLibrary.current_effect_text("grip", 3),
		"current_effect_text_for resolves exactly the level Save has on record")


func test_current_effect_text_for_falls_back_to_level_zero_when_never_purchased() -> void:
	assert_eq(BoostLibrary.current_effect_text_for("grip"), BoostLibrary.current_effect_text("grip", 0),
		"an un-upgraded boost (stored level 0, displayed as 'Lv 1') reports its base effect")


# True when every effect key a catalogue entry drives is a "mult" row — the entries whose
# figure is a percentage. Read off UpgradeLibrary.EFFECTS rather than hardcoded here, so a
# retyped or newly added row is classified correctly without editing this file.
func _is_pure_mult(id: String) -> bool:
	for effect_key in BoostLibrary.magnitude_for(id, 0):
		var desc: Dictionary = UpgradeLibrary.EFFECTS.get(effect_key, {})
		if String(desc.get("op", "mult")) != "mult":
			return false
	return true


# True for a dict-shaped entry (turbo/supercharger) — current_effect_text's third shape,
# neither a plain mult/add/set figure.
func _is_induction(id: String) -> bool:
	for effect_key in BoostLibrary.magnitude_for(id, 0):
		if BoostLibrary.magnitude_for(id, 0)[effect_key] is Dictionary:
			return true
	return false


# An induction boost's text is a signed percentage (its one scaled sub-field, the boost
# gain, as a swing) with its authored suffix — its own shape, distinct from both a mult
# entry's baseline-relative percentage and an add/set entry's absolute-with-unit figure.
func test_an_induction_boost_reads_as_a_signed_percentage_with_its_suffix() -> void:
	var checked := 0
	for id in BoostLibrary.CATALOGUE:
		if not _is_induction(id):
			continue
		var entry: Dictionary = BoostLibrary.CATALOGUE[id]
		var suffix := String(entry.get("display_suffix", ""))
		var text := BoostLibrary.current_effect_text(id, 0)
		assert_true(text.begins_with("+"), "'%s' shows a '+' sign" % id)
		assert_true(text.contains("%"), "'%s' is expressed as a percentage" % id)
		if not suffix.is_empty():
			assert_true(text.ends_with(suffix), "'%s' carries its display suffix" % id)
		checked += 1
	assert_gt(checked, 0, "the catalogue has an induction entry for this to cover")


# --- draw(): deterministic, repeat-free, real ids ---------------------------------

func test_the_draw_is_deterministic_in_its_seed() -> void:
	var a := BoostLibrary.draw(12345, 3)
	var b := BoostLibrary.draw(12345, 3)
	assert_eq(a, b, "the same seed draws the identical pick every time (resumable runs)")


func test_different_seeds_can_draw_different_picks() -> void:
	# Not guaranteed for every possible pair, but true for SOME seed within a small
	# search — if this never found one, the draw would not really be seeded at all.
	var first := BoostLibrary.draw(1, 3)
	var found_different := false
	for seed_value in range(2, 50):
		if BoostLibrary.draw(seed_value, 3) != first:
			found_different = true
			break
	assert_true(found_different, "different seeds are able to draw different picks")


func test_the_draw_never_repeats_a_boost_within_one_pick() -> void:
	var picked := BoostLibrary.draw(777, BoostLibrary.CATALOGUE.size())
	var seen: Dictionary = {}
	for entry in picked:
		var id := String((entry as Dictionary)["id"])
		assert_false(seen.has(id), "boost '%s' was drawn twice in one pick" % id)
		seen[id] = true


func test_the_draw_is_capped_at_the_catalogues_own_size() -> void:
	var picked := BoostLibrary.draw(1, BoostLibrary.CATALOGUE.size() + 50)
	assert_eq(picked.size(), BoostLibrary.CATALOGUE.size(),
		"asking for more than the catalogue holds never repeats to fill the count")


func test_every_drawn_entry_is_a_real_catalogue_boost() -> void:
	for entry in BoostLibrary.draw(999, 3):
		var id := String((entry as Dictionary)["id"])
		assert_true(BoostLibrary.CATALOGUE.has(id), "drawn id '%s' is a real entry" % id)


func test_a_zero_or_negative_count_draws_nothing() -> void:
	assert_eq(BoostLibrary.draw(1, 0), [])
	assert_eq(BoostLibrary.draw(1, -3), [])


# --- draw_from_ids(): the generic pool primitive draw() sits on ------------------
#
# region_run_mode.gd feeds this arbitrary ids — the boost catalogue's own ids plus a
# "drivetrain:<mode>" pseudo-id — so these tests deliberately use a synthetic pool
# rather than CATALOGUE.keys(), proving the function makes no assumption about what
# an id "means".

func test_draw_from_ids_is_deterministic_in_its_seed() -> void:
	var pool := ["a", "b", "c", "drivetrain:1"]
	var x := BoostLibrary.draw_from_ids(42, 2, pool)
	var y := BoostLibrary.draw_from_ids(42, 2, pool)
	assert_eq(x, y, "the same seed draws the identical ids every time")


func test_draw_from_ids_never_repeats_within_one_pick() -> void:
	var pool := ["a", "b", "c", "drivetrain:1"]
	var picked := BoostLibrary.draw_from_ids(5, pool.size(), pool)
	var seen: Dictionary = {}
	for id in picked:
		assert_false(seen.has(id), "id '%s' was drawn twice in one pick" % id)
		seen[id] = true


func test_draw_from_ids_is_capped_at_the_pools_own_size() -> void:
	var pool := ["a", "b", "drivetrain:1"]
	var picked := BoostLibrary.draw_from_ids(1, pool.size() + 50, pool)
	assert_eq(picked.size(), pool.size(),
		"asking for more than the pool holds never repeats to fill the count")


func test_draw_from_ids_returns_only_ids_from_the_given_pool() -> void:
	var pool := ["a", "b", "c", "drivetrain:1"]
	for id in BoostLibrary.draw_from_ids(77, 3, pool):
		assert_true(pool.has(id), "drawn id '%s' came from the given pool" % id)


func test_draw_from_ids_is_empty_for_an_empty_pool_or_non_positive_count() -> void:
	assert_eq(BoostLibrary.draw_from_ids(1, 3, []), [])
	assert_eq(BoostLibrary.draw_from_ids(1, 0, ["a", "b"]), [])
	assert_eq(BoostLibrary.draw_from_ids(1, -1, ["a", "b"]), [])


# --- label_for -------------------------------------------------------------------

func test_label_for_is_never_blank_for_a_real_id() -> void:
	for id in BoostLibrary.CATALOGUE:
		assert_false(BoostLibrary.label_for(id).is_empty(),
			"boost '%s' has no display label" % id)


func test_label_for_falls_back_to_the_id_when_unknown() -> void:
	assert_eq(BoostLibrary.label_for("ghost_boost"), "ghost_boost")


# --- category_of / resolve_id — the mid-run upgrade menu's seam ------------------

func test_every_catalogue_entry_has_a_real_category() -> void:
	for id in BoostLibrary.CATALOGUE:
		var category := BoostLibrary.category_of(id)
		assert_true(category == "power" or category == "handling",
			"'%s' has a real category, not '%s'" % [id, category])


func test_category_of_classifies_the_pseudo_id_families() -> void:
	assert_eq(BoostLibrary.category_of("drivetrain:1"), "handling")
	assert_eq(BoostLibrary.category_of("engine_swap:fx_v8"), "power")


func test_category_of_is_blank_for_an_unknown_id() -> void:
	assert_eq(BoostLibrary.category_of("not_a_real_boost"), "")


func test_resolve_id_matches_boost_for_for_a_catalogue_id() -> void:
	var id: String = BoostLibrary.CATALOGUE.keys()[0]
	assert_eq(BoostLibrary.resolve_id(id), BoostLibrary.boost_for(id))


func test_resolve_id_resolves_a_drivetrain_pseudo_id() -> void:
	assert_eq(BoostLibrary.resolve_id("drivetrain:2"), {"id": "drivetrain:2", "drivetrain_mode": 2})


func test_resolve_id_resolves_an_engine_swap_pseudo_id() -> void:
	assert_eq(BoostLibrary.resolve_id("engine_swap:fx_v8"),
		{"id": "engine_swap:fx_v8", "engine_id": "fx_v8"})


func test_resolve_id_is_empty_for_an_unknown_id() -> void:
	assert_eq(BoostLibrary.resolve_id("not_a_real_boost"), {})
