extends Node3D
# HQ — the meta-game hub (todo/menus.md location 1), now a DIEGETIC 3D space the
# camera flies through (todo/diegetic-hq.md) instead of flat overlay screens. One
# world; the camera moves between "stations":
#   * EXTERIOR — the boot/title shot: block buildings + the outdoor car park, with
#     Start / Free Roam / Settings buttons. Start flies the camera into the garage;
#     Free Roam opens the car park to pick a car and drive session-lessly.
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
const KW_KG_TO_HP_TONNE := CarLibrary.KW_KG_TO_HP_TONNE  # single source of truth for the kW/kg -> hp/tonne display conversion

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
# The itch.io page hosting the Android APK — where the mobile-web boot notice sends
# players for the (much faster) native build.
const ANDROID_APP_URL := "https://felixxwu.itch.io/tappa"
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

# Car-park lineup pointer state: a horizontal drag (mouse, or finger via
# emulate_mouse_from_touch) swipes the focus to the prev/next car; a short press
# that never turned into a drag is a TAP, which raycast-picks the parked car under
# the pointer and focuses it directly (see _lineup_pointer_input).
var _lineup_pressing := false
var _lineup_drag_accum := Vector2.ZERO

# Car-park state: the owned cars eligible for the chosen rally, the parked car nodes
# + their lot markers (parallel to _eligible), and which slot is focused.
var _eligible: Array = []
# instance_id -> the engine-detune fraction that would qualify an over-powered parked
# car for the chosen rally (RallyLibrary.qualifying_detune). Populated only by the
# rally car-select lineup (_build_eligible_lineup); for these cars Start becomes an
# explicit "agree to detune" action (see _show_detune_confirm / _on_start_pressed).
var _detune_needed: Dictionary = {}
var _drivetrain_needed: Dictionary = {}
# Confirm popup shown when Start is pressed on an over-powered car: the car looks
# eligible in the park; this dialog carries the doesn't-qualify warning and the
# "Detune to N% & Start" agreement (_show_detune_confirm). Built lazily.
var _detune_dialog: ConfirmationDialog
# Confirm popup shown when a chosen engine-swap partner would need a Repair Kit (the
# lift car and/or the partner isn't at 100% HP). Carries the kit cost, or the "not
# enough kits" block. Built lazily. _pending_swap holds the two instance ids awaiting
# the OK press.
var _swap_repair_dialog: ConfirmationDialog
var _pending_swap: Dictionary = {}
var _cars: Array = []
var _markers: Array = []
# Reuse cache for parked lineup cars, shared by every lineup (rally car-select,
# title, overflow) since they all build from the same owned cars. Keyed by the
# owned car's instance_id -> {"hash": int, "node": Node3D}; the hash is the deep
# Variant hash of the owned dict, so a car whose tuning / damage / engine changed
# gets a fresh respawn while unchanged cars are reused as-is (see _build_lineup /
# _release_lineup). Cars are hidden + detached (not freed) between lineups and
# freed with the HQ node on exit-to-race.
var _car_cache: Dictionary = {}
var _focus := 0
# Bumped each time a lineup is (re)built so an in-flight progressive spawn for an old
# lineup stops adding cars when it resumes (see _spawn_lineup_progressive).
var _settle_generation := 0

# Tuning-lift state: the selected car raised on the lift (a Car prop, separate from
# the car-park lineup), which OwnedCar it is, and which menu (TUNE / UPGRADES) is up.
var _lift_car: Node3D
var _lift_owned: Dictionary = {}
# Garage station "Repair" button (the row's 4th action, where Free Roam used to be):
# repairs the SELECTED car with one Repair Kit. Its label reflects state — "Repair
# (x kit)" when the car is damaged and a kit is owned, "Repair — full health" / "Repair
# — no kits" otherwise — recomputed on garage entry (_refresh_garage_repair_button).
var _garage_repair_button: Button
var _lift_car_instance_id := -2  # what _lift_car was built for (-2 = nothing yet)
# Deep hash of the owned dict _lift_car was built from. _ensure_lift_car reuses the
# prop only when BOTH the instance id and this hash match, so any in-place data change
# (repair, upgrade toggle, engine swap) auto-invalidates the prop — no mutator has to
# remember to force a respawn. Mirrors the car park's _obtain_parked_car / _car_cache.
var _lift_car_hash := 0
var _lift_page: int = LiftPage.HUB
# Lift animation: the car is LOWERED on the ground in the garage view and RAISED when
# the bay is entered (tweened over hq_lift_raise_time). _lift_raised is the current
# target pose; _lift_tween animates the car's height toward it.
var _lift_raised := false
var _lift_tween: Tween

# 3D staging. The STATIC world (sky, grass, buildings, trees, garage, car-park
# surface, map table, lift) is built by HQEnvironment; hq keeps the handles it drives.
var _env: HQEnvironment
var _camera: Camera3D
var _cam_tween: Tween
var _map_table: MapTable        # the wooden table model the map plane sits on
var _pins_root: Node3D          # parent of the rally pins
var _pins: Array = []           # the pin Node3Ds (each carries a "rally_id" meta)
var _table_pin_index := -1      # keyboard/gamepad cursor into _unlocked_pins() (-1 = none)

# Overlays (one CanvasLayer per station; only the active one is visible).
var _title_layer: CanvasLayer
var _android_notice_layer: CanvasLayer  # web-on-Android boot notice; null once dismissed
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
var _swap_preview_label: RichTextLabel
var _start_button: Button
var _title_start_button: Button  # EXTERIOR title Start — default keyboard/gamepad focus
var _title_free_roam_button: Button  # EXTERIOR title Free Roam (between Start and Settings)
var _title_settings_button: Button  # EXTERIOR title Settings (below Start)
var _title_version_label: Label  # EXTERIOR title build-version readout (bottom-right)
var _no_eligible_label: Label
# Car-park damage UI: a "too damaged" note + a Repair action for a wrecked focused car.
var _car_warning_label: Label
var _car_repair_button: Button

# Garage overlay cursor: a single left/right cursor over the bottom action row
# (Back / Map / Tune Car / Free Roam). Buttons are FOCUS_NONE and highlighted by hand
# (a ButtonCursor, like the tuning hub) since the garage is a spatially-navigated 3D
# station, not a focus graph. hq keeps the index (_garage_focus, read by tests); the
# ButtonCursor owns the shared wrap/paint/fire behaviour (scripts/button_cursor.gd).
var _garage_cursor := ButtonCursor.new()
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
# The HUB's Back / Change Car / Tuning / Upgrades row is a left/right ButtonCursor, same
# as the garage: hq keeps the index (_hub_focus, read by tests), the cursor the behaviour.
var _hub_cursor := ButtonCursor.new()
var _hub_focus := 1             # which hub item the cursor sits on (0 = Back, 1 = Change Car, 2 = Tune, 3 = Upgrades)
var _lift_menu_bg: ColorRect    # the right-side panel that backs a sub-menu (TUNE/UPGRADES)
var _lift_menu_title: Label     # the sub-menu page heading ("TUNE" / "UPGRADES")
var _lift_back_button: Button   # the shared "< Back" on a sub-menu page (TUNE/UPGRADES)
var _tune_panel: TuningPanel         # the TUNE menu (sliders) — shared with the start line
var _lift_upgrades_box: VBoxContainer  # the UPGRADES menu (install / repair)


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
	_env = HQEnvironment.new()
	# The pickable table / lift areas route their clicks back to hq's own handlers.
	_env.build(self, _on_table_input, _on_lift_input)
	_camera = _env.camera
	_map_table = _env.map_table
	_pins_root = _env.pins_root
	_build_title_overlay()
	_build_garage_overlay()
	_build_table_overlay()
	_build_detail_overlay()
	_build_lift_overlay()
	_build_car_overlay()
	_build_settings_overlay()
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
	# Playing the WEB build in an Android browser: point the player at the itch.io
	# APK once per boot — the native build performs far better than mobile web.
	# Only over the title shot (a normal boot); never over the overflow gate.
	if _should_show_android_app_notice() and _view == View.EXTERIOR:
		_show_android_app_notice()


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


# --- 3D world (built by HQEnvironment) ---------------------------------------

