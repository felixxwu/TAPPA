extends GutTest
# BoostLibrary (scripts/boost_library.gd) — the in-run boost catalogue and its
# seeded draw (todo/roguelike-pivot.md -> "Upgrades — RR's two-tier model", stage 5
# of todo/roguelike-pivot-plan.md), plus the stage 6 meta-level scaling
# (magnitude_for / effect_for / effect_range_text).
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
# trap (_cfg_set refuses a write to a field that doesn't exist).
func test_every_catalogue_cfg_field_is_a_real_config_property() -> void:
	var cfg := GameConfig.new()
	for id in BoostLibrary.CATALOGUE:
		var entry: Dictionary = BoostLibrary.CATALOGUE[id]
		for cfg_field in (entry["effect_fields"] as Dictionary).values():
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


# --- The meta seam (stage 6): magnitude_for / effect_for / effect_range_text -----

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
		var field: String = (BoostLibrary.CATALOGUE[id]["effect_fields"] as Dictionary).keys()[0]
		var lvl0 := float(BoostLibrary.magnitude_for(id, 0)[field])
		var lvl1 := float(BoostLibrary.magnitude_for(id, 1)[field])
		var lvl3 := float(BoostLibrary.magnitude_for(id, 3)[field])
		if direction > 0:
			assert_gt(lvl1, lvl0, "'%s' level 1 rolls higher than level 0" % id)
			assert_gt(lvl3, lvl1, "'%s' level 3 rolls higher still than level 1" % id)
		else:
			assert_lt(lvl1, lvl0, "'%s' level 1 rolls lower than level 0" % id)
			assert_lt(lvl3, lvl1, "'%s' level 3 rolls lower still than level 1" % id)


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


func test_effect_range_text_is_never_blank_for_a_real_id() -> void:
	for id in BoostLibrary.CATALOGUE:
		assert_false(BoostLibrary.effect_range_text(id).is_empty(),
			"boost '%s' has no effect range text" % id)


func test_effect_range_text_is_blank_for_an_unknown_id() -> void:
	assert_eq(BoostLibrary.effect_range_text("not_a_real_boost"), "")


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


# --- label_for -------------------------------------------------------------------

func test_label_for_is_never_blank_for_a_real_id() -> void:
	for id in BoostLibrary.CATALOGUE:
		assert_false(BoostLibrary.label_for(id).is_empty(),
			"boost '%s' has no display label" % id)


func test_label_for_falls_back_to_the_id_when_unknown() -> void:
	assert_eq(BoostLibrary.label_for("ghost_boost"), "ghost_boost")
