extends GutTest
# The weather table (WeatherLibrary): the single source of truth for what each
# weather condition IS — which GameConfig fields it reads and which structural
# features it has. See features/weather.md.
#
# Structure and relations only. No test here pins a TUNED value (a grip multiplier,
# a colour, a particle count) and none depends on a particular authored condition
# beyond `dry`, which is load-bearing structure: it is the fallback every unknown
# string resolves to, and its multiplier is the identity.


func after_each() -> void:
	WeatherLibrary.reset()


# --- by_id tolerance ---------------------------------------------------------

func test_by_id_falls_back_to_the_dry_entry_for_an_unknown_id() -> void:
	# A typo'd authored string, an id from an older build, or a condition removed
	# from the table must degrade to a plain dry stage rather than an empty dict
	# every consumer would then have to guard. Mirrors RallyLibrary.event_weather.
	var dry := WeatherLibrary.by_id(WeatherLibrary.DEFAULT_ID)
	assert_eq(String(dry.get("id", "")), WeatherLibrary.DEFAULT_ID, "the dry entry exists")
	assert_eq(WeatherLibrary.by_id("no_such_condition"), dry, "unknown id -> the dry entry")
	assert_eq(WeatherLibrary.by_id(""), dry, "empty id -> the dry entry")


func test_dry_grip_multiplier_is_exactly_one() -> void:
	# STRUCTURAL, not a tuning choice: dry being the identity is what lets
	# Drivetrain.surface_tire_params and LapTimeModel._surface_grip multiply
	# unconditionally, with no per-condition branch anywhere. If dry ever gained a
	# multiplier those call sites would silently start scaling a dry stage.
	var cfg := GameConfig.new()
	assert_eq(WeatherLibrary.grip_mult(cfg, WeatherLibrary.DEFAULT_ID), 1.0,
		"dry does not scale grip")
	assert_eq(WeatherLibrary.grip_mult(cfg, "no_such_condition"), 1.0,
		"an unknown condition resolves to dry, so it does not scale grip either")


func test_dry_constructs_nothing() -> void:
	# The zero-cost contract: dry names no look block, no road tint and no particle
	# kind, so world.gd._apply_weather_look writes nothing and builds nothing on a
	# dry stage. This is a hard requirement on the low-end phones the game targets.
	var dry := WeatherLibrary.by_id(WeatherLibrary.DEFAULT_ID)
	assert_true((dry.get("look", {}) as Dictionary).is_empty(), "dry authors no look block")
	assert_true((dry.get("road_tint", {}) as Dictionary).is_empty(), "dry tints no road")
	assert_eq(String(dry.get("particles", "")), "", "dry spawns no particle field")
	assert_eq(WeatherLibrary.headlight_amount(GameConfig.new(), WeatherLibrary.DEFAULT_ID), 0.0,
		"and switches no headlights on")


func test_headlight_amount_reads_the_config_field_the_entry_names() -> void:
	# Same contract as grip_mult: the entry NAMES a field, the value lives in the
	# config. A condition naming none is exactly 0 — lights off — which is what makes
	# the cone a bit-for-bit no-op in the shaders rather than something to branch on.
	WeatherLibrary.override_for_test([
		{"id": "dry"},
		{"id": "murk", "headlights": "storm_headlight_amount"},
	] as Array[Dictionary])
	var cfg := GameConfig.new()
	cfg.storm_headlight_amount = 0.4
	assert_almost_eq(WeatherLibrary.headlight_amount(cfg, "murk"), 0.4, 0.001,
		"the strength comes from the named config field")
	assert_eq(WeatherLibrary.headlight_amount(cfg, "dry"), 0.0,
		"a condition naming no field runs with the lights off")
	cfg.storm_headlight_amount = 3.0
	assert_eq(WeatherLibrary.headlight_amount(cfg, "murk"), 1.0,
		"and an over-bright value clamps rather than blowing the light term out")


# --- the config-field contract -----------------------------------------------

func test_grip_mult_reads_the_config_field_the_entry_names() -> void:
	# Synthetic table, synthetic field: the point is that the entry NAMES a
	# GameConfig field and the value is read from the config, not stored here.
	WeatherLibrary.override_for_test([
		{"id": "dry"},
		{"id": "drizzle", "grip_mult": "rain_grip_mult"},
	] as Array[Dictionary])
	var cfg := GameConfig.new()
	cfg.rain_grip_mult = 0.5
	assert_eq(WeatherLibrary.grip_mult(cfg, "drizzle"), 0.5,
		"the multiplier comes from the named config field")


