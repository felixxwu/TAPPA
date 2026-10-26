class_name RestStopPage
extends CanvasLayer
# Docs: features/free-roam.md, features/loot.md, features/menus.md — update in the same change as this file.
# Tests: tests/headless/test_free_roam_rest_stops.gd, tests/headless/test_loot.gd — extend in the same change (every menu change needs a keyboard+gamepad nav test).
# The rest-stop page (todo/2026-10-19-free-roam-pivot.md decision 9): opened when the car stops at
# a rest stop. Opening it repairs the car for free, and the game is frozen while it's up. Card pages
# (CardUI.card_page / card_list) driven by MenuNav:
#   MAIN    — the stop and the money held above the cards Continue / Parts / Garage / Map / Tune car.
#             The map is also where to travel from.
#   TUNE    — the shared TuningPanel on the active car (sliders, so a plain page, not cards).
#   PARTS   — a card per part unlocked for this car (pick to switch it on or off), then one per part
#             on sale for it (pick to buy it, which switches it on).
#   GARAGE  — a card per owned car with its "x / y upgrades" line (pick one to drive it), then one per car on sale (pick to buy and
#             drive it).
# Back (Esc / gamepad B, or the Back button) steps a sub-page → its parent page → MAIN → closed. A change of parts or car
# is applied when the page closes: `car_changed` asks the host to re-field the car.

signal closed
# The Map row: the host opens the map as the travel picker, over this page.
signal map_requested(site: int)
signal car_changed

enum View { WRECKED, MAIN, TUNE, PARTS, GARAGE }

@export var rest_stops: RestStops
@export var car: VehicleBody3D
@export var pause_menu: PauseMenu
@export var loot: LootDirector

# The active car's owned-car dict (Save's own copy), so tuning and parts land on it.
var owned: Dictionary = {}

var view := View.MAIN
var site := -1
var dirty := false
var _keep_at := 0
var _page: MenuPage
var _cards: CardCarousel
var _tune_panel: TuningPanel


func _init() -> void:
	layer = 6
	process_mode = Node.PROCESS_MODE_ALWAYS


func is_open() -> bool:
	return _page != null


func open(p_site: int) -> void:
	site = p_site
	dirty = false
	if car != null and car.get("damage") != null:
		(car.damage as DamageModel).repair(Config.data)
	get_tree().paused = true
	if pause_menu != null:
		pause_menu.set_input_enabled(false)
	_show(View.MAIN)


# The car gave up before reaching a rest stop: say how much money it dropped, and respawn at the last lit stop once the player continues. The game keeps running behind it.
func open_wrecked() -> void:
	if pause_menu != null:
		pause_menu.set_input_enabled(false)
	_show(View.WRECKED)


func close() -> void:
	_clear()
	get_tree().paused = false
	if pause_menu != null:
		pause_menu.set_input_enabled(true)
	closed.emit()
	if dirty:
		dirty = false
		car_changed.emit()


func _clear() -> void:
	if _page != null:
		CardUI.park_previews(_page)
		_page.queue_free()
		_page = null
	_cards = null


func _show(v: View) -> void:
	# Rebuilding the page the player is on (a part fitted, a car picked) keeps the cursor there.
	_keep_at = _cards.selected_index() if _cards != null and v == view else 0
	_clear()
	view = v
	match v:
		View.WRECKED:
			_build_wrecked()
		View.MAIN:
			_build_main()
		View.TUNE:
			_build_tune()
		View.PARTS:
			_build_parts()
		View.GARAGE:
			_build_garage()
	UITheme.enforce(_page)


# A card page: `entries` as cards (see CardUI.card_list), `header` lines above them, and a Back
# button below (to `back`, MAIN by default) unless this is MAIN (whose back is closing the page —
# Continue, or Esc).
# `selected` < 0 keeps the cursor where it was on this page.
func _card_page(title: String, entries: Array, header: Array = [], selected := -1, back := View.MAIN) -> void:
	_page = CardUI.card_page(self, {"title": title, "dim": true})
	_cards = CardUI.card_list(_page, entries, header, mini(_keep_at, entries.size() - 1) if selected < 0 else selected)
	var go_back := _show.bind(back)
	if view != View.MAIN:
		_page.add_action(UITheme.row_button("< Back", go_back))
	MenuNav.attach(_page, {first = _cards, on_back = close if view == View.MAIN else go_back})


func _build_wrecked() -> void:
	var lost := loot.lost if loot != null else 0
	var header: Array = ["You dropped $%d here" % lost] if lost > 0 else []
	_page = CardUI.card_page(self, {"title": "Wrecked", "dim": true})
	_cards = CardUI.card_list(_page, [{"title": "Respawn", "icon": "resume_run", "action": _respawn}], header, 0)
	MenuNav.attach(_page, {first = _cards, on_back = _respawn})


func _respawn() -> void:
	rest_stops.respawn()
	close()


func _build_main() -> void:
	var header: Array = [rest_stops.name_of(site) if rest_stops != null else "", "Car repaired",
		"$%d. Spend it: a wreck drops it all" % WorldSession.money()]
	_card_page("Checkpoint", [
		{"title": "Continue", "icon": "resume_run", "action": close},
		{"title": "Parts", "icon": "parts", "action": _show.bind(View.PARTS)},
		{"title": "Garage", "icon": "car", "action": _show.bind(View.GARAGE)},
		{"title": "Map", "icon": "map", "action": _open_map},
		{"title": "Tune car", "icon": "tune", "action": _show.bind(View.TUNE)},
	], header)