# World X of the centre of bay `i` (0 = left / −X). Delegates to HQEnvironment so the
# parked-car lineup (_build_lineup) and the painted bay dividers agree on the grid.
func _bay_center_x(i: int, bays: int) -> float:
	return HQEnvironment.bay_center_x(i, bays)


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
	# Pure click target — overlap monitoring is unused (see hq_environment.gd).
	area.monitoring = false
	area.monitorable = false
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
# eligibility filter used to build the car-park lineup (_build_eligible_lineup),
# including an over-powered car that would qualify if it agreed to a detune.
func _has_eligible_car(rally: Dictionary) -> bool:
	for car in Save.profile.get("cars", []):
		var entry := CarLibrary.by_id(String(car.get("model_id", "")))
		var meta := UpgradeLibrary.effective_meta(car, entry)
		if RallyLibrary.is_eligible(rally, meta):
			return true
		if _qualifying_detune_for(rally, car, entry, meta) > 0.0:
			return true
		if _qualifying_drivetrain_for(rally, car, entry, meta) >= 0:
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


# A diegetic-station action button: FOCUS_NONE (the station navigates by a manual
# left/right cursor, not native focus), text set raw (UITheme.enforce uppercases + sizes
# it on the next _normalize_menus), with `cb` wired to `pressed`. The repeated
# new + FOCUS_NONE + connect idiom the garage row / tuning hub used inline.
func _station_button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	return b


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

	# Free Roam: drop straight into a freshly-seeded stage with neutral (0.5) terrain
	# settings — no rally, no opponents, just driving. Opens the car park to pick which
	# owned car to drive (see _enter_free_roam).
	var free := Button.new()
	free.text = "Free Roam"
	free.focus_mode = Control.FOCUS_ALL
	free.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	free.custom_minimum_size = Vector2(220, 44)
	free.pressed.connect(_enter_free_roam)
	root.add_child(free)
	_title_free_roam_button = free

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

	# Framework: WASD + arrow + gamepad focus nav for the flat Start/Settings menu
	# (no on_back — EXTERIOR has no back; the diegetic stations behind keep menu_*).
	# MenuNav goes inert while _title_layer is hidden, so it never steals input from
	# the 3D stations. hq re-grabs focus itself on view entry.
	MenuNav.attach(root, {first = start})


# True when the WEB build is running in an Android browser — the one case where the
# player could instead install the (much faster) APK from the itch.io page. iOS has
# no app to offer and desktop web performs fine, so neither gets the notice.
func _should_show_android_app_notice() -> bool:
	return OS.has_feature("web_android")


# One-per-boot notice over the title shot: mobile-web performance is poor, the APK
# is much faster. Hides the title overlay while it's up so its MenuNav can't fight
# this one for focus; dismissing restores the title (whose MenuNav re-grabs focus
# via visibility_changed).
func _show_android_app_notice() -> void:
	if _android_notice_layer != null:
		return
	_title_layer.visible = false
	var made := _make_overlay()
	_android_notice_layer = made[0]
	var root: VBoxContainer = made[1]
	root.alignment = BoxContainer.ALIGNMENT_CENTER

	var msg := Label.new()
	msg.text = "Heads up: the browser version runs much slower on phones.\nFor smooth performance, install the free Android app from itch.io."
	msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	msg.add_theme_font_size_override("font_size", 22)
	root.add_child(msg)

	var get_app := Button.new()
	get_app.text = "Get the Android app"
	get_app.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	get_app.custom_minimum_size = Vector2(320, 52)
	get_app.pressed.connect(func() -> void: OS.shell_open(ANDROID_APP_URL))
	root.add_child(get_app)

	var stay := Button.new()
	stay.text = "Continue in browser"
	stay.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	stay.custom_minimum_size = Vector2(320, 44)
	stay.pressed.connect(_dismiss_android_app_notice)
	root.add_child(stay)

	MenuNav.attach(root, {first = get_app, on_back = _dismiss_android_app_notice})


func _dismiss_android_app_notice() -> void:
	if _android_notice_layer == null:
		return
	_android_notice_layer.queue_free()
	_android_notice_layer = null
	_title_layer.visible = _view == View.EXTERIOR


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
	# Back / Map / Tune Car / Repair form a single left/right ButtonCursor
	# (_garage_focus). FOCUS_NONE + hand-painted like the tuning hub, since the garage is
	# a spatially-navigated 3D station, not a native focus graph. Each button's pressed
	# callable is ALSO the cursor's action for that index, so click and select agree.
	# (Free Roam lives on the EXTERIOR title screen, not here — see _build_title_overlay.)
	var on_back := func() -> void: _go_to(View.EXTERIOR)
	var back := _station_button("< Back", on_back)
	actions.add_child(back)
	# Convenience buttons mirroring the clickable 3D table / lift.
	var to_table := _station_button("Career", _enter_table)
	actions.add_child(to_table)
	var to_lift := _station_button("Tune Car", _enter_lift)
	actions.add_child(to_lift)
	# Repair: spend one Repair Kit on the selected car (full restore). Its label is set
	# on garage entry to reflect whether there's anything to repair (see
	# _refresh_garage_repair_button); pressing it when there isn't is a no-op.
	var repair := _station_button("Repair", _repair_selected_car)
	actions.add_child(repair)
	_garage_repair_button = repair
	_garage_cursor.setup(
		[back, to_table, to_lift, repair],
		[on_back, _enter_table, _enter_lift, _repair_selected_car])

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

	_tune_panel = TuningPanel.new()
	content.add_child(_tune_panel)
	_lift_upgrades_box = VBoxContainer.new()
	_lift_upgrades_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lift_upgrades_box.add_theme_constant_override("separation", 8)
	content.add_child(_lift_upgrades_box)

	# Framework: WASD + arrow + gamepad focus nav for the native-focus TUNE (sliders)
	# and UPGRADES (install / repair) sub-pages. Attached to the sub-boxes ONLY — not
	# the lift root — so the diegetic HUB buttons (FOCUS_NONE, manual left/right
	# cursor) are left untouched. Each box goes inert while hidden (_menu_visible).
	MenuNav.attach(_tune_panel)
	MenuNav.attach(_lift_upgrades_box)

	# The shared "< Back" for both sub-pages. Focusable so keyboard/gamepad can reach it:
	# it lives in `root` (a sibling of the scroll, below the page content), and the box
	# MenuNavs drive focus across container boundaries by geometry, so down-nav off the
	# last slider / upgrade row lands here. It's also the focus fallback for a page whose
	# body has no focusable control (a fresh car's Upgrades page — see _open_lift_page).
	_lift_back_button = Button.new()
	_lift_back_button.text = "< Back"
	_lift_back_button.focus_mode = Control.FOCUS_ALL
	_lift_back_button.pressed.connect(_lift_hub)
	root.add_child(_lift_back_button)

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

	# Back / Change Car / Tuning / Upgrades form a single left/right ButtonCursor
	# (_hub_focus). As with the garage row, each button's pressed callable is also the
	# cursor's action for that index, so a click and a keyboard/gamepad select agree.
	var on_back := func() -> void: _go_to(View.GARAGE)
	var to_tune_cb := _open_lift_page.bind(LiftPage.TUNE)
	var to_upgrades_cb := _open_lift_page.bind(LiftPage.UPGRADES)
	var back := _station_button("< Back", on_back)
	_lift_hub_controls.add_child(back)
	# Change which car is on the lift: opens the car park to pick a new selected car.
	var change_car := _station_button("Change Car", _enter_change_car)
	_lift_hub_controls.add_child(change_car)
	# The two menu buttons.
	var to_tune := _station_button("Tuning >", to_tune_cb)
	_lift_hub_controls.add_child(to_tune)
	var to_upgrades := _station_button("Upgrades >", to_upgrades_cb)
	_lift_hub_controls.add_child(to_upgrades)
	_hub_cursor.setup(
		[back, change_car, to_tune, to_upgrades],
		[on_back, _enter_change_car, to_tune_cb, to_upgrades_cb])



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

	# Engine-swap only: the post-swap power-to-weight for BOTH cars (a swap exchanges
	# engines, so both change). Coloured ↑/↓ deltas; hidden in every other car-park mode.
	_swap_preview_label = RichTextLabel.new()
	_swap_preview_label.bbcode_enabled = true
	_swap_preview_label.fit_content = true
	_swap_preview_label.scroll_active = false
	_swap_preview_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_swap_preview_label.add_theme_font_size_override("normal_font_size", 13)
	_swap_preview_label.set_meta("menu_nav_skip", true)
	_swap_preview_label.visible = false
	root.add_child(_swap_preview_label)

	# Shown when the focused car can't be entered as-is: wrecked (why + how to fix it).
	# An over-powered car does NOT warn here — its detune agreement pops as a confirm
	# dialog on Start instead (_show_detune_confirm), keeping the overlay compact.
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
	_passthrough_overlay(root)  # let taps / swipes reach the 3D lineup behind the HUD


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
	_passthrough_overlay(root)  # let taps / swipes reach the 3D lineup behind the HUD


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
	_overflow_car_label.text = "%s  (%d of %d)" % [
		entry.get("name", owned.get("model_id", "?")),
		_focus + 1, _eligible.size()]
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

	# Framework: WASD + arrow + gamepad focus nav across the SettingsMenu rows and
	# the bottom button. No on_back — hq owns menu_back here (SettingsMenu.go_back /
	# gate handling). Inert while the settings layer is hidden.
	MenuNav.attach(root)


