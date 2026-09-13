extends GutTest
# RunPickPanel (scripts/run_pick_panel.gd) — the between-stage MODAL: one card list per
# stage, up to three cards (repair, a pre-rolled handling upgrade, a pre-rolled power
# upgrade), or a bare Continue when RunSession has nothing pending.
#
# THE NAV TEST CLAUDE.md requires of every menu: keyboard/gamepad reachability via
# MenuNav.attach, on a Control host with no world/scene needed at all — every builder
# below is deliberately decoupled from world.gd/$Car/the replay machinery for exactly
# this reason (see the class doc).

var _host: Control


func before_each() -> void:
	Config.reset()
	_host = Control.new()
	add_child_autofree(_host)


func after_each() -> void:
	Config.reset()


func _carousel(page: MenuPage) -> CardCarousel:
	var found := page.find_children("*", "CardCarousel", true, false)
	return (found[0] as CardCarousel) if not found.is_empty() else null


# Synthetic pick entries — a plain {id, effect} dict is all the panel reads for a
# catalogue boost, so there is no need to depend on a real catalogue entry existing.
# Ids default to real handling/power catalogue members so BoostLibrary.category_of
# classifies them without a fixture.
func _pick(ids: Array) -> Array:
	var out: Array = []
	for id in ids:
		out.append({"id": id, "effect": {}})
	return out


func _drivetrain_entry(mode: int) -> Dictionary:
	return {"id": "drivetrain:%d" % mode, "drivetrain_mode": mode}


func _engine_swap_entry(engine_id: String, hp: float, hp_delta: float) -> Dictionary:
	return {"id": "engine_swap:%s" % engine_id, "engine_id": engine_id, "hp": hp, "hp_delta": hp_delta}


# --- open_continue -----------------------------------------------------------------

func test_open_continue_is_keyboard_navigable() -> void:
	var page := RunPickPanel.open_continue(_host, func(_x: String) -> void: pass)
	assert_not_null(MenuNav.of(page), "the continue page has a MenuNav attached")
	assert_eq(_carousel(page).card_count(), 1, "one Continue card")


func test_confirming_continue_reports_an_empty_choice() -> void:
	var choices: Array = []
	var page := RunPickPanel.open_continue(_host, func(choice: String) -> void: choices.append(choice))
	_carousel(page).confirmed.emit(0)
	assert_eq(choices, [""])


# --- open_pick -----------------------------------------------------------------------

func test_open_pick_offers_three_navigable_cards_when_repair_is_offered() -> void:
	var pick := _pick(["grip", "gearbox"])
	var page := RunPickPanel.open_pick(_host, pick, true, 1.0, func(_x: String) -> void: pass)
	assert_not_null(MenuNav.of(page), "keyboard/gamepad navigable")
	assert_eq(_carousel(page).card_count(), 3, "repair + handling + power")


func test_open_pick_omits_repair_when_not_offered() -> void:
	var pick := _pick(["grip", "gearbox"])
	var page := RunPickPanel.open_pick(_host, pick, false, 1.0, func(_x: String) -> void: pass)
	assert_eq(_carousel(page).card_count(), 2, "handling + power, no repair card")


func test_confirming_repair_reports_repair() -> void:
	var choices: Array = []
	var pick := _pick(["grip", "gearbox"])
	var page := RunPickPanel.open_pick(_host, pick, true, 1.0,
		func(choice: String) -> void: choices.append(choice))
	_carousel(page).confirmed.emit(0)
	assert_eq(choices, ["repair"])


# The rolled handling/power winners must always come from the entries actually passed in
# for that category — never the other category's, never an id not in `pick`. Repeated
# since randi() is not seeded/controllable from here.
func test_the_rolled_winners_always_come_from_their_own_category() -> void:
	var pick := _pick(["grip", "aero", "gearbox"])
	var handling_ids := ["grip", "aero"]
	var power_ids := ["gearbox"]
	for _i in 20:
		var choices: Array = []
		var page := RunPickPanel.open_pick(_host, pick, true, 1.0,
			func(choice: String) -> void: choices.append(choice))
		var carousel := _carousel(page)
		carousel.confirmed.emit(1)  # 1st confirm on a pending card only reveals it
		carousel.confirmed.emit(1)  # 2nd confirm actually picks it
		carousel.confirmed.emit(2)
		carousel.confirmed.emit(2)
		assert_true(handling_ids.has(String(choices[0])),
			"handling winner '%s' came from the handling entries" % choices[0])
		assert_true(power_ids.has(String(choices[1])),
			"power winner '%s' came from the power entries" % choices[1])
		page.queue_free()


# --- "?" reveal ----------------------------------------------------------------------

func _card_title(carousel: CardCarousel, index: int) -> String:
	var info := carousel.get_card(index).info
	return (info.get_child(0) as Label).text


func test_pre_rolled_cards_start_face_down() -> void:
	var pick := _pick(["grip", "gearbox"])
	var page := RunPickPanel.open_pick(_host, pick, true, 1.0, func(_x: String) -> void: pass)
	var carousel := _carousel(page)
	assert_eq(_card_title(carousel, 1), "?", "handling card starts face-down")
	assert_eq(_card_title(carousel, 2), "?", "power card starts face-down")


