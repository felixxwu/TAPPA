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
#   * LIFT     — the tuning bay: the selected car raised on the lift on one side. The
#     bay opens on a HUB page (the car's name/description, a Change Car button, and
#     Tuning / Upgrades buttons) bottom-left beside the car. Change Car drops into the
#     car park to pick a new car for the lift; each menu button opens that menu as its
#     OWN full-height page (TUNE = grip/brake/aero sliders; UPGRADES = install parts +
#     repair) so neither needs to scroll; Back returns the page to the hub, and the
#     hub's Back returns to the garage.
#   * CARPARK  — the outdoor lineup of cars: in RALLY mode the cars ELIGIBLE for the
#     chosen rally (pan + Start); in CHANGE-CAR mode the whole collection (pan +
#     Select a new car for the lift).
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

# Camera stations (see the per-station poses in GameConfig "Menu / HQ"). SETTINGS
# is a flat overlay over the exterior shot (no dedicated camera pose), reached from
# the title screen.
#   * OVERFLOW  — the garage-full prompt: shown on entering HQ while the player owns
#     more than GameConfig.max_owned_cars (e.g. after a win pushed them to 11). The
#     whole collection is parked in the car park and the player must scrap one car
#     (the just-won car included; the player's last car excepted) to drop back to the
#     cap before they can do anything else. Reuses the car-park lineup + framing.
enum View { EXTERIOR, GARAGE, TABLE, LIFT, CARPARK, SETTINGS, OVERFLOW }

# The cars offered on first run (the two authored-body cars). The player picks one in
# the car park (see _enter_starter_pick); the chosen one becomes the player's first car.
# Generalises over this list, so a third starter is a one-line add.
const STARTER_MODEL_IDS := ["mx5", "focus", "twingo"]

# The tuning-lift pages (todo/menus.md rig 4). HUB is the bay landing page (car
# name/description + a Change Car button + Tuning/Upgrades buttons); TUNE is
# the handling sliders and UPGRADES is install parts / repair. Each menu is its own
# full-height page (reached from the hub) so neither has to scroll.
enum LiftPage { HUB, TUNE, UPGRADES }

# 1st place earns 3 stars, 2nd → 2, 3rd → 1, anything else (incl. not completed) → 0.
# Shown on the 3D map pins inside the house-style readout box as proper five-pointed
# stars (gold = earned, dim = not) drawn by StarRow — polygons, so they need no font
# glyph (Syne Mono has no ★/☆; same reason the UI uses ASCII like `<`/`>` for nav).
# Emitted once a car-park lineup has finished streaming its props in (the cars spawn
# one-per-frame, see _spawn_lineup_progressive). Lets tests await a fully-parked lineup.
signal lineup_built

const MAX_STARS := 3
const KW_TO_HP := 1.34102  # convert power-to-weight (kW/kg) to the displayed HP/kg

# The map-pin readout box: a 2D UITheme panel (rally name + StarRow) rendered to a
# billboarded Sprite3D. PIN_LABEL_PX is the off-screen viewport resolution; pixel_size
# scales it to world metres; rise is how far above the flag tip the box floats.
const PIN_LABEL_PX := Vector2i(320, 120)
const PIN_LABEL_PIXEL_SIZE := 0.00255  # 1.5x the original 0.0017 so the boxes read bigger
const PIN_LABEL_RISE := 0.16
# Sprite modulate for a readout box whose rally isn't available yet (greyed out).
const PIN_LABEL_DIM := Color(0.5, 0.5, 0.5, 0.4)

# Loaded LAZILY (not preloaded) so the heavy car scene — which pulls in the MX-5 glb,
# its texture and the engine-audio resources — isn't decoded at script-compile time
# (before _ready), which would stretch the "stuck at 100%" gap after Godot's boot bar.
# Both are only needed by _build_hq, which runs behind our LoadingScreen.
const CAR_SCENE_PATH := "res://car.tscn"
const TREE_MODEL_PATH := "res://models/low_poly_tree.glb"
var _car_scene: PackedScene  # cached on first use (load() also caches engine-side)


func _car_scene_res() -> PackedScene:
	if _car_scene == null:
		_car_scene = load(CAR_SCENE_PATH)
	return _car_scene

var _view: int = View.EXTERIOR
var _detail_open := false       # the rally-detail panel is up (a sub-state of TABLE)
var _selected_rally_id := ""
var _selected_instance_id := -1
# The car park serves several jobs. In RALLY mode (the default) it shows the cars
# eligible for the chosen rally and Start launches the rally. In CHANGE-CAR mode
# (entered from the tuning lift's "Change Car" button) it shows ALL owned cars and
# Select swaps the car raised on the lift, returning to the bay. In FREE-ROAM mode
# (the garage's "Free Roam" button) it shows ALL owned cars and Start launches a
# session-less drive with the picked car. _carpark_change_mode / _carpark_freeroam_mode
# (plus the swap / starter flags) pick which.
var _carpark_change_mode := false
# car park is picking an engine-swap partner (see _enter_engine_swap).
var _carpark_swap_mode := false
# True while the car park is showing the first-run starter picker (preview cars from
# CarLibrary, not owned cars — the garage is empty). Select grants the first
# car; see _enter_starter_pick / _confirm_starter.
var _carpark_starter_mode := false
# True while the car park is picking a car for a session-less FREE ROAM drive (entered
# from the garage's "Free Roam" button). It shows ALL owned cars and Start launches
# free roam with the chosen car (see _enter_free_roam / _start_free_roam).
var _carpark_freeroam_mode := false
# On the web build, go fullscreen on the player's first tap (browsers only allow
# fullscreen from a user gesture). Latched so we request it once. Orientation is
# locked to landscape via project.godot (display/window/handheld/orientation).
var _web_fullscreen_done := false

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
# True for the single garage refresh where ensure_repair_safety_net just granted a
# free kit, so the repair row can call it out. Recomputed each _refresh_lift_ui.
var _safety_net_granted := false
var _lift_car_instance_id := -2  # what _lift_car was built for (-2 = nothing yet)
var _lift_page: int = LiftPage.HUB
# Lift animation: the car is LOWERED on the ground in the garage view and RAISED when
# the bay is entered (tweened over hq_lift_raise_time). _lift_raised is the current
# target pose; _lift_tween animates the car's height toward it.
var _lift_raised := false
var _lift_tween: Tween

# 3D staging.
var _camera: Camera3D
var _cam_tween: Tween
var _map_table: MapTable        # the wooden table model the map plane sits on
var _map_plane: MeshInstance3D  # the flat map laid on the table top
var _pins_root: Node3D          # parent of the rally pins
var _pins: Array = []           # the pin Node3Ds (each carries a "rally_id" meta)
var _table_pin_index := -1      # keyboard/gamepad cursor into _unlocked_pins() (-1 = none)

# Overlays (one CanvasLayer per station; only the active one is visible).
var _title_layer: CanvasLayer
var _garage_layer: CanvasLayer
var _table_layer: CanvasLayer
var _detail_layer: CanvasLayer
var _lift_layer: CanvasLayer
var _car_layer: CanvasLayer
var _settings_layer: CanvasLayer
var _overflow_layer: CanvasLayer
# Settings page: the shared SettingsMenu (camera angle + mobile controls), reused by
# the in-run pause menu so both pages match.
var _settings_menu: SettingsMenu
var _settings_sub: Label             # subtitle (changes wording in the pre-rally gate)
var _settings_action_button: Button  # bottom button: "< Back" (title) or "Start >" (gate)
# True when Settings was opened as the mandatory pre-rally control-scheme gate (vs.
# from the title screen) — the bottom button then starts the rally instead of going back.
var _settings_gate := false

var _map_meter: Label           # progress-to-showdown meter on the table HUD
var _detail_title: Label
var _detail_body: Label
var _rally_banner: Label
var _car_name_label: Label
var _car_stats_label: Label
var _start_button: Button
var _title_start_button: Button  # EXTERIOR title Start — default keyboard/gamepad focus
var _title_settings_button: Button  # EXTERIOR title Settings (below Start)
var _title_version_label: Label  # EXTERIOR title build-version readout (bottom-right)
var _no_eligible_label: Label
# Car-park damage UI: a "too damaged" note + a Repair action for a wrecked focused car.
var _car_warning_label: Label
var _car_repair_button: Button

# Garage overlay cursor: a single left/right cursor over the bottom action row
# (Back / Map / Tune Car / Free Roam), painted by _refresh_garage_focus and fired by
# _activate_garage_focus. Buttons are FOCUS_NONE and highlighted by hand (like the
# tuning hub) since the garage is a spatially-navigated 3D station, not a focus graph.
var _garage_back_btn: Button    # "< Back" — index 0
var _garage_table_btn: Button   # "Map" — index 1
var _garage_lift_btn: Button    # "Tune Car" — index 2
var _garage_freeroam_btn: Button  # "Free Roam" — index 3
var _garage_focus := 1          # which garage action the cursor sits on (defaults to Map)

# Garage-overflow overlay widgets (the OVERFLOW station — scrap a car to make room).
var _overflow_banner: Label
var _overflow_car_label: Label
var _overflow_stats_label: Label
var _overflow_note: Label
var _scrap_button: Button

# Tuning-lift overlay widgets.
var _lift_info_panel: PanelContainer  # bottom-left car description panel (hidden when a sub-menu is open)
var _lift_car_label: Label      # selected car name + stats in the bottom-left info panel
var _lift_hub_controls: HBoxContainer  # the HUB page: one row of Back + Change Car + Tuning/Upgrades buttons
var _hub_back_btn: Button       # HUB "< Back" — left of the left/right cursor (index 0)
var _hub_change_btn: Button     # HUB "Change Car" — index 1 of the left/right cursor
var _hub_tune_btn: Button       # HUB "Tuning >" — index 2 of the left/right cursor
var _hub_upgrades_btn: Button   # HUB "Upgrades >" — right of the left/right cursor (index 3)
var _hub_focus := 1             # which hub item the cursor sits on (0 = Back, 1 = Change Car, 2 = Tune, 3 = Upgrades)
var _lift_menu_bg: ColorRect    # the right-side panel that backs a sub-menu (TUNE/UPGRADES)
var _lift_menu_title: Label     # the sub-menu page heading ("TUNE" / "UPGRADES")
var _lift_tune_box: VBoxContainer    # the TUNE menu (sliders)
var _lift_upgrades_box: VBoxContainer  # the UPGRADES menu (install / repair)
var _lift_sliders: Dictionary = {}     # axis -> HSlider
var _lift_slider_rows: Dictionary = {} # axis -> the row Control (to grey out when locked)
var _lift_slider_values: Dictionary = {}  # axis -> the value Label

# Confirmation for applying an upgrade. Applying a part PERMANENTLY consumes it
# from the unlocked pool and fixes it to this car (it can be toggled off but never
# moved — see Save.install_upgrade), so the player accepts this dialog before the
# part is committed. _pending_install holds the queued fit {instance_id, item_id}
# between popping the dialog and the player confirming.
var _confirm_dialog: ConfirmationDialog
var _pending_install: Dictionary = {}


func _ready() -> void:
	_ensure_starter()
	_ensure_selection()
	# Headless (the test runner): build synchronously so tests see a ready HQ after one
	# frame, with no loading cover. A real display gets the covered build below.
	if DisplayServer.get_name() == "headless":
		_build_hq()
		return
	# Godot's boot bar only covers the engine + .pck download + script compile. Building
	# the HQ (ground, buildings, the billboard tree ring, the garage, the parked lineup)
	# runs synchronously and takes a beat — long enough to look frozen once the boot bar
	# finishes. So cover that gap with OUR loading screen FIRST: add it, let it paint,
	# then do the heavy build behind it and reveal.
	var loading := LoadingScreen.new()
	loading.set_title("Entering HQ…")
	loading.set_step("Preparing the garage…")
	add_child(loading)
	# Two frames: the first lays out the overlay (deferred anchors → size), the second
	# draws it, so the build doesn't run before the cover is actually on screen.
	await get_tree().process_frame
	await get_tree().process_frame
	_build_hq()
	# Let the built scene render one frame before lifting the cover, so the reveal lands
	# on the title shot rather than a half-built frame.
	await get_tree().process_frame
	loading.finish()


