extends Node3D
# HQ — the meta-game hub (todo/menus.md location 1), diegetic 3D build
# (todo/diegetic-hq.md). Two SEPARATE screens, in this order:
#   1. WORLD MAP (flat overlay) — pick a rally from pins on a basic map.
#   2. CAR SELECT (3D car park) — pick from the cars ELIGIBLE for that rally; the
#      eligible cars are parked in a row and the menu camera pans between them.
# Only one screen's controls show at a time. Start (on the car screen) hands off to
# RallySession. It is the game's boot scene and stays lightweight (NO track gen).
#
# Shared-resource note: car.tscn's body/wheel meshes are SubResources shared across
# instances, so apply_car sizing one parked car would resize every other. After
# apply_owned each parked car gets its OWN mesh copies (_dup_meshes) so a mixed lot
# shows each at its true size. apply_owned also writes the shared Config.data (last
# car wins) — harmless here: the props don't simulate, and world.gd re-applies the
# fielded car's config before a run.

enum Screen { MAP, DETAIL, CARS }

# 1st place earns 3 stars, 2nd → 2, 3rd → 1, anything else (incl. not completed) → 0.
const MAX_STARS := 3


# A row of DRAWN stars (filled = earned). Drawn rather than ★/☆ text because the
# project's font has no glyphs for those symbols (they'd render as tofu boxes).
class StarRow extends Control:
	const STAR_R := 8.0
	const GAP := 5.0
	var _earned := 0
	var _total := 3

	func _init(earned: int, total: int) -> void:
		_earned = earned
		_total = total
		custom_minimum_size = Vector2(_total * (STAR_R * 2.0 + GAP), STAR_R * 2.0 + 4.0)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		for i in _total:
			var center := Vector2(STAR_R + i * (STAR_R * 2.0 + GAP), STAR_R + 2.0)
			var col := Color(1.0, 0.82, 0.3) if i < _earned else Color(0.32, 0.34, 0.40)
			draw_colored_polygon(_star_points(center, STAR_R), col)

	func _star_points(center: Vector2, r: float) -> PackedVector2Array:
		var pts := PackedVector2Array()
		for k in 10:
			var ang := -PI / 2.0 + k * PI / 5.0
			var rad := r if k % 2 == 0 else r * 0.45
			pts.append(center + Vector2(cos(ang), sin(ang)) * rad)
		return pts

const CAR_SCENE := preload("res://car.tscn")

var _screen: int = Screen.MAP
var _selected_rally_id := ""
var _selected_instance_id := -1

# Car-select state: the owned cars eligible for the chosen rally, the parked car
# nodes + their lot markers (parallel to _eligible), and which slot is focused.
var _eligible: Array = []
var _cars: Array = []
var _markers: Array = []
var _focus := 0

# 3D staging (the car park).
var _camera: Camera3D
var _stats_label: Label3D
var _cam_tween: Tween

# World-map overlay. The map content is larger than the on-screen frame and is
# panned (dragged) within it; pins ride on the content.
const MAP_SIZE := Vector2(1800.0, 1200.0)
var _map_layer: CanvasLayer
var _map_frame: Control      # the on-screen viewport into the map (clips + pans)
var _map_content: Control    # the full map plane (MAP_SIZE); panned by moving it
var _map_bg: ColorRect
var _map_meter: Label
var _panning := false
var _map_centered := false

# Rally-detail overlay (screen 2).
var _detail_layer: CanvasLayer
var _detail_title: Label
var _detail_body: Label

# Car-select overlay.
var _car_layer: CanvasLayer
var _rally_banner: Label
var _car_name_label: Label
var _car_stats_label: Label
var _start_button: Button
var _no_eligible_label: Label


func _ready() -> void:
	_ensure_starter()
	_build_world()
	_build_map_overlay()
	_build_detail_overlay()
	_build_car_overlay()
	_show_map()


# First run: grant the immortal starter (the anti-soft-lock floor — it can never
# be wrecked, so the player can always field something). Recorded in the profile.
func _ensure_starter() -> void:
	if Save.profile.get("starter_picked", false):
		return
	Save.grant_car("mx5", true)
	Save.profile["starter_picked"] = true
	Save.profile["starter_model_id"] = "mx5"
	Save.save()


