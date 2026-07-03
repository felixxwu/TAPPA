extends GutTest
# Logic tests for UITheme's shared time formatter. These pin FORMAT behaviour
# (the "m:ss.cc" shape, minutes rollover, the negative "no time" sentinel), not
# any tunable value.


func test_format_time_basic() -> void:
	# 1:23.21 — sub-minute fraction is zero-padded to two integer digits.
	assert_eq(UITheme.format_time(83210), "1:23.21")


func test_format_time_zero() -> void:
	assert_eq(UITheme.format_time(0), "0:00.00")


func test_format_time_minutes_rollover() -> void:
	# 65_000 ms = 1:05.00 (minutes carry, seconds wrap within the minute).
	assert_eq(UITheme.format_time(65000), "1:05.00")


func test_format_time_negative_default_sentinel() -> void:
	assert_eq(UITheme.format_time(-1), "--:--")


func test_format_time_negative_custom_sentinel() -> void:
	assert_eq(UITheme.format_time(-1, "—"), "—")
