extends Node3D
# HQ — the meta-game hub (todo/menus.md location 1), now a DIEGETIC 3D space the
# camera flies through (todo/diegetic-hq.md) instead of flat overlay screens. One
# world; the camera moves between "stations":
#   * EXTERIOR — the boot/title shot: block buildings + the outdoor car park, with
#     just a Start button. Start flies the camera into the garage.
#   * GARAGE   — a block garage interior holding the MAP TABLE and the TUNING LIFT.
#     The player's SELECTED car is raised on the lift here. Tap the table to see the
#     rallies; tap the lift to tune.
#   * TABLE    — a near-top-down look at the table's 3D map. Tap a rally pin to open
#     its detail; Enter flies out to the car park.
#   * LIFT     — the tuning bay: the selected car raised on the lift on one side, the
#     tuning menu on the other. Two menus — TUNE (grip/brake/aero sliders) and
#     UPGRADES (install parts + repair) — plus a control to change which car is tuned.
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
enum View { EXTERIOR, GARAGE, TABLE, LIFT, CARPARK }

# The two tuning-lift menus (todo/menus.md rig 4): TUNE = the handling sliders,
# UPGRADES = install parts / repair. Both share the change-car control + Back.
enum LiftTab { TUNE, UPGRADES }

# 1st place earns 3 stars, 2nd → 2, 3rd → 1, anything else (incl. not completed) → 0.
# Shown on the 3D map pins as small sphere meshes (gold = earned, grey = not) — a 3D
# row sidesteps the project font's missing ★/☆ glyphs (they'd render as tofu boxes,
# same reason the UI uses ASCII like `<`/`>` for nav).
const MAX_STARS := 3

const CAR_SCENE := preload("res://car.tscn")
const TREE_TEXTURE := preload("res://textures/tree.png")

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
# Bumped each time a lineup is (re)built so a pending settle-then-freeze timer for an
# old lineup no-ops when it fires (see _build_eligible_lineup / _freeze_lineup).
var _settle_generation := 0

# Tuning-lift state: the selected car raised on the lift (a Car prop, separate from
# the car-park lineup), which OwnedCar it is, and which menu (TUNE / UPGRADES) is up.
var _lift_car: Node3D
var _lift_owned: Dictionary = {}
var _lift_car_instance_id := -2  # what _lift_car was built for (-2 = nothing yet)
var _lift_tab: int = LiftTab.TUNE
# Lift animation: the car is LOWERED on the ground in the garage view and RAISED when
# the bay is entered (tweened over hq_lift_raise_time). _lift_raised is the current
# target pose; _lift_tween animates the car's height toward it.
var _lift_raised := false
var _lift_tween: Tween

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
var _lift_layer: CanvasLayer
var _car_layer: CanvasLayer

var _map_meter: Label           # progress-to-showdown meter on the table HUD
var _detail_title: Label
var _detail_body: Label
var _rally_banner: Label
var _car_name_label: Label
var _car_stats_label: Label
var _start_button: Button
var _no_eligible_label: Label

# Tuning-lift overlay widgets (the right-side menu panel).
var _lift_car_label: Label      # selected car name + stats at the top of the panel
var _lift_tab_tune: Button
var _lift_tab_upgrades: Button
var _lift_tune_box: VBoxContainer    # the TUNE menu (sliders)
var _lift_upgrades_box: VBoxContainer  # the UPGRADES menu (install / repair)
var _lift_sliders: Dictionary = {}     # axis -> HSlider
var _lift_slider_rows: Dictionary = {} # axis -> the row Control (to grey out when locked)
var _lift_slider_values: Dictionary = {}  # axis -> the value Label


func _ready() -> void:
	_ensure_starter()
	_ensure_selection()
	_build_environment()
	_build_title_overlay()
	_build_garage_overlay()
	_build_table_overlay()
	_build_detail_overlay()
	_build_lift_overlay()
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


# Make sure a valid car is selected (the one raised on the lift). Save.selected_car
# self-heals to the first owned car when the stored id is unset/invalid.
func _ensure_selection() -> void:
	Save.selected_car()


# --- 3D world (buildings, garage, table, lift, car park) ---------------------