# Open the Settings page. `gate` = the mandatory pre-rally pick (bottom button starts
# the rally); otherwise it's the title-screen settings (bottom button goes back).
# Always reset to the category list so each open starts at the top level.
func _open_settings(gate: bool) -> void:
	_settings_gate = gate
	_settings_sub.text = ("Choose your touch controls to start:" if gate
		else "Camera & controls:")
	# The pre-rally gate jumps straight to the mobile-controls page — the player only
	# needs to pick a touch layout, not wade through the full category list. The
	# title-screen / pause entry opens on the category list as usual.
	if gate:
		_settings_menu.show_schemes()  # emits page_changed → sets the bottom button label
	else:
		_settings_menu.show_list()
	_go_to(View.SETTINGS)


# Keep the single bottom button in step with the page: in the pre-rally gate the
# bottom button always starts the rally ("Start >", since the gate shows only the
# mobile-controls page); otherwise it's a plain "< Back" (out to the list from a
# sub-page, or out to the exterior from the list).
func _on_settings_page_changed(_is_root: bool) -> void:
	if _settings_action_button == null:
		return  # SettingsMenu._ready fires its first page_changed before the button exists
	_settings_action_button.text = "Start >" if _settings_gate else "< Back"


# The settings bottom button. On a sub-page it returns to the category list. On the
# list, in the pre-rally gate, make sure a scheme is saved (the highlighted default
# if the player didn't tap one) so we never ask again, then start the rally; from the
# title screen it just returns to the exterior.
func _on_settings_action() -> void:
	# Gate: the button starts the rally straight from the mobile-controls page. Make
	# sure a scheme is saved (the highlighted default if the player didn't tap one) so
	# we never ask again.
	if _settings_gate:
		if Save.get_setting(MobileControls.SETTING_KEY, null) == null:
			Save.set_setting(MobileControls.SETTING_KEY, MobileControls.DEFAULT_SCHEME)
		_settings_gate = false
		_begin_rally_start()
		return
	if not _settings_menu.at_root():
		_settings_menu.show_list()
		return
	_go_to(View.EXTERIOR)


# --- Confirmation dialog -----------------------------------------------------

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
		_refresh_garage_repair_button()  # reflect the selected car's health / kit count
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
# free roam with the focused car (see _start_free_roam), Back returns to the title.
# Entered from the EXTERIOR title screen's Free Roam button (see _build_title_overlay).
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
	var box: Control = _tune_panel if page == LiftPage.TUNE else _lift_upgrades_box
	# Seat the cursor on the page body's first control, else on the shared Back button
	# (a fresh car's Upgrades body has no focusable control, so it'd otherwise be dead).
	_grab_lift_page_focus.bind(box).call_deferred()


# Return from a sub-menu to the bay hub (restores the up/down hub cursor highlight).
# The hub navigates by hand (left/right cycles the car), so release the native focus
# the sub-page's sliders/buttons held.
func _lift_hub() -> void:
	_lift_page = LiftPage.HUB
	get_viewport().gui_release_focus()
	_refresh_lift_ui()


# Move the garage's left/right cursor between Back (0), Map (1), Tune Car (2) and
# Repair (3), wrapping at the ends, and repaint it.
func _move_garage_focus(step: int) -> void:
	_garage_focus = _garage_cursor.wrapped(_garage_focus, step)
	_refresh_garage_focus()


# Fire the garage action the cursor sits on: 0 backs out to the exterior, 1 opens the
# map table, 2 opens the tuning lift, 3 repairs the selected car.
func _activate_garage_focus() -> void:
	_garage_cursor.activate(_garage_focus)


# Paint the manual garage cursor (a spatially-navigated 3D station, so the Back / Map /
# Tune Car / Repair buttons are highlighted by hand rather than via native focus).
func _refresh_garage_focus() -> void:
	_garage_cursor.refresh(_garage_focus)


# Set the garage Repair button's label + enabled state to reflect the SELECTED car's
# state: it's DISABLED (greyed, unclickable) when there's nothing to do — the car is
# already at full health, or it's damaged but no Repair Kit is owned — and only enabled
# when a kit can actually restore a damaged car. The label spells out which case it is.
# First tops up a stranded player via the safety net (a free kit when every owned car is
# wrecked), so a repairable-but-kitless player is never left permanently stuck.
func _refresh_garage_repair_button() -> void:
	if _garage_repair_button == null:
		return
	Save.ensure_repair_safety_net()
	var owned := Save.selected_car()
	var entry := CarLibrary.by_id(String(owned.get("model_id", "")))
	var max_hp := float(entry.get("max_hp", 0.0))
	var hp := float(owned.get("hp", 0.0))
	var kits := int(Save.profile.get("inventory", {}).get(UpgradeLibrary.REPAIR_KIT_ID, 0))
	if max_hp > 0.0 and hp >= max_hp:
		_garage_repair_button.text = "Repair — full health"
		_garage_repair_button.disabled = true
	elif kits > 0:
		_garage_repair_button.text = "Repair (%d kit%s)" % [kits, "" if kits == 1 else "s"]
		_garage_repair_button.disabled = false
	else:
		_garage_repair_button.text = "Repair — no kits"
		_garage_repair_button.disabled = true


# Spend one Repair Kit on the selected car (full restore) from the garage. A no-op when
# the car is already at full health or no kit is owned — the button label already says
# so. On a repair, respawns the lift/garage prop (fresh DamageModel, so the wreck smoke
# stops) and re-labels the button.
func _repair_selected_car() -> void:
	var id := Save.selected_instance_id()
	if id < 0:
		return
	var owned := Save.get_car(id)
	var entry := CarLibrary.by_id(String(owned.get("model_id", "")))
	var max_hp := float(entry.get("max_hp", 0.0))
	var hp := float(owned.get("hp", 0.0))
	if max_hp <= 0.0 or hp >= max_hp:
		return  # nothing to repair
	if not Save.use_repair_kit(id):
		return  # no kit owned
	_ensure_lift_car()  # the car is healed — the hash flips, so the prop respawns healthy
	_refresh_garage_repair_button()


# Move the HUB's left/right cursor between Back (0), Change Car (1), Tuning (2) and
# Upgrades (3), wrapping at the ends, and repaint it.
func _move_hub_focus(step: int) -> void:
	_hub_focus = _hub_cursor.wrapped(_hub_focus, step)
	_refresh_hub_focus()


# Fire the hub item the cursor sits on: 0 backs out to the garage, 1 opens the car park
# to change car, 2/3 open the Tuning / Upgrades pages.
func _activate_hub_focus() -> void:
	_hub_cursor.activate(_hub_focus)


# Paint the manual hub cursor (the hub uses left/right + select, not native focus, so the
# Back / Change Car / Tuning / Upgrades buttons are highlighted by hand instead).
func _refresh_hub_focus() -> void:
	_hub_cursor.refresh(_hub_focus)


# Seat the sub-page cursor: the body's first focusable control, or the shared Back
# button when the body has none (a fresh car's Upgrades page — see _rebuild_upgrades_box)
# so the page is never dead to keyboard/gamepad.
func _grab_lift_page_focus(box: Node) -> void:
	var first := UITheme.first_focusable(box)
	UITheme.focus_grab(first if first != null else _lift_back_button)


# Spawn (or keep) the selected car raised on the lift. No-op if the right car is
# already there. The lift car is frozen immediately (wheels hang, as on a ramp).
func _ensure_lift_car() -> void:
	var owned := Save.selected_car()
	if owned.is_empty():
		_clear_lift_car()
		return
	var id := int(owned.get("instance_id", -1))
	var owned_hash := owned.hash()
	if is_instance_valid(_lift_car) and _lift_car_instance_id == id and _lift_car_hash == owned_hash:
		_lift_owned = owned
		return
	_clear_lift_car()
	_lift_owned = owned
	_lift_car_instance_id = id
	_lift_car_hash = owned_hash
	_lift_car = _spawn_lift_car(owned)


