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

	# The car/rally lists can be taller than a phone screen, so they live in a
	# scroll view that expands to fill the space between the fixed title and the
	# pinned Start button — the primary action stays on-screen no matter how many
	# cars/rallies are listed.
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 8)
	scroll.add_child(content)

	content.add_child(_section_label("Your cars"))
	_cars_box = VBoxContainer.new()
	content.add_child(_cars_box)

	content.add_child(_section_label("Rallies"))
	_rallies_box = VBoxContainer.new()
	content.add_child(_rallies_box)

	_status = Label.new()
	_status.text = "Select a car and a rally."
	content.add_child(_status)

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


# (Re)build the owned-car cards. Selecting a car re-derives its eligible rallies.
# Each card shows the metadata the player needs to make the risk/eligibility call:
# drivetrain / country / type / reward tier / power-to-weight, an HP bar, and any
# installed upgrades (todo/menus.md rig 1+2 — the flat stand-in for the showroom
# rig + world-anchored stats panel).
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
		_cars_box.add_child(_car_card(car))
	_refresh_rallies()


# A selectable stat card for one owned car: header toggle (model + instance), a
# metadata line, an HP bar, and an installed-upgrades line when fitted.
func _car_card(car: Dictionary) -> Control:
	var id := int(car["instance_id"])
	var entry := CarLibrary.by_id(String(car.get("model_id", "")))
	var card := VBoxContainer.new()
	card.add_theme_constant_override("separation", 2)

	var btn := Button.new()
	btn.text = "%s  #%d" % [entry.get("name", car.get("model_id", "?")), id]
	btn.focus_mode = Control.FOCUS_NONE
	btn.toggle_mode = true
	btn.button_pressed = id == _selected_instance_id
	btn.pressed.connect(_on_car_selected.bind(id))
	card.add_child(btn)

	var stats := Label.new()
	stats.add_theme_font_size_override("font_size", 12)
	stats.text = "%s · %s · %s · tier %d · %.2f kW/kg" % [
		_drive_text(int(entry.get("drive_mode", -1))),
		String(entry.get("country", "?")),
		String(entry.get("car_type", "?")),
		int(entry.get("reward_tier", 0)),
		CarLibrary.power_to_weight(entry),
	]
	card.add_child(stats)
	card.add_child(_hp_row(car, entry))

	var ups: Array = car.get("installed_upgrades", [])
	if not ups.is_empty():
		var names: Array[String] = []
		for item_id in ups:
			names.append(String(UpgradeLibrary.by_id(String(item_id)).get("name", item_id)))
		var u := Label.new()
		u.add_theme_font_size_override("font_size", 12)
		u.text = "Upgrades: %s" % ", ".join(names)
		card.add_child(u)
	return card


