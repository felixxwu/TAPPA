extends Node3D
# HQ — the meta-game hub (todo/menus.md location 1), now a DIEGETIC 3D space the
# camera flies through (todo/diegetic-hq.md) instead of flat overlay screens. One
# world; the camera moves between "stations":
#   * EXTERIOR — the boot/title shot: block buildings + the outdoor car park. A
#     title + Start button. Start flies the camera into the garage.
#   * GARAGE   — a block garage interior holding the MAP TABLE and the TUNING LIFT.
#     Tap the table to see the rallies; tap the lift to tune (coming later).
#   * TABLE    — a near-top-down look at the table's 3D map. Tap a rally pin to open
#     its detail; Enter flies out to the car park.
#   * CARPARK  — the outdoor lineup of the cars ELIGIBLE for the chosen rally; pan
#     between them and Start.
# Flow: pick rally (table) -> choose eligible car (car park) -> Start -> RallySession.
# It is the game's boot scene and stays lightweight (NO track gen).
#
# Clickable 3D objects (table, lift, rally pins) are Area3D with input_ray_pickable;
# get_viewport().physics_object_picking drives the picking. Headless tests call the
# handlers (_enter_table / _on_rally_pin / _enter_car_screen / ...) directly.
#
# Shared-resource note: car.tscn's body/wheel meshes are SubResources shared across
# instances, so apply_car sizing one parked car would resize every other. After
# apply_owned each parked car gets its OWN mesh copies (_dup_meshes) so a mixed lot
# shows each at its true size. apply_owned also writes the shared Config.data (last
# car wins) — harmless here: the props don't simulate, and world.gd re-applies the
# fielded car's config before a run.

# Camera stations (see the per-station poses in GameConfig "Menu / HQ").
enum View { EXTERIOR, GARAGE, TABLE, CARPARK }

# 1st place earns 3 stars, 2nd → 2, 3rd → 1, anything else (incl. not completed) → 0.
# Shown on the 3D map pins as small sphere meshes (gold = earned, grey = not) — a 3D
# row sidesteps the project font's missing ★/☆ glyphs (they'd render as tofu boxes,
# same reason the UI uses ASCII like `<`/`>` for nav).
const MAX_STARS := 3

const CAR_SCENE := preload("res://car.tscn")

var _view: int = View.EXTERIOR
var _detail_open := false       # the rally-detail panel is up (a sub-state of TABLE)
var _selected_rally_id := ""
var _selected_instance_id := -1

# Map-table pan state: drag the table view around (the map can be larger than the
# screen once zoomed in). _table_pan is the camera's X/Z offset from its base pose;
# _table_dragged distinguishes a pan from a tap so a drag doesn't open a rally.
var _table_pan := Vector3.ZERO
var _table_panning := false
var _table_dragged := false

# Car-park state: the owned cars eligible for the chosen rally, the parked car nodes
# + their lot markers (parallel to _eligible), and which slot is focused.
var _eligible: Array = []
var _cars: Array = []
var _markers: Array = []
var _focus := 0

# 3D staging.
var _camera: Camera3D
var _stats_label: Label3D       # billboarded car stats beside the focused parked car
var _cam_tween: Tween
var _map_plane: MeshInstance3D  # the flat map laid on the table top
var _pins_root: Node3D          # parent of the rally pins
var _pins: Array = []           # the pin Node3Ds (each carries a "rally_id" meta)

# Overlays (one CanvasLayer per station; only the active one is visible).
var _title_layer: CanvasLayer
var _garage_layer: CanvasLayer
var _table_layer: CanvasLayer
var _detail_layer: CanvasLayer
var _car_layer: CanvasLayer

var _lift_msg: Label            # transient "tuning coming soon" line in the garage
var _map_meter: Label           # progress-to-showdown meter on the table HUD
var _detail_title: Label
var _detail_body: Label
var _rally_banner: Label
var _car_name_label: Label
var _car_stats_label: Label
var _start_button: Button
var _no_eligible_label: Label


