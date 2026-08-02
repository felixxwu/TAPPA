class_name HqController
extends Node3D
# HQ — the meta-game hub (todo/menus.md location 1), now a DIEGETIC 3D space the
# camera flies through (todo/diegetic-hq.md) instead of flat overlay screens. One
# world; the camera moves between "stations":
#   * EXTERIOR — the boot/title shot: block buildings + the outdoor car park, with
#     a Start button (plus Exit Game on non-web builds). Start flies the camera into
#     the garage. (Settings lives on the garage action row.)
#   * GARAGE   — a block garage interior holding the MAP TABLE and the TUNING LIFT.
#     The player's SELECTED car is raised on the lift here. Tap the table to see the
#     rallies; tap the lift to tune. Its action row also carries FREE ROAM, which opens
#     the car park to pick a car and drive session-lessly.
#   * TABLE    — a near-top-down look at the table's 3D map. Tap a rally pin to open
#     its detail; Enter flies out to the car park.
#   * LIFT     — the tuning bay: the selected car raised on the lift on one side. The
#     bay opens on a HUB page (the car's name/description, Upgrades / Tuning buttons,
#     and a Test Drive button) bottom-left beside the car. Each menu button opens that
#     menu as its OWN full-height page (TUNE = grip/brake/aero sliders; UPGRADES =
#     install parts); Test Drive drops into free roam with the car on the lift
#     so neither needs to scroll; Back returns the page to the hub, and the hub's Back
#     returns to the garage. (A REPAIR button also lives on the hub row but is hidden
#     for now — earning Repair Kits is disabled.)
#   * CARPARK  — the outdoor lineup of cars: in RALLY mode the cars ELIGIBLE for the
#     chosen rally (pan + Start); in GARAGE mode the whole collection (pan +
#     Select the car to take to the tuning lift).
# Flow: pick rally (table) -> choose eligible car (car park) -> Start -> RallySession.
# It is the game's boot scene and stays lightweight (NO track gen).
#
# Clickable 3D objects (table, lift, rally pins) are Area3D with input_ray_pickable;
# get_viewport().physics_object_picking drives the picking. Headless tests call the
# handlers (_enter_table / _on_rally_pin / _enter_car_screen / ...) directly.
#
# Shared-resource note: car.tscn's body/wheel meshes are SubResources shared across
# instances, so apply_car sizing one parked car would resize every other. After
# apply_owned each parked car gets its OWN mesh copies (CarProp.dup_meshes) so a mixed lot
# shows each at its true size. apply_owned also writes the shared Config.data (last
# car wins) — harmless here: the props don't simulate, and world.gd re-applies the
# fielded car's config before a run.

# Camera stations (see the per-station poses in GameConfig "Menu / HQ"). SETTINGS
# is a flat overlay over the exterior shot (no dedicated camera pose), reached from
# the garage action row. (The collection is unbounded — the car park pages through it,
# so there's no garage-full gate.)
enum View { EXTERIOR, GARAGE, TABLE, LIFT, CARPARK, SETTINGS }

# The cars offered on first run (the two authored-body cars). The player picks one in
# the car park (see _enter_starter_pick); the chosen one becomes the player's first car.
# Generalises over this list, so a third starter is a one-line add.
const STARTER_MODEL_IDS := ["mx5", "focus", "twingo"]

# Static access to base_design_height() for the post-process dither grid; the same
# preload world.gd uses, since the autoload instance isn't needed for a static call.
const DisplayStretchScript := preload("res://scripts/display_stretch.gd")
# RallySession is an autoload with no class_name, so its STATIC canonical config
# writer (apply_event_config) must be reached through the script resource — calling a
# static via the instance warns. Same precedent as driving_context.gd.
const RallySessionScript := preload("res://scripts/rally_session.gd")

# The tuning-lift pages (todo/menus.md rig 4). HUB is the bay landing page (car
# name/description + Upgrades/Tuning buttons + a Test Drive button); TUNE is
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
# How many qualifying cars the rally-detail card names before it tails off with "+N more".
const MAX_QUALIFY_NAMES := 1
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
# The car park serves several jobs, one at a time (never overlapping):
#   RALLY    (default) — cars eligible for the chosen rally; Start launches the rally.
#   GARAGE   (garage's "Garage" button) — ALL owned cars; Select picks the car to tune
#            and takes the player straight to the tuning lift bay.
#   FREEROAM (garage's "Free Roam" button) — the WHOLE catalogue as base-model previews;
#            Start drops into a session-less drive in the picked car (owned or not).
#   SWAP     (_enter_engine_swap) — OTHER owned cars; Select picks an engine-swap partner.
#   STARTER  (first run) — preview cars (garage empty); Select grants the first car.
#   WHEELS   (_enter_wheel_swap) — the selected car ALONE in the lot, settled on its
#            suspension, with a low side-on camera; left/right cycles cosmetic wheel
#            styles live on the car and Start fits the shown one. Uses the car park
#            (not the tuning lift) precisely because the lift holds the car RAISED and
#            wheels are judged by stance. See features/wheel-customization.md.
#   CHALLENGE (_enter_challenge_car_screen) — the Rally Challenge entry point's car
#            picker (spec §7 / §2): owned cars ChallengeSession.eligible_cars(kind, ...)
#            reports for the currently-shown kind, same over-cap-but-detune-reachable
#            treatment as RALLY via _detune_needed (judged with
#            ChallengeSession.qualifying_detune_for instead of RallyLibrary.qualifying_detune,
#            since a challenge has no authored rally dict — see _build_challenge_lineup).
#            Start commits ChallengeSession.start + the scene hand-off instead of
#            RallySession.start_rally (see _begin_challenge_start).
# One enum instead of mutually-exclusive booleans: entering a job sets the mode
# (which inherently clears the others), and every exit/commit/back returns to RALLY.
enum CarparkMode { RALLY, GARAGE, FREEROAM, SWAP, STARTER, WHEELS, CHALLENGE }
var _carpark_mode := CarparkMode.RALLY

# Cosmetic wheel-swap state, live only in CarparkMode.WHEELS. _wheel_options is the
# style list from WheelStyle.options_for (stock first); _wheel_index is the cursor into
# it, previewed on the parked car as it moves. The preview is VISUAL ONLY — nothing is
# written to the save until Start (_commit_wheels), and backing out re-skins the car
# back to its saved style (_revert_wheel_preview) so no uncommitted skin can be left
# on the shared _car_cache node.
var _wheel_options: Array = []
var _wheel_index := 0
# The owned car this wheel session is for, captured ONCE on entry. Preview / revert /
# commit all key off this instead of re-deriving the car from _lift_owned in one place and
# Save.selected_instance_id() in another — two sources that agree today but would silently
# apply a commit to the WRONG car if they ever drifted apart.
var _wheel_instance_id := -1

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

# Car-park state. `_lineup` (CarList) is the SINGLE owner of the full car list, its
# pagination, and the cursor across every car-park screen (rally car-select, garage
# picker, engine-swap, starter, free roam). `_eligible` mirrors the CURRENT PAGE's cars
# (what's actually parked in the bays) and `_focus` the cursor's page-LOCAL index, both
# refreshed from `_lineup` after each nav so the rest of hq.gd can keep indexing
# `_eligible[_focus]` / `_markers[_focus]`. See scripts/car_list.gd.
var _lineup := CarList.new()
var _eligible: Array = []
# instance_id -> the engine-detune fraction that would qualify an over-powered parked
# car for the chosen rally (RallyLibrary.qualifying_detune). Populated only by the
# rally car-select lineup (_build_eligible_lineup); for these cars Start opens the
# over-limit prompt that routes to the upgrades menu (_show_over_limit_prompt /
# _on_start_pressed) rather than launching.
var _detune_needed: Dictionary = {}
var _drivetrain_needed: Dictionary = {}
# Confirm popup shown when Start is pressed on an over-powered car: the car looks
# eligible in the park; this dialog carries the "too powerful" nudge and routes to
# Change Upgrades (_show_over_limit_prompt). Implemented via ConfirmPopup.
# The car-park "Change Upgrades" popup, opened from the over-limit prompt as an alternative
# to detuning: a house-themed overlay on the car CanvasLayer hosting an UpgradesMenu for
# the focused car (no engine-swap row). Built lazily. _dirty tracks whether any upgrade
# changed, so closing rebuilds the eligible lineup (see _show/_close_upgrades_popup).
var _upgrades_popup: Control
var _upgrades_popup_menu: UpgradesMenu
var _upgrades_popup_done: Button   # gated by the rally's p/w cap (UpgradesMenu.bind_close_button)
var _upgrades_popup_dirty := false
# Tracks the currently open car-park ConfirmPopup (detune confirm), so
# _carpark_modal_open can detect it without a dedicated visible flag.
var _active_carpark_popup: ConfirmPopup = null
# Confirm popup shown when a chosen engine-swap partner is picked: swapping costs one
# engine swap token. Carries the token cost, or the "no tokens" block. Implemented via
# ConfirmPopup. _pending_swap holds the two instance ids awaiting the OK press.
var _pending_swap: Dictionary = {}
# The start path the mobile control-scheme gate interrupted, resumed by
# _on_settings_action once a scheme is saved. Set by _start_preflight, which every
# start path (career, challenge, free roam) funnels through — so the gate exists once
# and each path resumes into ITSELF rather than always into the career start.
var _pending_start: Callable = Callable()
var _cars: Array = []
var _markers: Array = []
# Reuse cache for parked lineup cars, shared by every lineup (rally car-select,
# title, free roam) since they all build from the same car dicts. Keyed by the
# owned car's instance_id -> {"hash": int, "node": Node3D}; the hash is the deep
# Variant hash of the owned dict, so a car whose tuning / damage / engine changed
# gets a fresh respawn while unchanged cars are reused as-is (see _build_lineup /
# _release_page_props). Cars are hidden + stowed off-screen (not freed) between lineups
# and freed with the HQ node on exit-to-race.
var _car_cache: Dictionary = {}
var _focus := 0
# Plays a short engine rev for the focused car each time the lineup selection
# changes (see _preview_rev). Created lazily on first focus.
var _preview_audio: CarPreviewAudio = null
# Bumped each time a lineup is (re)built so an in-flight progressive spawn for an old
# lineup stops adding cars when it resumes (see _spawn_lineup_progressive).
var _settle_generation := 0
# Free Roam pre-warm: just AFTER boot (once the loading cover lifts, one prop per frame —
# see _prewarm_free_roam_deferred) we spawn the catalogue's preview
# props into _car_cache (hidden) so entering Free Roam reuses them with no fresh instancing
# — killing the first-entry lag spike. _prewarm_marker is the off-screen stow marker the
# hidden props seat at until Free Roam re-seats them at real bays.
var _prewarm_marker: Marker3D = null
# True once every catalogue preview is warm in _car_cache (the deferred prewarm ran to
# completion, or _prewarm_free_roam was called synchronously). Read by tests; also lets a
# stray re-start of the deferred loop bail immediately.
var _prewarm_complete := false
# True while the deferred (one-prop-per-frame) prewarm loop is in flight, so it can't be
# started twice and overlap itself.
var _prewarm_running := false

# Tuning-lift state: the selected car raised on the lift (a Car prop, separate from
# the car-park lineup), which OwnedCar it is, and which menu (TUNE / UPGRADES) is up.
var _lift_car: Node3D
var _lift_owned: Dictionary = {}
# Car-lift HUB "Repair" button: repairs the SELECTED car with one Repair Kit. HIDDEN for
# now (earning Repair Kits is disabled) — built but kept invisible and out of the hub
# cursor (see _build_lift_overlay). Its label reflects state — "Repair (x kit)" when the
# car is damaged and a kit is owned, "Repair — full health" / "Repair — no kits"
# otherwise — recomputed whenever the lift is refreshed (_refresh_lift_repair_button).
var _lift_repair_button: Button
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
var _map_plane: MeshInstance3D   # the flat map laid on the table top
var _pins_root: Node3D          # parent of the rally pins
# False until _build_hq has run. _ready connects the cloud signals BEFORE the build
# (it has to: the boot pull it awaits is what emits them), so a handler can fire
# against a half-constructed HQ — see _on_cloud_profile_replaced.
var _hq_built := false
var _pins: Array = []           # the pin Node3Ds (each carries a "rally_id" meta)
# Focus cursor into _table_targets() (the unlocked rally pins); -1 = none.
var _table_focus_index := -1
# Cached _table_targets() result. The target set only changes on pin rebuild
# (_refresh_map_pins), which sets this back
# to null; every access rebuilds lazily. Per-frame table panning (_process ->
# _pan_table_step) reuses it instead of rebuilding a Dictionary-per-target array each frame.
var _table_targets_cache = null

# Overlays (one CanvasLayer per station; only the active one is visible).
# The overlay/menu-layer builders live in HqOverlays (scripts/hq_overlays.gd),
# constructed with `self` in _ready so they can reach back into this controller.
var _overlays: HqOverlays
var _title_layer: CanvasLayer

# How long the starter-pick gate will wait on the boot-time cloud pull before
# giving up and letting the player through (see _await_cloud_restore). A seam:
# tests shrink it so the bounded-wait path can be exercised without spending real
# seconds. Not a tunable — it is a timeout budget, not a look or balance value.
var cloud_restore_wait_sec: float = Cloud.INITIAL_SYNC_WAIT_SEC
# True while _on_exterior_start is parked in that wait. Guards against a second
# Start press spawning a second coroutine (see _on_exterior_start).
var _awaiting_cloud := false
var _android_notice_layer: CanvasLayer  # web-on-Android boot notice; null once dismissed
# Optional cloud save, reachable from the title screen as well as from Settings —
# a player restoring a career on a new device shouldn't have to find it in a
# submenu. Null while closed. See features/cloud-save.md.
var _account_layer: CanvasLayer
var _account_menu: AccountMenu
# Rally Challenge entry point (Daily/Weekly/Monthly, spec §7): a modal overlay over
# the garage, opened from the garage row's Challenge button, built as a dark detail-
# card sibling to the rally-detail panel (build_detail_overlay's MODAL_DIM + header +
# HSeparator + _detail_heading/_detail_wrap_label shape) rather than a flat button
# list. See hq_overlays.gd's build_challenge_overlay and the _open_challenge_overlay
# family below.
var _challenge_layer: CanvasLayer
var _challenge_kind: String = ChallengeLibrary.DAILY
# Bumped by every _refresh_challenge_overlay. The board queries that decorate the entry
# screen (placing, cut-line time) are async, so each captures the generation it was
# fired for and writes its answer ONLY if that's still current — the row may have been
# rebuilt, or the kind switched, while the request was in flight.
#
# This replaced "does the label still read the exact string I left it at", which looked
# equivalent and was not: _open_challenge_overlay runs UITheme.enforce right after
# building the row, uppercasing every Label, so a mixed-case comparison never matched
# and the answer was silently dropped. A counter can't be defeated by anything that
# rewrites the text.
var _challenge_refresh_generation := 0
# Board answers already fetched during THIS visit to the online challenge screen, keyed
# by period key (so a period rolling over mid-session re-asks by itself). Switching
# Daily/Weekly/Monthly re-renders the whole screen, which used to re-issue both queries
# every time and flash "Loading…" on rows the player had already seen answered.
#
# Cleared in _close_challenge_overlay — leaving the screen for the garage is the
# invalidation point, so the numbers can't go stale behind the player's back for long,
# and re-opening always asks again. Only OK answers are cached: a failure is a transient
# condition (offline, board unreachable), not a value, so it retries on the next visit
# to that tab instead of sticking for the rest of the session.
var _challenge_cutoff_cache: Dictionary = {}
var _challenge_placing_cache: Dictionary = {}
# The Daily/Weekly/Monthly tab row: real FOCUS_ALL buttons (so keyboard/gamepad focus
# can rest on and move across them via native left/right focus-neighbour nav — see
# menu_nav.gd) but mouse_filter = MOUSE_FILTER_IGNORE and no `pressed` wiring at all, so
# there is NO mouse hover/click interaction whatsoever — arriving via focus (each one's
# focus_entered calls _select_challenge_kind) is the only way to pick a kind. See
# build_challenge_overlay. Order matches [DAILY, WEEKLY, MONTHLY] — _challenge_kind_button.
var _challenge_kind_buttons: Array[Button] = []
# Header: title ("Daily Challenge") + subtitle (the rolled ceiling), mirroring
# _detail_title/_detail_region's two-line shape.
var _challenge_title_label: Label
var _challenge_subtitle_label: Label
# Four concise sections, each one _detail_heading + one/two _detail_wrap_label rows:
# win condition, win reward, eligible cars, current progress. (The ceiling already
# rides on the header subtitle, so it doesn't get its own "entry requirement" row.)
var _challenge_win_label: Label
var _challenge_reward_label: Label
var _challenge_eligible_label: Label
var _challenge_progress_label: Label
var _challenge_start_button: Button
var _garage_layer: CanvasLayer
var _table_layer: CanvasLayer
var _detail_layer: CanvasLayer
var _lift_layer: CanvasLayer
var _car_layer: CanvasLayer
var _settings_layer: CanvasLayer
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
var _detail_region: Label        # region tag under the title (muted)
var _detail_showdown: Label      # gold "SHOWDOWN" chip on the header row
var _detail_restriction: Label   # the eligibility restriction summary
var _detail_qualify: Label       # the qualifying cars, named (GREEN / RED / muted)
var _detail_adjust: Label        # "N need a tune/swap" caution (GOLD, hidden when 0)
var _detail_record: Label        # best-finish text beside the StarRow
var _detail_stars: StarRow       # medal row for the player's best finish
var _detail_enter_button: Button # "Enter Rally" — disabled when no owned car qualifies
var _rally_banner: Label
var _car_name_label: Label
var _car_stats_label: Label
var _swap_preview_label: RichTextLabel
var _start_button: Button
var _title_start_button: Button  # EXTERIOR title Start — first cursor stop
# These three are populated by HqOverlays.build_title_overlay (the assignment lives in
# another class now) and read by tests, so GDScript's in-class "unused" check can't see
# their use — silence it rather than reintroduce a dead in-class reference.
@warning_ignore("unused_private_class_variable")
var _title_account_button: Button  # EXTERIOR title Account (optional cloud save)
@warning_ignore("unused_private_class_variable")
var _title_settings_button: Button  # EXTERIOR title Settings
@warning_ignore("unused_private_class_variable")
var _title_exit_button: Button  # EXTERIOR title Exit Game (last in the row)
@warning_ignore("unused_private_class_variable")
var _title_version_label: Label  # EXTERIOR title build-version readout (bottom-right)
var _no_eligible_label: Label
# Car-park damage UI: a "too damaged" note + a Repair action for a wrecked focused car.
var _car_warning_label: Label
var _car_repair_button: Button

# Title screen cursor: a single left/right cursor over Start / Account / Settings /
# (Exit Game). Same diegetic-station idiom as the garage row and lift hub — FOCUS_NONE
# buttons highlighted by hand — now that EXTERIOR is a horizontal action row rather
# than a native-focus vertical list. hq keeps the index (_title_focus, read by tests);
# the ButtonCursor owns the shared wrap/paint/fire behaviour.
var _title_cursor := ButtonCursor.new()
var _title_focus := 0           # which title button the cursor sits on (starts on Start)

# Garage overlay cursor: a single left/right cursor over the bottom action row.
# Buttons are FOCUS_NONE and highlighted by hand (a ButtonCursor, like the tuning hub)
# since the garage is a spatially-navigated 3D station, not a focus graph. hq keeps
# the index (_garage_focus, read by tests); the ButtonCursor owns the shared
# wrap/paint/fire behaviour (scripts/button_cursor.gd).
#
# TWO LEVELS share this one row/cursor (rebuilt in place by _refresh_garage_row —
# same camera position, no view/scene change): the TOP level (Back / Drive /
# Garage / Mystery Box (N)) and, after pressing Drive, the DRIVE level (Back /
# Career / Free Roam / Online). _garage_showing_drive tracks which is current;
# entering the GARAGE view always resets to the top level (_go_to's View.GARAGE case).
var _garage_cursor := ButtonCursor.new()
var _garage_focus := 1          # which garage action the cursor sits on (defaults to Drive)
var _garage_showing_drive := false
# Drive's index in the TOP-level row, recomputed on every rebuild (see _refresh_garage_row).
var _garage_drive_index := 1
var _garage_actions_row: HBoxContainer  # the row _refresh_garage_row rebuilds in place

# Tuning-lift overlay widgets.
var _lift_info_panel: PanelContainer  # bottom-left car description panel (hidden when a sub-menu is open)
var _lift_car_label: Label      # selected car name + stats in the bottom-left info panel
var _lift_hub_controls: HBoxContainer  # the HUB page: one row of Back + Upgrades/Tuning + Test Drive buttons
# The HUB's Back / Upgrades / Tuning / Test Drive row is a left/right ButtonCursor, same
# as the garage: hq keeps the index (_hub_focus, read by tests), the cursor the behaviour.
var _hub_cursor := ButtonCursor.new()
var _hub_focus := 1             # which hub item the cursor sits on (0 = Back, 1 = Upgrades, 2 = Tune, 3 = Test Drive)
var _lift_menu_bg: ColorRect    # the right-side panel that backs a sub-menu (TUNE/UPGRADES)
var _lift_menu_title: Label     # the sub-menu page heading ("TUNE" / "UPGRADES")
var _lift_back_button: Button   # the shared "< Back" on a sub-menu page (TUNE/UPGRADES)
var _tune_panel: TuningPanel         # the TUNE menu (sliders) — shared with the start line
var _lift_upgrades_box: UpgradesMenu  # the UPGRADES menu (shared UpgradesMenu component)


func _ready() -> void:
	_ensure_starter()
	_ensure_selection()
	# Optional cloud save can swap the whole profile out from under a live HQ (a
	# first sign-in that restores a career, or "Use cloud" on a conflict), so the
	# car park has to rebuild rather than keep showing the old collection.
	Cloud.profile_replaced.connect(_on_cloud_profile_replaced)
	# A sync conflict must reach the player wherever they are, not only if they
	# happen to open the account page — see _on_cloud_conflict_detected.
	Cloud.conflict_detected.connect(_on_cloud_conflict_detected)
	# Dev profiling loop: with ?bench=1 in the web URL, boot straight into the
	# benchmark (skip building HQ we'd immediately discard). Paired with the page's
	# reload-listener (export_presets head_include) + the LAN collector, this lets a
	# dev iterate on the phone with no taps: rebuild → page reloads → benchmark runs
	# → results POST back. Gated on the URL param so it can never ship on by default.
	if _should_autostart_benchmark():
		_apply_bench_sweep_config()
		Benchmark.start()
		return
	# Headless (the test runner): build synchronously so tests see a ready HQ after one
	# frame, with no loading cover. A real display gets the covered build below.
	# The COVER is what headless skips — not the decision: _await_boot_pull runs here
	# too, and with no pull pending (the default in tests) it does not await at all, so
	# a ready HQ is still one frame away. See features/testing.md: skip the animation,
	# never the decision.
	if Platform.is_headless():
		await _await_boot_pull(null)
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
	# Let a boot-time cloud pull land BEFORE anything reads the profile, so the title
	# screen is built once from the settled career instead of being built from the
	# local one and then visibly rebuilt a second later. See _await_boot_pull.
	await _await_boot_pull(loading)
	if not is_inside_tree():
		return
	var boot_t0 := Time.get_ticks_msec()
	_build_hq()
	# _build_hq (View.EXTERIOR) kicks off _build_title_lineup, which parks the
	# player's owned-car page via the progressive, one-fresh-car-per-frame
	# _spawn_lineup_progressive. That's an async call _build_hq never awaits, so
	# without this it "returns" the instant the first uncached car yields a frame,
	# and every following per-car spawn — the actual cold-instantiate cost
	# (car.tscn embeds every car glb) — trickles out AFTER loading.finish() below,
	# landing as a stutter right when the player expects a live HQ. That's the
	# "big lag spike on first load with a lot of cars in the garage". Waiting for
	# lineup_built here keeps the whole (page_size-capped) build behind the cover,
	# where a brief wait is expected instead of in-game jank; it also warms
	# _car_cache for those cars, so the tuning lift and garage picker reuse them
	# instead of re-instancing (see _spawn_lift_car / _obtain_parked_car).
	if _view == View.EXTERIOR:
		await lineup_built
	var build_ms := Time.get_ticks_msec() - boot_t0
	_log_boot_cost(build_ms)
	# Let the built scene render one frame before lifting the cover, so the reveal lands
	# on the title shot rather than a half-built frame.
	await get_tree().process_frame
	loading.finish()
	# Warm the Free Roam picker AFTER the reveal, off the boot critical path: car.tscn
	# embeds every car glb, so building the whole-catalogue lineup is heavy and would hitch
	# the first time it's opened. It used to run here behind the cover, where it cost ~3x
	# the entire rest of HQ boot — pure time-to-first-interaction on the game's very first
	# screen. Now the player reaches an interactive HQ immediately and the warm trickles in
	# one prop per frame while they read the title (see _prewarm_free_roam_deferred).
	_prewarm_free_roam_deferred()