func _clear_lift_car() -> void:
	if _lift_tween != null and _lift_tween.is_valid():
		_lift_tween.kill()  # the tween targets the car we're about to free
	if is_instance_valid(_lift_car):
		_lift_car.queue_free()
	_lift_car = null
	_lift_car_instance_id = -2
	_lift_car_hash = 0


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
	# Recover a wrecked-out player before drawing the lift: a free Repair Kit when
	# every owned car is wrecked and none is held (also checked on save load and on
	# garage entry). Repair itself now lives on the garage station row, not here.
	Save.ensure_repair_safety_net()
	_lift_owned = Save.selected_car()
	var entry := CarLibrary.by_id(String(_lift_owned.get("model_id", "")))
	_lift_car_label.text = "%s\n%s" % [
		EngineSwap.display_name(entry, _lift_owned), _car_stats_text(_lift_owned, entry)]
	# Show the hub (car selector + menu buttons) or a sub-menu page from _lift_page.
	# The car description hides while a sub-menu is open so the centred page has room.
	_lift_hub_controls.visible = _lift_page == LiftPage.HUB
	_lift_info_panel.visible = _lift_page == LiftPage.HUB
	_lift_menu_bg.visible = _lift_page != LiftPage.HUB
	_tune_panel.visible = _lift_page == LiftPage.TUNE
	_lift_upgrades_box.visible = _lift_page == LiftPage.UPGRADES
	# TUNE hides the page title to reclaim vertical space (its sliders must fit
	# without scrolling); UPGRADES keeps its heading.
	_lift_menu_title.visible = _lift_page != LiftPage.TUNE
	_lift_menu_title.text = "UPGRADES"
	# Re-bind the TUNE panel to the current owned car and reflect its stored tuning.
	# on_change is a no-op: the HQ lift did not re-field the display car on a tune edit
	# (the change lands on next fielding), so preserve that behaviour.
	_tune_panel.setup(_lift_owned, Callable())
	_tune_panel.refresh()
	_rebuild_upgrades_box()
	_refresh_hub_focus()  # keep the left/right hub cursor highlight in step
	_normalize_menus()  # re-apply house rules to the freshly-built upgrade rows



# Rebuild the UPGRADES menu for the current car: one row per slot, each an earn-gated
# option selector on the right (None + the slot's catalogue parts; drivetrain is the
# RWD/AWD/FWD picker), plus the engine-swap row. A part option is greyed until that kit
# is fitted to this car; picking one enables it (at most one enabled per slot), picking
# None turns the slot off. A fitted part can't be removed, only switched off (to None).
func _rebuild_upgrades_box() -> void:
	# Preserve the focused control across the rebuild: a toggle / repair click rebuilds
	# these rows, and without this the keyboard/gamepad cursor would jump back to the top
	# of the list. Capture the focused control's stable key (only when it's inside this
	# box — on a fresh page open focus isn't here yet, so _open_lift_page seats it) and
	# re-grab the matching control after the rows are rebuilt.
	var focus_key := ""
	var focused := get_viewport().gui_get_focus_owner()
	if focused != null and focused.has_meta("upgrade_focus_key") \
			and _lift_upgrades_box.is_ancestor_of(focused):
		focus_key = String(focused.get_meta("upgrade_focus_key"))

	# Free the row children only — NOT the MenuNav helper attached to this box, which is
	# also a child. Freeing it would strip the page's WASD/gamepad focus nav (arrows still
	# work via native GUI, but menu_up/down/left/right wouldn't) — the tune box never hits
	# this because it's built once and never rebuilt.
	for c in _lift_upgrades_box.get_children():
		if c is MenuNav:
			continue
		c.queue_free()
	var id := int(_lift_owned.get("instance_id", -1))
	var installed: Array = _lift_owned.get("installed_upgrades", [])

	for slot in UpgradeLibrary.SLOTS:
		_lift_upgrades_box.add_child(_make_slot_row(slot, id, installed))

	# Engine swap: current engine + a button into the car-park swap picker.
	_lift_upgrades_box.add_child(_make_engine_swap_row(id))
	# No in-box Back button: the shared "< Back" in `root` (below the scroll) serves both
	# pages and is the focus fallback when this page's body has no focusable control (a
	# fresh car — all slots empty, full health, Swap Engine disabled). See _open_lift_page.

	# Re-apply the house font rules to the freshly-built rows. The row builders author
	# their own font_size (15); UITheme.enforce bumps every Label/Button back to FONT_SIZE
	# (16). Callers that rebuild via _refresh_lift_ui re-normalize afterwards, but the live
	# rebuild paths (_set_drivetrain / _set_turbo) don't — so without this the text would
	# visibly shrink 16 → 15 the moment you pick a drivetrain/turbo. Enforce at the shared
	# choke point so every rebuild path stays consistent.
	UITheme.enforce(_lift_upgrades_box)

	# Re-run attach on the freshly-built rows: makes the new toggle/apply/repair/swap
	# buttons focusable and re-seats MenuNav's `first` (its cursor-revive target) onto a
	# live control. attach reuses the existing MenuNav (preserved above), so no stacking.
	MenuNav.attach(_lift_upgrades_box)

	# Put the cursor back where it was (the same slot's toggle, the swap row, …) so a
	# toggle/repair click doesn't fling focus to the top. Deferred so the fresh rows are
	# in the tree; if the matching control is gone it stays wherever attach left it.
	if focus_key != "":
		_restore_upgrade_focus.bind(focus_key).call_deferred()


# Re-grab the upgrades control tagged with `focus_key` (set in the row builders) after a
# rebuild, so the keyboard/gamepad cursor stays put across a toggle/repair press. No-op
# if that control no longer exists (attach's re-seat stands).
func _restore_upgrade_focus(focus_key: String) -> void:
	for node in _lift_upgrades_box.find_children("*", "Control", true, false):
		var c := node as Control
		# Skip controls in a dying subtree: the rebuild queue_frees whole ROW containers,
		# whose descendant buttons aren't themselves is_queued_for_deletion(), so match the
		# FRESH tagged control — not the old one about to be freed (which would null focus).
		if c != null and not UITheme.in_dying_subtree(c) \
				and c.has_meta("upgrade_focus_key") \
				and String(c.get_meta("upgrade_focus_key")) == focus_key \
				and c.focus_mode != Control.FOCUS_NONE and c.is_visible_in_tree() \
				and not (c is BaseButton and (c as BaseButton).disabled):
			c.grab_focus()
			return


func _make_slot_row(slot: String, instance_id: int, installed: Array) -> Control:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 2)

	# The drivetrain slot has NO enable/disable toggle — owning the swap kit is the
	# unlock, and the selector's stock choice IS the "off" state (disabling would just
	# re-select the original drive mode). So show ONLY the FWD/RWD/AWD selector when the
	# kit is owned, or a plain "— empty —" line when it isn't.
	if slot == "drivetrain":
		if UpgradeLibrary.drivetrain_swap_unlocked(_lift_owned):
			box.add_child(_make_drivetrain_selector(instance_id))
		else:
			var empty := Label.new()
			empty.add_theme_font_size_override("font_size", 15)
			empty.text = "Drivetrain: — empty —"
			box.add_child(empty)
		return box

	# Every other slot is an EARN-GATED option selector on the right — "SLOT:" on the
	# left, then None + one button per catalogue part in this slot (Turbo has two, Small /
	# Big; the rest have exactly one, e.g. "Aero: None / Aero Kit"). None is always available
	# and plays the "off" role; each part option is greyed until its kit is fitted to this
	# car. Reads exactly like the drivetrain picker, and is built on the same enable/disable
	# machinery (one enabled part per slot), so the reward flow is unchanged — purely the
	# menu presentation, unified across all part slots.
	box.add_child(_make_option_selector(slot, instance_id, installed))
	return box


# The FWD/RWD/AWD picker shown on the drivetrain slot row once the swap kit is enabled.
# The current mode is the stored override, or the car's stock drive_mode when unset (-1).
# Each button is FOCUS_ALL so keyboard/gamepad can reach it; the active mode is marked.
func _make_drivetrain_selector(instance_id: int) -> Control:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var stock := int(CarLibrary.by_id(String(_lift_owned.get("model_id", ""))).get("drive_mode", CarLibrary.RWD))
	var override := int(_lift_owned.get("drivetrain_override", -1))
	var current := override if override >= 0 else stock
	var label := Label.new()
	label.text = "Drivetrain:"
	label.add_theme_font_size_override("font_size", 15)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	# Every mode is always available once the swap kit is owned (available = true) — the
	# earn-gating is on the whole selector, not per option. Reuses the shared _option_button
	# builder so the bracket-active / FOCUS_ALL / focus-key construction lives in one place.
	for mode in [CarLibrary.RWD, CarLibrary.AWD, CarLibrary.FWD]:
		row.add_child(_option_button(_drive_text(mode), mode == current, true,
			"drivetrain:" + str(mode), _set_drivetrain.bind(instance_id, mode)))
	return row


func _set_drivetrain(instance_id: int, mode: int) -> void:
	Save.set_drivetrain_override(instance_id, mode)
	_lift_owned = Save.get_car(instance_id)
	_rebuild_upgrades_box()  # re-marks the active mode and re-seats MenuNav focus