func test_config_fields_lists_every_field_an_entry_references() -> void:
	# fingerprint() folds these in, so a key that is not reported here would be a
	# tuning knob no cache invalidation ever sees.
	var fields := WeatherLibrary.config_fields({
		"id": "synthetic",
		"grip_mult": "g", "particles": "rain", "particle_count": "c", "wind_dir": "w",
		"look": {
			"background_color": "bg", "sky_color": "sky", "sun_energy_mult": "sun",
			"fog_density_mult": "fd", "fog_sky_affect": "fs",
		},
		"road_tint": {"amount": "rt", "color": "rc"},
		"headlights": "hl",
	})
	for expected in ["g", "c", "w", "bg", "sky", "sun", "fd", "fs", "rt", "rc", "hl"]:
		assert_true(fields.has(expected), "%s is reported as a config field" % expected)
	assert_false(fields.has("rain"), "the particle KIND is not a config field")


func test_config_fields_is_empty_for_a_featureless_entry() -> void:
	assert_eq(WeatherLibrary.config_fields({"id": "dry"}), [],
		"an entry with no features references no config")


# --- the cache fingerprint ---------------------------------------------------

func test_fingerprint_changes_when_the_table_changes() -> void:
	# Adding a condition must change the fingerprint automatically — this is the property
	# that replaced hand-listing each grip field by name (forgetting one meant a weather
	# change that moved lap times went unnoticed).
	var cfg := GameConfig.new()
	WeatherLibrary.override_for_test([{"id": "dry"}] as Array[Dictionary])
	var before := WeatherLibrary.fingerprint(cfg)
	WeatherLibrary.override_for_test([
		{"id": "dry"},
		{"id": "drizzle", "grip_mult": "rain_grip_mult"},
	] as Array[Dictionary])
	assert_ne(WeatherLibrary.fingerprint(cfg), before, "a new condition moves the fingerprint")


func test_fingerprint_changes_when_a_referenced_config_value_is_retuned() -> void:
	# Retuning a value the table POINTS AT must re-key too, not just editing the
	# table itself.
	WeatherLibrary.override_for_test([
		{"id": "dry"},
		{"id": "drizzle", "grip_mult": "rain_grip_mult"},
	] as Array[Dictionary])
	var cfg := GameConfig.new()
	cfg.rain_grip_mult = 0.9
	var before := WeatherLibrary.fingerprint(cfg)
	cfg.rain_grip_mult = 0.5
	assert_ne(WeatherLibrary.fingerprint(cfg), before, "a retune re-keys the field")


func test_fingerprint_is_stable_for_unchanged_inputs() -> void:
	var cfg := GameConfig.new()
	assert_eq(WeatherLibrary.fingerprint(cfg), WeatherLibrary.fingerprint(cfg),
		"the same table + config hashes the same")


# --- visibility-only conditions (fog's shape) --------------------------------

func test_a_visibility_only_condition_has_no_grip_no_particles_and_no_road_tint() -> void:
	# Fog's SHAPE, asserted against a synthetic table so no shipped colour or
	# multiplier is pinned: a condition may author a look block ALONE. That single
	# fact is what makes it a pure visibility condition —
	#   * no "grip_mult"  => grip_mult() is exactly 1.0, identical to dry, so neither
	#     the player's tyres nor LapTimeModel's rival field is touched;
	#   * no "particles"  => world.gd builds no WeatherField at all (the case the
	#     table was generalised for — it costs no new code);
	#   * no "road_tint"  => the road albedo is left alone, unlike a precipitation
	#     condition, which is correct because a foggy road is DRY.
	# The precipitation sibling in the same table is the contrast: it authors all
	# three, so this asserts a RELATION between two shapes, not any value.
	WeatherLibrary.override_for_test([
		{"id": "dry"},
		{
			"id": "haze",
			"look": {
				"background_color": "mist_background_color", "sky_color": "mist_sky_color",
				"sun_energy_mult": "mist_sun_energy_mult",
				"fog_density_mult": "mist_fog_density_mult",
				"fog_sky_affect": "mist_fog_sky_affect",
			},
		},
		{
			"id": "squall", "grip_mult": "rain_grip_mult", "particles": "rain",
			"particle_count": "rain_particle_count",
			"road_tint": {"amount": "rain_road_darken"},
		},
	] as Array[Dictionary])
	var cfg := GameConfig.new()
	var haze := WeatherLibrary.by_id("haze")
	var squall := WeatherLibrary.by_id("squall")
	assert_false((haze.get("look", {}) as Dictionary).is_empty(),
		"a visibility condition does author a look")
	assert_eq(WeatherLibrary.grip_mult(cfg, "haze"), 1.0,
		"a visibility-only condition does not scale grip — exactly dry")
	assert_eq(String(haze.get("particles", "")), "", "it constructs no particle field")
	assert_true((haze.get("road_tint", {}) as Dictionary).is_empty(),
		"it does not tint the road")
	# The contrast, in the same table: precipitation does all three.
	assert_lt(WeatherLibrary.grip_mult(cfg, "squall"), 1.0, "precipitation does scale grip")
	assert_ne(String(squall.get("particles", "")), "", "precipitation constructs a field")
	assert_false((squall.get("road_tint", {}) as Dictionary).is_empty(),
		"precipitation does tint the road")