func _ready() -> void:
	_ensure_starter()
	_build_environment()
	_build_title_overlay()
	_build_garage_overlay()
	_build_table_overlay()
	_build_detail_overlay()
	_build_car_overlay()
	# Enable 3D mouse/touch picking so the table / lift / pins receive input_event.
	get_viewport().physics_object_picking = true
	_refresh_map_pins()
	_go_to(View.EXTERIOR, true)


# First run: grant the immortal starter (the anti-soft-lock floor — it can never
# be wrecked, so the player can always field something). Recorded in the profile.
func _ensure_starter() -> void:
	if Save.profile.get("starter_picked", false):
		return
	Save.grant_car("mx5", true)
	Save.profile["starter_picked"] = true
	Save.profile["starter_model_id"] = "mx5"
	Save.save()


# --- 3D world (buildings, garage, table, lift, car park) ---------------------

func _build_environment() -> void:
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
	plane.size = Vector2(240.0, 240.0)
	ground.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.18, 0.19, 0.22)
	ground.material_override = mat
	add_child(ground)

	_build_buildings()
	_build_garage()
	_build_map_table()
	_build_lift()

	# Billboarded stats panel beside the focused car (Label3D for now; the richer
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


# A solid colour block (BoxMesh, centred at pos). The building/garage/table/lift art
# is deliberately placeholder (todo/diegetic-hq.md defers HQ art); the camera framing
# and the table/lift/car-park positions that the flow depends on live in GameConfig.
func _block(pos: Vector3, size: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	mi.material_override = m
	mi.position = pos
	add_child(mi)
	return mi


# Placeholder skyline behind the car park — simple blocks of varying height.
func _build_buildings() -> void:
	var blocks := [
		[Vector3(-16.0, 5.0, 42.0), Vector3(9.0, 10.0, 9.0), Color(0.26, 0.28, 0.34)],
		[Vector3(14.0, 7.0, 46.0), Vector3(8.0, 14.0, 8.0), Color(0.30, 0.31, 0.36)],
		[Vector3(0.0, 6.0, 54.0), Vector3(12.0, 12.0, 10.0), Color(0.24, 0.26, 0.31)],
		[Vector3(-26.0, 4.0, 32.0), Vector3(7.0, 8.0, 12.0), Color(0.28, 0.29, 0.33)],
		[Vector3(25.0, 5.0, 34.0), Vector3(7.0, 10.0, 9.0), Color(0.27, 0.28, 0.34)],
	]
	for b in blocks:
		_block(b[0], b[1], b[2])


# The garage shell: floor, back + side walls, and a flat roof. Open toward +Z (the
# car park) so the camera looks in through the front from the garage station. The
# roof is safe to keep: the table-map camera (eye y ~2.6) and the garage camera both
# sit BELOW the roof (y ~4.8+), so neither looks down through it.
func _build_garage() -> void:
	var cfg: GameConfig = Config.data
	var gx: float = cfg.hq_garage_size.x
	var gz: float = cfg.hq_garage_size.y
	var wall_h := 5.0
	var t := 0.4
	var wall := Color(0.30, 0.31, 0.35)
	_block(Vector3(0.0, 0.05, 0.0), Vector3(gx, 0.1, gz), Color(0.22, 0.23, 0.26))            # floor
	_block(Vector3(0.0, wall_h * 0.5, -gz * 0.5), Vector3(gx, wall_h, t), wall)                # back
	_block(Vector3(-gx * 0.5, wall_h * 0.5, 0.0), Vector3(t, wall_h, gz), wall)                # left
	_block(Vector3(gx * 0.5, wall_h * 0.5, 0.0), Vector3(t, wall_h, gz), wall)                 # right
	_block(Vector3(0.0, wall_h, 0.0), Vector3(gx, t, gz), Color(0.26, 0.27, 0.31))             # roof


# The map table: a block with the flat 3D map plane on top + a pickable area so a tap
# (in the garage view) drops the camera to the table view.
func _build_map_table() -> void:
	var cfg: GameConfig = Config.data
	var p: Vector3 = cfg.hq_table_pos
	var s: Vector3 = cfg.hq_table_size
	_block(p + Vector3(0.0, s.y * 0.5, 0.0), s, Color(0.34, 0.26, 0.18))  # table (wood)
	var top_y := p.y + s.y

	_map_plane = MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = cfg.hq_map_plane_size
	_map_plane.mesh = pm
	var mm := StandardMaterial3D.new()
	mm.albedo_color = Color(0.16, 0.28, 0.22)  # map green
	_map_plane.material_override = mm
	_map_plane.position = Vector3(p.x, top_y + 0.01, p.z)
	add_child(_map_plane)

	_pins_root = Node3D.new()
	add_child(_pins_root)

	var area := Area3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(s.x, 0.6, s.z)
	cs.shape = box
	area.add_child(cs)
	area.position = Vector3(p.x, top_y, p.z)
	area.input_ray_pickable = true
	area.input_event.connect(_on_table_input)
	add_child(area)


# The tuning lift: a platform + two posts, with a pickable area. Tapping it (in the
# garage) flashes a "coming soon" line — tuning itself is a later slice.
func _build_lift() -> void:
	var cfg: GameConfig = Config.data
	var p: Vector3 = cfg.hq_lift_pos
	var s: Vector3 = cfg.hq_lift_size
	var metal := Color(0.40, 0.42, 0.46)
	_block(p + Vector3(0.0, s.y * 0.5, 0.0), s, metal)  # platform
	_block(p + Vector3(-s.x * 0.5 + 0.2, 1.1, 0.0), Vector3(0.2, 2.2, 0.2), metal)
	_block(p + Vector3(s.x * 0.5 - 0.2, 1.1, 0.0), Vector3(0.2, 2.2, 0.2), metal)

	var area := Area3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(s.x, 2.4, s.z)
	cs.shape = box
	area.add_child(cs)
	area.position = p + Vector3(0.0, 1.2, 0.0)
	area.input_ray_pickable = true
	area.input_event.connect(_on_lift_input)
	add_child(area)


# --- 3D map pins -------------------------------------------------------------

# (Re)build the rally pins on the table's map plane: a tier-coloured pin marker at
# each rally's normalised map_pos, with a billboarded name and a row of sphere stars
# (1st-place best → 3 gold, 2nd → 2, 3rd → 1, else grey). The showdown pin is locked
# (grey, non-pickable) until every other rally is completed.
func _refresh_map_pins() -> void:
	for c in _pins_root.get_children():
		c.queue_free()
	_pins = []
	var cfg: GameConfig = Config.data
	var sd_unlocked := RallyLibrary.showdown_unlocked(Save.profile)
	var p: Vector3 = cfg.hq_table_pos
	var size: Vector2 = cfg.hq_map_plane_size
	var top_y := p.y + cfg.hq_table_size.y + 0.02
	for rally in RallyLibrary.RALLIES:
		var pin := _make_pin(rally, sd_unlocked, p, size, top_y)
		_pins_root.add_child(pin)
		_pins.append(pin)
	_refresh_meter()


func _make_pin(rally: Dictionary, sd_unlocked: bool, table_pos: Vector3, plane_size: Vector2, top_y: float) -> Node3D:
	var rally_id := String(rally["id"])
	var locked: bool = bool(rally["showdown"]) and not sd_unlocked
	var mp: Vector2 = rally.get("map_pos", Vector2(0.5, 0.5))
	# map_pos is normalised 0..1; centre the map plane, x→world X, y→world Z.
	var local := Vector3((mp.x - 0.5) * plane_size.x, 0.0, (mp.y - 0.5) * plane_size.y)
	var pin := Node3D.new()
	pin.position = Vector3(table_pos.x, top_y, table_pos.z) + local
	pin.set_meta("rally_id", rally_id)
	pin.set_meta("locked", locked)

	var marker := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.08
	cone.height = 0.28
	marker.mesh = cone
	marker.position = Vector3(0.0, cone.height * 0.5, 0.0)
	var cm := StandardMaterial3D.new()
	cm.albedo_color = Color(0.35, 0.37, 0.42) if locked else _tier_color(int(rally.get("difficulty", 1)))
	marker.material_override = cm
	pin.add_child(marker)

	# Stars: small sphere meshes (3D, no font glyph needed). Earned = gold, else grey.
	var earned := _stars_for(rally_id)
	for k in MAX_STARS:
		var star := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.035
		sm.height = 0.07
		star.mesh = sm
		var smat := StandardMaterial3D.new()
		smat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		smat.albedo_color = Color(1.0, 0.82, 0.3) if k < earned else Color(0.32, 0.34, 0.40)
		star.material_override = smat
		star.position = Vector3((k - (MAX_STARS - 1) * 0.5) * 0.10, cone.height + 0.09, 0.0)
		pin.add_child(star)

	var name3d := Label3D.new()
	name3d.text = String(rally["name"])
	name3d.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	name3d.font_size = 36
	name3d.pixel_size = 0.0022
	name3d.outline_size = 6
	name3d.position = Vector3(0.0, cone.height + 0.24, 0.0)
	pin.add_child(name3d)

	# Pickable hit sphere (skipped for a locked pin so it can't be entered). Kept a bit
	# larger than the marker so the pin stays easy to tap once it's small on screen.
	if not locked:
		var area := Area3D.new()
		var cs := CollisionShape3D.new()
		var sph := SphereShape3D.new()
		sph.radius = 0.28
		cs.shape = sph
		area.add_child(cs)
		area.position = Vector3(0.0, cone.height * 0.5, 0.0)
		area.input_ray_pickable = true
		area.input_event.connect(_on_pin_input.bind(rally_id))
		pin.add_child(area)
	return pin


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


func _refresh_meter() -> void:
	if _map_meter == null:
		return
	var total := 0
	for rally in RallyLibrary.RALLIES:
		if not rally["showdown"]:
			total += 1
	var done := RallyLibrary.completed_count(Save.profile)
	_map_meter.text = "Progress to the Showdown: %d / %d rallies completed" % [done, total]


# --- 3D picking handlers (real play; tests call the targets directly) --------

func _on_table_input(_cam: Node, event: InputEvent, _pos: Vector3, _normal: Vector3, _shape: int) -> void:
	if _view == View.GARAGE and _is_click(event):
		_enter_table()


func _on_lift_input(_cam: Node, event: InputEvent, _pos: Vector3, _normal: Vector3, _shape: int) -> void:
	if _view == View.GARAGE and _is_click(event):
		_flash_lift_message()


func _on_pin_input(_cam: Node, event: InputEvent, _pos: Vector3, _normal: Vector3, _shape: int, rally_id: String) -> void:
	# Select on RELEASE, and only if the press didn't turn into a pan-drag — so
	# dragging across the map to pan never accidentally opens a rally.
	if _view == View.TABLE and not _detail_open and not _table_dragged and _is_release(event):
		_on_rally_pin(rally_id)


func _is_click(event: InputEvent) -> bool:
	return event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT


func _is_release(event: InputEvent) -> bool:
	return event is InputEventMouseButton and not event.pressed and event.button_index == MOUSE_BUTTON_LEFT


# --- Station overlays --------------------------------------------------------

# A full-rect VBox inside a fresh CanvasLayer, with standard margins. Returns both.
func _make_overlay(margin := 24.0) -> Array:
	var layer := CanvasLayer.new()
	add_child(layer)
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = margin
	root.offset_top = margin
	root.offset_right = -margin
	root.offset_bottom = -margin
	root.add_theme_constant_override("separation", 12)
	layer.add_child(root)
	return [layer, root]


# Let taps fall THROUGH an overlay to the 3D scene behind it — only buttons keep
# capturing input. Without this the full-rect container + its labels/spacer (all
# default MOUSE_FILTER_STOP) eat every touch and the 3D map (table / lift / pins,
# picked via Area3D) never receives a pick. Call after the overlay is populated.
func _passthrough_overlay(root: Control) -> void:
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for n in root.find_children("*", "Control", true, false):
		if not (n is BaseButton):
			(n as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE


func _build_title_overlay() -> void:
	var made := _make_overlay()
	_title_layer = made[0]
	var root: VBoxContainer = made[1]
	root.alignment = BoxContainer.ALIGNMENT_CENTER

	var title := Label.new()
	title.text = "RALLY HQ"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 56)
	root.add_child(title)

	var sub := Label.new()
	sub.text = "Build your garage. Win rallies. Reach the Showdown."
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 16)
	root.add_child(sub)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 16)
	root.add_child(spacer)

	var start := Button.new()
	start.text = "Start"
	start.focus_mode = Control.FOCUS_NONE
	start.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	start.custom_minimum_size = Vector2(220, 52)
	start.pressed.connect(_on_exterior_start)
	root.add_child(start)


