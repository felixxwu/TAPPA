extends GutTest
# LevelWeather: the deterministic drift, rain turning to snow, the fade finishing, and the Dev button on Hafren.

var _pool: String


func before_each() -> void:
	_pool = Config.data.level_weather_pool


func after_each() -> void:
	Config.data.level_weather_pool = _pool
	LevelWeather.reset()


func test_draw_is_deterministic_per_seed_and_slot() -> void:
	for slot in 20:
		assert_eq(LevelWeather.draw("dry:1,rain:1,fog:1,storm:1,night:1", 7, slot), LevelWeather.draw("dry:1,rain:1,fog:1,storm:1,night:1", 7, slot))


func test_draw_only_returns_pool_members() -> void:
	for slot in 40:
		assert_true(["dry", "night"].has(LevelWeather.draw("dry:3,night:1", 3, slot)))


func test_empty_pool_falls_back_to_the_default_weather() -> void:
	assert_eq(LevelWeather.draw("", 1, 0), WeatherLibrary.DEFAULT_ID)


func test_rain_becomes_snow_only_inside_the_snow_biome() -> void:
	assert_eq(LevelWeather.resolve("rain", 1.0), WeatherLibrary.WEATHER_SNOW)
	assert_eq(LevelWeather.resolve("rain", 0.0), "rain")
	assert_eq(LevelWeather.resolve("fog", 1.0), "fog")


func _node(snow: float) -> LevelWeather:
	var node := LevelWeather.new()
	node.view = LevelView.new()
	add_child_autofree(node.view)
	add_child_autofree(node)
	node.snow_fn = func() -> float: return snow
	return node


func test_a_fade_reaches_its_target_and_stops() -> void:
	var node := _node(0.0)
	node._show("night", false)
	assert_true(node.is_fading())
	node._step(Config.data.level_weather_fade_s + 1.0)
	assert_false(node.is_fading())
	assert_eq(node._light, node._look_light("night"))
	node._show("dry", true)
	assert_eq(node._light, 1.0)


func test_dev_button_cycles_through_auto_and_the_pool() -> void:
	Config.data.level_weather_pool = "dry:1,fog:1"
	var node := _node(0.0)
	node.name = "LevelWeather"
	var ids: Array = [""] + node.pool_ids()
	assert_eq(ids, ["", "dry", "fog"])


func test_a_look_thickens_the_fog_by_pulling_its_far_end_in() -> void:
	var holder := WorldEnvironment.new()
	holder.name = "WorldEnvironment"
	holder.environment = Environment.new()
	add_child_autofree(holder)
	var node := _node(0.0)
	node.start()
	var entry: Dictionary = WeatherLibrary.CONDITIONS.filter(func(e: Dictionary) -> bool: return e.get("look", {}).has("fog_density_mult"))[0]
	node._show(String(entry["id"]), true)
	var mult := float(Config.data.get(String(entry["look"]["fog_density_mult"])))
	assert_almost_eq(holder.environment.fog_depth_end * mult, Config.data.level_fog_end_m, 0.01)


func test_the_headlights_switch_only_late_in_the_fade() -> void:
	var lit: Dictionary = WeatherLibrary.CONDITIONS.filter(func(e: Dictionary) -> bool: return e.has("headlights"))[0]
	var node := _node(0.0)
	node._show(WeatherLibrary.DEFAULT_ID, true)
	node._show(String(lit["id"]), false)
	assert_false(HeadlightCone.has_headlights(Config.data), "lights stay off as the weather starts to turn")
	node._step(Config.data.level_weather_fade_s * 0.5)
	assert_false(HeadlightCone.has_headlights(Config.data), "still off halfway through")
	node._step(Config.data.level_weather_fade_s)
	assert_true(HeadlightCone.has_headlights(Config.data), "on once the weather has turned")
	LevelWeather.reset()
	Config.data.weather = WeatherLibrary.DEFAULT_ID