# Build the whole HQ (environment, station overlays, map pins, initial title view).
# Synchronous; the caller decides whether to cover it with a loading screen.
func _build_hq() -> void:
	_build_environment()
	_build_title_overlay()
	_build_garage_overlay()
	_build_table_overlay()
	_build_detail_overlay()
	_build_lift_overlay()
	_build_car_overlay()
	_build_settings_overlay()
	_build_confirm_dialog()
	_build_overflow_overlay()
	# Enable 3D mouse/touch picking so the table / lift / pins receive input_event.
	get_viewport().physics_object_picking = true
	_refresh_map_pins()
	# Returning from the podium's final Continue opens straight on the GARAGE view
	# (one-shot flag set by podium.gd); a normal boot opens the exterior title.
	# Read + clear it now so it never lingers past this boot.
	var want_garage: bool = RallySession.return_to_garage
	RallySession.return_to_garage = false
	# A win can push the player past the car cap (the car is still granted). If the
	# garage is over capacity on entry, force the scrap-a-car prompt before anything
	# else; otherwise boot to the garage (returning from a rally) or the title shot.
	if _over_car_limit():
		_enter_overflow(true)
	else:
		_go_to(View.GARAGE if want_garage else View.EXTERIOR, true)


# First run no longer auto-grants a car: the player picks their starter (MX-5 vs
# Focus) in the car park on pressing Start (see _enter_starter_pick / _confirm_starter).
# The chosen car is a normal, wreckable car (the repair-kit safety net,
# Save.ensure_repair_safety_net, is the anti-soft-lock floor now). Kept as a hook in
# case a future migration needs to backfill; currently a no-op.
func _ensure_starter() -> void:
	pass


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

	var cfg: GameConfig = Config.data
	# Grass field covering the whole lot, with the concrete apron (below) laid on top
	# around the garage + car park. The grass uses the same texture as the run scene's
	# terrain, tiled to match (terrain_tile_per_meter), sitting a hair below the apron.
	var grass_size := 240.0
	var grass := MeshInstance3D.new()
	var grass_plane := PlaneMesh.new()
	grass_plane.size = Vector2(grass_size, grass_size)
	grass.mesh = grass_plane
	grass.position.y = -0.02  # just under the concrete so the apron wins where they overlap
	var grass_mat := StandardMaterial3D.new()
	grass_mat.albedo_texture = load("res://textures/grass.jpg")
	grass_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	var tiles := grass_size * cfg.terrain_tile_per_meter
	grass_mat.uv1_scale = Vector3(tiles, tiles, 1.0)
	grass.material_override = grass_mat
	add_child(grass)

	# Grey concrete apron around the garage + car park (the player parks / tunes here).
	var concrete := MeshInstance3D.new()
	var concrete_plane := PlaneMesh.new()
	concrete_plane.size = cfg.hq_concrete_size
	concrete.mesh = concrete_plane
	concrete.position = Vector3(cfg.hq_concrete_center.x, 0.0, cfg.hq_concrete_center.z)
	var concrete_mat := StandardMaterial3D.new()
	concrete_mat.albedo_color = Color(0.18, 0.19, 0.22)
	concrete.material_override = concrete_mat
	add_child(concrete)

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
	_build_carpark()
	_build_map_table()
	_build_lift()

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
# skybox, instead of floating on a bare plane. Reuses the stage's low-poly tree
# mesh field (TreeMeshField); scenery only (no collision). A close-in annulus,
# but with the front-centre corridor kept clear so trees never block the title
# camera's view of the car park, and the garage footprint kept clear so none
# spawn inside it. Trees hug the garage's sides and back.
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
	# 0 everywhere, which is all the field needs to seat the trees. Used only
	# during build(), then freed.
	var flat := TerrainManager.new()
	flat.layers = [] as Array[TerrainLayer]
	var field := TreeMeshField.new()
	add_child(field)
	# render_distance 1000 (no cull — HQ is small), no collision (scenery).
	field.build(positions, flat, _hq_tree_mesh(), cfg.tree_size_m.y,
		cfg.tree_collision_radius_m, cfg.tree_collision_height_m,
		1000.0, 0.0, cfg.tree_bin_size_m, false)
	flat.free()


# The tree ArrayMesh, pulled once from the imported .glb scene.
func _hq_tree_mesh() -> Mesh:
	var scene := (load(TREE_MODEL_PATH) as PackedScene).instantiate()
	var stack: Array[Node] = [scene]
	var mesh: Mesh = null
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			mesh = (n as MeshInstance3D).mesh
			break
		for c in n.get_children():
			stack.append(c)
	scene.free()
	return mesh


# The garage shell — the two-bay service-park model (scripts/garage.gd). Open
# toward +Z (the car park) so the camera looks in through the front from the
# garage station; the LEFT bay frames the map table (hq_table_pos, −X) and the
# RIGHT bay frames the tuning lift (hq_lift_pos, +X). The model is sized to the
# hq_garage_size footprint and centred at the origin (front edge at +gz/2, back
# wall at −gz/2), matching the old placeholder so the camera stations and the
# table/lift placement are unchanged. Its own environment + ground are off (the
# HQ provides the sky, sun, grass and concrete apron); it keeps its per-bay
# ceiling lights. The table-map camera (eye y ~2.6) and garage camera both sit
# below the roof (~5.6), so neither looks down through it.
func _build_garage() -> void:
	var cfg: GameConfig = Config.data
	var gx: float = cfg.hq_garage_size.x
	var gz: float = cfg.hq_garage_size.y
	var garage: Node3D = load("res://scripts/garage.gd").new()
	garage.build_environment = false
	garage.build_ground = false
	garage.num_bays = 2
	garage.bay_depth = gz
	# Two bays + three pillars span the full footprint width.
	garage.bay_width = (gx - 3.0 * garage.pillar_w) / 2.0
	# Model origin is the centre of the FRONT edge; shift it forward by half the
	# depth so the shell straddles the origin like the old placeholder did.
	garage.position = Vector3(0.0, 0.0, gz * 0.5)
	add_child(garage)


# --- Car park surface (painted parking bays) ---------------------------------

# Lay a tarmac parking-bay surface in front of the garage: a textured plane over the
# concrete apron with painted white bay dividers, one bay per max_owned_cars slot, so
# each parked car sits in its own marked bay. Centred on the lot (hq_carpark_origin +
# menu_car_park_offset) and sized from the bay width (menu_car_spacing) and depth
# (menu_carpark_bay_depth) so the bay grid lines up exactly with where _build_lineup
# parks the cars. Built once with the HQ; the cars are parked/cleared on top of it.
func _build_carpark() -> void:
	var cfg: GameConfig = Config.data
	var bays: int = max(1, cfg.max_owned_cars)
	var bw: float = cfg.menu_car_spacing
	var depth: float = cfg.menu_carpark_bay_depth
	var center := _carpark_center()
	var surface := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(bays * bw, depth)
	surface.mesh = pm
	# A hair above the concrete apron (y = 0) so the markings win over it without
	# z-fighting; the cars settle onto y = 0, so this sits just under their tyres.
	surface.position = Vector3(center.x, 0.012, center.z)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _carpark_bay_texture(bays)
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	mat.roughness = 0.95
	surface.material_override = mat
	add_child(surface)


# World centre (XZ) of the car-park lot — the bay row + its painted surface share it.
func _carpark_center() -> Vector3:
	var cfg: GameConfig = Config.data
	return cfg.hq_carpark_origin + Vector3(cfg.menu_car_park_offset, 0.0, 0.0)


# World X of the centre of bay `i` (0 = left / −X), derived from the lot centre, bay
# count and bay width so the cars (_build_lineup) and the painted dividers agree.
func _bay_center_x(i: int, bays: int) -> float:
	var bw: float = Config.data.menu_car_spacing
	return _carpark_center().x + (i + 0.5 - bays * 0.5) * bw


# Procedural tarmac-with-bay-markings texture: a dark asphalt field with white bay
# dividers every bay (bays + 1 lines) plus a solid "kerb" line across the back of the
# bays (the edge the nose-out cars back up to). The divider period matches one bay so,
# tiled 1:1 across the surface plane, the lines fall on the bay boundaries.
func _carpark_bay_texture(bays: int) -> ImageTexture:
	var px_per_bay := 96
	var w := bays * px_per_bay
	var h := 200
	var img := Image.create(w, h, true, Image.FORMAT_RGBA8)
	var asphalt := Color(0.15, 0.16, 0.18)
	var paint := Color(0.86, 0.87, 0.84)
	img.fill(asphalt)
	var half := 3  # half line width, px
	# Vertical bay dividers (run front-to-back along the plane's V / world Z).
	for b in range(bays + 1):
		var cx := clampi(b * px_per_bay, half, w - half - 1)
		for x in range(cx - half, cx + half + 1):
			for y in range(h):
				img.set_pixel(x, y, paint)
	# A solid kerb line across the back edge of every bay.
	for y in range(0, half * 2 + 1):
		for x in range(w):
			img.set_pixel(x, y, paint)
	img.generate_mipmaps()  # the lines minify cleanly when the lot is far / oblique
	return ImageTexture.create_from_image(img)


# The map table: a block with the flat 3D map plane on top + a pickable area so a tap
# (in the garage view) drops the camera to the table view.
func _build_map_table() -> void:
	var cfg: GameConfig = Config.data
	var p: Vector3 = cfg.hq_table_pos
	var s: Vector3 = cfg.hq_table_size
	# A proper wooden table (top + apron + legs + stretchers) instead of a plain
	# block; its top surface sits at y = s.y so the map plane / pins still align.
	_map_table = MapTable.new()
	_map_table.table_size = s
	_map_table.position = p
	add_child(_map_table)
	var top_y := p.y + s.y

	_map_plane = MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = cfg.hq_map_plane_size
	_map_plane.mesh = pm
	var mm := StandardMaterial3D.new()
	# Satellite map photo laid over the (now square) table top. Unshaded so the
	# aerial colours read true under the garage lighting from the near-top-down
	# table camera, rather than being darkened by the directional sun's angle.
	mm.albedo_texture = load("res://textures/map_table.jpg")
	mm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	mm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
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

# (Re)build the rally pins on the table's map plane: a state-coloured flag marker
# (RallyFlag) at each rally's normalised map_pos, with a billboarded house-style black
# box above it holding the rally name and a row of five-pointed stars (1st-place best →
# 3 gold, 2nd → 2, 3rd → 1, else dim). The flag colour encodes the medal tier; the
# showdown pin is locked (grey/disabled, non-pickable) until every other rally is done.
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

	# The marker: a procedural flag whose look encodes the rally's state — a checkered
	# pennant once podiumed, else green (an eligible car is owned) or grey (none /
	# locked), with a gold tip+base once won. See RallyFlag / features/menus.md.
	var earned := _stars_for(rally_id)
	var has_eligible := _has_eligible_car(rally)
	var flag := RallyFlag.build(locked, earned, has_eligible)
	pin.add_child(flag)
	var marker_top := RallyFlag.POLE_HEIGHT

	# Readout: a single design-system black box floating above the flag, holding the
	# rally name and a row of proper five-pointed stars (gold earned / dim not). Built
	# as a 2D UITheme panel rendered to a billboarded sprite, so it gets the real house
	# look (pure-black panel, Syne Mono, uppercase) and always faces the camera. The box
	# is dimmed for a rally that isn't available yet — locked, or with no eligible car.
	var available := not locked and has_eligible
	var label := _build_pin_label(String(rally["name"]), earned, available)
	label.position = Vector3(0.0, marker_top + PIN_LABEL_RISE, 0.0)
	pin.add_child(label)
	# Keep the readout panel reachable so the keyboard/gamepad cursor can paint it with
	# the hover-style selection look (see _select_table_pin) without resizing the pin.
	pin.set_meta("label_panel", label.get_meta("panel"))

	# Pickable hit spheres (skipped for a locked pin so it can't be entered), both bound
	# to the same handler so a click on EITHER the flag/pole OR the floating readout box
	# enters the rally. The box target makes the menu itself tappable (a bigger, easier
	# target than the slim flag); its radius is kept under half the closest pin spacing
	# (~0.72 m) so neighbouring menus' targets don't overlap.
	if not locked:
		_add_pin_hit(pin, rally_id, Vector3(0.0, marker_top * 0.5, 0.0), 0.28)
		_add_pin_hit(pin, rally_id, Vector3(0.0, marker_top + PIN_LABEL_RISE, 0.0), 0.32)
	return pin