# True on the web build when the page URL carries ?bench=1 — the dev auto-profiling
# switch (see _ready). Reads window.location.search via JavaScriptBridge; the page's
# reload-listener preserves the query string across reloads, so the flag persists
# through the whole iterate-on-phone loop. Never true off the web build.
func _should_autostart_benchmark() -> bool:
	if not Platform.is_web() or Platform.is_headless():
		return false
	if Benchmark.active:
		return false  # already in a benchmark session (e.g. Run again) — don't recurse
	var search := str(JavaScriptBridge.eval("window.location.search", true))
	return search.find("bench=1") != -1


# Dev sweep control: fetch /bench-config from the LAN collector (a synchronous XHR,
# fine at boot) and disable the benchmark toggles it names before the run starts.
# Lets a dev drive a toggle sweep remotely — write the file + reload the phone — with
# no shippable config change. Empty / missing config = full baseline (all on).
func _apply_bench_sweep_config() -> void:
	var raw := str(JavaScriptBridge.eval(
		"(function(){try{var x=new XMLHttpRequest();x.open('GET','/bench-config?t='+Date.now(),false);x.send();return x.responseText;}catch(e){return '';}})()",
		true))
	if raw.strip_edges() == "":
		return
	var data: Variant = JSON.parse_string(raw)
	if typeof(data) != TYPE_DICTIONARY:
		return
	var disabled: Array = data.get("disabled", [])
	for t in Benchmark.TOGGLES:
		var key := String(t["key"])
		Benchmark.set_option(key, not (key in disabled))
	# Two-pass spike-diagnosis mode (cold vs warm shader cache), driven from the
	# sweep config so it's controllable remotely (features/benchmark.md).
	Benchmark.two_pass = bool(data.get("two_pass", false))


# Push the dither grid + colour grade onto the PostProcess container's material, so
# the HQ's 3D world gets the same PS1 treatment as the driving stage (features/
# rendering.md → "Colour grade"). Shares GameConfig.apply_post_process with
# world.gd so the two screens can never grade differently. The station OVERLAYS are
# CanvasLayers drawn above the container and stay ungraded, exactly like the HUD.
func _apply_post_process() -> void:
	var container := get_node_or_null("PostProcess") as SubViewportContainer
	if container == null or container.material == null:
		return
	Config.data.apply_post_process(container.material as ShaderMaterial,
		Platform.is_web(), Platform.is_touch(),
		int(DisplayStretchScript.base_design_height()))


# Build the whole HQ (environment, station overlays, map pins, initial title view).
# Synchronous; the caller decides whether to cover it with a loading screen.
func _build_hq() -> void:
	_hq_built = true
	_apply_post_process()
	_env = HQEnvironment.new()
	# The pickable table / lift areas route their clicks back to hq's own handlers.
	_env.build(self, _on_table_input, _on_lift_input)
	_camera = _env.camera
	_map_table = _env.map_table
	_map_plane = _env.map_plane
	_pins_root = _env.pins_root
	_overlays = HqOverlays.new(self)
	_overlays.build_title_overlay()
	_overlays.build_garage_overlay()
	_overlays.build_table_overlay()
	_overlays.build_detail_overlay()
	_overlays.build_lift_overlay()
	_overlays.build_car_overlay()
	_overlays.build_settings_overlay()
	_overlays.build_challenge_overlay()
	# Enable 3D mouse/touch picking so the table / lift / pins receive input_event.
	get_viewport().physics_object_picking = true
	_refresh_map_pins()
	# Returning from the podium's final Continue opens straight on the GARAGE view
	# (one-shot flag set by podium.gd); a normal boot opens the exterior title.
	# Read + clear it now so it never lingers past this boot.
	var want_garage: bool = RallySession.return_to_garage
	RallySession.return_to_garage = false
	# Boot to the garage (returning from a rally) or the title shot. The collection is
	# unbounded, so there's no garage-full gate to clear first.
	_go_to(View.GARAGE if want_garage else View.EXTERIOR, true)
	# Playing the WEB build in an Android browser: point the player at the itch.io
	# APK once per boot — the native build performs far better than mobile web.
	# Only over the title shot (a normal boot).
	if _should_show_android_app_notice() and _view == View.EXTERIOR:
		_show_android_app_notice()
	# Web fullscreen/landscape (the "tap to play" prompt) is handled globally by the
	# WebFullscreen autoload so it works in every scene, including while driving.


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
# showdown pin is locked (grey/disabled, non-pickable) until every other rally is done,
# and any rally whose reveal_after (global reveal order) isn't met yet is locked
# the same way — a "coming up" hint (see RallyLibrary.rally_revealed).
func _refresh_map_pins() -> void:
	_table_targets_cache = null  # pins are being rebuilt — force a fresh target set
	for c in _pins_root.get_children():
		c.queue_free()
	_pins = []
	var cfg: GameConfig = Config.data
	# One world map, loaded once — there is no per-region map any more.
	_map_plane.material_override = PS1Material.unshaded(load(RegionLibrary.DEFAULT_MAP_IMAGE))
	var p: Vector3 = cfg.hq_table_pos
	var size: Vector2 = cfg.hq_map_plane_size
	var top_y := p.y + cfg.hq_table_size.y + 0.02
	for rally in RallyLibrary.all():
		var pin := _make_pin(rally, p, size, top_y)
		_pins_root.add_child(pin)
		_pins.append(pin)
	# Re-seat the cursor on whatever pin sits nearest the view centre (no camera
	# pan) so it never sits at -1 while the table actually has pins to focus —
	# every entry point into the table (fresh open, test harness) goes through here.
	_select_target_under_center()
	_refresh_meter()


func _make_pin(rally: Dictionary, table_pos: Vector3, plane_size: Vector2, top_y: float) -> Node3D:
	var rally_id := String(rally["id"])
	# Locked = not revealed yet: a showdown before its region's gate opens, OR a
	# non-showdown rally whose reveal_after (global reveal order) isn't met. A
	# locked pin renders grey + non-pickable — a "coming up" hint, not enterable.
	var locked: bool = not RallyLibrary.rally_revealed(rally, Save.profile)
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
	# the hover-style selection look (see _focus_table_target) without resizing the pin.
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
# Build a billboarded floating readout sprite: a content-hugging house panel centred in
# a transparent SubViewport (so only the black box shows), with `build_body` filling the
# VBox. Dimmed when `dim` (reads as disabled), and hands its panel back via the "panel"
# meta so the focus cursor / selection can repaint it.
func _build_readout_sprite(dim: bool, build_body: Callable) -> Sprite3D:
	var vp := SubViewport.new()
	vp.size = PIN_LABEL_PX
	vp.transparent_bg = true
	vp.gui_disable_input = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	vp.add_child(center)

	var panel := UITheme.panel(1.0, 14)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_child(box)

	build_body.call(box)

	UITheme.enforce(panel)  # house rules: uppercase + one font size

	var sprite := Sprite3D.new()
	sprite.add_child(vp)
	sprite.texture = vp.get_texture()
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sprite.shaded = false
	sprite.pixel_size = PIN_LABEL_PIXEL_SIZE
	sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	if dim:
		sprite.modulate = PIN_LABEL_DIM
	sprite.set_meta("panel", panel)
	return sprite


func _build_pin_label(rally_name: String, earned: int, available := true) -> Sprite3D:
	# Dimmed for a rally that can't be entered yet (locked / no eligible car), to match
	# its grey flag; hands its panel back so the pin (via _make_pin) repaints on selection.
	return _build_readout_sprite(not available, func(box: VBoxContainer) -> void:
		box.add_theme_constant_override("separation", UITheme.GAP)
		box.add_child(UITheme.title(rally_name))
		var stars := StarRow.new()
		stars.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		box.add_child(stars)
		stars.setup(earned, MAX_STARS))


# Stars earned in a rally from the player's best finish: 1st → 3, 2nd → 2, 3rd → 1,
# anything else (or never placed) → 0.
func _stars_for(rally_id: String) -> int:
	var placed := Save.best_placement(rally_id)
	if placed >= 1 and placed <= MAX_STARS:
		return MAX_STARS + 1 - placed
	return 0


# The eligibility decision for one owned `car` against `rally`, derived in ONE place so
# the pin-flag check (_has_eligible_car) and the car-park lineup (_build_eligible_lineup)
# can't drift. Returns {eligible, detune, drivetrain}: `eligible` = whether the car can
# enter at all (in-band); `detune` = the qualifying engine-detune fraction to apply
# (0.0 = none); `drivetrain` = the drive mode it must switch to (-1 = none). A car may
# need a switch, a detune, both, or neither. (There is no "underpowered but eligible"
# state — the p/w band floor makes an under-powered car ineligible outright.)
func _entry_plan(rally: Dictionary, car: Dictionary) -> Dictionary:
	var entry := CarLibrary.by_id(String(car.get("model_id", "")))
	var meta := UpgradeLibrary.effective_meta(car, entry)
	# The pw_min floor is judged at the car's MAX potential (full tune + kits enabled +
	# ballast off), so a car detuned/ballasted to fit a lower rally still qualifies for a
	# higher one it could reach by tuning up. The ceiling stays on the current meta (an
	# over-cap car detunes DOWN via _qualifying_detune_for).
	var floor_meta := UpgradeLibrary.max_potential_meta(car, entry)
	if RallyLibrary.is_eligible(rally, meta, floor_meta):
		return {"eligible": true, "detune": 0.0, "drivetrain": -1}
	var target := _switch_target_for(rally, car, meta)
	var meta_sw := meta
	if target >= 0:
		meta_sw = meta.duplicate()
		meta_sw["drive_mode"] = target
	# Switch alone qualifies?
	if target >= 0 and RallyLibrary.is_eligible(rally, meta_sw, floor_meta):
		return {"eligible": true, "detune": 0.0, "drivetrain": target}
	# Detune (on the switched-or-stock meta) qualifies, possibly stacked with a switch.
	var frac := _qualifying_detune_for(rally, car, entry, meta_sw, target)
	if frac > 0.0:
		return {"eligible": true, "detune": frac, "drivetrain": target if target >= 0 else -1}
	return {"eligible": false, "detune": 0.0, "drivetrain": -1}


# Duplicate `owned` with engine tune forced to 100% (detune undone) — the "full power"
# base the qualifying-detune prompt scales down from, so it always proposes an absolute
# slider setting regardless of the car's stored tune. Upgrades / ballast are left as-is
# (this only touches the tune); for the car's true MAX potential — full tune AND kits
# enabled AND ballast dropped, used for the pw_min floor check — see
# UpgradeLibrary.max_potential_meta.
func _detuned_to_full(owned: Dictionary) -> Dictionary:
	var full := owned.duplicate(true)
	var tuning: Dictionary = full.get("tuning", {})
	tuning["engine_detune"] = 1.0
	full["tuning"] = tuning
	return full


# effective_meta for `full`, optionally stamping a switched drive_mode on top (so a
# switch+detune stack is evaluated on the POST-switch mode). Shared meta tail.
func _meta_with_drive(full: Dictionary, entry: Dictionary, drive_override: int) -> Dictionary:
	var out := UpgradeLibrary.effective_meta(full, entry)
	if drive_override >= 0:
		out["drive_mode"] = drive_override
	return out


# Whether the player owns at least one car that can enter `rally` — drives the pin
# flag's green (raceable) vs grey (unavailable) pennant. Eligibility is in-band (the
# band floor is the power floor), so an owned eligible car is by construction
# adequately powered — there's no separate "underpowered but eligible" case to exclude.
func _has_eligible_car(rally: Dictionary) -> bool:
	for car in Save.profile.get("cars", []):
		if bool(_entry_plan(rally, car)["eligible"]):
			return true
	return false


func _refresh_meter() -> void:
	if _map_meter == null:
		return
	var total := 0
	var done := 0
	for rally in RallyLibrary.all():
		if rally["showdown"]:
			continue
		total += 1
		if Save.rally_completed(rally["id"]):
			done += 1
	_map_meter.text = "Progress: %d / %d rallies completed" % [done, total]


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


# THE MODAL PAGE SHAPE: a scrolled body with the exit control PINNED below it.
# Returns [layer, body, footer, root] — put variable-height content in `body`, put the
# control that LEAVES the page (Back / Done / Close) in `footer`, and hand `root` to
# MenuNav.attach / UITheme.enforce as before.
#
# WHY this exists, and why it isn't optional for a modal page. Every overlay here is laid
# out against a LOGICAL canvas whose height is fixed by display_stretch.gd —
# DisplayStretch.DESIGN_HEIGHT, 360 from project.godot and only 288 on the web-touch tier
# (GameConfig.viewport_height_web_touch) — while the WIDTH follows the device aspect and
# gets narrow on a phone, which makes autowrapped labels wrap to more lines. So a fixed,
# unscrolled column whose Back button is laid out AFTER the content doesn't overflow by
# device roulette: on the short tier, with a long restriction string or a server error
# spliced in, the exit is deterministically pushed off the bottom of the frame. And there
# is no second way out — `menu_back` binds Escape and gamepad B only (project.godot), so a
# touch player with the exit off-screen is simply TRAPPED in the page. Scrolling the body
# and pinning the exit outside the scroll makes that unreachable-by-construction: the
# footer is always the bottom row of the frame no matter how tall the content grows.
#
# THE PASSTHROUGH CARVE-OUT: this is for MODAL overlays only. The diegetic stations
# (garage, map table, car park) call _passthrough_overlay(), which sets
# MOUSE_FILTER_IGNORE on the root and its non-button children so taps fall through to the
# 3D Area3D pickers behind the HUD. A ScrollContainer defaults to MOUSE_FILTER_STOP and
# would eat those picks (and its drag gesture would fight the map pan), so plain
# _make_overlay stays exactly as it was — do NOT wrap a passthrough overlay in this.
func _make_modal_overlay(margin := 24.0) -> Array:
	var made := _make_overlay(margin)
	var layer: CanvasLayer = made[0]
	var root: VBoxContainer = made[1]

	var scroll := TouchScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)

	# EXPAND_FILL vertically so short content still fills (and can centre itself via
	# `alignment`) instead of collapsing to the top of the scroll viewport.
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 12)
	scroll.add_child(body)

	# The pinned exit row: a sibling BELOW the scroll, so it never moves. Controls put
	# here must be FOCUS_ALL — MenuNav drives focus across container boundaries by
	# geometry, so down-nav off the last body row lands here (the same arrangement
	# build_settings_overlay and build_lift_overlay already rely on), and
	# MenuNav._enable_scroll_follow sets follow_focus on the scroll so walking back UP
	# into the body reveals the row the cursor moved onto.
	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 8)
	root.add_child(footer)

	return [layer, body, footer, root]


# The widest a centred modal column may ask for on the CURRENT logical canvas. The frame's
# width is not a constant — it is DESIGN_HEIGHT * device_aspect / horizontal_stretch (see
# display_stretch.gd), so on the 288-high web-touch tier a 16:9 phone gives roughly 445
# logical units, and a hard-coded 460-wide column is already wider than the whole screen.
# `chrome` is the horizontal space the surrounding container costs (overlay margins, panel
# padding). Desktop keeps the authored `preferred` width; only the narrow tiers shrink.
func _modal_body_width(preferred: float, chrome := 88.0) -> float:
	var vp := get_viewport()
	if vp == null:
		return preferred
	var w := float(vp.get_visible_rect().size.x)
	if w <= 0.0:
		return preferred
	return maxf(160.0, minf(preferred, w - chrome))


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
	return UITheme.row_button(text, cb)


# A plain Label with `text` and a `font_size` override — the Label.new() + font-size +
# add-child idiom repeated across the station overlays. Deliberately NOT UITheme.label,
# which forces a role colour + uppercase (a different look). Any further overrides
# (alignment, colour, autowrap, size flags) are applied by the caller after this returns.
func _label(text: String, size: int) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", size)
	return lbl


# A quiet section heading for the rally-detail card. UITheme.enforce flattens every
# label to one size + uppercase, so a heading reads as a heading only by its dimmer
# colour and the grouping/spacing around it — not a larger font.
func _detail_heading(text: String) -> Label:
	var lbl := _label(text, 16)
	lbl.add_theme_color_override("font_color", UITheme.INK_DIM)
	return lbl


# A sidebar Label that wraps to its column width instead of drawing off the panel edge.
func _detail_wrap_label() -> Label:
	var lbl := _label("", 16)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.custom_minimum_size = Vector2(1, 0)  # don't let the longest word dictate column width
	return lbl


# A single-row "heading: value" pair — a fixed-width dim heading (_detail_heading)
# beside the value (_detail_wrap_label), added to `parent` as one HBoxContainer row.
# Used where the rally detail panel's heading-above-value-below shape (_detail_heading
# + _detail_wrap_label stacked) would cost more vertical space than the info is worth —
# the challenge screen's four sections, one line each instead of two. Returns the value
# Label for the caller to keep populating.
func _challenge_info_row(parent: VBoxContainer, heading_text: String) -> Label:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)
	var heading := _detail_heading(heading_text)
	heading.custom_minimum_size = Vector2(140, 0)
	row.add_child(heading)
	var value := _detail_wrap_label()
	row.add_child(value)
	return value


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
	# Scrolled body + pinned footer (_make_modal_overlay): this is the FIRST thing a
	# mobile-web player sees, on the short 288-high canvas, and a dismissal they can't
	# reach means they never get into the game at all.
	var made := _make_modal_overlay()
	_android_notice_layer = made[0]
	var root_box: VBoxContainer = made[1]
	var footer: HBoxContainer = made[2]
	var root: VBoxContainer = made[3]
	root_box.alignment = BoxContainer.ALIGNMENT_CENTER

	var msg := Label.new()
	msg.text = "Heads up: the browser version runs much slower on phones.\nFor smooth performance, install the free Android app from itch.io."
	msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	msg.add_theme_font_size_override("font_size", 22)
	root_box.add_child(msg)

	var get_app := Button.new()
	get_app.text = "Get the Android app"
	get_app.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	get_app.custom_minimum_size = Vector2(320, 52)
	get_app.pressed.connect(func() -> void: OS.shell_open(ANDROID_APP_URL))
	root_box.add_child(get_app)

	# "Continue in browser" is the way OUT of this notice, so it is pinned in the footer
	# rather than laid out under a message that wraps to more lines on a narrow phone.
	var stay := Button.new()
	stay.text = "Continue in browser"
	stay.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	stay.custom_minimum_size = Vector2(320, 44)
	stay.pressed.connect(_dismiss_android_app_notice)
	footer.alignment = BoxContainer.ALIGNMENT_CENTER
	footer.add_child(stay)

	MenuNav.attach(root, {first = get_app, on_back = _dismiss_android_app_notice})


func _dismiss_android_app_notice() -> void:
	if _android_notice_layer == null:
		return
	_android_notice_layer.queue_free()
	_android_notice_layer = null
	_title_layer.visible = _view == View.EXTERIOR
	_refresh_title_focus()


# --- Account overlay ---------------------------------------------------------
# The title-screen route into optional cloud save. Same AccountMenu widget the
# Settings page mounts; here it gets its own modal layer over the title so a
# returning player can sign in before touching anything else.

func _open_account_overlay() -> void:
	if _account_layer != null:
		return
	_title_layer.visible = false
	# Scrolled body + pinned Back (_make_modal_overlay). AccountMenu.rebuild splices
	# arbitrary server error text into the page, so its height is not something this
	# screen controls — the exit has to live outside the scrolling part.
	var made := _make_modal_overlay()
	_account_layer = made[0]
	var body: VBoxContainer = made[1]
	var footer: HBoxContainer = made[2]
	var root: VBoxContainer = made[3]
	body.alignment = BoxContainer.ALIGNMENT_CENTER
	# A dark backing so the account text reads over the busy 3D garage/car-park
	# behind it — same UITheme.MODAL_DIM treatment build_detail_overlay/
	# build_challenge_overlay use, just missing here until now.
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = UITheme.MODAL_DIM
	_account_layer.add_child(bg)
	_account_layer.move_child(bg, 0)

	_account_menu = AccountMenu.new()
	_account_menu.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_account_menu.custom_minimum_size = Vector2(_modal_body_width(420.0), 0)
	body.add_child(_account_menu)

	# Focusable and pinned: down-nav off the last AccountMenu row crosses the container
	# boundary into the footer by geometry, the same way build_settings_overlay's
	# bottom button is reached.
	var back := Button.new()
	back.text = "< Back"
	back.focus_mode = Control.FOCUS_ALL
	back.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	back.custom_minimum_size = Vector2(220, 44)
	back.pressed.connect(_close_account_overlay)
	footer.alignment = BoxContainer.ALIGNMENT_CENTER
	footer.add_child(back)

	UITheme.enforce(root)


func _close_account_overlay() -> void:
	if _account_layer == null:
		return
	_account_layer.queue_free()
	_account_layer = null
	_account_menu = null
	_title_layer.visible = _view == View.EXTERIOR
	_refresh_title_focus()


# --- Rally Challenge overlay (Daily/Weekly/Monthly, spec §7) -----------------
# A modal over the GARAGE, mirroring _open_account_overlay's modal-over-title shape:
# _challenge_layer built once in _ready (build_challenge_overlay), shown/hidden here
# rather than folded into the View enum / _update_overlays switch.

func _open_challenge_overlay() -> void:
	var unix_time := int(Time.get_unix_time_from_system())
	# A stale run (period rolled over since it was stored) is discarded here, before the
	# entry screen is built, so a rolled-over period shows a fresh entry rather than a
	# dead Resume button (spec §3). ChallengeSession.has_stale_run/resumable_run/
	# eligible_cars are pure static helpers (no Save dependency, testable with a
	# synthetic profile per challenge_session.gd) called through the autoload the same
	# way every other ChallengeSession call in this file is — the analyzer's "static
	# called on instance" warning is expected here, same as it would be for
	# RallySession.apply_event_config called via the RallySession autoload.
	@warning_ignore("static_called_on_instance")
	if ChallengeSession.has_stale_run(Save.profile, unix_time):
		ChallengeSession.discard_stale_run(unix_time)
	_garage_layer.visible = false
	_challenge_layer.visible = true
	_refresh_challenge_overlay()
	UITheme.enforce(_challenge_layer)
	# Land on the CURRENT kind's own tab, not just tree-order-first (which would always
	# be Daily) — re-opening after switching kind keeps the cursor on the kind you left.
	UITheme.focus_grab(_challenge_kind_button(_challenge_kind))


