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
#   * non-empty — a CardCarousel (CardUI, the same card shape the hub's pages use): one
#     card per drawn boost, PLUS a repair card when `offer_repair` says the car needs one,
#     PLUS one card per available drivetrain conversion (repair and the conversions are
#     never one of `pick`'s own entries — they don't go through the boost effects funnel,
#     so neither is a BoostLibrary id). Confirming any card is the whole interaction: it
#     both CHOOSES and REPORTS the choice in one press ("the player picks exactly one" —
#     there is nothing left to confirm).
#   * empty — every mode that doesn't offer a pick (the challenge) and this run's own
#     final/failed stage (report_event_result never draws one then) get a bare
#     Continue action instead.
#
# `on_choice` is called with "repair", a boost id, "drivetrain:<DriveMode int>", or ""
# (plain Continue) the instant a card is confirmed / Continue is pressed. This class does
# not know what happens next — RunSession.choose_repair / choose_boost / choose_drivetrain /
# continue_to_next_stage all live one level up, in world.gd, which owns applying the pick
# and advancing (or ending) the run. The CALLER also owns tearing the panel down — free
# `page.get_parent()` when the pick/Continue is done. (A stats-confirmation step is planned
# on top of this — on_choice reporting the choice, separate from the caller's teardown, is
# what leaves room for that without this file changing.)


# Build and return the modal, hosted on `host` via MenuPage.open_modal (see that
# function's own doc for why a modal must always go through it). `drivetrain_choices` is
# RunSession.drivetrain_choices() — the DriveMode ints worth offering as a conversion right
# now, [] when none is drawn (mirrors `pick`'s own empty contract). `offer_repair` is the
# caller's own "does the car need one" decision (RunSession/world.gd) — this class does not
# look at car health itself, so a healthy car simply passes false and gets no repair card.
static func open(host: Node, pick: Array, on_choice: Callable,
		drivetrain_choices: Array = [], offer_repair: bool = true) -> MenuPage:
	var title := "Choose a boost" if not pick.is_empty() else "Stage complete"
	var page := MenuPage.open_modal(host, {"margin": 24.0, "title": title})
	if pick.is_empty():
		var continue_btn := UITheme.button("Continue")
		continue_btn.pressed.connect(func() -> void: on_choice.call(""))
		page.add_action(continue_btn)
	else:
		var carousel := CardUI.build_carousel(page)
		# Parallel to the carousel's cards: the payload string `on_choice` gets when that
		# card is confirmed.
		var payloads: Array[String] = []
		if offer_repair:
			CardUI.text_card(carousel, "Repair the car", "", false, "repair")
			payloads.append("repair")
		for entry in pick:
			var id := String((entry as Dictionary).get("id", ""))
			# icons/cards/ is already keyed by boost/skill id — the same catalogue the hub's
			# shop cards draw from — so the boost id doubles as the icon name; an id with no
			# authored icon (a test fixture's synthetic id) falls back to generic.svg inside
			# CardUI.card_icon.
			CardUI.text_card(carousel, BoostLibrary.label_for(id), "", false, id)
			payloads.append(id)
		for mode in drivetrain_choices:
			var mode_int := int(mode)
			CardUI.text_card(carousel, "Convert to %s" % Drivetrain.DriveMode.keys()[mode_int],
				"", false, "drivetrain")
			payloads.append("drivetrain:%d" % mode_int)
		carousel.confirmed.connect(func(i: int) -> void: on_choice.call(payloads[i]))
	MenuNav.attach(page, {})
	return page