func _build_garage_overlay() -> void:
	var made := _make_overlay()
	_garage_layer = made[0]
	var root: VBoxContainer = made[1]

	var hint := Label.new()
	hint.text = "GARAGE — tap the map table to choose a rally, or the lift to tune"
	hint.add_theme_font_size_override("font_size", 22)
	root.add_child(hint)

	_lift_msg = Label.new()
	_lift_msg.add_theme_font_size_override("font_size", 16)
	_lift_msg.modulate = Color(1, 1, 1, 0.85)
	root.add_child(_lift_msg)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(spacer)

	var actions := HBoxContainer.new()
	root.add_child(actions)
	var back := Button.new()
	back.text = "< Back"
	back.focus_mode = Control.FOCUS_NONE
	back.pressed.connect(func() -> void: _go_to(View.EXTERIOR))
	actions.add_child(back)
	# Convenience: jump straight to the map table.
	var to_table := Button.new()
	to_table.text = "Open map table >"
	to_table.focus_mode = Control.FOCUS_NONE
	to_table.pressed.connect(_enter_table)
	actions.add_child(to_table)

	_passthrough_overlay(root)  # let taps reach the 3D table / lift behind the HUD


func _build_table_overlay() -> void:
	var made := _make_overlay()
	_table_layer = made[0]
	var root: VBoxContainer = made[1]

	var hint := Label.new()
	hint.text = "WORLD MAP — tap a rally to see its details"
	hint.add_theme_font_size_override("font_size", 22)
	root.add_child(hint)

	_map_meter = Label.new()
	_map_meter.add_theme_font_size_override("font_size", 14)
	root.add_child(_map_meter)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(spacer)

	var back := Button.new()
	back.text = "< Back to garage"
	back.focus_mode = Control.FOCUS_NONE
	back.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	back.pressed.connect(func() -> void: _go_to(View.GARAGE))
	root.add_child(back)

	_passthrough_overlay(root)  # let taps / drags reach the 3D map pins behind the HUD