# Add a pickable sphere Area3D (radius `r`, at local `pos`) to `pin`, routing clicks to
# the rally-pin handler for `rally_id`.
func _add_pin_hit(pin: Node3D, rally_id: String, pos: Vector3, r: float) -> void:
	var area := Area3D.new()
	var cs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = r
	cs.shape = sph
	area.add_child(cs)
	area.position = pos
	area.input_ray_pickable = true
	area.input_event.connect(_on_pin_input.bind(rally_id))
	pin.add_child(area)


# Build the floating readout box for a pin: a design-system black panel holding the
# rally name (Syne Mono, uppercase) above a row of proper StarRow stars, composited in
# an off-screen SubViewport and shown on a billboarded Sprite3D so it always faces the
# camera as one unit. The viewport owns the sprite as a child so it's freed with the pin.
func _build_pin_label(rally_name: String, earned: int, available := true) -> Sprite3D:
	var vp := SubViewport.new()
	vp.size = PIN_LABEL_PX
	vp.transparent_bg = true
	vp.gui_disable_input = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS

	# Centre a content-hugging house panel in the viewport; the rest stays transparent
	# so only the black box shows.
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	vp.add_child(center)

	var panel := UITheme.panel(1.0, 14)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", UITheme.GAP)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_child(box)

	box.add_child(UITheme.title(rally_name))

	var stars := StarRow.new()
	stars.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.add_child(stars)
	stars.setup(earned, MAX_STARS)

	UITheme.enforce(panel)  # house rules: uppercase + one font size

	var sprite := Sprite3D.new()
	sprite.add_child(vp)
	sprite.texture = vp.get_texture()
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sprite.shaded = false
	sprite.pixel_size = PIN_LABEL_PIXEL_SIZE
	sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	# Grey the whole readout out for a rally that can't be entered yet (locked / no
	# eligible car), so it reads as disabled to match its grey flag.
	if not available:
		sprite.modulate = PIN_LABEL_DIM
	# Hand the panel back so the pin (via _make_pin) can repaint it on selection.
	sprite.set_meta("panel", panel)
	return sprite


# Stars earned in a rally from the player's best finish: 1st → 3, 2nd → 2, 3rd → 1,
# anything else (or never placed) → 0.
func _stars_for(rally_id: String) -> int:
	var placed := Save.best_placement(rally_id)
	if placed >= 1 and placed <= MAX_STARS:
		return MAX_STARS + 1 - placed
	return 0


# Whether the player owns at least one car eligible to enter `rally` — drives the
# pin flag's green (raceable) vs grey (no qualifying car) pennant. Mirrors the
# eligibility filter used to build the car-park lineup (_build_eligible_lineup).
func _has_eligible_car(rally: Dictionary) -> bool:
	for car in Save.profile.get("cars", []):
		var meta := UpgradeLibrary.effective_meta(car, CarLibrary.by_id(String(car.get("model_id", ""))))
		if RallyLibrary.is_eligible(rally, meta):
			return true
	return false


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
	# Sit the buttons at the BOTTOM of the screen so the HQ (garage + parked
	# collection) stays visible above them rather than being covered by a centred menu.
	root.alignment = BoxContainer.ALIGNMENT_END

	# Title screen is just the Start button (and a Settings button below it) over the
	# parked-collection backdrop — no title/subtitle text.
	# The title overlay is a flat two-button menu (no spatial 3D nav here), so it uses
	# native focus: Start is focused on entry, ui_up/ui_down move between the two,
	# ui_accept fires the focused one. (The 3D stations behind it keep menu_* nav.)
	var start := Button.new()
	start.text = "Start"
	start.focus_mode = Control.FOCUS_ALL
	start.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	start.custom_minimum_size = Vector2(220, 52)
	start.pressed.connect(_on_exterior_start)
	root.add_child(start)
	_title_start_button = start

	var settings := Button.new()
	settings.text = "Settings"
	settings.focus_mode = Control.FOCUS_ALL
	settings.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	settings.custom_minimum_size = Vector2(220, 44)
	settings.pressed.connect(func() -> void: _open_settings(false))
	root.add_child(settings)
	_title_settings_button = settings

	# Build version, shown only on the title screen (bottom-right corner). It is
	# stamped into application/config/version by build_web.sh (0.<git commit count>
	# + short SHA) and falls back to the project default on editor/dev runs.
	var ver := str(ProjectSettings.get_setting("application/config/version", ""))
	var version_label := Label.new()
	version_label.text = ("v" + ver) if ver != "" else "dev"
	version_label.add_theme_font_size_override("font_size", 12)
	version_label.anchor_left = 1.0
	version_label.anchor_right = 1.0
	version_label.anchor_top = 1.0
	version_label.anchor_bottom = 1.0
	version_label.offset_left = -120.0
	version_label.offset_top = -28.0
	version_label.offset_right = -12.0
	version_label.offset_bottom = -8.0
	version_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	version_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	version_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	version_label.modulate = Color(1, 1, 1, 0.6)
	_title_layer.add_child(version_label)
	_title_version_label = version_label


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
	# Back / Open map table / Tune car form a single left/right cursor (_garage_focus),
	# painted by _refresh_garage_focus. FOCUS_NONE + hand-painted like the tuning hub,
	# since the garage is a spatially-navigated 3D station, not a native focus graph.
	var back := Button.new()
	back.text = "< Back"
	back.focus_mode = Control.FOCUS_NONE
	back.pressed.connect(func() -> void: _go_to(View.EXTERIOR))
	actions.add_child(back)
	_garage_back_btn = back
	# Convenience buttons mirroring the clickable 3D table / lift.
	var to_table := Button.new()
	to_table.text = "Map"
	to_table.focus_mode = Control.FOCUS_NONE
	to_table.pressed.connect(_enter_table)
	actions.add_child(to_table)
	_garage_table_btn = to_table
	var to_lift := Button.new()
	to_lift.text = "Tune Car"
	to_lift.focus_mode = Control.FOCUS_NONE
	to_lift.pressed.connect(_enter_lift)
	actions.add_child(to_lift)
	_garage_lift_btn = to_lift
	# Free Roam: drop straight into a freshly-seeded stage with neutral (0.5) terrain
	# settings — no rally, no opponents, just driving (see _enter_free_roam).
	var to_free := Button.new()
	to_free.text = "Free Roam"
	to_free.focus_mode = Control.FOCUS_NONE
	to_free.pressed.connect(_enter_free_roam)
	actions.add_child(to_free)
	_garage_freeroam_btn = to_free

	_passthrough_overlay(root)  # let taps reach the 3D table / lift behind the HUD


func _build_table_overlay() -> void:
	var made := _make_overlay()
	_table_layer = made[0]
	var root: VBoxContainer = made[1]

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
	bg.color = Color(0.0, 0.0, 0.0, 0.96)
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


# The tuning bay. The raised car is framed to the LEFT by the lift camera
# (hq_lift_cam_*); everything sits on top in one CanvasLayer with two faces:
#
#   * The HUB (default on entry) — a bottom column beside/under the car: the
#     selected car's name/description (filling the page width), then UNDER it a
#     Change Car button and the Tuning + Upgrades buttons that open each menu.
#   * A SUB-MENU page (TUNE or UPGRADES) — a solid panel CENTRED horizontally
#     (hq_lift_menu_centered_width_frac of the width) using most of the screen; the car
#     description hides while it's up. Because the hub controls + page chrome live
#     on the hub, each sub-menu gets the full panel height to itself and needn't scroll.
#
# _refresh_lift_ui toggles which face is shown from _lift_page.
func _build_lift_overlay() -> void:
	var frac: float = Config.data.hq_lift_menu_centered_width_frac
	_lift_layer = CanvasLayer.new()
	add_child(_lift_layer)

	# --- The sub-menu panel (shown on the TUNE / UPGRADES pages) ---
	# Centred horizontally and wide (hq_lift_menu_centered_width_frac) so an open page
	# uses most of the screen; the car description hides while it's up (_refresh_lift_ui).
	_lift_menu_bg = ColorRect.new()
	_lift_menu_bg.anchor_left = (1.0 - frac) * 0.5
	_lift_menu_bg.anchor_right = 1.0 - (1.0 - frac) * 0.5
	_lift_menu_bg.anchor_top = 0.0
	_lift_menu_bg.anchor_bottom = 1.0
	_lift_menu_bg.color = Color(0.0, 0.0, 0.0, 0.96)
	_lift_layer.add_child(_lift_menu_bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	_lift_menu_bg.add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)

	_lift_menu_title = Label.new()
	_lift_menu_title.add_theme_font_size_override("font_size", 22)
	root.add_child(_lift_menu_title)

	# A scroll container is kept as a safety net for very short screens, but with each
	# menu on its own page (no change-car control or tab strip above it) the content is
	# meant to fit without scrolling.
	var scroll := TouchScrollContainer.new()
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

	var menu_back := Button.new()
	menu_back.text = "< Back"
	menu_back.focus_mode = Control.FOCUS_NONE
	menu_back.pressed.connect(_lift_hub)
	root.add_child(menu_back)

	# --- The bottom column: car-description info panel + (on the HUB) the change-car
	# selector and the Tuning / Upgrades buttons. Spans the full page width (the sub-menu
	# no longer needs room on the right) and grows upward so the info panel sits at the
	# bottom with the hub controls above it; mouse-transparent except buttons.
	var left_col := VBoxContainer.new()
	left_col.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	left_col.offset_left = 20
	left_col.offset_right = -20
	left_col.offset_bottom = -20
	left_col.grow_vertical = Control.GROW_DIRECTION_BEGIN
	left_col.add_theme_constant_override("separation", 10)
	left_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lift_layer.add_child(left_col)

	_lift_info_panel = PanelContainer.new()
	var info_panel := _lift_info_panel
	info_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Solid black, sharp-cornered house panel (design system).
	info_panel.add_theme_stylebox_override("panel", UITheme.panel_box(0.82, 14))
	left_col.add_child(info_panel)
	var info := VBoxContainer.new()
	info.add_theme_constant_override("separation", 4)
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info_panel.add_child(info)
	_lift_car_label = Label.new()
	_lift_car_label.add_theme_font_size_override("font_size", 14)
	_lift_car_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lift_car_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_child(_lift_car_label)

	# The hub controls UNDER the car description: a SINGLE bottom row holding Back, the
	# Change Car button, and the Tuning / Upgrades buttons. Shown only on the HUB page
	# (_refresh_lift_ui). Hugs content on the left so the raised car stays in clear view.
	_lift_hub_controls = HBoxContainer.new()
	_lift_hub_controls.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_lift_hub_controls.add_theme_constant_override("separation", 8)
	_lift_hub_controls.mouse_filter = Control.MOUSE_FILTER_IGNORE
	left_col.add_child(_lift_hub_controls)

	# Back / Change Car / Tuning / Upgrades form a single left/right cursor (_hub_focus),
	# painted by _refresh_hub_focus.
	var back := Button.new()
	back.text = "< Back"
	back.focus_mode = Control.FOCUS_NONE
	back.pressed.connect(func() -> void: _go_to(View.GARAGE))
	_lift_hub_controls.add_child(back)
	_hub_back_btn = back

	# Change which car is on the lift: opens the car park to pick a new selected car.
	var change_car := Button.new()
	change_car.text = "Change Car"
	change_car.focus_mode = Control.FOCUS_NONE
	change_car.pressed.connect(_enter_change_car)
	_lift_hub_controls.add_child(change_car)
	_hub_change_btn = change_car

	# The two menu buttons.
	var to_tune := Button.new()
	to_tune.text = "Tuning >"
	to_tune.focus_mode = Control.FOCUS_NONE
	to_tune.pressed.connect(_open_lift_page.bind(LiftPage.TUNE))
	_lift_hub_controls.add_child(to_tune)
	_hub_tune_btn = to_tune
	var to_upgrades := Button.new()
	to_upgrades.text = "Upgrades >"
	to_upgrades.focus_mode = Control.FOCUS_NONE
	to_upgrades.pressed.connect(_open_lift_page.bind(LiftPage.UPGRADES))
	_lift_hub_controls.add_child(to_upgrades)
	_hub_upgrades_btn = to_upgrades


