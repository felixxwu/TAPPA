class_name RestStopPage
extends CanvasLayer
# Docs: features/free-roam.md, features/loot.md, features/menus.md — update in the same change as this file.
# Tests: tests/headless/test_free_roam_rest_stops.gd, tests/headless/test_loot.gd — extend in the same change (every menu change needs a keyboard+gamepad nav test).
# The rest-stop page (todo/2026-10-19-free-roam-pivot.md decision 9): opened when the car stops at
# a rest stop. Opening it repairs the car for free, and the game is frozen while it's up. Card pages
# (CardUI.card_page / card_list) driven by MenuNav:
#   MAIN    — the stop and the money held above the cards Continue / Shop / Garage / Map / Tune car.
#             The map is also where to travel from.
#   TUNE    — the shared TuningPanel on the active car (sliders, so a plain page, not cards).
#   SHOP    — four cards opening the pages below.
#   ENGINES — a card per owned car naming the engine in it: pick one, then pick another to swap their engines.
#   UPGRADES, TIRES, DRIVETRAINS — a card per part of that kind unlocked for this car (pick to switch it
#             on or off), then one per part on sale for it (pick to buy it, which switches it on).
#             TIRES starts with a Stock card, the car's own tires.
#   GARAGE — a card per owned car with its "x / y upgrades" line (pick one to drive it).
# Back (Esc / gamepad B, or the Back button) steps a sub-page → its parent page → MAIN → closed. A change of parts or car
# is applied when the page closes: `car_changed` asks the host to re-field the car.

# The Map row: the host opens the map as the travel picker, over this page.
signal map_requested(site: int)
signal car_changed
signal tuned

enum View { WRECKED, MAIN, TUNE, SHOP, UPGRADES, TIRES, ENGINES, DRIVETRAINS, GARAGE }

@export var rest_stops: RestStops
@export var car: VehicleBody3D
@export var pause_menu: PauseMenu
@export var loot: LootDirector

# The active car's owned-car dict (Save's own copy), so tuning and parts land on it.
var owned: Dictionary = {}

var view := View.MAIN
var site := -1
var _fielded_id := -1  # the car body in the world: after a Garage swap `owned` is another car
var dirty := false
var _swapped_car := false
var _swap_from := -1  # the car picked to swap its engine, waiting for the car to swap with
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
	_swapped_car = false
	_swap_from = -1
	_fielded_id = int(owned.get("instance_id", -1))
	if car != null and car.get("damage") != null:
		(car.damage as DamageModel).repair()
	get_tree().paused = true
	if pause_menu != null:
		pause_menu.set_input_enabled(false)
	_show(View.MAIN)


# The car gave up before reaching a rest stop: say how much money it dropped, and respawn at the last lit stop once the player continues. The game keeps running behind it.
func open_wrecked() -> void:
	if pause_menu != null:
		pause_menu.set_input_enabled(false)
	_show(View.WRECKED)


# The wrecked car reached a rest stop by itself: the wreck page has nothing left to offer.
func dismiss_wrecked() -> void:
	if _page != null and view == View.WRECKED:
		close()


func close() -> void:
	_clear()
	get_tree().paused = false
	if pause_menu != null:
		pause_menu.set_input_enabled(true)
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
		View.GARAGE:
			_build_garage()
	UITheme.enforce(_page)


# A card page: `entries` as cards (see CardUI.card_list), `header` lines above them, and a Back
# button below (to `back`, MAIN by default) unless this is MAIN (whose back is closing the page —
# Continue, or Esc).
# `selected` < 0 keeps the cursor where it was on this page.
func _card_page(title: String, entries: Array, header: Array = [], selected := -1, back := View.MAIN, on_back := Callable()) -> void:
	_page = CardUI.card_page(self, {"title": title, "dim": true})
	_cards = CardUI.card_list(_page, entries, header, mini(_keep_at, entries.size() - 1) if selected < 0 else selected)
	var go_back := on_back if on_back.is_valid() else _show.bind(back)
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
		{"title": "Shop", "icon": "shop", "action": _show.bind(View.SHOP)},
		{"title": "Garage", "icon": "car", "action": _show.bind(View.GARAGE)},
		{"title": "Map", "icon": "map", "action": _open_map},
		{"title": "Tune car", "icon": "tune", "action": _show.bind(View.TUNE)},
	], header)


# "N applied, M available" over the parts `belongs` accepts.
func _shop_text(belongs: Callable) -> String:
	var applied := 0
	for part: Dictionary in owned.get("parts", []):
		if LootRules.is_on(part) and belongs.call(part):
			applied += 1
	var available := 0
	for item: Dictionary in loot.for_sale() if loot != null else []:
		if String(item["kind"]) == "part" and belongs.call(item) and LootRules.fit_block_reason(owned, item).is_empty():
			available += 1
	return "%d applied, %d available" % [applied, available]


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
	if car != null and car.has_method("retune") and int(owned.get("instance_id", -1)) == _fielded_id:
		car.retune(LootRules.fielded(owned))
	tuned.emit()


func _build_shop() -> void:
	_card_page("Shop", [
		{"title": "Upgrades", "subtitle": _shop_text(LootRules.is_upgrade), "icon": "parts", "action": _show.bind(View.UPGRADES)},
		{"title": "Tires", "subtitle": _shop_text(LootRules.is_tire), "icon": "tire", "action": _show.bind(View.TIRES)},
		{"title": "Engine swaps", "icon": "engine_swap", "action": _show.bind(View.ENGINES)},
		{"title": "Drivetrain", "subtitle": _shop_text(LootRules.is_drivetrain), "icon": "drivetrain", "action": _show.bind(View.DRIVETRAINS)},
	], [LootRules.shop_header(owned), "$%d" % WorldSession.money()])


