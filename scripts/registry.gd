class_name Registry
extends RefCounted
# Shared lookup + test-override mechanism for the four authored content libraries
# (CarLibrary / EngineLibrary / RallyLibrary / UpgradeLibrary). Each of those
# libraries is a flat Array of entry Dictionaries keyed by a stable string "id";
# ownership/progress is persisted by that id (never array index), so a lookup must
# resolve a stored id back to the current array position / entry.
#
# Before this helper, index_of/by_id were reimplemented byte-identically in all
# four libraries, and the test seam (an override table swapped in by tests, so a
# logic/physics test can run against a synthetic roster) was duplicated on some and
# missing on others. This centralises both:
#   * index_of(entries, id) / by_id(entries, id) — the pure stable-id lookups.
#   * Seam(default_entries)                       — a tiny per-library override
#     holder. A library owns one Seam instance, exposes all()/override_for_test()/
#     reset() by delegating to it, and passes seam.all() into index_of/by_id.
# GDScript has no shared mutable static state across class_names, so the override
# table still physically lives on each library (via its own Seam), but the mechanism
# is defined once here and behaves identically everywhere.


# Array position of the entry with this stable id in `entries`, or -1 if none.
static func index_of(entries: Array, id: String) -> int:
	for i in entries.size():
		if entries[i]["id"] == id:
			return i
	return -1


# The entry for a stable id, or an empty Dictionary if unknown.
static func by_id(entries: Array, id: String) -> Dictionary:
	var i := index_of(entries, id)
	return entries[i] if i >= 0 else {}


# Per-library test-override holder. An empty override means "use the shipped
# catalogue". Tests call override_for_test() to run against a synthetic roster and
# reset() in teardown; inert in production (the override is always empty there).
class Seam extends RefCounted:
	var _default: Array[Dictionary]
	var _override: Array[Dictionary] = []

	func _init(default_entries: Array[Dictionary]) -> void:
		_default = default_entries

	func all() -> Array[Dictionary]:
		return _override if not _override.is_empty() else _default

	func override_for_test(entries: Array[Dictionary]) -> void:
		_override = entries

	func reset() -> void:
		_override = []