# The earn-gated option selector shown on every part slot except drivetrain: "SLOT:" then
# None + one button per catalogue part in this slot (in catalogue order). None is always
# available (the "off" state); each part is greyed until that kit is fitted to this car, and
# the active option is bracketed. The button label is the part's `menu_label` if present
# (Turbo's short Small / Big), else its full `name` ("Aero Kit", "Big Brake Kit", …).
func _make_option_selector(slot: String, instance_id: int, installed: Array) -> Control:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var label := Label.new()
	label.text = "%s:" % slot.capitalize()
	label.add_theme_font_size_override("font_size", 15)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	# The catalogue parts for this slot, in catalogue order (Turbo: Small then Big; the
	# rest have exactly one), and which one (if any) is currently the enabled pick.
	var parts: Array = []
	var current_id := ""
	for def in UpgradeLibrary.all():
		if String(def.get("slot", "")) != slot or bool(def.get("consumable", false)):
			continue
		parts.append(def)
		var pid := String(def.get("id", ""))
		if installed.has(pid) and UpgradeLibrary.is_enabled(_lift_owned, pid):
			current_id = pid
	# None is always available and plays the "off" role.
	row.add_child(_option_button("None", current_id == "", true,
		"opt:%s:none" % slot, _set_slot_option.bind(instance_id, slot, "")))
	# One button per catalogue part, greyed until that kit is fitted to this car.
	for def in parts:
		var pid := String(def.get("id", ""))
		var text := String(def.get("menu_label", def.get("name", pid)))
		row.add_child(_option_button(text, current_id == pid, installed.has(pid),
			"opt:%s:%s" % [slot, pid], _set_slot_option.bind(instance_id, slot, pid)))
	return row


# One selector button: bracketed when active, greyed when its option isn't available yet,
# FOCUS_ALL so keyboard/gamepad can reach it, and tagged with a stable focus key so the
# cursor lands back on it after the rebuild a press triggers.
func _option_button(text: String, active: bool, available: bool, focus_key: String,
		on_press: Callable) -> Button:
	var b := Button.new()
	b.text = "[%s]" % text if active else text
	b.focus_mode = Control.FOCUS_ALL
	b.disabled = not available
	b.set_meta("upgrade_focus_key", focus_key)
	b.pressed.connect(on_press)
	return b


func _set_slot_option(instance_id: int, slot: String, item_id: String) -> void:
	# None (item_id == "") disables every part in the slot; otherwise enable the chosen part
	# (same-slot exclusivity switches any sibling off). Goes through the shared enable/disable
	# path so the one-enabled-per-slot rule and the reward flow are preserved. The spec change
	# respawns the display prop and refreshes stats + rows (like _toggle_upgrade did).
	if item_id == "":
		for def in UpgradeLibrary.all():
			if String(def.get("slot", "")) == slot:
				Save.set_upgrade_enabled(instance_id, String(def.get("id", "")), false)
	else:
		Save.set_upgrade_enabled(instance_id, item_id, true)
	_ensure_lift_car()  # the car's spec changed — the hash flips, so the prop respawns
	_refresh_lift_ui()  # updates stats + rebuilds rows + re-seats MenuNav focus


# The engine-swap row on the upgrades page: current engine label + a Swap button
# that opens the car park in swap mode. A swap needs BOTH cars at 100% HP, but a
# damaged car no longer blocks the button — it's repaired with a Repair Kit as part
# of the swap (one kit per damaged car, spent on confirm). The button is only
# disabled when there's literally no other owned car to swap with; the repair-kit
# cost (and the "you have no kits" case) is surfaced in the car park + confirm popup,
# never by disabling. See features/engine-swap.md.
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
	button.set_meta("upgrade_focus_key", "swap")  # keep the cursor here across a rebuild
	var full_hp: bool = EngineSwap.at_full_health(owned)
	var has_target := not _swap_targets(instance_id).is_empty()
	button.disabled = not has_target  # only impossible when there's no other car at all
	if not has_target:
		button.tooltip_text = "No other car to swap engines with"
	elif not full_hp:
		button.tooltip_text = "Not at 100% health — swapping will spend a Repair Kit to restore it first"
	button.pressed.connect(_enter_engine_swap)
	row.add_child(button)
	return row


# The owned cars this car can swap engines with: every OTHER owned car, full to it.
# No car is excluded on health — a damaged partner is repaired with a Repair Kit as
# part of the swap (see _select_swap_target). Shared by the swap-row gating and the
# car-park swap lineup so they never disagree.
func _swap_targets(current_id: int) -> Array:
	var targets: Array = []
	if Save.get_car(current_id).is_empty():
		return targets
	for car in Save.profile.get("cars", []):
		if int(car.get("instance_id", -1)) == current_id:
			continue
		targets.append(car)
	return targets


# Repair Kits currently held in the shared inventory.
func _repair_kits_owned() -> int:
	return int(Save.profile.get("inventory", {}).get(UpgradeLibrary.REPAIR_KIT_ID, 0))


# How many Repair Kits a swap between these two cars would consume: one per car that
# isn't already at 100% health (the swap restores each damaged car to full first).
func _kits_needed_for_swap(lift: Dictionary, partner: Dictionary) -> int:
	var n := 0
	if not lift.is_empty() and not EngineSwap.at_full_health(lift):
		n += 1
	if not partner.is_empty() and not EngineSwap.at_full_health(partner):
		n += 1
	return n


# Toggle an applied part on/off (free, instant, reversible — no confirm needed)
# and rebuild the lift prop + UI so the spec change shows immediately.
func _toggle_upgrade(instance_id: int, item_id: String, enabled: bool) -> void:
	if Save.set_upgrade_enabled(instance_id, item_id, enabled):
		_ensure_lift_car()  # the car's spec changed — the hash flips, so the prop respawns
		_refresh_lift_ui()


# Enter the car park for the chosen rally: park the ELIGIBLE owned cars (plus any
# over-powered car a detune would qualify — see _build_eligible_lineup) and frame
# the first. With none, show a hint + disable Start.
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
		if _swap_preview_label != null:
			_swap_preview_label.visible = false
			_swap_preview_label.text = ""
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
		_go_to(View.EXTERIOR)
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
	# Release (hide + detach) the parked cars rather than freeing them, so a re-entry
	# into any lineup can reuse the cached instances (see _car_cache / _build_lineup).
	for car in _cars:
		if is_instance_valid(car):
			car.visible = false
	for marker in _markers:
		if is_instance_valid(marker):
			marker.queue_free()
	_cars = []
	_markers = []
	_eligible = []
	_detune_needed = {}
	_drivetrain_needed = {}


# Free every cached (and currently active) parked car outright — used when the cache
# would otherwise leak, e.g. eviction of sold cars. Frees the node and drops its entry.
func _free_cached_car(instance_id: int) -> void:
	var entry: Dictionary = _car_cache.get(instance_id, {})
	var node = entry.get("node")
	if is_instance_valid(node):
		node.queue_free()
	_car_cache.erase(instance_id)


# Drop cache entries for cars the player no longer owns (sold / scrapped), freeing
# their nodes so the cache doesn't outlive the collection.
func _evict_unowned_cached_cars() -> void:
	var owned_ids := {}
	for car in Save.profile.get("cars", []):
		owned_ids[int(car.get("instance_id", -1))] = true
	for id in _car_cache.keys():
		if not owned_ids.has(id):
			_free_cached_car(id)


# Park the owned cars ELIGIBLE for the selected rally (the car-select screen), plus
# any OVER-POWERED car a detune would fit under the rally's pw_max cap — those park
# looking eligible, and pressing Start pops an explicit agreement to that detune
# (_show_detune_confirm / _on_start_pressed).
func _build_eligible_lineup() -> void:
	var rally := RallyLibrary.by_id(_selected_rally_id)
	var eligible: Array = []
	var needs_detune := {}
	var needs_drivetrain := {}
	for car in Save.profile.get("cars", []):
		var entry := CarLibrary.by_id(String(car.get("model_id", "")))
		var meta := UpgradeLibrary.effective_meta(car, entry)
		if RallyLibrary.is_eligible(rally, meta):
			eligible.append(car)
			continue
		var id := int(car.get("instance_id", -1))
		var target := _switch_target_for(rally, car, meta)
		var meta_sw := meta
		if target >= 0:
			meta_sw = meta.duplicate()
			meta_sw["drive_mode"] = target
		# Switch alone qualifies?
		if target >= 0 and RallyLibrary.is_eligible(rally, meta_sw):
			needs_drivetrain[id] = target
			eligible.append(car)
			continue
		# Detune (on the switched-or-stock meta) qualifies, possibly stacked with a switch.
		var frac := _qualifying_detune_for(rally, car, entry, meta_sw, target)
		if frac > 0.0:
			if target >= 0:
				needs_drivetrain[id] = target
			needs_detune[id] = frac
			eligible.append(car)
	_build_lineup(eligible)  # clears _detune_needed / _drivetrain_needed (via _clear_lineup)
	_detune_needed = needs_detune
	_drivetrain_needed = needs_drivetrain


