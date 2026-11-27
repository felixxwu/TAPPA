class_name RestStopPage
extends CanvasLayer
# Docs: features/loot.md, features/menus.md — update in the same change as this file.
# Tests: tests/headless/test_level_shop_specialties.gd, tests/headless/test_level_view.gd — extend in the same change (every menu change needs a keyboard+gamepad nav test).
# The level's parts, engine-swap and tuning pages, opened over the host's own menu. Card pages
# (CardUI.card_page / card_list) driven by MenuNav:
#   TUNE    — the shared TuningPanel on the active car (sliders, so a plain page, not cards).
#   SHOP    — cards opening the pages below.
#   ENGINES — a card per owned car (`engine_cars`): pick one to fit its engine.
#   UPGRADES, TIRES, DRIVETRAINS — a card per part of that kind unlocked for this car (pick to switch
#             it on or off). TIRES starts with a Stock card, the car's own tires.
# Back (Esc / gamepad B, or the Back button) steps a sub-page → the shop → closed. A change of parts
# or engine is applied when the page closes: `car_changed` asks the host to re-field the car.

signal car_changed
signal tuned
signal closed

enum View { TUNE, SHOP, UPGRADES, TIRES, ENGINES, DRIVETRAINS }

@export var car: VehicleBody3D

# The active car's owned-car dict, so tuning and parts land on it.
var owned: Dictionary = {}
# The car ids whose engines can be fitted: the cars the player owns.
var engine_cars: Array = []

var view := View.SHOP
var _fielded_id := -1  # the car body in the world, which tuning retunes live
var dirty := false
var _keep_at := 0
var _rebuilding := false
var _root := View.SHOP  # the page whose Back closes this one
var _page: MenuPage
var _cards: CardCarousel
var _tune_panel: TuningPanel


func _init() -> void:
	layer = 6
	process_mode = Node.PROCESS_MODE_ALWAYS


func is_open() -> bool:
	return _page != null


func open_shop() -> void:
	_open(View.SHOP)


func open_engines() -> void:
	_open(View.ENGINES)


func open_tune() -> void:
	_open(View.TUNE)


func _open(root: View) -> void:
	_root = root
	dirty = false
	_fielded_id = int(owned.get("instance_id", -1))
	_show(root)


func close() -> void:
	_clear()
	get_tree().paused = false
	if dirty:
		dirty = false
		car_changed.emit()
	closed.emit()


func _clear() -> void:
	if _page != null:
		CardUI.park_previews(_page)
		_page.queue_free()
		_page = null
	_cards = null


func _show(v: View) -> void:
	# Rebuilding the page the player is on (a part switched) keeps the cursor there.
	_rebuilding = _cards != null and v == view
	_keep_at = _cards.selected_index() if _rebuilding else 0
	_clear()
	view = v
	match v:
		View.TUNE:
			_build_tune()
		View.SHOP:
			_build_shop()
		View.UPGRADES:
			_build_part_page("Upgrades", LootRules.is_upgrade)
		View.TIRES:
			_build_part_page("Tires", LootRules.is_tire, [_stock_tire_entry()])
		View.ENGINES:
			_build_engines()
		View.DRIVETRAINS:
			_build_part_page("Drivetrain", LootRules.is_drivetrain)
	UITheme.enforce(_page)


# A card page: `entries` as cards (see CardUI.card_list), `header` lines above them, and a Back
# button below: to the shop, or closing the page from the page it was opened on.
func _card_page(title: String, entries: Array, header: Array = []) -> void:
	_page = CardUI.card_page(self, {"title": title, "dim": true})
	_cards = CardUI.card_list(_page, entries, header, mini(_keep_at, entries.size() - 1), not _rebuilding)
	var go_back := close if view == _root else _show.bind(View.SHOP)
	_page.add_action(UITheme.row_button("< Back", go_back))
	MenuNav.attach(_page, {first = _cards, on_back = go_back})


# "N applied" over the parts `belongs` accepts.
func _shop_text(belongs: Callable) -> String:
	var applied := 0
	for part: Dictionary in owned.get("parts", []):
		if LootRules.is_on(part) and belongs.call(part):
			applied += 1
	return "%d applied" % applied


