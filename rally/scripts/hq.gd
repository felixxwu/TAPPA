extends Node3D
# HQ — the meta-game hub (todo/menus.md location 1). This is the FIRST diegetic 3D
# slice (todo/diegetic-hq.md): the flat car-park surface is replaced by a real 3D
# showroom — a menu camera framing your car in a lit lot, cycled prev/next — while
# the rally board + Start stay a flat overlay (the map → 3D-pins port is a later
# slice). It is the game's boot scene and stays lightweight (NO track generation).
#
# Scope note (todo/diegetic-hq.md): this slice shows ONE focused car at a time (the
# proven one-car-at-a-time invariant — `Car.apply_owned` mutates the shared
# `Config.data` and the car scene's mesh sub-resources, so configuring N cars at
# once would stomp them). A simultaneous parked lineup is the immediate follow-up,
# once per-instance mesh duplication is handled and the result can be eyeballed.

const CAR_SCENE := preload("res://car.tscn")

var _selected_instance_id := -1
var _selected_rally_id := ""

# Showroom state: the owned-car list and which one is focused (shown + selected).
var _owned: Array = []
var _focus := 0
var _car: Node3D = null

# 3D staging.
var _camera: Camera3D
var _display_marker: Marker3D
var _stats_label: Label3D
var _cam_tween: Tween

# Flat overlay widgets.
var _rallies_box: VBoxContainer
var _status: Label
var _start_button: Button
var _car_name_label: Label
var _car_stats_label: Label


func _ready() -> void:
	_ensure_starter()
	_build_world()
	_build_overlay()
	_reload_owned()
	_show_focused_car()


# First run: grant the immortal starter (the anti-soft-lock floor — it can never
# be wrecked, so the player can always field something). Recorded in the profile.
func _ensure_starter() -> void:
	if Save.profile.get("starter_picked", false):
		return
	Save.grant_car("mx5", true)
	Save.profile["starter_picked"] = true
	Save.profile["starter_model_id"] = "mx5"
	Save.save()


# --- 3D world (the lot) ------------------------------------------------------

func _build_world() -> void:
	var cfg: GameConfig = Config.data

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = cfg.background_color
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.6, 0.68)
	e.ambient_light_energy = 1.0
	env.environment = e
	add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-50.0), deg_to_rad(40.0), 0.0)
	sun.light_energy = 1.1
	add_child(sun)

	# The lot floor: a plain plane (visual only — the parked car is physics-frozen,
	# so no collider is needed).
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(60.0, 60.0)
	ground.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.18, 0.19, 0.22)
	ground.material_override = mat
	add_child(ground)

	# Where the focused car sits.
	_display_marker = Marker3D.new()
	add_child(_display_marker)

	# A floating stats panel beside the car (Label3D for the slice; the SubViewport
	# panel of menus.md rig 2 is deferred). Billboarded so it always faces the camera.
	_stats_label = Label3D.new()
	_stats_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_stats_label.modulate = Color(1, 1, 1)
	_stats_label.outline_size = 12
	_stats_label.font_size = 64
	_stats_label.pixel_size = 0.006
	_stats_label.position = Vector3(-2.6, 1.4, 0.0)
	_stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	add_child(_stats_label)

	_camera = Camera3D.new()
	_camera.current = true
	add_child(_camera)
	_snap_camera_to_focus()


# --- Flat overlay (rally board + start) --------------------------------------