# --- 3D world (the lot, used by the car-select screen) -----------------------

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

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(120.0, 60.0)
	ground.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.18, 0.19, 0.22)
	ground.material_override = mat
	add_child(ground)

	# Billboarded stats panel beside the focused car (Label3D for now; the
	# SubViewport panel of menus.md rig 2 is deferred).
	_stats_label = Label3D.new()
	_stats_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_stats_label.outline_size = 12
	_stats_label.font_size = 64
	_stats_label.pixel_size = 0.006
	_stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	add_child(_stats_label)

	_camera = Camera3D.new()
	_camera.current = true
	add_child(_camera)


# --- World-map overlay (screen 1) --------------------------------------------

func _build_map_overlay() -> void:
	_map_layer = CanvasLayer.new()
	add_child(_map_layer)

	# Everything except the pins ignores the mouse, so a press on empty map falls
	# through to _unhandled_input (where drag-panning lives); pins keep STOP so they
	# stay clickable.
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.06, 0.08, 0.11)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map_layer.add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 16.0
	root.offset_top = 16.0
	root.offset_right = -16.0
	root.offset_bottom = -16.0
	root.add_theme_constant_override("separation", 8)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map_layer.add_child(root)

	var title := Label.new()
	title.text = "WORLD MAP — drag to pan, tap a rally"
	title.add_theme_font_size_override("font_size", 28)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(title)

	_map_meter = Label.new()
	_map_meter.add_theme_font_size_override("font_size", 14)
	_map_meter.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_map_meter)

	# The map: a clipping frame (the viewport into the world) holding a larger map
	# plane (_map_content, MAP_SIZE) that is dragged around inside it. Pins are
	# placed on the content by fractional anchors, so they ride along when panning.
	# (Basic flat map; the stylised 3D map plane of menus.md rig 3 is a later slice.)
	_map_frame = Control.new()
	_map_frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_map_frame.clip_contents = true
	_map_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map_frame.resized.connect(_on_map_resized)
	root.add_child(_map_frame)

	_map_content = Control.new()
	_map_content.size = MAP_SIZE
	_map_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map_frame.add_child(_map_content)

	_map_bg = ColorRect.new()
	_map_bg.size = MAP_SIZE
	_map_bg.color = Color(0.13, 0.18, 0.16)
	_map_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map_content.add_child(_map_bg)


func _on_map_resized() -> void:
	# Centre the map the first time the frame gets a real size, then keep the pan
	# clamped to the edges on later resizes.
	if not _map_centered and _map_frame.size.x > 0.0:
		_map_content.position = (_map_frame.size - MAP_SIZE) * 0.5
		_map_centered = true
	_clamp_map()


# (Re)build the rally pins: a simple clickable icon with the rally name and a
# star rating under it (3 stars for a 1st-place best, 2 for 2nd, 1 for 3rd, else
# empty). Clicking opens the rally detail (screen 2). The showdown icon is locked
# (disabled) until all other rallies are completed.
func _refresh_map() -> void:
	for child in _map_content.get_children():
		if child != _map_bg:
			child.queue_free()
	var sd_unlocked := RallyLibrary.showdown_unlocked(Save.profile)
	var total := 0
	for rally in RallyLibrary.RALLIES:
		if not rally["showdown"]:
			total += 1
	var done_count := RallyLibrary.completed_count(Save.profile)
	_map_meter.text = "Progress to the Showdown: %d / %d rallies completed" % [done_count, total]

	for rally in RallyLibrary.RALLIES:
		_map_content.add_child(_map_pin(rally, sd_unlocked))


