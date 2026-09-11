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


# --- Stage-based hilliness/curviness (StageConfig.stage_scale + apply_event_config) --
# LOGIC only, per CLAUDE.md: no assertion here may fail if the authored
# stage_hilliness_scale_*/stage_curviness_scale_* values in game_config.tres were
# retuned to another reasonable setting — everything is built on synthetic min/max.

func test_stage_scale_interpolates_linearly_between_synthetic_min_and_max() -> void:
	assert_almost_eq(StageConfig.stage_scale(0, 8, 1.0, 2.0), 1.0, 0.0001,
		"first stage lands on min_v")
	assert_almost_eq(StageConfig.stage_scale(7, 8, 1.0, 2.0), 2.0, 0.0001,
		"last stage lands on max_v")
	var mid := StageConfig.stage_scale(3, 8, 1.0, 2.0)
	assert_true(mid > 1.0 and mid < 2.0, "a middle stage lands strictly between min_v and max_v")
	# Monotonic across the whole range, for any reasonable min/max including a
	# DECREASING one (a designer could author max_v < min_v).
	for min_v in [0.0, 1.0, 0.5]:
		for max_v in [1.0, 2.5, 0.2]:
			var prev := StageConfig.stage_scale(0, 8, min_v, max_v)
			for i in range(1, 8):
				var cur := StageConfig.stage_scale(i, 8, min_v, max_v)
				if max_v >= min_v:
					assert_true(cur >= prev - 0.0001,
						"scale is non-decreasing stage over stage when max_v >= min_v")
				else:
					assert_true(cur <= prev + 0.0001,
						"scale is non-increasing stage over stage when max_v < min_v")
				prev = cur


func test_stage_scale_clamps_out_of_range_indices() -> void:
	assert_almost_eq(StageConfig.stage_scale(-3, 8, 1.0, 2.0), 1.0, 0.0001,
		"a negative index clamps to min_v")
	assert_almost_eq(StageConfig.stage_scale(99, 8, 1.0, 2.0), 2.0, 0.0001,
		"an index past the end clamps to max_v")


func test_stage_scale_with_one_stage_is_always_min_v() -> void:
	assert_almost_eq(StageConfig.stage_scale(0, 1, 1.0, 2.0), 1.0, 0.0001,
		"a single-stage run has nothing to interpolate across, so it's pinned to min_v")


func test_negative_stage_index_leaves_terrain_and_straightness_unscaled() -> void:
	var cfg := GameConfig.new()
	StageConfig.apply_event_config(cfg, {
		"terrain_layer1_amplitude": 20.0, "straightness": 0.5,
	})  # stage_index defaults to -1
	assert_eq(cfg.terrain_layer1_amplitude, 20.0,
		"no run stage known -> hilliness scale is not applied")
	assert_eq(cfg.track_straightness, 0.5,
		"no run stage known -> curviness scale is not applied")


func test_later_stage_is_hillier_and_curvier_than_an_earlier_stage_for_any_scale_config() -> void:
	# apply_event_config always reads the authored .tres fresh (`load(Config.CONFIG_PATH)`),
	# not a caller-supplied config, so exercising a non-identity scale means
	# temporarily retuning the cached authored resource itself (Godot's resource
	# cache returns the SAME instance for the same path) — saved and restored
	# below, and deliberately NOT the shipped values (CLAUDE.md: never pin a
	# tunable), just some min < max on both axes to prove the relationship.
	var base: GameConfig = load(Config.CONFIG_PATH)
	var saved := {
		"hmin": base.stage_hilliness_scale_min, "hmax": base.stage_hilliness_scale_max,
		"cmin": base.stage_curviness_scale_min, "cmax": base.stage_curviness_scale_max,
	}
	base.stage_hilliness_scale_min = 0.8
	base.stage_hilliness_scale_max = 1.6
	base.stage_curviness_scale_min = 1.0
	base.stage_curviness_scale_max = 1.8

	var event := {"terrain_layer1_amplitude": 20.0, "terrain_layer2_amplitude": 4.0,
		"terrain_layer3_amplitude": 2.0, "straightness": 0.6}

	var first := GameConfig.new()
	StageConfig.apply_event_config(first, event, 0, 8)
	var last := GameConfig.new()
	StageConfig.apply_event_config(last, event, 7, 8)

	base.stage_hilliness_scale_min = saved["hmin"]
	base.stage_hilliness_scale_max = saved["hmax"]
	base.stage_curviness_scale_min = saved["cmin"]
	base.stage_curviness_scale_max = saved["cmax"]

	assert_true(last.terrain_layer1_amplitude > first.terrain_layer1_amplitude,
		"stage 8 is hillier than stage 1 (layer 1)")
	assert_true(last.terrain_layer2_amplitude > first.terrain_layer2_amplitude,
		"stage 8 is hillier than stage 1 (layer 2)")
	assert_true(last.terrain_layer3_amplitude > first.terrain_layer3_amplitude,
		"stage 8 is hillier than stage 1 (layer 3)")
	assert_true(last.track_straightness < first.track_straightness,
		"stage 8 is curvier (lower straightness) than stage 1")
	assert_true(last.track_straightness >= 0.0 and last.track_straightness <= 1.0,
		"straightness stays clamped to [0, 1] even after the curviness scale")
