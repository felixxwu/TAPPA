extends GutTest
# Snowfall: a weather look on the level's snow biome, never a second grip lever over it.

func test_the_snowfall_condition_carries_no_grip_multiplier() -> void:
	# LevelView.set_snow already sets grip from the snow under the car; a weather
	# multiplier on top would be two levers over one variable.
	var cfg: GameConfig = GameConfig.new()
	assert_eq(WeatherLibrary.grip_mult(cfg, WeatherLibrary.WEATHER_SNOW), 1.0,
		"snowfall does not touch grip")
	var entry := WeatherLibrary.by_id(WeatherLibrary.WEATHER_SNOW)
	assert_eq(String(entry.get("id", "")), WeatherLibrary.WEATHER_SNOW,
		"setup: the snow condition is a real entry, not the dry fallback")