# One map pin: [icon button] over [name] over [stars], placed at the rally's
# fractional map_pos. The icon button carries the rally id in metadata so the rest
# of the UI (and tests) can find it; only the icon is clickable.
func _map_pin(rally: Dictionary, sd_unlocked: bool) -> Control:
	var rally_id := String(rally["id"])
	var locked: bool = rally["showdown"] and not sd_unlocked
	var pin := VBoxContainer.new()
	pin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pin.alignment = BoxContainer.ALIGNMENT_CENTER

	var icon := _pin_icon(rally_id, locked, int(rally.get("difficulty", 1)))
	if not locked:
		icon.pressed.connect(_on_rally_pin.bind(rally_id))
	pin.add_child(icon)

	var name_lbl := Label.new()
	name_lbl.text = String(rally["name"])
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 13)
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pin.add_child(name_lbl)

	# Stars are DRAWN (StarRow), not font glyphs — the project font has no ★/☆.
	var stars := StarRow.new(_stars_for(rally_id), MAX_STARS)
	stars.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	pin.add_child(stars)

	var mp: Vector2 = rally.get("map_pos", Vector2(0.5, 0.5))
	pin.anchor_left = mp.x
	pin.anchor_right = mp.x
	pin.anchor_top = mp.y
	pin.anchor_bottom = mp.y
	pin.offset_left = -80.0
	pin.offset_right = 80.0
	pin.offset_top = -36.0
	pin.offset_bottom = 48.0
	return pin


# The clickable map marker: a rounded colour chip (tier-coloured, grey when locked)
# — a "simple icon" that needs no font glyph. Carries the rally id in metadata.
func _pin_icon(rally_id: String, locked: bool, difficulty: int) -> Button:
	var icon := Button.new()
	icon.focus_mode = Control.FOCUS_NONE
	icon.custom_minimum_size = Vector2(44.0, 44.0)
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	icon.set_meta("rally_id", rally_id)
	icon.disabled = locked
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.35, 0.37, 0.42) if locked else _tier_color(difficulty)
	sb.set_corner_radius_all(10)
	sb.set_border_width_all(2)
	sb.border_color = Color(0.0, 0.0, 0.0, 0.45)
	for state in ["normal", "hover", "pressed", "disabled"]:
		icon.add_theme_stylebox_override(state, sb)
	return icon


func _tier_color(difficulty: int) -> Color:
	match difficulty:
		1: return Color(0.32, 0.70, 0.42)   # green
		2: return Color(0.30, 0.56, 0.86)   # blue
		3: return Color(0.92, 0.62, 0.26)   # orange
		_: return Color(0.86, 0.32, 0.32)   # red (showdown / top tier)


# Stars earned in a rally from the player's best finish: 1st → 3, 2nd → 2, 3rd → 1,
# anything else (or never placed) → 0.
func _stars_for(rally_id: String) -> int:
	var placed := Save.best_placement(rally_id)
	if placed >= 1 and placed <= MAX_STARS:
		return MAX_STARS + 1 - placed
	return 0


# --- Map panning (drag / touch / controller stick) ---------------------------

# Move the map plane by a pointer delta and keep it clamped to the frame edges.
func _pan_map(delta: Vector2) -> void:
	_map_content.position += delta
	_clamp_map()


# Keep the map plane covering the frame: you can't drag past its edges.
func _clamp_map() -> void:
	var fs := _map_frame.size
	var pos := _map_content.position
	pos.x = clampf(pos.x, minf(0.0, fs.x - MAP_SIZE.x), maxf(0.0, fs.x - MAP_SIZE.x))
	pos.y = clampf(pos.y, minf(0.0, fs.y - MAP_SIZE.y), maxf(0.0, fs.y - MAP_SIZE.y))
	_map_content.position = pos


func _on_rally_pin(rally_id: String) -> void:
	_selected_rally_id = rally_id
	_show_detail()


# --- Rally-detail overlay (screen 2) -----------------------------------------

