extends GutTest
# RunPickPanel (scripts/run_pick_panel.gd) — the between-stage MODAL (repair vs. a
# drawn boost, or a bare Continue), replacing the deleted standings.tscn interstitial
# (todo/roguelike-pivot.md "Between stages: repair or boost", stage 5).
#
# THE NAV TEST CLAUDE.md requires of every menu: keyboard/gamepad reachability via
# MenuNav.attach, on a Control host with no world/scene needed at all — this panel is
# deliberately decoupled from world.gd/$Car/the replay machinery for exactly this
# reason (see the class doc).

var _host: Control


func before_each() -> void:
	_host = Control.new()
	add_child_autofree(_host)


# Every focusable Button under `page`, in tree order.
func _buttons(page: MenuPage) -> Array:
	var out: Array = []
	for node in page.find_children("*", "Button", true, false):
		if (node as Button).focus_mode != Control.FOCUS_NONE:
			out.append(node)
	return out


func _pick(ids: Array) -> Array:
	var out: Array = []
	for id in ids:
		out.append({"id": id, "effect": {}})
	return out


# --- Navigation (the CLAUDE.md contract) ------------------------------------------

func test_a_pick_page_is_keyboard_navigable() -> void:
	var page := RunPickPanel.open(_host, _pick(["a", "b"]), func(_x: String) -> void: pass)
	assert_not_null(MenuNav.of(page), "the pick page has a MenuNav attached")
	assert_gt(_buttons(page).size(), 0, "the pick page offers at least one focusable control")


func test_a_plain_continue_page_is_keyboard_navigable() -> void:
	var page := RunPickPanel.open(_host, [], func(_x: String) -> void: pass)
	assert_not_null(MenuNav.of(page), "the continue-only page has a MenuNav attached")
	assert_gt(_buttons(page).size(), 0, "the continue-only page offers a focusable control")


# --- Shape: a row per boost plus repair, or a bare Continue -----------------------

func test_a_non_empty_pick_offers_repair_plus_one_row_per_boost() -> void:
	var page := RunPickPanel.open(_host, _pick(["a", "b", "c"]), func(_x: String) -> void: pass)
	assert_eq(_buttons(page).size(), 4, "3 boosts + the always-present repair row")


func test_an_empty_pick_offers_only_continue() -> void:
	var page := RunPickPanel.open(_host, [], func(_x: String) -> void: pass)
	assert_eq(_buttons(page).size(), 1, "just the one Continue action")


# --- Pressing a row reports the choice, and nothing more --------------------------

func test_pressing_repair_reports_repair() -> void:
	var choices: Array = []
	var page := RunPickPanel.open(_host, _pick(["a"]),
		func(choice: String) -> void: choices.append(choice))
	for b in _buttons(page):
		if String((b as Button).text).to_lower().contains("repair"):
			(b as Button).pressed.emit()
	assert_eq(choices, ["repair"])


func test_pressing_a_boost_row_reports_its_id() -> void:
	var choices: Array = []
	var page := RunPickPanel.open(_host, _pick(["fx_boost_x"]),
		func(choice: String) -> void: choices.append(choice))
	for b in _buttons(page):
		if not String((b as Button).text).to_lower().contains("repair"):
			(b as Button).pressed.emit()
	assert_eq(choices, ["fx_boost_x"])


func test_pressing_continue_reports_an_empty_choice() -> void:
	var choices: Array = []
	var page := RunPickPanel.open(_host, [],
		func(choice: String) -> void: choices.append(choice))
	_buttons(page)[0].pressed.emit()
	assert_eq(choices, [""])