# The engine-detune fraction that would let `owned` enter `rally`, for the one case
# the car-park prompt covers: the car is TOO POWERFUL (its current p/w sits over the
# rally's pw_max cap) but tuning the engine down would duck it under. -1.0 when the
# car is under the cap (already eligible, or ineligible for a reason detuning can't
# fix — those cars keep today's behaviour) or when no detune qualifies it.
func _qualifying_detune_for(rally: Dictionary, owned: Dictionary, entry: Dictionary, meta: Dictionary, drive_override := -1) -> float:
	var r: Dictionary = rally.get("restriction", {})
	if not r.has("pw_max"):
		return -1.0
	if CarLibrary.power_to_weight(meta) * KW_KG_TO_HP_TONNE <= float(r["pw_max"]):
		return -1.0
	var frac := RallyLibrary.qualifying_detune(rally, _full_power_meta(owned, entry, drive_override))
	return frac if frac > 0.0 and frac < 1.0 else -1.0


# The drive mode this car would switch to for `rally` (the rally's required mode), or -1
# when the rally has no drive_mode rule, the car lacks the swap kit, or it's already in
# that mode. Judges ONLY the drive_mode dimension — callers layer detune on top.
func _switch_target_for(rally: Dictionary, owned: Dictionary, meta: Dictionary) -> int:
	var r: Dictionary = rally.get("restriction", {})
	if not r.has("drive_mode"):
		return -1
	if not UpgradeLibrary.drivetrain_swap_unlocked(owned):
		return -1
	var required := int(r["drive_mode"])
	if int(meta.get("drive_mode", -1)) == required:
		return -1
	return required


# The drive mode `owned` must switch to in order to enter `rally`, or -1 when it's
# already compliant OR can't be switched (no swap kit / rally has no drive_mode rule /
# fails for another reason). Accepts a switch that qualifies ALONE, or a switch that
# qualifies when STACKED with an engine detune (see _qualifying_detune_for).
func _qualifying_drivetrain_for(rally: Dictionary, owned: Dictionary, entry: Dictionary, meta: Dictionary) -> int:
	var target := _switch_target_for(rally, owned, meta)
	if target < 0:
		return -1
	var switched := meta.duplicate()
	switched["drive_mode"] = target
	if RallyLibrary.is_eligible(rally, switched):
		return target
	return target if _qualifying_detune_for(rally, owned, entry, switched, target) > 0.0 else -1


# The car's effective stats at FULL engine tune (detune 1.0), whatever the stored
# slider value — the base the qualifying-detune math scales down from, so the prompt
# always proposes an absolute slider setting. `drive_override` stamps a switched
# drive_mode on top, so a switch+detune stack is evaluated on the POST-switch mode.
func _full_power_meta(owned: Dictionary, entry: Dictionary, drive_override := -1) -> Dictionary:
	var full := owned.duplicate(true)
	var tuning: Dictionary = full.get("tuning", {})
	tuning["engine_detune"] = 1.0
	full["tuning"] = tuning
	var out := UpgradeLibrary.effective_meta(full, entry)
	if drive_override >= 0:
		out["drive_mode"] = drive_override
	return out


# Park ALL owned cars for the title screen, so the player's whole collection is on
# show in the car park behind the title overlay (rebuilt on entering EXTERIOR).
func _build_title_lineup() -> void:
	_build_lineup(Save.profile.get("cars", []).duplicate())


# Park the given owned cars in the painted bays, laid out as a centred row ALONG X at
# the car-park lot (GameConfig.hq_carpark_origin / menu_car_spacing), each car parked
# nose-out toward the courtyard / menu camera (+Z) so the front-3/4 framing shows its
# face with the garage behind it. Fewer cars than bays are centred within the grid so
# they stay over real bays. The cars are placed resting on their wheels and frozen at
# once (see _spawn_parked_car). Shared by the rally car-select lineup (eligible cars)
# and the title screen (all owned cars).
func _build_lineup(cars: Array) -> void:
	_clear_lineup()  # bumps _settle_generation, cancelling any in-flight spawn
	_evict_unowned_cached_cars()  # drop cached nodes for cars sold since the last build
	_eligible = cars
	var cfg: GameConfig = Config.data
	var n := cars.size()
	var bays: int = max(1, cfg.max_owned_cars)
	var center := HQEnvironment.carpark_center()
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
		var car := _obtain_parked_car(cars[i], _markers[i])
		_cars.append(car)
		# Both fresh and cached cars are placed frozen at rest (see _spawn_parked_car /
		# _obtain_parked_car), so there's nothing to settle. Only a freshly-instanced car
		# (heavy: physics scene + mesh duplication) is spread across a frame to avoid
		# hitching; a cached car reappears with no per-frame cost.
		if car.get_meta("lineup_fresh", false):
			await get_tree().process_frame
	if generation != _settle_generation:
		return
	emit_signal("lineup_built")


# Return a parked car for `owned` at `marker`, reusing the cached instance when this
# car's data is unchanged (deep hash match) or (re)spawning a fresh one otherwise. The
# returned node carries a "lineup_fresh" meta so the caller knows whether it still
# needs to settle. Updates _car_cache in place.
func _obtain_parked_car(owned: Dictionary, marker: Marker3D) -> Node3D:
	var instance_id := int(owned.get("instance_id", -1))
	var owned_hash := owned.hash()
	var cached: Dictionary = _car_cache.get(instance_id, {})
	var node = cached.get("node")
	if is_instance_valid(node) and int(cached.get("hash", 0)) == owned_hash:
		# Reuse: it's already built, sized, and frozen. Re-seat it analytically at the new
		# bay so it sits on its wheels (writing the raw marker transform would drop the
		# body to ground level — marker y = 0 — and sink it).
		_seat_car_at_marker(node, marker)
		node.visible = true
		node.set_meta("lineup_fresh", false)
		node.set_meta("owned_instance_id", instance_id)
		return node
	# Stale (data changed) or missing: drop any old node and spawn afresh.
	if is_instance_valid(node):
		node.queue_free()
	var fresh := _spawn_parked_car(owned, marker)
	fresh.set_meta("lineup_fresh", true)
	fresh.set_meta("owned_instance_id", instance_id)
	_car_cache[instance_id] = {"hash": owned_hash, "node": fresh}
	return fresh


# Spawn one owned car as a silent car prop resting at a marker, with its OWN mesh
# copies (see _dup_meshes) so a mixed lineup shows each at its true size. Placed with
# its wheels on the bay via the analytic rest ride height (car.gd:settled_ride_height)
# and frozen at once — no live physics to settle, so nothing to mistime or drift.
func _spawn_parked_car(owned: Dictionary, marker: Marker3D) -> Node3D:
	var car := _car_scene_res().instantiate()
	add_child(car)
	# Isolated config so this parked/display car's apply_owned can't clobber the
	# player car's tuning in the shared global Config.data (see car.gd `config`).
	car.use_isolated_config()
	car.apply_owned(owned)
	_dup_meshes(car)
	_seat_car_at_marker(car, marker)
	# Frozen prop resting at its pose: no body integration and no per-frame car script
	# (drivetrain/steering/aero) cost. We stop physics processing rather than fully
	# PROCESS_MODE_DISABLE the node so the body stays a normal member of the physics
	# space — it must remain ray-pickable for tap-to-focus (see _car_index_at).
	car.freeze = true
	car.set_physics_process(false)
	# Silence its engine — no audio from the parked cars.
	var audio := car.get_node_or_null("EngineAudio")
	if audio != null:
		audio.process_mode = Node.PROCESS_MODE_DISABLED
		if audio is AudioStreamPlayer:
			audio.playing = false
			audio.volume_db = -80.0
	_add_synthetic_smoke(car)
	return car


# Seat a car on its bay marker with its wheels on the ground: the marker's pose (bay
# position + facing) lifted by the car's analytic resting ride height. Shared by fresh
# spawns and cache reuse so both sit identically on their suspension at any bay.
func _seat_car_at_marker(car: Node, marker: Marker3D) -> void:
	car.global_transform = marker.global_transform
	car.global_position += Vector3.UP * car.settled_ride_height()


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
		_car_name_label.text = "%s  (%d of %d)" % [
			display_name, _focus + 1, _eligible.size()]
		_car_stats_label.text = stats
		_refresh_swap_preview()
		if _carpark_swap_mode:
			# Picking a swap partner: no car is excluded — warn about the Repair Kit
			# cost (and the no-kits case) instead of gating on damage.
			_refresh_swap_repair_warning(owned)
		else:
			# A wrecked focused car gates Start + offers a Repair (full restore).
			_refresh_focus_damage(owned)
	_normalize_menus()  # keep house rules on the just-updated car name / stats
	_move_camera_to(_camera_target_xform(), snap)