func _build_detail_overlay() -> void:
	_detail_layer = CanvasLayer.new()
	add_child(_detail_layer)

	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.08, 0.10, 0.14)
	_detail_layer.add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 24.0
	root.offset_top = 24.0
	root.offset_right = -24.0
	root.offset_bottom = -24.0
	root.add_theme_constant_override("separation", 12)
	_detail_layer.add_child(root)

	_detail_title = Label.new()
	_detail_title.add_theme_font_size_override("font_size", 30)
	root.add_child(_detail_title)

	_detail_body = Label.new()
	_detail_body.add_theme_font_size_override("font_size", 16)
	_detail_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_detail_body)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	root.add_child(actions)
	var back := Button.new()
	back.text = "< Map"
	back.focus_mode = Control.FOCUS_NONE
	back.pressed.connect(_show_map)
	actions.add_child(back)
	var enter := Button.new()
	enter.text = "Enter Rally — choose car >"
	enter.focus_mode = Control.FOCUS_NONE
	enter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	enter.pressed.connect(_enter_car_screen)
	actions.add_child(enter)


# Show the detail screen for the selected rally: name, difficulty, restriction,
# event count, and the player's best result / star rating.
func _show_detail() -> void:
	_screen = Screen.DETAIL
	_clear_lineup()
	_map_layer.visible = false
	_car_layer.visible = false
	_detail_layer.visible = true
	var rally := RallyLibrary.by_id(_selected_rally_id)
	_detail_title.text = String(rally.get("name", "?"))
	var best := Save.best_placement(_selected_rally_id)
	var best_line := "Best finish: P%d   (%d / %d stars)" % [best, _stars_for(_selected_rally_id), MAX_STARS] if best > 0 \
		else "Not yet completed (finish top 3 to earn stars)"
	var lines: Array[String] = [
		"Difficulty: %d" % int(rally.get("difficulty", 0)),
		"Eligible cars: %s" % _restriction_text(rally.get("restriction", {})),
		"%d events — combined time sets your result." % rally.get("events", []).size(),
		best_line,
	]
	if bool(rally.get("showdown", false)):
		lines.append("THE SHOWDOWN — the final challenge.")
	_detail_body.text = "\n".join(lines)


# --- Car-select overlay (screen 2) -------------------------------------------

func _build_car_overlay() -> void:
	_car_layer = CanvasLayer.new()
	add_child(_car_layer)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 16.0
	root.offset_top = 16.0
	root.offset_right = -16.0
	root.offset_bottom = -16.0
	root.add_theme_constant_override("separation", 8)
	_car_layer.add_child(root)

	_rally_banner = Label.new()
	_rally_banner.add_theme_font_size_override("font_size", 22)
	root.add_child(_rally_banner)

	var hint := Label.new()
	hint.text = "Choose your car"
	hint.add_theme_font_size_override("font_size", 14)
	root.add_child(hint)

	# Push the car nav + actions to the bottom so the 3D car park is visible above.
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(spacer)

	_no_eligible_label = Label.new()
	_no_eligible_label.add_theme_font_size_override("font_size", 16)
	_no_eligible_label.visible = false
	root.add_child(_no_eligible_label)

	# Car selector: ◄ / ► pan the camera to the prev/next eligible car.
	var nav := HBoxContainer.new()
	nav.add_theme_constant_override("separation", 8)
	root.add_child(nav)
	var prev := Button.new()
	prev.text = "<"
	prev.focus_mode = Control.FOCUS_NONE
	prev.pressed.connect(_cycle_focus.bind(-1))
	nav.add_child(prev)
	_car_name_label = Label.new()
	_car_name_label.add_theme_font_size_override("font_size", 18)
	_car_name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_car_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	nav.add_child(_car_name_label)
	var next := Button.new()
	next.text = ">"
	next.focus_mode = Control.FOCUS_NONE
	next.pressed.connect(_cycle_focus.bind(1))
	nav.add_child(next)

	_car_stats_label = Label.new()
	_car_stats_label.add_theme_font_size_override("font_size", 12)
	_car_stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_car_stats_label)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	root.add_child(actions)
	var back := Button.new()
	back.text = "< Back"
	back.focus_mode = Control.FOCUS_NONE
	back.pressed.connect(_show_detail)
	actions.add_child(back)
	_start_button = Button.new()
	_start_button.text = "Start Rally"
	_start_button.focus_mode = Control.FOCUS_NONE
	_start_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_start_button.pressed.connect(_on_start_pressed)
	actions.add_child(_start_button)