func _close_challenge_overlay() -> void:
	if _challenge_layer == null:
		return
	# Leaving for the garage is the cache's invalidation point: the board keeps moving,
	# so the next visit asks again rather than showing numbers from the last one.
	_challenge_cutoff_cache.clear()
	_challenge_placing_cache.clear()
	_challenge_layer.visible = false
	_garage_layer.visible = _view == View.GARAGE


# Switching kind resets any prior car-picker context and instantly re-derives the whole
# screen for the new kind — Resume is only offered when the freshly-shown kind matches
# the stored run's kind (see _refresh_challenge_overlay). Called both by a tab's
# focus_entered (keyboard/gamepad arriving on it) and directly wherever the kind needs
# setting programmatically (e.g. focusing the right tab on open).
func _select_challenge_kind(kind_str: String) -> void:
	_challenge_kind = kind_str
	_refresh_challenge_overlay()


# Ask the board where the player finished and append it to the COMPLETED row.
#
# ALWAYS LIVE, NEVER STORED. A completed record only ever refers to a period that is
# still open (the outcome map is pruned to live periods), so the field keeps growing
# and the player's position keeps moving underneath them. Caching the rank at finish
# time would show a placing that was true once and is quietly wrong now.
#
# Non-blocking on purpose: the row reads COMPLETED the instant the page opens and
# gains "- 3 of 42" when the answer arrives. This is decoration on an already-correct
# label, so it gets no CloudBusy cover — there is nothing to wait for and nothing the
# player is prevented from doing — and a failure is simply not rendered.
func _fetch_challenge_placing(period_key_str: String, stage_count: int, generation: int) -> void:
	if period_key_str == "" or stage_count <= 0:
		return
	# Already answered this visit (a tab switch, not a fresh open) — render it straight
	# away. No query, and no "Loading…" flash on a row the player has already seen.
	if _challenge_placing_cache.has(period_key_str):
		_apply_challenge_placing(_challenge_placing_cache[period_key_str])
		return
	if Cloud == null or Cloud.challenge_leaderboard == null:
		return
	# SIGNED OUT: don't ask. fetch_final_rank needs a token to find the player's own
	# row, so it can only ever answer "not ok" here — but fetch_standings_at issues
	# the board query BEFORE it discovers that, which would mean a real network round
	# trip on every visit to the page, for an answer that cannot exist.
	if not Cloud.is_signed_in():
		return
	# Say we're fetching rather than leaving the placing to pop in later. Only from
	# here — past every "we are not going to ask" guard above — so a row that will
	# never gain a placing doesn't advertise one.
	_set_challenge_completed_text("Loading…")
	var info := await Cloud.challenge_leaderboard.fetch_final_rank(period_key_str, stage_count)
	# Cached BEFORE the staleness check: the answer is valid for its period whatever is
	# on screen now, so a player who switched tabs mid-flight still gets it instantly on
	# switching back, rather than paying for the same query twice.
	if bool(info.get("ok", false)):
		_challenge_placing_cache[period_key_str] = info
	# The player can switch tabs (or leave HQ entirely) while this is in flight, so
	# check the row hasn't been rebuilt under us before writing to it — otherwise the
	# Daily's placing lands on the Weekly's row. See _challenge_refresh_generation for
	# why this is a counter and not "does the label still read what I left it at".
	if not is_inside_tree() or generation != _challenge_refresh_generation:
		return
	_apply_challenge_placing(info)


# Render a placing answer onto the COMPLETED row (shared by the live and cached paths).
func _apply_challenge_placing(info: Dictionary) -> void:
	if not is_instance_valid(_challenge_progress_label):
		return
	if not bool(info.get("ok", false)):
		# Signed out, no username, or the board is unreachable — fall back to a bare
		# COMPLETED. The placeholder is not a resting state.
		_set_challenge_completed_text("")
		return
	_set_challenge_completed_text("%d of %d" % [
		int(info.get("rank", 0)), int(info.get("total_entries", 0))])


# Write the win-condition row as "<condition>" or "<condition> - <tail>". ALWAYS
# rebuilt from _CHALLENGE_WIN_CONDITION rather than appended to whatever is on screen,
# so the transient "Loading…" can't end up cemented in front of the answer — and
# uppercased here, because UITheme.enforce only runs on the open path and this row is
# also rewritten later, asynchronously, long after that pass.
func _set_challenge_win_text(tail: String) -> void:
	if not is_instance_valid(_challenge_win_label):
		return
	var text := _CHALLENGE_WIN_CONDITION
	if tail != "":
		text += " - " + tail
	_challenge_win_label.text = UITheme.caps(text)


# Write the progress row's COMPLETED state as "COMPLETED" or "COMPLETED - <tail>".
# Same contract as _set_challenge_win_text: always rebuilt from the constant rather
# than appended to what's on screen, so the transient "Loading…" can't survive in
# front of the placing, and uppercased here because this row is rewritten
# asynchronously long after the one-shot UITheme.enforce pass.
func _set_challenge_completed_text(tail: String) -> void:
	if not is_instance_valid(_challenge_progress_label):
		return
	var text := "COMPLETED"
	if tail != "":
		text += " - " + tail
	_challenge_progress_label.text = UITheme.caps(text)


# Fill in the CURRENT time on the top-50% cut line, so the win condition reads
# "Top 50% - 1:52.24" rather than an abstract percentage the player can't aim at.
# Appended to the SAME row (no separate line) — the entry screen is a compact HUD
# readout, and a bare percentage gives nothing to chase.
#
# Never persisted, and re-asked on every fresh open of the screen, for the same reason
# the completed placing is (see _fetch_challenge_placing): the cut line MOVES as
# entrants arrive and times improve, so a number saved across sessions would be quietly
# wrong. Within ONE visit it is cached per period key (see _challenge_cutoff_cache) so
# flipping between the Daily/Weekly/Monthly tabs doesn't re-query what it just asked.
#
# Non-blocking and undecorated on failure: the row is already correct without the
# time, so there's no CloudBusy cover and an unreachable board just leaves
# "Top 50%" standing.
func _fetch_challenge_cutoff(period_key_str: String, stage_count: int, generation: int) -> void:
	if period_key_str == "" or stage_count <= 0:
		return
	# Already answered this visit (a tab switch, not a fresh open) — render it straight
	# away. No query, and no "Loading…" flash on a row the player has already seen.
	if _challenge_cutoff_cache.has(period_key_str):
		_apply_challenge_cutoff(_challenge_cutoff_cache[period_key_str])
		return
	if Cloud == null or Cloud.challenge_leaderboard == null:
		return
	# SIGNED OUT: don't ask. The board itself is world-readable (firestore.rules
	# `allow read: if true`), so this query WOULD answer — but a signed-out player
	# cannot post a checkpoint at all, so there is no cut for them to make, and asking
	# anyway means a real network round trip on every visit to this page.
	if not Cloud.is_signed_in():
		return
	# Say we're fetching rather than leaving a gap the time will pop into. Only from
	# here — past every "we are not going to ask" guard above — so a signed-out player
	# never sees a "Loading…" that resolves to nothing.
	_set_challenge_win_text("Loading…")
	var info := await Cloud.challenge_leaderboard.fetch_cutoff(period_key_str, stage_count)
	# Cached BEFORE the staleness check — see the same note in _fetch_challenge_placing.
	if bool(info.get("ok", false)):
		_challenge_cutoff_cache[period_key_str] = info
	# The player can switch tabs (or leave HQ) while this is in flight — don't land the
	# Daily's cut line on the Weekly's row. Generation, not a text comparison: the row is
	# UPPERCASED by UITheme.enforce after it is built (see _challenge_refresh_generation),
	# so matching on the text silently dropped every answer.
	if not is_inside_tree() or generation != _challenge_refresh_generation:
		return
	_apply_challenge_cutoff(info)


# Render a cut-line answer onto the win row (shared by the live and cached paths).
func _apply_challenge_cutoff(info: Dictionary) -> void:
	if not is_instance_valid(_challenge_win_label):
		return
	if not bool(info.get("ok", false)) or not bool(info.get("exists", false)):
		# Unreachable, or nobody is on the line yet (any finish currently makes it).
		# Either way the placeholder must come back off — it is not a resting state.
		_set_challenge_win_text("")
		return
	_set_challenge_win_text(UITheme.format_time(int(info.get("cutoff_ms", 0))))


# The tab button for `kind_str` (Daily/Weekly/Monthly), matched by list position —
# _challenge_kind_buttons is built in the same [DAILY, WEEKLY, MONTHLY] order every time.
func _challenge_kind_button(kind_str: String) -> Button:
	var kinds := [ChallengeLibrary.DAILY, ChallengeLibrary.WEEKLY, ChallengeLibrary.MONTHLY]
	var idx := kinds.find(kind_str)
	if idx < 0 or idx >= _challenge_kind_buttons.size():
		return null
	return _challenge_kind_buttons[idx]


# Player-facing summary of ChallengeSession._COMPLETION_REWARD — keep the two in
# step when the reward table is retuned.
const _CHALLENGE_REWARD_TEXT := {
	"daily": "2 mystery boxes",
	"weekly": "3 mystery boxes + 1 low-tier car",
	"monthly": "4 mystery boxes + 1 high-tier car",
}
const _CHALLENGE_WIN_CONDITION := "Top 50%"


# Rebuild the whole entry screen from ChallengeSession/ChallengeLibrary's current state:
# header (kind + ceiling) and the four sections (win condition, win reward, eligible
# cars, current progress), then the Start/Resume button. Every row is a short phrase,
# not a sentence — this is a HUD readout, not prose.
func _refresh_challenge_overlay() -> void:
	if _challenge_layer == null:
		return
	# Invalidate any board query still in flight for the PREVIOUS build of this screen.
	_challenge_refresh_generation += 1
	var generation := _challenge_refresh_generation
	_challenge_title_label.text = "%s Challenge" % _challenge_kind.capitalize()
	# Highlight the current kind's tab — a font-colour swap (GOLD vs. the house default)
	# rather than a toggled "pressed" look, since these buttons have no toggle_mode/press
	# state at all (no mouse interaction reaches them; see _challenge_kind_buttons).
	for btn in _challenge_kind_buttons:
		var is_current := String(btn.get_meta("challenge_kind", "")) == _challenge_kind
		btn.add_theme_color_override("font_color", UITheme.GOLD if is_current else UITheme.INK_DIM)

	var unix_time := int(Time.get_unix_time_from_system())
	var period := ChallengeLibrary.current_period(_challenge_kind, unix_time)
	var ceiling := ChallengeLibrary.ceiling_for(String(period.get("key", "")))
	_challenge_subtitle_label.text = "%d hp/t max" % int(round(ceiling))

	_set_challenge_win_text("")
	_fetch_challenge_cutoff(String(period.get("key", "")),
		int(period.get("stage_count", 0)), generation)
	_challenge_reward_label.text = str(_CHALLENGE_REWARD_TEXT.get(_challenge_kind, ""))

	@warning_ignore("static_called_on_instance")
	var resumable := ChallengeSession.resumable_run(Save.profile, unix_time)
	# Resume is only offered for the SAME kind the resumable run belongs to — switching
	# the kind while a different kind's run is stored still shows that other kind's fresh
	# Start (its own eligible cars/ceiling), not a mismatched Resume button.
	var resuming := not resumable.is_empty() and String(resumable.get("kind", "")) == _challenge_kind

	# Eligible cars — NAME them (capped + "+N more"), same as the rally pin detail
	# panel's own eligibility read-out (_eligibility_summary/_qualifying_cars_text),
	# not just a count. ChallengeSession.eligible_cars already includes the
	# detune-reachable ones, split here into ready-now vs. needs-a-tune like
	# _eligibility_summary's own "adjust" bucket.
	@warning_ignore("static_called_on_instance")
	var eligible := ChallengeSession.eligible_cars(_challenge_kind, Save.profile, unix_time)
	var ready_names: Array[String] = []
	var tune_names: Array[String] = []
	for car in eligible:
		var entry := CarLibrary.by_id(String(car.get("model_id", "")))
		if entry.is_empty():
			continue
		var meta := UpgradeLibrary.effective_meta(car, entry)
		var display_name := EngineSwap.display_name(entry, car)
		if CarLibrary.power_to_weight_hp_tonne(meta) <= ceiling:
			ready_names.append(display_name)
		else:
			tune_names.append(display_name)
	if resuming:
		# A run in progress has no choice left to make — the car was committed when it
		# started and is locked to it for the rest of the period. Listing the whole
		# eligible set here would imply you could still switch; name the ONE car you
		# actually picked instead, which also explains why it has disappeared from the
		# garage/career pickers.
		var locked := Save.get_car(int(resumable.get("car_instance_id", -1)))
		var locked_entry := CarLibrary.by_id(String(locked.get("model_id", "")))
		_challenge_eligible_label.text = EngineSwap.display_name(locked_entry, locked) \
			if not locked_entry.is_empty() else "Your locked car"
		_challenge_eligible_label.add_theme_color_override("font_color", UITheme.GOLD)
	elif eligible.is_empty():
		_challenge_eligible_label.text = "No eligible car"
		_challenge_eligible_label.add_theme_color_override("font_color", UITheme.RED)
	else:
		var text := _qualifying_cars_text(ready_names) if not ready_names.is_empty() else "None ready"
		if not tune_names.is_empty():
			text += "\nNeeds tune: %s" % _qualifying_cars_text(tune_names)
		_challenge_eligible_label.text = text
		_challenge_eligible_label.add_theme_color_override(
			"font_color", UITheme.GREEN if not ready_names.is_empty() else UITheme.GOLD)

	# Current progress — the stored run for THIS kind, if any, else this period's
	# terminal outcome. A finished period is one attempt spent: completed or DNF'd,
	# both terminal until the period rolls over, so Start stays disabled.
	@warning_ignore("static_called_on_instance")
	var outcome := ChallengeSession.period_outcome(Save.profile, String(period.get("key", "")))
	var finished := not outcome.is_empty()
	if resuming:
		var done := int(resumable.get("stage_index", 0))
		var total := int(period.get("stage_count", 0))
		# Say the run is LIVE, not just how far it got — a bare "0 / 2 stages" reads
		# identically to "not started" and gives no hint that this kind is holding a
		# car locked (which is why that car has vanished from the other pickers).
		_challenge_progress_label.text = "IN PROGRESS - %d/%d stages" % [done, total]
		_challenge_progress_label.add_theme_color_override("font_color", UITheme.GOLD)
	elif finished and bool(outcome.get("dnf", false)):
		_challenge_progress_label.text = "DNF"
		_challenge_progress_label.add_theme_color_override("font_color", UITheme.RED)
	elif finished:
		# Show COMPLETED immediately and fetch the placing LIVE — never a stored one.
		# Only live periods survive the outcome prune, so every completed record on
		# screen belongs to a board that is still open: more entrants keep arriving
		# and faster times keep pushing the player down, so a rank saved at finish
		# time is stale by construction.
		_set_challenge_completed_text("")
		_challenge_progress_label.add_theme_color_override("font_color", UITheme.GREEN)
		_fetch_challenge_placing(String(period.get("key", "")),
			int(period.get("stage_count", 0)), generation)
	else:
		_challenge_progress_label.text = "Not started"
		# Cleared explicitly: the label is reused across kind switches, so a colour
		# left over from a previous kind's IN PROGRESS/DNF would stick.
		_challenge_progress_label.remove_theme_color_override("font_color")

	_challenge_start_button.text = "Resume" if resuming else "Start"
	# A spent period can't be re-entered, however many eligible cars are sitting there.
	_challenge_start_button.disabled = not resuming and (finished or eligible.is_empty())
	UITheme.enforce(_challenge_layer)


# Start/Resume. Resume (spec §3: same kind as the stored run) calls ChallengeSession.resume
# directly — no car to pick, the locked car is already fixed. Otherwise this now OPENS the
# real 3D car park (spec §7 point 4) restricted to this kind's eligible cars, instead of
# committing straight from a focused button-list item; the car park's own Start
# (_begin_challenge_start) does the actual ChallengeSession.start + scene hand-off.
# Enter/gamepad-accept on a focused kind tab acts as Start, exactly as if the Start
# button itself had focus — the player shouldn't have to tab down to Start first once
# they've settled on a kind. Respects the SAME disabled gate Start does (no eligible
# car): a Button's `pressed` signal fires on activate regardless of a DIFFERENT
# button's disabled state, so that has to be checked here explicitly rather than
# relying on Godot to block it.
func _on_challenge_tab_activated() -> void:
	if not _challenge_start_button.disabled:
		_on_challenge_start_pressed()


func _on_challenge_start_pressed() -> void:
	var unix_time := int(Time.get_unix_time_from_system())
	@warning_ignore("static_called_on_instance")
	var resumable := ChallengeSession.resumable_run(Save.profile, unix_time)
	if not resumable.is_empty() and String(resumable.get("kind", "")) == _challenge_kind:
		# Resume runs the same pre-flight a fresh start does — the mobile control-scheme
		# gate applies whether or not there's a car left to pick (the car is already
		# committed, hence no select id here).
		_close_challenge_overlay()  # before the gate, so the picker isn't drawn over
		if not _start_preflight(_on_challenge_start_pressed):
			return
		if not ChallengeSession.resume(unix_time):
			return
		await _hand_off_to_challenge_scene()
		return
	_close_challenge_overlay()
	_enter_challenge_car_screen(_challenge_kind)


# Hand off to the driving scene the same way a normal rally does (_begin_rally_start): a
# loading screen, two frames for it to paint, then the scene load — gated on
# ChallengeSession.auto_load_scenes (mirrors RallySession.auto_load_scenes) so tests can
# drive start()/resume() with no scene load.
#
# world.gd already branches on ChallengeSession.is_active() when it boots (building the
# current stage's TrackGenParams from ChallengeSession.current_stage_params() and routing
# StageManager.stage_completed to ChallengeSession.report_event_result / take_pending_repair
# instead of RallySession's — spec §3's single-call-site mode branch), so this plain scene
# load is enough to hand off — no RallySession needs to be active for a challenge run.
func _hand_off_to_challenge_scene() -> void:
	# No config seating here: world.gd._ready pulls the first stage's track
	# parameters itself via DrivingContext.apply_stage_config, so this hand-off is
	# a plain scene load with no ordering dependency to forget.
	if ChallengeSession.auto_load_scenes:
		var loading := LoadingScreen.new()
		loading.set_step("Preparing challenge…")
		add_child(loading)
		await get_tree().process_frame
		await get_tree().process_frame
		get_tree().change_scene_to_file("res://main.tscn")


# Open the car park for the currently-shown challenge kind: park the eligible owned cars
# (plus any over-ceiling car a detune would fit under, tracked via _detune_needed — see
# _build_challenge_lineup) and frame the first. With none, show a hint + disable Start.
# Mirrors _enter_car_screen's shape for CarparkMode.RALLY.
func _enter_challenge_car_screen(kind_str: String) -> void:
	_carpark_mode = CarparkMode.CHALLENGE
	_challenge_kind = kind_str
	_start_button.text = "Start Challenge"
	_build_challenge_lineup(kind_str)
	var unix_time := int(Time.get_unix_time_from_system())
	var period := ChallengeLibrary.current_period(kind_str, unix_time)
	var ceiling := ChallengeLibrary.ceiling_for(String(period.get("key", "")))
	_rally_banner.text = "%s Challenge — needs <= %d hp/tonne" % [kind_str.capitalize(), int(round(ceiling))]
	_view = View.CARPARK
	_detail_open = false
	_update_overlays()
	if _eligible.is_empty():
		_show_empty_carpark("No eligible car for this challenge — none of your cars meet the ceiling.")
		return
	_no_eligible_label.visible = false
	_focus = 0
	_focus_changed(true)


# Park the owned cars ChallengeSession.eligible_cars(kind, ...) reports for `kind_str` (already
# challenge-lock-excluded per §2), tracking which of them are over the ceiling STOCK but
# reachable by lowering detune — those park looking eligible, and pressing Start pops the
# same over-limit prompt _build_eligible_lineup's rally cars use, judged with
# ChallengeSession.qualifying_detune_for (a challenge has no authored rally dict) against the
# synthetic `{"restriction": {"pw_max": ceiling}}` shape ChallengeSession itself uses
# internally.
func _build_challenge_lineup(kind_str: String) -> void:
	var unix_time := int(Time.get_unix_time_from_system())
	@warning_ignore("static_called_on_instance")
	var eligible := ChallengeSession.eligible_cars(kind_str, Save.profile, unix_time)
	var period := ChallengeLibrary.current_period(kind_str, unix_time)
	var ceiling := ChallengeLibrary.ceiling_for(String(period.get("key", "")))
	var synthetic_rally := {"restriction": {"pw_max": ceiling}}
	var filtered: Array = []
	var needs_detune := {}
	for car in eligible:
		var id := int(car.get("instance_id", -1))
		filtered.append(car)
		var entry := CarLibrary.by_id(String(car.get("model_id", "")))
		if entry.is_empty():
			continue
		var meta := UpgradeLibrary.effective_meta(car, entry)
		if CarLibrary.power_to_weight_hp_tonne(meta) > ceiling:
			@warning_ignore("static_called_on_instance")
			var frac := ChallengeSession.qualifying_detune_for(synthetic_rally, car, entry)
			if frac > 0.0:
				needs_detune[id] = frac
	_build_lineup(filtered)  # clears _detune_needed / _drivetrain_needed, repopulated below
	_detune_needed = needs_detune
	_drivetrain_needed = {}


# Commit the focused car park selection: ChallengeSession.start, then the same scene
# hand-off Resume uses. Mirrors _begin_rally_start's shape for CarparkMode.CHALLENGE.
func _begin_challenge_start() -> void:
	var owned := Save.get_car(_selected_instance_id)
	if owned.is_empty():
		return
	# The same pre-flight the career start runs (mobile control-scheme gate + select the
	# fielded car) — a challenge used to skip both.
	if not _start_preflight(_begin_challenge_start, _selected_instance_id):
		return
	var unix_time := int(Time.get_unix_time_from_system())
	if not ChallengeSession.start(_challenge_kind, owned, unix_time):
		return
	_clear_lineup()
	_selected_instance_id = -1
	_carpark_mode = CarparkMode.RALLY
	await _hand_off_to_challenge_scene()



# Build the ◄/► car-selector nav row for the car park (_build_car_overlay): a "<" prev
# button, a centred car-name label, and a ">" next button in an HBox, with prev/next
# wired to _cycle_focus(∓1). Returns [nav_row, center_label] so the caller stashes the
# label in its own member field (_car_name_label).
func _build_carpark_nav_row() -> Array:
	var nav := HBoxContainer.new()
	nav.add_theme_constant_override("separation", 8)
	var prev := Button.new()
	prev.text = "<"
	prev.focus_mode = Control.FOCUS_NONE
	prev.pressed.connect(_cycle_focus.bind(-1))
	nav.add_child(prev)
	var center := _label("", 18)
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	nav.add_child(center)
	var next := Button.new()
	next.text = ">"
	next.focus_mode = Control.FOCUS_NONE
	next.pressed.connect(_cycle_focus.bind(1))
	nav.add_child(next)
	return [nav, center]