func _build_environment() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	# Same skybox as the run scene (main.tscn) so HQ shares the look. The garage
	# stays lit (directional + ambient below); the sky is just the backdrop.
	var sky_mat := PanoramaSkyMaterial.new()
	sky_mat.panorama = load("res://textures/sky_field.png")
	var sky := Sky.new()
	sky.sky_material = sky_mat
	e.background_mode = Environment.BG_SKY
	e.sky = sky
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

	# Collision floor under the lot so the parked cars settle onto their suspension
	# (the visual ground plane has no collision). A thick box with its top at y = 0.
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(240.0, 2.0, 240.0)
	floor_shape.shape = floor_box
	floor_shape.position = Vector3(0.0, -1.0, 0.0)  # top face at y = 0
	floor_body.add_child(floor_shape)
	add_child(floor_body)

	_build_buildings()
	_build_trees()
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


# Placeholder skyline BEHIND the garage (−Z) — simple blocks of varying height.
# The title camera (hq_exterior_cam_*) sits out at +Z looking back over the car
# park toward the garage, so buildings belong behind the garage (its back wall is
# at z ≈ −6); placing them in front of it would block the shot.
func _build_buildings() -> void:
	var blocks := [
		[Vector3(-15.0, 6.0, -16.0), Vector3(9.0, 12.0, 9.0), Color(0.26, 0.28, 0.34)],
		[Vector3(-3.0, 8.0, -24.0), Vector3(11.0, 16.0, 10.0), Color(0.24, 0.26, 0.31)],
		[Vector3(12.0, 7.0, -18.0), Vector3(9.0, 14.0, 9.0), Color(0.30, 0.31, 0.36)],
		[Vector3(24.0, 5.0, -13.0), Vector3(8.0, 10.0, 8.0), Color(0.28, 0.29, 0.33)],
		[Vector3(-25.0, 5.0, -14.0), Vector3(8.0, 10.0, 9.0), Color(0.27, 0.28, 0.34)],
		[Vector3(5.0, 5.0, -12.0), Vector3(7.0, 10.0, 7.0), Color(0.29, 0.30, 0.35)],
	]
	for b in blocks:
		_block(b[0], b[1], b[2])


# Trees framing the lot so HQ reads as an outdoor clearing under the open-field
# skybox, instead of floating on a bare plane. Reuses the stage's billboard
# renderer/texture (one MultiMesh, one draw call); scenery only (no collision).
# A close-in annulus, but with the front-centre corridor kept clear so trees never
# block the title camera's view of the car park, and the garage footprint kept
# clear so none spawn inside it. Trees hug the garage's sides and back.
func _build_trees() -> void:
	var cfg: GameConfig = Config.data
	var rng := RandomNumberGenerator.new()
	rng.seed = 20240
	var positions := PackedVector2Array()
	var inner := 18.0
	var outer := 66.0
	for _i in 320:
		var ang := rng.randf() * TAU
		var rad := sqrt(rng.randf()) * (outer - inner) + inner
		var p := Vector2(cos(ang) * rad, sin(ang) * rad)
		# Keep the front-centre clear: the car park sits at +Z (hq_carpark_origin)
		# and the title camera looks down that corridor, so no trees with |x| small
		# and z ahead of the garage. Also skip the garage footprint itself.
		if absf(p.x) < 22.0 and p.y > 8.0:
			continue
		if absf(p.x) < 9.0 and absf(p.y) < 9.0:
			continue
		positions.append(p)
	# HQ ground is a flat plane at y = 0; a layerless TerrainManager returns height
	# 0 everywhere, which is all BillboardField needs to seat the trees. Used only
	# during build(), then freed.
	var flat := TerrainManager.new()
	flat.layers = [] as Array[TerrainLayer]
	var field := BillboardField.new()
	add_child(field)
	field.build(positions, flat, cfg.tree_size_m, TREE_TEXTURE,
		cfg.tree_collision_radius_m, cfg.tree_collision_height_m, false, 1000.0, 0.0)
	flat.free()


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
		_enter_lift()


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

	# Title screen is just the Start button over the parked-collection backdrop —
	# no title/subtitle text.
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
	hint.text = "GARAGE — tap the map table to choose a rally, or the lift to tune your car"
	hint.add_theme_font_size_override("font_size", 22)
	root.add_child(hint)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(spacer)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	root.add_child(actions)
	var back := Button.new()
	back.text = "< Back"
	back.focus_mode = Control.FOCUS_NONE
	back.pressed.connect(func() -> void: _go_to(View.EXTERIOR))
	actions.add_child(back)
	# Convenience buttons mirroring the clickable 3D lift / table.
	var to_lift := Button.new()
	to_lift.text = "Tune car (lift) >"
	to_lift.focus_mode = Control.FOCUS_NONE
	to_lift.pressed.connect(_enter_lift)
	actions.add_child(to_lift)
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