# --- Screen transitions ------------------------------------------------------

func _show_map() -> void:
	_screen = Screen.MAP
	_selected_instance_id = -1
	_clear_lineup()
	_detail_layer.visible = false
	_car_layer.visible = false
	_map_layer.visible = true
	_refresh_map()


# Enter the car-select screen for the chosen rally: park only the ELIGIBLE owned
# cars and frame the first one. With none eligible, show a hint + disable Start.
func _enter_car_screen() -> void:
	_screen = Screen.CARS
	_map_layer.visible = false
	_detail_layer.visible = false
	_car_layer.visible = true
	_build_eligible_lineup()
	var rally := RallyLibrary.by_id(_selected_rally_id)
	var done := Save.rally_completed(_selected_rally_id)
	_rally_banner.text = "%s%s  (diff %d) — needs %s" % [
		rally.get("name", "?"), "  (done)" if done else "",
		int(rally.get("difficulty", 0)), _restriction_text(rally.get("restriction", {}))]
	if _eligible.is_empty():
		_no_eligible_label.visible = true
		_no_eligible_label.text = "No eligible car for this rally — win or pick a qualifying car."
		_car_name_label.text = ""
		_car_stats_label.text = ""
		_stats_label.text = ""
		_start_button.disabled = true
		return
	_no_eligible_label.visible = false
	_focus = 0
	_focus_changed(true)  # snap the camera in on entry


# --- Car park (the eligible lineup) ------------------------------------------

func _clear_lineup() -> void:
	for car in _cars:
		if is_instance_valid(car):
			car.queue_free()
	for marker in _markers:
		if is_instance_valid(marker):
			marker.queue_free()
	_cars = []
	_markers = []
	_eligible = []


# Park one frozen car per owned car eligible for the selected rally, laid out in a
# centred row (GameConfig.menu_car_spacing).
func _build_eligible_lineup() -> void:
	_clear_lineup()
	var rally := RallyLibrary.by_id(_selected_rally_id)
	for car in Save.profile.get("cars", []):
		var meta := CarLibrary.by_id(String(car.get("model_id", "")))
		if RallyLibrary.is_eligible(rally, meta):
			_eligible.append(car)
	var cfg: GameConfig = Config.data
	var n := _eligible.size()
	for i in n:
		var marker := Marker3D.new()
		marker.position = Vector3((i - (n - 1) * 0.5) * cfg.menu_car_spacing, 0.0, 0.0)
		add_child(marker)
		_markers.append(marker)
		_cars.append(_spawn_parked_car(_eligible[i], marker))


# Spawn one owned car as a parked, silent, physics-frozen prop at a marker, with its
# OWN mesh copies (see _dup_meshes) so a mixed lineup shows each at its true size.
func _spawn_parked_car(owned: Dictionary, marker: Marker3D) -> Node3D:
	var car := CAR_SCENE.instantiate()
	add_child(car)
	car.apply_owned(owned)
	_dup_meshes(car)
	car.global_transform = marker.global_transform
	car.freeze = true
	car.collision_layer = 0
	car.collision_mask = 0
	var audio := car.get_node_or_null("EngineAudio")
	if audio != null and audio.has_method("stop"):
		audio.stop()
	car.process_mode = Node.PROCESS_MODE_DISABLED
	return car


# Give a car instance its own copies of every mesh resource (car.tscn's body/wheel
# meshes are SubResources shared across instances; apply_car resized the shared one
# to THIS car, so duplicating now freezes those dimensions before the next car's
# apply_car mutates the shared original again).
func _dup_meshes(car: Node) -> void:
	for mi in car.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh != null:
			m.mesh = m.mesh.duplicate()


# Pan the focus to the prev/next eligible car (wrapping).
func _cycle_focus(step: int) -> void:
	if _cars.is_empty():
		return
	_focus = wrapi(_focus + step, 0, _cars.size())
	_focus_changed()


