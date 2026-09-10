class_name CarStatsPanel
extends RefCounted
# Docs: features/car-stats.md — update in the same change as this file.
# Tests: tests/headless/test_car_stats_panel.gd — extend in the same change.
#
# THE CAR SPEC SHEET, drawn. One reusable two-column read-out of `CarStats.ROWS`, in two
# modes off the same builder:
#   * PLAIN        — `build(values)`. Every stat as one figure. What the buy/select popup
#                    shows: this is the car.
#   * COMPARISON   — `build(before, after)`. Every stat as "400 -> 500", the worse figure
#                    in red and the better in green, so the direction of the change is
#                    readable without doing arithmetic. What the upgrade confirmation
#                    shows: this is what the pick would do to the car.
# The mode is chosen by whether `after` is empty, so a caller that has no comparison to
# make simply does not pass one — there is no flag to get wrong.
#
# WHICH SIDE IS GREEN IS NOT THIS FILE'S DECISION. `CarStats.change` owns it, because
# "bigger is better" is true of power and false of weight and a display that guesses gets
# half the sheet backwards. This file only paints what it is told: the better figure
# green, the worse one red, and a stat that did not move (or one like the drivetrain that
# has no better/worse at all) plain.
#
# AN UNCHANGED STAT COLLAPSES TO ONE FIGURE rather than rendering "400 -> 400" in grey.
# On a real upgrade most of the sheet does not move, and a column of identical pairs
# joined by arrows buries the two rows that actually changed — which is the entire
# question the player opened this panel to answer.
#
# NOT A SCENE and not a page: it returns a plain Control the caller mounts wherever it
# likes (a ConfirmPopup's body, a MenuPage's body). That is what lets both the hub popup
# and the between-stage confirmation share it, and what keeps its tests free of a world
# scene.

# The glyph between a before and an after figure. The project's own arrow (features docs
# and UI copy use "->" nowhere and the em-arrow everywhere).
const ARROW := "→"


# The read-out. `before` and `after` are `CarStats.values` dicts. Pass `after` empty (the
# default) for the plain single-figure mode.
#
# Rows follow `CarStats.ROWS` order, filling the two columns left-to-right then down —
# the same shape and reasoning as the hub's lifetime-stats page (a single column ran too
# tall for the screen and each row is short enough to pair).
static func build(before: Dictionary, after: Dictionary = {}) -> Control:
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", UITheme.GAP)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for entry in CarStats.ROWS:
		var id := String((entry as Dictionary).get("id", ""))
		if not before.has(id):
			# A sheet missing a stat draws no row for it rather than a "0" — a synthetic
			# fixture car legitimately carries only some fields, and inventing a zero
			# would read as "this car has no grip".
			continue
		grid.add_child(_row(id, float(before[id]),
			float(after[id]) if after.has(id) else NAN))
	return grid


# One "Label: figure" cell. `after` is NAN when there is nothing to compare against —
# chosen over a second bool because a comparison whose figure is genuinely absent and a
# plain row are the same case here, and NAN can never collide with a real stat value.
static func _row(id: String, before: float, after: float) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var key := UITheme.label("%s:" % CarStats.label_for(id), "dim")
	row.add_child(key)

	var before_text := CarStats.format(id, before)
	if is_nan(after) or CarStats.format(id, after) == before_text:
		# Plain mode, and the unchanged-stat case described in the header — one figure,
		# no arrow, no colour.
		row.add_child(UITheme.label(before_text))
		return row

	# The change's direction decides which SIDE is green: the improved figure is green
	# and the one given up is red, whichever way round the stat runs. A NEUTRAL stat
	# (CarStats.change answers 0 for it) still reaches here when its value moved — the
	# drivetrain going RWD -> AWD is a real change with no better or worse — so it draws
	# both sides plain.
	var change := CarStats.change(id, before, after)
	var before_role := "ink"
	var after_role := "ink"
	if change > 0:
		before_role = "red"
		after_role = "green"
	elif change < 0:
		before_role = "green"
		after_role = "red"
	row.add_child(UITheme.label(before_text, before_role))
	row.add_child(UITheme.label(ARROW, "dim"))
	row.add_child(UITheme.label(CarStats.format(id, after), after_role))
	return row
