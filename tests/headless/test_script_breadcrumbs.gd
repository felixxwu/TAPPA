extends GutTest
# Docs: features/README.md (the "# Docs: / # Tests: header breadcrumb" convention)
# Tests: this file IS the enforcement for that convention.
#
# Scripts in scripts/ carry a two-line header breadcrumb naming the feature doc(s) that
# describe them and the test file(s) that cover them, so an agent editing the script is
# told what else to update without having to already know. The convention was added
# wholesale; this file is what keeps it true afterwards.
#
# What went wrong without it, and what each test below is for:
#
#   * A breadcrumb naming a file that no longer exists is worse than none — it sends the
#     reader somewhere empty and costs them the trip. Renaming or deleting a test or a
#     doc silently rots every breadcrumb pointing at it.
#   * A breadcrumb naming SIXTEEN test files is not a pointer, it is a haystack. Observed
#     directly: a probe followed the "# Docs:" half of a breadcrumb precisely (two files,
#     obvious action) and ignored the "# Tests:" half of the same comment block (five
#     files, no indication which one pinned the behaviour it was changing) — and shipped
#     a red test. The cap is what keeps the line actionable.
#
# Nothing here pins WHICH docs or tests a script names, or how many scripts carry a
# breadcrumb. Adding, renaming and retargeting breadcrumbs all stay green; only a
# dangling pointer or an unreadably long list fails.

const MAX_TESTS_NAMED := 3
const SCRIPTS_DIR := "res://scripts"


# RECURSIVE, and that is the point (fixed round 027). This walked only the TOP level of
# scripts/ until then, so every file in a SUBDIRECTORY escaped the convention entirely —
# `scripts/cloud/` (13 files, 12 of them with no breadcrumb at all) and
# `scripts/multiplayer/` (5). Both directories were created AFTER the convention landed,
# which is exactly the decay this guard's own header warns about: "a convention that only
# holds for the files that happened to exist on the day of the sweep decays from that day
# onward." A non-recursive scan re-opens that hole for every new directory.
#
# The BREADCRUMB_BASELINE below matches on BASENAME, and no subdirectory file shares a
# basename with a baseline entry (checked when this was made recursive), so nothing became
# accidentally exempt.
func _script_paths() -> Array[String]:
	var out: Array[String] = []
	_gd_scripts_under(SCRIPTS_DIR, out)
	assert_gt(out.size(), 100, "scripts/ must be readable and is expected to be large")
	return out


# Header only: a breadcrumb is a header comment. Scanning the whole file would pick up
# incidental mentions of test paths in prose and turn this guard into a nuisance.
func _header_lines(path: String) -> Array[String]:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var out: Array[String] = []
	for i in 8:
		if f.eof_reached():
			break
		out.append(f.get_line())
	return out


func _named(path: String, prefix: String, pattern: String) -> Array[String]:
	var re := RegEx.create_from_string(pattern)
	for line in _header_lines(path):
		if not line.begins_with(prefix):
			continue
		var out: Array[String] = []
		for m in re.search_all(line):
			out.append(m.get_string())
		return out
	return []


func test_every_breadcrumb_test_file_exists() -> void:
	for path in _script_paths():
		for named in _named(path, "# Tests:", r"tests/headless/\w+\.gd"):
			assert_true(FileAccess.file_exists("res://" + named),
				("%s's `# Tests:` breadcrumb names %s, which does not exist — a pointer " +
				"to nothing costs the next reader the trip. Retarget it or drop it.")
					% [path, named])


func test_every_breadcrumb_doc_file_exists() -> void:
	for path in _script_paths():
		for named in _named(path, "# Docs:", r"features/[\w-]+\.md"):
			assert_true(FileAccess.file_exists("res://" + named),
				("%s's `# Docs:` breadcrumb names %s, which does not exist. Retarget it " +
				"or drop it.") % [path, named])


func test_no_breadcrumb_names_more_tests_than_a_reader_will_triage() -> void:
	# The cap is the whole point of the line: name the PRIMARY covering tests, and let the
	# reader derive the rest with the grep the breadcrumb itself suggests. A list long
	# enough to need triage gets skipped entirely, which is the failure this guards.
	for path in _script_paths():
		var named := _named(path, "# Tests:", r"tests/headless/\w+\.gd")
		assert_true(named.size() <= MAX_TESTS_NAMED,
			("%s's `# Tests:` breadcrumb names %d test files; the cap is %d. Keep the " +
			"primary ones and point at a grep for the rest — a list this long is a " +
			"haystack, and a reader under context pressure skips it.")
				% [path, named.size(), MAX_TESTS_NAMED])