# --- Settings page -----------------------------------------------------------


# Open the Settings page. `gate` = the mandatory pre-rally pick (bottom button starts
# the rally); otherwise it's the title-screen Settings (bottom button returns to the
# title). Always reset to the category list so each open starts at the top level.
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
# if the player didn't tap one) so we never ask again, then start the rally; otherwise
# Settings only ever opens from the title screen now, so it just returns to EXTERIOR.
func _on_settings_action() -> void:
	# Gate: the button starts the rally straight from the mobile-controls page. Make
	# sure a scheme is saved (the highlighted default if the player didn't tap one) so
	# we never ask again.
	if _settings_gate:
		if Save.get_setting(MobileControls.SETTING_KEY, null) == null:
			Save.set_setting(MobileControls.SETTING_KEY, MobileControls.DEFAULT_SCHEME)
		_settings_gate = false
		# Resume whichever start path the gate interrupted (career, challenge, free
		# roam — see _start_preflight), falling back to the career start for a gate
		# opened without one.
		var resume := _pending_start
		_pending_start = Callable()
		if resume.is_valid():
			resume.call()
		else:
			_proceed_with_start()
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
	_normalize_menus()


# Apply the design-system house rules (uppercase + one font size + fixed
# single-line button height) to every overlay. Re-run on each view change and
# after any dynamic text refresh so the rules keep holding as labels change.
func _normalize_menus() -> void:
	for layer in [_title_layer, _garage_layer, _table_layer, _detail_layer,
			_lift_layer, _car_layer, _settings_layer]:
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
	# The selected car sits on the lift whenever we're inside (garage/lift); it costs
	# nothing once frozen, so keep it around while inside and drop it otherwise. In the
	# garage it rests LOWERED on the ground; entering the bay (_enter_lift) raises it.
	#
	# ORDER MATTERS: this runs BEFORE the title lineup is built. _lift_car SHARES its
	# node with _car_cache, and _clear_lift_car hides + stows that node. Building the
	# lineup first meant the selected car was parked in a bay and then immediately
	# hidden by the clear below — and since set_selected_car promotes the selected car
	# to index 0, the FIRST slot on the title screen was always empty.
	if view == View.GARAGE:
		_ensure_lift_car()
		_lower_lift_car()
		_garage_showing_drive = false  # always land on the TOP level entering fresh
		_refresh_garage_row(true)  # seat the cursor on Drive each time we enter
	elif view == View.LIFT:
		_ensure_lift_car()  # the slow raise is triggered by _enter_lift
	elif view == View.TABLE:
		pass  # KEEP the lift car: the map table never shows the lift, but tearing the
		# prop down (and rebuilding it on the way back) landed in the very frame the
		# camera starts its flight to the table, which is exactly when a hitch is most
		# visible. It's frozen with process disabled, so leaving it standing is free —
		# and the player is one Back away from the garage that wants it again. Every
		# OTHER station still clears it below: the car park / title lineup BORROW this
		# node out of _car_cache (see _spawn_lift_car / _obtain_parked_car), so the lift
		# must hand it back before those build.
	else:
		_clear_lift_car()
	# The title screen shows the player's whole collection parked in the car park.
	if view == View.EXTERIOR:
		_build_title_lineup()
		_title_focus = _title_start_index()  # seat the cursor on Start each time
		_refresh_title_focus()
	_update_overlays()
	if view == View.CARPARK:
		return  # camera handled by _focus_changed once the lineup exists
	_move_camera_to(_station_xform(view), snap)


# The cloud replaced the local profile with a downloaded career (first sign-in on
# a new device, or "Use cloud" on a conflict). Everything on screen is now showing
# somebody else's — or an older — set of cars, so rebuild the views that read the
# profile. Without this the player signs in, their cars ARE restored, and the car
# park still shows the empty lot they started with until they quit and relaunch.
#
# Only the profile-backed views need it; the lift car is re-derived from the new
# selection, and the map pins / meter read completion counts that just changed.
func _on_cloud_profile_replaced() -> void:
	if not is_inside_tree():
		return
	# NOT YET BUILT. _ready connects this signal, then awaits the boot pull — and that
	# pull landing a downloaded career is exactly what emits profile_replaced. So on a
	# signed-in boot this fires while _pins_root / _overlays / the lineup are all still
	# null, and rebuilding them crashed on a null node. Nothing to do: _build_hq runs
	# straight after the await and constructs every one of these views from the profile
	# this signal just settled. See _await_boot_pull.
	if not _hq_built:
		return
	_car_cache.clear()  # cached nodes belong to cars that may no longer be owned
	# A download that lands while the STARTER PICKER is open (the player got there
	# before the gate was armed, or waited it out) has just given them a career.
	# Leaving the picker up would let them "choose" a second free car on top of it
	# and overwrite the restored selection, so back out to the title instead.
	if _view == View.CARPARK and _carpark_mode == CarparkMode.STARTER \
			and bool(Save.profile.get("starter_picked", false)):
		_clear_lineup()
		_carpark_mode = CarparkMode.RALLY
		_go_to(View.EXTERIOR)
		return
	if _view == View.EXTERIOR:
		# NOT the boot path any more — _await_boot_pull holds the build until the
		# initial pull has settled, so a title built at boot is already built from the
		# downloaded career. What reaches here is a profile landing MID-SESSION: a
		# first sign-in from the account page, or "Use cloud" on a conflict, both of
		# which return the player to a title showing the old collection.
		_clear_lift_car()
		_build_title_lineup()
	elif _view == View.GARAGE or _view == View.LIFT:
		_ensure_lift_car()
	_refresh_map_pins()
	_refresh_meter()


func _on_exterior_exit() -> void:
	get_tree().quit()


func _on_exterior_start() -> void:
	# RE-ENTRANCY. This used to be synchronous, so pressing Start twice was
	# impossible; the cloud-restore wait opens a window of up to
	# cloud_restore_wait_sec in which it is not. The Start button keeps keyboard
	# and gamepad focus behind the cover (LoadingScreen blocks the mouse, not
	# ui_accept), and a player looking at an unexplained wait is exactly the one
	# who presses Enter again — which would run two coroutines and, on release,
	# open two starter pickers or race a picker against a garage transition.
	if _awaiting_cloud:
		return
	# First-time players (no starter chosen yet) pick a starter car in the car park;
	# returning players go straight to the garage.
	if not bool(Save.profile.get("starter_picked", false)):
		_awaiting_cloud = true
		if _title_start_button != null:
			_title_start_button.disabled = true
		await _await_cloud_restore()
		_awaiting_cloud = false
		if is_instance_valid(_title_start_button):
			_title_start_button.disabled = false
		if not is_inside_tree():
			return
		# The pull may have landed a real career while we waited, in which case
		# there is no starter to pick — this player already has cars.
		if bool(Save.profile.get("starter_picked", false)):
			_go_to(View.GARAGE)
			return
		# The pull may instead have settled as a CONFLICT: this device and the cloud
		# both moved on, so the download was NOT applied and a real career may be
		# sitting in the cloud right now. Waiting for the pull is not enough on its
		# own — releasing the gate here would offer a starter pick anyway, and picking
		# one writes to the profile, so "keep this device" stops meaning "keep what I
		# had" and starts meaning "keep the fresh save I was just handed". Put the
		# conflict to the player instead, and only continue once it is settled.
		if ConflictPrompt.is_blocked():
			await _resolve_conflict_before_starting()
			if not is_inside_tree() or ConflictPrompt.is_blocked():
				return  # still unresolved ("Decide later") — no new career is begun
			if bool(Save.profile.get("starter_picked", false)):
				_go_to(View.GARAGE)  # "Use cloud" restored a real career
				return
		_enter_starter_pick()
	else:
		_go_to(View.GARAGE)


# Put an unresolved sync conflict to the player and WAIT for their answer, so the
# starter pick can only proceed once it is settled. Headless has no popup to show,
# so it returns immediately and the caller's is_blocked() re-check keeps the gate
# shut — the decision stays proven in tests even though the UI is skipped (the same
# rule _await_cloud_restore records: skip the animation, never the decision).
func _resolve_conflict_before_starting() -> void:
	if Platform.is_headless():
		return
	# A one-element Array, not a bool: GDScript lambdas capture by VALUE, so
	# `done = true` inside the callback would leave the outer local false and spin
	# this loop forever. An Array is a reference, so the write is visible here.
	var done := [false]
	var popup := ConflictPrompt.open(self, func() -> void: done[0] = true)
	if popup == null:
		return
	while not done[0] and is_inside_tree():
		await get_tree().process_frame


# A conflict can be raised at ANY time — at sign-in on boot, or by a background
# sync — not only while the account page happens to be open. The HQ is always in
# the tree, so it listens too and raises the same shared prompt. Without this the
# only subscriber was account_menu.gd, and a conflict detected anywhere else
# silently blocked every later push with no way for the player to find out.
func _on_cloud_conflict_detected(_summary: Dictionary) -> void:
	if not is_inside_tree() or Platform.is_headless():
		return
	# The starter-pick gate raises its own blocking prompt and owns the flow there;
	# a second one on top of it would stack two popups over the same decision.
	if _awaiting_cloud:
		return
	# NO "is my prompt already up?" LATCH HERE. That bool used to live in this file
	# and another in account_menu.gd, and neither could see the other — which is how
	# one broadcast opened two popups. ConfirmPopup.MODAL_GROUP now answers that
	# question for the whole tree, so raising unconditionally is safe: a second
	# attempt is refused at the door and returns null.
	ConflictPrompt.open(self)


# Hold the BOOT BUILD until the boot-time cloud pull has settled, so the title
# screen is built exactly once — from the career the player actually has.
#
# THE SYMPTOM. HQ boots and reveals the title in about a second; the initial pull
# is a network round trip. The title was therefore built from the LOCAL profile,
# and _on_cloud_profile_replaced rebuilt it a second or two later when the download
# landed — the player watched their garage pop in in front of them.
#
# WHO WAITS. Only a player with a stored credential: Cloud.initial_pull_pending is
# false for anyone signed out or never signed in, so they reveal immediately and
# wait for nothing. Everyone else waits for the pull's own outcome under the hard
# cap inside Cloud.await_initial_sync — success, 4xx, 5xx and a hung socket all
# settle it, so there is no path here that does not return.
#
# NO SECOND COVER. The boot LoadingScreen is already on screen when this runs, so
# this re-labels it rather than stacking a CloudBusy over it (`loading` is null
# headless, and on the mid-session paths that have no cover of their own).
#
# A CONFLICT IS NOT A RESTORE. A pull that settles as a conflict deliberately does
# not apply the download, so the title reveals against the LOCAL profile — which is
# correct, and the conflict still reaches the player: conflict_detected is connected
# in _ready above this wait, and _on_exterior_start re-checks ConflictPrompt.is_blocked
# before letting anyone start. Gating the title must not swallow the prompt.
func _await_boot_pull(loading: LoadingScreen) -> void:
	if Cloud == null or not Cloud.initial_pull_pending:
		return
	if loading != null and is_instance_valid(loading):
		loading.set_step("Restoring your cloud save…")
	await Cloud.await_initial_sync(cloud_restore_wait_sec)


# Hold the FIRST-RUN STARTER PICK — and only that — until the boot-time cloud
# pull has settled.
#
# THE RACE. Cloud._kick_off_initial_pull is deferred and costs a network round
# trip; HQ boots and reveals the title in about a second. A returning player on a
# new device can therefore press Start and be offered a starter car while their
# real career is still in flight. Picking one grants a car and calls Save.save(),
# which marks the profile UNSYNCED — so the arriving download stops being a clean
# "cloud is ahead, take it" and becomes a divergence prompt about a career they
# never actually lost, where one mis-tap discards it or overwrites the cloud copy
# with a single starter car.
#
# THE TITLE IS GATED TOO, at boot — see _await_boot_pull. This used to say that
# gating the title "would make an offline player wait for something that is never
# coming". The concern was real, the conclusion was too broad: initial_pull_pending
# is already false for anyone without a stored credential, so the narrow gate was
# available all along. This one survives because a pull can also land mid-session
# (a first sign-in from the account page), where boot is long past.
#
# GUARANTEED EXIT. A player with no stored credential has
# Cloud.initial_pull_pending false and is never gated at all. Everyone else waits
# for the pull's own outcome (success, 4xx, 5xx, or transport failure), under a
# hard cap inside Cloud.await_initial_sync. There is no path here that does not
# return.
#
# TESTABILITY. The headless guard covers ONLY the cover — the visual work. The
# decision (is a pull pending?) and the wait itself run identically headless, so
# a test can prove that this path actually waits and actually releases. A guard
# that skipped the wait too would leave the one behaviour that matters unproven;
# that mistake shipped a blank page earlier in this same session, and
# features/testing.md now records the rule: skip the animation, never the
# decision or the final state.
func _await_cloud_restore() -> void:
	if Cloud == null or not Cloud.initial_pull_pending:
		return
	# The SHARED busy cover (scripts/cloud/cloud_busy.gd), not a private one: this
	# gates progression, so it blocks, and it must look and behave like every other
	# cloud wait in the game. CloudBusy owns the headless rule (skip the visual,
	# never the await or the decision) and the minimum visible duration.
	#
	# The await stays DIRECT rather than going through CloudBusy.run_covered: this
	# call answers with a bare bool, not the {"ok", "error"} shape, and there is
	# nothing here to report — a timed-out restore is a legitimate outcome that
	# simply lets the player through.
	var busy := CloudBusy.cover(self, "Restoring your career…", "Checking your cloud save…")
	await Cloud.await_initial_sync(cloud_restore_wait_sec)
	await busy.end()


# Garage: open the car park to pick which owned car to work on. Parks the WHOLE owned
# collection and frames the currently-selected car; Select commits that car and drops
# straight into the tuning lift bay (see _select_garage_car), Back returns to the garage.
# Entered from the GARAGE action row's Garage button (see _build_garage_overlay).
func _open_garage_picker() -> void:
	_carpark_mode = CarparkMode.GARAGE
	var cars: Array = []
	for car in Save.profile.get("cars", []):
		# NO challenge-lock exclusion here. A challenge locks the RUN to the car it
		# started with; it does not reserve the car. It stays fully usable in the
		# garage, career and free roam between stages — including repairs and
		# upgrades, which the design deliberately accepts (a challenge is a time
		# competition, not a survival one).
		cars.append(car)
	# Open framed on the currently-selected car (on whatever page it lands), defaulting
	# to the first parked car.
	_build_lineup(cars, _index_of_instance(cars, Save.selected_instance_id()))
	_rally_banner.text = "Garage — pick a car"
	_no_eligible_label.visible = false
	_start_button.text = "Select Car"
	_start_button.disabled = _lineup.is_empty()
	_view = View.CARPARK
	_detail_open = false
	_update_overlays()
	# Fly (don't snap) — a tween carries the player smoothly from the garage into the
	# car-select shot.
	_focus_changed(false)


# The index of the owned car `id` within `cars`, or 0 (the first car) when not present —
# used to seat the car-park cursor on a specific car when opening a picker.
func _index_of_instance(cars: Array, id: int) -> int:
	for i in cars.size():
		if int(cars[i].get("instance_id", -1)) == id:
			return i
	return 0


# Free Roam picker Start: field the focused catalogue car for a session-less drive. The
# picker parks base-model previews (negative instance ids), so field the bare base model
# by id; an owned entry (id >= 0) would field its tuned instance instead. See _enter_free_roam.
func _start_free_roam() -> void:
	if _eligible.is_empty() or _focus >= _eligible.size():
		return
	var pick: Dictionary = _eligible[_focus]
	var id := int(pick.get("instance_id", -1))
	var model_id := "" if id >= 0 else String(pick.get("model_id", ""))
	await _launch_free_roam(id, model_id)


# Launch a session-less free-roam drive fielding the given car: an OWNED instance
# (instance_id >= 0 — e.g. Test Drive of the tuned car on the lift, which world.gd fields
# with its upgrades + saved HP) OR a bare catalogue MODEL (model_id, a not-yet-owned car
# picked in Free Roam). Writes a FRESH random seed + neutral terrain + random region
# (_prepare_free_roam) and loads the run scene. The player leaves via Pause → Quit to HQ
# (pause_menu.gd loads hq.tscn when no session is active). A random seed each time means a
# different track on every entry.
func _launch_free_roam(instance_id: int, model_id: String) -> void:
	# The same pre-flight the career and challenge starts run — free roam used to skip
	# the mobile control-scheme gate entirely. It also owns "select the fielded car",
	# which only applies to an OWNED instance here (a bare catalogue preview has none).
	if not _start_preflight(_launch_free_roam.bind(instance_id, model_id), instance_id):
		return
	_carpark_mode = CarparkMode.RALLY
	_clear_lineup()
	_selected_instance_id = -1
	_prepare_free_roam()  # may abandon a stale session, which resets the free-roam ids
	# Field by MODEL when given one (a not-yet-owned preview): normalise the instance id to
	# the -1 sentinel so it can't be mistaken for a real owned instance (RallySession's
	# contract: -1 / "" = no pick). Owned Test Drive passes a real id and no model.
	RallySession.free_roam_instance_id = instance_id if model_id == "" else -1
	RallySession.free_roam_model_id = model_id
	var loading := LoadingScreen.new()
	loading.set_step("Loading free roam…")
	add_child(loading)
	# Let the overlay paint before the synchronous scene change (mirrors _begin_rally_start).
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().change_scene_to_file("res://main.tscn")


# Config setup for free roam, split out so it's testable without a scene change: clear
# any active session, then seat a fresh random seed + the neutral free-roam landscape
# into the live Config. A random seed means a new track every entry.
#
# Free roam is SESSION-LESS, so DrivingContext.apply_stage_config (world.gd._ready)
# deliberately no-ops for it and these writes are what generation actually consumes.
# They go through the CANONICAL writer (RallySession.apply_event_config) with the rolled
# values shaped as an event dict, rather than hand-writing the handful of fields free
# roam cares about: Config.data is never reset between scenes, so every field a
# hand-written subset omitted (turn count, width, cliffiness, the terrain layers) used to
# survive from the last rally — enter free roam after a 40-turn max-cliff event and you
# got a 40-turn max-cliff free roam. Routing through the writer pins every omitted field
# to the authored baseline, so "fields the writer resets" can no longer drift from
# "fields free roam remembers to set".
func _prepare_free_roam() -> void:
	# Ensure no stale session steers world.gd down the rally path.
	if RallySession.is_active():
		RallySession.abandon()
	var cfg: GameConfig = Config.data
	# The authored baseline, for the fields free roam wants at their GLOBAL default
	# rather than at an event's default. The event_* helpers fall back to RallyLibrary
	# constants, NOT to cfg: an omitted "cliffiness" means flat and an omitted "width"
	# means RallyLibrary.DEFAULT_WIDTH, neither of which is what free roam wants — it
	# wants the game's normal cliffs and the authored road width. Pass both explicitly.
	var base: GameConfig = load(Config.CONFIG_PATH)
	# Free roam rolls a fresh landscape each entry: a random lake depth, a random
	# large-scale relief (layer-1 amplitude), and a random region. The region is drawn
	# from the whole RegionLibrary roster (not the unlocked subset — free roam is a
	# sandbox, and Greece was always reachable here), so a newly authored region shows
	# up in free roam automatically.
	RallySessionScript.apply_event_config(cfg, {
		"seed": randi(),
		"straightness": base.free_roam_straightness,
		"forestiness": base.free_roam_forestiness,
		"surface_mix": base.free_roam_tarmac_fraction,
		"cliffiness": base.cliff_amount,
		"width": base.track_width,
		"water_level": randf_range(base.free_roam_water_level_min_m, base.free_roam_water_level_max_m),
		"terrain_layer1_amplitude": randf_range(base.free_roam_relief_min, base.free_roam_relief_max),
	})
	var regions := RegionLibrary.all()
	RallySession.free_roam_region_id = "" if regions.is_empty() \
		else String(regions[randi() % regions.size()].get("id", ""))


func _enter_table() -> void:
	_detail_open = false
	_table_pan = Vector3.ZERO  # re-centre the map each time we open it
	_table_dragged = false
	_table_panning = false
	_refresh_map_pins()  # reflect any newly-earned stars / showdown unlock
	# On entry, steer straight to the toughest event the player hasn't finished yet:
	# focus (and pan the camera to) the highest-difficulty incomplete rally pin. From
	# there the player pans the camera and selection tracks the view centre. Falls back
	# to the centre-nearest target when every pin is done (or there are none).
	if not _focus_hardest_incomplete():
		_select_target_under_center()
	_go_to(View.TABLE)


# The pins a keyboard/gamepad cursor can land on: the unlocked ones, in rally order
# (the locked showdown pin is skipped — it's non-pickable until everything else is done).
func _unlocked_pins() -> Array:
	var out: Array = []
	for pin in _pins:
		if not bool(pin.get_meta("locked", false)):
			out.append(pin)
	return out


# Every focus target on the table right now: the unlocked pins. There is one world map
# with every rally on it, so pins are the only kind of target.
# Each entry: {node, kind, pos}; kind is always "pin".
# Cached (see _table_targets_cache): rebuilt only when the cache is invalidated by a pin
# rebuild, so the per-frame pan glide doesn't re-allocate it.
func _table_targets() -> Array:
	if _table_targets_cache == null:
		_table_targets_cache = _build_table_targets()
	return _table_targets_cache


func _build_table_targets() -> Array:
	var out: Array = []
	for pin in _unlocked_pins():
		out.append({"node": pin, "kind": "pin", "pos": (pin as Node3D).position})
	return out


# The table's on-screen up/right directions as world vectors in the (flat) XZ plane.
# The table camera is fixed and never rotated/tilted much, so these are effectively
# constant; deriving them from the cam pose keeps up = "away into the screen" and
# right = 90° clockwise of it, matching what the player sees. Returns [up, right].
func _table_plane_axes() -> Array:
	var cfg: GameConfig = Config.data
	var fwd: Vector3 = cfg.hq_table_cam_look - cfg.hq_table_cam_eye
	fwd.y = 0.0
	var up := fwd.normalized() if fwd.length() > 0.001 else Vector3(0.0, 0.0, -1.0)
	var right := Vector3(-up.z, 0.0, up.x)  # up rotated -90° about Y (world +X when up = -Z)
	return [up, right]


# Poll the held menu directions each frame and glide the table camera smoothly while
# any are down (no discrete jumps — hold a direction and the map slides under a fixed
# reticle). Only active in the TABLE view with the detail panel closed.
func _process(delta: float) -> void:
	if _view != View.TABLE or _detail_open:
		return
	var dir2 := Vector2.ZERO
	if Input.is_action_pressed("menu_up"):
		dir2 += Vector2.UP
	if Input.is_action_pressed("menu_down"):
		dir2 += Vector2.DOWN
	if Input.is_action_pressed("menu_left"):
		dir2 += Vector2.LEFT
	if Input.is_action_pressed("menu_right"):
		dir2 += Vector2.RIGHT
	if dir2 != Vector2.ZERO:
		_pan_table_step(dir2, Config.data.hq_table_pan_glide * delta)