func _build_tune() -> void:
	_page = MenuPage.new({"title": "Tune car", "dim": true, "alpha": 0.0, "width": UITheme.px(560)})
	add_child(_page)
	_tune_panel = TuningPanel.new()
	_page.body().add_child(_tune_panel)
	_tune_panel.setup(owned, _on_tuned)
	_tune_panel.refresh()
	var back := _page.add_action(UITheme.row_button("< Back", close))
	for b in _tune_panel.action_buttons():
		if b.get_parent() != null:
			b.get_parent().remove_child(b)
		_page.add_action(b)
	MenuNav.attach(_page, {first = _tune_panel.first_slider() if _tune_panel.first_slider() != null else back,
		on_back = close})


func _on_tuned() -> void:
	if car != null and car.has_method("retune") and int(owned.get("instance_id", -1)) == _fielded_id:
		car.retune(LootRules.fielded(owned))
	tuned.emit()


func _build_shop() -> void:
	_card_page("Shop", [
		{"title": "Upgrades", "subtitle": _shop_text(LootRules.is_upgrade), "icon": "parts", "action": _show.bind(View.UPGRADES)},
		{"title": "Tires", "subtitle": _shop_text(LootRules.is_tire), "icon": "tire", "action": _show.bind(View.TIRES)},
		{"title": "Engine swaps", "icon": "engine_swap", "action": _show.bind(View.ENGINES)},
		{"title": "Drivetrain", "subtitle": _shop_text(LootRules.is_drivetrain), "icon": "drivetrain", "action": _show.bind(View.DRIVETRAINS)},
	].filter(func(e: Dictionary) -> bool: return not (engine_cars.is_empty() and e["title"] == "Engine swaps")), _header())


func _header() -> Array:
	return [LootRules.shop_header(owned)]


# The engine of every car the player owns (`engine_cars`), any one fitted with a pick.
func _build_engines() -> void:
	var entries: Array = []
	for i in CarLibrary.all().size():
		var id := String(CarLibrary.all()[i]["id"])
		if not id in engine_cars:
			continue
		var fitted := LootRules.engine_owner(owned) == id
		entries.append({"title": _car_name(id), "desc": LootRules.engine_name({"model_id": id}), "car": i,
			"extra": "Fitted" if fitted else "", "action": Callable() if fitted else _fit_engine.bind(id)})
	_card_page("Engine swaps", entries, _header())


func _fit_engine(model_id: String) -> void:
	if model_id == String(owned.get("model_id", "")):
		owned.erase("engine_from")
	else:
		owned["engine_from"] = model_id
	dirty = true
	_show(view)


# Stock is no part at all: it's on whenever no bought tire is, and picking it switches them off.
func _stock_tire_entry() -> Dictionary:
	var on := not (owned.get("parts", []) as Array).any(func(p: Dictionary) -> bool:
		return LootRules.is_tire(p) and LootRules.is_on(p))
	return {"title": "Stock tires", "desc": "What it came with.", "extra": "On" if on else "Off",
		"extra_variant": "" if on else "dim", "icon": "tire", "action": Callable() if on else _fit_stock_tires}


func _fit_stock_tires() -> void:
	_set_parts(LootRules.on_stock_tires(owned.get("parts", [])))
	_show(view)


# One parts page: `entries_first`, then the parts `belongs` accepts that this car has unlocked.
func _build_part_page(title: String, belongs: Callable, entries_first: Array = []) -> void:
	var entries := entries_first.duplicate()
	var parts: Array = owned.get("parts", [])
	for i in parts.size():
		if not belongs.call(parts[i]):
			continue
		var text := LootRules.card_text(parts[i])
		var on := LootRules.is_on(parts[i])
		entries.append({"title": text[0], "desc": text[1], "extra": "On" if on else "Off",
			"extra_variant": "" if on else "dim", "icon": LootRules.icon(parts[i]), "action": _toggle_part.bind(i)})
	if entries.is_empty():
		entries.append({"title": "No parts yet", "subtitle": "Buy some at a shop", "icon": "stash"})
	_card_page(title, entries, _header())


func _toggle_part(index: int) -> void:
	_set_parts(LootRules.toggled(owned.get("parts", []), index))
	_show(view)


func _set_parts(parts: Array) -> void:
	owned["parts"] = parts
	Save.set_car_parts(int(owned.get("instance_id", -1)), parts)
	dirty = true


func _car_name(model_id: String) -> String:
	return String(CarLibrary.by_id(model_id).get("name", model_id))


# Readout for tests: the current page's card list (null on TUNE).
func cards() -> CardCarousel:
	return _cards


# Pick the card whose title starts with `text`, as a player would. False if absent or disabled.
func pick(text: String) -> bool:
	return _cards != null and CardUI.pick(_cards, text)