# Build the TUNE menu: one slider row per tuning axis. Static structure; gating /
# values are refreshed per car by _refresh_lift_ui.
func _build_lift_tune_box(parent: VBoxContainer) -> void:
	_lift_tune_box = VBoxContainer.new()
	_lift_tune_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lift_tune_box.add_theme_constant_override("separation", 8)
	parent.add_child(_lift_tune_box)

	var hint := Label.new()
	hint.text = "Free & reversible."
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
		{"axis": "engine_detune", "name": "Engine detune", "lo": "0%", "hi": "100%",
			"min": 0.0, "max": 100.0, "step": 5.0, "fmt": "%d%%"},
	]:
		_lift_tune_box.add_child(_make_slider_row(spec))

	var reset := Button.new()
	reset.text = "Reset to neutral"
	reset.focus_mode = Control.FOCUS_ALL
	reset.pressed.connect(_reset_tuning)
	_lift_tune_box.add_child(reset)


func _make_slider_row(spec: Dictionary) -> Control:
	var axis := String(spec["axis"])
	# Use horizontal space: a left column (name above value) sits beside a right
	# column (the slider above its extremity labels).
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 16)
	row.alignment = BoxContainer.ALIGNMENT_CENTER

	# Left column: name on top of the current value. FIXED width (clip, don't grow) so
	# a longer value — e.g. the detune row's "80% - 0.20 HP/kg" readout — can't widen
	# this column and shrink only that row's slider. Every row's slider column then
	# gets the same leftover width, so all sliders line up to the same length.
	var label_col := VBoxContainer.new()
	label_col.add_theme_constant_override("separation", 2)
	label_col.custom_minimum_size = Vector2(180, 0)
	label_col.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	row.add_child(label_col)
	var name_label := Label.new()
	name_label.text = String(spec["name"])
	name_label.add_theme_font_size_override("font_size", 16)
	name_label.clip_text = true
	label_col.add_child(name_label)
	var value := Label.new()
	value.add_theme_font_size_override("font_size", 14)
	value.modulate = Color(1, 1, 1, 0.8)
	value.clip_text = true
	label_col.add_child(value)
	_lift_slider_values[axis] = value

	# Right column: the slider with its extremity labels beneath.
	var slider_col := VBoxContainer.new()
	slider_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider_col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider_col.add_theme_constant_override("separation", 2)
	row.add_child(slider_col)

	var slider := HSlider.new()
	slider.min_value = float(spec.get("min", -1.0))
	slider.max_value = float(spec.get("max", 1.0))
	slider.step = float(spec.get("step", 0.05))
	# Focusable: ui_up/ui_down walk between sliders, ui_left/ui_right nudge the focused
	# one (the natural Range behaviour) — keyboard/gamepad tuning with no pointer.
	slider.focus_mode = Control.FOCUS_ALL
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(_on_tune_slider_changed.bind(axis))
	slider_col.add_child(slider)
	_lift_sliders[axis] = slider

	var ends := HBoxContainer.new()
	slider_col.add_child(ends)
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

	# Shown only when the focused car is wrecked: why it can't be entered + how to fix it.
	_car_warning_label = Label.new()
	_car_warning_label.add_theme_font_size_override("font_size", 14)
	_car_warning_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_car_warning_label.add_theme_color_override("font_color", UITheme.RED)
	_car_warning_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_car_warning_label.visible = false
	root.add_child(_car_warning_label)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	root.add_child(actions)
	var back := Button.new()
	back.text = "< Back"
	back.focus_mode = Control.FOCUS_NONE
	back.pressed.connect(_car_back)
	actions.add_child(back)
	# Repair the focused wrecked car (uses one kit, restores full health, enables Start).
	# Hidden unless the focused car is wrecked AND a Repair Kit is owned.
	_car_repair_button = Button.new()
	_car_repair_button.text = "Repair (1 kit)"
	_car_repair_button.focus_mode = Control.FOCUS_NONE
	_car_repair_button.visible = false
	_car_repair_button.pressed.connect(_repair_focused_car)
	actions.add_child(_car_repair_button)
	_start_button = Button.new()
	_start_button.text = "Start Rally"
	_start_button.focus_mode = Control.FOCUS_NONE
	_start_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_start_button.pressed.connect(_on_start_pressed)
	actions.add_child(_start_button)


# --- Garage overflow (scrap a car to make room) ------------------------------

# The OVERFLOW overlay: a banner + the focused car's name/stats, the same ◄ / ►
# car selector as the car park, and a "Scrap this car" action. Mirrors the car
# overlay's bottom-anchored layout so the 3D lineup shows above it.
func _build_overflow_overlay() -> void:
	var made := _make_overlay(16.0)
	_overflow_layer = made[0]
	var root: VBoxContainer = made[1]

	_overflow_banner = Label.new()
	_overflow_banner.add_theme_font_size_override("font_size", 22)
	root.add_child(_overflow_banner)

	var hint := Label.new()
	hint.text = "Your garage is full. Pick a car to scrap — the just-won car counts too."
	hint.add_theme_font_size_override("font_size", 14)
	root.add_child(hint)

	# Push the nav + actions to the bottom so the 3D car park is visible above.
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(spacer)

	# Car selector: ◄ / ► pan the camera to the prev/next owned car.
	var nav := HBoxContainer.new()
	nav.add_theme_constant_override("separation", 8)
	root.add_child(nav)
	var prev := Button.new()
	prev.text = "<"
	prev.focus_mode = Control.FOCUS_NONE
	prev.pressed.connect(_cycle_focus.bind(-1))
	nav.add_child(prev)
	_overflow_car_label = Label.new()
	_overflow_car_label.add_theme_font_size_override("font_size", 18)
	_overflow_car_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_overflow_car_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	nav.add_child(_overflow_car_label)
	var next := Button.new()
	next.text = ">"
	next.focus_mode = Control.FOCUS_NONE
	next.pressed.connect(_cycle_focus.bind(1))
	nav.add_child(next)

	_overflow_stats_label = Label.new()
	_overflow_stats_label.add_theme_font_size_override("font_size", 12)
	_overflow_stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_overflow_stats_label)

	_overflow_note = Label.new()
	_overflow_note.add_theme_font_size_override("font_size", 12)
	_overflow_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_overflow_note.modulate = Color(1, 0.8, 0.4)
	root.add_child(_overflow_note)

	_scrap_button = Button.new()
	_scrap_button.text = "Scrap this car"
	_scrap_button.focus_mode = Control.FOCUS_NONE
	_scrap_button.pressed.connect(_on_scrap_pressed)
	root.add_child(_scrap_button)


# Whether the player owns more cars than the cap (so the scrap prompt must show).
func _over_car_limit() -> bool:
	return _owned_count() > Config.data.max_owned_cars


func _owned_count() -> int:
	return Save.profile.get("cars", []).size()


# Enter the scrap-a-car prompt: park the WHOLE collection and frame the first car.
func _enter_overflow(snap := false) -> void:
	_build_lineup(Save.profile.get("cars", []).duplicate())
	_view = View.OVERFLOW
	_detail_open = false
	_clear_lift_car()  # not inside the garage while overflowing
	_update_overlays()
	_focus = 0
	_focus_changed(snap)


# Scrap the focused car (unless it's the player's last car), then re-evaluate: stay
# in the prompt while still over the cap, otherwise fly out to the title.
func _on_scrap_pressed() -> void:
	if _eligible.is_empty() or _focus >= _eligible.size():
		return
	var owned: Dictionary = _eligible[_focus]
	var id := int(owned.get("instance_id", -1))
	if not Save.scrap_car(id):
		return
	Save.save()
	if _selected_instance_id == id:
		_selected_instance_id = -1
	if _over_car_limit():
		_enter_overflow(true)  # rebuild the (smaller) lineup, keep prompting
	else:
		_clear_lineup()
		_go_to(View.EXTERIOR, true)


# Refresh the overflow overlay for the focused car (banner count, name, stats, and
# the scrap button — disabled with a note when it's the player's last car).
func _refresh_overflow_ui(owned: Dictionary, entry: Dictionary, stats: String) -> void:
	_overflow_banner.text = "GARAGE FULL — scrap a car to make room  (%d / %d)" % [
		_owned_count(), Config.data.max_owned_cars]
	_overflow_car_label.text = "%s  #%d  (%d of %d)" % [
		entry.get("name", owned.get("model_id", "?")),
		int(owned.get("instance_id", -1)), _focus + 1, _eligible.size()]
	_overflow_stats_label.text = stats
	var last_car := _owned_count() <= 1
	_scrap_button.disabled = last_car
	_overflow_note.text = "Your last car can't be scrapped — choose another." if last_car else ""


# --- Settings page -----------------------------------------------------------

# The title-screen Settings overlay: the shared SettingsMenu (camera angle + mobile
# control scheme). Choices are highlighted and persisted via Save.set_setting; the
# same component backs the in-run pause menu, so the two pages stay identical.
func _build_settings_overlay() -> void:
	var made := _make_overlay()
	_settings_layer = made[0]
	var root: VBoxContainer = made[1]

	var title := Label.new()
	title.text = "SETTINGS"
	title.add_theme_font_size_override("font_size", 32)
	root.add_child(title)

	_settings_sub = Label.new()
	_settings_sub.text = "Camera & controls:"
	_settings_sub.add_theme_font_size_override("font_size", 16)
	root.add_child(_settings_sub)

	var scroll := TouchScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	_settings_menu = SettingsMenu.new()
	_settings_menu.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_settings_menu.page_changed.connect(_on_settings_page_changed)
	scroll.add_child(_settings_menu)

	_settings_action_button = Button.new()
	_settings_action_button.text = "< Back"
	# Focusable so down-nav from the last category row reaches the bottom button.
	_settings_action_button.focus_mode = Control.FOCUS_ALL
	_settings_action_button.pressed.connect(_on_settings_action)
	root.add_child(_settings_action_button)


# Open the Settings page. `gate` = the mandatory pre-rally pick (bottom button starts
# the rally); otherwise it's the title-screen settings (bottom button goes back).
# Always reset to the category list so each open starts at the top level.
func _open_settings(gate: bool) -> void:
	_settings_gate = gate
	_settings_sub.text = ("Choose your touch controls to start:" if gate
		else "Camera & controls:")
	_settings_menu.show_list()  # emits page_changed → sets the bottom button label
	_go_to(View.SETTINGS)


# Keep the single bottom button in step with the page: on a sub-page it backs out
# to the list ("< Back"); on the list it is the host's own action — "Start >" in the
# pre-rally gate, "< Back" (to the exterior) on the title screen.
func _on_settings_page_changed(is_root: bool) -> void:
	if _settings_action_button == null:
		return  # SettingsMenu._ready fires its first page_changed before the button exists
	_settings_action_button.text = "Start >" if (is_root and _settings_gate) else "< Back"


# The settings bottom button. On a sub-page it returns to the category list. On the
# list, in the pre-rally gate, make sure a scheme is saved (the highlighted default
# if the player didn't tap one) so we never ask again, then start the rally; from the
# title screen it just returns to the exterior.
func _on_settings_action() -> void:
	if not _settings_menu.at_root():
		_settings_menu.show_list()
		return
	if _settings_gate:
		if Save.get_setting(MobileControls.SETTING_KEY, null) == null:
			Save.set_setting(MobileControls.SETTING_KEY, MobileControls.DEFAULT_SCHEME)
		_settings_gate = false
		_begin_rally_start()
	else:
		_go_to(View.EXTERIOR)


# --- Confirmation dialog -----------------------------------------------------

# A shared yes/no dialog for irreversible actions. Currently the upgrade-apply
# gate: applying a part consumes it from the unlocked pool and fixes it to this
# car for good (toggleable, never movable or refunded — not even on a wreck), so
# the player confirms before committing. _on_install_confirmed runs on accept.
func _build_confirm_dialog() -> void:
	_confirm_dialog = ConfirmationDialog.new()
	_confirm_dialog.title = "Fit upgrade?"
	_confirm_dialog.ok_button_text = "Fit it"
	_confirm_dialog.get_cancel_button().text = "Cancel"
	_confirm_dialog.confirmed.connect(_on_install_confirmed)
	add_child(_confirm_dialog)


