extends GutTest
# Lint for the `features/` folder itself — the agent-oriented map of this project
# (CLAUDE.md: "read it first to get oriented"). These are structural contracts on the
# DOCS, not on gameplay: nothing here pins a value, names a catalogue entry, or cares
# what any doc says. They only assert that the map keeps the two properties that make it
# usable to someone holding a small part of the repo in context:
#
#   1. every area doc says which tests cover it, in a fixed place near the top;
#   2. every area doc is reachable from features/README.md.
#
# Both come from the small-model-readiness loop. Rounds 001 and 002 both found probes
# that read exactly the right `features/` doc, changed the right code, and then either
# broke a test they had no way to find or shipped a doc nobody could reach. The rules
# were already written down in CLAUDE.md; a rule only in the rulebook does not survive
# context pressure, so they are enforced here and stated in the docs themselves.

const FEATURES_DIR := "res://features"
const INDEX := "res://features/README.md"

# README.md is the index, not an area doc, so it carries no `**Tests:**` line and does
# not index itself.
const NOT_AN_AREA_DOC := ["README.md"]


func _feature_docs() -> Array:
	var out := []
	var dir := DirAccess.open(FEATURES_DIR)
	if dir == null:
		return out
	for name in dir.get_files():
		if name.ends_with(".md") and not NOT_AN_AREA_DOC.has(name):
			out.append(name)
	out.sort()
	return out


func _read(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


# Guards the folder itself being findable — if this fails the other two tests would
# vacuously pass over an empty list.
func test_the_features_folder_is_readable_and_not_empty() -> void:
	assert_gt(_feature_docs().size(), 0,
		"no .md files found under %s — the docs lint would silently pass" % FEATURES_DIR)


# The `**Tests:**` line is the fix for "I found the right doc and still could not tell
# which tests owned this behaviour". Position matters as much as presence: it sits
# directly under `**Source:**` in every file, so it is inside the first screenful rather
# than four hundred lines down where several docs used to mention their tests.
func test_every_feature_doc_names_the_tests_that_cover_it() -> void:
	for name in _feature_docs():
		var text := _read("%s/%s" % [FEATURES_DIR, name])
		assert_true(text.find("**Tests:**") != -1,
			("features/%s has no `**Tests:**` line. Add one directly under the " +
			"`**Source:**` line naming the tests/headless/*.gd files that cover this " +
			"area (or `**Tests:** none — this area has no automated coverage.`)") % name)


# A named test file that does not exist is worse than none: it sends the next reader
# somewhere empty and they conclude the area is untested. Checked by existence only —
# which tests a doc chooses to name is editorial.
func test_every_test_file_named_by_a_feature_doc_exists() -> void:
	var line_re := RegEx.new()
	line_re.compile("\\*\\*Tests:\\*\\*(.*)")
	var path_re := RegEx.new()
	path_re.compile("tests/headless/(test_[a-z0-9_]+\\.gd)")
	for name in _feature_docs():
		var text := _read("%s/%s" % [FEATURES_DIR, name])
		var line := line_re.search(text)
		if line == null:
			continue  # already reported by the test above
		for hit in path_re.search_all(line.get_string(1)):
			var rel := hit.get_string(1)
			assert_true(FileAccess.file_exists("res://tests/headless/" + rel),
				"features/%s points at tests/headless/%s, which does not exist"
					% [name, rel])


# CLAUDE.md requires a new feature doc to be indexed in features/README.md, and round 001
# saw every probe skip it. An unindexed doc is invisible to anyone who starts, as
# instructed, from the README — so the doc exists and the navigation problem remains.
func test_every_feature_doc_is_linked_from_the_readme() -> void:
	var index := _read(INDEX)
	assert_ne(index, "", "features/README.md is missing or unreadable")
	for name in _feature_docs():
		assert_true(index.find(name) != -1,
			("features/%s is not linked from features/README.md — add it to the feature " +
			"index table, or nobody starting from the README will find it") % name)


# --- Area docs must stay findable by size (ratchet) ----------------------------
# The defect this guards, found by the small-model-readiness loop in rounds 011-012:
# `features/menus.md` reached 2,539 lines covering every menu in the game, with
# "Adding a setting" buried as a subsection under a heading named after a different
# screen. Three probes in a row solved their task's CODE and updated no doc at all —
# one of them wrote a test unprompted, so it was not doc-writing reluctance. It was
# doc-LOCATION cost: finding the insertion point cost more than the change.
#
# A line count is a proxy for "can a reader find their section", but it is the proxy
# that actually broke, and it is machine-checkable. The fix a failure asks for is
# always the same and is stated in the message: move a self-contained topic into its
# own area doc and index it — which is this folder's existing convention.
const DOC_LINE_CAP := 1200

# BASELINE, in the same spirit as test_script_breadcrumbs.gd's:
#   * a doc NOT listed must stay under the cap — so no NEW monolith can appear;
#   * a doc listed must not GROW past the size recorded here, so the existing ones
#     can only shrink and the next addition has to go somewhere findable;
#   * a doc listed that has fallen under the cap must be REMOVED from the list.
# Do not add to this list. If you are here because a doc failed, split it.
const OVERSIZED_BASELINE := {
	"terrain.md": 1310,
}


# Matches `wc -l`: a file ending in a newline has that trailing empty segment dropped,
# so the number here is the same one you get at a shell and the baseline is checkable
# by hand.
func _line_count(name: String) -> int:
	var text := _read("%s/%s" % [FEATURES_DIR, name])
	var parts := text.split("\n")
	var n := parts.size()
	if n > 0 and parts[n - 1] == "":
		n -= 1
	return n


func test_no_area_doc_grows_into_an_unnavigable_monolith() -> void:
	for name in _feature_docs():
		var lines := _line_count(name)
		if OVERSIZED_BASELINE.has(name):
			assert_lte(lines, int(OVERSIZED_BASELINE[name]),
				("features/%s is on the oversized baseline at %d lines and has grown to %d. "
				+ "It may only SHRINK. Put your addition in its own area doc (with **Source:** "
				+ "/ **Tests:** lines and a features/README.md index row) and link it from here "
				+ "— see features/menu-navigation.md and features/settings.md, both split out "
				+ "of menus.md in round 012 for exactly this reason.")
					% [name, int(OVERSIZED_BASELINE[name]), lines])
		else:
			assert_lte(lines, DOC_LINE_CAP,
				("features/%s is %d lines, over the %d-line cap. A doc this size stops being "
				+ "navigable: a reader looking for one screen cannot find its section, which is "
				+ "how round 011 lost a task. Split a self-contained topic into its own area "
				+ "doc, give it **Source:** / **Tests:** lines, and index it in "
				+ "features/README.md.") % [name, lines, DOC_LINE_CAP])


func test_the_oversized_doc_baseline_only_shrinks() -> void:
	for name in OVERSIZED_BASELINE:
		assert_true(FileAccess.file_exists("%s/%s" % [FEATURES_DIR, name]),
			"features/%s is on OVERSIZED_BASELINE but does not exist — remove the entry" % name)
		assert_gt(_line_count(name), DOC_LINE_CAP,
			("features/%s is on OVERSIZED_BASELINE but is now under the %d-line cap. Remove it "
			+ "from the list so it cannot silently grow back.") % [name, DOC_LINE_CAP])
