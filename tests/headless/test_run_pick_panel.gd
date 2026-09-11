extends GutTest
# RunPickPanel (scripts/run_pick_panel.gd) — the between-stage MODAL, redesigned per
# todo/mid-run-upgrade-menu.md into four steps: open_continue (no pick to offer),
# open_repair_or_upgrade, open_category_choice, open_roll (the slot-machine reveal).
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


# --- open_repair_or_upgrade ---------------------------------------------------------

func test_open_repair_or_upgrade_offers_two_navigable_cards() -> void:
	var page := RunPickPanel.open_repair_or_upgrade(_host, func(_x: String) -> void: pass)
	assert_not_null(MenuNav.of(page), "keyboard/gamepad navigable")
	assert_eq(_carousel(page).card_count(), 2, "repair + upgrade")


func test_confirming_repair_reports_repair() -> void:
	var choices: Array = []
	var page := RunPickPanel.open_repair_or_upgrade(_host, func(choice: String) -> void: choices.append(choice))
	_carousel(page).confirmed.emit(0)
	assert_eq(choices, ["repair"])


func test_confirming_upgrade_reports_upgrade() -> void:
	var choices: Array = []
	var page := RunPickPanel.open_repair_or_upgrade(_host, func(choice: String) -> void: choices.append(choice))
	_carousel(page).confirmed.emit(1)
	assert_eq(choices, ["upgrade"])


# --- open_category_choice ------------------------------------------------------------

func test_open_category_choice_is_keyboard_navigable() -> void:
	var pick := _pick(["grip", "gearbox"])
	var page := RunPickPanel.open_category_choice(_host, pick, func(_x: String) -> void: pass)
	assert_not_null(MenuNav.of(page), "keyboard/gamepad navigable")
	assert_eq(_carousel(page).card_count(), 2, "handling + power")


func test_both_categories_enabled_when_both_have_entries() -> void:
	var pick := _pick(["grip", "gearbox"])  # grip=handling, gearbox=power
	var page := RunPickPanel.open_category_choice(_host, pick, func(_x: String) -> void: pass)
	var carousel := _carousel(page)
	assert_false(carousel.get_card(0).disabled, "handling has an entry")
	assert_false(carousel.get_card(1).disabled, "power has an entry")


func test_a_category_with_nothing_to_roll_is_disabled() -> void:
	var pick := _pick(["grip", "aero"])  # both handling, nothing for power
	var page := RunPickPanel.open_category_choice(_host, pick, func(_x: String) -> void: pass)
	var carousel := _carousel(page)
	assert_false(carousel.get_card(0).disabled, "handling has entries")
	assert_true(carousel.get_card(1).disabled, "power has nothing to roll")


func test_confirming_a_category_reports_its_name() -> void:
	var choices: Array = []
	var pick := _pick(["grip", "gearbox"])
	var page := RunPickPanel.open_category_choice(_host, pick,
		func(choice: String) -> void: choices.append(choice))
	_carousel(page).confirmed.emit(1)
	assert_eq(choices, ["power"])


# --- open_roll -----------------------------------------------------------------------

func test_open_roll_is_keyboard_navigable() -> void:
	var pick := _pick(["grip", "aero", "brakes"])
	var page := RunPickPanel.open_roll(_host, pick, "handling", func(_x: String) -> void: pass)
	assert_not_null(MenuNav.of(page), "keyboard/gamepad navigable")


func test_open_roll_only_renders_cards_in_the_chosen_category() -> void:
	var pick := _pick(["grip", "aero", "gearbox"])  # 2 handling, 1 power
	var page := RunPickPanel.open_roll(_host, pick, "handling", func(_x: String) -> void: pass)
	assert_eq(_carousel(page).card_count(), 2, "only the handling entries are shown")


# The winner on_done reports must always be one of the entries the panel was actually
# handed for that category — never the other category's, never something outside `pick`
# entirely. The winner is fixed the instant open_roll builds the page (before any spin
# runs), so pressing Next directly (bypassing its disabled flag, same as emitting any
# other signal) is enough to observe it without waiting out the real animation. Repeated
# since randi() is not seeded/controllable from here.
func test_the_rolled_winner_always_comes_from_the_given_category() -> void:
	var pick := _pick(["grip", "aero", "gearbox"])
	var handling_ids := ["grip", "aero"]
	for _i in 20:
		# An Array, not a plain String local: a lambda captures an outer local BY VALUE
		# in GDScript, so reassigning it from inside the callback would never be seen
		# out here — mutating a shared Array (append) is the idiom every other test in
		# this file already uses for the same reason.
		var choices: Array = []
		var page := RunPickPanel.open_roll(_host, pick, "handling",
			func(choice: String) -> void: choices.append(choice))
		_next_button(page).pressed.emit()
		var winner := String(choices[0])
		assert_true(handling_ids.has(winner), "winner '%s' came from the handling entries" % winner)
		page.queue_free()


