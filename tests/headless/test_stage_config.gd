extends GutTest
# StageConfig (scripts/stage_config.gd): the canonical writer that turns a stage/event
# dict into a GameConfig — the one place an authored (or rolled) stage's track
# parameters reach the config the world is generated from. Extracted from
# RallySession (now deleted, todo/roguelike-pivot.md decision 5), which owned it only
# by accident of history: it is pure, scene-free and session-free, and every kind of
# run (Rally Challenge, benchmark, the offline track-cache tools, and career rallies
# while they existed) goes through it. This is the ONLY coverage of that seam, moved
# here verbatim rather than lost when its former host was deleted.
#
# These test the OVERRIDE/FALLBACK LOGIC, not any authored value: a synthetic event
# dict flows into the config, and omitted keys resolve to the pristine baseline —
# never to a value a prior event left on the shared session config.


func before_each() -> void:
	Config.reset()


func after_each() -> void:
	Config.reset()


# --- Per-event config application (StageConfig.apply_event_config) ------------

func test_event_terrain_override_flows_into_config() -> void:
	var cfg := GameConfig.new()
	StageConfig.apply_event_config(cfg, {
		"terrain_layer1_wavelength": 123.0, "terrain_layer1_amplitude": 45.0,
		"terrain_layer3_amplitude": 6.0, "water_level": -20.0,
	})
	assert_eq(cfg.terrain_layer1_wavelength, 123.0, "layer1 wavelength override applied")
	assert_eq(cfg.terrain_layer1_amplitude, 45.0, "layer1 amplitude override applied")
	assert_eq(cfg.terrain_layer3_amplitude, 6.0, "layer3 amplitude override applied")
	assert_eq(cfg.track_water_level_m, -20.0, "water_level override applied")


func test_omitted_keys_fall_back_to_authored_baseline_not_prior_event() -> void:
	var base: GameConfig = load(Config.CONFIG_PATH)
	var cfg := GameConfig.new()
	# Event A overrides two fields on the shared config...
	StageConfig.apply_event_config(cfg, {
		"terrain_layer2_wavelength": 999.0, "water_level": -30.0,
	})
	assert_eq(cfg.terrain_layer2_wavelength, 999.0, "event A override took effect")
	# ...event B omits them and must NOT inherit A's values — it gets the baseline.
	StageConfig.apply_event_config(cfg, {})
	assert_eq(cfg.terrain_layer2_wavelength, base.terrain_layer2_wavelength,
		"omitted terrain key resolves to the authored baseline, not event A's override")
	assert_eq(cfg.track_water_level_m, base.track_water_level_m,
		"omitted water_level resolves to the authored baseline, not event A's override")


func test_apply_event_config_carries_weather_and_defaults_to_dry() -> void:
	var cfg := GameConfig.new()
	StageConfig.apply_event_config(cfg, {"weather": "rain"})
	assert_eq(cfg.weather, RallyLibrary.WEATHER_RAIN, "rain event seats rain onto the config")
	# An event with no weather key at all leaves the config dry.
	StageConfig.apply_event_config(cfg, {})
	assert_eq(cfg.weather, RallyLibrary.WEATHER_DRY, "omitted weather key resolves to dry")


# --- Waterline resolution: event -> region -> GameConfig baseline --------------
# Order is the whole contract (CLAUDE.md: never pin the shipped -12/-5/-10
# values). Synthetic regions via the Registry.Seam only.

func test_apply_event_config_event_water_level_beats_its_region() -> void:
	RegionLibrary.override_for_test([{"id": "fx_region", "water_level": -99.0}])
	var cfg := GameConfig.new()
	StageConfig.apply_event_config(cfg, {"water_level": -1.0, "region": "fx_region"})
	assert_almost_eq(cfg.track_water_level_m, -1.0, 0.0001,
		"event's own water_level wins over its region")
	RegionLibrary.reset()

func test_apply_event_config_inherits_region_when_event_authors_none() -> void:
	RegionLibrary.override_for_test([{"id": "fx_region", "water_level": -99.0}])
	var cfg := GameConfig.new()
	StageConfig.apply_event_config(cfg, {"region": "fx_region"})
	assert_almost_eq(cfg.track_water_level_m, -99.0, 0.0001,
		"an event that authors no water_level inherits its region's")
	RegionLibrary.reset()

func test_apply_event_config_falls_back_to_baseline_with_no_region_context() -> void:
	var base: GameConfig = load(Config.CONFIG_PATH)
	var cfg := GameConfig.new()
	# The challenge / free-roam / dev-page shape: no "region" key at all.
	StageConfig.apply_event_config(cfg, {})
	assert_eq(cfg.track_water_level_m, base.track_water_level_m,
		"no region tag and no event override -> GameConfig baseline")