func _build_detail_overlay() -> void:
	var made := _make_overlay()
	_detail_layer = made[0]
	var root: VBoxContainer = made[1]
	# A solid backing so the detail reads as a panel over the map.
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.08, 0.10, 0.14, 0.96)
	_detail_layer.add_child(bg)
	_detail_layer.move_child(bg, 0)

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
	back.pressed.connect(_hide_detail)
	actions.add_child(back)
	var enter := Button.new()
	enter.text = "Enter Rally — choose car >"
	enter.focus_mode = Control.FOCUS_NONE
	enter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	enter.pressed.connect(_enter_car_screen)
	actions.add_child(enter)


func _build_car_overlay() -> void:
	var made := _make_overlay(16.0)
	_car_layer = made[0]
	var root: VBoxContainer = made[1]

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
	back.pressed.connect(_car_back)
	actions.add_child(back)
	_start_button = Button.new()
	_start_button.text = "Start Rally"
	_start_button.focus_mode = Control.FOCUS_NONE
	_start_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_start_button.pressed.connect(_on_start_pressed)
	actions.add_child(_start_button)


# Show only the active station's overlay (detail is a TABLE sub-state).
func _update_overlays() -> void:
	_title_layer.visible = _view == View.EXTERIOR
	_garage_layer.visible = _view == View.GARAGE
	_table_layer.visible = _view == View.TABLE and not _detail_open
	_detail_layer.visible = _view == View.TABLE and _detail_open
	_car_layer.visible = _view == View.CARPARK


