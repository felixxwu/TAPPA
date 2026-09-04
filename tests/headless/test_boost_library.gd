extends GutTest
# BoostLibrary (scripts/boost_library.gd) — the in-run boost catalogue and its
# seeded draw (todo/roguelike-pivot.md -> "Upgrades — RR's two-tier model", stage 5
# of todo/roguelike-pivot-plan.md). Pure logic, no scene, no Save.
#
# Per CLAUDE.md nothing here may pin a shipped magnitude (run_boost_mass_mult and
# friends are GameConfig tunables a designer retunes freely) — every assertion below
# is a CONTRACT: the draw is deterministic and repeat-free, every catalogue entry
# resolves to a real UpgradeLibrary effect, and effect_for reads its value LIVE off
# Config.data rather than baking one in.


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
