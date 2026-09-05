extends GutTest
# firestore.rules — the file CI deploys, checked for the failure that actually happened.
#
# WHY THIS FILE EXISTS. The rules are the ONLY thing protecting the cloud save
# (features/cloud-save.md: the client's API key is public by design), and they are
# deployed by CI on every push to main — so a malformed file does not fail loudly in the
# game, it fails in a deploy job and the console silently keeps serving the LAST GOOD
# rules. That is the worst shape of failure: nothing local goes red, the game keeps
# working, and the deployed policy quietly drifts from the committed one.
#
# THE REAL BUG THIS CATCHES. Deleting the multiplayer lobby removed its `match
# /lobby_state/{doc} {` header line but left the block's BODY behind — a `validState()`
# function and four `allow` lines with no `match` around them, and one extra `}`. Nothing
# in the repo reads this file, so it sat broken from 2026-09-02 until the deploy log was
# read: three weeks of pushes in which the Firestore rules deploy failed every time.
#
# WHAT IS AND IS NOT TESTED HERE. This is a STRUCTURAL check, not a rules-semantics one:
# GDScript cannot evaluate the Firestore rules language, and pretending otherwise would be
# theatre. Real semantics need the Firebase emulator, which is CI's job. What a cheap
# structural check does cover is exactly the class of damage a deletion causes — an
# unbalanced brace, an orphaned block, a stranded `allow` outside any `match`.

const RULES_PATH := "res://firestore.rules"


func _rules_text() -> String:
	var f := FileAccess.open(RULES_PATH, FileAccess.READ)
	assert_not_null(f, "firestore.rules is readable — CI deploys it, so it must exist")
	return f.get_as_text() if f != null else ""


# Strip line comments and quoted strings so a `{` inside either can't skew the count.
# Rules comments are `//` to end of line; strings are single-quoted in this file.
func _significant_lines(text: String) -> Array[String]:
	var out: Array[String] = []
	for raw in text.split("\n"):
		var line := String(raw)
		var quote := line.find("'")
		while quote >= 0:
			var close := line.find("'", quote + 1)
			if close < 0:
				break
			line = line.substr(0, quote) + line.substr(close + 1)
			quote = line.find("'")
		var comment := line.find("//")
		if comment >= 0:
			line = line.substr(0, comment)
		out.append(line)
	return out


# THE ONE THAT WOULD HAVE CAUGHT IT. An unbalanced file is rejected by the rules compiler
# with "Unexpected '}'" and the deploy job exits 1.
func test_the_braces_balance() -> void:
	var depth := 0
	var line_no := 0
	for line in _significant_lines(_rules_text()):
		line_no += 1
		depth += line.count("{") - line.count("}")
		assert_gte(depth, 0,
			"firestore.rules closes a block that was never opened, at line %d" % line_no)
		if depth < 0:
			return
	assert_eq(depth, 0, "every block in firestore.rules is closed exactly once")


# The orphan's OTHER signature: a rule body left behind when its `match` header is
# deleted. Every `allow` and every `function` must sit inside a match block — at the top
# level they are the wreckage of a half-finished deletion.
func test_no_rule_body_sits_outside_a_match_block() -> void:
	var depth := 0
	var line_no := 0
	for line in _significant_lines(_rules_text()):
		line_no += 1
		var stripped := line.strip_edges()
		# Depth 0 is the file itself; 1 is inside `service`; 2 is inside the databases
		# match. A rule body has to be deeper than that.
		if depth <= 2 and (stripped.begins_with("allow ") or stripped.begins_with("function ")):
			assert_true(false,
				"firestore.rules line %d ('%s') is outside any match block — the mark of a "
				% [line_no, stripped] + "deleted `match` header whose body was left behind")
			return
		depth += line.count("{") - line.count("}")
	assert_true(true, "every allow/function sits inside a match block")


# The deny-all catch-all is what makes "nothing else in the database is reachable" true,
# and it is the single line whose absence would silently open every future collection.
func test_the_deny_all_catch_all_is_present() -> void:
	var text := _rules_text()
	assert_true(text.contains("match /{document=**}"),
		"the catch-all match is present, so a new collection is closed until it opts in")
	assert_true(text.contains("allow read, write: if false;"),
		"and it denies both reads and writes")


# Collections the pivot deleted must not still be granted access. A stale grant is not a
# crash — it is an open door onto data nothing writes any more.
func test_no_rules_survive_for_deleted_collections() -> void:
	var text := _rules_text()
	for gone in ["stage_times", "lobby_rounds", "lobby_state"]:
		assert_false(text.contains("match /%s" % gone),
			"'%s' was deleted with its feature, so it must not still have a rule" % gone)
