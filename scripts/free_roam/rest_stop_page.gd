class_name RestStopPage
extends CanvasLayer
# Docs: features/free-roam.md, features/loot.md, features/menus.md — update in the same change as this file.
# Tests: tests/headless/test_free_roam_rest_stops.gd, tests/headless/test_loot.gd — extend in the same change (every menu change needs a keyboard+gamepad nav test).
# The rest-stop page (todo/2026-10-19-free-roam-pivot.md decision 9): opened when the car stops at
# a rest stop. Opening it banks the carried loot (LootDirector.bank) and repairs the car for free,
# and the game is frozen while it's up. Card pages (CardUI.card_page / card_list) driven by MenuNav:
#   MAIN    — the stop and what was banked above the cards Continue / Tune car / Parts / Garage /
#             Travel / Map / Journal.
#   TUNE    — the shared TuningPanel on the active car (sliders, so a plain page, not cards).
#   PARTS   — a card per fitted part (pick to take it off), then one per stash part (pick to fit;
#             a part for a taken slot swaps with what's there), then one per part on another owned
#             car (pick, confirm, and it moves over).
#   GARAGE  — a card per owned car; pick one to drive it.
#   TRAVEL  — a card per other lit rest stop, nearest first.
#   JOURNAL — a card per revealed biome; pick one for REGION. Also opened on its own from the pause
#             menu (open_journal): then Back leaves the page through the caller's on_close instead.
#   REGION  — a card per item and car in that biome, found or not (read-only).
# Back (Esc / gamepad B, or the Back button) steps a sub-page → its parent page → MAIN → closed. A change of parts or car
# is applied when the page closes: `car_changed` asks the host to re-field the car.

signal closed
# The Map row: the host opens the map as the travel picker, over this page.
signal map_requested(site: int)
signal car_changed

enum View { WRECKED, MAIN, TUNE, PARTS, GARAGE, TRAVEL, JOURNAL, REGION }

@export var rest_stops: RestStops
@export var car: VehicleBody3D
@export var pause_menu: PauseMenu
@export var loot: LootDirector

# The active car's owned-car dict (Save's own copy), so tuning and parts land on it.
var owned: Dictionary = {}

var view := View.MAIN
var site := -1
var banked: Array = []
var dirty := false
var journal_ring := -1
# Set while the journal was opened on its own (open_journal, from the pause menu): its Back hands
# back to this rather than stepping to MAIN.
var _on_journal_close := Callable()
var _page: MenuPage
var _cards: CardCarousel
var _tune_panel: TuningPanel


func _init() -> void:
	layer = 6
	process_mode = Node.PROCESS_MODE_ALWAYS


func is_open() -> bool:
	return _page != null


# The journal on its own, over the already-frozen game (the pause menu's Journal row). It leaves the
# pause state alone: Back clears the page and calls `on_close`, which hands back to the caller.
func open_journal(on_close: Callable) -> void:
	_on_journal_close = on_close
	journal_ring = -1
	_show(View.JOURNAL)


func _close_journal() -> void:
	_clear()
	var on_close := _on_journal_close
	_on_journal_close = Callable()
	on_close.call()


func open(p_site: int) -> void:
	site = p_site
	dirty = false
	_on_journal_close = Callable()
	banked = loot.bank() if loot != null else []
	if car != null and car.get("damage") != null:
		(car.damage as DamageModel).repair(Config.data)
	get_tree().paused = true
	if pause_menu != null:
		pause_menu.set_input_enabled(false)
	_show(View.MAIN)


# The car gave up before reaching a rest stop: say what was carried (and is now left at the wreck),
# and respawn at the last lit stop once the player continues. The game keeps running behind it.
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
		View.TRAVEL:
			_build_travel()
		View.JOURNAL:
			_build_journal()
		View.REGION:
			_build_region()
	UITheme.enforce(_page)


# A card page: `entries` as cards (see CardUI.card_list), `header` lines above them, and a Back
# button below (to `back`, MAIN by default) unless this is MAIN (whose back is closing the page —
# Continue, or Esc).
func _card_page(title: String, entries: Array, header: Array = [], selected := 0, back := View.MAIN) -> void:
	_page = CardUI.card_page(self, {"title": title, "dim": true})
	_cards = CardUI.card_list(_page, entries, header, selected)
	var go_back := _show.bind(back)
	if view == View.JOURNAL and _on_journal_close.is_valid():
		go_back = _close_journal
	if view != View.MAIN:
		_page.add_action(UITheme.row_button("< Back", go_back))
	MenuNav.attach(_page, {first = _cards, on_back = close if view == View.MAIN else go_back})


