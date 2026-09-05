class_name RunPickPanel
extends RefCounted
# Docs: features/region-runs.md — update in the same change as this file.
# Tests: tests/headless/test_run_pick_panel.gd — extend in the same change.
#
# THE BETWEEN-STAGE MODAL (todo/roguelike-pivot.md "Between stages: repair or boost",
# stage 5 of todo/roguelike-pivot-plan.md). Replaces the old per-stage leaderboard —
# `standings.tscn`, deleted with the global stage boards (decision 30) — as the thing
# `world.gd` hosts over the just-finished stage's cinematic replay.
#
# Deliberately NOT a scene, and deliberately decoupled from world.gd / $Car / the
# replay machinery: it only needs a host Node to hang a MenuPage off, the pick
# RunSession is currently offering, and a callback. That is what makes it testable
# without booting a world scene at all (CLAUDE.md's performance rules: a full
# main.tscn build costs real seconds per test; this needs none) — see
# tests/headless/test_run_pick_panel.gd, the nav test CLAUDE.md requires of every menu.
#
# Two shapes, driven entirely by whether `pick` is empty:
#   * non-empty  — a row per drawn boost, PLUS an always-present repair row, PLUS one row
#     per available drivetrain conversion (repair and the conversions are never one of
#     `pick`'s own entries — they don't go through the boost effects funnel, so neither is
#     a BoostLibrary id). Pressing any row is the whole interaction: it both CHOOSES and
#     DISMISSES in one press ("the player picks exactly one" — there is nothing left to
#     confirm).
#   * empty — every mode that doesn't offer a pick (the challenge) and this run's own
#     final/failed stage (report_event_result never draws one then) get a bare
#     Continue action instead.
#
# `on_choice` is called with "repair", a boost id, "drivetrain:<DriveMode int>", or ""
# (plain Continue) the instant a row is pressed. This class does not know what happens
# next — RunSession.choose_repair / choose_boost / choose_drivetrain / continue_to_next_stage
# all live one level up, in world.gd, which owns applying the pick and advancing (or
# ending) the run.


# Build and return the modal, hosted on `host` via MenuPage.open_modal (see that
# function's own doc for why a modal must always go through it). `drivetrain_choices` is
# RunSession.drivetrain_choices() — the DriveMode ints worth offering as a conversion right
# now, [] when none is drawn (mirrors `pick`'s own empty contract). The caller owns tearing
# the panel down — free `page.get_parent()` when the pick/Continue is done.
static func open(host: Node, pick: Array, on_choice: Callable, drivetrain_choices: Array = []) -> MenuPage:
	var title := "Choose a boost" if not pick.is_empty() else "Stage complete"
	var page := MenuPage.open_modal(host, {"margin": 24.0, "title": title})
	if pick.is_empty():
		var continue_btn := UITheme.button("Continue")
		continue_btn.pressed.connect(func() -> void: on_choice.call(""))
		page.add_action(continue_btn)
	else:
		# Buttons, not labels — MenuNav only walks focusable controls, so a label row
		# would be invisible to keyboard/gamepad nav (CLAUDE.md's menu-navigation rule).
		var repair_btn := UITheme.button("Repair the car")
		repair_btn.pressed.connect(func() -> void: on_choice.call("repair"))
		page.body().add_child(repair_btn)
		for entry in pick:
			var id := String((entry as Dictionary).get("id", ""))
			var boost_btn := UITheme.button(BoostLibrary.label_for(id))
			boost_btn.pressed.connect(func() -> void: on_choice.call(id))
			page.body().add_child(boost_btn)
		for mode in drivetrain_choices:
			var mode_int := int(mode)
			var drive_btn := UITheme.button("Convert to %s" % Drivetrain.DriveMode.keys()[mode_int])
			drive_btn.pressed.connect(func() -> void: on_choice.call("drivetrain:%d" % mode_int))
			page.body().add_child(drive_btn)
	MenuNav.attach(page, {})
	return page