# The tuning-lift menu: a solid panel anchored to ONE side of the screen (the right
# hq_lift_menu_width_frac of the width) so the raised car — framed to the LEFT by the
# lift camera (hq_lift_cam_*) — stays in clear view. The panel holds only the
# interactive controls (change-car, the TUNE/UPGRADES tab + its scrollable content,
# and Back) so it stays short enough for small screens; the bay title and the selected
# car's name/description sit in a separate BOTTOM-LEFT panel beside the car.
func _build_lift_overlay() -> void:
	var frac: float = Config.data.hq_lift_menu_width_frac
	_lift_layer = CanvasLayer.new()
	add_child(_lift_layer)

	var bg := ColorRect.new()
	bg.anchor_left = 1.0 - frac
	bg.anchor_right = 1.0
	bg.anchor_top = 0.0
	bg.anchor_bottom = 1.0
	bg.color = Color(0.08, 0.10, 0.14, 0.96)
	_lift_layer.add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	bg.add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)

	# Change which car is tuned (cycles all owned cars; updates the selected car).
	var car_nav := HBoxContainer.new()
	car_nav.add_theme_constant_override("separation", 8)
	root.add_child(car_nav)
	var prev_car := Button.new()
	prev_car.text = "< Car"
	prev_car.focus_mode = Control.FOCUS_NONE
	prev_car.pressed.connect(_cycle_lift_car.bind(-1))
	car_nav.add_child(prev_car)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	car_nav.add_child(spacer)
	var next_car := Button.new()
	next_car.text = "Car >"
	next_car.focus_mode = Control.FOCUS_NONE
	next_car.pressed.connect(_cycle_lift_car.bind(1))
	car_nav.add_child(next_car)

	# The two-menu tab strip.
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 6)
	root.add_child(tabs)
	_lift_tab_tune = Button.new()
	_lift_tab_tune.text = "Tune"
	_lift_tab_tune.focus_mode = Control.FOCUS_NONE
	_lift_tab_tune.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lift_tab_tune.pressed.connect(_set_lift_tab.bind(LiftTab.TUNE))
	tabs.add_child(_lift_tab_tune)
	_lift_tab_upgrades = Button.new()
	_lift_tab_upgrades.text = "Upgrades"
	_lift_tab_upgrades.focus_mode = Control.FOCUS_NONE
	_lift_tab_upgrades.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lift_tab_upgrades.pressed.connect(_set_lift_tab.bind(LiftTab.UPGRADES))
	tabs.add_child(_lift_tab_upgrades)

	# Scrollable content area (the upgrades list can grow past the panel height).
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 10)
	scroll.add_child(content)

	_build_lift_tune_box(content)
	_lift_upgrades_box = VBoxContainer.new()
	_lift_upgrades_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lift_upgrades_box.add_theme_constant_override("separation", 8)
	content.add_child(_lift_upgrades_box)

	var back := Button.new()
	back.text = "< Back to garage"
	back.focus_mode = Control.FOCUS_NONE
	back.pressed.connect(_lift_back)
	root.add_child(back)

	# The bay title + the selected car's name & description live at the BOTTOM-LEFT —
	# on the lift side, beside the car — so the right-hand menu panel stays short
	# enough to fit small screens. A slim self-sizing panel that grows up/right.
	var info_panel := PanelContainer.new()
	info_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	info_panel.offset_left = 20
	info_panel.offset_bottom = -20
	info_panel.grow_horizontal = Control.GROW_DIRECTION_END
	info_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	info_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var info_style := StyleBoxFlat.new()
	info_style.bg_color = Color(0.08, 0.10, 0.14, 0.82)
	info_style.corner_radius_top_left = 6
	info_style.corner_radius_top_right = 6
	info_style.corner_radius_bottom_left = 6
	info_style.corner_radius_bottom_right = 6
	for side in ["left", "top", "right", "bottom"]:
		info_style.set("content_margin_" + side, 14.0)
	info_panel.add_theme_stylebox_override("panel", info_style)
	_lift_layer.add_child(info_panel)
	var info := VBoxContainer.new()
	info.add_theme_constant_override("separation", 4)
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info_panel.add_child(info)
	var title := Label.new()
	title.text = "TUNING BAY"
	title.add_theme_font_size_override("font_size", 22)
	info.add_child(title)
	_lift_car_label = Label.new()
	_lift_car_label.add_theme_font_size_override("font_size", 14)
	_lift_car_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lift_car_label.custom_minimum_size = Vector2(360, 0)
	info.add_child(_lift_car_label)