# --- Station transitions -----------------------------------------------------

# Move to a station: update overlays + fly the camera there. CARPARK framing tracks
# the focused car, so it's driven by _focus_changed (after the lineup is built).
func _go_to(view: int, snap := false) -> void:
	_view = view
	if view != View.TABLE:
		_detail_open = false
	_update_overlays()
	if view == View.CARPARK:
		return  # camera handled by _focus_changed once the lineup exists
	_move_camera_to(_station_xform(view), snap)


func _on_exterior_start() -> void:
	_go_to(View.GARAGE)


func _enter_table() -> void:
	_detail_open = false
	_table_pan = Vector3.ZERO  # re-centre the map each time we open it
	_table_dragged = false
	_table_panning = false
	_refresh_map_pins()  # reflect any newly-earned stars / showdown unlock
	_go_to(View.TABLE)


func _flash_lift_message() -> void:
	_lift_msg.text = "Tuning bay — coming soon."


func _on_rally_pin(rally_id: String) -> void:
	_selected_rally_id = rally_id
	_show_detail()


# Show the detail panel for the selected rally (a sub-state of the TABLE view).
func _show_detail() -> void:
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
	_detail_open = true
	_view = View.TABLE
	_update_overlays()


func _hide_detail() -> void:
	_detail_open = false
	_update_overlays()