func _build_wrecked() -> void:
	var header: Array = ["Your car wrecked before reaching a checkpoint."]
	var lost := WorldSession.list("carried")
	if lost.is_empty():
		header.append("You weren't carrying anything.")
	else:
		header.append("Left at the wreck, drive back to recover:")
		for item: Dictionary in lost:
			header.append(LootRules.label(item))
	_page = CardUI.card_page(self, {"title": "Wrecked", "dim": true})
	_cards = CardUI.card_list(_page, [{"title": "Respawn", "icon": "resume_run", "action": _respawn}], header, 0)
	MenuNav.attach(_page, {first = _cards, on_back = _respawn})


func _respawn() -> void:
	rest_stops.respawn()
	close()


func _build_main() -> void:
	var header: Array = [rest_stops.name_of(site) if rest_stops != null else "", "Car repaired"]
	if not banked.is_empty():
		var names: Array[String] = []
		for item: Dictionary in banked:
			names.append(LootRules.label(item))
		header.append("Banked: " + ", ".join(names))
	var no_travel := rest_stops == null or rest_stops.travel_targets(site).is_empty()
	_card_page("Checkpoint", [
		{"title": "Continue", "icon": "resume_run", "action": close},
		{"title": "Tune car", "icon": "tune", "action": _show.bind(View.TUNE)},
		{"title": "Parts", "icon": "parts", "action": _show.bind(View.PARTS)},
		{"title": "Garage", "icon": "car", "action": _show.bind(View.GARAGE)},
		{"title": "Travel", "icon": "travel", "action": _show.bind(View.TRAVEL), "disabled": no_travel,
			"subtitle": "No other checkpoint reached" if no_travel else ""},
		{"title": "Map", "icon": "map", "action": _open_map},
		{"title": "Journal", "icon": "journal", "action": _show.bind(View.JOURNAL)},
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
	var fitted: Array = owned.get("parts", [])
	for i in fitted.size():
		var text := LootRules.card_text(fitted[i])
		entries.append({"title": text[0], "subtitle": text[1] + " · fitted",
			"extra": "Take off", "icon": LootRules.icon(fitted[i]), "action": _unfit.bind(i)})
	var stash := WorldSession.list("stash")
	for i in stash.size():
		var part: Dictionary = stash[i]
		var taken := LootRules.occupant(owned, part)
		# can_fit already covers a swap (one of a kind, so an occupant never blocks it), and never
		# offers a kit for the car's own layout, whatever is fitted.
		var ok := LootRules.can_fit(owned, part)
		var extra := "Can't fit"
		if ok:
			extra = "Swap for " + LootRules.card_text(taken)[0] if not taken.is_empty() else "Fit"
		var text := LootRules.card_text(part)
		entries.append({"title": text[0], "subtitle": text[1] + " · stash", "extra": extra,
			"icon": LootRules.icon(part), "disabled": not ok, "action": _fit.bind(i)})
	var active := int(owned.get("instance_id", -1))
	for c: Dictionary in Save.profile.get(Save.KEY_CARS, []):
		var id := int(c.get("instance_id", -1))
		if id == active:
			continue
		var on: Array = c.get("parts", [])
		for i in on.size():
			var part: Dictionary = on[i]
			var taken := LootRules.occupant(owned, part)
			var ok := LootRules.can_fit(owned, part)
			var extra := "Can't fit"
			if ok:
				extra = "Swap for " + LootRules.card_text(taken)[0] if not taken.is_empty() else "Move here"
			var text := LootRules.card_text(part)
			entries.append({"title": text[0], "subtitle": text[1] + " · on " + _car_name(c), "extra": extra,
				"icon": LootRules.icon(part), "disabled": not ok, "action": _confirm_take.bind(id, i)})
	if entries.is_empty():
		entries.append({"title": "No parts yet", "subtitle": "Find parts out on the island", "icon": "stash"})
	_card_page("Parts", entries, [_car_name(owned)])


func _same_id_fitted(part: Dictionary) -> bool:
	for p: Dictionary in owned.get("parts", []):
		if String(p["id"]) == String(part["id"]):
			return true
	return false


func _fit(stash_index: int) -> void:
	var stash := WorldSession.list("stash")
	var part: Dictionary = stash[stash_index]
	stash.remove_at(stash_index)
	WorldSession.set_list("stash", stash)
	_fit_part(part)


func _confirm_take(instance_id: int, index: int) -> void:
	var from := Save.get_car(instance_id)
	var part: Dictionary = (from.get("parts", []) as Array)[index]
	ConfirmPopup.open(self, "Move %s?" % LootRules.card_text(part)[0],
		"It will be removed from the %s." % _car_name(from),
		[{"label": "Cancel", "callback": Callable()}, {"label": "Move", "callback": _take.bind(instance_id, index)}],
		1, 0)


func _take(instance_id: int, index: int) -> void:
	var from_parts: Array = Save.get_car(instance_id).get("parts", []).duplicate()
	var part: Dictionary = from_parts[index]
	from_parts.remove_at(index)
	Save.set_car_parts(instance_id, from_parts)
	_fit_part(part)


# Fits `part` on the active car; whatever it displaces goes to the stash.
func _fit_part(part: Dictionary) -> void:
	var parts: Array = owned.get("parts", []).duplicate()
	var taken := LootRules.occupant(owned, part)
	if not taken.is_empty():
		parts.erase(taken)
		var stash := WorldSession.list("stash")
		stash.append(taken)
		WorldSession.set_list("stash", stash)
	parts.append(part)
	_set_parts(parts)
	_show(View.PARTS)


func _unfit(index: int) -> void:
	var parts: Array = owned.get("parts", []).duplicate()
	var stash := WorldSession.list("stash")
	stash.append(parts[index])
	parts.remove_at(index)
	_set_parts(parts)
	WorldSession.set_list("stash", stash)
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
		entries.append({"title": _car_name(c), "subtitle": CardUI.car_subtitle(model), "car": c,
			"extra": "Driving" if id == active else "", "action": Callable() if id == active else _drive.bind(id)})
	_card_page("Garage", entries, [], selected)


func _car_name(c: Dictionary) -> String:
	var model := String(c.get("model_id", ""))
	return String(CarLibrary.by_id(model).get("name", model))


func _drive(instance_id: int) -> void:
	WorldSession.set_active_car(instance_id)
	owned = WorldSession.active_car()
	dirty = true
	_show(View.GARAGE)


func _build_travel() -> void:
	var here := rest_stops.streamer.sites.pos[site]
	var entries: Array = []
	for t in rest_stops.travel_targets(site):
		var km := rest_stops.streamer.sites.pos[t].distance_to(here) / 1000.0
		entries.append({"title": rest_stops.name_of(t), "subtitle": "%.1f km away" % km, "icon": "rest_stop",
			"action": _travel.bind(t)})
	_card_page("Travel", entries)


func _build_journal() -> void:
	var entries: Array = []
	var selected := 0
	for r: Dictionary in loot.journal() if loot != null else []:
		var found := 0
		for entry: Dictionary in r["items"]:
			found += int(bool(entry["found"]))
		if int(r["ring"]) == journal_ring:
			selected = entries.size()
		entries.append({"title": String(r["name"]), "subtitle": "%d of %d found" % [found, r["items"].size()],
			"icon": "journal", "action": _open_region.bind(int(r["ring"]))})
	if entries.is_empty():
		entries.append({"title": "Nothing known yet", "icon": "journal"})
	_card_page("Journal", entries, ["Find rumours to learn what lies further out."], selected)


func _open_region(ring: int) -> void:
	journal_ring = ring
	_show(View.REGION)


func _build_region() -> void:
	var entries: Array = []
	var title := "Journal"
	for r: Dictionary in loot.journal() if loot != null else []:
		if int(r["ring"]) != journal_ring:
			continue
		title = String(r["name"])
		for entry: Dictionary in r["items"]:
			var found := bool(entry["found"])
			var text := LootRules.card_text(entry["item"])
			entries.append({"title": text[0], "subtitle": text[1],
				"extra": "Found" if found else "Not found yet", "extra_variant": "" if found else "dim",
				"icon": LootRules.icon(entry["item"])})
	if entries.is_empty():
		entries.append({"title": "Nothing here", "icon": "journal"})
	_card_page(title, entries, [], 0, View.JOURNAL)


func _open_map() -> void:
	_clear()
	map_requested.emit(site)


# The map closed (Back, or a travel): come back to the main page, unless a travel moved the car.
func return_from_map() -> void:
	if rest_stops != null and rest_stops.last_site != site:
		close()
		return
	_show(View.MAIN)


# Travel first, then close: after a parts / car change close() asks the host to save and reload the
# scene, and that save must see the car at the destination (and the respawn point there).
func _travel(target: int) -> void:
	rest_stops.travel_to(target)
	close()


# Readout for tests: the current page's card list (null on TUNE).
func cards() -> CardCarousel:
	return _cards


# Pick the card whose title starts with `text`, as a player would. False if absent or disabled.
func pick(text: String) -> bool:
	return _cards != null and CardUI.pick(_cards, text)