# Show only the active station's overlay (detail is a TABLE sub-state).
func _update_overlays() -> void:
	_title_layer.visible = _view == View.EXTERIOR
	_garage_layer.visible = _view == View.GARAGE
	_table_layer.visible = _view == View.TABLE and not _detail_open
	_detail_layer.visible = _view == View.TABLE and _detail_open
	_lift_layer.visible = _view == View.LIFT
	_car_layer.visible = _view == View.CARPARK
	_settings_layer.visible = _view == View.SETTINGS
	_overflow_layer.visible = _view == View.OVERFLOW
	_normalize_menus()


# Apply the design-system house rules (uppercase + one font size + fixed
# single-line button height) to every overlay. Re-run on each view change and
# after any dynamic text refresh so the rules keep holding as labels change.
func _normalize_menus() -> void:
	for layer in [_title_layer, _garage_layer, _table_layer, _detail_layer,
			_lift_layer, _car_layer, _settings_layer, _overflow_layer]:
		if layer != null:
			UITheme.enforce(layer)


# --- Station transitions -----------------------------------------------------

# Move to a station: update overlays + fly the camera there. CARPARK framing tracks
# the focused car, so it's driven by _focus_changed (after the lineup is built).
func _go_to(view: int, snap := false) -> void:
	_view = view
	if view != View.TABLE:
		_detail_open = false
	# Drop any GUI focus when changing station. HQ hides overlays by toggling their
	# CanvasLayer, which does NOT clear a Control's focus (a CanvasLayer breaks the
	# visibility chain), so a button on the view we just left would otherwise keep
	# focus and silently swallow arrow keys / Enter in the next, spatially-navigated
	# station. The native-focus views (the title, below; Settings + lift sub-pages
	# via their own paths) re-grab a control immediately after.
	get_viewport().gui_release_focus()
	# The title screen shows the player's whole collection parked in the car park.
	if view == View.EXTERIOR:
		_build_title_lineup()
	# The selected car sits on the lift whenever we're inside (garage/lift); it costs
	# nothing once frozen, so keep it around while inside and drop it otherwise. In the
	# garage it rests LOWERED on the ground; entering the bay (_enter_lift) raises it.
	if view == View.GARAGE:
		_ensure_lift_car()
		_lower_lift_car()
		_garage_focus = 1  # seat the cursor on Open map table each time we enter the garage
		_refresh_garage_focus()
	elif view == View.LIFT:
		_ensure_lift_car()  # the slow raise is triggered by _enter_lift
	else:
		_clear_lift_car()
	# Land the keyboard/gamepad cursor on the title's Start button (the title is the one
	# HQ overlay driven by native focus; the rest use spatial menu_* nav).
	if view == View.EXTERIOR:
		UITheme.focus_grab.bind(_title_start_button).call_deferred()
	_update_overlays()
	if view == View.CARPARK:
		return  # camera handled by _focus_changed once the lineup exists
	_move_camera_to(_station_xform(view), snap)


func _on_exterior_start() -> void:
	_maybe_enter_web_fullscreen()
	# First-time players (no starter chosen yet) pick a starter car in the car park;
	# returning players go straight to the garage.
	if not bool(Save.profile.get("starter_picked", false)):
		_enter_starter_pick()
	else:
		_go_to(View.GARAGE)


# Take the web/mobile build fullscreen on the first user gesture, but ONLY when we're
# stuck in portrait. Browsers reject fullscreen outside a user-activation context, so
# this is called from input handlers (the Start button / first tap — see
# _unhandled_input). Gated to the touch web build so a desktop browser isn't forced
# fullscreen during dev.
#
# Crucial: some embedders (itch.io) already auto-present the game fullscreen in
# landscape. Re-requesting fullscreen on the canvas there FLIPS it to portrait, so if
# we're already landscape we leave it alone — there's nothing to fix. We only force
# fullscreen when the viewport is portrait; the landscape orientation lock then comes
# from the export's fullscreenchange handler (export_presets head_include).
func _maybe_enter_web_fullscreen() -> void:
	if _web_fullscreen_done or not OS.has_feature("web"):
		return
	if not (DisplayServer.is_touchscreen_available() or Config.data.mobile_controls_force):
		return
	_web_fullscreen_done = true
	var size := DisplayServer.window_get_size()
	if size.x >= size.y:
		return  # already landscape (e.g. itch.io's auto-fullscreen) — don't disturb it
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)


# Free Roam: open the car park to pick which owned car to drive. Parks the WHOLE owned
# collection (like Change Car) and frames the currently-selected car; Start launches
# free roam with the focused car (see _start_free_roam), Back returns to the garage.
func _enter_free_roam() -> void:
	_carpark_freeroam_mode = true
	_carpark_change_mode = false
	_carpark_swap_mode = false
	_carpark_starter_mode = false
	_build_lineup(Save.profile.get("cars", []).duplicate())
	_rally_banner.text = "Free roam — pick your car"
	_no_eligible_label.visible = false
	_start_button.text = "Start Free Roam"
	_start_button.disabled = _eligible.is_empty()
	_view = View.CARPARK
	_detail_open = false
	_update_overlays()
	# Frame the currently-selected car, defaulting to the first parked car.
	_focus = 0
	var sel := Save.selected_instance_id()
	for i in _eligible.size():
		if int(_eligible[i].get("instance_id", -1)) == sel:
			_focus = i
			break
	_focus_changed(true)


# Launch free roam with the focused car: no rally, no opponents — just drive. Selects
# the car, hands its instance to RallySession.free_roam_instance_id (world.gd fields it
# with no active session), writes a FRESH random seed + neutral (0.5) terrain settings
# into the live Config, then loads the run scene. The player leaves via Pause → Quit to
# HQ (pause_menu.gd loads hq.tscn directly when no session is active). A random seed
# each time means a different track on every entry.
func _start_free_roam() -> void:
	if _selected_instance_id < 0:
		return
	# Field this car for the drive, and select it so the lift shows it on return.
	Save.set_selected_car(_selected_instance_id)
	RallySession.free_roam_instance_id = _selected_instance_id
	_carpark_freeroam_mode = false
	_clear_lineup()
	_selected_instance_id = -1
	_prepare_free_roam()
	var loading := LoadingScreen.new()
	loading.set_step("Loading free roam…")
	add_child(loading)
	# Let the overlay paint before the synchronous scene change (mirrors _begin_rally_start).
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().change_scene_to_file("res://main.tscn")


# Config setup for free roam, split out so it's testable without a scene change: clear
# any active session, then write a fresh random seed + neutral terrain settings into the
# live Config. A random seed means a new track every entry.
func _prepare_free_roam() -> void:
	# Ensure no stale session steers world.gd down the rally path.
	if RallySession.is_active():
		RallySession.abandon()
	var cfg: GameConfig = Config.data
	cfg.track_seed = randi()
	cfg.track_straightness = 0.5
	cfg.track_forestiness = 0.5
	cfg.track_tarmac_fraction = 0.5


func _enter_table() -> void:
	_detail_open = false
	_table_pan = Vector3.ZERO  # re-centre the map each time we open it
	_table_dragged = false
	_table_panning = false
	_refresh_map_pins()  # reflect any newly-earned stars / showdown unlock
	# Seat the keyboard cursor on the first pin (highlight only) but leave the map
	# centred — the camera follows the cursor once the player actually cycles.
	_select_table_pin(0, false)
	_go_to(View.TABLE)


# The pins a keyboard/gamepad cursor can land on: the unlocked ones, in rally order
# (the locked showdown pin is skipped — it's non-pickable until everything else is done).
func _unlocked_pins() -> Array:
	var out: Array = []
	for pin in _pins:
		if not bool(pin.get_meta("locked", false)):
			out.append(pin)
	return out


# Move the table cursor to the i-th unlocked pin (wrapping) and give it the hover-style
# selection highlight (all pins stay one size — see UITheme.mark_panel_focused). When
# `pan` is set, also slide the map so the pin sits under the camera (used when the
# player cycles); on first entry it's false so the map stays centred (the camera is
# placed by _go_to).
func _select_table_pin(i: int, pan := true) -> void:
	var pins := _unlocked_pins()
	if pins.is_empty():
		_table_pin_index = -1
		return
	_table_pin_index = wrapi(i, 0, pins.size())
	var selected: Node3D = pins[_table_pin_index]
	# Every pin stays the same size; the selected one is marked by the hover-style
	# highlight on its readout box (matching a hovered menu button) plus the camera
	# centring below — not by scaling it up, which made some rally boxes read larger.
	for pin in pins:
		var panel: PanelContainer = pin.get_meta("label_panel")
		UITheme.mark_panel_focused(panel, pin == selected)
	if not pan:
		return
	# Pan so the selected pin centres under the table camera's look point, clamped to
	# the map extents exactly like a finger-drag (see _pan_table).
	var cfg: GameConfig = Config.data
	var half: Vector2 = cfg.hq_map_plane_size
	_table_pan.x = clampf(selected.position.x - cfg.hq_table_cam_look.x, -half.x * 0.5, half.x * 0.5)
	_table_pan.z = clampf(selected.position.z - cfg.hq_table_cam_look.z, -half.y * 0.5, half.y * 0.5)
	if _view == View.TABLE:
		_move_camera_to(_station_xform(View.TABLE), false)


func _cycle_table_pin(step: int) -> void:
	if _table_pin_index < 0:
		_select_table_pin(0)
	else:
		_select_table_pin(_table_pin_index + step)


# Open the rally detail for the pin the cursor is on (the keyboard/gamepad equivalent
# of clicking it). A drag re-centres the cursor, so the index always tracks a real pin.
func _open_selected_pin() -> void:
	var pins := _unlocked_pins()
	if _table_pin_index >= 0 and _table_pin_index < pins.size():
		_on_rally_pin(String(pins[_table_pin_index].get_meta("rally_id")))


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
	var events: Array = rally.get("events", [])
	# Difficulty is a hidden tier (it drives reward value, not anything the player
	# sees) — the eligible-car requirement is the visible gate.
	var lines: Array[String] = [
		"Eligible cars: %s" % _restriction_text(rally.get("restriction", {})),
		"%d events — combined time sets your result." % events.size(),
	]
	# Per-event surface mix (gravel vs tarmac), one line each.
	for i in events.size():
		lines.append("  Event %d: %s" % [i + 1, _surface_mix_text(events[i])])
	lines.append(best_line)
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

# Enter the tuning bay: raise the selected car on the lift, frame it to one side, and
# show the HUB (car description + Change Car + Tuning/Upgrades buttons).
func _enter_lift() -> void:
	_ensure_lift_car()
	_lift_page = LiftPage.HUB
	_hub_focus = 1  # the cursor starts on Change Car each time we enter the bay
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


# Back out of the bay one level: a sub-menu page returns to the hub; the hub returns
# to the garage. (The hub's own Back-to-garage button goes straight to the garage.)
func _lift_back() -> void:
	if _lift_page == LiftPage.HUB:
		_go_to(View.GARAGE)
	else:
		_lift_hub()


# Open a sub-menu (TUNE / UPGRADES) as its own full-height page. These pages use
# native focus (sliders / install buttons), so drop the cursor onto the first control.
func _open_lift_page(page: int) -> void:
	_lift_page = page
	_refresh_lift_ui()
	var box: Control = _lift_tune_box if page == LiftPage.TUNE else _lift_upgrades_box
	_grab_first_focus.bind(box).call_deferred()


# Return from a sub-menu to the bay hub (restores the up/down hub cursor highlight).
# The hub navigates by hand (left/right cycles the car), so release the native focus
# the sub-page's sliders/buttons held.
func _lift_hub() -> void:
	_lift_page = LiftPage.HUB
	get_viewport().gui_release_focus()
	_refresh_lift_ui()


# Move the garage's left/right cursor between Back (0), Map (1), Tune Car (2) and
# Free Roam (3), wrapping at the ends, and repaint it.
func _move_garage_focus(step: int) -> void:
	_garage_focus = wrapi(_garage_focus + step, 0, 4)
	_refresh_garage_focus()


# Fire the garage action the cursor sits on: 0 backs out to the exterior, 1 opens the
# map table, 2 opens the tuning lift, 3 launches free roam.
func _activate_garage_focus() -> void:
	match _garage_focus:
		0: _go_to(View.EXTERIOR)
		1: _enter_table()
		2: _enter_lift()
		3: _enter_free_roam()


