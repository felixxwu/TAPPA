extends GutTest
# CarStatsPanel (scripts/car_stats_panel.gd) — the reusable plain/comparison spec-sheet
# read-out. Built off synthetic CarStats.values-shaped dicts, never a real catalogue car
# (CLAUDE.md) — this file only cares that the grid is 2 columns, the arrow and colours
# appear exactly when a stat actually changed, the colour side matches CarStats.change's
# direction, and a stat missing from `before` draws no row.

func _labels(control: Control) -> Array[Label]:
	var out: Array[Label] = []
	for node in control.find_children("*", "Label", true, false):
		out.append(node as Label)
	return out


func test_plain_mode_renders_one_figure_per_row_and_no_arrow() -> void:
	var grid := CarStatsPanel.build({"power": 400.0, "mass": 1200.0})
	var texts := ""
	for l in _labels(grid):
		texts += String(l.text) + " "
	assert_false(texts.contains(CarStatsPanel.ARROW), "plain mode never draws the arrow")


func test_comparison_mode_draws_the_arrow_only_for_stats_that_changed() -> void:
	var before := {"power": 400.0, "mass": 1200.0}
	var after := {"power": 500.0, "mass": 1200.0}
	var grid := CarStatsPanel.build(before, after)
	var rows := grid.get_children()
	var power_row: HBoxContainer = null
	var mass_row: HBoxContainer = null
	for row in rows:
		var texts := ""
		for l in _labels(row):
			texts += String(l.text) + " "
		if texts.contains("POWER"):
			power_row = row
		elif texts.contains("WEIGHT"):
			mass_row = row
	assert_not_null(power_row, "setup: the power row is present")
	assert_not_null(mass_row, "setup: the mass row is present")
	var power_texts := ""
	for l in _labels(power_row):
		power_texts += String(l.text) + " "
	assert_true(power_texts.contains(CarStatsPanel.ARROW), "power changed, so it draws the arrow")
	var mass_texts := ""
	for l in _labels(mass_row):
		mass_texts += String(l.text) + " "
	assert_false(mass_texts.contains(CarStatsPanel.ARROW), "mass did not change, so no arrow")


func test_the_improved_side_is_green_and_the_worse_side_is_red() -> void:
	# power is BETTER: after (500) improved over before (400) -> before=red, after=green.
	var grid := CarStatsPanel.build({"power": 400.0}, {"power": 500.0})
	var labels := _labels(grid)
	# Row layout: key label, before label, arrow label, after label.
	assert_eq(labels.size(), 4, "setup: one comparison row draws key/before/arrow/after")
	assert_eq(labels[1].get_theme_color("font_color"), UITheme.RED, "the worse (before) figure is red")
	assert_eq(labels[3].get_theme_color("font_color"), UITheme.GREEN, "the better (after) figure is green")


func test_the_improved_side_flips_for_a_worse_direction_stat() -> void:
	# mass is WORSE: after (1400, heavier) is worse than before (1200) -> before=green, after=red.
	var grid := CarStatsPanel.build({"mass": 1200.0}, {"mass": 1400.0})
	var labels := _labels(grid)
	assert_eq(labels[1].get_theme_color("font_color"), UITheme.GREEN, "the lighter (before) figure is green")
	assert_eq(labels[3].get_theme_color("font_color"), UITheme.RED, "the heavier (after) figure is red")


func test_a_stat_missing_from_before_yields_no_row() -> void:
	var grid := CarStatsPanel.build({"power": 400.0})
	var texts := ""
	for l in _labels(grid):
		texts += String(l.text) + " "
	assert_false(texts.contains("WEIGHT"), "mass is absent from `before`, so it draws no row")


func test_the_grid_has_two_columns() -> void:
	var grid := CarStatsPanel.build({"power": 400.0, "mass": 1200.0})
	assert_eq(grid.columns, 2)
