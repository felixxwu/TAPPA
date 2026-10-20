class_name RestStopPage
extends CanvasLayer
# Docs: features/free-roam.md, features/loot.md, features/menus.md — update in the same change as this file.
# Tests: tests/headless/test_free_roam_rest_stops.gd, tests/headless/test_loot.gd — extend in the same change (every menu change needs a keyboard+gamepad nav test).
# The rest-stop page (todo/2026-10-19-free-roam-pivot.md decision 9): opened when the car stops at
# a rest stop. Opening it banks the carried loot (LootDirector.bank) and repairs the car for free,
# and the game is frozen while it's up. Flat MenuPages driven by MenuNav, one column of rows:
#   MAIN    — the stop, what was banked, and Continue / Tune car / Parts / Garage / Travel / Map /
#             Journal.
#   TUNE    — the shared TuningPanel on the active car.
#   PARTS   — the active car's fitted parts (press to take one off) and the stash (press to fit;
#             a part for a taken slot swaps with what's there).
#   GARAGE  — every owned car; press one to drive it.
#   TRAVEL  — every other lit rest stop, nearest first.
#   JOURNAL — each revealed biome's loot, found or not.
# Back (Esc / gamepad B, or the Back rows) steps a sub-page → MAIN → closed. A change of parts or car
# is applied when the page closes: `car_changed` asks the host to re-field the car.

signal closed
# The Map row: the host opens the map as the travel picker, over this page.
signal map_requested(site: int)
signal car_changed

enum View { MAIN, TUNE, PARTS, GARAGE, TRAVEL, JOURNAL }

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
var _page: MenuPage
var _rows: Array[Button] = []
var _tune_panel: TuningPanel


func _init() -> void:
	layer = 6
	process_mode = Node.PROCESS_MODE_ALWAYS


func is_open() -> bool:
	return _page != null


func open(p_site: int) -> void:
	site = p_site
	dirty = false
	banked = loot.bank() if loot != null else []
	if car != null and car.get("damage") != null:
		(car.damage as DamageModel).repair(Config.data)
	get_tree().paused = true
	if pause_menu != null:
		pause_menu.set_input_enabled(false)
	_show(View.MAIN)


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
		_page.queue_free()
		_page = null
	_rows.clear()


func _show(v: View) -> void:
	_clear()
	view = v
	match v:
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
	UITheme.enforce(_page)


func _new_page(title: String) -> void:
	_page = MenuPage.new({"title": title, "dim": true})
	add_child(_page)


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_page.body().add_child(l)
	return l


func _row(text: String, on_press: Callable) -> Button:
	var b := UITheme.row_button(text, on_press)
	_page.body().add_child(b)
	_rows.append(b)
	return b


func _attach(back_to: Callable) -> void:
	MenuNav.attach(_page, {first = _first_enabled(), on_back = back_to})


func _first_enabled() -> Control:
	for b in _rows:
		if not b.disabled:
			return b
	return _rows[0] if not _rows.is_empty() else null


func _back_row() -> void:
	_row("< Back", _show.bind(View.MAIN))


func _build_main() -> void:
	_new_page("Rest stop")
	_label(rest_stops.name_of(site) if rest_stops != null else "")
	_label("Car repaired")
	if not banked.is_empty():
		var names: Array[String] = []
		for item: Dictionary in banked:
			names.append(LootLibrary.label(item))
		_label("Banked: " + ", ".join(names))
	_row("Continue", close)
	_row("Tune car", _show.bind(View.TUNE))
	_row("Parts", _show.bind(View.PARTS))
	_row("Garage", _show.bind(View.GARAGE))
	var travel := _row("Travel", _show.bind(View.TRAVEL))
	travel.disabled = rest_stops == null or rest_stops.travel_targets(site).is_empty()
	_row("Map", _open_map)
	_row("Journal", _show.bind(View.JOURNAL))
	_attach(close)


func _build_tune() -> void:
	_new_page("Tune car")
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
		car.retune(LootLibrary.fielded(owned))


func _build_parts() -> void:
	_new_page("Parts")
	var fitted: Array = owned.get("parts", [])
	_label("Fitted to this car" if not fitted.is_empty() else "Nothing fitted")
	for i in fitted.size():
		_row("- " + LootLibrary.label(fitted[i]), _unfit.bind(i))
	var stash := WorldSession.list("stash")
	_label("Stash" if not stash.is_empty() else "The stash is empty")
	for i in stash.size():
		var part: Dictionary = stash[i]
		var b := _row("+ " + LootLibrary.label(part), _fit.bind(i))
		var slot_ok := LootLibrary.can_fit(owned, part) or not LootLibrary.occupant(owned, part).is_empty()
		b.disabled = not slot_ok or _same_id_fitted(part)
	_back_row()
	_attach(_show.bind(View.MAIN))


func _same_id_fitted(part: Dictionary) -> bool:
	for p: Dictionary in owned.get("parts", []):
		if String(p["id"]) == String(part["id"]):
			return true
	return false


func _fit(stash_index: int) -> void:
	var stash := WorldSession.list("stash")
	var part: Dictionary = stash[stash_index]
	var parts: Array = owned.get("parts", []).duplicate()
	var taken := LootLibrary.occupant(owned, part)
	stash.remove_at(stash_index)
	if not taken.is_empty():
		parts.erase(taken)
		stash.append(taken)
	parts.append(part)
	_set_parts(parts)
	WorldSession.set_list("stash", stash)
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
	_new_page("Garage")
	var active := int(owned.get("instance_id", -1))
	for c: Dictionary in Save.profile.get(Save.KEY_CARS, []):
		var model := String(c.get("model_id", ""))
		var id := int(c.get("instance_id", -1))
		var b := _row(String(CarLibrary.by_id(model).get("name", model)) + ("  (driving)" if id == active else ""), _drive.bind(id))
		b.disabled = id == active
	_back_row()
	_attach(_show.bind(View.MAIN))


func _drive(instance_id: int) -> void:
	WorldSession.set_active_car(instance_id)
	owned = WorldSession.active_car()
	dirty = true
	_show(View.GARAGE)


func _build_travel() -> void:
	_new_page("Travel")
	var here := rest_stops.streamer.sites.pos[site]
	for t in rest_stops.travel_targets(site):
		var km := rest_stops.streamer.sites.pos[t].distance_to(here) / 1000.0
		_row("%s  ·  %.1f km" % [rest_stops.name_of(t), km], _travel.bind(t))
	_back_row()
	_attach(_show.bind(View.MAIN))


func _build_journal() -> void:
	_new_page("Journal")
	var rings: Array = loot.journal() if loot != null else []
	for r: Dictionary in rings:
		_label(String(r["name"]).to_upper())
		for entry: Dictionary in r["items"]:
			_label(("[x] " if bool(entry["found"]) else "[ ] ") + String(entry["label"]))
	if rings.is_empty():
		_label("Nothing known yet")
	_label("Find rumours to learn what lies further out.")
	_back_row()
	_attach(_show.bind(View.MAIN))


func _open_map() -> void:
	_clear()
	map_requested.emit(site)


# The map closed (Back, or a travel): come back to the main page, unless a travel moved the car.
func return_from_map() -> void:
	if rest_stops != null and rest_stops.last_site != site:
		close()
		return
	_show(View.MAIN)


func _travel(target: int) -> void:
	close()
	rest_stops.travel_to(target)


# Readouts for tests: the page's rows, top to bottom, and one by its leading text.
func rows() -> Array[Button]:
	return _rows


func row(text: String) -> Button:
	for b in _rows:
		if b.text.to_lower().begins_with(text.to_lower()):
			return b
	return null
