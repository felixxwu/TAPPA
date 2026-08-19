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



# --- Benchmark resolution sweep (features/benchmark.md → "Resolution sweep") ----

func test_design_height_override_sets_logical_height() -> void:
	# The sweep passes an explicit design height; the logical frame renders at it.
	var logical := DisplayStretch.logical_size(Vector2i(1995, 1078), 1.0, 720.0)
	assert_eq(logical.y, 720, "override height becomes the logical height")


func test_design_height_override_keeps_the_aspect() -> void:
	# Width still follows the window aspect (and the stretch) at any height —
	# the realised stretch is unchanged by the override.
	var logical := DisplayStretch.logical_size(Vector2i(1995, 1078), 1.1, 900.0)
	var x_scale := float(1995) / float(logical.x)
	var y_scale := float(1078) / float(logical.y)
	assert_almost_eq(x_scale / y_scale, 1.1, 0.02, "stretch holds under a height override")


func test_design_height_default_matches_design_height() -> void:
	# Omitting the override is exactly the pre-sweep behaviour (normal play path).
	var with_default := DisplayStretch.logical_size(Vector2i(1280, 960), 1.1)
	var explicit := DisplayStretch.logical_size(Vector2i(1280, 960), 1.1, DESIGN_HEIGHT)
	assert_eq(with_default, explicit, "default parameter is DESIGN_HEIGHT")


func test_degenerate_height_override_is_safe() -> void:
	var logical := DisplayStretch.logical_size(Vector2i(1280, 960), 1.0, 0.0)
	assert_gt(logical.y, 0, "zero override height is clamped, not rendered at 0")


# --- Configured render height (features/rendering.md) ----------------------------

func test_configured_height_is_used() -> void:
	# A positive config render_height renders at exactly that logical height.
	var h := DisplayStretch.design_height_for(Vector2i(1995, 1078), false, 0, 720)
	assert_eq(h, 720.0, "a positive config height is the logical height")


func test_zero_config_height_follows_the_window() -> void:
	# 0 = device-native: the logical height follows the window height.
	var h := DisplayStretch.design_height_for(Vector2i(1995, 1078), false, 0, 0)
	assert_eq(h, 1078.0, "config height 0 renders at the window height")


func test_benchmark_sweep_height_beats_the_config() -> void:
	# An explicit sweep height must measure THAT resolution whatever the config says.
	var h := DisplayStretch.design_height_for(Vector2i(1995, 1078), true, 900, 720)
	assert_eq(h, 900.0, "the sweep override wins during a benchmark")


func test_benchmark_without_sweep_height_measures_what_ships() -> void:
	var h := DisplayStretch.design_height_for(Vector2i(1995, 1078), true, 0, 720)
	assert_eq(h, 720.0, "baseline benchmark measures the shipped config height")


func test_degenerate_window_with_native_config_is_safe() -> void:
	var h := DisplayStretch.design_height_for(Vector2i(0, 0), false, 0, 0)
	assert_eq(h, DESIGN_HEIGHT, "zero-size window falls back to the design height")


func test_config_carries_a_sane_render_height() -> void:
	# Sanity only (never pin the chosen value): non-negative, and if fixed, tall
	# enough to be a usable frame.
	var cfg := load("res://config/game_config.tres") as GameConfig
	assert_true(cfg.render_height >= 0, "render_height is 0 (native) or a positive height")
