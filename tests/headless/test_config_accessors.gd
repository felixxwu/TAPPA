extends GutTest
# Covers scripts/config.gd's Config.get_float / Config.get_bool — the ONE shared field
# accessor that replaced five divergent local `_cfg_float`/`_cfg_bool` copies (see
# features/configuration.md). This file pins the CONTRACT only: an existing field
# returns its authored value (never a specific value — that's a tunable a designer may
# retune) and an absent field returns the caller's fallback. It deliberately asserts NO
# tunable VALUE from game_config.tres.


func after_each() -> void:
	Config.reset()  # undo any per-test mutation of Config.data


func test_get_float_returns_authored_value_for_existing_field() -> void:
	# road_tile_per_meter exists on every GameConfig and is never null-valued (it's a
	# plain @export float) — mutate it to a value chosen by THIS TEST, not the
	# catalogue, so the assertion doesn't pin an authored number.
	Config.data.road_tile_per_meter = 3.5
	assert_eq(Config.get_float("road_tile_per_meter", -1.0), 3.5,
		"an existing field returns the live authored value, not the fallback")


func test_get_float_returns_fallback_for_missing_field() -> void:
	assert_eq(Config.get_float("this_field_does_not_exist_xyz", 7.25), 7.25,
		"a field that isn't declared on GameConfig resolves to the caller's fallback")


func test_get_bool_returns_authored_value_for_existing_field() -> void:
	Config.data.ai_adapt_enabled = false
	assert_eq(Config.get_bool("ai_adapt_enabled", true), false,
		"an existing bool field returns the live authored value, not the fallback")


func test_get_bool_returns_fallback_for_missing_field() -> void:
	assert_eq(Config.get_bool("this_field_does_not_exist_xyz", true), true,
		"a field that isn't declared on GameConfig resolves to the caller's fallback")


func test_get_float_returns_fallback_when_data_is_null() -> void:
	# Defensive path: a bare/off-tree caller with no Config.data yet must not crash.
	var saved := Config.data
	Config.data = null
	assert_eq(Config.get_float("road_tile_per_meter", 42.0), 42.0,
		"a null Config.data falls back rather than erroring")
	Config.data = saved