# The two-way power-to-weight preview shown only while picking an engine-swap partner.
# A swap EXCHANGES engines, so it shows the resulting hp/tonne for the car on the lift
# (receiving the focused partner's engine) AND the focused partner (receiving the lift
# car's engine). Coloured ↑ gain / ↓ loss / — unchanged. Hidden in every other mode.
func _refresh_swap_preview() -> void:
	if _swap_preview_label == null:
		return
	if not _carpark_swap_mode:
		_swap_preview_label.visible = false
		_swap_preview_label.text = ""
		return
	var lift_owned := Save.get_car(Save.selected_instance_id())
	var partner_owned: Dictionary = _eligible[_focus]
	if lift_owned.is_empty() or partner_owned.is_empty():
		_swap_preview_label.visible = false
		return
	var lift_entry := CarLibrary.by_id(String(lift_owned.get("model_id", "")))
	var partner_entry := CarLibrary.by_id(String(partner_owned.get("model_id", "")))
	var lift_stock := String(lift_entry.get("engine", ""))
	var partner_stock := String(partner_entry.get("engine", ""))
	var lift_engine := EngineSwap.current_engine_id(lift_owned, lift_stock)
	var partner_engine := EngineSwap.current_engine_id(partner_owned, partner_stock)
	var k := CarLibrary.KW_KG_TO_HP_TONNE
	# Lift car receives the partner's engine; partner receives the lift car's engine.
	var lift_before := CarLibrary.power_to_weight(UpgradeLibrary.effective_meta(lift_owned, lift_entry)) * k
	var lift_after := EngineSwap.pw_after_swap(lift_owned, lift_entry, partner_engine) * k
	var partner_before := CarLibrary.power_to_weight(UpgradeLibrary.effective_meta(partner_owned, partner_entry)) * k
	var partner_after := EngineSwap.pw_after_swap(partner_owned, partner_entry, lift_engine) * k
	_swap_preview_label.text = "%s\n%s" % [
		_swap_preview_row(String(lift_entry.get("name", "?")), lift_before, lift_after),
		_swap_preview_row(String(partner_entry.get("name", "?")), partner_before, partner_after)]
	_swap_preview_label.visible = true


# One preview row: "Name:  before → after hp/tonne ↑" with a coloured arrow.
func _swap_preview_row(car_name: String, before: float, after: float) -> String:
	var arrow := "[color=#888]—[/color]"
	if after > before + 0.5:
		arrow = "[color=#5fd35f]↑[/color]"
	elif after < before - 0.5:
		arrow = "[color=#e05555]↓[/color]"
	return "[center]%s:  %.0f → %.0f hp/tonne %s[/center]" % [car_name, before, after, arrow]


# A wrecked focused car can't be entered: disable Start and explain why, offering a
# Repair (full restore) when a kit is owned. A healthy car clears all of this — an
# over-powered car looks eligible here; its detune agreement only surfaces as a
# confirm popup on Start (_show_detune_confirm).
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


# Swap-partner warning (car park, swap mode): no car is ever excluded, so Start
# stays enabled. When the lift car and/or this partner aren't at 100% HP, spell out
# how many Repair Kits the swap will spend to restore them first — and, if the player
# is short, tell them (the confirm popup then blocks the swap). A pair already at full
# health needs no kit and shows nothing.
func _refresh_swap_repair_warning(partner_owned: Dictionary) -> void:
	_start_button.disabled = false
	_car_repair_button.visible = false
	var lift := Save.get_car(Save.selected_instance_id())
	var needed := _kits_needed_for_swap(lift, partner_owned)
	if needed == 0:
		_car_warning_label.visible = false
		return
	_car_warning_label.visible = true
	var kit_word := "Kit" if needed == 1 else "Kits"
	var kits := _repair_kits_owned()
	if kits >= needed:
		_car_warning_label.text = "This swap will spend %d Repair %s to restore both cars to 100%% first." % [needed, kit_word]
	else:
		_car_warning_label.text = "This swap needs %d Repair %s to restore both cars, but you have %d." % [needed, kit_word, kits]


# An over-powered focused car (parked because a detune would duck it under the
# rally's pw_max cap — _build_eligible_lineup) looks eligible in the car park —
# no warning label, plain Start — to keep the car-select overlay compact. Pressing
# Start pops this confirm instead: it spells out that the car doesn't qualify and
# the engine tune that would fix it, and the OK button ("Detune to N% & Start")
# applies that tune and launches (_on_detune_confirmed).
func _show_detune_confirm(owned: Dictionary, frac: float) -> void:
	var entry := CarLibrary.by_id(String(owned.get("model_id", "")))
	var cap := float(RallyLibrary.by_id(_selected_rally_id).get("restriction", {}).get("pw_max", 0.0))
	var pw := CarLibrary.power_to_weight(UpgradeLibrary.effective_meta(owned, entry)) * KW_KG_TO_HP_TONNE
	var tuned_pw := CarLibrary.power_to_weight(_full_power_meta(owned, entry)) * KW_KG_TO_HP_TONNE * frac
	var pct := roundi(frac * 100.0)
	if _detune_dialog == null:
		_detune_dialog = ConfirmationDialog.new()
		_detune_dialog.title = "Detune to enter?"
		_detune_dialog.get_cancel_button().text = "Cancel"
		_detune_dialog.confirmed.connect(_on_detune_confirmed)
		# Cap the dialog's width: without wrapping it sizes to the longest text line
		# and can overflow a small window. Wrap the message at a fixed label width
		# instead and let the dialog grow vertically.
		var label := _detune_dialog.get_label()
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.custom_minimum_size = Vector2(400, 0)
		add_child(_detune_dialog)
	_detune_dialog.dialog_text = ("%.0f hp/tonne is over this rally's %.0f cap. " +
		"Starting will detune the engine to %d%% (%.0f hp/tonne) so it qualifies.") % [pw, cap, pct, tuned_pw]
	_detune_dialog.ok_button_text = "Detune to %d%% & Start" % pct
	_detune_dialog.reset_size()  # re-fit to this car's message (a stale larger size sticks otherwise)
	_detune_dialog.popup_centered()


# The player agreed to the qualifying detune (_show_detune_confirm): apply that
# engine tune to the car, then continue the normal start flow. The agreement is
# TEMPORARY, for this rally only — register the current tune (the garage-set
# value, or the untouched 1.0) with the session so it's restored when the rally
# ends (RallySession.register_detune_revert; garage-lift detunes stay permanent).
func _on_detune_confirmed() -> void:
	var frac: float = _detune_needed.get(_selected_instance_id, -1.0)
	if frac <= 0.0:
		return
	var prior := float(Save.get_car(_selected_instance_id).get("tuning", {}).get("engine_detune", 1.0))
	RallySession.register_detune_revert(_selected_instance_id, prior)
	Save.set_engine_detune(_selected_instance_id, frac)
	_detune_needed.erase(_selected_instance_id)
	await _proceed_with_start()


