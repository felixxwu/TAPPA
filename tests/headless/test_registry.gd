extends GutTest
# Direct tests for the shared Registry helper (scripts/registry.gd) that backs the
# four content libraries' stable-id lookups + test-override seam. Uses synthetic
# entries only — no dependency on any real catalogue value.


func _entries() -> Array[Dictionary]:
	return [
		{"id": "alpha", "n": 1},
		{"id": "beta", "n": 2},
		{"id": "gamma", "n": 3},
	]


func test_index_of_finds_position_and_reports_missing() -> void:
	var e := _entries()
	assert_eq(Registry.index_of(e, "beta"), 1, "returns the array position of the id")
	assert_eq(Registry.index_of(e, "nope"), -1, "unknown id -> -1")


func test_by_id_returns_entry_or_empty() -> void:
	var e := _entries()
	assert_eq(Registry.by_id(e, "gamma")["n"], 3, "returns the matching entry dict")
	assert_true(Registry.by_id(e, "nope").is_empty(), "unknown id -> empty dict")


func test_seam_defaults_to_shipped_then_overrides_then_resets() -> void:
	var default_entries: Array[Dictionary] = [{"id": "stock"}]
	var seam := Registry.Seam.new(default_entries)
	assert_eq(seam.all(), default_entries, "empty override -> the default catalogue")

	var synthetic: Array[Dictionary] = [{"id": "synth"}]
	seam.override_for_test(synthetic)
	assert_eq(seam.all(), synthetic, "override swaps the table in")
	assert_eq(Registry.by_id(seam.all(), "synth")["id"], "synth", "lookups see the override")

	seam.reset()
	assert_eq(seam.all(), default_entries, "reset restores the default catalogue")