func _build_engines() -> void:
	var cars: Array = Save.profile.get(Save.KEY_CARS, [])
	var entries: Array = []
	for c: Dictionary in cars:
		var id := int(c.get("instance_id", -1))
		entries.append({"title": _car_name(c), "desc": LootRules.engine_name(c), "car": LootRules.fielded(c),
			"extra": "Swap with..." if id == _swap_from else "", "extra_variant": "green",
			"action": _pick_engine_swap.bind(id) if cars.size() > 1 else Callable()})
	var header: Array = [LootRules.shop_header(owned)]
	if cars.size() < 2:
		header.append("Find another car to swap engines with")
	_card_page("Engine swaps", entries, header, -1, View.SHOP, _back_from_engines)


# The first pick marks the car, picking it again drops it, and picking another swaps their engines.
func _pick_engine_swap(id: int) -> void:
	if _swap_from < 0:
		_swap_from = id
	else:
		if id != _swap_from:
			Save.swap_engines(_swap_from, id)
			var active := int(owned.get("instance_id", -1))
			dirty = dirty or id == active or _swap_from == active
		_swap_from = -1
	_show(view)


# Back drops a car waiting to swap before it leaves the page.
func _back_from_engines() -> void:
	if _swap_from >= 0:
		_swap_from = -1
		_show(view)
	else:
		_show(View.SHOP)


# Stock is no part at all: it's on whenever no bought tire is, and picking it switches them off.
func _stock_tire_entry() -> Dictionary:
	var on := not (owned.get("parts", []) as Array).any(func(p: Dictionary) -> bool:
		return LootRules.is_tire(p) and LootRules.is_on(p))
	return {"title": "Stock tires", "desc": "What it came with.", "extra": "On" if on else "Off",
		"extra_variant": "" if on else "dim", "icon": "tire", "action": Callable() if on else _fit_stock_tires}


func _fit_stock_tires() -> void:
	_set_parts(LootRules.on_stock_tires(owned.get("parts", [])))
	_show(view)


# One Shop page: `entries_first`, the parts `belongs` accepts that this car has unlocked, then those on sale.
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
	var money := WorldSession.money()
	for part: Dictionary in loot.for_sale() if loot != null else []:
		if String(part["kind"]) != "part" or not belongs.call(part):
			continue
		var cost := LootRules.price(part)
		var block := LootRules.fit_block_reason(owned, part)
		var text := LootRules.card_text(part)
		entries.append({"title": text[0], "desc": text[1],
			"extra": block if not block.is_empty() else "$%d" % cost,
			"extra_variant": "" if not block.is_empty() else price_variant(cost, money), "icon": LootRules.icon(part),
			"disabled": not block.is_empty() or cost > money, "action": _buy_part.bind(part)})
	if entries.is_empty():
		entries.append({"title": "No parts yet", "subtitle": "Light checkpoints further out to buy some", "icon": "stash"})
	_card_page(title, entries, [LootRules.shop_header(owned), "$%d" % money], -1, View.SHOP)


# A price reads green when the player can pay it and red when they can't.
static func price_variant(cost: int, money: int) -> String:
	return "green" if cost <= money else "red"


# Buy a part on sale: it's unlocked for this car and switched on straight away.
func _buy_part(item: Dictionary) -> void:
	if loot.buy(item).is_empty():
		return
	var parts: Array = owned.get("parts", []).duplicate(true)
	var part := item.duplicate()
	part["on"] = false
	parts.append(part)
	_set_parts(LootRules.toggled(parts, parts.size() - 1))
	_show(view)


func _toggle_part(index: int) -> void:
	_set_parts(LootRules.toggled(owned.get("parts", []), index))
	_show(view)


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
		var stats := LootRules.fitted_stats(c)
		if id == active:
			selected = entries.size()
		entries.append({"title": _car_name(c), "desc": CardUI.stats_line(stats["hp"], stats["mass"], stats["drive_mode"]),
			"subtitle": LootRules.upgrades_text(c), "car": LootRules.fielded(c),
			"extra": "Driving" if id == active else "", "action": Callable() if id == active else _drive.bind(id)})
	entries.append_array(unfound_cards())
	_card_page("Garage", entries, ["$%d" % WorldSession.money()], selected)


# A greyed-out card for each car still parked somewhere on the island, saying which region it's in
# (the ring its side road is in, which can differ from the car's own when that ring had no room).
func unfound_cards() -> Array:
	var out: Array = []
	if loot == null or loot.streamer == null:
		return out
	var sites := loot.streamer.sites
	var cars := Array(sites.of_kind(RoadSites.Kind.CAR))
	cars.sort_custom(func(a: int, b: int) -> bool: return sites.ring[a] < sites.ring[b])
	for i: int in cars:
		var id := String(sites.car_id[i])
		if ParkedCars.model_owned(id):
			continue
		out.append({"title": String(CarLibrary.by_id(id).get("name", id)),
			"desc": "%s region" % RegionBanner.name_for(loot.streamer.settings, sites.ring[i]),
			"subtitle": "Not found yet", "car": CarLibrary.index_of(id), "disabled": true})
	return out


func _car_name(c: Dictionary) -> String:
	var model := String(c.get("model_id", ""))
	return String(CarLibrary.by_id(model).get("name", model))


func _drive(instance_id: int) -> void:
	WorldSession.set_active_car(instance_id)
	owned = WorldSession.active_car()
	dirty = true
	_swapped_car = true
	_show(View.GARAGE)


# What the loading screen says while the world reloads to apply this visit's changes.
func reload_title() -> String:
	return "Changing cars" if _swapped_car else "Applying parts to your car"


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