# Spend a Repair Kit on the focused (wrecked) car: full restore, then re-evaluate so
# Start unlocks and the stats refresh. The owned dict is shared with the save, so the
# restored HP flows straight back into the lineup.
func _repair_focused_car() -> void:
	if _eligible.is_empty():
		return
	var id := int(_eligible[_focus].get("instance_id", -1))
	if Save.use_repair_kit(id):
		_build_lineup(_eligible)  # respawn the healed prop so its fresh (healthy)
		_focus_changed()          # DamageModel stops the synthetic smoke



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
	return "%s | %.2f G | %.0f hp/tonne | %s" % [
		_drive_text(int(entry.get("drive_mode", -1))),
		CarLibrary.max_lateral_g(meta, Config.data),
		CarLibrary.power_to_weight(meta) * KW_KG_TO_HP_TONNE,
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
	# A min+max pair reads as a single range ("power-to-weight 300-400 hp/tonne"); a lone
	# floor or ceiling keeps its >= / <= form. The authored bands are already in hp/tonne
	# (RallyLibrary converts a car's kW/kg to hp/tonne before comparing), the same unit as
	# every player-facing p/w readout (the car stats + the detune slider), so display
	# them straight — no conversion here.
	if restriction.has("pw_min") and restriction.has("pw_max"):
		parts.append("power-to-weight %.0f-%.0f hp/tonne" % [
			float(restriction["pw_min"]), float(restriction["pw_max"])])
	elif restriction.has("pw_min"):
		parts.append("power-to-weight >= %.0f hp/tonne" % float(restriction["pw_min"]))
	elif restriction.has("pw_max"):
		parts.append("power-to-weight <= %.0f hp/tonne" % float(restriction["pw_max"]))
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
	# Apply a qualifying drivetrain switch first (temporary, reverted after the rally),
	# so the subsequent detune math sees the switched car.
	var need_dm: int = _drivetrain_needed.get(_selected_instance_id, -1)
	if need_dm >= 0:
		var prior_dm := int(Save.get_car(_selected_instance_id).get("drivetrain_override", -1))
		RallySession.register_drivetrain_revert(_selected_instance_id, prior_dm)
		Save.set_drivetrain_override(_selected_instance_id, need_dm)
		_drivetrain_needed.erase(_selected_instance_id)
	# An over-powered car looks eligible in the park; pressing Start pops the detune
	# agreement as a confirm dialog instead of an always-on warning label. Only an
	# explicit OK there applies the tune and fields the car (_on_detune_confirmed).
	var detune: float = _detune_needed.get(_selected_instance_id, -1.0)
	if detune > 0.0:
		_show_detune_confirm(owned, detune)
		return
	await _proceed_with_start()


# The start flow after any detune agreement is settled: the mobile control-scheme
# gate, then the actual handoff.
func _proceed_with_start() -> void:
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
	_enter_lift()  # a different car is selected — _ensure_lift_car's id/hash key respawns it


# Confirm the highlighted car as the engine-swap partner: exchange engines, then
# respawn the lift prop with its new engine and return to the upgrades page.
func _select_swap_target() -> void:
	var current_id := Save.selected_instance_id()
	if _selected_instance_id < 0:
		return
	var partner_id := _selected_instance_id
	var needed := _kits_needed_for_swap(Save.get_car(current_id), Save.get_car(partner_id))
	if needed > 0:
		# A damaged car is involved: confirm the Repair Kit cost (or block if short)
		# before touching anything. The commit happens on OK (_on_swap_repair_confirmed).
		_show_swap_repair_confirm(current_id, partner_id, needed)
		return
	_commit_engine_swap(current_id, partner_id)


# Perform the swap, repairing any car that isn't at full health with a Repair Kit
# first (each spends one kit) so Save.swap_engines' both-at-100% guard passes. Callers
# guarantee enough kits are owned. Then respawn the lift prop with its new engine and
# return to the upgrades page.
func _commit_engine_swap(current_id: int, partner_id: int) -> void:
	if not EngineSwap.at_full_health(Save.get_car(current_id)):
		Save.use_repair_kit(current_id)
	if not EngineSwap.at_full_health(Save.get_car(partner_id)):
		Save.use_repair_kit(partner_id)
	Save.swap_engines(current_id, partner_id)
	_clear_lineup()
	_selected_instance_id = -1
	_carpark_swap_mode = false
	_ensure_lift_car()  # the engine data changed — the hash flips, so the prop respawns
	_enter_lift()


# Popup when a swap partner needs repairing: if the player owns enough kits, an OK
# ("Repair & Swap") commits the swap; if not, the OK is disabled and the message says
# so — no car is excluded, the player is just told they're short on kits.
func _show_swap_repair_confirm(current_id: int, partner_id: int, needed: int) -> void:
	if _swap_repair_dialog == null:
		_swap_repair_dialog = ConfirmationDialog.new()
		_swap_repair_dialog.title = "Repair to swap?"
		_swap_repair_dialog.get_cancel_button().text = "Cancel"
		_swap_repair_dialog.confirmed.connect(_on_swap_repair_confirmed)
		var label := _swap_repair_dialog.get_label()
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.custom_minimum_size = Vector2(400, 0)
		add_child(_swap_repair_dialog)
	var kits := _repair_kits_owned()
	var kit_word := "Kit" if needed == 1 else "Kits"
	if kits >= needed:
		_pending_swap = {"current": current_id, "partner": partner_id}
		_swap_repair_dialog.dialog_text = ("Both cars must be at 100%% to swap engines. " +
			"This will spend %d Repair %s to restore them, then exchange engines.") % [needed, kit_word]
		_swap_repair_dialog.ok_button_text = "Repair & Swap"
		_swap_repair_dialog.get_ok_button().disabled = false
	else:
		_pending_swap = {}
		_swap_repair_dialog.dialog_text = ("This swap needs %d Repair %s to restore both cars to 100%%, " +
			"but you only have %d. Win more, or pick a car that's already at full health.") % [needed, kit_word, kits]
		_swap_repair_dialog.ok_button_text = "Repair & Swap"
		_swap_repair_dialog.get_ok_button().disabled = true
	_swap_repair_dialog.reset_size()
	_swap_repair_dialog.popup_centered()


# OK on the repair-to-swap popup: spend the kits and perform the swap.
func _on_swap_repair_confirmed() -> void:
	if _pending_swap.is_empty():
		return
	var current_id := int(_pending_swap["current"])
	var partner_id := int(_pending_swap["partner"])
	_pending_swap = {}
	_commit_engine_swap(current_id, partner_id)


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
				# In the pre-rally gate we show only the mobile-controls page (no category
				# list), so back cancels the gate straight back to the car park. Otherwise
				# a sub-page backs out to the category list first, then back exits to title.
				if _settings_gate:
					_go_to(View.CARPARK)
					_settings_gate = false
				elif not _settings_menu.go_back():
					_go_to(View.EXTERIOR)
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
			# leave the prompt until the garage is back under the cap. Swipe + tap-a-car
			# work here too (the overflow shares the lineup machinery).
			if _lineup_pointer_input(event):
				pass
			elif event.is_action_pressed("menu_left"):
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
	if _lineup_pointer_input(event):
		return
	if event.is_action_pressed("menu_left"):
		_cycle_focus(-1)
	elif event.is_action_pressed("menu_right"):
		_cycle_focus(1)
	elif event.is_action_pressed("menu_select") and not _start_button.disabled:
		_on_start_pressed()
	elif event.is_action_pressed("menu_back"):
		_car_back()


# Pointer navigation for the car-park / overflow lineup (mouse, or finger via
# emulate_mouse_from_touch): a horizontal drag past menu_swipe_min_px swipes the
# focus to the prev/next car (drag left pulls the NEXT car in from the right, like
# flicking a carousel); a press+release that stayed under menu_tap_max_px is a tap,
# which raycasts into the lot and focuses the parked car under the pointer, so the
# player can just touch the car they want instead of hunting for the ◄ ► buttons.
# Returns true when the event was pointer traffic this handler owns.
func _lineup_pointer_input(event: InputEvent) -> bool:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_lineup_pressing = true
			_lineup_drag_accum = Vector2.ZERO
		elif _lineup_pressing:
			_lineup_pressing = false
			var cfg: GameConfig = Config.data
			if absf(_lineup_drag_accum.x) >= cfg.menu_swipe_min_px \
					and absf(_lineup_drag_accum.x) > absf(_lineup_drag_accum.y):
				_cycle_focus(1 if _lineup_drag_accum.x < 0.0 else -1)
			elif _lineup_drag_accum.length() <= cfg.menu_tap_max_px:
				_focus_car_at(event.position)
		return true
	if event is InputEventMouseMotion and _lineup_pressing:
		_lineup_drag_accum += event.relative
		return true
	return false


# Tap-to-select: raycast from the camera through the tapped screen point and, if it
# hits one of the parked lineup cars, focus that car directly. The frozen props stay
# in the physics space (freeze + PROCESS_MODE_DISABLED don't remove their bodies),
# so a plain space query finds them without any per-car Area3D plumbing.
func _focus_car_at(screen_pos: Vector2) -> void:
	var idx := _car_index_at(screen_pos)
	if idx >= 0 and idx != _focus:
		_focus = idx
		_focus_changed()


# The lineup index of the parked car whose body the ray through `screen_pos` hits
# first, or -1 for a miss (ground, buildings, empty sky). The hit collider is a
# child body inside the car scene, so walk up to the root that _cars holds.
func _car_index_at(screen_pos: Vector2) -> int:
	var from := _camera.project_ray_origin(screen_pos)
	var to := from + _camera.project_ray_normal(screen_pos) * 200.0
	var hit := get_world_3d().direct_space_state.intersect_ray(
		PhysicsRayQueryParameters3D.create(from, to))
	if hit.is_empty():
		return -1
	var node: Node = hit.get("collider")
	while node != null:
		var i := _cars.find(node)
		if i >= 0:
			return i
		node = node.get_parent()
	return -1
