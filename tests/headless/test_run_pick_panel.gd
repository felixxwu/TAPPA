extends GutTest
# RunPickPanel (scripts/run_pick_panel.gd) — the between-stage MODAL (repair vs. a
# drawn boost, or a bare Continue), replacing the deleted standings.tscn interstitial
# (todo/roguelike-pivot.md "Between stages: repair or boost", stage 5).
#
# THE NAV TEST CLAUDE.md requires of every menu: keyboard/gamepad reachability via
# MenuNav.attach, on a Control host with no world/scene needed at all — this panel is
# deliberately decoupled from world.gd/$Car/the replay machinery for exactly this
# reason (see the class doc).
#
# A non-empty pick renders as a CardCarousel now (CardUI, the same shape the hub's own
# pages use) rather than a Button per row — the Continue-only shape is unchanged.

var _host: Control


func before_each() -> void:
	_host = Control.new()
	add_child_autofree(_host)


# The one focusable control on a Continue-only page (no carousel involved).
func _continue_button(page: MenuPage) -> Button:
	for node in page.find_children("*", "Button", true, false):
		if (node as Button).focus_mode != Control.FOCUS_NONE:
			return node as Button
	return null


func _carousel(page: MenuPage) -> CardCarousel:
	var found := page.find_children("*", "CardCarousel", true, false)
	return (found[0] as CardCarousel) if not found.is_empty() else null


# Synthetic pick entries — a plain {id, effect} dict is all RunPickPanel reads (see
# open()'s pick loop), so there is no need to depend on a real catalogue boost existing.
func _pick(ids: Array) -> Array:
	var out: Array = []
	for id in ids:
		out.append({"id": id, "effect": {}})
	return out


# --- Navigation (the CLAUDE.md contract) ------------------------------------------

func test_a_pick_page_is_keyboard_navigable() -> void:
	var page := RunPickPanel.open(_host, _pick(["a", "b"]), func(_x: String) -> void: pass)
	assert_not_null(MenuNav.of(page), "the pick page has a MenuNav attached")
	var carousel := _carousel(page)
	assert_not_null(carousel, "the non-empty pick renders as a carousel")
	assert_gt(carousel.card_count(), 0, "the pick page offers at least one card")


func test_a_plain_continue_page_is_keyboard_navigable() -> void:
	var page := RunPickPanel.open(_host, [], func(_x: String) -> void: pass)
	assert_not_null(MenuNav.of(page), "the continue-only page has a MenuNav attached")
	assert_not_null(_continue_button(page), "the continue-only page offers a focusable control")


# Nav reaches every enabled card and a disabled one cannot land a confirm.
func test_nav_reaches_every_enabled_card_and_skips_a_disabled_one() -> void:
	var page := RunPickPanel.open(_host, _pick(["a", "b"]), func(_x: String) -> void: pass,
		false)  # no repair card offered — nothing disabled in this shape to begin with
	var carousel := _carousel(page)
	assert_eq(carousel.card_count(), 2)
	for i in carousel.card_count():
		assert_false(carousel.get_card(i).disabled, "every drawn-boost card is enabled")
	# A disabled card never fires confirmed (card_carousel.gd _confirm_selected) — proven
	# directly rather than by faking a disabled catalogue entry this file has no business
	# authoring.
	var fired: Array = []
	carousel.confirmed.connect(func(i: int) -> void: fired.append(i))
	carousel.get_card(0).disabled = true
	carousel.select(0, false)
	carousel._confirm_selected()
	assert_eq(fired, [], "a disabled card cannot land a confirm")


# --- Shape: a card per boost, plus repair (when offered), plus conversions --------

func test_a_non_empty_pick_offers_repair_plus_one_card_per_boost() -> void:
	var page := RunPickPanel.open(_host, _pick(["a", "b", "c"]), func(_x: String) -> void: pass)
	assert_eq(_carousel(page).card_count(), 4, "3 boosts + the repair card")


func test_offer_repair_false_omits_the_repair_card() -> void:
	var page := RunPickPanel.open(_host, _pick(["a", "b", "c"]), func(_x: String) -> void: pass,
		false)
	assert_eq(_carousel(page).card_count(), 3, "3 boosts, no repair card when not offered")


func test_offer_repair_defaults_true_for_existing_callers() -> void:
	var page := RunPickPanel.open(_host, _pick(["a"]), func(_x: String) -> void: pass)
	assert_eq(_carousel(page).card_count(), 2, "1 boost + repair, offer_repair defaults true")


func test_an_empty_pick_offers_only_continue() -> void:
	var page := RunPickPanel.open(_host, [], func(_x: String) -> void: pass)
	assert_null(_carousel(page), "the empty-pick shape has no carousel at all")
	assert_not_null(_continue_button(page))


# --- Confirming a card reports the choice, and nothing more -----------------------

func test_confirming_the_repair_card_reports_repair() -> void:
	var choices: Array = []
	var page := RunPickPanel.open(_host, _pick(["a"]),
		func(choice: String) -> void: choices.append(choice))
	var carousel := _carousel(page)
	# Repair is added first (see open()'s own ordering).
	carousel.confirmed.emit(0)
	assert_eq(choices, ["repair"])


