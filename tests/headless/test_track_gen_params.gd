extends GutTest
# TrackGenParams is the single shape contract. You cannot obtain params without a
# water level, and for_config is deterministic (same cfg -> same params). The
# dry-start search moves the origin off water and stays deterministic.

const TrackGenParams = preload("res://scripts/track_gen_params.gd")

func _cfg() -> GameConfig:
	var c := GameConfig.new()
	c.track_seed = 7
	c.track_turn_count = 8
	c.track_width = 6.0
	c.water_enabled = true
	c.track_water_level_m = -0.5
	return c

func test_for_config_reads_seed_and_water() -> void:
	var p := TrackGenParams.for_config(_cfg())
	assert_eq(p.seed, 7, "seed from cfg")
	assert_true(p.water_enabled, "water enabled from cfg")
	assert_almost_eq(p.water_level, -0.5, 0.0001, "water level from cfg")
	assert_true(p.water_sampler.is_valid(), "sampler is built")

func test_for_config_deterministic() -> void:
	var a := TrackGenParams.for_config(_cfg())
	var b := TrackGenParams.for_config(_cfg())
	assert_eq(a.seed, b.seed)
	assert_eq(a.origin, b.origin, "same origin")
	assert_almost_eq(a.water_sampler.call(5.0, 5.0), b.water_sampler.call(5.0, 5.0), 0.0001,
		"same sampler output")

func test_dry_start_moves_off_water() -> void:
	# Water covers a disc around nominal origin; the search must find dry ground.
	var cfg := GameConfig.new()
	cfg.track_seed = 5
	cfg.water_enabled = true
	cfg.track_water_level_m = 0.0
	cfg.water_shore_clearance_m = 0.5
	var p := TrackGenParams.for_config(cfg)
	p.water_enabled = true
	p.water_level = 0.0
	# Override sampler: underwater within 20m of nominal origin, dry beyond.
	p.water_sampler = func(x: float, z: float) -> float:
		return -10.0 if Vector2(x, z).length() < 20.0 else 10.0
	p.recompute_origin()
	assert_true(p.water_sampler.call(p.origin.x, p.origin.y) >= p.water_level + p.shore_clearance
		or not p.water_enabled,
		"start origin is on dry ground (or water disabled by fallback)")

func test_dry_start_deterministic() -> void:
	var cfg := GameConfig.new()
	cfg.track_seed = 5
	cfg.water_enabled = true
	cfg.track_water_level_m = 0.0
	var a := TrackGenParams.for_config(cfg)
	var b := TrackGenParams.for_config(cfg)
	assert_eq(a.origin, b.origin, "same (seed, water_level) -> same origin")
