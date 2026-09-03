extends GutTest
# Docs: features/hud.md, features/debug-tools.md
# Tests: this file guards those two docs against HUD.DEBUG_READOUT_NODES drifting past them.
#
# Modelled on tests/headless/test_region_docs.gd, which is the one intervention in this
# codebase with a clean before/after showing it works: the round it was added, the region
# doc came out correct while the HUD docs — same probe class, same round, same
# prose-editing task — came out wrong in three places. The difference was that one had a
# test behind it and the other had a comment.
#
# What went wrong without it: a change that moved `GearLabel` out of the H-gated debug
# readout also rewrote three docs to say speed and rpm were now always visible. They were
# not — they are still in the constant. Plausible prose is cheap to write and nothing
# contradicted it.
#
# The guard is deliberately narrow. It does not check tone, completeness, or how the docs
# describe anything; those are the author's business and pinning them would just be
# another thing to update. It checks the one claim that can be mechanically falsified:
# **a doc must not describe a label as H-gated when it is not, and must not describe one
# as always-visible when it is.** Moving a label in or out of DEBUG_READOUT_NODES stays
# green as long as the docs are corrected in the same change — which is the point.

const HUD_SCRIPT := "res://scripts/hud.gd"
const DOCS := ["res://features/hud.md", "res://features/debug-tools.md"]

# The labels whose gating the docs actually discuss. Not read from the scene: the point is
# to catch a doc making a claim about a name, so the name is the unit. A label nobody
# documents needs no guard.
const DOCUMENTED_LABELS := [
	&"SpeedLabel", &"GearLabel", &"RPMLabel", &"BoostLabel", &"SeedLabel",
	&"GripGrid",
]

# Phrases that assert a label is NOT behind the H toggle. Matched against the sentence a
# label's name appears in, so an unrelated mention elsewhere in the doc is not a false
# positive.
const ALWAYS_VISIBLE_CLAIMS := [
	"always visible", "at all times", "permanently visible", "always shown",
	"visible at all times", "no longer part of the debug", "not hidden by default",
]

# The inverse claims: phrases that assert a label IS behind the H toggle. Matched the
# same way, against documented labels that are NOT in the constant.
const HIDDEN_CLAIMS := [
	"hidden by default", "hidden until", "toggled with", "h-gated", "dev diagnostic",
	"is hidden", "part of the debug readout", "part of the debug overlay",
]


func _hud_membership() -> Array:
	# Parsed from source rather than instantiated: this guard must run without building a
	# HUD node, and the constant is a plain literal list.
	var f := FileAccess.open(HUD_SCRIPT, FileAccess.READ)
	assert_not_null(f, "scripts/hud.gd must be readable")
	if f == null:
		return []
	var src := f.get_as_text()
	var start := src.find("const DEBUG_READOUT_NODES")
	assert_true(start != -1, "hud.gd must still declare DEBUG_READOUT_NODES")
	if start == -1:
		return []
	# The literal starts at the `[` AFTER the `=` — searching from the declaration start
	# would stop at the `]` inside the `Array[StringName]` type annotation, parse an empty
	# membership, and turn every assertion below into a vacuous pass (it did, silently,
	# for two rounds).
	var open := src.find("[", src.find("=", start))
	var close := src.find("]", open)
	var body := src.substr(open, close - open)
	var out: Array = []
	var re := RegEx.create_from_string(r'&"(\w+)"')
	for m in re.search_all(body):
		out.append(StringName(m.get_string(1)))
	assert_true(out.size() > 0,
		"parsed DEBUG_READOUT_NODES as empty — the guard cannot check anything; fix the parse in this test")
	return out


# A doc can transcribe the membership without ever writing a node name: "speed, RPM,
# boost, seed…" is the same rotting second copy in prose clothing (a probe wrote exactly
# that). Derive the prose word from each node name so the enumeration check sees both
# spellings without keeping its own word list to rot.
func _prose_stem(label: StringName) -> String:
	return String(label).to_lower().trim_suffix("label").trim_suffix("grid")


func _label_mentioned(raw_line: String, lower_line: String, label: StringName) -> bool:
	if raw_line.find(String(label)) != -1:
		return true
	var re := RegEx.create_from_string("\\b%s\\b" % _prose_stem(label))
	return re.search(lower_line) != null


func _sentences_mentioning(doc: String, needle: String) -> Array[String]:
	var out: Array[String] = []
	for line in doc.split("\n"):
		if line.find(needle) != -1:
			out.append(line.to_lower())
	return out


func test_no_doc_claims_a_gated_label_is_always_visible() -> void:
	# The exact error a probe shipped: three docs rewritten to say "speed / gear / rpm are
	# now always visible" when only gear had moved.
	var gated := _hud_membership()
	for path in DOCS:
		var f := FileAccess.open(path, FileAccess.READ)
		assert_not_null(f, "%s must exist — the HUD docs guard reads it" % path)
		if f == null:
			continue
		var doc := f.get_as_text()
		for label in gated:
			for line in _sentences_mentioning(doc, String(label)):
				for claim in ALWAYS_VISIBLE_CLAIMS:
					assert_true(line.find(claim) == -1,
						("%s says `%s` is \"%s\", but %s IS still in " +
						"hud.gd's DEBUG_READOUT_NODES — it is hidden until H. Either " +
						"correct the sentence or remove the label from the constant.")
							% [path, label, claim, label])


func test_no_doc_claims_an_ungated_label_is_hidden() -> void:
	# The other direction — the header always promised it, round 044 found it missing: a
	# probe un-gated speed/rpm and every doc sentence calling them hidden stayed green.
	var gated := _hud_membership()
	for path in DOCS:
		var f := FileAccess.open(path, FileAccess.READ)
		assert_not_null(f, "%s must exist — the HUD docs guard reads it" % path)
		if f == null:
			continue
		var doc := f.get_as_text()
		for label in DOCUMENTED_LABELS:
			if label in gated:
				continue
			for line in _sentences_mentioning(doc, String(label)):
				for claim in HIDDEN_CLAIMS:
					assert_true(line.find(claim) == -1,
						("%s says `%s` is \"%s\", but %s is NOT in hud.gd's " +
						"DEBUG_READOUT_NODES — it is always visible. Either correct " +
						"the sentence or add the label to the constant.")
							% [path, label, claim, label])


func test_the_docs_do_not_transcribe_the_membership_list() -> void:
	# features/hud.md carried, in bold, "this doc deliberately does not list it" with the
	# reason inline — and a probe deleted that sentence and hand-wrote the list back. A
	# transcribed list is a second copy that rots on the next membership change, which is
	# the failure this whole guard exists for. Detected structurally: a single line that
	# names four or more members at once is an enumeration, not a discussion.
	var gated := _hud_membership()
	for path in DOCS:
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		for line in f.get_as_text().split("\n"):
			var lower := line.to_lower()
			var hits := 0
			for label in gated:
				if _label_mentioned(line, lower, label):
					hits += 1
			assert_true(hits < 4,
				("%s enumerates %d DEBUG_READOUT_NODES members on one line. Do not " +
				"transcribe the membership list into prose — point at " +
				"hud.gd's DEBUG_READOUT_NODES instead. A second copy of the list is a " +
				"second thing to rot, and it already has once.\n  line: %s")
					% [path, hits, line.strip_edges()])