# ---------------------------------------------------------------------------
# THE RATCHET: every NEW script must carry a breadcrumb.
#
# The tests above keep existing breadcrumbs honest. They do nothing about the next
# script somebody adds — and a convention that only holds for the files that
# happened to exist on the day of the sweep decays from that day onward. This is
# the half-fix that has cost this project two rounds already: 82 scripts were given
# breadcrumbs with nothing requiring the 83rd to have one.
#
# So: a script must carry a `# Docs:` breadcrumb UNLESS it is named in the frozen
# list below. That list is the set of scripts predating the convention. It is a
# BASELINE, not an exemption policy:
#
#   * a script NOT on the list must comply — so every new file complies by default,
#     with no rule to remember and no reviewer needed to catch it;
#   * a script ON the list that has SINCE gained a breadcrumb must be REMOVED from
#     the list — enforced below, so the list can only ever shrink.
#
# Do not add to this list. If you are here because a new script failed the check,
# the fix is a two-line header on your script, not a new entry.
const BREADCRUMB_BASELINE := [
	"account_menu.gd",
	"barrier_field.gd",
	"barrier_layout.gd",
	"barrier_section.gd",
	"benchmark_report.gd",
	"bush_field.gd",
	"button_cursor.gd",
	"car_library.gd",
	"car_list.gd",
	"car_preview_audio.gd",
	"car_prop.gd",
	"car_silhouettes.gd",
	"car_stat_bounds.gd",
	"challenge_session.gd",
	"chunk_border_debug.gd",
	"confirm_popup.gd",
	"control_scheme_diagram.gd",
	"cpu_particle_pool.gd",
	"crosswind.gd",
	"crowd.gd",
	"distant_terrain.gd",
	"driving_context.gd",
	"exhaust_lab.gd",
	"garage.gd",
	"gauge_icons.gd",
	"global_standings.gd",
	"headlight_cone.gd",
	"hud_gauge.gd",
	"input_remap.gd",
	"loading_screen.gd",
	"loading_tips.gd",
	"menu_page.gd",
	"mesh_util.gd",
	"music_library.gd",
	"music_schedule.gd",
	"obstacle_body.gd",
	"pacenotes.gd",
	"pause_icon.gd",
	"perf_log.gd",
	"perf_overlay.gd",
	"platform.gd",
	"polygon_icon.gd",
	"post_process_view.gd",
	"present_box.gd",
	"ps1_material.gd",
	"rain_field.gd",
	"rally_flag.gd",
	"rally_trophy.gd",
	"registry.gd",
	"repair_reveal.gd",
	"road_markings.gd",
	"slider_row.gd",
	"spectator_group.gd",
	"spectator_scatter.gd",
	"stale_guard.gd",
	"star_row.gd",
	"stat_bar.gd",
	"terrain_chunk_builder.gd",
	"terrain_lod.gd",
	"text_field.gd",
	"tilt_input.gd",
	"touch_scroll_container.gd",
	"track_cache.gd",
	"track_preview.gd",
	"track_surface.gd",
	"tree_fall.gd",
	"tree_silhouette.gd",
	"upgrade_icons.gd",
	"upgrade_reveal.gd",
	"username_popup.gd",
	"weather_library.gd",
	"web_fullscreen.gd",
	"wheel_style.gd",
	"wrench_icon.gd",
]


func test_every_new_script_carries_a_docs_breadcrumb() -> void:
	var baseline := {}
	for name in BREADCRUMB_BASELINE:
		baseline[name] = true
	for path in _script_paths():
		var name: String = path.get_file()
		if baseline.has(name):
			continue
		var has_docs := false
		for line in _header_lines(path):
			if line.begins_with("# Docs:"):
				has_docs = true
				break
		# Report the FULL path, not the basename: the scan is recursive, so "scripts/foo.gd"
		# would send a reader hunting in the wrong directory for a file under scripts/cloud/.
		assert_true(has_docs,
			("AA has no `# Docs:` header breadcrumb. Every script added since " +
			"the convention landed carries one: `# Docs: features/<area>.md — update in " +
			"the same change as this file.` plus a `# Tests:` line naming up to BB " +
			"primary test files. If this script genuinely has no feature area yet, that " +
			"is the thing to fix — write the doc, or name the closest area.")
				.replace("AA", path).replace("BB", str(MAX_TESTS_NAMED)))


