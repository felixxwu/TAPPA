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
#     card per entry in `pick`, PLUS a repair card when `offer_repair` says the car needs
#     one. `pick` (RunSession.pending_pick()) is drawn from ONE merged pool — the boost
#     catalogue plus, when available, an AWD conversion pseudo-entry and/or a next-rung-up
#     engine swap pseudo-entry — so an entry is EITHER a BoostLibrary id (`{"id", "effect"}`)
#     OR a drivetrain conversion (`{"id": "drivetrain:<DriveMode int>", "drivetrain_mode":
#     ...}`) OR an engine swap (`{"id": "engine_swap:<EngineLibrary id>", "engine_id",
#     "hp", "hp_delta"}` — the last two stamped on by RunSession._with_engine_swap_display);
#     this file renders whichever shape it's handed rather than sourcing extras from a
#     second list.
#     A boost card's subtitle shows its purchased level 1-based ("Lv %d", Save.boost_level(id)
#     + 1 — hub_shell.gd's own convention: an un-upgraded boost is level 0 in Save but
#     draws its level-1 magnitude, so it reads "Lv 1", never "Lv 0"). Confirming any card
#     is the whole interaction: it both CHOOSES and REPORTS the choice in one press ("the
#     player picks exactly one" — there is nothing left to confirm).
#   * empty — every mode that doesn't offer a pick (the challenge) and this run's own
#     final/failed stage (report_event_result never draws one then) get a bare
#     Continue action instead.
#
# `on_choice` is called with "repair", a boost id, "drivetrain:<DriveMode int>",
# "engine_swap:<EngineLibrary id>", or "" (plain Continue) the instant a card is confirmed
# / Continue is pressed. This class does not know what happens next —
# RunSession.choose_repair / choose_boost / choose_drivetrain / choose_engine_swap /
# continue_to_next_stage all live one level up, in world.gd, which owns applying the pick
# and advancing (or ending) the run. The CALLER also owns tearing the panel down — free
# `page.get_parent()` when the pick/Continue is done. (A stats-confirmation step is planned
# on top of this — on_choice reporting the choice, separate from the caller's teardown, is
# what leaves room for that without this file changing.)
#
# The page's own backdrop is deliberately TRANSPARENT (alpha 0.0, below) so the 3D world
# shows through the gaps between cards — each card keeps its own opaque background
# (card_carousel.gd's _card_stylebox, UITheme.panel_box(1.0)), so legibility is unaffected.


# Build and return the modal, hosted on `host` via MenuPage.open_modal (see that
# function's own doc for why a modal must always go through it). `offer_repair` is the
# caller's own "does the car need one" decision (RunSession/world.gd) — this class does not
# look at car health itself, so a healthy car simply passes false and gets no repair card.
static func open(host: Node, pick: Array, on_choice: Callable,
		offer_repair: bool = true) -> MenuPage:
	var title := "Choose a boost" if not pick.is_empty() else "Stage complete"
	var page := MenuPage.open_modal(host, {"margin": 24.0, "title": title, "alpha": 0.0})
	if pick.is_empty():
		var continue_btn := UITheme.button("Continue")
		continue_btn.pressed.connect(func() -> void: on_choice.call(""))
		page.add_action(continue_btn)
	else:
		# This page was opened with a real 24px margin (above) and MenuPage's default body
		# padding, NOT CardUI's edge-to-edge defaults (0/0, what hub_shell.gd's carousel
		# pages use) — build_carousel must be told that explicitly, or it claims more width
		# than this page's own clip_contents actually leaves visible.
		var carousel := CardUI.build_carousel(page, 24.0, UITheme.PANEL_PAD)
		# Parallel to the carousel's cards: the payload string `on_choice` gets when that
		# card is confirmed.
		var payloads: Array[String] = []
		if offer_repair:
			CardUI.text_card(carousel, "Repair the car", "", false, "repair")
			payloads.append("repair")
		for entry in pick:
			var id := String((entry as Dictionary).get("id", ""))
			if id.begins_with("drivetrain:"):
				var mode_int := int(id.substr("drivetrain:".length()))
				CardUI.text_card(carousel, "Convert to %s" % Drivetrain.DriveMode.keys()[mode_int],
					"", false, "drivetrain")
			elif id.begins_with("engine_swap:"):
				# RunSession._with_engine_swap_display already stamped "hp"/"hp_delta" onto
				# this entry — title reads e.g. "250HP V6" (hp + the donor's layout label,
				# EngineSwap.layout_label already uppercased/stripped so UITheme.label's own
				# uppercasing is a no-op here), subtitle "+100 HP" (the delta over the car's
				# current engine, always positive — _pool_engine_swap_ids only ever offers a
				# STRICTLY more powerful engine).
				var engine_id := String((entry as Dictionary).get("engine_id", ""))
				var hp := int(round(float((entry as Dictionary).get("hp", 0.0))))
				var hp_delta := int(round(float((entry as Dictionary).get("hp_delta", 0.0))))
				var layout := EngineSwap.layout_label(engine_id)
				var card_title := "%dHP %s" % [hp, layout] if not layout.is_empty() else "%dHP" % hp
				CardUI.text_card(carousel, card_title, "+%d HP" % hp_delta, false, "engine_swap")
			else:
				# icons/cards/ is already keyed by boost/skill id — the same catalogue the
				# hub's shop cards draw from — so the boost id doubles as the icon name; an
				# id with no authored icon (a test fixture's synthetic id) falls back to
				# generic.svg inside CardUI.card_icon.
				#
				# Level shown 1-based (hub_shell.gd's own "Lv %d" convention — an
				# un-upgraded boost is level 0 in Save but reads "Lv 1", the level whose
				# magnitude it actually draws), so the player sees which purchased tier
				# they're about to pick up, not just the boost's name.
				CardUI.text_card(carousel, BoostLibrary.label_for(id),
					"Lv %d" % (Save.boost_level(id) + 1), false, id)
			payloads.append(id)
		carousel.confirmed.connect(func(i: int) -> void: on_choice.call(payloads[i]))
	MenuNav.attach(page, {})
	return page
