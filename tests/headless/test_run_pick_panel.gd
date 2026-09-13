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
	var page := RunPickPanel.open_pick(_host, pick, true, func(_x: String) -> void: pass)
	assert_not_null(MenuNav.of(page), "keyboard/gamepad navigable")
	assert_eq(_carousel(page).card_count(), 3, "repair + handling + power")


func test_open_pick_omits_repair_when_not_offered() -> void:
	var pick := _pick(["grip", "gearbox"])
	var page := RunPickPanel.open_pick(_host, pick, false, func(_x: String) -> void: pass)
	assert_eq(_carousel(page).card_count(), 2, "handling + power, no repair card")


func test_confirming_repair_reports_repair() -> void:
	var choices: Array = []
	var pick := _pick(["grip", "gearbox"])
	var page := RunPickPanel.open_pick(_host, pick, true,
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
		var page := RunPickPanel.open_pick(_host, pick, true,
			func(choice: String) -> void: choices.append(choice))
		var carousel := _carousel(page)
		carousel.confirmed.emit(1)
		carousel.confirmed.emit(2)
		assert_true(handling_ids.has(String(choices[0])),
			"handling winner '%s' came from the handling entries" % choices[0])
		assert_true(power_ids.has(String(choices[1])),
			"power winner '%s' came from the power entries" % choices[1])
		page.queue_free()


func test_a_category_with_nothing_to_roll_is_disabled() -> void:
	var pick := _pick(["grip", "aero"])  # both handling, nothing for power
	var page := RunPickPanel.open_pick(_host, pick, true, func(_x: String) -> void: pass)
	var carousel := _carousel(page)
	assert_false(carousel.get_card(1).disabled, "handling has entries")
	assert_true(carousel.get_card(2).disabled, "power has nothing to roll")


func test_a_drivetrain_entry_can_be_the_pre_rolled_handling_winner() -> void:
	var pick := _pick(["gearbox"])
	pick.append(_drivetrain_entry(Drivetrain.DriveMode.AWD))
	var choices: Array = []
	var page := RunPickPanel.open_pick(_host, pick, false,
		func(choice: String) -> void: choices.append(choice))
	var carousel := _carousel(page)
	carousel.confirmed.emit(0)  # only one handling entry, so it's always the winner
	assert_eq(choices, ["drivetrain:%d" % Drivetrain.DriveMode.AWD])


func test_an_engine_swap_entry_can_be_the_pre_rolled_power_winner() -> void:
	var pick := _pick(["grip"])
	pick.append(_engine_swap_entry("fx_v8", 300.0, 100.0))
	var choices: Array = []
	var page := RunPickPanel.open_pick(_host, pick, false,
		func(choice: String) -> void: choices.append(choice))
	var carousel := _carousel(page)
	carousel.confirmed.emit(1)  # only one power entry, so it's always the winner
	assert_eq(choices, ["engine_swap:fx_v8"])


# --- Builds with no world scene ------------------------------------------------------

func test_builds_with_no_world_scene() -> void:
	# Nothing above touches $Car, world.gd or the replay machinery — the whole suite runs
	# against a bare Control host, which is the point: proven here explicitly so a future
	# change that sneaks in a world/scene dependency fails loudly.
	var page := RunPickPanel.open_continue(_host, func(_x: String) -> void: pass)
	assert_not_null(page)
