extends GutTest
# The Water config group exists with sane values. Whether water is on is a tunable, so it isn't asserted.

func test_water_config_fields_exist() -> void:
	var cfg := GameConfig.new()
	assert_true("water_enabled" in cfg, "has the water toggle")
	assert_true("track_water_level_m" in cfg, "has a water level field")
	assert_gt(cfg.water_shore_clearance_m, 0.0, "positive shore clearance")