# React to a focus change: make the focused car the selected car, re-aim the camera
# + stats panel at it. No respawn — every eligible car is already parked.
func _focus_changed(snap := false) -> void:
	if _cars.is_empty():
		return
	var owned: Dictionary = _eligible[_focus]
	_selected_instance_id = int(owned.get("instance_id", -1))
	var entry := CarLibrary.by_id(String(owned.get("model_id", "")))
	_car_name_label.text = "%s  #%d  (%d of %d)" % [
		entry.get("name", owned.get("model_id", "?")), _selected_instance_id, _focus + 1, _cars.size()]
	var stats := _car_stats_text(owned, entry)
	_car_stats_label.text = stats
	_stats_label.text = "%s\n%s" % [entry.get("name", "?"), stats]
	_stats_label.global_position = (_markers[_focus] as Marker3D).global_position + Vector3(-2.6, 1.4, 0.0)
	_start_button.disabled = false
	if snap:
		_snap_camera_to_focus()
	else:
		_ease_camera_to_focus()


# One-line car summary shared by the overlay and the 3D Label3D.
func _car_stats_text(owned: Dictionary, entry: Dictionary) -> String:
	var immortal: bool = owned.get("immortal", false)
	var max_hp := float(entry.get("max_hp", 0.0))
	var hp := float(owned.get("hp", 0.0))
	var hp_text := "INF HP" if immortal else "%d/%d HP" % [roundi(hp), roundi(max_hp)]
	return "%s | %s | %s | tier %d | %.2f kW/kg | %s" % [
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


# Human-readable summary of a rally's restriction (the map pin + the car banner).
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


# --- Menu camera -------------------------------------------------------------

func _focused_car_pos() -> Vector3:
	if _markers.is_empty():
		return Vector3.ZERO
	return (_markers[_focus] as Marker3D).global_position


# The framing transform for the focused car: a 3/4 hero shot from the configured
# offset, looking at the car a little above its origin.
func _camera_target_xform() -> Transform3D:
	var cfg: GameConfig = Config.data
	var car_pos := _focused_car_pos()
	var eye := car_pos + cfg.menu_camera_offset
	var look := car_pos + Vector3.UP * cfg.menu_camera_look_height
	var t := Transform3D.IDENTITY
	t.origin = eye
	return t.looking_at(look, Vector3.UP)  # looking_at keeps the origin (the eye)


func _snap_camera_to_focus() -> void:
	_camera.global_transform = _camera_target_xform()


# Ease the camera into the framing over GameConfig.menu_camera_move_time (a pan
# along the lot each time you cycle cars). Snaps when the move time is ~0.
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


# --- Start -------------------------------------------------------------------

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
	if _screen == Screen.MAP:
		_map_input(event)
	elif _screen == Screen.CARS:
		_cars_input(event)


# World map: drag to pan with the mouse or a finger. (A press that lands on a pin
# is consumed by the pin — see the IGNORE filters in _build_map_overlay — so this
# only fires for the empty map, which is where you grab to pan.)
func _map_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_panning = event.pressed
	elif event is InputEventMouseMotion and _panning:
		_pan_map(event.relative)
	elif event is InputEventScreenTouch:
		_panning = event.pressed
	elif event is InputEventScreenDrag:
		_pan_map(event.relative)


func _cars_input(event: InputEvent) -> void:
	if event.is_action_pressed("menu_left"):
		_cycle_focus(-1)
	elif event.is_action_pressed("menu_right"):
		_cycle_focus(1)
	elif event.is_action_pressed("menu_select") and not _start_button.disabled:
		_on_start_pressed()
	elif event.is_action_pressed("menu_back"):
		_show_detail()


# Controller-stick panning of the world map (the left stick); drag panning is
# handled event-by-event in _map_input.
func _process(delta: float) -> void:
	if _screen != Screen.MAP or _map_frame == null:
		return
	var stick := Vector2(
		Input.get_joy_axis(0, JOY_AXIS_LEFT_X), Input.get_joy_axis(0, JOY_AXIS_LEFT_Y))
	if stick.length() > 0.2:  # deadzone
		# Pushing the stick right reveals the map to the right (content slides left).
		_pan_map(-stick * Config.data.menu_map_pan_speed * delta)
