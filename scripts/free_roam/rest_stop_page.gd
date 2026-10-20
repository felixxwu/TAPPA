class_name RestStopPage
extends CanvasLayer
# Docs: features/free-roam.md, features/menus.md — update in the same change as this file.
# Tests: tests/headless/test_free_roam_rest_stops.gd — extend in the same change (every menu change needs a keyboard+gamepad nav test).
# The rest-stop page (todo/2026-10-19-free-roam-pivot.md decision 9, stage 5 scope): opened when
# the car stops at a rest stop. The car is repaired for free the moment it opens, and the game is
# frozen while it's up. Three pages, all flat MenuPages driven by MenuNav:
#   MAIN    — the stop's name, "Car repaired", and Continue / Tune car / Travel.
#   TUNE    — the shared TuningPanel on the fielded car (car.retune on every edit).
#   TRAVEL  — every other lit rest stop, nearest first; picking one goes there.
# Back (Esc / gamepad B, or the Back buttons) steps TUNE/TRAVEL → MAIN → closed.

signal closed
# The Map button: the host opens the map as the travel picker, over this page.
signal map_requested(site: int)

enum View { MAIN, TUNE, TRAVEL }

@export var rest_stops: RestStops
@export var car: VehicleBody3D
@export var pause_menu: PauseMenu

# The owned-car dict the car was fielded from (free_roam.gd), so tuning edits land on it.
var owned: Dictionary = {}

var view := View.MAIN
var site := -1
var _page: MenuPage
var _continue_button: Button
var _tune_button: Button
var _travel_button: Button
var _tune_panel: TuningPanel
var _travel_buttons: Array[Button] = []
var _map_button: Button


func _init() -> void:
	layer = 6
	process_mode = Node.PROCESS_MODE_ALWAYS


func is_open() -> bool:
	return _page != null


func open(p_site: int) -> void:
	site = p_site
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


func _clear() -> void:
	if _page != null:
		_page.queue_free()
		_page = null
	_travel_buttons.clear()


func _show(v: View) -> void:
	_clear()
	view = v
	match v:
		View.MAIN:
			_build_main()
		View.TUNE:
			_build_tune()
		View.TRAVEL:
			_build_travel()
	UITheme.enforce(_page)


func _build_main() -> void:
	var title := rest_stops.name_of(site) if rest_stops != null else "Rest stop"
	_page = MenuPage.new({"title": "Rest stop", "dim": true})
	add_child(_page)
	var name_label := Label.new()
	name_label.text = title
	_page.body().add_child(name_label)
	var repaired := Label.new()
	repaired.text = "Car repaired"
	_page.body().add_child(repaired)
	_continue_button = _page.add_action(UITheme.row_button("Continue", close))
	_tune_button = _page.add_action(UITheme.row_button("Tune car", _show.bind(View.TUNE)))
	_travel_button = _page.add_action(UITheme.row_button("Travel", _show.bind(View.TRAVEL)))
	_travel_button.disabled = rest_stops == null or rest_stops.travel_targets(site).is_empty()
	_map_button = _page.add_action(UITheme.row_button("Map", _open_map))
	MenuNav.attach(_page, {first = _continue_button, on_back = close})


func _build_tune() -> void:
	_page = MenuPage.new({"title": "Tune car", "dim": true})
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
		car.retune(owned)


func _build_travel() -> void:
	_page = MenuPage.new({"title": "Travel", "dim": true})
	add_child(_page)
	var targets := rest_stops.travel_targets(site)
	var here := rest_stops.streamer.sites.pos[site]
	for t in targets:
		var km := rest_stops.streamer.sites.pos[t].distance_to(here) / 1000.0
		var b := UITheme.row_button("%s  ·  %.1f km" % [rest_stops.name_of(t), km], _travel.bind(t))
		_page.body().add_child(b)
		_travel_buttons.append(b)
	var back := _page.add_action(UITheme.row_button("< Back", _show.bind(View.MAIN)))
	MenuNav.attach(_page, {first = _travel_buttons[0] if not _travel_buttons.is_empty() else back,
		on_back = _show.bind(View.MAIN)})


func _open_map() -> void:
	_clear()
	map_requested.emit(site)


# The map closed (Back, or a travel, which closes it first): come back to the main page, unless a
# travel already moved the car, in which case close for good.
func return_from_map() -> void:
	if rest_stops != null and rest_stops.last_site != site:
		close()
		return
	_show(View.MAIN)


func _travel(target: int) -> void:
	close()
	rest_stops.travel_to(target)


# Readouts for tests.
func travel_buttons() -> Array[Button]:
	return _travel_buttons


func main_buttons() -> Array[Button]:
	return [_continue_button, _tune_button, _travel_button, _map_button]