# Build the TUNE menu: one slider row per tuning axis. Static structure; gating /
# values are refreshed per car by _refresh_lift_ui.
func _build_lift_tune_box(parent: VBoxContainer) -> void:
	_lift_tune_box = VBoxContainer.new()
	_lift_tune_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lift_tune_box.add_theme_constant_override("separation", 12)
	parent.add_child(_lift_tune_box)

	var hint := Label.new()
	hint.text = "Free, reversible handling tweaks. Slide left/right and they save instantly."
	hint.add_theme_font_size_override("font_size", 12)
	hint.modulate = Color(1, 1, 1, 0.8)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lift_tune_box.add_child(hint)

	# One row per axis: a heading + value, then the slider. The labels at each end
	# name the slider's directions so the player knows which way is which.
	for spec in [
		{"axis": "grip_balance", "name": "Grip balance", "lo": "understeer", "hi": "oversteer"},
		{"axis": "brake_bias", "name": "Brake bias", "lo": "rearward", "hi": "forward"},
		{"axis": "aero_balance", "name": "Aero balance", "lo": "front", "hi": "rear"},
	]:
		_lift_tune_box.add_child(_make_slider_row(spec))

	var reset := Button.new()
	reset.text = "Reset to neutral"
	reset.focus_mode = Control.FOCUS_NONE
	reset.pressed.connect(_reset_tuning)
	_lift_tune_box.add_child(reset)


func _make_slider_row(spec: Dictionary) -> Control:
	var axis := String(spec["axis"])
	var row := VBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 2)

	var header := HBoxContainer.new()
	row.add_child(header)
	var name_label := Label.new()
	name_label.text = String(spec["name"])
	name_label.add_theme_font_size_override("font_size", 16)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(name_label)
	var value := Label.new()
	value.add_theme_font_size_override("font_size", 14)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	header.add_child(value)
	_lift_slider_values[axis] = value

	var slider := HSlider.new()
	slider.min_value = -1.0
	slider.max_value = 1.0
	slider.step = 0.05
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(_on_tune_slider_changed.bind(axis))
	row.add_child(slider)
	_lift_sliders[axis] = slider

	var ends := HBoxContainer.new()
	row.add_child(ends)
	var lo := Label.new()
	lo.text = String(spec["lo"])
	lo.add_theme_font_size_override("font_size", 11)
	lo.modulate = Color(1, 1, 1, 0.6)
	lo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ends.add_child(lo)
	var hi := Label.new()
	hi.text = String(spec["hi"])
	hi.add_theme_font_size_override("font_size", 11)
	hi.modulate = Color(1, 1, 1, 0.6)
	hi.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	ends.add_child(hi)

	_lift_slider_rows[axis] = row
	return row


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
	_lift_layer.visible = _view == View.LIFT
	_car_layer.visible = _view == View.CARPARK


# --- Station transitions -----------------------------------------------------

