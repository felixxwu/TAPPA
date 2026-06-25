extends Control
# HQ — the meta-game hub (todo/menus.md location 1), minimal vertical-slice
# version: a flat placeholder UI (the diegetic 3D car-park / map / tuning-lift
# staging is the full menus build). It is the game's boot scene and a lightweight
# scene with NO track generation.
#
# What the slice covers: ensure a starter car exists, list owned cars + the
# rallies the selected car can enter, and start a rally — handing off to
# RallySession (todo/rally-event-flow.md), which fields the car, runs the events
# and returns to the podium → HQ.

var _selected_instance_id := -1
var _selected_rally_id := ""

var _cars_box: VBoxContainer
var _rallies_box: VBoxContainer
var _status: Label
var _start_button: Button


func _ready() -> void:
	_ensure_starter()
	_build_ui()
	_refresh_cars()


# First run: grant the immortal starter (the anti-soft-lock floor — it can never
# be wrecked, so the player can always field something). Recorded in the profile.
func _ensure_starter() -> void:
	if Save.profile.get("starter_picked", false):
		return
	Save.grant_car("mx5", true)
	Save.profile["starter_picked"] = true
	Save.profile["starter_model_id"] = "mx5"
	Save.save()


func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.12, 0.11, 0.16)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 16.0
	root.offset_top = 16.0
	root.offset_right = -16.0
	root.offset_bottom = -16.0
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	var title := Label.new()
	title.text = "RALLY HQ"
	title.add_theme_font_size_override("font_size", 28)
	root.add_child(title)

	root.add_child(_section_label("Your cars"))
	_cars_box = VBoxContainer.new()
	root.add_child(_cars_box)

	root.add_child(_section_label("Rallies"))
	_rallies_box = VBoxContainer.new()
	root.add_child(_rallies_box)

	_status = Label.new()
	_status.text = "Select a car and a rally."
	root.add_child(_status)

	_start_button = Button.new()
	_start_button.text = "Start Rally"
	_start_button.focus_mode = Control.FOCUS_NONE
	_start_button.disabled = true
	_start_button.pressed.connect(_on_start_pressed)
	root.add_child(_start_button)


func _section_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 16)
	return l


# (Re)build the owned-car buttons. Selecting a car re-derives its eligible rallies.
func _refresh_cars() -> void:
	for child in _cars_box.get_children():
		child.queue_free()
	var cars: Array = Save.profile.get("cars", [])
	if cars.is_empty():
		_cars_box.add_child(_section_label("(no cars)"))
		return
	# Default-select the first owned car if nothing is selected yet.
	if _selected_instance_id < 0 or Save.get_car(_selected_instance_id).is_empty():
		_selected_instance_id = int(cars[0]["instance_id"])
	for car in cars:
		var id := int(car["instance_id"])
		var btn := Button.new()
		btn.text = _car_label(car)
		btn.focus_mode = Control.FOCUS_NONE
		btn.toggle_mode = true
		btn.button_pressed = id == _selected_instance_id
		btn.pressed.connect(_on_car_selected.bind(id))
		_cars_box.add_child(btn)
	_refresh_rallies()


func _car_label(car: Dictionary) -> String:
	var entry := CarLibrary.by_id(String(car.get("model_id", "")))
	var model_name := String(entry.get("name", car.get("model_id", "?")))
	var max_hp: float = entry.get("max_hp", 0.0)
	var hp := float(car.get("hp", 0.0))
	var hp_text := "∞" if car.get("immortal", false) else "%d/%d HP" % [roundi(hp), roundi(max_hp)]
	return "%s  #%d  (%s)" % [model_name, int(car["instance_id"]), hp_text]


# (Re)build the rally buttons for the selected car: only rallies it is eligible
# for, with the showdown shown only once unlocked. Completed rallies are marked
# (still enterable — re-wins farm rewards, todo/reward-system.md).
func _refresh_rallies() -> void:
	for child in _rallies_box.get_children():
		child.queue_free()
	var owned := Save.get_car(_selected_instance_id)
	if owned.is_empty():
		return
	var meta := CarLibrary.by_id(String(owned.get("model_id", "")))
	var sd_unlocked := RallyLibrary.showdown_unlocked(Save.profile)
	for rally in RallyLibrary.RALLIES:
		if rally["showdown"] and not sd_unlocked:
			continue
		if not RallyLibrary.is_eligible(rally, meta):
			continue
		var btn := Button.new()
		var done := Save.rally_completed(String(rally["id"]))
		btn.text = "%s  (diff %d)%s" % [rally["name"], int(rally["difficulty"]), "  ✓" if done else ""]
		btn.focus_mode = Control.FOCUS_NONE
		btn.toggle_mode = true
		btn.button_pressed = String(rally["id"]) == _selected_rally_id
		btn.pressed.connect(_on_rally_selected.bind(String(rally["id"])))
		_rallies_box.add_child(btn)


func _on_car_selected(instance_id: int) -> void:
	_selected_instance_id = instance_id
	_selected_rally_id = ""  # eligibility may have changed; clear the rally pick
	_refresh_cars()
	_update_status()


func _on_rally_selected(rally_id: String) -> void:
	_selected_rally_id = rally_id
	_update_status()


func _update_status() -> void:
	var car := Save.get_car(_selected_instance_id)
	var can_start := not car.is_empty() and _selected_rally_id != ""
	_start_button.disabled = not can_start
	if can_start:
		var rally := RallyLibrary.by_id(_selected_rally_id)
		_status.text = "Field %s in %s" % [_car_label(car), rally["name"]]
	else:
		_status.text = "Select a car and a rally."


# Hand off to the orchestrator. RallySession derives the event target times,
# builds the opponent field, and loads the first event's run scene.
func _on_start_pressed() -> void:
	var owned := Save.get_car(_selected_instance_id)
	var rally := RallyLibrary.by_id(_selected_rally_id)
	if owned.is_empty() or rally.is_empty():
		return
	RallySession.start_rally(rally, owned)
