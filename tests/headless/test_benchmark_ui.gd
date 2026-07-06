extends GutTest
# Benchmark UI (features/benchmark.md): the Settings → Benchmark page (toggle
# rows + Start) and the end-of-run results panel, including the keyboard/gamepad
# navigation contract every menu must honour (features/menus.md).

const TEST_PATH := "user://test_benchmark_ui_profile.json"

var _save: Node


func before_each() -> void:
	_save = get_node("/root/Save")
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.load_or_new()
	_reset_benchmark()


func after_each() -> void:
	_reset_benchmark()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


func _reset_benchmark() -> void:
	Benchmark.active = false
	Benchmark.results = {}
	Benchmark._saved = {}
	for t in Benchmark.TOGGLES:
		Benchmark.set_option(String(t["key"]), true)


# --- Settings → Benchmark page --------------------------------------------------

func _make_settings() -> SettingsMenu:
	var sm := SettingsMenu.new()
	add_child_autofree(sm)
	return sm


func test_benchmark_page_has_a_row_per_toggle() -> void:
	var sm := _make_settings()
	assert_eq(sm.benchmark_rows.size(), Benchmark.TOGGLES.size(),
		"one settings row per benchmark toggle")
	for row in sm.benchmark_rows:
		assert_eq((row["button"] as Button).focus_mode, Control.FOCUS_ALL,
			"benchmark rows are keyboard/gamepad focusable")


func test_toggle_row_flips_the_option_and_repaints() -> void:
	var sm := _make_settings()
	var row: Dictionary = sm.benchmark_rows[0]
	var key := String(row["key"])
	assert_true((row["button"] as Button).text.ends_with("ON"), "an on toggle reads ON")
	(row["button"] as Button).pressed.emit()
	assert_false(Benchmark.get_option(key), "pressing the row turns the option off")
	assert_true((row["button"] as Button).text.ends_with("OFF"), "and the row repaints OFF")
	(row["button"] as Button).pressed.emit()
	assert_true(Benchmark.get_option(key), "pressing again turns it back on")


func test_benchmark_page_navigation() -> void:
	var sm := _make_settings()
	await get_tree().process_frame  # _ready shows the list + deferred focus
	sm.show_benchmark()
	assert_false(sm.at_root(), "the benchmark page is a sub-page")
	await get_tree().process_frame  # deferred focus grab
	assert_eq(sm.get_viewport().gui_get_focus_owner(), sm.benchmark_rows[0]["button"],
		"opening the Benchmark page focuses its first row")
	assert_true(sm.go_back(), "go_back from the benchmark page is consumed")
	assert_true(sm.at_root(), "and returns to the category list")


# --- Results panel ---------------------------------------------------------------

func _fake_stats() -> Dictionary:
	var s := BenchmarkStats.summarise({
		"frame_ms": [16.0, 16.0, 16.0, 33.0],
		"draws": [500.0, 520.0],
		"render_cpu_ms": [3.0, 3.0],
	})
	s["distance_m"] = 2500.0
	s["disabled"] = ["Spectators"] as Array[String]
	return s


func test_results_panel_lines_carry_the_breakdown() -> void:
	var lines := BenchmarkResults.format_lines(_fake_stats())
	var text := "\n".join(lines)
	# GUT's assert_string_contains takes no message arg (3rd param is match_case).
	assert_string_contains(text, "avg fps")       # the headline fps
	assert_string_contains(text, "1% low")        # the stutter number
	assert_string_contains(text, "draws")         # draw calls
	assert_string_contains(text, "physics")       # process breakdown
	assert_string_contains(text, "2500 m")        # the driven distance
	assert_string_contains(text, "Spectators")    # disabled toggles recorded


func test_results_panel_lines_survive_empty_stats() -> void:
	var lines := BenchmarkResults.format_lines({})
	assert_true(lines.size() > 0, "an empty run still formats")
	for line in lines:
		assert_false(line.contains("disabled"), "no disabled line when nothing was off")


func test_results_panel_is_keyboard_navigable_and_actions_fire() -> void:
	var hits := {"again": 0, "exited": 0}
	var panel := BenchmarkResults.new()
	add_child_autofree(panel)
	panel.setup(_fake_stats(),
		func() -> void: hits["again"] += 1,
		func() -> void: hits["exited"] += 1)
	await get_tree().process_frame  # MenuNav's deferred focus grab

	assert_eq(panel.again_button.focus_mode, Control.FOCUS_ALL, "Run again is focusable")
	assert_eq(panel.exit_button.focus_mode, Control.FOCUS_ALL, "Exit is focusable")
	assert_eq(panel.again_button.get_viewport().gui_get_focus_owner(), panel.again_button,
		"the cursor opens on Run again")

	panel.again_button.pressed.emit()
	assert_eq(hits["again"], 1, "Run again fires its action")
	panel.exit_button.pressed.emit()
	assert_eq(hits["exited"], 1, "Exit fires its action")

	# Back (Esc / gamepad B) routes to Exit via the MenuNav framework.
	var back := InputEventAction.new()
	back.action = "ui_cancel"
	back.pressed = true
	var nav: MenuNav = null
	for child in panel.get_children():
		for sub in child.get_children():
			if sub is MenuNav:
				nav = sub
	assert_not_null(nav, "the results panel attaches the MenuNav framework")
	nav._unhandled_input(back)
	assert_eq(hits["exited"], 2, "back routes to Exit")
