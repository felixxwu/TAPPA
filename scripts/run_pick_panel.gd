class_name RunPickPanel
extends RefCounted
# Docs: features/region-runs.md — update in the same change as this file.
# Tests: tests/headless/test_run_pick_panel.gd — extend in the same change.
#
# THE BETWEEN-STAGE MODAL (todo/roguelike-pivot.md "Between stages: repair or boost",
# stage 5). world.gd hosts this over the just-finished stage's cinematic replay — the
# same beat that used to load the now-deleted standings.tscn.
#
# Deliberately NOT a scene, and deliberately decoupled from world.gd / $Car / the
# replay machinery: every builder below only needs a host Node to hang a MenuPage off,
# the pick RunSession is currently offering, and a callback. That is what makes it
# testable without booting a world scene at all — see tests/headless/test_run_pick_panel.gd.
#
# TWO ENTRY POINTS, each returning a MenuPage built the same way (MenuPage.open_modal +
# CardUI.build_carousel + MenuNav.attach):
#
#   open_continue — no pick to offer (a challenge stage, or this run's own final/failed
#                   stage): one "Continue" card.
#   open_pick     — ONE menu, up to three cards: "Repair the car" (omitted when
#                   RunSession.offer_repair() is false — the undamaged-arrival reward),
#                   one PRE-ROLLED handling upgrade, one PRE-ROLLED power upgrade. Each
#                   upgrade card is drawn once with plain randi() from that category's
#                   pool (BoostLibrary.category_of) the instant the page is built, and
#                   disabled when the category has nothing to draw — so the player picks
#                   a DIRECTION and a specific pre-rolled option in one step, never a
#                   category followed by a separate random reveal. Nothing is committed
#                   by drawing the cards: RunSession.choose_* only runs once a card is
#                   confirmed, so an app restart before that simply reopens this menu and
#                   redraws fresh candidates with no inconsistency.
#
# `on_choice` reports a choice (the winner's id, or "repair") the instant it's made; this
# class does not know what happens next — RunSession.choose_repair/choose_boost/
# choose_drivetrain/choose_engine_swap/continue_to_next_stage all live one level up, in
# world.gd (see `_open_pick_panel`), which owns applying the pick and advancing (or
# ending) the run.
#
# The page's own backdrop is deliberately TRANSPARENT (alpha 0.0, below) so the 3D world
# shows through the gaps between cards — each card keeps its own opaque background
# (card_carousel.gd's _card_stylebox, UITheme.panel_box(1.0)), so legibility is unaffected.


const _MODAL_OPTS := {"margin": 24.0, "title": ""}


static func _open(host: Node, title: String) -> MenuPage:
	var opts := _MODAL_OPTS.duplicate()
	opts["title"] = title
	opts["alpha"] = 0.0
	return MenuPage.open_modal(host, opts)


# Step: no pick to offer at all — a bare "Continue" card (the challenge, and this run's
# own final/failed stage).
static func open_continue(host: Node, on_choice: Callable) -> MenuPage:
	var page := _open(host, "Stage complete")
	var carousel := CardUI.build_carousel(page, 24.0, UITheme.PANEL_PAD)
	CardUI.text_card(carousel, "Continue", "", false, "generic")
	carousel.confirmed.connect(func(_i: int) -> void: on_choice.call(""))
	MenuNav.attach(page, {})
	return page


# Every id in `pick` whose BoostLibrary.category_of is `category` — the pool a
# pre-rolled category card is drawn from, and what decides whether that card is
# offered at all.
static func _ids_for_category(pick: Array, category: String) -> Array[String]:
	var out: Array[String] = []
	for entry in pick:
		var id := String((entry as Dictionary).get("id", ""))
		if BoostLibrary.category_of(id) == category:
			out.append(id)
	return out


static func _entry_for_id(pick: Array, id: String) -> Dictionary:
	for entry in pick:
		if String((entry as Dictionary).get("id", "")) == id:
			return entry as Dictionary
	return {}