func test_the_breadcrumb_baseline_only_shrinks() -> void:
	# A ratchet that can quietly widen is not a ratchet. When a listed script gains a
	# breadcrumb its entry must go, or the list drifts into a permanent exemption
	# roster and its length stops meaning anything.
	for name in BREADCRUMB_BASELINE:
		var path: String = SCRIPTS_DIR + "/" + String(name)
		if not FileAccess.file_exists(path):
			continue  # renamed or deleted: a stale entry is harmless, drop it when convenient
		for line in _header_lines(path):
			assert_false(line.begins_with("# Docs:"),
				("scripts/AA now HAS a `# Docs:` breadcrumb, so remove it from " +
				"BREADCRUMB_BASELINE in this file. The baseline is only allowed to " +
				"shrink — leaving it there silently re-exempts the script.")
					.replace("AA", name))
			break


# --- Guard: a local must not shadow a method of its own class ----------------------------
#
# WHY (round 017). `rally_session.gd` has `func rally_id() -> String`, and two of its methods
# ALSO declared `var rally_id := String(_rally.get("id", ""))` as a local. So the bare token
# `rally_id` meant a String inside those two functions and a **Callable** everywhere else in
# the same file.
#
# A probe adding a feature to a third function in that file copied the neighbours' bare
# identifier — which is exactly what small models do (they clone the adjacent code) — and
# wrote `Save.record_rally_finish(rally_id)`. That resolved to the method, so the argument was
# a Callable, and THE WHOLE PROJECT FAILED TO COMPILE: every autoload died, the game would not
# boot. The probe reported the change as "fully integrated and ready for testing".
#
# The parse error is loud, so this is not about detection — it is about not laying the trap.
# All four collisions in scripts/ were renamed in round 017 and there are no exemptions, so
# this list must stay empty: the property holds for every file that exists and every file
# that does not exist yet.
#
# Deliberately narrow: it flags only a local whose name EQUALS a method on the same class,
# which is always avoidable and never useful. It says nothing about locals shadowing member
# variables (Godot warns on those itself) or about names from other classes.
func test_no_local_variable_shadows_a_method_of_the_same_class() -> void:
	var files: Array[String] = []
	_gd_scripts_under("res://scripts", files)
	assert_gt(files.size(), 50, "sanity: expected to find the scripts/ tree")

	var func_re := RegEx.new()
	func_re.compile("^(?:static\\s+)?func\\s+([A-Za-z0-9_]+)")
	var local_re := RegEx.new()
	local_re.compile("^\\s+var\\s+([A-Za-z0-9_]+)\\s*[:=]")

	var offenders: Array[String] = []
	for path in files:
		var src := FileAccess.get_file_as_string(path)
		if src == "":
			continue
		var lines := src.split("\n")
		var methods := {}
		for line in lines:
			var m := func_re.search(line)
			if m != null:
				methods[m.get_string(1)] = true
		var current := ""
		var n := 0
		for line in lines:
			n += 1
			var f := func_re.search(line)
			if f != null:
				current = f.get_string(1)
				continue
			var v := local_re.search(line)
			if v != null and methods.has(v.get_string(1)):
				offenders.append("%s:%d — local '%s' in %s() shadows the method of the same name"
					% [path, n, v.get_string(1), current])

	assert_eq(offenders, ([] as Array[String]),
		"these locals shadow a method of their own class: %s. " % str(offenders)
		+ "Rename the LOCAL (the method is the public name and its callers depend on it). "
		+ "This is not a style point: the bare identifier then means a String in one function "
		+ "and a Callable in the next, and code copied between them fails to COMPILE — which "
		+ "takes down every autoload, not just the file. See rally_session.gd's `rid` locals "
		+ "for the shape.")


# Shared with the guards above: every .gd under a directory, recursively.
func _gd_scripts_under(dir_path: String, out: Array[String]) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	for f in d.get_files():
		if f.ends_with(".gd"):
			out.append(dir_path.path_join(f))
	for sub in d.get_directories():
		_gd_scripts_under(dir_path.path_join(sub), out)