# Paint the manual garage cursor (a spatially-navigated 3D station, so the Back / Map /
# Tune Car / Free Roam buttons are highlighted by hand rather than via native focus).
func _refresh_garage_focus() -> void:
	if _garage_table_btn == null:
		return
	UITheme.mark_focused(_garage_back_btn, _garage_focus == 0)
	UITheme.mark_focused(_garage_table_btn, _garage_focus == 1)
	UITheme.mark_focused(_garage_lift_btn, _garage_focus == 2)
	UITheme.mark_focused(_garage_freeroam_btn, _garage_focus == 3)


# Move the HUB's left/right cursor between Back (0), Change Car (1), Tuning (2) and
# Upgrades (3), wrapping at the ends, and repaint it.
func _move_hub_focus(step: int) -> void:
	_hub_focus = wrapi(_hub_focus + step, 0, 4)
	_refresh_hub_focus()


# Fire the hub item the cursor sits on: 0 backs out to the garage, 1 opens the car park
# to change car, 2/3 open the Tuning / Upgrades pages.
func _activate_hub_focus() -> void:
	match _hub_focus:
		0: _go_to(View.GARAGE)
		1: _enter_change_car()
		2: _open_lift_page(LiftPage.TUNE)
		3: _open_lift_page(LiftPage.UPGRADES)


# Paint the manual hub cursor (the hub uses left/right + select, not native focus, so the
# Back / Change Car / Tuning / Upgrades buttons are highlighted by hand instead).
func _refresh_hub_focus() -> void:
	if _hub_tune_btn == null:
		return
	UITheme.mark_focused(_hub_back_btn, _hub_focus == 0)
	UITheme.mark_focused(_hub_change_btn, _hub_focus == 1)
	UITheme.mark_focused(_hub_tune_btn, _hub_focus == 2)
	UITheme.mark_focused(_hub_upgrades_btn, _hub_focus == 3)


# Grab focus on the first focusable, enabled, visible control under `root` — used to
# seat the cursor when a native-focus page (the tuning sliders / upgrade list) opens.
func _grab_first_focus(root: Node) -> void:
	for c in root.find_children("*", "Control", true, false):
		var ctrl := c as Control
		if ctrl.focus_mode != Control.FOCUS_NONE and ctrl.is_visible_in_tree() \
				and not (ctrl is BaseButton and (ctrl as BaseButton).disabled):
			ctrl.grab_focus()
			return


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
	var car := _car_scene_res().instantiate()
	add_child(car)
	# Isolated config so this parked/display car's apply_owned can't clobber the
	# player car's tuning in the shared global Config.data (see car.gd `config`).
	car.use_isolated_config()
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
	_add_synthetic_smoke(car)
	return car


# Refresh the whole menu for the current selected car: name + stats, which menu is
# shown, the sliders' gating/values, and the upgrades list.
func _refresh_lift_ui() -> void:
	# Recover a wrecked-out player before drawing the garage: a free Repair Kit when
	# every owned car is wrecked and none is held (also checked on save load). The
	# repair row calls out the free kit when it was just granted.
	_safety_net_granted = Save.ensure_repair_safety_net()
	_lift_owned = Save.selected_car()
	var entry := CarLibrary.by_id(String(_lift_owned.get("model_id", "")))
	var id := int(_lift_owned.get("instance_id", -1))
	_lift_car_label.text = "%s  #%d\n%s" % [
		EngineSwap.display_name(entry, _lift_owned), id, _car_stats_text(_lift_owned, entry)]
	# Show the hub (car selector + menu buttons) or a sub-menu page from _lift_page.
	# The car description hides while a sub-menu is open so the centred page has room.
	_lift_hub_controls.visible = _lift_page == LiftPage.HUB
	_lift_info_panel.visible = _lift_page == LiftPage.HUB
	_lift_menu_bg.visible = _lift_page != LiftPage.HUB
	_lift_tune_box.visible = _lift_page == LiftPage.TUNE
	_lift_upgrades_box.visible = _lift_page == LiftPage.UPGRADES
	_lift_menu_title.text = "TUNE" if _lift_page == LiftPage.TUNE else "UPGRADES"
	_refresh_sliders()
	_rebuild_upgrades_box()
	_refresh_hub_focus()  # keep the left/right hub cursor highlight in step
	_normalize_menus()  # re-apply house rules to the freshly-built upgrade rows


# The engine-detune slider's value label: the detune percent plus the car's LIVE
# power-to-weight at that setting (e.g. "80% - 0.20 HP/kg"), so the player sees the
# ratio each event is gated on move as they detune. effective_meta already folds in
# the (mirrored) detune, so this recomputes off the current setting.
func _detune_label_text(pct: int) -> String:
	var entry := CarLibrary.by_id(String(_lift_owned.get("model_id", "")))
	var pw := CarLibrary.power_to_weight(UpgradeLibrary.effective_meta(_lift_owned, entry)) * KW_TO_HP
	return "%d%% - %.2f HP/kg" % [pct, pw]


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
		if axis == "engine_detune":
			slider.set_value_no_signal(clampf(float(tuning.get("engine_detune", 1.0)), 0.0, 1.0) * 100.0)
			value.text = _detune_label_text(int(round(slider.value)))
		else:
			slider.set_value_no_signal(clampf(float(tuning.get(axis, 0.0)), -1.0, 1.0))
			if unlocked:
				value.text = "%+.2f" % slider.value
			else:
				value.text = "needs %s" % ("Big Brake Kit" if axis == "brake_bias" else "Aero Kit")


func _on_tune_slider_changed(value: float, axis: String) -> void:
	if _lift_owned.is_empty():
		return
	if axis == "engine_detune":
		var frac := clampf(value / 100.0, 0.0, 1.0)
		Save.set_engine_detune(int(_lift_owned.get("instance_id", -1)), frac)
		var tuning_d: Dictionary = _lift_owned.get("tuning", {})
		tuning_d["engine_detune"] = frac
		_lift_owned["tuning"] = tuning_d
		(_lift_slider_values[axis] as Label).text = _detune_label_text(int(round(value)))
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


# Rebuild the UPGRADES menu for the current car: one row per slot listing every
# applied part with an Enable/Disable toggle (at most one enabled per slot), an
# Apply button per matching unlocked item, plus the repair-kit action. Applying a
# part consumes it from the unlocked pool and fits it to this car for good
# (confirmed first); a fitted part can't be removed, only toggled off.
func _rebuild_upgrades_box() -> void:
	for c in _lift_upgrades_box.get_children():
		c.queue_free()
	var id := int(_lift_owned.get("instance_id", -1))
	var installed: Array = _lift_owned.get("installed_upgrades", [])
	var inventory: Dictionary = Save.profile.get("inventory", {})

	var heading := Label.new()
	heading.text = "Applied parts stay on this car for good — toggle them on or off below."
	heading.add_theme_font_size_override("font_size", 12)
	heading.modulate = Color(1, 1, 1, 0.8)
	heading.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lift_upgrades_box.add_child(heading)

	for slot in UpgradeLibrary.SLOTS:
		_lift_upgrades_box.add_child(_make_slot_row(slot, id, installed, inventory))

	# Repair kit + HP (the one consumable; heals working HP).
	_lift_upgrades_box.add_child(_make_repair_row(id, inventory))
	# Engine swap: current engine + a button into the car-park swap picker.
	_lift_upgrades_box.add_child(_make_engine_swap_row(id))


func _make_slot_row(slot: String, instance_id: int, installed: Array, inventory: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 2)

	# One line per part applied to this car in this slot — "SLOT: PART NAME" on the
	# left, a bare Enable/Disable toggle on the right of the SAME row. A DISABLED
	# part reads "— empty —" exactly like an unfilled slot (its effect is off, so
	# the slot is effectively empty), with the Enable button kept alongside to
	# bring it back. Enabling switches off any same-slot sibling. A slot with
	# nothing fitted at all is a single "— empty —" line with no button.
	var any_fitted := false
	for item_id in installed:
		if UpgradeLibrary.slot_of(item_id) != slot:
			continue
		any_fitted = true
		var enabled := UpgradeLibrary.is_enabled(_lift_owned, item_id)
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var name_label := Label.new()
		name_label.add_theme_font_size_override("font_size", 15)
		name_label.text = "%s: %s" % [slot.capitalize(),
			UpgradeLibrary.by_id(item_id).get("name", item_id) if enabled else "— empty —"]
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_label)
		var toggle := Button.new()
		toggle.text = "Disable" if enabled else "Enable"
		toggle.focus_mode = Control.FOCUS_ALL
		toggle.pressed.connect(_toggle_upgrade.bind(instance_id, item_id, not enabled))
		row.add_child(toggle)
		box.add_child(row)
	if not any_fitted:
		var empty := Label.new()
		empty.add_theme_font_size_override("font_size", 15)
		empty.text = "%s: — empty —" % slot.capitalize()
		box.add_child(empty)

	# An Apply button for each unlocked (not-yet-applied) item that fits this slot.
	for item_id in inventory:
		if UpgradeLibrary.slot_of(item_id) != slot or installed.has(item_id):
			continue
		var count := int(inventory[item_id])
		if count <= 0:
			continue
		var apply := Button.new()
		apply.text = "Apply %s  (x%d)" % [UpgradeLibrary.by_id(item_id).get("name", item_id), count]
		apply.focus_mode = Control.FOCUS_ALL
		apply.pressed.connect(_install_upgrade.bind(instance_id, item_id))
		box.add_child(apply)
	return box