# A boost card shows the purchased level it will draw at (1-based, hub_shell.gd's own
# "Lv %d" convention) so the player can tell "Grip" apart from an upgraded "Grip Lv 2".
func test_a_boost_card_shows_its_level() -> void:
	var page := RunPickPanel.open(_host, _pick(["fx_boost_x"]),
		func(_x: String) -> void: pass, false)
	var card := _carousel(page).get_card(0)
	var labels := card.info.find_children("*", "Label", true, false)
	var texts: Array[String] = []
	for label in labels:
		texts.append((label as Label).text)
	# UITheme.label() uppercases everything it's given (rule 2's house style), so the
	# rendered text reads "LV 1", not "Lv 1" — the level shown is still 1-based underneath.
	assert_true(texts.has("LV 1"), "an un-upgraded boost reads Lv 1, never Lv 0")


func test_confirming_a_boost_card_reports_its_id() -> void:
	var choices: Array = []
	var page := RunPickPanel.open(_host, _pick(["fx_boost_x"]),
		func(choice: String) -> void: choices.append(choice), false)
	var carousel := _carousel(page)
	assert_eq(carousel.card_count(), 1)
	carousel.confirmed.emit(0)
	assert_eq(choices, ["fx_boost_x"])


func test_pressing_continue_reports_an_empty_choice() -> void:
	var choices: Array = []
	var page := RunPickPanel.open(_host, [],
		func(choice: String) -> void: choices.append(choice))
	_continue_button(page).pressed.emit()
	assert_eq(choices, [""])


# --- Drivetrain conversion: rendered from a `pick` entry, same as a boost ---------
#
# A conversion is no longer a separate list appended on top — it's an entry the CALLER
# (RunSession.pending_pick(), via the merged BoostLibrary.draw_from_ids pool) already
# drew INTO `pick` itself, shaped {"id": "drivetrain:<mode>", "drivetrain_mode": mode}.
# This file only proves the panel renders/reports whichever shape a `pick` entry has.

func _drivetrain_entry(mode: int) -> Dictionary:
	return {"id": "drivetrain:%d" % mode, "drivetrain_mode": mode}


# Same idea for the engine swap: RunSession._with_engine_swap_display already stamps
# "hp"/"hp_delta" onto the drawn entry before RunPickPanel ever sees it — this file only
# proves the panel renders/reports whichever shape it's handed.
func _engine_swap_entry(engine_id: String, hp: float, hp_delta: float) -> Dictionary:
	return {"id": "engine_swap:%s" % engine_id, "engine_id": engine_id, "hp": hp, "hp_delta": hp_delta}


func test_a_drivetrain_pick_entry_adds_one_card_and_stays_navigable() -> void:
	var pick := _pick(["a"])
	pick.append(_drivetrain_entry(Drivetrain.DriveMode.AWD))
	var page := RunPickPanel.open(_host, pick, func(_x: String) -> void: pass)
	assert_eq(_carousel(page).card_count(), 3, "1 boost + repair + 1 conversion card")
	assert_not_null(MenuNav.of(page), "still keyboard/gamepad navigable with a conversion card")


func test_confirming_a_drivetrain_card_reports_its_mode() -> void:
	var choices: Array = []
	var pick := _pick(["a"])
	pick.append(_drivetrain_entry(Drivetrain.DriveMode.AWD))
	var page := RunPickPanel.open(_host, pick,
		func(choice: String) -> void: choices.append(choice), false)
	var carousel := _carousel(page)
	# boost, then the one conversion (repair omitted here).
	carousel.confirmed.emit(1)
	assert_eq(choices, ["drivetrain:%d" % Drivetrain.DriveMode.AWD])


func test_no_drivetrain_entry_offers_no_conversion_card() -> void:
	var page := RunPickPanel.open(_host, _pick(["a"]), func(_x: String) -> void: pass)
	assert_eq(_carousel(page).card_count(), 2, "just the boost and repair — no conversion drawn")


# --- The engine swap entry ---------------------------------------------------------

func test_an_engine_swap_pick_entry_adds_one_card_and_stays_navigable() -> void:
	var pick := _pick(["a"])
	pick.append(_engine_swap_entry("fx_v8", 300.0, 100.0))
	var page := RunPickPanel.open(_host, pick, func(_x: String) -> void: pass)
	assert_eq(_carousel(page).card_count(), 3, "1 boost + repair + 1 engine swap card")
	assert_not_null(MenuNav.of(page), "still keyboard/gamepad navigable with an engine swap card")


func test_confirming_an_engine_swap_card_reports_its_id() -> void:
	var choices: Array = []
	var pick := _pick(["a"])
	pick.append(_engine_swap_entry("fx_v8", 300.0, 100.0))
	var page := RunPickPanel.open(_host, pick,
		func(choice: String) -> void: choices.append(choice), false)
	var carousel := _carousel(page)
	# boost, then the one engine swap (repair omitted here).
	carousel.confirmed.emit(1)
	assert_eq(choices, ["engine_swap:fx_v8"])


func test_no_engine_swap_entry_offers_no_swap_card() -> void:
	var page := RunPickPanel.open(_host, _pick(["a"]), func(_x: String) -> void: pass)
	assert_eq(_carousel(page).card_count(), 2, "just the boost and repair — no swap drawn")


# --- Builds with no world scene ----------------------------------------------------

func test_builds_with_no_world_scene() -> void:
	# Nothing above touches $Car, world.gd or the replay machinery — the whole suite runs
	# against a bare Control host, which is the point: proven here explicitly so a future
	# change that sneaks in a world/scene dependency fails loudly.
	var page := RunPickPanel.open(_host, _pick(["a"]), func(_x: String) -> void: pass)
	assert_not_null(page)