func _build_tune() -> void:
	_page = MenuPage.new({"title": "Tune car", "dim": true, "alpha": 0.0, "width": UITheme.px(560)})
	add_child(_page)
	_tune_panel = TuningPanel.new()
	_page.body().add_child(_tune_panel)
	_tune_panel.setup(owned, _on_tuned)
	_tune_panel.refresh()
	var back := _page.add_action(UITheme.row_button("< Back", _show.bind(View.MAIN)))
	for b in _tune_panel.action_buttons():
		if b.get_parent() != null:
			b.get_parent().remove_child(b)
		_page.add_action(b)
	MenuNav.attach(_page, {first = _tune_panel.first_slider() if _tune_panel.first_slider() != null else back,
		on_back = _show.bind(View.MAIN)})


func _on_tuned() -> void:
	if car != null and car.has_method("retune"):
		car.retune(LootRules.fielded(owned))


func _build_parts() -> void:
	var entries: Array = []
	var parts: Array = owned.get("parts", [])
	for i in parts.size():
		var text := LootRules.card_text(parts[i])
		var on := LootRules.is_on(parts[i])
		entries.append({"title": text[0], "desc": text[1], "extra": "On" if on else "Off",
			"extra_variant": "" if on else "dim", "icon": LootRules.icon(parts[i]), "action": _toggle_part.bind(i)})
	var money := WorldSession.money()
	for part: Dictionary in loot.for_sale() if loot != null else []:
		if String(part["kind"]) != "part":
			continue
		var cost := LootRules.price(part)
		var block := LootRules.fit_block_reason(owned, part)
		var text := LootRules.card_text(part)
		entries.append({"title": text[0], "desc": text[1],
			"extra": block if not block.is_empty() else "$%d" % cost, "icon": LootRules.icon(part),
			"disabled": not block.is_empty() or cost > money, "action": _buy_part.bind(part)})
	if entries.is_empty():
		entries.append({"title": "No parts yet", "subtitle": "Light checkpoints further out to buy some", "icon": "stash"})
	_card_page("Parts", entries, [_car_name(owned), "$%d" % money])


# Buy a part on sale: it's unlocked for this car and switched on straight away.
func _buy_part(item: Dictionary) -> void:
	if loot.buy(item).is_empty():
		return
	var parts: Array = owned.get("parts", []).duplicate(true)
	var part := item.duplicate()
	part["on"] = false
	parts.append(part)
	_set_parts(LootRules.toggled(parts, parts.size() - 1))
	_show(View.PARTS)


# Buy a car on sale and switch to it.
func _buy_car(item: Dictionary) -> void:
	var bought := loot.buy(item)
	if not bought.is_empty():
		_drive(int(bought["instance_id"]))


func _toggle_part(index: int) -> void:
	_set_parts(LootRules.toggled(owned.get("parts", []), index))
	_show(View.PARTS)


func _set_parts(parts: Array) -> void:
	owned["parts"] = parts
	Save.set_car_parts(int(owned.get("instance_id", -1)), parts)
	dirty = true


func _build_garage() -> void:
	var active := int(owned.get("instance_id", -1))
	var entries: Array = []
	var selected := 0
	for c: Dictionary in Save.profile.get(Save.KEY_CARS, []):
		var id := int(c.get("instance_id", -1))
		var model := CarLibrary.by_id(String(c.get("model_id", "")))
		if id == active:
			selected = entries.size()
		entries.append({"title": _car_name(c), "desc": CardUI.car_subtitle(model),
			"subtitle": LootRules.upgrades_text(c), "car": c,
			"extra": "Driving" if id == active else "", "action": Callable() if id == active else _drive.bind(id)})
	var money := WorldSession.money()
	for item: Dictionary in loot.for_sale() if loot != null else []:
		if String(item["kind"]) != "car":
			continue
		var model := CarLibrary.by_id(String(item["id"]))
		var cost := LootRules.price(item)
		entries.append({"title": String(model.get("name", item["id"])), "subtitle": CardUI.car_subtitle(model),
			"car": CarLibrary.index_of(String(item["id"])), "extra": "$%d" % cost, "extra_variant": "dim",
			"disabled": cost > money, "action": _buy_car.bind(item)})
	_card_page("Garage", entries, ["$%d" % money], selected)


func _car_name(c: Dictionary) -> String:
	var model := String(c.get("model_id", ""))
	return String(CarLibrary.by_id(model).get("name", model))


func _drive(instance_id: int) -> void:
	WorldSession.set_active_car(instance_id)
	owned = WorldSession.active_car()
	dirty = true
	_show(View.GARAGE)


func _open_map() -> void:
	_clear()
	map_requested.emit(site)


# The map closed (Back, or a travel): come back to the main page, unless a travel moved the car.
func return_from_map() -> void:
	if rest_stops != null and rest_stops.last_site != site:
		close()
		return
	_show(View.MAIN)


# Readout for tests: the current page's card list (null on TUNE).
func cards() -> CardCarousel:
	return _cards


# Pick the card whose title starts with `text`, as a player would. False if absent or disabled.
func pick(text: String) -> bool:
	return _cards != null and CardUI.pick(_cards, text)