# Slide the table camera `dist` world-metres in screen-direction `dir2` (UP/DOWN/LEFT/
# RIGHT, or a diagonal sum), then snap selection to whichever target now sits nearest
# the view centre. The player drives the camera directly; the "cursor" is just whatever
# the camera reticle is pointed at, so there are no discrete jumps between pins. Both the
# held-glide (_process, dist = speed·delta) and tests drive this.
func _pan_table_step(dir2: Vector2, dist: float) -> void:
	if dir2 == Vector2.ZERO or dist <= 0.0:
		return
	var cfg: GameConfig = Config.data
	var axes := _table_plane_axes()
	# Godot's Vector2.UP/DOWN use screen convention (y+ = down), so the y term is
	# negated to line up with axes[0] ("up" as a world-space direction).
	var want: Vector3 = axes[1] * dir2.x - axes[0] * dir2.y
	if want.length() < 0.001:
		return
	want = want.normalized()
	var half := cfg.hq_map_plane_size
	_table_pan.x = clampf(_table_pan.x + want.x * dist, -half.x * 0.5, half.x * 0.5)
	_table_pan.z = clampf(_table_pan.z + want.z * dist, -half.y * 0.5, half.y * 0.5)
	if _view == View.TABLE:
		_move_camera_to(_station_xform(View.TABLE), true)
	_select_target_under_center()


# The map-plane point currently under the table camera's centre. The camera looks at
# hq_table_cam_look, offset by the live pan (see _station_xform), so the centre is just
# that look point shifted by _table_pan — i.e. where a ray down the camera's centre
# meets the map. Selection tracks whichever target lies nearest here.
func _table_center_pos() -> Vector3:
	var cfg: GameConfig = Config.data
	return Vector3(cfg.hq_table_cam_look.x + _table_pan.x, 0.0, cfg.hq_table_cam_look.z + _table_pan.z)


# Seat the cursor on the highest-difficulty rally pin the player hasn't completed yet,
# panning the camera to it. Difficulty is the hidden authored tier; ties break toward
# the first such pin in rally order (targets are built in that order). Completed pins are
# skipped. Returns false when there's no incomplete pin (all done, or no pins at all),
# leaving the caller to seat focus some other way.
func _focus_hardest_incomplete() -> bool:
	var targets := _table_targets()
	var best := -1
	var best_diff := -1
	for i in targets.size():
		var t: Dictionary = targets[i]
		if String(t["kind"]) != "pin":
			continue
		var rally_id := String((t["node"] as Node3D).get_meta("rally_id"))
		if Save.rally_completed(rally_id):
			continue
		var rally := RallyLibrary.by_id(rally_id)
		var diff := int(rally.get("difficulty", 0)) if not rally.is_empty() else 0
		if diff > best_diff:
			best_diff = diff
			best = i
	if best < 0:
		return false
	_focus_table_target(best, true)  # pan the camera onto it so selection sticks
	return true


# Seat the cursor on whichever pin sits nearest the view
# centre, without moving the camera (the player already put it there). This is the
# raycast-to-centre selection that keyboard pan, drag pan, and table entry all share.
func _select_target_under_center() -> void:
	var targets := _table_targets()
	if targets.is_empty():
		_table_focus_index = -1
		return
	var center := _table_center_pos()
	var best := -1
	var best_d := INF
	for i in targets.size():
		var off: Vector3 = Vector3(targets[i]["pos"]) - center
		off.y = 0.0
		var d := off.length()
		if d < best_d:
			best_d = d
			best = i
	if best >= 0:
		_focus_table_target(best, false)


# Seat the cursor on target `i`, paint the focus highlight (the hover-style readout
# underline), and (when `pan`) slide the map so the focused pin centres under the
# table camera.
func _focus_table_target(i: int, pan := true) -> void:
	var targets := _table_targets()
	if targets.is_empty():
		_table_focus_index = -1
		return
	_table_focus_index = clampi(i, 0, targets.size() - 1)
	var sel: Dictionary = targets[_table_focus_index]
	for t in targets:
		var on: bool = t == sel
		var node: Node3D = t["node"]
		if node.has_meta("label_panel"):
			UITheme.mark_panel_focused(node.get_meta("label_panel"), on)
	if pan:
		_pan_table_to(Vector3(sel["pos"]))


# Fire the focused target: open the pin's rally detail.
func _activate_table_focus() -> void:
	var targets := _table_targets()
	if _table_focus_index < 0 or _table_focus_index >= targets.size():
		return
	var t: Dictionary = targets[_table_focus_index]
	match String(t["kind"]):
		"pin":
			_on_rally_pin(String((t["node"] as Node3D).get_meta("rally_id")))


# Slide the map so `target` (a table-plane world position) centres under the table
# camera's look point, clamped to the map extents (as a finger-drag would).
func _pan_table_to(target: Vector3) -> void:
	var cfg: GameConfig = Config.data
	var half: Vector2 = cfg.hq_map_plane_size
	_table_pan.x = clampf(target.x - cfg.hq_table_cam_look.x, -half.x * 0.5, half.x * 0.5)
	_table_pan.z = clampf(target.z - cfg.hq_table_cam_look.z, -half.y * 0.5, half.y * 0.5)
	if _view == View.TABLE:
		_move_camera_to(_station_xform(View.TABLE), false)


func _on_rally_pin(rally_id: String) -> void:
	_selected_rally_id = rally_id
	_show_detail()


# Show the detail panel for the selected rally (a sub-state of the TABLE view).
func _show_detail() -> void:
	var rally := RallyLibrary.by_id(_selected_rally_id)
	# The stage COUNT is all the per-stage detail the panel shows now — it rides on the
	# title ("Coastal Sprint - 3 stages") instead of a whole left-hand column.
	var stage_count: int = (rally.get("events", []) as Array).size()
	_detail_title.text = "%s - %d %s" % [
		String(rally.get("name", "?")), stage_count,
		"stage" if stage_count == 1 else "stages"]
	var region := String(rally.get("region", ""))
	_detail_region.text = region  # UITheme.enforce uppercases it
	_detail_region.visible = region != ""
	# Difficulty is a hidden tier (it drives reward value, not anything the player
	# sees) — the eligible-car requirement is the visible gate. The showdown chip
	# replaces the old trailing "THE SHOWDOWN" body line.
	_detail_showdown.visible = bool(rally.get("showdown", false))

	# --- Eligibility: restriction + how many of the player's cars can enter.
	_detail_restriction.text = _restriction_text(rally.get("restriction", {}))
	var elig := _eligibility_summary(rally, Save.profile.get("cars", []))
	var total := int(elig["total"])
	var qualify := int(elig["qualify"])
	if total == 0:
		_detail_qualify.text = "No cars owned yet"
		_detail_qualify.add_theme_color_override("font_color", UITheme.INK_DIM)
	elif qualify == 0:
		_detail_qualify.text = "No cars qualify"
		_detail_qualify.add_theme_color_override("font_color", UITheme.RED)
	else:
		_detail_qualify.text = _qualifying_cars_text(elig["names"])
		_detail_qualify.add_theme_color_override("font_color", UITheme.GREEN)
	var adjust := int(elig["adjust"])
	_detail_adjust.visible = adjust > 0
	_detail_adjust.text = "%d need a tune / swap to fit" % adjust
	# No owned car qualifies for this rally yet — the button would only lead to an
	# empty car park, so disable it rather than let the player tap through to it.
	_detail_enter_button.disabled = qualify == 0

	# --- Record: best finish + medal stars.
	var best := Save.best_placement(_selected_rally_id)
	_detail_record.text = "Best: P%d" % best if best > 0 else "Not yet completed"
	# The star row always shows, unrun or not — an empty row of three reads as
	# "no medals yet" and keeps the record line's layout stable between rallies.
	_detail_stars.visible = true
	_detail_stars.setup(_stars_for(_selected_rally_id), MAX_STARS)

	_detail_open = true
	_view = View.TABLE
	_update_overlays()


# How many of the player's owned `cars` can enter `rally`, tallied on top of
# _entry_plan so this agrees exactly with the green/grey map pin (_has_eligible_car)
# and the car-park lineup — the ONE eligibility decision, never re-derived here.
# Returns {total, qualify, adjust, names}: `total` counts owned cars whose model still
# resolves (a removed model is skipped, not counted); `qualify` = can enter at all
# (matches the pin); `adjust` = qualify but only after a detune and/or drivetrain
# switch. `adjust` is a subset of `qualify`. `names` lists the qualifying cars' display
# names, in roster order, so the panel can name them instead of just counting them.
func _eligibility_summary(rally: Dictionary, cars: Array) -> Dictionary:
	var total := 0
	var qualify := 0
	var adjust := 0
	var names: Array[String] = []
	for car in cars:
		var entry := CarLibrary.by_id(String(car.get("model_id", "")))
		if entry.is_empty():
			continue  # a stale / removed model — not a countable car
		total += 1
		var plan := _entry_plan(rally, car)
		if not bool(plan["eligible"]):
			continue
		qualify += 1
		names.append(EngineSwap.display_name(entry, car))
		if float(plan["detune"]) > 0.0 or int(plan["drivetrain"]) >= 0:
			adjust += 1
	return {"total": total, "qualify": qualify, "adjust": adjust, "names": names}


# The qualifying-car read-out: name the cars rather than counting them. Caps the list at
# MAX_QUALIFY_NAMES and tails the rest as "+N more" so a big garage can't blow the panel
# out. Callers only reach this with a non-empty list (empty is its own RED message).
func _qualifying_cars_text(names: Array) -> String:
	if names.size() <= MAX_QUALIFY_NAMES:
		return ", ".join(names)
	var shown: Array[String] = []
	for i in MAX_QUALIFY_NAMES:
		shown.append(String(names[i]))
	return "%s, +%d more" % [", ".join(shown), names.size() - MAX_QUALIFY_NAMES]


func _hide_detail() -> void:
	_detail_open = false
	_update_overlays()


# --- Tuning lift (features/tuning.md / todo/menus.md rig 4) ----------------------

# Enter the tuning bay: raise the selected car on the lift, frame it to one side, and
# show the HUB (car description + Upgrades/Tuning buttons + Test Drive).
func _enter_lift() -> void:
	_ensure_lift_car()
	_lift_page = LiftPage.HUB
	_hub_focus = 1  # the cursor starts on Upgrades each time we enter the bay
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


# The car's CALCULATED body rest location (car.gd settled_ride_height) — how high its
# body sits above the plane its wheels rest on, settled on its own suspension. This is
# the LOWERED pose's ride height (a low sports car sits lower than a tall 4x4). Callers
# only reach the lowered pose with a car raised; the 0.0 guards a null deref and is never
# used in practice.
func _lift_car_lowered_height() -> float:
	return _lift_car.settled_ride_height() if is_instance_valid(_lift_car) else 0.0


# World-space Y of the car origin for the lowered / raised pose.
#   LOWERED — the car rests on the FLOOR (hq_lift_pos.y, the lot's y=0 collision floor)
#     at its own settled ride height: exactly how it sits parked, wheels on the ground.
#     NOT measured from the platform top — the beam tucks between the wheels, it does not
#     hold the car up when down.
#   RAISED  — the car sits on top of the beam, hq_lift_car_height above the platform top.
func _lift_car_y(raised: bool) -> float:
	var cfg: GameConfig = Config.data
	if raised:
		return cfg.hq_lift_pos.y + cfg.hq_lift_platform_size.y + cfg.hq_lift_car_height
	return cfg.hq_lift_pos.y + _lift_car_lowered_height()


# World-space Y of the platform beam's CENTRE. Lowered it rests on the floor; raised it
# climbs by the SAME delta the car climbs, so the beam stays tucked under the chassis.
func _lift_platform_y(raised: bool) -> float:
	var cfg: GameConfig = Config.data
	var base := cfg.hq_lift_pos.y + cfg.hq_lift_platform_size.y * 0.5
	var rise := _lift_car_y(true) - _lift_car_y(false)
	return base + (rise if raised else 0.0)


# Move the lift car to its current target height (_lift_raised), tweening unless
# animate is false / the time is 0. The tween is owned by HQ (not the frozen car), so
# it ticks regardless of the car's disabled process mode.
func _apply_lift_height(animate: bool) -> void:
	if not is_instance_valid(_lift_car):
		return
	var target := _lift_car_y(_lift_raised)
	var plat_target := _lift_platform_y(_lift_raised)
	var plat := _env.lift_platform if _env != null else null
	if _lift_tween != null and _lift_tween.is_valid():
		_lift_tween.kill()
	if not animate or Config.data.hq_lift_raise_time <= 0.0:
		var p := _lift_car.global_position
		p.y = target
		_lift_car.global_position = p
		_lift_car.settle_wheels_to_ground(_lift_car.ground_raycast())
		if is_instance_valid(plat):
			var pp := plat.global_position
			pp.y = plat_target
			plat.global_position = pp
		return
	_lift_tween = create_tween()
	_lift_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_lift_tween.tween_property(_lift_car, "global_position:y", target, Config.data.hq_lift_raise_time)
	# The beam rides up/down with the car (a real 2-post lift), tweened in parallel.
	if is_instance_valid(plat):
		_lift_tween.parallel().tween_property(plat, "global_position:y", plat_target, Config.data.hq_lift_raise_time)
	# Re-droop the wheels each frame as the car's Y animates: they rest on the lot floor
	# when down and extend to full droop (dangle) as the lift raises. Parallel so it runs
	# alongside the height tween; guarded in case the car frees mid-tween.
	_lift_tween.parallel().tween_method(
		func(_v: float) -> void:
			if is_instance_valid(_lift_car):
				_lift_car.settle_wheels_to_ground(_lift_car.ground_raycast()),
		0.0, 1.0, Config.data.hq_lift_raise_time)


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
	# _tune_panel and _lift_upgrades_box are unrelated Control subtypes, so assign in a
	# branch rather than a ternary (whose operands would be type-incompatible).
	var box: Control
	if page == LiftPage.TUNE:
		box = _tune_panel
	else:
		box = _lift_upgrades_box
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


# Move the title's left/right cursor between Start (0), Account (1), Settings (2)
# and Exit Game (3, non-web only), wrapping at the ends, and repaint it.
func _move_title_focus(step: int) -> void:
	_title_focus = _title_cursor.wrapped(_title_focus, step)
	_refresh_title_focus()


# Fire the title action the cursor sits on: 0 starts the run, 1 opens the Account
# overlay, 2 opens Settings, 3 (non-web) quits the game.
func _activate_title_focus() -> void:
	_title_cursor.activate(_title_focus)


# Paint the manual title cursor (EXTERIOR is a spatially-navigated 3D station like the
# garage, so Start / Account / Settings / Exit Game are highlighted by hand).
# Start's position in the title row. COMPUTED, not a literal: the row is ordered
# exit-left / proceed-right (features/menus.md → "Button order") so Start is last — but
# "Exit Game" is skipped entirely on web, so "last" is a different index per platform.
# Asked of the cursor itself (ButtonCursor.index_of), which owns the array the index
# indexes into — not the button's scene-tree child position, which only happens to agree
# today because nothing else is parented into that row.
func _title_start_index() -> int:
	return _title_cursor.index_of(_title_start_button)


func _refresh_title_focus() -> void:
	_title_cursor.refresh(_title_focus)


# Move the garage's left/right cursor across whichever level's row is currently
# showing (see _refresh_garage_row), wrapping at the ends, and repaint it.
func _move_garage_focus(step: int) -> void:
	_garage_focus = _garage_cursor.wrapped(_garage_focus, step)
	_refresh_garage_focus()


# Fire the garage action the cursor sits on.
func _activate_garage_focus() -> void:
	_garage_cursor.activate(_garage_focus)


# Paint the manual garage cursor (a spatially-navigated 3D station, so the row is
# highlighted by hand rather than via native focus).
func _refresh_garage_focus() -> void:
	_garage_cursor.refresh(_garage_focus)


# Back out of the DRIVE level to the TOP level (Back/Drive/Garage/Mystery Box) — the
# garage row's own "go up a level" action, distinct from the TOP level's Back (which
# leaves the garage station for the exterior). Pulls the camera back out to the wide
# garage framing it came from (still the same station; see _station_xform).
func _garage_back_to_top() -> void:
	_garage_showing_drive = false
	_refresh_garage_row(true)  # seat back on Drive
	_move_camera_to(_station_xform(View.GARAGE), false)


# Enter the DRIVE level (Career/Free Roam/Online): the row's contents change, and the
# camera eases in to a low 3/4 front shot of the car on the lift — no view/scene
# change, still View.GARAGE. Seats the cursor on Career (1), the primary action,
# not Back (0).
func _enter_garage_drive_level() -> void:
	_garage_showing_drive = true
	_garage_focus = 1
	_refresh_garage_row()
	_move_camera_to(_station_xform(View.GARAGE), false)


# Rebuild the garage action row's buttons + ButtonCursor for whichever level is
# current (_garage_showing_drive) — TOP: Back / Drive / Garage / Mystery Box (N);
# DRIVE: Back / Career / Free Roam / Online. Called on every level switch and
# whenever the Mystery Box button's count/enabled-state needs a repaint (e.g. after
# opening one). Frees the row's previous children each time (a plain HBoxContainer,
# not a MenuNav host, so nothing analogous to UpgradesMenu.rebuild()'s "preserve the
# MenuNav child" carve-out is needed here).
func _refresh_garage_row(seat_on_drive := false) -> void:
	for c in _garage_actions_row.get_children():
		c.queue_free()
	var buttons: Array[Button] = []
	var actions: Array[Callable] = []
	if _garage_showing_drive:
		var on_back := _garage_back_to_top
		var back := _station_button("< Back", on_back)
		_garage_actions_row.add_child(back)
		buttons.append(back); actions.append(on_back)
		# Convenience button mirroring the clickable 3D table.
		var to_table := _station_button("Career", _enter_table)
		_garage_actions_row.add_child(to_table)
		buttons.append(to_table); actions.append(_enter_table)
		# Free Roam: open the car park across the WHOLE catalogue (owned or not) and
		# drop into a session-less drive in the picked car.
		var to_free := _station_button("Free Roam", _enter_free_roam)
		_garage_actions_row.add_child(to_free)
		buttons.append(to_free); actions.append(_enter_free_roam)
		# Online: the Daily/Weekly/Monthly seeded Rally Challenge entry point (renamed
		# from "Challenge" — a modal overlay over the garage, see build_challenge_overlay
		# / _open_challenge_overlay).
		var to_online := _station_button("Online", _open_challenge_overlay)
		_garage_actions_row.add_child(to_online)
		buttons.append(to_online); actions.append(_open_challenge_overlay)
	else:
		var on_back := func() -> void: _go_to(View.EXTERIOR)
		var back := _station_button("< Back", on_back)
		_garage_actions_row.add_child(back)
		buttons.append(back); actions.append(on_back)
		# Garage: open the car park to pick which owned car to work on, then drop
		# straight into the tuning lift bay for that car (_open_garage_picker).
		var to_garage := _station_button("Garage", _open_garage_picker)
		_garage_actions_row.add_child(to_garage)
		buttons.append(to_garage); actions.append(_open_garage_picker)
		# Mystery Box: a garage-wide reward action, not per-car — moved here from the
		# Lift's Upgrades page (see _on_open_mystery_box). OMITTED entirely with none
		# held (not shown disabled) — same "hide, don't grey out" convention the row
		# used at the Lift before it moved. Disabled + explains why only when a box
		# IS held but there's nowhere for the gift to land.
		var boxes := Save.mystery_boxes_owned()
		if boxes > 0:
			var to_box := _station_button("Mystery Box (%d)" % boxes, _on_open_mystery_box)
			if not RewardSystem.any_car_has_room(Save.profile):
				to_box.disabled = true
				to_box.tooltip_text = "Every car in the garage is fully upgraded"
			else:
				to_box.tooltip_text = "Open a mystery box — fits a random upgrade to one of your cars"
			_garage_actions_row.add_child(to_box)
			buttons.append(to_box); actions.append(_on_open_mystery_box)
		# Drive LAST: it is the proceeding action, and the house order puts those on the
		# right (features/menus.md → "Button order"). It switches this SAME row to
		# Career/Free Roam/Online (_enter_garage_drive_level) — no camera move beyond the
		# level's own re-framing, no view change.
		var to_drive := _station_button("Drive", _enter_garage_drive_level)
		_garage_actions_row.add_child(to_drive)
		buttons.append(to_drive); actions.append(_enter_garage_drive_level)
		# Where Drive ended up. Mystery Box is omitted entirely when none is held, so this
		# is NOT a constant — asked of the array the cursor actually indexes into rather
		# than re-derived from the row's construction order, so adding or moving a button
		# can't silently desync it.
		_garage_drive_index = buttons.find(to_drive)
	_garage_cursor.setup(buttons, actions)
	# Seat BEFORE the settle so the row is painted once, with the right cursor. Doing this
	# in the caller instead meant this function painted a stale focus that was immediately
	# overwritten and repainted (ButtonCursor.refresh walks every button each time).
	if seat_on_drive:
		_garage_focus = _garage_drive_index
	_garage_focus = _garage_cursor.settled(_garage_focus)
	_refresh_garage_focus()
	# Freshly-built buttons start life with raw (non-uppercase) text — _normalize_menus
	# (UITheme.enforce) is what applies the house rules, and it only runs on a view
	# change/dynamic-text refresh elsewhere; a level switch (Drive <-> top) doesn't go
	# through _go_to, so it has to re-apply the rules itself here.
	_normalize_menus()


# Set the lift HUB Repair button's label + enabled state to reflect the SELECTED car's
# state: it's DISABLED (greyed, unclickable) when there's nothing to do — the car is
# already at full health, or it's damaged but no Repair Kit is owned — and only enabled
# when a kit can actually restore a damaged car. The label spells out which case it is.
# First tops up a stranded player via the safety net (a free kit when every owned car is
# wrecked), so a repairable-but-kitless player is never left permanently stuck.
func _refresh_lift_repair_button() -> void:
	if _lift_repair_button == null:
		return
	Save.ensure_repair_safety_net()
	var owned := Save.selected_car()
	var entry := CarLibrary.by_id(String(owned.get("model_id", "")))
	var max_hp := float(entry.get("max_hp", 0.0))
	var hp := float(owned.get("hp", 0.0))
	var kits := _repair_kits_owned()
	if max_hp > 0.0 and hp >= max_hp:
		_lift_repair_button.text = "Repair — full health"
		_lift_repair_button.disabled = true
	elif kits > 0:
		_lift_repair_button.text = "Repair (%d kit%s)" % [kits, "" if kits == 1 else "s"]
		_lift_repair_button.disabled = false
	else:
		_lift_repair_button.text = "Repair — no kits"
		_lift_repair_button.disabled = true


# Spend one Repair Kit on the selected car (full restore) from the lift HUB. A no-op when
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
	_refresh_lift_repair_button()


# Move the HUB's left/right cursor between Back (0), Tuning (1), Upgrades (2) and
# Test Drive (3), wrapping at the ends, and repaint it. (Repair is built but hidden while
# Repair Kits are disabled, so it's not in the cursor — see _build_lift_overlay.)
func _move_hub_focus(step: int) -> void:
	_hub_focus = _hub_cursor.wrapped(_hub_focus, step)
	_refresh_hub_focus()


# Fire the hub item the cursor sits on: 0 backs out to the garage, 1/2 open the Tuning /
# Upgrades pages, 3 launches a Test Drive (free roam with the car on the lift).
func _activate_hub_focus() -> void:
	_hub_cursor.activate(_hub_focus)