func test_a_single_entry_category_skips_the_spin_and_enables_next_immediately() -> void:
	var pick := _pick(["gearbox"])  # the only power entry with no engine swap available
	var page := RunPickPanel.open_roll(_host, pick, "power", func(_x: String) -> void: pass)
	assert_false(_next_button(page).disabled, "nothing to spin toward with one entry")


func test_confirming_next_reports_the_winner_id() -> void:
	var pick := _pick(["gearbox"])
	var choices: Array = []
	var page := RunPickPanel.open_roll(_host, pick, "power",
		func(choice: String) -> void: choices.append(choice))
	_next_button(page).pressed.emit()
	assert_eq(choices, ["gearbox"])


func test_a_drivetrain_entry_renders_and_can_be_rolled() -> void:
	var pick := _pick(["gearbox"])
	pick.append(_drivetrain_entry(Drivetrain.DriveMode.AWD))
	var choices: Array = []
	var page := RunPickPanel.open_roll(_host, pick, "handling",
		func(choice: String) -> void: choices.append(choice))
	assert_eq(_carousel(page).card_count(), 1, "only the one handling (drivetrain) entry")
	_next_button(page).pressed.emit()
	assert_eq(choices, ["drivetrain:%d" % Drivetrain.DriveMode.AWD])


func test_an_engine_swap_entry_renders_and_can_be_rolled() -> void:
	var pick := _pick(["gearbox"])
	pick.append(_engine_swap_entry("fx_v8", 300.0, 100.0))
	var choices: Array = []
	var page := RunPickPanel.open_roll(_host, pick, "power",
		func(choice: String) -> void: choices.append(choice))
	assert_eq(_carousel(page).card_count(), 2, "gearbox + the one engine swap, both power")
	_next_button(page).pressed.emit()
	assert_true(choices[0] == "gearbox" or choices[0] == "engine_swap:fx_v8",
		"the winner is one of the two power entries actually offered")


func test_the_roll_carousel_is_decorative_only() -> void:
	# The player must not be able to nudge the highlight off the landed winner — see
	# open_roll's own doc for why this is deliberate, not an oversight.
	var pick := _pick(["gearbox"])
	pick.append(_engine_swap_entry("fx_v8", 300.0, 100.0))
	var page := RunPickPanel.open_roll(_host, pick, "power", func(_x: String) -> void: pass)
	var carousel := _carousel(page)
	assert_eq(carousel.focus_mode, Control.FOCUS_NONE, "the carousel itself is not focusable")
	# The carousel's own mouse_filter only stops a tap on its BACKGROUND — each card is a
	# separate Control with its own direct gui_input connection (card_carousel.gd), which
	# a parent's mouse_filter does nothing to block. Every card must ALSO ignore input, or
	# a tap straight on a card could still move the highlight (or confirm a different one)
	# after the spin lands — reading as "I might still be able to change this".
	for i in carousel.card_count():
		assert_eq(carousel.get_card(i).root.mouse_filter, Control.MOUSE_FILTER_IGNORE,
			"card %d ignores taps too, not just the carousel's own background" % i)


func _next_button(page: MenuPage) -> Button:
	# UITheme.button() uppercases its label (rule 2's house style), so the rendered
	# text reads "NEXT", not "Next".
	for node in page.find_children("*", "Button", true, false):
		if (node as Button).text == "NEXT":
			return node as Button
	return null


# --- Builds with no world scene ------------------------------------------------------

func test_builds_with_no_world_scene() -> void:
	# Nothing above touches $Car, world.gd or the replay machinery — the whole suite runs
	# against a bare Control host, which is the point: proven here explicitly so a future
	# change that sneaks in a world/scene dependency fails loudly.
	var page := RunPickPanel.open_continue(_host, func(_x: String) -> void: pass)
	assert_not_null(page)
