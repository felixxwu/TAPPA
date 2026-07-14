extends GutTest

# DisplayStretch applies a constant, device-independent horizontal stretch to the
# whole frame by shrinking only the logical WIDTH the window scales back out from.

const DisplayStretch := preload("res://scripts/display_stretch.gd")
const DESIGN_HEIGHT := 400.0


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
