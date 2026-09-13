extends GutTest
# Pure-logic coverage for MenuShowcaseCache — no terrain, no track generation.
# See test_menu_showcase.gd for the integration coverage of _build() actually
# consuming the committed cache (built once in before_all there).


func test_version_tag_is_deterministic_for_the_same_config() -> void:
	var a := MenuShowcaseCache.version_tag_for(Config.data)
	var b := MenuShowcaseCache.version_tag_for(Config.data)
	assert_eq(a, b, "the same config produces the same fingerprint every time")
	assert_true(a.begins_with(MenuShowcaseCache.CACHE_VERSION + ":"),
		"starts with the manual version segment")


func test_is_valid_accepts_a_matching_version_tag() -> void:
	var cache := MenuShowcaseCache.new()
	cache.version_tag = MenuShowcaseCache.version_tag_for(Config.data)
	assert_true(MenuShowcaseCache.is_valid(cache, Config.data))


func test_is_valid_rejects_a_stale_version_tag() -> void:
	var cache := MenuShowcaseCache.new()
	cache.version_tag = "stale:does:not:match"
	assert_false(MenuShowcaseCache.is_valid(cache, Config.data))


func test_is_valid_rejects_null() -> void:
	assert_false(MenuShowcaseCache.is_valid(null, Config.data))


func test_load_if_valid_returns_null_when_the_committed_file_is_absent() -> void:
	# Doesn't assume the committed cache exists in this checkout (e.g. a fresh
	# clone before ./cache_menu_showcase.sh has ever run) — only that a missing
	# file is a clean miss, never an error.
	if not FileAccess.file_exists(MenuShowcaseCache.CACHE_PATH):
		assert_null(MenuShowcaseCache.load_if_valid(Config.data))
	else:
		pass_test("committed cache is present in this checkout — see test_menu_showcase.gd for hit coverage")