# --- Guard: StubHud must match the real HUD's arity, method for method ----------------------
#
# WHY (round 026). `stage_manager.gd` decides what it may call with `_hud_can[m] =
# _hud.has_method(m)` — and `has_method()` says nothing about ARITY. So widening a HUD method
# leaves the guard GREEN and breaks the call at runtime instead, against whichever HUD is
# actually attached. In tests that HUD is `StubHud` above.
#
# That is not hypothetical: a probe added a second gap to `Hud.show_position`, correctly
# updated `stage_manager.gd`'s call site AND `test_hud.gd`'s call sites, and missed this one
# stub. The engine DOES name it once the call runs ("Invalid call ... Expected 4 argument(s)"),
# but it surfaces as a debugger break attributed to whichever test was mid-flight, alongside an
# out-of-bounds read on the empty recorder array — so what you SEE first is two unrelated-looking
# stage-manager assertions failing. This guard names the drift directly instead.
#
# IT LIVES HERE, NOT IN test_stage_manager.gd, and that placement is load-bearing: the arity
# break triggers a Godot debugger break mid-run, which halted GUT before it reached this test
# when it was appended to that file. A guard must not be reachable only AFTER the failure it
# diagnoses. This file instantiates nothing and scans source, so it always runs.
#
# Both lists are derived, so this needs no maintenance: the METHOD NAMES come from
# `stage_manager.gd`'s own `_hud_can` block (the exact duck-typed boundary), and the arities
# come from the two sources. Add a method to that block and it is covered automatically.
#
# Counts total parameters, defaults included. Every one of the ten methods matches on main, so
# there are no exemptions and none should be added — fix the stub instead.
func test_stub_hud_matches_the_real_hud_signature_for_every_duck_typed_method() -> void:
	var sm := FileAccess.get_file_as_string("res://scripts/stage_manager.gd")
	var hud_src := FileAccess.get_file_as_string("res://scripts/hud.gd")
	var self_src := FileAccess.get_file_as_string("res://tests/headless/test_stage_manager.gd")
	assert_ne(sm, "", "could not read stage_manager.gd")
	assert_ne(hud_src, "", "could not read hud.gd")
	assert_ne(self_src, "", "could not read this test file")

	# The duck-typed boundary, read out of stage_manager's own list rather than restated here.
	var list_re := RegEx.new()
	list_re.compile('for m in \\[([^\\]]*)\\]:')
	var list_m := list_re.search(sm)
	assert_ne(list_m, null,
		"could not find stage_manager.gd's `for m in [...]` HUD method list — if it was "
		+ "restructured, update THIS guard; it is not a stage-manager failure")
	var name_re := RegEx.new()
	name_re.compile('"([a-z_]+)"')
	var names: Array[String] = []
	for hit in name_re.search_all(list_m.get_string(1)):
		names.append(hit.get_string(1))
	assert_gt(names.size(), 5, "expected the HUD method list to hold several names")

	var mismatches: Array[String] = []
	for n in names:
		var real := _arity_of(hud_src, n)
		var stub := _arity_of(self_src, n)
		if real < 0:
			mismatches.append("%s: not found in hud.gd" % n)
		elif stub < 0:
			mismatches.append("%s: StubHud does not implement it, but _hud_can will report it can" % n)
		elif real != stub:
			mismatches.append("%s: hud.gd takes %d arg(s), StubHud takes %d" % [n, real, stub])

	assert_eq(mismatches, ([] as Array[String]),
		"StubHud has drifted from the real HUD: %s. " % str(mismatches)
		+ "stage_manager gates these calls on has_method() alone, which ignores arity, so the "
		+ "call is only rejected once it actually runs: the engine raises \"Invalid call to "
		+ "function ... Expected N argument(s)\" and takes a debugger break, which fails whatever "
		+ "test was mid-flight and can halt the run before later tests execute. Fix StubHud in "
		+ "tests/headless/test_stage_manager.gd to match hud.gd; do not add an exemption here.")


# Total parameter count of `func <name>(...)` in `src`, or -1 if absent. Matches both a
# top-level func and one indented inside an inner class (StubHud's are indented).
func _arity_of(src: String, method_name: String) -> int:
	var re := RegEx.new()
	re.compile("(?m)^\\t?func %s\\(([^)]*)\\)" % method_name)
	var m := re.search(src)
	if m == null:
		return -1
	var args := m.get_string(1).strip_edges()
	if args == "":
		return 0
	return args.split(",").size()
