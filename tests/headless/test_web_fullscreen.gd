extends GutTest
# WebFullscreen autoload (features/mobile-controls.md → "Web fullscreen +
# landscape"): the orientation predicate that decides when the "tap to play"
# prompt shows and when a fullscreen request is allowed. Pure logic — the overlay
# / DisplayServer side is web-runtime only and not headless-testable.


func test_taller_than_wide_is_portrait() -> void:
	assert_true(WebFullscreen.is_portrait(Vector2i(400, 800)), "phone held upright")


func test_wider_than_tall_is_not_portrait() -> void:
	assert_false(WebFullscreen.is_portrait(Vector2i(800, 400)), "landscape needs no prompt")


func test_square_counts_as_landscape() -> void:
	# The boundary: a square viewport must NOT prompt, so we never re-request
	# fullscreen (which would flip an already-fine layout to portrait).
	assert_false(WebFullscreen.is_portrait(Vector2i(500, 500)), "square is not portrait")


func test_autoload_is_inert_off_web() -> void:
	# In the headless test runner OS.has_feature("web") is false, so the autoload
	# must have disabled its per-frame polling and never built an overlay.
	assert_false(WebFullscreen.is_processing(), "polling off when not a web build")
	assert_null(WebFullscreen._layer, "no overlay created off the web build")