# Paint the manual hub cursor (the hub uses left/right + select, not native focus, so the
# Back / Upgrades / Tuning / Test Drive buttons are highlighted by hand instead).
func _refresh_hub_focus() -> void:
	_hub_cursor.refresh(_hub_focus)


# Seat the sub-page cursor: the body's first focusable control, or the shared Back
# button when the body has none (a fresh car's Upgrades page — see UpgradesMenu.rebuild)
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
	# The id/hash match alone is NOT enough to skip re-showing it: _lift_car shares its
	# node with _car_cache (see _spawn_lift_car), and the garage picker's parked lineup
	# borrows that very node while open (_obtain_parked_car) then HIDES + STOWS it on the
	# way out (_release_page_props / _clear_lineup, called by _select_garage_car before
	# _enter_lift). Reselecting the SAME car hits this id/hash match with the node still
	# stowed off-screen from that hide — the "car vanishes from the lift" bug. Requiring
	# `.visible` too forces the fall-through spawn path below, whose _car_cache hit just
	# reconfigures (not rebuilds) the node back onto the lift — cheap, and correct.
	if is_instance_valid(_lift_car) and _lift_car_instance_id == id and _lift_car_hash == owned_hash \
			and _lift_car.visible:
		_lift_owned = owned
		return
	_clear_lift_car()
	_lift_owned = owned
	_lift_car_instance_id = id
	_lift_car_hash = owned_hash
	_lift_car = _spawn_lift_car(owned)
	# Snap the freshly-spawned car (and its beam) to the current target pose. The provisional
	# spawn height was computed before _lift_car existed; now that it does, _apply_lift_height
	# re-derives the LOWERED pose from the car's own settled ride height and conforms its
	# wheels to the platform — a respawn while raised appears already dangling, while lowered,
	# resting at the car's true rest.
	if is_instance_valid(_lift_car):
		_apply_lift_height(false)


func _clear_lift_car() -> void:
	if _lift_tween != null and _lift_tween.is_valid():
		_lift_tween.kill()  # the tween targets the car we're about to free
	if is_instance_valid(_lift_car):
		var cached: Dictionary = _car_cache.get(_lift_car_instance_id, {})
		if cached.get("node") == _lift_car:
			# This node is also the warm _car_cache entry for this car (built or
			# borrowed via _spawn_lift_car below) — don't free it, just hide + stow it,
			# exactly like _release_page_props does for parked cars, so the car park /
			# Free Roam / a future lift visit can reuse it with no re-instancing.
			_lift_car.visible = false
			_lift_car.global_position = _prewarm_stow_marker().global_position
		else:
			_lift_car.queue_free()
	_lift_car = null
	_lift_car_instance_id = -2
	_lift_car_hash = 0


# Build (or reuse) the selected car as a silent, frozen prop on the lift platform at
# the current pose height (lowered in the garage, raised in the bay — so a re-spawn
# while raised appears already raised). Its own mesh copies, like the car-park props
# (CarProp.dup_meshes).
#
# Checks _car_cache first: this car may already be warm from the garage picker's
# parked lineup, the title lineup, or a previous lift visit (car.tscn embeds every
# car glb, so CarProp.spawn — instantiate + prune 8 unused bodies + dup_meshes — is
# the expensive step; that's the "small lag on every tuning-lift car swap" this
# avoids). GARAGE/LIFT and CARPARK views are mutually exclusive (see
# _evict_unowned_cached_cars), so borrowing a parked-lineup node for the lift, and
# handing it back on _clear_lift_car, is safe.
func _spawn_lift_car(owned: Dictionary) -> Node3D:
	var cfg: GameConfig = Config.data
	var xform := Transform3D.IDENTITY
	xform.origin = Vector3(cfg.hq_lift_pos.x, _lift_car_y(_lift_raised), cfg.hq_lift_pos.z)
	var configure := func(c) -> void: c.global_transform = xform
	var instance_id := int(owned.get("instance_id", -1))
	var owned_hash := owned.hash()
	var cached: Dictionary = _car_cache.get(instance_id, {})
	var node = cached.get("node")
	if is_instance_valid(node) and int(cached.get("hash", 0)) == owned_hash:
		# Already warm — reconfigure the cached node for lift display instead of
		# paying the full CarProp.spawn cost again. Smoke was already attached the
		# first time this node was built (spawn attaches it once; reuse never re-adds
		# it — see _obtain_parked_car / _warm_one_preview, which follow the same rule).
		configure.call(node)
		node.process_mode = Node.PROCESS_MODE_DISABLED
		node.visible = true
		return node
	if is_instance_valid(node):
		node.queue_free()
	var fresh := CarProp.spawn(self, _car_scene_res(), {
		"owned": owned,
		"configure": configure,
		"disable_process": true,
		"smoke": _add_synthetic_smoke,
	})
	_car_cache[instance_id] = {"hash": owned_hash, "node": fresh}
	return fresh


# Refresh the whole menu for the current selected car: name + stats, which menu is
# shown, the sliders' gating/values, and the upgrades list.
func _refresh_lift_ui() -> void:
	# Recover a wrecked-out player before drawing the lift: a free Repair Kit when
	# every owned car is wrecked and none is held (also checked on save load).
	Save.ensure_repair_safety_net()
	_lift_owned = Save.selected_car()
	_refresh_lift_car_label()
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
	_tune_panel.setup(_lift_owned, Callable(), _enter_wheel_swap)
	_tune_panel.refresh()
	# NO_LIMIT is deliberate and explicit, not an omitted argument: the garage isn't a
	# commitment point (nothing launches from the lift), so no p/w ceiling gate belongs
	# here — the gate lives at the start line / car park where a car is actually
	# committed to an event.
	_lift_upgrades_box.setup(_lift_owned, _on_lift_upgrade_changed, _enter_engine_swap,
		UpgradesMenu.NO_LIMIT)
	_refresh_lift_repair_button()  # reflect the selected car's health / kit count
	_hub_focus = _hub_cursor.settled(_hub_focus)  # keep the cursor on a live item
	_refresh_hub_focus()  # keep the left/right hub cursor highlight in step
	_normalize_menus()  # re-apply house rules to the freshly-built upgrade rows


# The lift's UpgradesMenu on_change: a part / drivetrain edit changed the car's spec,
# so respawn the display prop (its hash flipped) and refresh the lift name + stats to
# match — the component has already rebuilt its own rows + stats line.
func _on_lift_upgrade_changed() -> void:
	_ensure_lift_car()
	_lift_owned = Save.selected_car()
	_refresh_lift_car_label()


# Set the lift's car-label to the current owned car's display name + stats line.
func _refresh_lift_car_label() -> void:
	var entry := CarLibrary.by_id(String(_lift_owned.get("model_id", "")))
	_lift_car_label.text = "%s\n%s" % [
		EngineSwap.display_name(entry, _lift_owned), _car_stats_text(_lift_owned, entry)]


# Every owned car other than `current_id`. Used by engine-swap (_swap_targets), which
# offers the OTHER owned cars.
func _other_owned_cars(current_id: int) -> Array:
	var targets: Array = []
	for car in Save.profile.get("cars", []):
		if int(car.get("instance_id", -1)) == current_id:
			continue
		targets.append(car)
	return targets


# The owned cars this car can swap engines with: every OTHER owned car (health is
# irrelevant — a damaged partner is repaired as part of the swap). Used by
# _enter_engine_swap to build the car-park swap lineup.
func _swap_targets(current_id: int) -> Array:
	# No partners if the current car itself doesn't exist (nothing to swap into).
	if Save.get_car(current_id).is_empty():
		return []
	var out: Array = []
	for car in _other_owned_cars(current_id):
		# NO challenge-lock exclusion — see _open_garage_picker. A car fielded by an
		# active run is still a valid swap partner.
		out.append(car)
	return out


# Repair Kits currently held in the shared inventory.
func _repair_kits_owned() -> int:
	return int(Save.profile.get("inventory", {}).get(UpgradeLibrary.REPAIR_KIT_ID, 0))


# Reset the car-park overlay to its empty state: show `message`, blank the car labels,
# hide the swap-preview / warning / repair widgets, disable Start, and frame the empty
# lot. Shared by the rally car-select and Garage picker screens when nothing qualifies.
func _show_empty_carpark(message: String) -> void:
	_no_eligible_label.visible = true
	_no_eligible_label.text = message
	_car_name_label.text = ""
	_car_stats_label.text = ""
	if _swap_preview_label != null:
		_swap_preview_label.visible = false
		_swap_preview_label.text = ""
	_car_warning_label.visible = false
	_car_repair_button.visible = false
	_start_button.disabled = true
	_move_camera_to(_station_xform(View.CARPARK), true)


# Enter the car park for the chosen rally: park the ELIGIBLE owned cars (plus any
# over-powered car a detune would qualify — see _build_eligible_lineup) and frame
# the first. With none, show a hint + disable Start.
func _enter_car_screen() -> void:
	_carpark_mode = CarparkMode.RALLY
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
		_show_empty_carpark("No eligible car for this rally — win or pick a qualifying car.")
		return
	_no_eligible_label.visible = false
	_focus = 0
	_focus_changed(true)  # snaps the camera onto the first car


# Test Drive from the tuning bay: launch free roam with the car currently on the lift —
# no car picker, we're already focused on one. Fields the OWNED (tuned) instance.
func _test_drive() -> void:
	var id := Save.selected_instance_id()
	if id < 0:
		return
	await _launch_free_roam(id, "")


# Free Roam: open the car park across the WHOLE catalogue (owned cars and not) as base-
# model previews, framed on the currently-selected car's model. Start drops into a
# session-less drive in the picked car (see _start_free_roam); Back returns to the garage.
# Entered from the GARAGE action row's Free Roam button (see _build_garage_overlay).
func _enter_free_roam() -> void:
	_carpark_mode = CarparkMode.FREEROAM
	var previews := _all_car_previews()
	_build_lineup(previews, _index_of_model(previews, String(Save.selected_car().get("model_id", ""))))
	_rally_banner.text = "Free roam — pick any car"
	_no_eligible_label.visible = false
	_start_button.text = "Start Free Roam"
	_start_button.disabled = _lineup.is_empty()
	_view = View.CARPARK
	_detail_open = false
	_update_overlays()
	# Fly (don't snap) — a tween carries the player smoothly from the garage into the shot.
	_focus_changed(false)


# The index of the first preview whose model matches `model_id` within `cars`, or 0 when
# not present — used to seat the Free Roam cursor on the currently-selected car's model.
func _index_of_model(cars: Array, model_id: String) -> int:
	if model_id == "":
		return 0
	for i in cars.size():
		if String(cars[i].get("model_id", "")) == model_id:
			return i
	return 0


func _car_back() -> void:
	# Backing out of the wheel view DISCARDS the preview. Re-skin the parked car back to
	# its saved style BEFORE _clear_lineup: the node survives in _car_cache under an
	# UNCHANGED owned.hash() (nothing was saved), and the tuning lift borrows that very
	# same node — so a preview left on it would reappear on the lift. Same class of leak
	# as the "car vanishes from the lift" cache bug documented in _ensure_lift_car.
	if _carpark_mode == CarparkMode.WHEELS:
		_revert_wheel_preview()
		_wheel_options = []
		_wheel_instance_id = -1
		# Backing out MID-STREAM abandons the spawn before it emits lineup_built, so the
		# one-shot preview hook would otherwise stay connected — surviving into unrelated
		# lineup builds and erroring on the next connect. Drop it here.
		if lineup_built.is_connected(_apply_wheel_preview):
			lineup_built.disconnect(_apply_wheel_preview)
	_clear_lineup()
	_selected_instance_id = -1
	var mode := _carpark_mode
	_carpark_mode = CarparkMode.RALLY  # leaving the park in every case
	match mode:
		CarparkMode.STARTER:
			_go_to(View.EXTERIOR)
		CarparkMode.GARAGE, CarparkMode.FREEROAM:
			_go_to(View.GARAGE)
		CarparkMode.SWAP, CarparkMode.WHEELS:
			_enter_lift()
		CarparkMode.CHALLENGE:
			_go_to(View.GARAGE)
			_open_challenge_overlay()
		_:
			_go_to(View.TABLE)


# Open the car park to pick an engine-swap partner: all OTHER owned cars at full
# health (the current car is excluded — you can't swap with yourself). Confirming a
# target exchanges engines via Save.swap_engines. See features/engine-swap.md.
func _enter_engine_swap() -> void:
	_carpark_mode = CarparkMode.SWAP
	_selected_instance_id = -1  # no partner chosen yet; guards _select_swap_target
	var current_id := Save.selected_instance_id()
	var targets := _swap_targets(current_id)
	_build_lineup(targets)
	_rally_banner.text = "Engine swap"
	_start_button.text = "Swap Engine"
	_view = View.CARPARK
	_detail_open = false
	_update_overlays()
	# No partner to swap with (only one car owned) — show a hint + disable Swap instead of
	# a dead lot with an empty, no-op button (_select_swap_target bails on no selection).
	if _eligible.is_empty():
		_show_empty_carpark("No other car to swap engines with — this is your only car.")
		return
	_no_eligible_label.visible = false
	_focus = 0
	_focus_changed(true)


# Open a held mystery box: resolves + spends it as one atomic save transaction
# (Save.open_mystery_box), then shows a plain reveal card naming the winning car
# and item (or the repair-kit fallback). Deliberately NOT the race-context
# UpgradeReveal (its repair-now/drive-mode/choice branches all assume the
# revealed item belongs to the car the player just drove, which a gift to a
# DIFFERENT car would misfire) — a simple ConfirmPopup suffices here.
#
# A garage-row action (not a per-car Lift row — a mystery box isn't about the car on
# the lift, it's a garage-wide reward), and it carries no "current car" at all: ANY
# owned car with an empty slot can receive the gift, the selected one included.
func _on_open_mystery_box() -> void:
	# NEVER spend a box we can't show the result of. Opening is an irreversible save
	# transaction and the reveal below is a ConfirmPopup, which is REFUSED while another
	# modal is on screen (ConfirmPopup.MODAL_GROUP) — so opening first and revealing
	# second means a stacked press silently eats a box and its part, leaving the player
	# with no idea what they got. Check first, mutate second.
	if ConfirmPopup.any_open(get_tree()) != null:
		return
	var result := Save.open_mystery_box()
	if result.is_empty():
		return  # no box held; button should have been disabled
	# Label/value, one per line — scannable at a glance rather than a sentence.
	var body: String
	if bool(result.get("fallback", false)):
		body = "Reward: Repair Kit\nFor: no car had room for the gift"
	else:
		var recipient := Save.get_car(int(result["recipient_instance_id"]))
		var entry := CarLibrary.by_id(String(recipient.get("model_id", "")))
		var recipient_name := EngineSwap.display_name(entry, recipient)
		var item_name := String(UpgradeLibrary.by_id(String(result["item_id"])).get("name", result["item_id"]))
		body = "Reward: %s\nFor: %s\n\nInstalled disabled — enable it from that car's upgrades menu." \
			% [item_name, recipient_name]
	_refresh_garage_row()
	ConfirmPopup.open(self, "Mystery Box!", body, [{"label": "Nice", "callback": Callable()}], 0)


# Open the COSMETIC WHEEL view: the selected car ALONE in the lot (a one-element
# lineup, which the paginator centres in the bays), framed by a low side-on camera.
# left/right cycles wheel styles, previewing each live on the settled car; Start fits
# the shown one. Free and ungated, but restricted to the player's garage — only wheels
# from owned cars are on offer (plus this car's own stock wheels, always). Entered
# from the tuning lift's HUB row. See features/wheel-customization.md.
func _enter_wheel_swap() -> void:
	# _lift_owned is the authoritative car on the lift (the entry point), not merely the
	# save's selection — mirror the lift's own source of truth.
	var owned := _lift_owned
	if owned.is_empty():
		return
	_carpark_mode = CarparkMode.WHEELS
	_wheel_instance_id = int(owned.get("instance_id", -1))
	var model_id := String(owned.get("model_id", ""))
	_wheel_options = WheelStyle.options_for(model_id, Save.profile)
	_wheel_index = WheelStyle.option_index(_wheel_options, owned, model_id)
	# A ONE-CAR lineup: _render_lineup_page centres a short page in the lot, so the car
	# stands alone over a real bay with no neighbours competing for the side-on frame.
	_build_lineup([owned])
	_rally_banner.text = "Wheels"
	_start_button.text = "Fit Wheels"
	_view = View.CARPARK
	_detail_open = false
	_update_overlays()
	if _eligible.is_empty():
		_show_empty_carpark("No car to fit wheels to.")
		return
	_no_eligible_label.visible = false
	_focus = 0
	# One full _focus_changed to seat the selection / camera / damage row, then the wheel
	# label takes over the name line. Subsequent cycling deliberately does NOT re-run
	# _focus_changed (it would rev the engine and rewrite the label "1 of 1" every flick).
	_focus_changed(true)
	# The parked prop is streamed in ASYNCHRONOUSLY (_spawn_lineup_progressive awaits at
	# least a physics frame before it settles the wheels and emits), so applying the
	# preview now would run against an empty _cars. Fire it once the lot is actually built.
	# Guarded: backing out MID-STREAM abandons the spawn on its generation check, so the
	# signal never fires and the one-shot is never consumed — re-entering would then push a
	# "signal already connected" error. (_car_back also disconnects it on the way out.)
	if not lineup_built.is_connected(_apply_wheel_preview):
		lineup_built.connect(_apply_wheel_preview, CONNECT_ONE_SHOT)


# Step the wheel-style cursor and preview the new style on the parked car. Wraps both
# ways. This is what left/right drives in CarparkMode.WHEELS instead of paging bays —
# a solo lineup has no pages, so _cycle_focus hands the input here.
func _cycle_wheel(step: int) -> void:
	if _wheel_options.is_empty():
		return
	_wheel_index = posmod(_wheel_index + step, _wheel_options.size())
	_apply_wheel_preview()


# Re-skin the parked car to the cursor's style and label it. Visual only — nothing is
# saved (see _commit_wheels) and no geometry/physics/pose is touched (car.reskin_wheels).
func _apply_wheel_preview() -> void:
	# Guard the deferred (lineup_built) call: the player can back out before the lot
	# finishes streaming in, by which point there is nothing to preview onto.
	if _wheel_options.is_empty() or _carpark_mode != CarparkMode.WHEELS:
		return
	var option: Dictionary = _wheel_options[_wheel_index]
	for car in _cars:
		if is_instance_valid(car):
			car.reskin_wheels(String(option.get("texture", "")))
	_car_name_label.text = "%s  (%d of %d)" % [
		String(option.get("name", "?")), _wheel_index + 1, _wheel_options.size()]
	_car_stats_label.text = "Unlock more wheels by owning more cars."
	_normalize_menus()  # house text rules on the just-written wheel name / note


# Re-skin the parked car back to its SAVED style. Called when backing out, so an
# uncommitted preview can never persist on the shared _car_cache node (which the tuning
# lift borrows for the very same car — see _obtain_parked_car / _spawn_lift_car).
func _revert_wheel_preview() -> void:
	var owned := Save.get_car(_wheel_instance_id)
	if owned.is_empty():
		return
	var saved := WheelStyle.texture_for(owned, String(owned.get("model_id", "")))
	for car in _cars:
		if is_instance_valid(car):
			car.reskin_wheels(saved)


# Fit the shown wheels to the selected car and return to the lift. Free and ungated:
# no token, no consumable, no confirm popup. Writing the style into the owned dict
# changes owned.hash(), which invalidates the car-prop caches so the lift respawns the
# car wearing its new wheels.
func _commit_wheels() -> void:
	if _wheel_options.is_empty():
		return
	var option: Dictionary = _wheel_options[_wheel_index]
	# "Stock" commits as an ERASE (Save.set_wheels normalises), keeping the owned dict's
	# hash identical to a never-customised car.
	var id := "" if bool(option.get("stock", false)) else String(option.get("id", ""))
	Save.set_wheels(_wheel_instance_id, id)
	_wheel_options = []
	_wheel_instance_id = -1
	_clear_lineup()
	_carpark_mode = CarparkMode.RALLY
	_enter_lift()


# One PREVIEW car dict per STARTER_MODEL_IDS (not owned cars — the garage is empty),
# used both by the starter picker and by the empty-lot title backdrop. Negative
# instance ids mark them as previews rather than owned cars.
func _starter_previews() -> Array:
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
	return previews


# One PREVIEW car dict per catalogue entry (CarLibrary.all()), for the Free Roam picker
# which offers the WHOLE catalogue — owned or not. Negative instance ids mark them as
# base-model previews (no upgrades / tuning); free roam fields them by model_id.
# NOTE: these share the negative-id namespace with _starter_previews (both count from -1),
# and preview entries are now kept warm in _car_cache (never evicted — see
# _evict_unowned_cached_cars). That's safe ONLY because the two are mutually exclusive: the
# starter picker exists before the player owns any car, while the Free Roam prewarm runs
# from the GARAGE (post-ownership). If they ever coexist, give them disjoint id ranges so a
# starter preview can't collide with a prewarmed catalogue entry at the same negative id.
func _all_car_previews() -> Array:
	var previews: Array = []
	var idx := -1
	for spec in CarLibrary.all():
		previews.append({
			"instance_id": idx,  # negative: a preview, not an owned car
			"model_id": String(spec.get("id", "")),
			"hp": float(spec.get("max_hp", 1000.0)),
			"installed_upgrades": [],
			"tuning": {},
		})
		idx -= 1
	return previews


# First-run starter picker: park one PREVIEW car per STARTER_MODEL_IDS (not owned
# cars — the garage is empty) and let the player choose. Select grants that model as
# the player's first car (see _confirm_starter); Back returns to the title.
func _enter_starter_pick() -> void:
	_carpark_mode = CarparkMode.STARTER
	_build_lineup(_starter_previews())
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
	_carpark_mode = CarparkMode.RALLY
	_go_to(View.GARAGE)


# --- Car park (the eligible lineup) ------------------------------------------

# Release just the CURRENTLY-PARKED page's props + markers, cancelling any in-flight
# settle. Leaves `_lineup` and the detune/drivetrain maps intact — a page flip re-renders
# on top of the same list.
func _release_page_props() -> void:
	_settle_generation += 1  # cancel any pending settle-then-freeze for this lineup
	# Hide the parked cars rather than freeing them, so a re-entry into any lineup can
	# reuse the cached instances (see _car_cache / _build_lineup). Their frozen bodies stay
	# ray-pickable (CarProp.stop_physics), so STOW them off-screen too — otherwise a hidden
	# car left sitting in its bay would intercept a tap-to-focus ray meant for the NEW page's
	# car spawned at the same bay (_car_index_at). Reuse re-seats them via _seat_car_at_marker.
	var stow := _prewarm_stow_marker().global_position
	for car in _cars:
		if is_instance_valid(car):
			car.visible = false
			car.global_position = stow
	for marker in _markers:
		if is_instance_valid(marker):
			marker.queue_free()
	_cars = []
	_markers = []


# Full car-park teardown, used when LEAVING the lot (back / launch): release the page
# props and forget the list + cursor + per-rally detune maps.
func _clear_lineup() -> void:
	_release_page_props()
	_lineup.setup([], max(1, Config.data.carpark_page_size))
	_eligible = []
	_detune_needed = {}
	_drivetrain_needed = {}


# Free every cached (and currently active) parked car outright — used when the cache
# would otherwise leak, e.g. eviction of preview cars no longer offered. Frees the node and drops its entry.
func _free_cached_car(instance_id: int) -> void:
	var entry: Dictionary = _car_cache.get(instance_id, {})
	var node = entry.get("node")
	if is_instance_valid(node):
		node.queue_free()
	_car_cache.erase(instance_id)


