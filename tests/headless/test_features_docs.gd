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