func _build_overlay() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 16.0
	root.offset_top = 16.0
	root.offset_right = -16.0
	root.offset_bottom = -16.0
	root.add_theme_constant_override("separation", 8)
	layer.add_child(root)

	var title := Label.new()
	title.text = "RALLY HQ"
	title.add_theme_font_size_override("font_size", 28)
	root.add_child(title)

	# Car selector: ◄ / ► cycle the focused car (mirrors the menu_left/right inputs
	# and the swipe gestures the diegetic spec calls for; tap-friendly for mobile).
	var nav := HBoxContainer.new()
	nav.add_theme_constant_override("separation", 8)
	root.add_child(nav)
	var prev := Button.new()
	prev.text = "◄"
	prev.focus_mode = Control.FOCUS_NONE
	prev.pressed.connect(_cycle_focus.bind(-1))
	nav.add_child(prev)
	_car_name_label = Label.new()
	_car_name_label.add_theme_font_size_override("font_size", 18)
	_car_name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_car_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	nav.add_child(_car_name_label)
	var next := Button.new()
	next.text = "►"
	next.focus_mode = Control.FOCUS_NONE
	next.pressed.connect(_cycle_focus.bind(1))
	nav.add_child(next)

	_car_stats_label = Label.new()
	_car_stats_label.add_theme_font_size_override("font_size", 12)
	root.add_child(_car_stats_label)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 8)
	scroll.add_child(content)

	content.add_child(_section_label("Rallies"))
	_rallies_box = VBoxContainer.new()
	content.add_child(_rallies_box)

	_status = Label.new()
	_status.text = "Pick a rally."
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


# --- Showroom (the focused car) ----------------------------------------------

# Re-read the owned-car list from the save and clamp the focus into range.
func _reload_owned() -> void:
	_owned = Save.profile.get("cars", [])
	if _owned.is_empty():
		_focus = 0
	else:
		_focus = clampi(_focus, 0, _owned.size() - 1)


# Focus the owned car with this instance id (re-reading the save first, so a car
# just won/granted shows up). Used by the reward arrival and tests.
func focus_instance(instance_id: int) -> void:
	_reload_owned()
	for i in _owned.size():
		if int(_owned[i].get("instance_id", -1)) == instance_id:
			_focus = i
			break
	_show_focused_car()


# Step the focus to the prev/next owned car (wrapping), re-reading the save so the
# list stays current.
func _cycle_focus(step: int) -> void:
	_reload_owned()
	if _owned.is_empty():
		return
	_focus = wrapi(_focus + step, 0, _owned.size())
	_show_focused_car()


# Spawn (or respawn) the focused car as a parked, silent, physics-frozen prop, make
# it the selected car, and refresh the camera + panels + rally board around it.
func _show_focused_car() -> void:
	if _owned.is_empty():
		_selected_instance_id = -1
		_car_name_label.text = "(no cars)"
		_car_stats_label.text = ""
		_stats_label.text = ""
		_refresh_rallies()
		_update_status()
		return
	var owned: Dictionary = _owned[_focus]
	_selected_instance_id = int(owned.get("instance_id", -1))
	_spawn_focused_car(owned)
	var entry := CarLibrary.by_id(String(owned.get("model_id", "")))
	var header := "%s  #%d  (%d of %d)" % [
		entry.get("name", owned.get("model_id", "?")), _selected_instance_id, _focus + 1, _owned.size()]
	_car_name_label.text = header
	var stats := _car_stats_text(owned, entry)
	_car_stats_label.text = stats
	_stats_label.text = "%s\n%s" % [entry.get("name", "?"), stats]
	_ease_camera_to_focus()
	_refresh_rallies()
	_update_status()


func _spawn_focused_car(owned: Dictionary) -> void:
	if _car != null:
		_car.queue_free()
		_car = null
	var car := CAR_SCENE.instantiate()
	add_child(car)
	car.apply_owned(owned)
	# Park it: sit it exactly at the marker, kill physics + input + engine audio so
	# it's a pure static prop (no driving, no idle engine note in the menu).
	car.global_transform = _display_marker.global_transform
	car.freeze = true
	car.collision_layer = 0
	car.collision_mask = 0
	var audio := car.get_node_or_null("EngineAudio")
	if audio != null and audio.has_method("stop"):
		audio.stop()
	car.process_mode = Node.PROCESS_MODE_DISABLED
	_car = car