# Drop cache entries for cars the player no longer owns, freeing their nodes so the cache
# doesn't outlive the collection. PREVIEW entries (negative instance_id — Free Roam's
# whole-catalogue previews, pre-warmed once and kept in memory for the session) are NEVER
# evicted here: they aren't "owned", but re-warming them is exactly the lag spike we're
# avoiding, so they persist for the HQ's lifetime (freed only with the HQ node). Entries
# in `keep` (the list currently being built) are preserved too.
func _evict_unowned_cached_cars(keep: Array = []) -> void:
	var owned_ids := {}
	for car in Save.profile.get("cars", []):
		owned_ids[int(car.get("instance_id", -1))] = true
	for car in keep:
		owned_ids[int(car.get("instance_id", -1))] = true
	for id in _car_cache.keys():
		if int(id) < 0:
			continue  # a preview / pre-warmed car — keep it warm in memory
		if not owned_ids.has(id):
			_free_cached_car(id)


# Park the owned cars ELIGIBLE for the selected rally (the car-select screen), plus
# any OVER-POWERED car a detune could fit under the rally's pw_max cap — those park
# looking eligible, and pressing Start pops the over-limit prompt routing to the
# upgrades menu (_show_over_limit_prompt / _on_start_pressed).
func _build_eligible_lineup() -> void:
	var rally := RallyLibrary.by_id(_selected_rally_id)
	var eligible: Array = []
	var needs_detune := {}
	var needs_drivetrain := {}
	for car in Save.profile.get("cars", []):
		# NO challenge-lock exclusion — see _open_garage_picker. A car fielded by an
		# active challenge run can still be entered into a career rally.
		var plan := _entry_plan(rally, car)
		if not bool(plan["eligible"]):
			continue
		eligible.append(car)
		var id := int(car.get("instance_id", -1))
		if int(plan["drivetrain"]) >= 0:
			needs_drivetrain[id] = int(plan["drivetrain"])
		if float(plan["detune"]) > 0.0:
			needs_detune[id] = float(plan["detune"])
	_build_lineup(eligible)  # clears _detune_needed / _drivetrain_needed, then repopulated below
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
	# Compare the ROUNDED hp/tonne (the figure the player actually sees) so this agrees with
	# RallyLibrary.ineligibility_reason — a car already at/under the displayed cap shouldn't
	# be treated as needing a detune.
	if CarLibrary.power_to_weight_hp_tonne(meta) <= roundi(float(r["pw_max"])):
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
	return _meta_with_drive(_detuned_to_full(owned), entry, drive_override)


# Park ALL owned cars for the title screen, so the player's whole collection is on
# show in the car park behind the title overlay (rebuilt on entering EXTERIOR). A
# fresh player (no car owned yet, starter not picked) has an empty lot, so show the
# three starter cars as previews instead — the same set the starter picker offers.
func _build_title_lineup() -> void:
	var owned: Array = Save.profile.get("cars", [])
	if owned.is_empty():
		_build_lineup(_starter_previews())
	else:
		_build_lineup(owned.duplicate())


# Park the given owned cars in the painted bays, laid out as a centred row ALONG X at
# the car-park lot (GameConfig.hq_carpark_origin / menu_car_spacing), each car parked
# nose-out toward the courtyard / menu camera (+Z) so the front-3/4 framing shows its
# face with the garage behind it. Fewer cars than bays are centred within the grid so
# they stay over real bays. The cars are placed resting on their wheels and frozen at
# once (see _spawn_parked_car). Central entry for EVERY car-park screen — rally car-select,
# the garage picker, engine-swap, the starter picker, Free Roam and the title backdrop —
# each of which just hands its full car list here; CarList (_lineup) pages through it.
func _build_lineup(cars: Array, start_global := 0) -> void:
	_release_page_props()  # bumps _settle_generation, cancelling any in-flight spawn
	# A fresh list drops any per-rally over-limit maps from the previous build; the rally
	# car-select repopulates them right after (see _build_eligible_lineup).
	_detune_needed = {}
	_drivetrain_needed = {}
	# Hand the WHOLE list to the paginator and seat the cursor; it hands back one page at
	# a time. `carpark_page_size` bays per page — the list itself is unbounded.
	_lineup.setup(cars, max(1, Config.data.carpark_page_size), start_global)
	_evict_unowned_cached_cars(cars)  # drop cached nodes for cars sold since the last build
	_render_lineup_page()


# Spawn the CURRENT page of the paginator into the painted bays. Called on entry and on
# every page flip (_cycle_focus); rebuilds only the visible page's props, so a 300-car
# collection never parks more than `carpark_page_size` heavy physics props at once.
func _render_lineup_page() -> void:
	_release_page_props()
	_eligible = _lineup.page_items()
	_focus = _lineup.focus
	var cfg: GameConfig = Config.data
	var n := _eligible.size()
	var bays: int = max(1, cfg.carpark_page_size)
	var center := HQEnvironment.carpark_center()
	# Lay out the lot markers up front (cheap Marker3Ds): the camera framing and the
	# focus cursor key off _markers / _eligible, so they work immediately even while the
	# heavy car props are still streaming in below. Centre a short final page within the
	# lot so its cars stay over real bays.
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
	_spawn_lineup_progressive(_eligible, _settle_generation)


# Stream the parked car props in across frames (see _build_lineup), then let them
# settle and freeze. Bails the moment a newer lineup supersedes this one.
func _spawn_lineup_progressive(cars: Array, generation: int) -> void:
	for i in cars.size():
		if generation != _settle_generation:
			return  # a rebuild / back-out replaced this lineup mid-stream
		var car := _obtain_parked_car(cars[i], _markers[i])
		# A failed spawn (e.g. a car model/texture that couldn't load) returns null —
		# skip it rather than let the null escape into _cars or the get_meta call below,
		# which would throw and silently abort this coroutine mid-loop, leaving
		# lineup_built never emitted and the boot's `await lineup_built` (see _ready)
		# hung forever behind the loading cover.
		if car == null:
			push_warning("HQ: skipping lineup slot %d — car spawn returned null (bad model/texture?)" % i)
			continue
		_cars.append(car)
		# Both fresh and cached cars are placed frozen at rest (see _spawn_parked_car /
		# _obtain_parked_car), so there's nothing to settle. Only a freshly-instanced car
		# (heavy: physics scene + mesh duplication) is spread across a frame to avoid
		# hitching; a cached car reappears with no per-frame cost.
		if car.get_meta("lineup_fresh", false):
			await get_tree().process_frame
	if generation != _settle_generation:
		return
	# Refine the analytic seating: droop each parked car's wheels onto the actual lot
	# floor via a downward raycast. Runs after a physics frame so newly-added bodies are
	# visible to the space query; guarded so a rebuild/back-out abandons it cleanly.
	await get_tree().physics_frame
	if generation != _settle_generation:
		return
	for car in _cars:
		if is_instance_valid(car):
			car.settle_wheels_to_ground(car.ground_raycast())
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
		# body to ground level — marker y = 0 — and sink it). Reset process_mode in case
		# this node was last borrowed by the tuning lift (_spawn_lift_car disables it).
		_seat_car_at_marker(node, marker)
		node.visible = true
		node.process_mode = Node.PROCESS_MODE_INHERIT
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
# copies (see CarProp.dup_meshes) so a mixed lineup shows each at its true size. Placed with
# its wheels on the bay via the analytic rest ride height (car.gd:settled_ride_height)
# and frozen at once — no live physics to settle, so nothing to mistime or drift.
# An off-screen stow marker the pre-warmed Free Roam props seat at until Free Roam re-seats
# them at real bays. Sunk far below the lot so the hidden, frozen props never intersect the
# garage / lift cars or get ray-picked. Created lazily and kept for the HQ's lifetime.
func _prewarm_stow_marker() -> Marker3D:
	if not is_instance_valid(_prewarm_marker):
		_prewarm_marker = Marker3D.new()
		_prewarm_marker.position = Vector3(0.0, -1000.0, 0.0)
		add_child(_prewarm_marker)
	return _prewarm_marker


# Pre-warm the Free Roam picker: spawn each catalogue preview as a HIDDEN, cached parked
# prop so entering Free Roam reuses them via _obtain_parked_car with no fresh instancing —
# that first-entry build (car.tscn embeds all car glbs) is the lag spike. This is the
# SYNCHRONOUS form (one long beat); the shipped boot path uses the frame-spread
# _prewarm_free_roam_deferred instead, off the critical path. The props land in _car_cache keyed by their
# (negative) preview instance_id, exactly where _obtain_parked_car looks, and are kept for
# the session (never evicted — see _evict_unowned_cached_cars). Idempotent: a preview already
# warm (matching hash) is skipped, so a stray re-call is a cheap no-op.
func _prewarm_free_roam() -> void:
	for preview in _all_car_previews():
		_warm_one_preview(preview)
	_prewarm_complete = true


# Spawn ONE catalogue preview into _car_cache as a hidden, stowed prop. Returns true when
# it actually spawned (false = already warm, so the call was a no-op). The unit of work
# shared by _prewarm_free_roam and its deferred, frame-spread twin below.
func _warm_one_preview(preview: Dictionary) -> bool:
	var instance_id := int(preview.get("instance_id", -1))
	var preview_hash: int = preview.hash()
	var cached: Dictionary = _car_cache.get(instance_id, {})
	if is_instance_valid(cached.get("node")) and int(cached.get("hash", 0)) == preview_hash:
		return false  # already warm
	if is_instance_valid(cached.get("node")):
		cached["node"].queue_free()
	var node := _spawn_parked_car(preview, _prewarm_stow_marker())
	node.visible = false
	_car_cache[instance_id] = {"hash": preview_hash, "node": node}
	return true


# The deferred prewarm: the same work as _prewarm_free_roam, but started AFTER the loading
# cover lifts and spread one prop per frame, so HQ is interactive at the end of _build_hq
# instead of one whole prewarm later (§2.14 / E8 — the prewarm measured ~3x the rest of
# HQ boot). Each spawn is still a single indivisible beat, so the trickle isn't free: it's
# a handful of frames of hitch while the player looks at the static title shot, instead of
# a frozen boot. Awaiting a frame BETWEEN spawns also lets input and the reveal tween run.
#
# If the player opens Free Roam before this finishes, nothing breaks and nothing is
# dropped: _build_lineup goes through _obtain_parked_car, which reuses whatever is already
# warm and instances the rest on the spot (the old first-entry cost, but only for the
# not-yet-warmed remainder), and those lineup nodes land in _car_cache under the same
# key + hash, so this loop simply skips them when it resumes on the next frame.
#
# Idempotent and self-cancelling: re-entrant calls bail, and the loop stops if the HQ
# leaves the tree (exit to a race frees the node and everything it cached).
func _prewarm_free_roam_deferred() -> void:
	if _prewarm_complete or _prewarm_running:
		return
	_prewarm_running = true
	var t0 := Time.get_ticks_msec()
	var spawned := 0
	for preview in _all_car_previews():
		if not is_inside_tree():
			_prewarm_running = false
			return
		if _warm_one_preview(preview):
			spawned += 1
			await get_tree().process_frame
	_prewarm_running = false
	_prewarm_complete = true
	_log_prewarm_cost(Time.get_ticks_msec() - t0, spawned)


# --- Boot instrumentation (todo/mobile-web-performance.md §2.14) --------------------
# HQ is run/main_scene, so its _ready is the first cost every player pays, and the props
# _prewarm_free_roam parks in _car_cache stay resident for the WHOLE session — one CarProp
# per catalogue preview plus one per parked owned car, each with its own duplicated meshes
# (CarProp.dup_meshes). That trade is deliberate and documented above; these logs exist to
# MEASURE it, not to change it, because it is missing from the web build's resident-RAM
# budget and the per-car mesh copies scale linearly with the player's garage.
#
# Line format mirrors world.gd's "load stage:" / "terrain precompute:" lines so a boot log
# greps cleanly. Called only from the non-headless path in _ready, so it is silent under
# the test runner exactly like world.gd::_stage.

# Rough per-vertex byte cost of an interleaved car vertex (position + normal + tangent +
# UV, packed). Only used to turn vertex/index counts into an order-of-magnitude MB figure
# in the log below — it is an estimate label, never a budget.
const CAR_MESH_VERTEX_BYTES := 32
const CAR_MESH_INDEX_BYTES := 4


# Print HQ's boot wall-clock and the resident cost of _car_cache at the current garage
# size. Cheap: the mesh walk reads ArrayMesh surface header counts
# (surface_get_array_len / surface_get_array_index_len) — it never copies a surface array
# — and it runs once, behind the loading cover.
func _log_boot_cost(build_ms: int) -> void:
	print("hq boot stage: %-22s %5d ms" % ["build", build_ms])
	print("hq boot total: %d ms" % build_ms)


# Printed when the deferred Free Roam prewarm finishes (see _prewarm_free_roam_deferred).
# Wall-clock here spans the awaited frames, so it is NOT boot cost — it's how long after
# the reveal the cache took to fill. The resident car-cache figures follow it because the
# cache is only at full size once the warm completes.
func _log_prewarm_cost(elapsed_ms: int, spawned: int) -> void:
	print("hq prewarm (deferred, off boot path): %d props over %d ms wall-clock"
		% [spawned, elapsed_ms])
	var cost := _car_cache_mesh_cost()
	print("hq car cache: %d props (%d preview, %d owned-garage), %d meshes, ~%.2f MB mesh data (est)"
		% [cost["props"], cost["previews"], cost["props"] - cost["previews"],
			cost["meshes"], float(cost["bytes"]) / 1048576.0])


# Resident cost of _car_cache: how many props are held, how many of them are the
# never-evicted Free Roam previews (negative instance_id — see _evict_unowned_cached_cars),
# how many duplicated meshes they own, and an estimate of those meshes' vertex/index bytes.
# Returns {"props", "previews", "meshes", "bytes"}.
func _car_cache_mesh_cost() -> Dictionary:
	var out := {"props": 0, "previews": 0, "meshes": 0, "bytes": 0}
	for id in _car_cache:
		var node = _car_cache[id].get("node")
		if not is_instance_valid(node):
			continue
		out["props"] += 1
		if int(id) < 0:
			out["previews"] += 1
		for child in node.find_children("*", "MeshInstance3D", true, false):
			# ArrayMesh only: the car glbs import as ArrayMesh, and primitives (if any ever
			# appear) carry no surface-array counts to read cheaply, so they're skipped
			# rather than guessed at. That keeps this an under-estimate, never an over-one.
			var mesh := (child as MeshInstance3D).mesh as ArrayMesh
			if mesh == null:
				continue
			out["meshes"] += 1
			for s in mesh.get_surface_count():
				out["bytes"] += (mesh.surface_get_array_len(s) * CAR_MESH_VERTEX_BYTES
					+ mesh.surface_get_array_index_len(s) * CAR_MESH_INDEX_BYTES)
	return out


func _spawn_parked_car(owned: Dictionary, marker: Marker3D) -> Node3D:
	# Frozen prop resting at its pose: no body integration and no per-frame car script
	# (drivetrain/steering/aero) cost. We stop physics processing (stop_physics) rather
	# than fully PROCESS_MODE_DISABLE the node so the body stays a normal member of the
	# physics space — it must remain ray-pickable for tap-to-focus (see _car_index_at).
	var configure := func(c) -> void: _seat_car_at_marker(c, marker)
	return CarProp.spawn(self, _car_scene_res(), {
		"owned": owned,
		"configure": configure,
		"stop_physics": true,
		"smoke": _add_synthetic_smoke,
	})


# Seat a car on its bay marker with its wheels on the ground: the marker's pose (bay
# position + facing) lifted by the car's analytic resting ride height. Shared by fresh
# spawns and cache reuse so both sit identically on their suspension at any bay.
func _seat_car_at_marker(car: Node, marker: Marker3D) -> void:
	car.global_transform = marker.global_transform
	car.global_position += Vector3.UP * car.settled_ride_height()
	car.settle_wheel_visuals()  # frozen prop: droop the wheels to their live rest pose


# Give a damaged display car (car park / lift) its own synthetic engine smoke — the
# frozen prop's engine never runs, so EngineSmoke self-times puffs from the car's
# damage severity instead of misfire cutouts. Parented to the CAR (so it's freed with
# it) but top_level (world-space render, ignoring the car transform, like the event
# pool at the scene root) and PROCESS_MODE_ALWAYS (keeps puffing though the car is
# frozen / process-disabled). Skipped for a healthy car (severity 0 = no smoke).
func _add_synthetic_smoke(car: Node) -> void:
	# Healthy display cars (no misfire severity) don't smoke; the wreck path has no
	# such gate. The shared attach handles the engine_smoke_enabled check + wiring.
	if car.get("damage") == null or car.damage.misfire_level(Config.data) <= 0.0:
		return
	EngineSmoke.attach_synthetic(car)


# Pan the focus to the prev/next car in the list (wrapping). Delegates to the paginator:
# a move within the page just re-frames; a move across a page boundary flips the page and
# re-spawns its props (snapping the camera, since the whole lineup changed). At the ends
# of the whole list it wraps around (single page → wraps in place). See scripts/car_list.gd.
func _cycle_focus(step: int) -> void:
	# The cosmetic wheel view parks ONE car, so there are no bays to page: the same
	# left/right input (plus the ◄ ► nav-row buttons and the swipe gesture, which both
	# route here) steps the WHEEL list instead. Deliberately bypasses _focus_changed —
	# the focused car never changes, and that path would rev the engine and overwrite the
	# wheel name label on every flick.
	if _carpark_mode == CarparkMode.WHEELS:
		_cycle_wheel(step)
		return
	if _lineup.is_empty():
		return
	var page_flipped := _lineup.advance(step)
	if page_flipped:
		_render_lineup_page()   # spawn the new page's props; refreshes _eligible / _focus
		_focus_changed(true)    # snap — the whole lineup just swapped out
	else:
		_focus = _lineup.focus
		_focus_changed()


# React to a focus change: make the focused car the selected car, re-aim the camera
# + stats panel at it. No respawn — every eligible car is already parked.
func _focus_changed(snap := false) -> void:
	if _eligible.is_empty():
		return
	var owned: Dictionary = _eligible[_focus]
	_selected_instance_id = int(owned.get("instance_id", -1))
	var entry := CarLibrary.by_id(String(owned.get("model_id", "")))
	# Let the player hear the focused car: rev its (possibly swapped) engine. Fires
	# on every flick and on the initial lineup show; a new rev cancels the previous.
	if not entry.is_empty():
		_preview_rev(EngineSwap.current_engine_id(owned, String(entry.get("engine", ""))))
	var stats := _car_stats_text(owned, entry)
	var display_owned: Dictionary = Save.get_car(_selected_instance_id)
	var display_name: String = (EngineSwap.display_name(entry, display_owned)
		if not display_owned.is_empty() else String(entry.get("name", owned.get("model_id", "?"))))
	# Position across the WHOLE list (all pages), not just the current page.
	_car_name_label.text = "%s  (%d of %d)" % [
		display_name, _lineup.global_index() + 1, _lineup.total()]
	_car_stats_label.text = stats
	_refresh_swap_preview()
	if _carpark_mode == CarparkMode.SWAP:
		# Picking a swap partner: no car is excluded on health; the token cost is
		# surfaced in the confirm popup, so keep Start enabled and the warning clear.
		_start_button.disabled = false
		_car_warning_label.visible = false
		_car_repair_button.visible = false
	else:
		# A wrecked focused car gates Start + offers a Repair (full restore).
		_refresh_focus_damage(owned)
	_normalize_menus()  # keep house rules on the just-updated car name / stats
	_move_camera_to(_camera_target_xform(), snap)


# Rev the focused car's engine as a short preview (lazily builds the player).
func _preview_rev(engine_id: String) -> void:
	if engine_id.is_empty():
		return
	if _preview_audio == null:
		_preview_audio = CarPreviewAudio.new()
		add_child(_preview_audio)
	_preview_audio.rev(engine_id)


# The two-way power-to-weight preview shown only while picking an engine-swap partner.
# A swap EXCHANGES engines, so it shows the resulting hp/tonne for the car on the lift
# (receiving the focused partner's engine) AND the focused partner (receiving the lift
# car's engine). Coloured ↑ gain / ↓ loss / — unchanged. Hidden in every other mode.
func _refresh_swap_preview() -> void:
	if _swap_preview_label == null:
		return
	if _carpark_mode != CarparkMode.SWAP:
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
# over-powered car looks eligible here; the over-limit prompt only surfaces as a
# confirm popup on Start (_show_over_limit_prompt).
func _refresh_focus_damage(owned: Dictionary) -> void:
	# Garage mode just picks the car for the lift, so a wrecked car is still a valid
	# pick (it can be repaired in the bay). WHEELS is purely COSMETIC — a wrecked car
	# can always be re-shod, so damage must never gate it either. Never gate Select on
	# damage in those modes; nor when the focused car isn't wrecked.
	if _carpark_mode == CarparkMode.GARAGE or _carpark_mode == CarparkMode.WHEELS \
			or not Save.car_is_wrecked(owned):
		_start_button.disabled = false
		_car_warning_label.visible = false
		_car_repair_button.visible = false
		return
	_start_button.disabled = true
	_car_warning_label.visible = true
	var kits := _repair_kits_owned()
	if kits > 0:
		_car_warning_label.text = "Too damaged to enter. Use a Repair Kit to restore it to full health and race."
		_car_repair_button.visible = true
		_car_repair_button.text = "Repair (1 kit)"
	else:
		_car_warning_label.text = "Too damaged to enter — and you have no Repair Kits. Win one, or pick another car."
		_car_repair_button.visible = false


# A full-screen dimmer + centred house panel on the car CanvasLayer, holding `body`
# built by the caller. Used for the detune prompt and the Change-Upgrades popup so both
# read as on-brand modals (black panel, sharp corners) instead of native grey dialogs.
#
# Same scrolled-body / pinned-footer contract as _make_modal_overlay (read its header for
# WHY): the caller's `build_body` fills a VBox that lives inside a TouchScrollContainer,
# and `build_footer` fills the row pinned underneath it, which is where the control that
# closes the modal belongs. The panel is capped to the frame height (not just centred on
# it) so the footer is on screen even when the body is taller than the canvas — which the
# upgrades list, on the 288-high tier, routinely is.
func _make_carpark_modal(build_body: Callable, build_footer := Callable()) -> Control:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = UITheme.MODAL_DIM
	root.add_child(dim)
	# A margined full-rect row rather than a CenterContainer: a CenterContainer hands its
	# child the child's full MINIMUM size, so a panel taller than the frame would simply
	# overhang the top and bottom of the screen — taking the pinned footer with it, which
	# is the exact failure this shape exists to prevent. The panel instead gets the frame
	# height (minus margins) as its budget and the scroll inside it absorbs the overflow.
	# Horizontally it still hugs its content and centres (SIZE_SHRINK_CENTER).
	var center := MarginContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "top", "right", "bottom"]:
		center.add_theme_constant_override("margin_" + side, 16)
	root.add_child(center)
	var row := HBoxContainer.new()
	# BoxContainer packs non-expanding children from the start, so centring is the row's
	# alignment, not a size flag on the panel.
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(row)
	var panel := UITheme.panel(1.0, 20)
	panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	row.add_child(panel)
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", UITheme.GAP)
	panel.add_child(outer)
	var scroll := TouchScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", UITheme.GAP)
	scroll.add_child(vbox)
	build_body.call(vbox)
	if build_footer.is_valid():
		var footer := VBoxContainer.new()
		footer.add_theme_constant_override("separation", UITheme.GAP)
		outer.add_child(footer)
		build_footer.call(footer)
	_car_layer.add_child(root)
	return root