# Move to a station: update overlays + fly the camera there. CARPARK framing tracks
# the focused car, so it's driven by _focus_changed (after the lineup is built).
func _go_to(view: int, snap := false) -> void:
	_view = view
	if view != View.TABLE:
		_detail_open = false
	# The title screen shows the player's whole collection parked in the car park.
	if view == View.EXTERIOR:
		_build_title_lineup()
	# The selected car sits on the lift whenever we're inside (garage/lift); it costs
	# nothing once frozen, so keep it around while inside and drop it otherwise. In the
	# garage it rests LOWERED on the ground; entering the bay (_enter_lift) raises it.
	if view == View.GARAGE:
		_ensure_lift_car()
		_lower_lift_car()
	elif view == View.LIFT:
		_ensure_lift_car()  # the slow raise is triggered by _enter_lift
	else:
		_clear_lift_car()
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


# --- Tuning lift (features/tuning.md / todo/menus.md rig 4) ----------------------

# Enter the tuning bay: raise the selected car on the lift, frame it to one side,
# and show the tuning menu on the other. Defaults to the TUNE menu.
func _enter_lift() -> void:
	_ensure_lift_car()
	_lift_tab = LiftTab.TUNE
	_refresh_lift_ui()
	_go_to(View.LIFT)
	_raise_lift_car()  # slowly raise the car on the lift as we arrive


# Raise / lower the car on the lift to its target pose. Lowering is the garage rest
# pose; raising is the bay pose. Both animate over hq_lift_raise_time.
func _raise_lift_car() -> void:
	_lift_raised = true
	_apply_lift_height(true)


func _lower_lift_car() -> void:
	_lift_raised = false
	_apply_lift_height(true)


# World-space Y of the car origin for the lowered / raised pose (above the platform top).
func _lift_car_y(raised: bool) -> float:
	var cfg: GameConfig = Config.data
	var top := cfg.hq_lift_pos.y + cfg.hq_lift_size.y
	return top + (cfg.hq_lift_car_height if raised else cfg.hq_lift_car_lowered_height)


# Move the lift car to its current target height (_lift_raised), tweening unless
# animate is false / the time is 0. The tween is owned by HQ (not the frozen car), so
# it ticks regardless of the car's disabled process mode.
func _apply_lift_height(animate: bool) -> void:
	if not is_instance_valid(_lift_car):
		return
	var target := _lift_car_y(_lift_raised)
	if _lift_tween != null and _lift_tween.is_valid():
		_lift_tween.kill()
	if not animate or Config.data.hq_lift_raise_time <= 0.0:
		var p := _lift_car.global_position
		p.y = target
		_lift_car.global_position = p
		return
	_lift_tween = create_tween()
	_lift_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_lift_tween.tween_property(_lift_car, "global_position:y", target, Config.data.hq_lift_raise_time)


func _lift_back() -> void:
	_go_to(View.GARAGE)


func _set_lift_tab(tab: int) -> void:
	_lift_tab = tab
	_refresh_lift_ui()


# Cycle which owned car is on the lift (and is therefore the selected car). Wraps;
# re-spawns the lift car and refreshes the menus for the new car.
func _cycle_lift_car(step: int) -> void:
	var cars: Array = Save.profile.get("cars", [])
	if cars.size() <= 1:
		return
	var idx := 0
	for i in cars.size():
		if int(cars[i].get("instance_id", -1)) == Save.selected_instance_id():
			idx = i
			break
	idx = wrapi(idx + step, 0, cars.size())
	Save.set_selected_car(int(cars[idx].get("instance_id", -1)))
	_lift_car_instance_id = -2  # force a respawn for the new selection
	_ensure_lift_car()
	_refresh_lift_ui()


# Spawn (or keep) the selected car raised on the lift. No-op if the right car is
# already there. The lift car is frozen immediately (wheels hang, as on a ramp).
func _ensure_lift_car() -> void:
	var owned := Save.selected_car()
	if owned.is_empty():
		_clear_lift_car()
		return
	var id := int(owned.get("instance_id", -1))
	if is_instance_valid(_lift_car) and _lift_car_instance_id == id:
		_lift_owned = owned
		return
	_clear_lift_car()
	_lift_owned = owned
	_lift_car_instance_id = id
	_lift_car = _spawn_lift_car(owned)


