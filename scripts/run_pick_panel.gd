class_name RunPickPanel
extends RefCounted
# Docs: features/region-runs.md — update in the same change as this file.
# Tests: tests/headless/test_run_pick_panel.gd — extend in the same change.
#
# THE BETWEEN-STAGE MODAL (todo/roguelike-pivot.md "Between stages: repair or boost",
# stage 5; redesigned per todo/mid-run-upgrade-menu.md into a player-directed,
# multi-step flow). world.gd hosts this over the just-finished stage's cinematic
# replay — the same beat that used to load the now-deleted standings.tscn.
#
# Deliberately NOT a scene, and deliberately decoupled from world.gd / $Car / the
# replay machinery: every builder below only needs a host Node to hang a MenuPage off,
# the pick RunSession is currently offering, and a callback. That is what makes it
# testable without booting a world scene at all — see tests/headless/test_run_pick_panel.gd.
#
# FOUR STEPS, one builder each, each returning a MenuPage built the same way
# (MenuPage.open_modal + CardUI.build_carousel + MenuNav.attach) so every step reads as
# the same visual system ("every choice-making menu is a card list"):
#
#   open_continue         — no pick to offer (a challenge stage, or this run's own
#                            final/failed stage): one "Continue" card.
#   open_repair_or_upgrade — "Repair the car" / "Upgrade car". world.gd only calls this
#                            when RunSession.offer_repair() is true; the undamaged-arrival
#                            reward skips straight to open_category_choice instead.
#   open_category_choice  — "Better Handling" / "More Power", each disabled when that
#                            category has nothing in `pick` to roll (BoostLibrary.category_of).
#   open_roll             — the slot-machine reveal: a CardCarousel of every entry in the
#                            chosen category, a scripted spin landing on a randomly picked
#                            winner, then a Next button (disabled until the spin lands)
#                            that reports the winner's id. The winner is drawn with plain
#                            randi() — NOT seeded/persisted, since nothing is committed
#                            until Next is pressed (RunSession.choose_* hasn't run yet), so
#                            an app restart mid-roll simply restarts the flow from
#                            open_continue/open_repair_or_upgrade with no inconsistency.
#
# `on_choice`/`on_done` report a choice the instant it's made; this class does not know
# what happens next — RunSession.choose_repair/choose_boost/choose_drivetrain/
# choose_engine_swap/continue_to_next_stage all live one level up, in world.gd, which owns
# applying the pick and advancing (or ending) the run, and chains these four steps
# together (see world.gd's _open_pick_panel / _on_repair_or_upgrade / _open_category_panel
# / _open_roll_panel). The CALLER also owns tearing each step's page down before opening
# the next.
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


# Step 1: repair or upgrade. Only called when RunSession.offer_repair() is true — the
# undamaged-arrival reward pick skips this step entirely (world.gd goes straight to
# open_category_choice), matching the old panel's "no repair row" behaviour for that case.
static func open_repair_or_upgrade(host: Node, on_choice: Callable) -> MenuPage:
	var page := _open(host, "Stage complete")
	var carousel := CardUI.build_carousel(page, 24.0, UITheme.PANEL_PAD)
	CardUI.text_card(carousel, "Repair the car", "", false, "repair")
	CardUI.text_card(carousel, "Upgrade car", "", false, "generic")
	var payloads := ["repair", "upgrade"]
	carousel.confirmed.connect(func(i: int) -> void: on_choice.call(payloads[i]))
	MenuNav.attach(page, {})
	return page


# Every id in `pick` whose BoostLibrary.category_of is `category` — the pool a category
# card's roll draws from, and what decides whether that card is offered at all.
static func _ids_for_category(pick: Array, category: String) -> Array[String]:
	var out: Array[String] = []
	for entry in pick:
		var id := String((entry as Dictionary).get("id", ""))
		if BoostLibrary.category_of(id) == category:
			out.append(id)
	return out