# An over-powered focused car (parked because a detune would duck it under the rally's
# pw_max cap — _build_eligible_lineup) looks eligible in the car park; pressing Start
# pops this on-brand modal instead. It offers three left/right-navigable choices —
# Change Upgrades (open the gated upgrades menu, where detune / ballast / stripping parts
# brings the car under the cap — the menu won't let them leave until it's eligible) or
# Cancel. No auto-detune button: the player makes the change themselves and re-presses
# Start (the fix persists like any garage edit — see todo/detune-min-pw-interaction.md).
func _show_over_limit_prompt(_owned: Dictionary) -> void:
	_active_carpark_popup = ConfirmPopup.open(self, "Too powerful",
		"Change your upgrades to get under the power-to-weight limit.",
		[ {"label": "Cancel", "callback": _close_detune_panel},
		  {"label": "Change Upgrades", "callback": _detune_change_upgrades} ], 1, 0)


# Whether a car-park modal overlay (detune prompt / Change-Upgrades popup) is showing,
# so _unhandled_input hands navigation to its MenuNav instead of the lineup beneath.
func _carpark_modal_open() -> bool:
	return is_instance_valid(_active_carpark_popup) \
		or (_upgrades_popup != null and _upgrades_popup.visible)


func _close_detune_panel() -> void:
	_focus_changed()


# The detune prompt's Change Upgrades choice: close the prompt and open the upgrades
# menu for the focused car so the player can strip / switch parts to duck under the cap.
func _detune_change_upgrades() -> void:
	_show_upgrades_popup(Save.get_car(_selected_instance_id))


# Show the upgrades menu over the car-park car-select for the focused car, as an on-brand
# centred modal. Reuses the UpgradesMenu component with NO engine-swap row (on_swap left
# invalid — the swap flow would change the HQ view). Nav-wired so it's keyboard/gamepad
# navigable; Done / back closes it (see _close_upgrades_popup).
func _show_upgrades_popup(owned: Dictionary) -> void:
	if _upgrades_popup == null:
		_upgrades_popup = _make_carpark_modal(
			func(vbox: VBoxContainer) -> void:
				# 460 was wider than the whole logical canvas on the short web-touch tier
				# (~445 units on a 16:9 phone), so it's now the DESKTOP preference and
				# _modal_body_width clamps it to whatever the frame can actually show;
				# chrome = the panel's 20-unit padding either side plus the modal margin.
				vbox.custom_minimum_size = Vector2(_modal_body_width(460.0, 72.0), 0)
				vbox.add_child(UITheme.title("Upgrades"))
				_upgrades_popup_menu = UpgradesMenu.new()
				vbox.add_child(_upgrades_popup_menu),
			func(footer: VBoxContainer) -> void:
				# Done is the gated exit (bind_close_button below blocks it, AND back,
				# while the car is over the p/w cap). It is PINNED outside the scroll:
				# the controls the player needs in order to get under the cap are the very
				# ones that grow this list, so letting them push Done off the bottom would
				# lock a touch player inside a modal they are not allowed to leave.
				_upgrades_popup_done = Button.new()
				_upgrades_popup_done.text = "Done"
				_upgrades_popup_done.focus_mode = Control.FOCUS_ALL
				# NOTE: press is wired by bind_close_button below (gated), not here.
				footer.add_child(_upgrades_popup_done))
	_upgrades_popup_dirty = false
	_upgrades_popup.visible = true
	var pw_limit := -1.0
	if _carpark_mode == CarparkMode.CHALLENGE:
		var unix_time := int(Time.get_unix_time_from_system())
		var period := ChallengeLibrary.current_period(_challenge_kind, unix_time)
		pw_limit = ChallengeLibrary.ceiling_for(String(period.get("key", "")))
	else:
		var rally := RallyLibrary.by_id(_selected_rally_id)
		var restriction: Dictionary = rally.get("restriction", {}) if not rally.is_empty() else {}
		pw_limit = float(restriction.get("pw_max", -1.0))
	_upgrades_popup_menu.setup(owned, _on_popup_upgrade_changed, Callable(), pw_limit)
	# Gate Done + Esc/back on the rally's p/w cap: over the cap, the button goes red and
	# neither it nor MenuNav's on_back closes the popup until the player detunes under it.
	_upgrades_popup_menu.bind_close_button(_upgrades_popup_done, _close_upgrades_popup)
	UITheme.enforce(_upgrades_popup)
	MenuNav.attach(_upgrades_popup, {
		"first": _upgrades_popup_menu.first_control(),
		"on_back": _upgrades_popup_menu.request_close,
	})


# A popup upgrade edit: just flag dirty. The UpgradesMenu already repainted its own detune
# label + gated Done button (the visible feedback); the parked-car prop + lineup are rebuilt
# on close so a live rebuild can't steal focus from the popup mid-edit.
func _on_popup_upgrade_changed() -> void:
	_upgrades_popup_dirty = true


# Close the upgrades popup and return to car-select. If anything changed, rebuild the
# eligible lineup so a now-ineligible car drops out; the player re-presses Start and the
# normal flow recomputes (eligible → launch; still over → detune prompt reappears).
func _close_upgrades_popup() -> void:
	if _upgrades_popup != null:
		_upgrades_popup.visible = false
	if _upgrades_popup_dirty:
		if _carpark_mode == CarparkMode.CHALLENGE:
			_build_challenge_lineup(_challenge_kind)
		else:
			_build_eligible_lineup()
		_upgrades_popup_dirty = false
	_focus_changed()


# Spend a Repair Kit on the focused (wrecked) car: full restore, then re-evaluate so
# Start unlocks and the stats refresh. The owned dict is shared with the save, so the
# restored HP flows straight back into the lineup.
func _repair_focused_car() -> void:
	if _eligible.is_empty():
		return
	var id := int(_eligible[_focus].get("instance_id", -1))
	if Save.use_repair_kit(id):
		_render_lineup_page()  # respawn the current page so the healed prop is fresh (healthy)
		_focus_changed()       # DamageModel stops the synthetic smoke



# One-line car summary shown in the car-select overlay: drive layout,
# peak horsepower, kerb weight, and condition. Health reads as a percentage (kept
# distinct so it doesn't read as the horsepower figure now shown alongside it); a
# wrecked (0 HP) car is flagged so the lineup makes clear why it can't be entered.
# The power-to-weight ratio lives only in the upgrades-menu detune readout.
func _car_stats_text(owned: Dictionary, entry: Dictionary) -> String:
	var max_hp := float(entry.get("max_hp", 0.0))
	var hp := float(owned.get("hp", 0.0))
	var hp_text: String
	if max_hp > 0.0 and hp <= 0.0:
		hp_text = "WRECKED"
	else:
		hp_text = "Health %d%%" % roundi(clampf(hp / max_hp, 0.0, 1.0) * 100.0) if max_hp > 0.0 else "Health ?"
	var meta := UpgradeLibrary.effective_meta(owned, entry)
	return "%s | %.0f HP | %.0f kg | %s" % [
		CarLibrary.drive_text(int(entry.get("drive_mode", -1))),
		CarLibrary.horsepower(meta),
		float(meta.get("mass", 0.0)),
		hp_text,
	]


# Human-readable summary of a rally's restriction (the detail panel + the car banner).
func _restriction_text(restriction: Dictionary) -> String:
	if restriction.is_empty():
		return "any car"
	var parts: Array[String] = []
	if restriction.has("drive_mode"):
		parts.append("%s cars" % CarLibrary.drive_text(int(restriction["drive_mode"])))
	if restriction.has("country"):
		parts.append("%s cars" % String(restriction["country"]))
	if restriction.has("car_type"):
		parts.append("%s body" % String(restriction["car_type"]))
	if restriction.has("doors_min"):
		parts.append(">= %d doors" % int(restriction["doors_min"]))
	if restriction.has("doors_max"):
		parts.append("<= %d doors" % int(restriction["doors_max"]))
	# Engine-derived gates (displacement / cylinder count) are judged against the car's
	# CURRENT engine, so a swap changes them (RallyLibrary.ineligibility_reason).
	if restriction.has("engine_min_l"):
		parts.append("engine >= %.1f L" % float(restriction["engine_min_l"]))
	if restriction.has("engine_max_l"):
		parts.append("engine <= %.1f L" % float(restriction["engine_max_l"]))
	if restriction.has("cylinders_min"):
		parts.append(">= %d cylinders" % int(restriction["cylinders_min"]))
	if restriction.has("cylinders_max"):
		parts.append("<= %d cylinders" % int(restriction["cylinders_max"]))
	# The p/w gate is a band: pw_min..pw_max (either edge may be absent). A car must sit
	# inside it — over pw_max is capped out (detune to duck under), under pw_min is
	# ineligible. Both edges are authored in hp/tonne (RallyLibrary converts a car's kW/kg
	# to hp/tonne before comparing), the same unit as every player-facing p/w readout (the
	# car stats + the detune slider), so display them straight — no conversion here. The
	# unit carries the meaning, so there's no "power-to-weight" label on the figure.
	var has_min: bool = restriction.has("pw_min")
	var has_max: bool = restriction.has("pw_max")
	if has_min and has_max:
		parts.append("%.0f–%.0f hp/tonne" % [float(restriction["pw_min"]), float(restriction["pw_max"])])
	elif has_max:
		parts.append("<= %.0f hp/tonne" % float(restriction["pw_max"]))
	elif has_min:
		parts.append(">= %.0f hp/tonne" % float(restriction["pw_min"]))
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
		# The garage station has TWO framings: the wide shell view on the TOP level,
		# and — once Drive is pressed — a low 3/4 front hero shot of the car on the
		# lowered lift. Same station (no view change), different camera.
		View.GARAGE:
			if _garage_showing_drive and is_instance_valid(_lift_car):
				return _drive_cam_xform()
			return _look_xform(cfg.hq_garage_cam_eye, cfg.hq_garage_cam_look)
		View.TABLE: return _look_xform(cfg.hq_table_cam_eye + _table_pan, cfg.hq_table_cam_look + _table_pan)
		View.LIFT: return _look_xform(cfg.hq_lift_cam_eye, cfg.hq_lift_cam_look)
		View.CARPARK: return _camera_target_xform()
		# Title shot: eye + look are OFFSETS from the first (leftmost) parked car, so the
		# low ~45° "past the first car, down the line" framing tracks the lead car as the
		# centred lineup grows and its leftmost car slides toward −X (more cars owned).
		_:
			var anchor := _first_car_anchor()
			return _look_xform(anchor + cfg.hq_exterior_cam_eye, anchor + cfg.hq_exterior_cam_look)


# The DRIVE level's framing: a low three-quarter FRONT shot of the car resting on the
# lowered lift. Posed relative to hq_lift_pos rather than the car node so it's stable
# while the lower tween is still settling the car's Y (and so it still reads sanely
# for a car whose ride height differs). Only used while a lift car exists — with an
# empty garage _station_xform falls back to the wide station view.
func _drive_cam_xform() -> Transform3D:
	var cfg: GameConfig = Config.data
	var base := Vector3(cfg.hq_lift_pos.x, 0.0, cfg.hq_lift_pos.z)
	return _look_xform(base + cfg.hq_drive_cam_offset,
		base + Vector3.UP * cfg.hq_drive_cam_look_height)


func _focused_car_pos() -> Vector3:
	if _markers.is_empty():
		return Config.data.hq_carpark_origin
	return (_markers[_focus] as Marker3D).global_position


# Ground position of the first (leftmost, −X) parked car — the anchor the exterior
# title camera is posed relative to (see _station_xform). Markers are laid out
# left→right, so index 0 is the lead car. Falls back to the lot centre when no
# lineup is built yet (e.g. an empty garage), keeping the framing sane.
func _first_car_anchor() -> Vector3:
	if _markers.is_empty():
		return HQEnvironment.carpark_center()
	var p := (_markers[0] as Marker3D).global_position
	return Vector3(p.x, 0.0, p.z)


# The framing transform for the focused car: a 3/4 hero shot from the configured
# offset, looking at the car a little above its origin.
func _camera_target_xform() -> Transform3D:
	var cfg: GameConfig = Config.data
	var car_pos := _focused_car_pos()
	# The cosmetic wheel view swaps in a LOW SIDE-ON framing so the settled car's flank
	# and both wheels fill the frame. Branched here (not in _station_xform) because
	# _snap_camera_to_focus / _focus_changed come through this function directly.
	if _carpark_mode == CarparkMode.WHEELS:
		return _look_xform(car_pos + cfg.hq_wheel_cam_offset,
			car_pos + Vector3.UP * cfg.hq_wheel_cam_look_height)
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
	# In every non-RALLY mode the same Start button commits that mode's action instead
	# of launching a rally.
	match _carpark_mode:
		CarparkMode.STARTER:  # first run: commit the focused preview as the first car
			_confirm_starter()
			return
		CarparkMode.SWAP:  # exchange engines with the focused car
			_select_swap_target()
			return
		CarparkMode.WHEELS:  # fit the previewed cosmetic wheels (free, no confirm)
			_commit_wheels()
			return
		CarparkMode.GARAGE:  # select the focused car and drop into the tuning bay
			_select_garage_car()
			return
		CarparkMode.FREEROAM:  # launch a session-less drive in the focused car
			await _start_free_roam()
			return
		CarparkMode.CHALLENGE:  # commit the focused eligible car to a fresh challenge run
			if _detune_needed.get(_selected_instance_id, -1.0) > 0.0:
				_show_over_limit_prompt(Save.get_car(_selected_instance_id))
				return
			await _begin_challenge_start()
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
	# An over-powered car looks eligible in the park; pressing Start pops a prompt that
	# routes the player to the upgrades menu to shed power (detune / ballast / strip
	# parts), rather than launching. _detune_needed marks the over-cap-but-fixable cars.
	if _detune_needed.get(_selected_instance_id, -1.0) > 0.0:
		_show_over_limit_prompt(owned)
		return
	# A car below the class p/w floor is now INELIGIBLE (the floor is judged at the car's
	# max potential), so it never reaches the car-park lineup — there's no under-powered
	# start to warn about here anymore (the old soft "Underpowered" prompt is retired).
	await _proceed_with_start()


# The pre-flight EVERY start path shares — career, challenge (fresh and Resume) and free
# roam. Two steps that used to live only on the career path, so a touch player whose first
# drive was a challenge got no control-scheme picker, and the garage lift didn't show the
# car they'd just raced:
#
#   1. the mobile control-scheme gate — on a touch device with no scheme chosen yet, open
#      the picker instead of starting. `resume` is stashed so _on_settings_action can
#      continue THIS path once a scheme is saved.
#   2. select the fielded car, so the tuning lift shows what the player last drove.
#
# Returns false when the caller must abort (the gate took over).
func _start_preflight(resume: Callable, select_instance_id: int = -1) -> bool:
	if _is_mobile() and Save.get_setting(MobileControls.SETTING_KEY, null) == null:
		_pending_start = resume
		_open_settings(true)
		return false
	if select_instance_id >= 0:
		Save.set_selected_car(select_instance_id)
	return true


# The career start flow once the car is eligible (any drivetrain switch applied): the
# shared pre-flight, then the actual handoff.
func _proceed_with_start() -> void:
	if not _start_preflight(_proceed_with_start, _selected_instance_id):
		return
	await _begin_rally_start()


# Commit the focused car as the new selected car (the one raised on the lift) and
# enter the tuning bay. Any owned car is selectable here — even a wrecked one can
# sit on the lift to be repaired / tuned.
func _select_garage_car() -> void:
	if _selected_instance_id >= 0:
		Save.set_selected_car(_selected_instance_id)
	_clear_lineup()
	_selected_instance_id = -1
	_carpark_mode = CarparkMode.RALLY
	_enter_lift()  # a different car is selected — _ensure_lift_car's id/hash key respawns it


# Confirm the highlighted car as the engine-swap partner: exchange engines, then
# respawn the lift prop with its new engine and return to the upgrades page.
func _select_swap_target() -> void:
	var current_id := Save.selected_instance_id()
	if _selected_instance_id < 0:
		return
	_show_swap_confirm(current_id, _selected_instance_id)


# Perform the swap (Save.swap_engines spends one engine swap token), then respawn
# the lift prop with its new engine and return to the upgrades page.
func _commit_engine_swap(current_id: int, partner_id: int) -> void:
	Save.swap_engines(current_id, partner_id)
	_clear_lineup()
	_selected_instance_id = -1
	_carpark_mode = CarparkMode.RALLY
	_ensure_lift_car()  # the engine data changed — the hash flips, so the prop respawns
	_enter_lift()


# Confirm popup for a chosen engine-swap partner: swapping costs one token. If the
# player holds one, OK ("Swap") commits; if not, OK is disabled and the message says
# so (the swap-row button already blocks this case, but the popup stays defensive).
func _show_swap_confirm(current_id: int, partner_id: int) -> void:
	var tokens := Save.engine_swap_tokens_owned()
	var body: String
	if tokens > 0:
		_pending_swap = {"current": current_id, "partner": partner_id}
		body = ("Exchange engines between these two cars? " +
			"This spends 1 engine swap token (you have %d)." % tokens)
	else:
		_pending_swap = {}
		body = "You have no engine swap tokens. Win one from a rally reward, then swap."
	ConfirmPopup.open(self, "Swap engines?", body,
		[ {"label": "Cancel", "callback": Callable()},
		  {"label": "Swap", "callback": _on_swap_confirmed, "disabled": tokens <= 0} ], 1, 0)


# OK on the swap-confirm popup: perform the swap (spends the token).
func _on_swap_confirmed() -> void:
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
	# Fielding a car also selects it (so the tuning lift shows the car the player last
	# raced) — done by the shared _start_preflight, which every start path runs before
	# reaching its own handoff, rather than once per path.
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
	# While the player is typing (the account sign-in form is the only text input
	# in the game), the HQ must not read bare keys as station navigation, and Back
	# belongs to the field — MenuNav turns it into "stop typing". One shared
	# predicate so this guard cannot drift from the one MenuNav uses.
	if MenuNav.is_text_editing():
		return
	# A ConfirmPopup / UsernamePopup is MODAL: it owns the input until dismissed, and its
	# own MenuNav handles select/back on its buttons. Normally the focused popup button
	# consumes ui_accept before this ever runs — but that relies on the popup HOLDING
	# focus, and when it doesn't (nothing focusable, focus released by a rebuild under
	# it), the same keypress fell through to the station rows below and fired a SECOND
	# action behind the popup. That's how opening a mystery box could spend a second box
	# whose reveal was then refused for stacking — the spend is not undoable, so the
	# station must simply not listen while a modal is up. Guarded here, alongside the
	# account/challenge overlays, which own input the same way.
	if ConfirmPopup.any_open(get_tree()) != null:
		return
	# The account overlay is modal over the title screen: it owns Back until closed.
	if _account_layer != null:
		if event.is_action_pressed("menu_back") or event.is_action_pressed("ui_cancel"):
			if not _account_menu.go_back():
				_close_account_overlay()
			get_viewport().set_input_as_handled()
		return
	# The challenge overlay is modal over the garage: it owns focus nav entirely via its
	# own MenuNav (attached in build_challenge_overlay), including left/right — the kind
	# tabs are real FOCUS_ALL controls now, so native ui_left/ui_right focus-neighbour
	# movement (menu_nav.gd) does the job; hq must still bail out here (its
	# _unhandled_input runs BEFORE the overlay's own MenuNav node, an HQ descendant) so
	# the GARAGE view below doesn't also react to the same key.
	if _challenge_layer != null and _challenge_layer.visible:
		return
	match _view:
		View.EXTERIOR:
			# The title row (Start / Account / Settings / Exit Game) is a single
			# left/right cursor; select fires it. Same idiom as the garage row / lift
			# hub — see build_title_overlay. No menu_back: EXTERIOR is the root station.
			if event.is_action_pressed("menu_left"):
				_move_title_focus(-1)
			elif event.is_action_pressed("menu_right"):
				_move_title_focus(1)
			elif event.is_action_pressed("menu_select"):
				_activate_title_focus()
		View.SETTINGS:
			if event.is_action_pressed("menu_back"):
				# In the pre-rally gate we show only the mobile-controls page (no category
				# list), so back cancels the gate straight back to the car park. Otherwise
				# a sub-page backs out to the category list first, then back exits to the garage.
				if _settings_gate:
					_go_to(View.CARPARK)
					_settings_gate = false
				elif not _settings_menu.go_back():
					_go_to(View.EXTERIOR)
		View.GARAGE:
			# The bottom action row is a single left/right cursor (two levels share it —
			# see _refresh_garage_row); select fires it. menu_back on the TOP level
			# shortcuts to the exterior; on the DRIVE level it goes up one level instead
			# (mirroring the Back button's own action at each level), same as any other
			# nested menu's Back convention.
			if event.is_action_pressed("menu_left"):
				_move_garage_focus(-1)
			elif event.is_action_pressed("menu_right"):
				_move_garage_focus(1)
			elif event.is_action_pressed("menu_select"):
				_activate_garage_focus()
			elif event.is_action_pressed("menu_back"):
				if _garage_showing_drive:
					_garage_back_to_top()
				else:
					_go_to(View.EXTERIOR)
		View.LIFT:
			if _lift_page == LiftPage.HUB:
				# Hub: left/right move the cursor between Back / Upgrades / Tuning /
				# Test Drive; select fires it; menu_back is a shortcut to the garage.
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
			elif event.is_action_pressed("menu_select"):
				_activate_table_focus()
			else:
				# Up/down/left/right glide the camera continuously while held — polled
				# in _process, not per-press — so only pointer drag is handled here.
				_table_pan_input(event)
		View.CARPARK:
			# While an on-brand modal is up (detune prompt / Change-Upgrades popup) its
			# MenuNav owns navigation — don't also drive the lineup underneath.
			if _carpark_modal_open():
				return
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
	_select_target_under_center()  # selection tracks the view centre as the map slides


func _cars_input(event: InputEvent) -> void:
	if _lineup_pointer_input(event):
		return
	if event.is_action_pressed("menu_left"):
		_cycle_focus(-1)
	elif event.is_action_pressed("menu_right"):
		_cycle_focus(1)
	# The cosmetic wheel view reads as a LIST, so up/down cycles it too (keyboard W/S +
	# arrows, gamepad D-pad/stick). Harmless to bind only there: paging bays is a
	# horizontal action, and the other modes leave up/down free.
	elif _carpark_mode == CarparkMode.WHEELS and event.is_action_pressed("menu_up"):
		_cycle_wheel(-1)
	elif _carpark_mode == CarparkMode.WHEELS and event.is_action_pressed("menu_down"):
		_cycle_wheel(1)
	elif event.is_action_pressed("menu_select") and not _start_button.disabled:
		_on_start_pressed()
	elif event.is_action_pressed("menu_back"):
		_car_back()


# Pointer navigation for the car-park lineup (mouse, or finger via
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
	if _carpark_mode == CarparkMode.WHEELS:
		return  # one car, already focused — a tap must not re-run _focus_changed here
	var idx := _car_index_at(screen_pos)
	if idx >= 0 and idx != _focus:
		_lineup.focus_local(idx)  # a tap stays on the current page; keep the paginator in step
		_focus = _lineup.focus
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
