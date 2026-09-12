extends GutTest
# StageFields (scripts/stage_fields.gd) — pure (Dictionary) -> value field readers.
# Logic tests only: synthetic dicts, never a real region's authored stage
# (CLAUDE.md bans depending on a specific catalogue entry).

func test_event_width_defaults_and_overrides() -> void:
	assert_eq(StageFields.event_width({}), StageFields.DEFAULT_WIDTH, "default width")
	assert_eq(StageFields.event_width({"width": 8.5}), 8.5, "override width")


func test_event_forestiness_defaults_and_clamps() -> void:
	assert_eq(StageFields.event_forestiness({}), 1.0, "default forestiness is fully wooded")
	assert_eq(StageFields.event_forestiness({"forestiness": 2.0}), 1.0, "clamped above 1")
	assert_eq(StageFields.event_forestiness({"forestiness": -1.0}), 0.0, "clamped below 0")


func test_event_tarmac_fraction_defaults_and_clamps() -> void:
	assert_eq(StageFields.event_tarmac_fraction({}), 0.0, "default is all gravel")
	assert_eq(StageFields.event_tarmac_fraction({"surface_mix": 0.5}), 0.5)


func test_event_straightness_defaults_and_clamps() -> void:
	assert_eq(StageFields.event_straightness({}), 0.0, "default straightness")
	assert_eq(StageFields.event_straightness({"straightness": 1.5}), 1.0, "clamped above 1")


func test_event_cliffiness_defaults_and_clamps() -> void:
	assert_eq(StageFields.event_cliffiness({}), 0.0, "default is flat")
	assert_eq(StageFields.event_cliffiness({"cliffiness": 0.4}), 0.4)


func test_event_weather_defaults_and_tolerates_unknown_strings() -> void:
	assert_eq(StageFields.event_weather({}), StageFields.WEATHER_DRY, "omitted weather is dry")
	assert_eq(StageFields.event_weather({"weather": "not_a_real_condition"}), StageFields.WEATHER_DRY,
		"an unrecognised string falls back to dry rather than crashing")
	assert_eq(StageFields.event_weather({"weather": StageFields.WEATHER_RAIN}), StageFields.WEATHER_RAIN)


func test_event_is_wet_recognises_every_wet_condition_not_just_rain() -> void:
	assert_false(StageFields.event_is_wet({"weather": StageFields.WEATHER_DRY}))
	assert_true(StageFields.event_is_wet({"weather": StageFields.WEATHER_RAIN}))
	assert_true(StageFields.event_is_wet({"weather": StageFields.WEATHER_STORM}),
		"storm is wetter than rain and must count as wet too")