# Step 2: the player's own choice of direction. A category can genuinely run dry within
# a run — Power exhausts once "gearbox", "turbo" and "supercharger" have each been
# picked once (all three are non-stacking, BoostLibrary.stacks(), so a repeat is
# excluded from later pools) and the engine swap has nothing left to offer (the car
# already runs the catalogue's most powerful engine). A category with nothing to roll
# is guarded the same "locked rows stay visible, disabled" way every other disabled
# card in this project is, rather than being hidden.
static func open_category_choice(host: Node, pick: Array, on_choice: Callable) -> MenuPage:
	var page := _open(host, "Choose a direction")
	var carousel := CardUI.build_carousel(page, 24.0, UITheme.PANEL_PAD)
	var handling_empty := _ids_for_category(pick, "handling").is_empty()
	var power_empty := _ids_for_category(pick, "power").is_empty()
	CardUI.text_card(carousel, "Better Handling", "", handling_empty, "grip")
	CardUI.text_card(carousel, "More Power", "", power_empty, "gearbox")
	var payloads := ["handling", "power"]
	carousel.confirmed.connect(func(i: int) -> void: on_choice.call(payloads[i]))
	MenuNav.attach(page, {})
	return page


# One card for `entry`, in whichever of the three pick shapes it is — a boost
# ({"id","effect"}), a drivetrain conversion ({"id","drivetrain_mode"}), or an engine
# swap ({"id","engine_id","hp","hp_delta"}). Factored out so open_roll renders exactly
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


# Step 3: the roll. Builds a carousel of every `pick` entry in `category`, picks a
# winner with plain randi() (see class doc for why this is safe to leave unseeded), then
# spins toward it. The carousel is DECORATIVE ONLY here — focus_mode/mouse_filter are
# turned off so a player can't nudge the highlight off the winner mid- or post-spin; the
# only interactive control on this page is the Next button (disabled until the spin
# lands), which reports the winner's id via `on_done` the instant it's pressed. No
# `on_back`: the roll cannot be cancelled once a category is chosen — "the upgrade has
# been randomly chosen, the user has no choice" (todo/mid-run-upgrade-menu.md).
static func open_roll(host: Node, pick: Array, category: String, on_done: Callable) -> MenuPage:
	var entries: Array[Dictionary] = []
	for entry in pick:
		if BoostLibrary.category_of(String((entry as Dictionary).get("id", ""))) == category:
			entries.append(entry as Dictionary)
	var page := _open(host, "Rolling...")
	var carousel := CardUI.build_carousel(page, 24.0, UITheme.PANEL_PAD)
	carousel.focus_mode = Control.FOCUS_NONE
	carousel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for entry in entries:
		_add_pick_card(carousel, entry)
	var winner_index := randi() % entries.size() if entries.size() > 1 else 0
	var winner_id := String(entries[winner_index].get("id", "")) if not entries.is_empty() else ""
	var next_btn := UITheme.button("Next")
	var spinning := entries.size() > 1
	next_btn.disabled = spinning
	next_btn.pressed.connect(func() -> void: on_done.call(winner_id))
	page.add_action(next_btn)
	MenuNav.attach(page, {"first": next_btn})
	if spinning:
		_spin(carousel, winner_index, func() -> void: next_btn.disabled = false)
	elif not entries.is_empty():
		carousel.select(winner_index, false)
	return page


# The spin: `Config.data.upgrade_roll_spin_ticks` steps of CardCarousel.select(idx, true),
# each landing one card closer to `winner_index` (wrapping through the carousel like a
# real reel), with a GROWING interval between ticks (0.4x -> 1.6x of the even share of
# `upgrade_roll_spin_duration_s`) so the spin visibly decelerates into the landing rather
# than stopping abruptly. `on_finished` fires once the tween reaches the winner.
static func _spin(carousel: CardCarousel, winner_index: int, on_finished: Callable) -> void:
	var n := carousel.card_count()
	var ticks: int = maxi(1, Config.data.upgrade_roll_spin_ticks)
	var total: float = Config.data.upgrade_roll_spin_duration_s
	var tween := carousel.create_tween()
	for i in ticks:
		var idx := winner_index - (ticks - 1 - i)
		idx = ((idx % n) + n) % n
		var frac := float(i + 1) / float(ticks)
		var interval := (total / float(ticks)) * (0.4 + 1.2 * frac)
		tween.tween_callback(carousel.select.bind(idx, true))
		tween.tween_interval(interval)
	tween.tween_callback(on_finished)