# An HP bar + readout for a car. The immortal starter shows a full bar and ∞.
func _hp_row(car: Dictionary, entry: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var immortal: bool = car.get("immortal", false)
	var max_hp := float(entry.get("max_hp", 0.0))
	var hp := float(car.get("hp", 0.0))
	var bar := ProgressBar.new()
	bar.custom_minimum_size = Vector2(160, 12)
	bar.show_percentage = false
	bar.max_value = 1.0 if immortal else maxf(1.0, max_hp)
	bar.value = 1.0 if immortal else hp
	row.add_child(bar)
	var label := Label.new()
	label.add_theme_font_size_override("font_size", 12)
	label.text = "∞ HP" if immortal else "%d/%d HP" % [roundi(hp), roundi(max_hp)]
	row.add_child(label)
	return row


func _drive_text(drive_mode: int) -> String:
	match drive_mode:
		CarLibrary.RWD: return "RWD"
		CarLibrary.AWD: return "AWD"
		CarLibrary.FWD: return "FWD"
		_: return "?"


# (Re)build the rally board for the selected car. Unlike the first slice, EVERY
# rally is shown so the player can see what's locked and WHY: a rally the selected
# car can't enter is disabled with its restriction spelled out ("needs RWD"), so
# the unlock path ("win a JP car → Rising Sun opens") is legible. Completed rallies
# are marked ✓ but stay selectable (re-wins farm rewards, todo/reward-system.md).
# The showdown is shown locked with a progress meter until every other rally is done.
func _refresh_rallies() -> void:
	for child in _rallies_box.get_children():
		child.queue_free()
	var owned := Save.get_car(_selected_instance_id)
	if owned.is_empty():
		return
	var meta := CarLibrary.by_id(String(owned.get("model_id", "")))
	var sd_unlocked := RallyLibrary.showdown_unlocked(Save.profile)

	# Showdown progress meter (gameplay.md › the final showdown): completed / total.
	var total := 0
	for rally in RallyLibrary.RALLIES:
		if not rally["showdown"]:
			total += 1
	var done_count := RallyLibrary.completed_count(Save.profile)
	var meter := Label.new()
	meter.add_theme_font_size_override("font_size", 12)
	meter.text = "Progress to the Showdown: %d / %d rallies completed" % [done_count, total]
	_rallies_box.add_child(meter)

	for rally in RallyLibrary.RALLIES:
		var rally_id := String(rally["id"])
		var is_showdown: bool = rally["showdown"]
		var eligible := RallyLibrary.is_eligible(rally, meta)
		var done := Save.rally_completed(rally_id)
		var btn := Button.new()
		btn.focus_mode = Control.FOCUS_NONE
		# A rally is enterable when the car is eligible AND (it's not the showdown,
		# or the showdown is unlocked). Locked rallies are shown but disabled.
		var enterable := eligible and (not is_showdown or sd_unlocked)
		if enterable:
			btn.toggle_mode = true
			btn.button_pressed = rally_id == _selected_rally_id
			btn.text = "%s  (diff %d)%s" % [rally["name"], int(rally["difficulty"]), "  ✓" if done else ""]
			btn.pressed.connect(_on_rally_selected.bind(rally_id))
		else:
			btn.disabled = true
			btn.text = "🔒 %s  (diff %d) — %s" % [
				rally["name"], int(rally["difficulty"]), _lock_reason(rally, is_showdown, sd_unlocked, done_count, total)]
		_rallies_box.add_child(btn)


# Why a shown-but-locked rally can't be entered by the selected car: either the
# showdown gate (complete all rallies first) or the car failing the restriction.
func _lock_reason(rally: Dictionary, is_showdown: bool, sd_unlocked: bool, done_count: int, total: int) -> String:
	if is_showdown and not sd_unlocked:
		return "complete all rallies first (%d/%d)" % [done_count, total]
	return "needs %s" % _restriction_text(rally.get("restriction", {}))


# Human-readable summary of a rally's restriction, for the locked-rally hint and
# (eventually) the briefing panel. Empty restriction is open-class (never locked).
func _restriction_text(restriction: Dictionary) -> String:
	if restriction.is_empty():
		return "any car"
	var parts: Array[String] = []
	if restriction.has("drive_mode"):
		parts.append("%s cars" % _drive_text(int(restriction["drive_mode"])))
	if restriction.has("country"):
		parts.append("%s cars" % String(restriction["country"]))
	if restriction.has("car_type"):
		parts.append("%s body" % String(restriction["car_type"]))
	if restriction.has("engine_min_l"):
		parts.append("engine ≥ %.1f L" % float(restriction["engine_min_l"]))
	if restriction.has("engine_max_l"):
		parts.append("engine ≤ %.1f L" % float(restriction["engine_max_l"]))
	if restriction.has("pw_min"):
		parts.append("power-to-weight ≥ %.2f" % float(restriction["pw_min"]))
	if restriction.has("pw_max"):
		parts.append("power-to-weight ≤ %.2f" % float(restriction["pw_max"]))
	return ", ".join(parts)


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
		var entry := CarLibrary.by_id(String(car.get("model_id", "")))
		var model_name := String(entry.get("name", car.get("model_id", "?")))
		_status.text = "Field %s #%d in %s" % [model_name, int(car["instance_id"]), rally["name"]]
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
