extends GutTest
# Docs: features/regions.md
# Tests: this file guards features/regions.md against the region table drifting past it.
#
# `RegionLibrary.REGIONS` is the single source of truth for which regions exist.
# `features/regions.md` also describes them — in prose, by hand — and prose does not
# follow a table. That is not hypothetical: an eval probe added a region and updated no
# doc, leaving the doc's "the game ships six" enumeration wrong with the whole suite
# green, because nothing connected the two.
#
# So this file makes the doc a ratchet rather than a snapshot. It does NOT check what the
# doc says about a region — tone, detail and ordering are the author's business, and a
# test that pinned them would just be a second thing to update. It checks the one
# property that must hold for the doc to be worth reading at all: **every region that
# exists is mentioned, and any count the doc states is the real count.**
#
# Adding a region therefore forces a doc edit, in the same change, with a failure message
# that says exactly what to write. Retuning a region, reordering the table, or rewriting
# the prose all stay green.

const DOC_PATH := "res://features/regions.md"

# Number words the doc might plausibly use for a table this size. Only consulted when the
# doc actually states a count — see test_any_region_count_the_doc_states_is_correct.
const NUMBER_WORDS := {
	"two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
	"nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
}


func _doc_text() -> String:
	var f := FileAccess.open(DOC_PATH, FileAccess.READ)
	assert_not_null(f, "features/regions.md must exist — the region docs guard reads it")
	return "" if f == null else f.get_as_text()


func test_every_authored_region_is_mentioned_in_the_doc() -> void:
	# The ratchet. A region absent from the doc is a region a reader cannot discover, and
	# the id is the one string guaranteed to be stable enough to search for.
	var doc := _doc_text()
	if doc == "":
		return
	for region in RegionLibrary.REGIONS:
		var id := String(region.get("id", ""))
		assert_true(doc.find("`%s`" % id) != -1,
			("features/regions.md never mentions the region `%s`, which is authored in " +
			"RegionLibrary.REGIONS. Add it to the region description near the top of the " +
			"doc — a region nobody can find in the docs is a region nobody will reuse.") % id)


func test_any_region_count_the_doc_states_is_correct() -> void:
	# The doc opens by counting the regions ("The game ships six: …"). A count is the
	# fastest thing to falsify and the easiest to forget, so if one is present it must be
	# right. If a future rewrite drops the count entirely, that is fine and this passes —
	# the guard is on the claim, not on making the claim.
	var doc := _doc_text()
	if doc == "":
		return
	var expected := RegionLibrary.REGIONS.size()
	var re := RegEx.create_from_string(r"(?i)ships\s+([a-z]+)")
	for m in re.search_all(doc):
		var word := m.get_string(1).to_lower()
		if not NUMBER_WORDS.has(word):
			continue
		assert_eq(int(NUMBER_WORDS[word]), expected,
			("features/regions.md says the game ships '%s' regions, but " +
			"RegionLibrary.REGIONS holds %d. Update the count and the list beside it.")
				% [word, expected])