# One card list, up to three cards: repair (when offered), a pre-rolled handling
# upgrade, a pre-rolled power upgrade. Each upgrade is drawn once with plain randi()
# from its category's pool the instant this page is built — NOT seeded/persisted, since
# nothing is committed until the card is confirmed (RunSession.choose_* hasn't run yet),
# so an app restart before that simply reopens this menu and redraws fresh candidates
# with no inconsistency. A category with nothing to draw from is disabled rather than
# hidden, the same "locked rows stay visible" treatment every other disabled card in
# this project gets.
static func open_pick(host: Node, pick: Array, offer_repair: bool, on_choice: Callable) -> MenuPage:
	var page := _open(host, "Stage complete")
	var carousel := CardUI.build_carousel(page, 24.0, UITheme.PANEL_PAD)
	var payloads: Array[String] = []
	if offer_repair:
		CardUI.text_card(carousel, "Repair the car", "", false, "repair")
		payloads.append("repair")
	for category in ["handling", "power"]:
		var ids := _ids_for_category(pick, category)
		if ids.is_empty():
			var label := "Better Handling" if category == "handling" else "More Power"
			var icon := "grip" if category == "handling" else "gearbox"
			CardUI.text_card(carousel, label, "", true, icon)
			payloads.append("")
		else:
			var winner_id := ids[randi() % ids.size()]
			_add_pick_card(carousel, _entry_for_id(pick, winner_id))
			payloads.append(winner_id)
	carousel.confirmed.connect(func(i: int) -> void: on_choice.call(payloads[i]))
	MenuNav.attach(page, {})
	return page


# One card for `entry`, in whichever of the three pick shapes it is — a boost
# ({"id","effect"}), a drivetrain conversion ({"id","drivetrain_mode"}), or an engine
# swap ({"id","engine_id","hp","hp_delta"}). Factored out so open_pick renders exactly
# the same card shapes the rest of the game already uses for these ids.
static func _add_pick_card(carousel: CardCarousel, entry: Dictionary) -> void:
	var id := String(entry.get("id", ""))
	if id.begins_with("drivetrain:"):
		var mode_int := int(entry.get("drivetrain_mode", 0))
		CardUI.text_card(carousel, "Convert to %s" % Drivetrain.DriveMode.keys()[mode_int],
			"", false, "drivetrain")
	elif id.begins_with("engine_swap:"):
		# RunSession._with_engine_swap_display already stamped "hp"/"hp_delta" onto this
		# entry — title reads e.g. "250HP V6" (hp + the donor's layout label,
		# EngineSwap.layout_label already uppercased/stripped so UITheme.label's own
		# uppercasing is a no-op here), subtitle "+100 HP" (the delta over the car's
		# current engine, always positive — _pool_engine_swap_ids only ever offers a
		# STRICTLY more powerful engine).
		var engine_id := String(entry.get("engine_id", ""))
		var hp := int(round(float(entry.get("hp", 0.0))))
		var hp_delta := int(round(float(entry.get("hp_delta", 0.0))))
		var layout := EngineSwap.layout_label(engine_id)
		var card_title := "%dHP %s" % [hp, layout] if not layout.is_empty() else "%dHP" % hp
		CardUI.text_card(carousel, card_title, "+%d HP" % hp_delta, false, "engine_swap")
	else:
		# icons/cards/ is already keyed by boost/skill id — the same catalogue the hub's
		# shop cards draw from — so the boost id doubles as the icon name; an id with no
		# authored icon (a test fixture's synthetic id) falls back to generic.svg inside
		# CardUI.card_icon.
		#
		# Level shown 1-based (hub_shell.gd's own "Lv %d" convention — an un-upgraded
		# boost is level 0 in Save but reads "Lv 1", the level whose magnitude it
		# actually draws), so the player sees which purchased tier they're about to
		# land on, not just the boost's name.
		CardUI.text_card(carousel, BoostLibrary.label_for(id),
			"Lv %d" % (Save.boost_level(id) + 1), false, id)