func _clear_lift_car() -> void:
	if _lift_tween != null and _lift_tween.is_valid():
		_lift_tween.kill()  # the tween targets the car we're about to free
	if is_instance_valid(_lift_car):
		_lift_car.queue_free()
	_lift_car = null
	_lift_car_instance_id = -2


# Build the selected car as a silent, frozen prop on the lift platform at the current
# pose height (lowered in the garage, raised in the bay — so a re-spawn while raised
# appears already raised). Its own mesh copies, like the car-park props (_dup_meshes).
func _spawn_lift_car(owned: Dictionary) -> Node3D:
	var cfg: GameConfig = Config.data
	var car := CAR_SCENE.instantiate()
	add_child(car)
	car.apply_owned(owned)
	_dup_meshes(car)
	var xform := Transform3D.IDENTITY
	xform.origin = Vector3(cfg.hq_lift_pos.x, _lift_car_y(_lift_raised), cfg.hq_lift_pos.z)
	car.global_transform = xform
	car.freeze = true
	car.process_mode = Node.PROCESS_MODE_DISABLED
	var audio := car.get_node_or_null("EngineAudio")
	if audio != null:
		audio.process_mode = Node.PROCESS_MODE_DISABLED
		if audio is AudioStreamPlayer:
			audio.playing = false
			audio.volume_db = -80.0
	return car


# Refresh the whole menu for the current selected car: name + stats, which menu is
# shown, the sliders' gating/values, and the upgrades list.
func _refresh_lift_ui() -> void:
	_lift_owned = Save.selected_car()
	var entry := CarLibrary.by_id(String(_lift_owned.get("model_id", "")))
	var id := int(_lift_owned.get("instance_id", -1))
	_lift_car_label.text = "%s  #%d\n%s" % [
		entry.get("name", "?"), id, _car_stats_text(_lift_owned, entry)]
	_lift_tune_box.visible = _lift_tab == LiftTab.TUNE
	_lift_upgrades_box.visible = _lift_tab == LiftTab.UPGRADES
	_lift_tab_tune.disabled = _lift_tab == LiftTab.TUNE
	_lift_tab_upgrades.disabled = _lift_tab == LiftTab.UPGRADES
	_refresh_sliders()
	_rebuild_upgrades_box()


# Reflect the stored tuning + each axis's unlock state onto the sliders.
func _refresh_sliders() -> void:
	var tuning: Dictionary = _lift_owned.get("tuning", {})
	for axis in TuningLibrary.AXES:
		var slider: HSlider = _lift_sliders[axis]
		var value: Label = _lift_slider_values[axis]
		var row: Control = _lift_slider_rows[axis]
		var unlocked := TuningLibrary.axis_unlocked(_lift_owned, axis)
		slider.editable = unlocked
		row.modulate = Color(1, 1, 1, 1.0 if unlocked else 0.4)
		# set_value_no_signal so syncing the UI doesn't re-save the value.
		slider.set_value_no_signal(clampf(float(tuning.get(axis, 0.0)), -1.0, 1.0))
		if unlocked:
			value.text = "%+.2f" % slider.value
		else:
			value.text = "needs %s" % ("Big Brake Kit" if axis == "brake_bias" else "Aero Kit")


func _on_tune_slider_changed(value: float, axis: String) -> void:
	if _lift_owned.is_empty():
		return
	var tuning: Dictionary = _lift_owned.get("tuning", {})
	tuning[axis] = value
	_lift_owned["tuning"] = tuning
	Save.set_tuning(int(_lift_owned.get("instance_id", -1)), tuning)
	(_lift_slider_values[axis] as Label).text = "%+.2f" % value


# Zero every axis (free + instant) — the lift's Reset action (features/tuning.md).
func _reset_tuning() -> void:
	if _lift_owned.is_empty():
		return
	_lift_owned["tuning"] = {}
	Save.set_tuning(int(_lift_owned.get("instance_id", -1)), {})
	_refresh_sliders()


