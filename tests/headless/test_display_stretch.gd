extends GutTest

# DisplayStretch applies a constant, device-independent horizontal stretch to the
# whole frame by shrinking only the logical WIDTH the window scales back out from.

const DisplayStretch := preload("res://scripts/display_stretch.gd")
const DESIGN_HEIGHT := DisplayStretch.DESIGN_HEIGHT


# The realised stretch = (horizontal scale-to-window) / (vertical scale-to-window).
func _realised_stretch(window_size: Vector2i, stretch: float) -> float:
	var logical := DisplayStretch.logical_size(window_size, stretch)
	var x_scale := float(window_size.x) / float(logical.x)
	var y_scale := float(window_size.y) / float(logical.y)
	return x_scale / y_scale


func test_stretches_horizontal_by_the_factor() -> void:
	# Same 1.1x widening regardless of device aspect (rounding tolerance only).
	for window_size in [Vector2i(1280, 960), Vector2i(1920, 1080), Vector2i(800, 600), Vector2i(2400, 1080)]:
		assert_almost_eq(_realised_stretch(window_size, 1.1), 1.1, 0.02,
			"1.1x stretch on window %s" % window_size)


func test_height_is_never_distorted() -> void:
	# Vertical must stay 1:1 with the design height — the stretch is horizontal only.
	var logical := DisplayStretch.logical_size(Vector2i(1280, 960), 1.1)
	assert_eq(logical.y, int(DESIGN_HEIGHT), "logical height stays the design height")


func test_factor_one_is_a_no_op() -> void:
	assert_almost_eq(_realised_stretch(Vector2i(1280, 960), 1.0), 1.0, 0.01,
		"a 1.0 factor leaves the frame undistorted")


func test_wider_devices_still_reveal_more_width() -> void:
	# Wider windows get a wider logical frame (more world shown), not just more stretch.
	var narrow := DisplayStretch.logical_size(Vector2i(800, 600), 1.1)
	var wide := DisplayStretch.logical_size(Vector2i(2400, 600), 1.1)
	assert_gt(wide.x, narrow.x, "a wider window exposes a wider logical frame")


func test_degenerate_inputs_are_safe() -> void:
	# Zero height / zero factor must not divide-by-zero or produce a zero width.
	var zero_h := DisplayStretch.logical_size(Vector2i(1280, 0), 1.1)
	assert_gt(zero_h.x, 0, "zero window height yields a safe non-zero width")
	var zero_factor := DisplayStretch.logical_size(Vector2i(1280, 960), 0.0)
	assert_gt(zero_factor.x, 0, "zero stretch factor is clamped, not divided by")


func test_config_carries_the_authored_stretch() -> void:
	var cfg := load("res://config/game_config.tres") as GameConfig
	assert_gt(cfg.horizontal_stretch, 0.0, "horizontal_stretch is a positive factor")


# --- Benchmark landscape override (features/benchmark.md) -----------------------

func test_benchmark_swaps_portrait_to_landscape() -> void:
	# A portrait window during a benchmark renders at the landscape resolution, so
	# the GPU/fill cost is representative instead of ~1/4 size.
	assert_eq(DisplayStretch.benchmark_window_size(Vector2i(400, 900), true), Vector2i(900, 400),
		"portrait window is swapped to landscape while benchmarking")


func test_benchmark_leaves_landscape_untouched() -> void:
	assert_eq(DisplayStretch.benchmark_window_size(Vector2i(900, 400), true), Vector2i(900, 400),
		"an already-landscape window is unchanged")


func test_non_benchmark_never_swaps() -> void:
	# Normal play always uses the real window orientation (portrait stays portrait).
	assert_eq(DisplayStretch.benchmark_window_size(Vector2i(400, 900), false), Vector2i(400, 900),
		"outside a benchmark the real window size is used")


# --- Mobile-web render resolution tier (todo/mobile-web-performance.md §3.2) ------
# The rendered frame height is driven by DisplayStretch.DESIGN_HEIGHT, seeded from
# [display] window/size/viewport_height and then lowered for the web-TOUCH tier only.
# These assert the BRANCH, never the chosen numbers (both are tunables).

const BASE_HEIGHT := 360


func _tier_cfg() -> GameConfig:
	# Synthetic config: a base height and a deliberately different low-tier height, so
	# the branch is observable without depending on the authored values.
	var cfg := GameConfig.new()
	cfg.viewport_height_web_touch = 200
	cfg.virtual_resolution = Vector2(480, 360)
	return cfg


func test_web_touch_takes_the_low_resolution_tier() -> void:
	var cfg := _tier_cfg()
	assert_eq(cfg.viewport_height_for(true, true, BASE_HEIGHT), cfg.viewport_height_web_touch,
		"a web TOUCH device renders at the low-tier height")


func test_every_other_target_keeps_the_base_height() -> void:
	# The constraint that matters: only (web AND touch) is tiered down.
	var cfg := _tier_cfg()
	assert_eq(cfg.viewport_height_for(false, false, BASE_HEIGHT), BASE_HEIGHT,
		"desktop keeps the authored height")
	assert_eq(cfg.viewport_height_for(true, false, BASE_HEIGHT), BASE_HEIGHT,
		"a DESKTOP browser keeps the authored height")
	assert_eq(cfg.viewport_height_for(false, true, BASE_HEIGHT), BASE_HEIGHT,
		"native mobile keeps the authored height")


func test_low_tier_is_not_higher_than_the_base() -> void:
	# Sanity guard only: the tier is a reduction, never an upscale.
	var cfg := load("res://config/game_config.tres") as GameConfig
	assert_lte(cfg.viewport_height_web_touch, int(DisplayStretch.base_design_height()),
		"the web-touch height never exceeds the authored base height")
	assert_gt(cfg.viewport_height_web_touch, 0, "the web-touch height is positive")


func test_virtual_resolution_stays_in_proportion() -> void:
	var cfg := _tier_cfg()
	var height := cfg.viewport_height_for(true, true, BASE_HEIGHT)
	var scaled := cfg.virtual_resolution_for(true, true, BASE_HEIGHT)
	var ratio := float(height) / float(BASE_HEIGHT)
	assert_almost_eq(scaled.x, cfg.virtual_resolution.x * ratio, 1.0,
		"the post-process grid width scales with the render height")
	assert_almost_eq(scaled.y, cfg.virtual_resolution.y * ratio, 1.0,
		"the post-process grid height scales with the render height")
	# ...and the grid's own aspect is preserved, so the dither pattern keeps its shape.
	assert_almost_eq(scaled.x / scaled.y,
		cfg.virtual_resolution.x / cfg.virtual_resolution.y, 0.02,
		"the post-process grid keeps its authored aspect")


func test_virtual_resolution_untouched_off_the_low_tier() -> void:
	var cfg := _tier_cfg()
	for target in [[false, false], [true, false], [false, true]]:
		assert_eq(cfg.virtual_resolution_for(target[0], target[1], BASE_HEIGHT),
			cfg.virtual_resolution,
			"post-process grid unchanged for web=%s touch=%s" % [target[0], target[1]])


func test_zero_base_height_is_safe() -> void:
	var cfg := _tier_cfg()
	assert_eq(cfg.virtual_resolution_for(true, true, 0), cfg.virtual_resolution,
		"a degenerate base height falls back to the authored grid rather than dividing by zero")