# Enter the car park for the chosen rally: park only the ELIGIBLE owned cars and
# frame the first. With none eligible, show a hint + disable Start.
func _enter_car_screen() -> void:
	_build_eligible_lineup()
	var rally := RallyLibrary.by_id(_selected_rally_id)
	var done := Save.rally_completed(_selected_rally_id)
	_rally_banner.text = "%s%s  (diff %d) — needs %s" % [
		rally.get("name", "?"), "  (done)" if done else "",
		int(rally.get("difficulty", 0)), _restriction_text(rally.get("restriction", {}))]
	_view = View.CARPARK
	_detail_open = false
	_update_overlays()
	if _eligible.is_empty():
		_no_eligible_label.visible = true
		_no_eligible_label.text = "No eligible car for this rally — win or pick a qualifying car."
		_car_name_label.text = ""
		_car_stats_label.text = ""
		_stats_label.text = ""
		_start_button.disabled = true
		_move_camera_to(_station_xform(View.CARPARK), true)
		return
	_no_eligible_label.visible = false
	_focus = 0
	_focus_changed(true)  # snaps the camera onto the first car


func _car_back() -> void:
	_clear_lineup()
	_selected_instance_id = -1
	_go_to(View.TABLE)


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
# centred row at the car-park origin (GameConfig.hq_carpark_origin / menu_car_spacing).
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
		marker.position = cfg.hq_carpark_origin + Vector3((i - (n - 1) * 0.5) * cfg.menu_car_spacing, 0.0, 0.0)
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
	_move_camera_to(_camera_target_xform(), snap)


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


# Human-readable summary of a rally's restriction (the detail panel + the car banner).
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


# --- Camera ------------------------------------------------------------------

# A camera transform that sits at `eye` looking at `look`.
func _look_xform(eye: Vector3, look: Vector3) -> Transform3D:
	var t := Transform3D.IDENTITY
	t.origin = eye
	if eye.distance_to(look) < 0.001:
		return t
	return t.looking_at(look, Vector3.UP)  # looking_at keeps the origin (the eye)


# The camera pose for a station.
func _station_xform(view: int) -> Transform3D:
	var cfg: GameConfig = Config.data
	match view:
		View.GARAGE: return _look_xform(cfg.hq_garage_cam_eye, cfg.hq_garage_cam_look)
		View.TABLE: return _look_xform(cfg.hq_table_cam_eye + _table_pan, cfg.hq_table_cam_look + _table_pan)
		View.CARPARK: return _camera_target_xform()
		_: return _look_xform(cfg.hq_exterior_cam_eye, cfg.hq_exterior_cam_look)


func _focused_car_pos() -> Vector3:
	if _markers.is_empty():
		return Config.data.hq_carpark_origin
	return (_markers[_focus] as Marker3D).global_position


# The framing transform for the focused car: a 3/4 hero shot from the configured
# offset, looking at the car a little above its origin.
func _camera_target_xform() -> Transform3D:
	var cfg: GameConfig = Config.data
	var car_pos := _focused_car_pos()
	return _look_xform(car_pos + cfg.menu_camera_offset, car_pos + Vector3.UP * cfg.menu_camera_look_height)


func _snap_camera_to_focus() -> void:
	_move_camera_to(_camera_target_xform(), true)


func _ease_camera_to_focus() -> void:
	_move_camera_to(_camera_target_xform(), false)