func test_merely_selecting_a_pending_card_does_not_reveal_it() -> void:
	# Navigating onto a "?" card (arrow keys/gamepad, or a tap that only re-centres a
	# non-centred card) must NOT reveal it — only an actual confirm should, so a card
	# the player lands on by default is never mistaken for already being shown.
	var pick := _pick(["grip", "gearbox"])
	var page := RunPickPanel.open_pick(_host, pick, true, 1.0, func(_x: String) -> void: pass)
	var carousel := _carousel(page)
	carousel.select(1, false)
	assert_eq(_card_title(carousel, 1), "?", "mere selection does not reveal the card")


func test_the_first_confirm_on_a_pending_card_only_reveals_it() -> void:
	var pick := _pick(["grip", "gearbox"])
	var choices: Array = []
	var page := RunPickPanel.open_pick(_host, pick, true, 1.0,
		func(choice: String) -> void: choices.append(choice))
	var carousel := _carousel(page)
	carousel.confirmed.emit(1)
	assert_ne(_card_title(carousel, 1), "?", "the card is revealed")
	assert_eq(choices, [], "the first confirm on a '?' card is consumed, not reported as a choice")


func test_the_second_confirm_on_a_revealed_card_reports_the_same_winner_it_showed() -> void:
	var pick := _pick(["grip", "gearbox"])
	var choices: Array = []
	var page := RunPickPanel.open_pick(_host, pick, true, 1.0,
		func(choice: String) -> void: choices.append(choice))
	var carousel := _carousel(page)
	carousel.confirmed.emit(1)  # reveal
	carousel.confirmed.emit(1)  # actually pick
	assert_eq(choices, ["grip"], "the revealed card and the confirmed winner are the same draw")


func test_a_card_landed_on_by_default_still_needs_two_confirms() -> void:
	# No repair card offered, so the handling slot (index 0) starts centred/selected
	# from the very first frame with no navigation at all — it must still take a
	# reveal confirm before a second confirm can pick it.
	var pick := _pick(["grip", "gearbox"])
	var choices: Array = []
	var page := RunPickPanel.open_pick(_host, pick, false, 1.0,
		func(choice: String) -> void: choices.append(choice))
	var carousel := _carousel(page)
	assert_eq(_card_title(carousel, 0), "?", "the default-selected card still starts face-down")
	carousel.confirmed.emit(0)
	assert_eq(choices, [], "confirming the default-selected card the first time only reveals it")
	carousel.confirmed.emit(0)
	assert_eq(choices, ["grip"], "the second confirm picks it")


func _card_subtitle(carousel: CardCarousel, index: int) -> String:
	return (carousel.get_card(index).info.get_child(1) as Label).text


func test_repair_card_states_the_actual_before_and_after_health() -> void:
	var pick := _pick(["grip", "gearbox"])
	var page := RunPickPanel.open_pick(_host, pick, true, 0.62, func(_x: String) -> void: pass)
	assert_eq(_card_subtitle(_carousel(page), 0), "62% -> 100%")


func test_a_revealed_boost_card_states_its_effect() -> void:
	var pick := _pick(["grip", "gearbox"])
	var page := RunPickPanel.open_pick(_host, pick, false, 1.0, func(_x: String) -> void: pass)
	var carousel := _carousel(page)
	carousel.confirmed.emit(1)  # reveal the power slot ("gearbox") — first confirm only
	var expected := "Lv %d, %s" % [Save.boost_level("gearbox") + 1, BoostLibrary.current_effect_text_for("gearbox")]
	assert_eq(_card_subtitle(carousel, 1), expected.to_upper(), "UITheme.label uppercases every subtitle")


func test_a_category_with_nothing_to_roll_is_disabled() -> void:
	var pick := _pick(["grip", "aero"])  # both handling, nothing for power
	var page := RunPickPanel.open_pick(_host, pick, true, 1.0, func(_x: String) -> void: pass)
	var carousel := _carousel(page)
	assert_false(carousel.get_card(1).disabled, "handling has entries")
	assert_true(carousel.get_card(2).disabled, "power has nothing to roll")


func test_a_drivetrain_entry_can_be_the_pre_rolled_handling_winner() -> void:
	var pick := _pick(["gearbox"])
	pick.append(_drivetrain_entry(Drivetrain.DriveMode.AWD))
	var choices: Array = []
	var page := RunPickPanel.open_pick(_host, pick, false, 1.0,
		func(choice: String) -> void: choices.append(choice))
	var carousel := _carousel(page)
	carousel.confirmed.emit(0)  # reveal — only one handling entry, so it's always the winner
	carousel.confirmed.emit(0)  # pick
	assert_eq(choices, ["drivetrain:%d" % Drivetrain.DriveMode.AWD])


func test_an_engine_swap_entry_can_be_the_pre_rolled_power_winner() -> void:
	var pick := _pick(["grip"])
	pick.append(_engine_swap_entry("fx_v8", 300.0, 100.0))
	var choices: Array = []
	var page := RunPickPanel.open_pick(_host, pick, false, 1.0,
		func(choice: String) -> void: choices.append(choice))
	var carousel := _carousel(page)
	carousel.confirmed.emit(1)  # reveal — only one power entry, so it's always the winner
	carousel.confirmed.emit(1)  # pick
	assert_eq(choices, ["engine_swap:fx_v8"])


# --- Builds with no world scene ------------------------------------------------------

func test_builds_with_no_world_scene() -> void:
	# Nothing above touches $Car, world.gd or the replay machinery — the whole suite runs
	# against a bare Control host, which is the point: proven here explicitly so a future
	# change that sneaks in a world/scene dependency fails loudly.
	var page := RunPickPanel.open_continue(_host, func(_x: String) -> void: pass)
	assert_not_null(page)
