extends GutTest
# The Water config group exists with sane defaults and a disabled-by-default guard.
# Values themselves are tunable — we only assert the fields exist and that water is
# off by default so existing events are unaffected.

func test_water_defaults_off() -> void:
	var cfg := GameConfig.new()
	assert_false(cfg.water_enabled, "water is off by default so existing events are unaffected")
	assert_true("track_water_level_m" in cfg, "has a water level field")
	assert_gt(cfg.water_shore_clearance_m, 0.0, "positive shore clearance")
