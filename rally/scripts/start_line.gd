class_name StartLine
extends Node3D
# The pre-event start-line scene (todo/menus.md location 2) — the diegetic moment
# between picking a car in HQ and the 3·2·1·GO countdown. It runs inside the live
# run scene (main.tscn) once the world is built and a RallySession is active, and
# shows two things while the car is held locked by the StageManager's STAGING phase:
#
#   * a world-anchored BRIEFING panel — rally name, event N of 3, the car
#     restriction, and the fielded car + its HP bar, "so the risk is legible
#     before you commit" (gameplay.md). A SubViewport Control rendered onto a
#     billboarded Sprite3D — the richer diegetic panel of menus.md rig 2.
#   * a few atmosphere PRESENCE cars staggered at the grid — flavour only, NOT
#     the real opponent field (that's RallyLibrary's per-seed roster). Frozen,
#     collision-off, silenced car props, reusing the HQ car-park prop pattern.
#
# The player launches with menu_select (Enter / gamepad A) or a tap; StartLine then
# hides the briefing and calls StageManager.begin_countdown() to start the run.
#
# Created and wired by world.gd (session runs only). A plain dev boot of main.tscn
# never builds a StartLine and the StageManager goes straight to the countdown.

const CAR_SCENE := preload("res://car.tscn")

var _stage_manager: Node       # the StageManager — begin_countdown() on launch
var _launched := false

# Diegetic nodes.
var _briefing: Node3D          # holds the billboarded panel sprite
var _viewport: SubViewport     # renders the briefing Control onto the sprite
var _presence: Array = []      # the parked atmosphere car props

# Panel controls kept so tests (and a future refresh) can read them without
# depending on the SubViewport actually rendering under headless.
var _rally_label: Label
var _event_label: Label
var _restriction_label: Label
var _car_label: Label
var _hp_bar: ProgressBar
var _hp_label: Label
var _prompt_label: Label


func _cfg() -> GameConfig:
	return Config.data


# Build the start-line scene around the fielded car. `start_xform` is the car's
# global pose at the grid (its spawn), used to lay out the panel + presence cars;
# `terrain` (a TerrainManager, optional) lets presence cars sit on the ground.
func setup(car: Node3D, terrain: Node, stage_manager: Node, rally: Dictionary, event_index: int) -> void:
	_stage_manager = stage_manager
	var start_xform := car.global_transform
	_build_briefing(car, rally, event_index, start_xform)
	_spawn_presence(rally, start_xform, terrain)


# --- Briefing panel (world-anchored SubViewport -> billboarded Sprite3D) ------

func _build_briefing(car: Node3D, rally: Dictionary, event_index: int, start_xform: Transform3D) -> void:
	var cfg := _cfg()
	_briefing = Node3D.new()
	_briefing.name = "Briefing"
	add_child(_briefing)
	_briefing.global_position = start_xform * cfg.start_briefing_offset

	# A SubViewport holding the panel Control. Transparent so only the panel shows;
	# UPDATE_ALWAYS keeps it live (cheap — a static panel) and renders in-game while
	# headless simply never produces pixels, which the logic below doesn't need.
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(360, 300)
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_briefing.add_child(_viewport)
	_viewport.add_child(_build_panel(car, rally, event_index))

	var sprite := Sprite3D.new()
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sprite.shaded = false
	sprite.double_sided = true
	sprite.pixel_size = cfg.start_briefing_pixel_size
	sprite.texture = _viewport.get_texture()
	_briefing.add_child(sprite)


# The briefing Control tree (lives inside the SubViewport). References to the live
# labels / HP bar are retained on the StartLine for tests + future refresh.
func _build_panel(car: Node3D, rally: Dictionary, event_index: int) -> Control:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.09, 0.13, 0.94)
	style.border_color = Color(0.9, 0.7, 0.25, 0.9)
	style.set_border_width_all(3)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(16)
	panel.add_theme_stylebox_override("panel", style)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	panel.add_child(col)

	_rally_label = _line(col, String(rally.get("name", "Rally")), 30)
	_rally_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.35))

	var total: int = rally.get("events", []).size()
	if total <= 0:
		total = RallySession.EVENTS_PER_RALLY
	_event_label = _line(col, "Event %d of %d" % [event_index + 1, total], 18)

	_restriction_label = _line(col, "Eligible: %s" % _restriction_text(rally.get("restriction", {})), 14)
	_restriction_label.modulate = Color(1, 1, 1, 0.8)

	_sep(col)

	_car_label = _line(col, _car_name(car), 20)

	# HP row: a real bar (the "risk is legible" cue), or "INF" for the immortal starter.
	var hp_row := HBoxContainer.new()
	hp_row.add_theme_constant_override("separation", 8)
	col.add_child(hp_row)
	_hp_label = Label.new()
	_hp_label.add_theme_font_size_override("font_size", 14)
	_hp_label.text = "HP"
	hp_row.add_child(_hp_label)
	_hp_bar = ProgressBar.new()
	_hp_bar.max_value = 1.0
	_hp_bar.step = 0.001
	_hp_bar.show_percentage = false
	_hp_bar.custom_minimum_size = Vector2(180, 16)
	_hp_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hp_row.add_child(_hp_bar)
	_apply_hp(car)

	_sep(col)

	_prompt_label = _line(col, "Press ENTER or tap to launch", 16)
	_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt_label.modulate = Color(0.7, 0.9, 1.0)
	return panel


