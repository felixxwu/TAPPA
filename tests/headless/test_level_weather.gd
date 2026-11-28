extends GutTest
# LevelWeather: the deterministic drift, rain turning to snow, the fade finishing, and the Dev button on Hafren.

var _pool: String


func before_each() -> void:
	_pool = Config.data.level_weather_pool


func after_each() -> void:
	Config.data.level_weather_pool = _pool
	LevelWeather.reset()
	WeatherLibrary.reset()
	LevelWeather.forced_weather = ""
	LevelWeather.drive_time = 0.0


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
	var density0 := holder.environment.fog_density
	node._show(String(entry["id"]), true)
	var mult := float(Config.data.get(String(entry["look"]["fog_density_mult"])))
	assert_almost_eq(holder.environment.fog_depth_end * mult, Config.data.level_fog_end_m, 0.01)
	assert_eq(holder.environment.fog_density, density0, "not by raising the density, which over-brightens depth fog past its colour")


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


func test_a_later_slot_never_repeats_the_weather_before_it() -> void:
	for seed in 20:
		var prev := LevelWeather.draw("dry:4,rain:1,fog:1", seed, 0, "dry")
		for slot in range(1, 8):
			var now := LevelWeather.draw("dry:4,rain:1,fog:1", seed, slot, "dry")
			assert_ne(now, prev, "seed %d slot %d repeated %s" % [seed, slot, now])
			prev = now


func test_the_weather_clock_survives_a_level_reload() -> void:
	LevelWeather.drive_time = Config.data.level_weather_hold_s * 2.5
	var node := _node(0.0)
	node.start()
	assert_eq(node._shown, LevelWeather.draw(Config.data.level_weather_pool, LevelWeather.seed_value, 2, Config.data.level_weather))


func test_a_pool_drops_unknown_conditions_and_empty_weights() -> void:
	WeatherLibrary.override_for_test([{"id": "dry"}, {"id": "rain"}, {"id": "fog"}] as Array[Dictionary])
	assert_eq(LevelWeather.parse_pool("dry:2, nonsense:5, rain:0, fog"), [["dry", 2.0], ["fog", 1.0]])


func test_the_target_look_keeps_the_scenes_colour_and_lays_the_weathers_overcast_on_top() -> void:
	var cfg: GameConfig = Config.data
	var base_env := {"bg": Color.BLACK, "fog": Color.BLACK, "density": 0.01, "sky_affect": 0.1}
	WeatherLibrary.override_for_test([{"id": "dry"}, {"id": "murk", "look": {
		"background_color": "mist_background_color",
		"sun_energy_mult": "mist_sun_energy_mult",
		"fog_density_mult": "mist_fog_density_mult",
		"fog_sky_affect": "mist_fog_sky_affect"}}] as Array[Dictionary])
	assert_eq(LevelWeather.target_look(cfg, "dry", base_env)["bg"], Color.BLACK, "a weather with no look keeps the scene's")
	var murk_look: Dictionary = WeatherLibrary.by_id("murk")["look"]
	var wet := LevelWeather.target_look(cfg, "murk", base_env)
	assert_eq(wet["bg"], cfg.get(String(murk_look["background_color"])))
	assert_almost_eq(float(wet["density"]), 0.01 * float(cfg.get(String(murk_look["fog_density_mult"]))), 1e-6)