# --- wind and lightning blocks -----------------------------------------------

func test_only_time_affecting_values_enter_the_physics_fingerprint() -> void:
	# THE RULE: a weather value belongs in the physics fingerprint if and only if it can
	# change how fast the stage is driven — the grip multiplier and the wind force.
	# Everything else (particle counts, every look colour, the road tint, the lightning
	# flash) is LOOK. config_fields() still reports the entry's FULL surface;
	# physics_fields() is the narrow set the fingerprint uses.
	var entry := {
		"id": "synthetic", "grip_mult": "g", "particles": "rain", "particle_count": "c",
		"look": {"background_color": "bg", "sky_color": "sky", "sun_energy_mult": "sun",
			"fog_density_mult": "fd", "fog_sky_affect": "fs"},
		"road_tint": {"amount": "rt", "color": "rc"},
		"wind": {"strength": "ws", "gust": "wg", "dir_deg": "wd"},
		"lightning": {"flash": "lf", "duration": "ld", "interval_min": "li",
			"interval_max": "lx"},
	}
	var physics := WeatherLibrary.physics_fields(entry)
	for expected in ["g", "ws", "wg", "wd"]:
		assert_true(physics.has(expected), "%s can change a lap time, so it is folded in" % expected)
	for cosmetic in ["c", "bg", "sky", "sun", "fd", "fs", "rt", "rc", "lf", "ld", "li", "lx"]:
		assert_false(physics.has(cosmetic), "%s is look only, so it is left out" % cosmetic)
		assert_true(WeatherLibrary.config_fields(entry).has(cosmetic),
			"%s is still reported as a field the entry references" % cosmetic)


func test_a_cosmetic_retune_does_not_move_the_physics_fingerprint() -> void:
	# The consequence of the rule above, asserted end-to-end through the hash: nudging a
	# colour must NOT move the fingerprint, while changing a value that alters lap times
	# must. Relations only — no colour or multiplier value
	# is pinned, and both are set to arbitrary distinct values here.
	WeatherLibrary.override_for_test([
		{"id": "dry"},
		{"id": "drizzle", "grip_mult": "rain_grip_mult",
			"look": {"background_color": "rain_background_color", "sky_color": "rain_sky_color",
				"sun_energy_mult": "rain_sun_energy_mult",
				"fog_density_mult": "rain_fog_density_mult",
				"fog_sky_affect": "rain_fog_sky_affect"}},
	] as Array[Dictionary])
	var cfg := GameConfig.new()
	var before := WeatherLibrary.fingerprint(cfg)
	cfg.rain_background_color = Color(0.1, 0.2, 0.3)
	assert_eq(WeatherLibrary.fingerprint(cfg), before, "a look retune moves nothing")
	cfg.rain_grip_mult = cfg.rain_grip_mult * 0.5
	assert_ne(WeatherLibrary.fingerprint(cfg), before, "a grip retune re-keys the field")


func test_config_fields_reports_a_shared_field_once() -> void:
	# One entry may legitimately point two keys at the same config field (a wind
	# heading shared by the particles and the body force, so the drops stream the way
	# the car is pushed). config_fields is a SET of referenced fields, not a bag.
	var entry := {
		"id": "synthetic", "particles": "rain", "wind_dir": "shared_heading",
		"wind": {"strength": "ws", "gust": "wg", "dir_deg": "shared_heading"},
	}
	assert_eq(WeatherLibrary.config_fields(entry).count("shared_heading"), 1,
		"a shared field is listed once")
	assert_eq(WeatherLibrary.physics_fields(entry).count("shared_heading"), 1,
		"and once in the narrower physics set too")