func _make_repair_row(instance_id: int, inventory: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	var kits := int(inventory.get(UpgradeLibrary.REPAIR_KIT_ID, 0))
	var entry := CarLibrary.by_id(String(_lift_owned.get("model_id", "")))
	var label := Label.new()
	label.add_theme_font_size_override("font_size", 15)
	# Health as a percentage (a raw HP number reads as horsepower). A wrecked car (0%)
	# is called out — it can't enter a rally until repaired.
	var max_hp := float(entry.get("max_hp", 0.0))
	var hp := float(_lift_owned.get("hp", 0.0))
	var pct := roundi(clampf(hp / max_hp, 0.0, 1.0) * 100.0) if max_hp > 0.0 else 0
	var wrecked := Save.car_is_wrecked(_lift_owned)
	var health_text := "WRECKED — too damaged to race" if wrecked else "Health: %d%%" % pct
	label.text = "%s   —   Repair Kits: x%d" % [health_text, kits]
	box.add_child(label)
	# When the safety net just topped up a stranded player, say so on the row.
	if _safety_net_granted:
		var net_note := Label.new()
		net_note.text = "All your cars were wrecked — a free Repair Kit was provided."
		net_note.add_theme_font_size_override("font_size", 12)
		net_note.modulate = Color(0.6, 1, 0.7)
		net_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(net_note)
	# A Repair Kit fully restores the car. Offer it whenever the car isn't already at
	# full health and a kit is owned; flag the missing-kit case for a wrecked car.
	if hp < max_hp:
		if kits > 0:
			var repair := Button.new()
			repair.text = "Use Repair Kit (restore to full health)"
			repair.focus_mode = Control.FOCUS_ALL
			repair.pressed.connect(_use_repair_kit.bind(instance_id))
			box.add_child(repair)
		elif wrecked:
			var note := Label.new()
			note.text = "No Repair Kits — win one to bring this car back."
			note.add_theme_font_size_override("font_size", 12)
			note.modulate = Color(1, 0.7, 0.5)
			box.add_child(note)
	return box


# The engine-swap row on the upgrades page: current engine label + a Swap button
# that opens the car park in swap mode. Gated on the car being at 100% HP (both
# cars must be full to swap). See features/engine-swap.md.
func _make_engine_swap_row(instance_id: int) -> HBoxContainer:
	var owned := Save.get_car(instance_id)
	var entry := CarLibrary.by_id(String(owned.get("model_id", "")))
	var current := EngineSwap.current_engine_id(owned, String(entry.get("engine", "")))
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = "Engine: %s" % EngineLibrary.by_id(current).get("name", current)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var button := Button.new()
	button.text = "Swap Engine"
	button.focus_mode = Control.FOCUS_ALL
	var full_hp: bool = EngineSwap.can_swap(owned, owned)  # true iff this car is at max HP
	var has_target := not _swap_targets(instance_id).is_empty()
	button.disabled = not (full_hp and has_target)
	if not full_hp:
		button.tooltip_text = "This car must be at 100% health to swap engines"
	elif not has_target:
		button.tooltip_text = "No other 100%-health car to swap with"
	button.pressed.connect(_enter_engine_swap)
	row.add_child(button)
	return row


# The owned cars this car can swap engines with: every OTHER owned car that (with
# this one) passes EngineSwap.can_swap — i.e. both at 100% HP. Shared by the swap-row
# gating and the car-park swap lineup so they never disagree.
func _swap_targets(current_id: int) -> Array:
	var current_owned := Save.get_car(current_id)
	var targets: Array = []
	if current_owned.is_empty():
		return targets
	for car in Save.profile.get("cars", []):
		if int(car.get("instance_id", -1)) == current_id:
			continue
		if EngineSwap.can_swap(current_owned, car):
			targets.append(car)
	return targets


# Applying a part is irreversible (it's consumed from the unlocked pool and stays
# on this car for good), so ASK first. The actual fit happens in _apply_upgrade
# once the player accepts the dialog.
func _install_upgrade(instance_id: int, item_id: String) -> void:
	var item_name: String = UpgradeLibrary.by_id(item_id).get("name", item_id)
	_pending_install = {"instance_id": instance_id, "item_id": item_id}
	_confirm_dialog.dialog_text = (
		"Apply %s to this car?\n\nThe part stays on this car for good — it can be toggled on/off but never moved to another car or recovered, even if the car is wrecked."
		% item_name)
	_confirm_dialog.popup_centered()


# Accept handler for the fit-confirmation dialog: apply the queued install.
func _on_install_confirmed() -> void:
	if _pending_install.is_empty():
		return
	var instance_id := int(_pending_install["instance_id"])
	var item_id := String(_pending_install["item_id"])
	_pending_install = {}
	_apply_upgrade(instance_id, item_id)


# Actually fit the part (consuming it from inventory) and rebuild the lift + UI.
func _apply_upgrade(instance_id: int, item_id: String) -> void:
	if Save.install_upgrade(instance_id, item_id):
		_lift_car_instance_id = -2  # the car's spec changed — rebuild the prop
		_ensure_lift_car()
		_refresh_lift_ui()


# Toggle an applied part on/off (free, instant, reversible — no confirm needed)
# and rebuild the lift prop + UI so the spec change shows immediately.
func _toggle_upgrade(instance_id: int, item_id: String, enabled: bool) -> void:
	if Save.set_upgrade_enabled(instance_id, item_id, enabled):
		_lift_car_instance_id = -2  # the car's spec changed — rebuild the prop
		_ensure_lift_car()
		_refresh_lift_ui()


func _use_repair_kit(instance_id: int) -> void:
	if Save.use_repair_kit(instance_id):
		_refresh_lift_ui()


# Enter the car park for the chosen rally: park only the ELIGIBLE owned cars and
# frame the first. With none eligible, show a hint + disable Start.
func _enter_car_screen() -> void:
	_carpark_change_mode = false
	_carpark_freeroam_mode = false
	_start_button.text = "Start Rally"
	_build_eligible_lineup()
	var rally := RallyLibrary.by_id(_selected_rally_id)
	var done := Save.rally_completed(_selected_rally_id)
	_rally_banner.text = "%s%s — needs %s" % [
		rally.get("name", "?"), "  (done)" if done else "",
		_restriction_text(rally.get("restriction", {}))]
	_view = View.CARPARK
	_detail_open = false
	_update_overlays()
	if _eligible.is_empty():
		_no_eligible_label.visible = true
		_no_eligible_label.text = "No eligible car for this rally — win or pick a qualifying car."
		_car_name_label.text = ""
		_car_stats_label.text = ""
		_car_warning_label.visible = false
		_car_repair_button.visible = false
		_start_button.disabled = true
		_move_camera_to(_station_xform(View.CARPARK), true)
		return
	_no_eligible_label.visible = false
	_focus = 0
	_focus_changed(true)  # snaps the camera onto the first car


# Enter the car park from the tuning lift to pick a new car for the lift: park the
# WHOLE owned collection and frame the car currently on the lift. Select swaps the
# raised car; Back returns to the bay (see _on_start_pressed / _car_back).
func _enter_change_car() -> void:
	_carpark_change_mode = true
	_carpark_freeroam_mode = false
	_build_lineup(Save.profile.get("cars", []).duplicate())
	_rally_banner.text = "Change car"
	_no_eligible_label.visible = false
	_start_button.text = "Select Car"
	_view = View.CARPARK
	_detail_open = false
	_update_overlays()
	# Frame the car already on the lift (the selected car), defaulting to the first.
	_focus = 0
	var sel := Save.selected_instance_id()
	for i in _eligible.size():
		if int(_eligible[i].get("instance_id", -1)) == sel:
			_focus = i
			break
	_focus_changed(true)


func _car_back() -> void:
	_clear_lineup()
	_selected_instance_id = -1
	if _carpark_starter_mode:
		_carpark_starter_mode = false
		_go_to(View.EXTERIOR)
	elif _carpark_freeroam_mode:
		_carpark_freeroam_mode = false
		_go_to(View.GARAGE)
	elif _carpark_swap_mode:
		_carpark_swap_mode = false
		_enter_lift()
	elif _carpark_change_mode:
		_carpark_change_mode = false
		_enter_lift()
	else:
		_go_to(View.TABLE)


# Open the car park to pick an engine-swap partner: all OTHER owned cars at full
# health (the current car is excluded — you can't swap with yourself). Confirming a
# target exchanges engines via Save.swap_engines. See features/engine-swap.md.
func _enter_engine_swap() -> void:
	_carpark_swap_mode = true
	_carpark_change_mode = false
	_carpark_starter_mode = false
	_carpark_freeroam_mode = false
	_selected_instance_id = -1  # no partner chosen yet; guards _select_swap_target
	var current_id := Save.selected_instance_id()
	var targets := _swap_targets(current_id)
	_build_lineup(targets)
	_rally_banner.text = "Engine swap"
	_no_eligible_label.visible = false
	_start_button.text = "Swap Engine"
	_view = View.CARPARK
	_detail_open = false
	_update_overlays()
	_focus = 0
	_focus_changed(true)


# First-run starter picker: park one PREVIEW car per STARTER_MODEL_IDS (not owned
# cars — the garage is empty) and let the player choose. Select grants that model as
# the player's first car (see _confirm_starter); Back returns to the title.
func _enter_starter_pick() -> void:
	_carpark_starter_mode = true
	_carpark_change_mode = false
	_carpark_freeroam_mode = false
	var previews: Array = []
	var idx := -1
	for id in STARTER_MODEL_IDS:
		var entry := CarLibrary.by_id(id)
		if entry.is_empty():
			continue
		previews.append({
			"instance_id": idx,  # negative: a preview, not an owned car
			"model_id": id,
			"hp": float(entry.get("max_hp", 1000.0)),
			"installed_upgrades": [],
			"tuning": {},
		})
		idx -= 1
	_build_lineup(previews)
	_rally_banner.text = "Choose your starter car"
	_no_eligible_label.visible = false
	_start_button.text = "Choose This Car"
	_start_button.disabled = false
	_view = View.CARPARK
	_detail_open = false
	_update_overlays()
	_focus = 0
	_focus_changed(true)


# Commit the focused preview as the player's first car: grant it, record the choice,
# select it, then enter the garage.
func _confirm_starter() -> void:
	if _eligible.is_empty():
		return
	var model_id := String(_eligible[_focus].get("model_id", ""))
	if model_id == "":
		return
	var car := Save.grant_car(model_id)
	Save.profile["starter_picked"] = true
	Save.profile["starter_model_id"] = model_id
	Save.set_selected_car(int(car.get("instance_id", -1)))
	Save.save()
	_clear_lineup()
	_selected_instance_id = -1
	_carpark_starter_mode = false
	_go_to(View.GARAGE)


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
		var meta := UpgradeLibrary.effective_meta(car, CarLibrary.by_id(String(car.get("model_id", ""))))
		if RallyLibrary.is_eligible(rally, meta):
			eligible.append(car)
	_build_lineup(eligible)


# Park ALL owned cars for the title screen, so the player's whole collection is on
# show in the car park behind the title overlay (rebuilt on entering EXTERIOR).
func _build_title_lineup() -> void:
	_build_lineup(Save.profile.get("cars", []).duplicate())


# Park the given owned cars in the painted bays, laid out as a centred row ALONG X at
# the car-park lot (GameConfig.hq_carpark_origin / menu_car_spacing), each car parked
# nose-out toward the courtyard / menu camera (+Z) so the front-3/4 framing shows its
# face with the garage behind it. Fewer cars than bays are centred within the grid so
# they stay over real bays. The cars drop in live and settle onto their suspension,
# then freeze (see _freeze_lineup). Shared by the rally car-select lineup (eligible
# cars) and the title screen (all owned cars).
func _build_lineup(cars: Array) -> void:
	_clear_lineup()  # bumps _settle_generation, cancelling any in-flight spawn/freeze
	_eligible = cars
	var cfg: GameConfig = Config.data
	var n := cars.size()
	var bays: int = max(1, cfg.max_owned_cars)
	var center := _carpark_center()
	# Lay out ALL the lot markers up front (cheap Marker3Ds): the camera framing and the
	# focus cursor key off _markers / _eligible, so they work immediately even while the
	# heavy car props are still streaming in below.
	# Centre the occupied bays within the lot (clamped so an over-cap overflow lineup,
	# which can briefly exceed the bay count, still starts at the first bay).
	var start: int = max(0, floori((bays - n) / 2.0))
	for i in n:
		var marker := Marker3D.new()
		marker.position = Vector3(_bay_center_x(start + i, bays), 0.0, center.z)
		# Nose toward +Z (the courtyard / camera), so the menu camera sits in front.
		marker.rotation.y = PI
		add_child(marker)
		_markers.append(marker)
	# Spawn the heavy car props ONE PER FRAME instead of all at once. Each car is a full
	# physics scene (chassis + wheels + drivetrain + mesh duplication), so building the
	# whole lineup in a single frame hitches; spreading it out keeps each frame cheap and
	# lets a car that takes longer than one frame to instance spill into its own frame
	# without piling onto the others. Guarded by _settle_generation so a rebuild (or a
	# back-out) abandons a half-spawned lineup cleanly.
	_spawn_lineup_progressive(cars, _settle_generation)


# Stream the parked car props in across frames (see _build_lineup), then let them
# settle and freeze. Bails the moment a newer lineup supersedes this one.
func _spawn_lineup_progressive(cars: Array, generation: int) -> void:
	for i in cars.size():
		if generation != _settle_generation:
			return  # a rebuild / back-out replaced this lineup mid-stream
		_cars.append(_spawn_parked_car(cars[i], _markers[i]))
		await get_tree().process_frame
	if generation != _settle_generation:
		return
	emit_signal("lineup_built")
	# Let the lineup settle under physics for a moment, then freeze the settled pose.
	await get_tree().create_timer(Config.data.menu_car_settle_seconds).timeout
	_freeze_lineup(generation)


# Spawn one owned car as a live, silent car prop at a marker (raised by
# menu_car_drop_height so it drops onto its suspension), with its OWN mesh copies
# (see _dup_meshes) so a mixed lineup shows each at its true size. It runs physics
# until _freeze_lineup locks the settled pose.
func _spawn_parked_car(owned: Dictionary, marker: Marker3D) -> Node3D:
	var car := _car_scene_res().instantiate()
	add_child(car)
	# Isolated config so this parked/display car's apply_owned can't clobber the
	# player car's tuning in the shared global Config.data (see car.gd `config`).
	car.use_isolated_config()
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
	_add_synthetic_smoke(car)
	return car


# Give a damaged display car (car park / lift) its own synthetic engine smoke — the
# frozen prop's engine never runs, so EngineSmoke self-times puffs from the car's
# damage severity instead of misfire cutouts. Parented to the CAR (so it's freed with
# it) but top_level (world-space render, ignoring the car transform, like the event
# pool at the scene root) and PROCESS_MODE_ALWAYS (keeps puffing though the car is
# frozen / process-disabled). Skipped for a healthy car (severity 0 = no smoke).
func _add_synthetic_smoke(car: Node) -> void:
	if not Config.data.engine_smoke_enabled:
		return
	if car.get("damage") == null or car.damage.misfire_level(Config.data) <= 0.0:
		return
	var smoke := EngineSmoke.new()
	car.add_child(smoke)
	# Emits in the car's LOCAL space (see EngineSmoke._puff), so it renders at the
	# bonnet relative to the car — no top_level. PROCESS_MODE_ALWAYS keeps it puffing
	# even though the display car is frozen / process-disabled once settled.
	smoke.process_mode = Node.PROCESS_MODE_ALWAYS
	smoke.setup_synthetic(car)


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


# Pan the focus to the prev/next eligible car (wrapping). Keyed off _eligible (set
# up front), so panning works even while the car props are still streaming in.
func _cycle_focus(step: int) -> void:
	if _eligible.is_empty():
		return
	_focus = wrapi(_focus + step, 0, _eligible.size())
	_focus_changed()


# React to a focus change: make the focused car the selected car, re-aim the camera
# + stats panel at it. No respawn — every eligible car is already parked.
func _focus_changed(snap := false) -> void:
	if _eligible.is_empty():
		return
	var owned: Dictionary = _eligible[_focus]
	_selected_instance_id = int(owned.get("instance_id", -1))
	var entry := CarLibrary.by_id(String(owned.get("model_id", "")))
	var stats := _car_stats_text(owned, entry)
	# The same lineup + focus machinery drives both the rally car-select (CARPARK)
	# and the scrap prompt (OVERFLOW); update whichever overlay is up.
	if _view == View.OVERFLOW:
		_refresh_overflow_ui(owned, entry, stats)
	else:
		var display_owned: Dictionary = Save.get_car(_selected_instance_id)
		var display_name: String = (EngineSwap.display_name(entry, display_owned)
			if not display_owned.is_empty() else String(entry.get("name", owned.get("model_id", "?"))))
		_car_name_label.text = "%s  #%d  (%d of %d)" % [
			display_name, _selected_instance_id, _focus + 1, _eligible.size()]
		_car_stats_label.text = stats
		# A wrecked focused car gates Start + offers a Repair (full restore).
		_refresh_focus_damage(owned)
	_normalize_menus()  # keep house rules on the just-updated car name / stats
	_move_camera_to(_camera_target_xform(), snap)


# A wrecked focused car can't be entered: disable Start and explain why, offering a
# Repair (full restore) when a kit is owned. A healthy car clears all of this.
func _refresh_focus_damage(owned: Dictionary) -> void:
	# Change-car mode just swaps the car on the lift, so a wrecked car is still a valid
	# pick (it can be repaired in the bay). Never gate Select on damage there.
	if _carpark_change_mode:
		_start_button.disabled = false
		_car_warning_label.visible = false
		_car_repair_button.visible = false
		return
	if not Save.car_is_wrecked(owned):
		_start_button.disabled = false
		_car_warning_label.visible = false
		_car_repair_button.visible = false
		return
	_start_button.disabled = true
	_car_warning_label.visible = true
	var kits := int(Save.profile.get("inventory", {}).get(UpgradeLibrary.REPAIR_KIT_ID, 0))
	if kits > 0:
		_car_warning_label.text = "Too damaged to enter. Use a Repair Kit to restore it to full health and race."
		_car_repair_button.visible = true
		_car_repair_button.text = "Repair (1 kit)"
	else:
		_car_warning_label.text = "Too damaged to enter — and you have no Repair Kits. Win one, or pick another car."
		_car_repair_button.visible = false


# Spend a Repair Kit on the focused (wrecked) car: full restore, then re-evaluate so
# Start unlocks and the stats refresh. The owned dict is shared with the save, so the
# restored HP flows straight back into the lineup.
func _repair_focused_car() -> void:
	if _eligible.is_empty():
		return
	var id := int(_eligible[_focus].get("instance_id", -1))
	if Save.use_repair_kit(id):
		_focus_changed()


# One-line car summary shown in the car-select / overflow overlays. Health reads as a
# percentage (a raw HP number is misleading — it can read as horsepower); a wrecked
# (0 HP) car is flagged so the lineup makes clear why it can't be entered.
func _car_stats_text(owned: Dictionary, entry: Dictionary) -> String:
	var max_hp := float(entry.get("max_hp", 0.0))
	var hp := float(owned.get("hp", 0.0))
	var hp_text: String
	if max_hp > 0.0 and hp <= 0.0:
		hp_text = "WRECKED"
	else:
		hp_text = "Health %d%%" % roundi(clampf(hp / max_hp, 0.0, 1.0) * 100.0) if max_hp > 0.0 else "Health ?"
	var meta := UpgradeLibrary.effective_meta(owned, entry)
	return "%s | %.2f G | %.2f HP/kg | %s" % [
		_drive_text(int(entry.get("drive_mode", -1))),
		CarLibrary.max_lateral_g(meta, Config.data),
		CarLibrary.power_to_weight(meta) * KW_TO_HP,
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
	# A min+max pair reads as a single range ("power-to-weight 0.23-0.32"); a lone
	# floor or ceiling keeps its >= / <= form.
	if restriction.has("pw_min") and restriction.has("pw_max"):
		parts.append("power-to-weight %.2f-%.2f" % [float(restriction["pw_min"]), float(restriction["pw_max"])])
	elif restriction.has("pw_min"):
		parts.append("power-to-weight >= %.2f" % float(restriction["pw_min"]))
	elif restriction.has("pw_max"):
		parts.append("power-to-weight <= %.2f" % float(restriction["pw_max"]))
	return ", ".join(parts)


# Human-readable gravel/tarmac surface mix for one rally event. Full-one-surface
# events read as just "all gravel" / "all tarmac"; mixed events show both shares.
func _surface_mix_text(event: Dictionary) -> String:
	var tarmac := RallyLibrary.event_tarmac_fraction(event)
	if tarmac <= 0.0:
		return "all gravel"
	if tarmac >= 1.0:
		return "all tarmac"
	var tarmac_pct := int(round(tarmac * 100.0))
	return "%d%% gravel / %d%% tarmac" % [100 - tarmac_pct, tarmac_pct]


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
		View.OVERFLOW: return _camera_target_xform()
		# Title shot: shift by the lineup's off-centre offset so it stays framed at the
		# same angle (a pure X translation of eye + look keeps the view direction).
		_: return _look_xform(
			cfg.hq_exterior_cam_eye + Vector3(cfg.menu_car_park_offset, 0.0, 0.0),
			cfg.hq_exterior_cam_look + Vector3(cfg.menu_car_park_offset, 0.0, 0.0))


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
	# On first run the same action COMMITS the focused preview as the player's first car.
	if _carpark_starter_mode:
		_confirm_starter()
		return
	# In engine-swap mode the same action exchanges engines with the focused car.
	if _carpark_swap_mode:
		_select_swap_target()
		return
	# In change-car mode the same action SELECTS the focused car for the lift and
	# returns to the bay, rather than launching a rally.
	if _carpark_change_mode:
		_select_changed_car()
		return
	# In free-roam mode the same action launches free roam with the focused car.
	if _carpark_freeroam_mode:
		await _start_free_roam()
		return
	var owned := Save.get_car(_selected_instance_id)
	var rally := RallyLibrary.by_id(_selected_rally_id)
	if owned.is_empty() or rally.is_empty():
		return
	# On mobile, the player must choose a touch control scheme before their first
	# event. If they haven't picked one yet, show the picker as a gate now; once they
	# confirm it's saved and we never ask again (see _on_settings_action).
	if _is_mobile() and Save.get_setting(MobileControls.SETTING_KEY, null) == null:
		_open_settings(true)
		return
	await _begin_rally_start()


# Commit the focused car as the new selected car (the one raised on the lift) and
# return to the tuning bay. Any owned car is selectable here — even a wrecked one can
# sit on the lift to be repaired / tuned.
func _select_changed_car() -> void:
	if _selected_instance_id >= 0:
		Save.set_selected_car(_selected_instance_id)
	_clear_lineup()
	_selected_instance_id = -1
	_carpark_change_mode = false
	_lift_car_instance_id = -2  # force the lift to respawn the newly-selected car
	_enter_lift()


# Confirm the highlighted car as the engine-swap partner: exchange engines, then
# respawn the lift prop with its new engine and return to the upgrades page.
func _select_swap_target() -> void:
	var current_id := Save.selected_instance_id()
	if _selected_instance_id >= 0:
		Save.swap_engines(current_id, _selected_instance_id)
	_clear_lineup()
	_selected_instance_id = -1
	_carpark_swap_mode = false
	_lift_car_instance_id = -2  # force prop respawn with the new engine
	_ensure_lift_car()
	_enter_lift()


# True on a touch device (or when the controls are force-enabled for testing) — the
# only case the mobile control-scheme picker is relevant.
func _is_mobile() -> bool:
	return DisplayServer.is_touchscreen_available() or Config.data.mobile_controls_force


# The actual handoff to RallySession, covered by a loading screen. Split out of
# _on_start_pressed so the mobile control-scheme gate can call it after the pick.
func _begin_rally_start() -> void:
	var owned := Save.get_car(_selected_instance_id)
	var rally := RallyLibrary.by_id(_selected_rally_id)
	if owned.is_empty() or rally.is_empty():
		return
	# Fielding a car also selects it, so the tuning lift shows the car the player
	# last raced when they return to the garage.
	Save.set_selected_car(_selected_instance_id)
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
	# Any first tap/click on the web build is a valid gesture to go fullscreen.
	if (event is InputEventScreenTouch and event.pressed) or _is_click(event):
		_maybe_enter_web_fullscreen()
	match _view:
		View.EXTERIOR:
			# The title is a flat two-button menu (Start / Settings) driven by native
			# focus — ui_accept fires whichever button is focused (see _build_title_overlay).
			# Don't hard-route menu_select to Start here, or pressing accept on Settings
			# would fire Start instead.
			pass
		View.SETTINGS:
			if event.is_action_pressed("menu_back"):
				# A sub-page backs out to the category list first (handled by the shared
				# menu); from the list, cancel the pre-rally gate back to the car park,
				# otherwise back to the title.
				if not _settings_menu.go_back():
					_go_to(View.CARPARK if _settings_gate else View.EXTERIOR)
					_settings_gate = false
		View.GARAGE:
			# The bottom action row (Back / Map / Tune Car / Free Roam) is a single
			# left/right cursor; select fires it. menu_back shortcuts to the exterior.
			if event.is_action_pressed("menu_left"):
				_move_garage_focus(-1)
			elif event.is_action_pressed("menu_right"):
				_move_garage_focus(1)
			elif event.is_action_pressed("menu_select"):
				_activate_garage_focus()
			elif event.is_action_pressed("menu_back"):
				_go_to(View.EXTERIOR)
		View.LIFT:
			if _lift_page == LiftPage.HUB:
				# Hub: left/right move the cursor between Back / Change Car / Tuning /
				# Upgrades; select fires it; menu_back is a shortcut to the garage.
				if event.is_action_pressed("menu_left"):
					_move_hub_focus(-1)
				elif event.is_action_pressed("menu_right"):
					_move_hub_focus(1)
				elif event.is_action_pressed("menu_select"):
					_activate_hub_focus()
				elif event.is_action_pressed("menu_back"):
					_go_to(View.GARAGE)
			elif event.is_action_pressed("menu_back"):
				_lift_hub()  # a sub-menu page backs out to the hub (its controls use
				# native focus for up/down/left-right/select)
		View.TABLE:
			if _detail_open:
				if event.is_action_pressed("menu_select"):
					_enter_car_screen()
				elif event.is_action_pressed("menu_back"):
					_hide_detail()
			elif event.is_action_pressed("menu_back"):
				_go_to(View.GARAGE)
			elif event.is_action_pressed("menu_left") or event.is_action_pressed("menu_up"):
				_cycle_table_pin(-1)
			elif event.is_action_pressed("menu_right") or event.is_action_pressed("menu_down"):
				_cycle_table_pin(1)
			elif event.is_action_pressed("menu_select"):
				_open_selected_pin()
			else:
				_table_pan_input(event)
		View.CARPARK:
			_cars_input(event)
		View.OVERFLOW:
			# Pan the lineup and scrap the focused car. No "back" — the player can't
			# leave the prompt until the garage is back under the cap.
			if event.is_action_pressed("menu_left"):
				_cycle_focus(-1)
			elif event.is_action_pressed("menu_right"):
				_cycle_focus(1)
			elif event.is_action_pressed("menu_select") and not _scrap_button.disabled:
				_on_scrap_pressed()


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
