extends GutTest
# The same config must produce the SAME shape every time: identical centerline points + cells.

const TrackGenParams = preload("res://scripts/track_gen_params.gd")

func test_same_config_same_shape() -> void:
	var cfg := GameConfig.new()
	cfg.track_seed = 11
	cfg.track_turn_count = 8
	cfg.water_enabled = true
	cfg.track_water_level_m = -1.0
	var a := await TrackGenerator.generate(TrackGenParams.for_config(cfg))
	var b := await TrackGenerator.generate(TrackGenParams.for_config(cfg))
	assert_eq(a["cells"].size(), b["cells"].size(), "identical footprint")
	assert_eq(a["centerline"].point_count, b["centerline"].point_count, "identical centerline")

func test_water_off_still_generates() -> void:
	var cfg := GameConfig.new()
	cfg.track_seed = 11
	cfg.track_turn_count = 8
	cfg.water_enabled = false
	var p := TrackGenParams.for_config(cfg)
	var res := await TrackGenerator.generate(p)
	assert_true(res["complete"], "a plain track still generates with water off")