func _line(parent: Node, text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	parent.add_child(l)
	return l


func _sep(parent: Node) -> void:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, 4)
	parent.add_child(s)


# Fill the HP bar from the car's damage model (immortal cars show full + "INF").
func _apply_hp(car: Node) -> void:
	var dmg = car.get("damage") if car != null else null
	if dmg == null:
		_hp_bar.value = 1.0
		_hp_label.text = "HP"
		return
	if bool(dmg.immortal):
		_hp_bar.value = 1.0
		_hp_bar.modulate = Color(0.6, 0.85, 1.0)
		_hp_label.text = "INF HP"
		return
	var frac := clampf(dmg.hp / dmg.max_hp, 0.0, 1.0) if dmg.max_hp > 0.0 else 0.0
	_hp_bar.value = frac
	_hp_bar.modulate = Color.from_hsv(frac * 0.33, 0.8, 0.95)  # green→amber→red, matches the HUD
	_hp_label.text = "%d/%d HP" % [roundi(dmg.hp), roundi(dmg.max_hp)]


func _car_name(car: Node) -> String:
	if car != null and car.has_method("current_car_name"):
		var n: String = car.current_car_name()
		if n != "":
			return n
	return "Your car"


# --- Presence cars (atmosphere only) -----------------------------------------

# Stagger a few frozen car props behind the player at the grid, alternating sides
# and stepping back a row every two cars. Models are picked deterministically from
# the rally's seed so the line-up is stable for a given event.
func _spawn_presence(rally: Dictionary, start_xform: Transform3D, terrain: Node) -> void:
	var cfg := _cfg()
	var count: int = cfg.start_presence_count
	if count <= 0:
		return
	var seed_base := _presence_seed(rally)
	for i in count:
		var side := -1.0 if i % 2 == 0 else 1.0
		# Step back a row every two cars (0,0,1,1,2,…); float math avoids the
		# integer-division warning while keeping the same stepping.
		var row := floorf(float(i) / 2.0) + 1.0
		var local := Vector3(side * cfg.start_presence_lateral, 0.0, row * cfg.start_presence_longitudinal)
		var pos := start_xform * local
		if terrain != null and terrain.has_method("height_at"):
			pos.y = terrain.height_at(pos.x, pos.z) + (start_xform.origin.y - _terrain_floor(terrain, start_xform.origin))
		var model_index := (seed_base + i) % CarLibrary.CARS.size()
		_presence.append(_spawn_prop(model_index, pos, start_xform.basis))


# Ride height of the player car above the terrain at its spawn — reused so presence
# cars sit at the same height over their (possibly different) ground sample.
func _terrain_floor(terrain: Node, origin: Vector3) -> float:
	if terrain != null and terrain.has_method("height_at"):
		return terrain.height_at(origin.x, origin.z)
	return origin.y


# A parked, silent, physics-frozen car prop (the HQ car-park pattern): its own mesh
# copies so a mixed line-up keeps each body at its true size, no collision, no sim.
func _spawn_prop(model_index: int, pos: Vector3, heading: Basis) -> Node3D:
	var car := CAR_SCENE.instantiate()
	add_child(car)
	if car.has_method("apply_car"):
		car.apply_car(model_index)
	_dup_meshes(car)
	car.global_transform = Transform3D(heading, pos)
	car.freeze = true
	car.collision_layer = 0
	car.collision_mask = 0
	var audio := car.get_node_or_null("EngineAudio")
	if audio != null and audio.has_method("stop"):
		audio.stop()
	car.process_mode = Node.PROCESS_MODE_DISABLED
	return car


func _dup_meshes(car: Node) -> void:
	for mi in car.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh != null:
			m.mesh = m.mesh.duplicate()


# Deterministic per-rally seed for the presence line-up (stable across re-entries).
func _presence_seed(rally: Dictionary) -> int:
	var events: Array = rally.get("events", [])
	if not events.is_empty():
		return int(events[0].get("seed", 0))
	return 0


# --- Launch ------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if _launched:
		return
	if event.is_action_pressed("menu_select") \
			or (event is InputEventScreenTouch and event.pressed) \
			or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		launch()


# Hide the briefing and hand off to the countdown. Idempotent — a second tap during
# the countdown does nothing (begin_countdown() is itself a no-op outside STAGING).
func launch() -> void:
	if _launched:
		return
	_launched = true
	if _briefing != null:
		_briefing.visible = false
	if _viewport != null:
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED  # stop rendering the hidden panel
	if _stage_manager != null and _stage_manager.has_method("begin_countdown"):
		_stage_manager.begin_countdown()


func has_launched() -> bool:
	return _launched


func presence_count() -> int:
	return _presence.size()


# --- Restriction text (mirrors hq.gd's wording for the briefing) -------------

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
		parts.append("engine >= %.1f L" % float(restriction["engine_min_l"]))
	if restriction.has("engine_max_l"):
		parts.append("engine <= %.1f L" % float(restriction["engine_max_l"]))
	if restriction.has("pw_min"):
		parts.append("power-to-weight >= %.2f" % float(restriction["pw_min"]))
	if restriction.has("pw_max"):
		parts.append("power-to-weight <= %.2f" % float(restriction["pw_max"]))
	return ", ".join(parts)


func _drive_text(drive_mode: int) -> String:
	match drive_mode:
		CarLibrary.RWD: return "RWD"
		CarLibrary.AWD: return "AWD"
		CarLibrary.FWD: return "FWD"
		_: return "?"