# Ease (or snap) the camera to a transform over GameConfig.menu_camera_move_time.
func _move_camera_to(xform: Transform3D, snap: bool) -> void:
	var cfg: GameConfig = Config.data
	if _cam_tween != null and _cam_tween.is_valid():
		_cam_tween.kill()
	if snap or cfg.menu_camera_move_time <= 0.0:
		_camera.global_transform = xform
		return
	_cam_tween = create_tween()
	_cam_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_cam_tween.tween_property(_camera, "global_transform", xform, cfg.menu_camera_move_time)


# --- Start -------------------------------------------------------------------

# Hand off to the orchestrator. RallySession derives the event target times
# (generating each event's track) and loads the first event's run scene — heavy,
# synchronous work that would otherwise freeze HQ with no feedback. So cover the
# screen with the loading overlay FIRST and let it paint a frame, then do the
# handoff behind it (the run scene then shows its own loading screen — continuous).
func _on_start_pressed() -> void:
	var owned := Save.get_car(_selected_instance_id)
	var rally := RallyLibrary.by_id(_selected_rally_id)
	if owned.is_empty() or rally.is_empty():
		return
	var loading := LoadingScreen.new()
	loading.set_step("Preparing rally…")
	add_child(loading)
	# Let the overlay actually PAINT before the heavy, synchronous handoff
	# (start_rally generates a track per event, then changes scene). ONE
	# process_frame wasn't enough: it resumes at the start of the next frame, before
	# the overlay's deferred layout (anchors → size) has resolved and drawn, so the
	# screen still froze blank. Two frames let the first draw the laid-out overlay and
	# resume after it. (RenderingServer.frame_post_draw is the "right" signal but never
	# fires under the headless test runner — it wedges the test loop — so we stick to
	# process_frame, which resolves both in-game and headless.)
	await get_tree().process_frame
	await get_tree().process_frame
	RallySession.start_rally(rally, owned)


# --- Menu input (keyboard / gamepad; clicking 3D objects is the primary path) -

func _unhandled_input(event: InputEvent) -> void:
	match _view:
		View.EXTERIOR:
			if event.is_action_pressed("menu_select"):
				_on_exterior_start()
		View.GARAGE:
			if event.is_action_pressed("menu_select"):
				_enter_table()
			elif event.is_action_pressed("menu_back"):
				_go_to(View.EXTERIOR)
		View.TABLE:
			if _detail_open:
				if event.is_action_pressed("menu_select"):
					_enter_car_screen()
				elif event.is_action_pressed("menu_back"):
					_hide_detail()
			elif event.is_action_pressed("menu_back"):
				_go_to(View.GARAGE)
			else:
				_table_pan_input(event)
		View.CARPARK:
			_cars_input(event)


# Drag the map table around (mouse, or finger via emulate_mouse_from_touch). A drag
# sets _table_dragged so the release doesn't also open the pin under the finger.
func _table_pan_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_table_panning = event.pressed
		if event.pressed:
			_table_dragged = false
	elif event is InputEventMouseMotion and _table_panning:
		if event.relative.length() > 2.0:
			_table_dragged = true
		_pan_table(event.relative)


# Translate the table camera in the map plane (X/Z) by a screen-drag delta — grab the
# map and drag it. Clamped so the view stays over the map. Snaps (follows the finger).
func _pan_table(rel: Vector2) -> void:
	var cfg: GameConfig = Config.data
	var half := cfg.hq_map_plane_size
	_table_pan.x = clampf(_table_pan.x - rel.x * cfg.hq_table_pan_speed, -half.x * 0.5, half.x * 0.5)
	_table_pan.z = clampf(_table_pan.z - rel.y * cfg.hq_table_pan_speed, -half.y * 0.5, half.y * 0.5)
	_move_camera_to(_station_xform(View.TABLE), true)


func _cars_input(event: InputEvent) -> void:
	if event.is_action_pressed("menu_left"):
		_cycle_focus(-1)
	elif event.is_action_pressed("menu_right"):
		_cycle_focus(1)
	elif event.is_action_pressed("menu_select") and not _start_button.disabled:
		_on_start_pressed()
	elif event.is_action_pressed("menu_back"):
		_car_back()
