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


func _script_paths() -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(SCRIPTS_DIR)
	assert_not_null(dir, "scripts/ must be readable")
	if dir == null:
		return out
	for f in dir.get_files():
		if f.ends_with(".gd"):
			out.append("%s/%s" % [SCRIPTS_DIR, f])
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
	"camera_manager.gd",
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
	"fps_setting.gd",
	"garage.gd",
	"gauge_icons.gd",
	"global_standings.gd",
	"headlight_cone.gd",
	"hq_environment.gd",
	"hud_gauge.gd",
	"input_remap.gd",
	"loading_screen.gd",
	"loading_tips.gd",
	"map_fog.gd",
	"map_house.gd",
	"map_table.gd",
	"menu_page.gd",
	"mesh_util.gd",
	"music_director.gd",
	"music_library.gd",
	"music_schedule.gd",
	"obstacle_body.gd",
	"overworld_blocks.gd",
	"overworld_cache.gd",
	"overworld_fog_wall.gd",
	"overworld_garage.gd",
	"overworld_map.gd",
	"overworld_marker.gd",
	"overworld_pads.gd",
	"overworld_picker.gd",
	"overworld_region.gd",
	"overworld_roads.gd",
	"overworld_route.gd",
	"overworld_scatter.gd",
	"overworld_zone.gd",
	"overworld_zones.gd",
	"overworld.gd",
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
	"wreck_screen.gd",
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
		assert_true(has_docs,
			("scripts/AA has no `# Docs:` header breadcrumb. Every script added since " +
			"the convention landed carries one: `# Docs: features/<area>.md — update in " +
			"the same change as this file.` plus a `# Tests:` line naming up to BB " +
			"primary test files. If this script genuinely has no feature area yet, that " +
			"is the thing to fix — write the doc, or name the closest area.")
				.replace("AA", name).replace("BB", str(MAX_TESTS_NAMED)))


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