# Rebuild the UPGRADES menu for the current car: one row per slot showing what's
# fitted, an Install button per matching uninstalled item in the inventory, an
# Uninstall, and the repair-kit action. Items return to inventory on uninstall.
func _rebuild_upgrades_box() -> void:
	for c in _lift_upgrades_box.get_children():
		c.queue_free()
	var id := int(_lift_owned.get("instance_id", -1))
	var installed: Array = _lift_owned.get("installed_upgrades", [])
	var inventory: Dictionary = Save.profile.get("inventory", {})

	var heading := Label.new()
	heading.text = "Install parts onto this car. Parts return to your inventory if you swap them out."
	heading.add_theme_font_size_override("font_size", 12)
	heading.modulate = Color(1, 1, 1, 0.8)
	heading.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lift_upgrades_box.add_child(heading)

	for slot in UpgradeLibrary.SLOTS:
		_lift_upgrades_box.add_child(_make_slot_row(slot, id, installed, inventory))

	# Repair kit + HP (the one consumable; heals working HP).
	_lift_upgrades_box.add_child(_make_repair_row(id, inventory))


func _make_slot_row(slot: String, instance_id: int, installed: Array, inventory: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 2)

	# The fitted item in this slot (if any).
	var fitted := ""
	for item_id in installed:
		if UpgradeLibrary.slot_of(item_id) == slot:
			fitted = item_id
			break

	var header := Label.new()
	header.add_theme_font_size_override("font_size", 15)
	var fitted_name: String = UpgradeLibrary.by_id(fitted).get("name", "—") if fitted != "" else "— empty —"
	header.text = "%s: %s" % [slot.capitalize(), fitted_name]
	box.add_child(header)

	# Uninstall the fitted item.
	if fitted != "":
		var uninstall := Button.new()
		uninstall.text = "Remove"
		uninstall.focus_mode = Control.FOCUS_NONE
		uninstall.pressed.connect(_uninstall_upgrade.bind(instance_id, fitted))
		box.add_child(uninstall)

	# An Install button for each owned (uninstalled) item that fits this slot.
	for item_id in inventory:
		if UpgradeLibrary.slot_of(item_id) != slot:
			continue
		var count := int(inventory[item_id])
		if count <= 0:
			continue
		var install := Button.new()
		install.text = "Install %s  (x%d)" % [UpgradeLibrary.by_id(item_id).get("name", item_id), count]
		install.focus_mode = Control.FOCUS_NONE
		install.pressed.connect(_install_upgrade.bind(instance_id, item_id))
		box.add_child(install)
	return box


