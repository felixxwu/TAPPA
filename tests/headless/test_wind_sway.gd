extends GutTest
# Tree wind sway (scripts/wind_sway.gd, shaders/wind_sway.gdshaderinc). See
# features/trees.md and features/weather.md.
#
# BEHAVIOUR ONLY. Nothing here pins an authored strength, speed or heading — a
# designer retuning foliage_wind_strength or storm_foliage_wind_strength in the
# inspector must not break a single assertion. What IS pinned is the structure that
# has to hold for any values: an entry naming no "foliage_wind" falls back to the
# shared base, one that names a field gets THAT field instead, and the heading
# conversion matches the one the particle wind and the crosswind force already use.


func after_each() -> void:
	WeatherLibrary.reset()


func _install_synthetic_table(strength_field: String) -> void:
	var conditions: Array[Dictionary] = [
		{"id": "dry"},
		{"id": "gusty", "foliage_wind": strength_field},
	]
	WeatherLibrary.override_for_test(conditions)


func test_a_condition_naming_no_foliage_wind_gets_the_base_strength() -> void:
	_install_synthetic_table("storm_foliage_wind_strength")
	var cfg := GameConfig.new()
	cfg.foliage_wind_strength = 0.06
	cfg.storm_foliage_wind_strength = 0.5
	assert_almost_eq(WindSway.strength(cfg, "dry"), 0.06, 0.0001,
		"a condition naming no foliage_wind field falls back to the shared base")


func test_a_condition_naming_a_foliage_wind_field_gets_that_value_instead() -> void:
	_install_synthetic_table("storm_foliage_wind_strength")
	var cfg := GameConfig.new()
	cfg.foliage_wind_strength = 0.06
	cfg.storm_foliage_wind_strength = 0.5
	assert_almost_eq(WindSway.strength(cfg, "gusty"), 0.5, 0.0001,
		"a condition naming a field reads THAT field, not the base")


func test_an_unknown_condition_falls_back_to_the_dry_base() -> void:
	_install_synthetic_table("storm_foliage_wind_strength")
	var cfg := GameConfig.new()
	cfg.foliage_wind_strength = 0.06
	assert_almost_eq(WindSway.strength(cfg, "typo'd-id"), 0.06, 0.0001,
		"WeatherLibrary.by_id's dry fallback means an unknown id is just the base")


func test_direction_deg_prefers_the_conditions_own_heading() -> void:
	var conditions: Array[Dictionary] = [
		{"id": "dry"},
		{"id": "windy", "wind_dir": "storm_wind_dir_deg"},
	]
	WeatherLibrary.override_for_test(conditions)
	var cfg := GameConfig.new()
	cfg.foliage_wind_dir_deg = 10.0
	cfg.storm_wind_dir_deg = 250.0
	assert_almost_eq(WindSway.direction_deg(cfg, "dry"), 10.0, 0.0001,
		"a condition naming no heading falls back to the shared base")
	assert_almost_eq(WindSway.direction_deg(cfg, "windy"), 250.0, 0.0001,
		"a condition naming a heading uses THAT field, not the base")


func test_params_direction_is_a_unit_vector_matching_the_particle_convention() -> void:
	var cfg := GameConfig.new()
	cfg.foliage_wind_dir_deg = 90.0
	var dir: Vector3 = WindSway.params(cfg, "dry")[WindSway.G_DIR]
	assert_almost_eq(dir.length(), 1.0, 0.0001, "the pushed heading is a unit vector")
	# 90 degrees == world +Z, the same convention Crosswind.direction (used by the
	# storm body force) and the particle wind_dir conversion in world.gd both use.
	assert_almost_eq(dir.x, 0.0, 0.001, "90 degrees points along +Z, not +X")
	assert_almost_eq(dir.z, 1.0, 0.001, "90 degrees points along +Z")
	assert_eq(dir, Crosswind.direction(90.0), "matches the shared heading conversion exactly")


func test_strength_with_a_null_config_is_zero() -> void:
	assert_eq(WindSway.strength(null, "dry"), 0.0, "no config -> no sway, not a crash")


func test_params_with_a_null_config_is_still() -> void:
	var vals := WindSway.params(null, "dry")
	assert_eq(vals[WindSway.G_STRENGTH], 0.0, "no config -> zero strength, not a crash")


func test_config_fields_includes_foliage_wind_and_physics_fields_does_not() -> void:
	var entry := {"id": "synthetic", "foliage_wind": "storm_foliage_wind_strength"}
	assert_true(WeatherLibrary.config_fields(entry).has("storm_foliage_wind_strength"),
		"foliage_wind is reported as a field the entry references")
	assert_false(WeatherLibrary.physics_fields(entry).has("storm_foliage_wind_strength"),
		"foliage_wind is purely cosmetic, so it must not re-key the opponent cache")