# One-line car summary shared by the overlay and the 3D Label3D.
func _car_stats_text(owned: Dictionary, entry: Dictionary) -> String:
	var immortal: bool = owned.get("immortal", false)
	var max_hp := float(entry.get("max_hp", 0.0))
	var hp := float(owned.get("hp", 0.0))
	var hp_text := "∞ HP" if immortal else "%d/%d HP" % [roundi(hp), roundi(max_hp)]
	return "%s · %s · %s · tier %d · %.2f kW/kg · %s" % [
		_drive_text(int(entry.get("drive_mode", -1))),
		String(entry.get("country", "?")),
		String(entry.get("car_type", "?")),
		int(entry.get("reward_tier", 0)),
		CarLibrary.power_to_weight(entry),
		hp_text,
	]


func _drive_text(drive_mode: int) -> String:
	match drive_mode:
		CarLibrary.RWD: return "RWD"
		CarLibrary.AWD: return "AWD"
		CarLibrary.FWD: return "FWD"
		_: return "?"


# --- Menu camera -------------------------------------------------------------

# The framing transform for the focused car: a 3/4 hero shot from the configured
# offset, looking at the car a little above its origin.
func _camera_target_xform() -> Transform3D:
	var cfg: GameConfig = Config.data
	var car_pos := _display_marker.global_transform.origin
	var eye := car_pos + cfg.menu_camera_offset
	var look := car_pos + Vector3.UP * cfg.menu_camera_look_height
	var t := Transform3D.IDENTITY
	t.origin = eye
	return t.looking_at(look, Vector3.UP)  # looking_at keeps the origin (the eye)


func _snap_camera_to_focus() -> void:
	_camera.global_transform = _camera_target_xform()


# Ease the camera into the framing over GameConfig.menu_camera_move_time (a small
# settle each time you cycle cars). Snaps when the move time is ~0.
func _ease_camera_to_focus() -> void:
	var cfg: GameConfig = Config.data
	if _cam_tween != null and _cam_tween.is_valid():
		_cam_tween.kill()
	if cfg.menu_camera_move_time <= 0.0:
		_snap_camera_to_focus()
		return
	_cam_tween = create_tween()
	_cam_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_cam_tween.tween_property(_camera, "global_transform", _camera_target_xform(), cfg.menu_camera_move_time)


# --- Rally board (flat overlay) ----------------------------------------------

# (Re)build the rally board for the focused car. EVERY rally is shown so the player
# can see what's locked and WHY: a rally the car can't enter is disabled with its
# restriction spelled out ("needs RWD"), so the unlock path is legible. Completed
# rallies are marked ✓ but stay selectable (re-wins farm rewards). The showdown is
# shown locked with a progress meter until every other rally is done.
func _refresh_rallies() -> void:
	for child in _rallies_box.get_children():
		child.queue_free()
	var owned := Save.get_car(_selected_instance_id)
	if owned.is_empty():
		return
	var meta := CarLibrary.by_id(String(owned.get("model_id", "")))
	var sd_unlocked := RallyLibrary.showdown_unlocked(Save.profile)

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


# Why a shown-but-locked rally can't be entered by the focused car: either the
# showdown gate (complete all rallies first) or the car failing the restriction.
func _lock_reason(rally: Dictionary, is_showdown: bool, sd_unlocked: bool, done_count: int, total: int) -> String:
	if is_showdown and not sd_unlocked:
		return "complete all rallies first (%d/%d)" % [done_count, total]
	return "needs %s" % _restriction_text(rally.get("restriction", {}))


# Human-readable summary of a rally's restriction, for the locked-rally hint.
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
		_status.text = "Pick a rally."


# Hand off to the orchestrator. RallySession derives the event target times,
# builds the opponent field, and loads the first event's run scene.
func _on_start_pressed() -> void:
	var owned := Save.get_car(_selected_instance_id)
	var rally := RallyLibrary.by_id(_selected_rally_id)
	if owned.is_empty() or rally.is_empty():
		return
	RallySession.start_rally(rally, owned)


# --- Menu input (todo/menus.md › Menu navigation & input) --------------------

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("menu_left"):
		_cycle_focus(-1)
	elif event.is_action_pressed("menu_right"):
		_cycle_focus(1)
	elif event.is_action_pressed("menu_select") and not _start_button.disabled:
		_on_start_pressed()