func _make_repair_row(instance_id: int, inventory: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	var kits := int(inventory.get(UpgradeLibrary.REPAIR_KIT_ID, 0))
	var entry := CarLibrary.by_id(String(_lift_owned.get("model_id", "")))
	var label := Label.new()
	label.add_theme_font_size_override("font_size", 15)
	if bool(_lift_owned.get("immortal", false)):
		label.text = "Condition: INDESTRUCTIBLE (starter)"
		box.add_child(label)
		return box
	label.text = "Condition: %d / %d HP   —   Repair Kits: x%d" % [
		roundi(float(_lift_owned.get("hp", 0.0))), roundi(float(entry.get("max_hp", 0.0))), kits]
	box.add_child(label)
	if kits > 0:
		var repair := Button.new()
		repair.text = "Use Repair Kit (+%d HP)" % roundi(Config.data.repair_kit_hp)
		repair.focus_mode = Control.FOCUS_NONE
		repair.pressed.connect(_use_repair_kit.bind(instance_id))
		box.add_child(repair)
	return box


func _install_upgrade(instance_id: int, item_id: String) -> void:
	if Save.install_upgrade(instance_id, item_id):
		_lift_car_instance_id = -2  # the car's spec changed — rebuild the prop
		_ensure_lift_car()
		_refresh_lift_ui()


func _uninstall_upgrade(instance_id: int, item_id: String) -> void:
	if Save.uninstall_upgrade(instance_id, item_id):
		_lift_car_instance_id = -2
		_ensure_lift_car()
		_refresh_lift_ui()


func _use_repair_kit(instance_id: int) -> void:
	if Save.use_repair_kit(instance_id, Config.data.repair_kit_hp):
		_refresh_lift_ui()


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
	_settle_generation += 1  # cancel any pending settle-then-freeze for this lineup
	for car in _cars:
		if is_instance_valid(car):
			car.queue_free()
	for marker in _markers:
		if is_instance_valid(marker):
			marker.queue_free()
	_cars = []
	_markers = []
	_eligible = []


# Park the owned cars ELIGIBLE for the selected rally (the car-select screen).
func _build_eligible_lineup() -> void:
	var rally := RallyLibrary.by_id(_selected_rally_id)
	var eligible: Array = []
	for car in Save.profile.get("cars", []):
		if RallyLibrary.is_eligible(rally, CarLibrary.by_id(String(car.get("model_id", "")))):
			eligible.append(car)
	_build_lineup(eligible)


# Park ALL owned cars for the title screen, so the player's whole collection is on
# show in the car park behind the title overlay (rebuilt on entering EXTERIOR).
func _build_title_lineup() -> void:
	_build_lineup(Save.profile.get("cars", []).duplicate())


# Park the given owned cars, laid out in a centred row at the car-park origin
# (GameConfig.hq_carpark_origin / menu_car_spacing). The cars drop in live and
# settle onto their suspension, then freeze (see _freeze_lineup). Shared by the
# rally car-select lineup (eligible cars) and the title screen (all owned cars).
func _build_lineup(cars: Array) -> void:
	_clear_lineup()
	_eligible = cars
	var cfg: GameConfig = Config.data
	var n := cars.size()
	for i in n:
		var marker := Marker3D.new()
		marker.position = cfg.hq_carpark_origin + Vector3((i - (n - 1) * 0.5) * cfg.menu_car_spacing, 0.0, 0.0)
		add_child(marker)
		_markers.append(marker)
		_cars.append(_spawn_parked_car(cars[i], marker))
	# Let the lineup settle under physics for a moment, then freeze the settled pose.
	# Guarded by a generation id so re-building the lineup cancels a pending freeze
	# for the old one.
	_settle_generation += 1
	get_tree().create_timer(cfg.menu_car_settle_seconds).timeout.connect(
		_freeze_lineup.bind(_settle_generation))


# Spawn one owned car as a live, silent car prop at a marker (raised by
# menu_car_drop_height so it drops onto its suspension), with its OWN mesh copies
# (see _dup_meshes) so a mixed lineup shows each at its true size. It runs physics
# until _freeze_lineup locks the settled pose.
func _spawn_parked_car(owned: Dictionary, marker: Marker3D) -> Node3D:
	var car := CAR_SCENE.instantiate()
	add_child(car)
	car.apply_owned(owned)
	_dup_meshes(car)
	var xform := marker.global_transform
	xform.origin += Vector3.UP * Config.data.menu_car_drop_height
	car.global_transform = xform
	car.freeze = false  # live so it settles; frozen by _freeze_lineup once at rest
	# Silence its engine — no audio from the parked cars.
	var audio := car.get_node_or_null("EngineAudio")
	if audio != null:
		audio.process_mode = Node.PROCESS_MODE_DISABLED
		if audio is AudioStreamPlayer:
			audio.playing = false
			audio.volume_db = -80.0
	return car


# Freeze the settled lineup (called a moment after spawning). No-op if a newer
# lineup has since been built (generation mismatch) or the cars are gone.
func _freeze_lineup(generation: int) -> void:
	if generation != _settle_generation:
		return
	for car in _cars:
		if is_instance_valid(car):
			car.freeze = true
			car.process_mode = Node.PROCESS_MODE_DISABLED


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
		View.LIFT: return _look_xform(cfg.hq_lift_cam_eye, cfg.hq_lift_cam_look)
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
			elif event.is_action_pressed("menu_left"):
				_enter_lift()
			elif event.is_action_pressed("menu_back"):
				_go_to(View.EXTERIOR)
		View.LIFT:
			if event.is_action_pressed("menu_left"):
				_cycle_lift_car(-1)
			elif event.is_action_pressed("menu_right"):
				_cycle_lift_car(1)
			elif event.is_action_pressed("menu_select"):
				_set_lift_tab(LiftTab.UPGRADES if _lift_tab == LiftTab.TUNE else LiftTab.TUNE)
			elif event.is_action_pressed("menu_back"):
				_lift_back()
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