func test_a_wind_block_names_only_config_fields_that_exist() -> void:
	# The contract between the table and the crosswind force: every field a "wind"
	# block names must be a real GameConfig property, or the force silently reads
	# null. Checked over the SHIPPED table as opaque input (no entry is named, no
	# value asserted) — the same style as the roster invariants elsewhere.
	var cfg := GameConfig.new()
	for entry in WeatherLibrary.all():
		var wind: Dictionary = entry.get("wind", {})
		for key in WeatherLibrary.WIND_KEYS:
			if wind.has(key):
				assert_true(cfg.get(String(wind[key])) != null,
					"%s names a real GameConfig field" % String(wind[key]))
		var lightning: Dictionary = entry.get("lightning", {})
		for key in WeatherLibrary.LIGHTNING_KEYS:
			if lightning.has(key):
				assert_true(cfg.get(String(lightning[key])) != null,
					"%s names a real GameConfig field" % String(lightning[key]))


# --- Wetness classification --------------------------------------------------

# THE guard that makes is_wet a real seam rather than a helper that rots: the eighth
# weather condition must be CLASSIFIED, not silently defaulted.
#
# WHY IT MATTERS: WETNESS is a separate dict from the entries, precisely because an
# omitted entry KEY legitimately means "does not have that feature" — so an unclassified
# condition would read as dry with nothing to notice it. Adding a condition to CONDITIONS
# without a WETNESS row fails HERE, at the table, instead of showing up months later as a
# wet-road rule that quietly does nothing on the new condition.
#
# Pins no tunable and no design call: the subject list is DERIVED from the library, and
# nothing here asserts WHICH ids are wet — only that each one is answered. A designer may
# flip any classification, or add a condition wet or dry, and this stays green.
func test_every_condition_is_classified_wet_or_dry() -> void:
	assert_gt(WeatherLibrary.all().size(), 0, "the table is non-empty (else this asserts nothing)")
	var unclassified: Array = []
	for entry in WeatherLibrary.all():
		var id := String(entry.get("id", ""))
		assert_ne(id, "", "every condition declares an id")
		if not WeatherLibrary.WETNESS.has(id):
			unclassified.append(id)
	assert_eq(unclassified, [],
		"every WeatherLibrary condition has a WETNESS row (add yours: \"<id>\": true/false)")


func test_wetness_never_classifies_a_condition_that_does_not_exist() -> void:
	# The other direction: a stale row for a removed/renamed condition is dead weight that
	# makes the table look more complete than it is. Derived from the library, so it holds
	# for any roster.
	var ids: Array = []
	for entry in WeatherLibrary.all():
		ids.append(String(entry.get("id", "")))
	var orphans: Array = []
	for id in WeatherLibrary.WETNESS.keys():
		if not ids.has(String(id)):
			orphans.append(String(id))
	assert_eq(orphans, [], "no WETNESS row names a condition the table does not declare")


func test_is_wet_tolerates_unknown_ids_and_agrees_with_wet_ids() -> void:
	# Contract, not classification. An unknown id resolves through by_id's dry fallback
	# like every other query here, so a typo'd authored string can never make a stage wet.
	# And wet_ids() is derived from is_wet, so the set form and the per-id form are one
	# answer — a caller cannot get two different pictures of the same table.
	assert_false(WeatherLibrary.is_wet("no_such_condition"), "an unknown id is not wet")
	assert_false(WeatherLibrary.is_wet(""), "an empty id is not wet")
	assert_false(WeatherLibrary.is_wet(WeatherLibrary.DEFAULT_ID),
		"the dry fallback condition is not wet (structural: it is the absence of every feature)")
	var wet: Array = WeatherLibrary.wet_ids()
	for entry in WeatherLibrary.all():
		var id := String(entry.get("id", ""))
		assert_eq(WeatherLibrary.is_wet(id), wet.has(id),
			"wet_ids() and is_wet() agree about '%s'" % id)


func test_a_condition_installed_for_a_test_is_not_wet_by_accident() -> void:
	# The override seam must not inherit a classification from a same-named shipped id by
	# luck: an id nothing classifies is dry, which is the safe direction.
	WeatherLibrary.override_for_test([{"id": "dry"}, {"id": "synthetic_condition"}] as Array[Dictionary])
	assert_false(WeatherLibrary.is_wet("synthetic_condition"), "an unclassified condition is dry")
	assert_eq(WeatherLibrary.wet_ids(), [], "and contributes nothing to the wet set")
