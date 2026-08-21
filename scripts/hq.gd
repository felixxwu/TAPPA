class_name HqController
extends Node3D
# Docs: features/engine-swap.md, features/menus.md, features/tuning.md, features/world-panel.md — update in the same change as this file.
# Tests: tests/headless/test_menu_flow.gd, tests/headless/test_menu_nav.gd, tests/headless/test_menu_page.gd — extend in the same change. These are the PRIMARY ones, not all of them: before you change behaviour here, `grep -rn 'HqController' tests/headless/` and read the assertions that pin what you are about to change (12 test files touch this script).
# HQ — the meta-game hub (todo/menus.md location 1), now a DIEGETIC 3D space the
# camera flies through (todo/diegetic-hq.md) instead of flat overlay screens. One
# world; the camera moves between "stations":
#   * EXTERIOR — the boot/title shot: block buildings + the outdoor car park, with a
#     row of Exit Game (non-web) / FREE ROAM / Settings / Start. Start flies the camera
#     into the garage; FREE ROAM opens the car park to pick any catalogue car and drive
#     session-lessly (it needs no owned car or session, so it belongs here rather than
#     behind the garage).
#   * GARAGE   — a block garage interior holding the MAP TABLE and the TUNING LIFT.
#     The player's SELECTED car is raised on the lift here. Tap the table to see the
#     rallies; tap the lift to tune. Its action row is ONE level:
#     Back / Career / Garage / Online.
#   * TABLE    — a near-top-down look at the table's 3D map. Tap a rally pin to open
#     its detail; Enter flies out to the car park.
#   * LIFT     — the tuning bay: the selected car raised on the lift on one side. The
#     bay opens on a HUB page (the car's name/description, Upgrades / Tuning buttons,
#     and a Test Drive button) bottom-left beside the car. Each menu button opens that
#     menu as its OWN full-height page (TUNE = grip/brake/aero sliders; UPGRADES =
#     install parts); Test Drive drops into free roam with the car on the lift
#     so neither needs to scroll; Back returns the page to the hub, and the hub's Back
#     returns to the garage.
#   * CARPARK  — the outdoor lineup of cars: in RALLY mode the cars ELIGIBLE for the
#     chosen rally (pan + Start); in GARAGE mode the whole collection (pan +
#     Select the car to take to the tuning lift).
# Flow: pick rally (table) -> choose eligible car (car park) -> Start -> RallySession.
# It is the game's boot scene and stays lightweight (NO track gen).
#
# Clickable 3D objects (table, lift, rally pins) are Area3D with input_ray_pickable;
# get_viewport().physics_object_picking drives the picking. Headless tests call the
# handlers (_table_ui._enter_table / _table_ui._on_rally_pin / _enter_car_screen / ...) directly.
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
# The starter roster lives in CarLibrary (catalogue content, one source of truth); this
# alias keeps the existing hq.STARTER_MODEL_IDS call sites and test hooks working.
const STARTER_MODEL_IDS := CarLibrary.STARTER_MODEL_IDS

# RallySession is an autoload with no class_name, so its STATIC canonical config
# writer (apply_event_config) must be reached through the script resource — calling a
# static via the instance warns. Same precedent as driving_context.gd.
const RallySessionScript := preload("res://scripts/rally_session.gd")
# Same idiom as RallySessionScript above, and for the same reason: ChallengeSession is an
# AUTOLOAD, so the bare name is the node instance — and calling one of its `static func`s through
# an instance raises STATIC_CALLED_ON_INSTANCE. Reaching the script directly keeps the call clean.
const ChallengeSessionScript := preload("res://scripts/challenge_session.gd")

# The tuning-lift pages (todo/menus.md rig 4). HUB is the bay landing page (car
# name/description + Upgrades/Tuning buttons + a Test Drive button); TUNE is
# the handling sliders and UPGRADES is install parts / repair. Each menu is its own
# full-height page (reached from the hub) so neither has to scroll.
enum LiftPage { HUB, TUNE, UPGRADES }

# 1st place earns 3 stars, the rest of the podium 2, any other finish 1, not finishing
# (incl. not completed) 0 — see RallyLibrary.stars_for_placement, the one definition.
# Shown on the 3D map pins inside the house-style readout box as proper five-pointed
# stars (gold = earned, dim = not) drawn by StarRow — polygons, so they need no font
# glyph (Syne Mono has no ★/☆; same reason the UI uses ASCII like `<`/`>` for nav).
# Emitted once a car-park lineup has finished streaming its props in (the cars spawn
# one-per-frame, see _spawn_lineup_progressive). Lets tests await a fully-parked lineup.
signal lineup_built

# The star row's length — one definition, shared with the gate arithmetic, so the medals
# drawn on a pin can't disagree with what the special ladder counts.
const MAX_STARS := RallyLibrary.MAX_STARS_PER_RALLY
# How many qualifying cars the rally-detail card names before it tails off with "+N more".
# Re-exported from RallyDetail (where the read-out it caps now lives) rather than declared
# twice: this is the name test_rally_detail.gd reads it by.
const MAX_QUALIFY_NAMES := RallyDetail.MAX_QUALIFY_NAMES
const KW_KG_TO_HP_TONNE := CarLibrary.KW_KG_TO_HP_TONNE  # single source of truth for the kW/kg -> hp/tonne display conversion

# The map-pin readout box: a 2D UITheme panel (rally name + StarRow) rendered to a
# billboarded Sprite3D. PIN_LABEL_PX is the off-screen viewport resolution; pixel_size
# scales it to world metres; rise is how far above the flag tip the box floats.
# The authored 400x150 medium is scaled by UITheme.UI_SCALE (and pixel_size divided by it)
# so the pin keeps its exact world-metre size while the texture gains the resolution the
# sharper world now renders at — the same medium-not-content scaling as WorldPanel and the
# screen itself (features/ui-design-system.md -> "UI scale").
const PIN_LABEL_PX := Vector2i(int(400 * UITheme.UI_SCALE + 0.5), int(150 * UITheme.UI_SCALE + 0.5))
# Font size for the map's floating pin readouts ONLY (see _build_readout_sprite). Larger
# than UITheme.FONT_SIZE because these are rendered to a texture and viewed at a distance in
# 3D; the flat menus are read at native resolution and stay at the house size. Authored 24,
# inflated with its medium (UI_SCALE) like every other size.
const PIN_LABEL_FONT_SIZE := int(24 * UITheme.UI_SCALE + 0.5)
const PIN_LABEL_PIXEL_SIZE := 0.00255 / UITheme.UI_SCALE  # authored 0.00255 (1.5x the original 0.0017 so the boxes read bigger); divided by UI_SCALE to cancel the PIN_LABEL_PX growth
# Every map readout wears the SAME pure-black panel — design-system house rule 4, with no
# exception. Special events used to get an inverted light-brown face to stand out, which is
# gone: the 3D markers now carry that job (a car model, a trophy, or a flag), and a panel
# colour saying "this one is different" on top of a marker that already says so was the same
# emphasis twice. The retired constants were ACCENT_READOUT_BG / ACCENT_READOUT_INK.
# Sprite modulate for a readout box whose rally isn't available yet (greyed out).

# Loaded LAZILY (not preloaded) so the heavy car scene — which pulls in the MX-5 glb,
# its texture and the engine-audio resources — isn't decoded at script-compile time
# (before _ready), which would stretch the "stuck at 100%" gap after Godot's boot bar.
# Both are only needed by _build_hq, which runs behind our LoadingScreen.
const CAR_SCENE_PATH := Scenes.CAR
# The itch.io page hosting the Android APK — where the mobile-web boot notice sends
# players for the (much faster) native build.
const ANDROID_APP_URL := "https://felixxwu.itch.io/tappa"
var _car_scene: PackedScene  # cached on first use (load() also caches engine-side)


func _car_scene_res() -> PackedScene:
	if _car_scene == null:
		_car_scene = load(CAR_SCENE_PATH)
	return _car_scene

var _view: int = View.EXTERIOR
# (`_detail_open` — the rally-detail panel is up, a sub-state of TABLE — now forwards to
# RallyDetail; it is declared with the rest of the panel's handles further down.)
# New-rally reveal (a second sub-state of TABLE, sibling to _detail_open): the map
# camera is walking a queue of rallies that just became enterable, flipping each pin
# from its locked to its unlocked look. While _revealing the table's own input is
# suspended and player input is LOCKED — presses are swallowed, not acted on, so the parade
# always plays out (see _unhandled_input's View.TABLE branch).
var _revealing := false
# The parade's own bookkeeping (the queue, the ids already flipped, the sequence token) lives
# on HqTable (scripts/hq_table.gd), which drives it and is its only user. `_revealing` above
# stays here because hq.gd's input lock and prewarm gate both read it.
# NOTE on the @warning_ignore tags below. hq.gd was split into helper scripts
# (hq_table / hq_carpark / hq_challenge / hq_overlays) that reach back into this controller
# for shared state. The analyzer sees one file at a time, so every field only THOSE helpers
# touch reads as unused here — a warning that is wrong, and that surfaces as a test failure
# in whichever suite happens to load hq.gd first. The tag marks the field as deliberately
# cross-file rather than dead; if you delete a helper's last use of one, delete the field
# too.
@warning_ignore("unused_private_class_variable")  # shared with the hq_*.gd helpers
var _reveal_banner: Label               # the "NEW RALLY - …" line on the table overlay
var _selected_rally_id := ""
var _selected_instance_id := -1
# The car park serves several jobs, one at a time (never overlapping):
#   RALLY    (default) — cars eligible for the chosen rally; Start launches the rally.
#   FREEROAM (the TITLE screen's "Free Roam" button) — the WHOLE catalogue as base-model previews;
#            Start drops into a session-less drive in the picked car (owned or not).
#   SWAP     (_enter_engine_swap) — OTHER owned cars; Select picks an engine-swap partner.
#   STARTER  (first run) — preview cars (garage empty); Select grants the first car.
#   WHEELS   (_enter_wheel_swap) — the selected car ALONE in the lot, settled on its
#            suspension, with a low side-on camera; left/right cycles cosmetic wheel
#            styles live on the car and Start fits the shown one. Uses the car park
#            (not the tuning lift) precisely because the lift holds the car RAISED and
#            wheels are judged by stance. See features/wheel-customization.md.
#   CHALLENGE (_challenge_ui._enter_challenge_car_screen) — the Rally Challenge entry point's car
#            picker (spec §7 / §2): owned cars ChallengeSession.eligible_cars(kind, ...)
#            reports for the currently-shown kind. A challenge has no authored rally dict
#            and is the one screen still judging a PERFORMANCE ceiling, so it runs its own
#            check rather than the categorical rally one (see
#            _challenge_ui._build_challenge_lineup).
#            Start commits ChallengeSession.start + the scene hand-off instead of
#            RallySession.start_rally (see _challenge_ui._begin_challenge_start).
# One enum instead of mutually-exclusive booleans: entering a job sets the mode
# (which inherently clears the others), and every exit/commit/back returns to RALLY.
enum CarparkMode { RALLY, FREEROAM, SWAP, STARTER, WHEELS, CHALLENGE, PRESENT }
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
# instance_id -> the engine-detune fraction that would duck an over-ceiling parked car
# under a Rally CHALLENGE's ceiling. Career rallies no longer gate on performance at
# all, so only the challenge car-select lineup populates this (hq_challenge.gd); for
# these cars Start opens the over-limit prompt that routes to the upgrades menu
# (_show_over_limit_prompt / _on_start_pressed) rather than launching.
var _detune_needed: Dictionary = {}
# Confirm popup shown when Start is pressed on an over-powered car: the car looks
# eligible in the park; this dialog carries the "too powerful" nudge and routes to
# Change Upgrades (_show_over_limit_prompt). Implemented via ConfirmPopup.
# The car-park "Change Upgrades" popup and the currently-open car-park ConfirmPopup live on
# HqCarpark (scripts/hq_carpark.gd), which owns both and is their only user.
# Confirm popup shown when a chosen engine-swap partner is picked. Swapping is free and
# unlimited once its rally has been won, so the popup only ever carries the go-ahead or
# the still-locked block. Implemented via ConfirmPopup. _pending_swap holds the two
# instance ids awaiting the OK press (and is empty exactly when the swap can't happen).
var _pending_swap: Dictionary = {}
# The start path the mobile control-scheme gate interrupted, resumed by
# _on_settings_action once a scheme is saved. Set by _start_preflight, which every
# start path (career, challenge, free roam) funnels through — so the gate exists once
# and each path resumes into ITSELF rather than always into the career start.
var _pending_start: Callable = Callable()
var _cars: Array = []
var _markers: Array = []
# WORLD-SPACE MENUS (world_panel.gd + world_panel_host.gd, features/world-panel.md), off
# by default behind Config.data.world_space_menus. `_car_root` / `_lift_root` are the two
# migrated screens' trees, held so their WorldPanelHost can MOVE each one between its flat
# CanvasLayer and a panel welded into the 3D scene. All the swap machinery lives in
# WorldPanelHost — a station only supplies its layer, tree, anchor and size.
var _car_root: Control
var _lift_root: Control
var _title_root: Control
var _garage_root: Control
# The challenge screen is a MODAL over the garage rather than a View of its own, so its shown-ness
# is its own flag rather than a _view comparison (hq_challenge.gd toggles it).
var _challenge_shown := false
# Reuse cache for parked lineup cars, shared by every lineup (rally car-select,
# title, free roam) since they all build from the same car dicts. Keyed by the
# owned car's instance_id -> {"hash": int, "node": Node3D}; the hash is the deep
# Variant hash of the owned dict, so a car whose tuning / damage / engine changed
# gets a fresh respawn while unchanged cars are reused as-is (see _build_lineup /
# _release_page_props). Cars are hidden + stowed off-screen (not freed) between lineups
# and freed with the HQ node on exit-to-race.
var _car_cache: Dictionary = {}
var _focus := 0
# The focus-rev audio player and the lineup spawn generation live on HqCarpark
# (scripts/hq_carpark.gd), which is their only user.
# Free Roam pre-warm: just AFTER boot (once the loading cover lifts, one prop per frame —
# see _prewarm_free_roam_deferred) we spawn the catalogue's preview
# props into _car_cache (hidden) so entering Free Roam reuses them with no fresh instancing
# — killing the first-entry lag spike. The off-screen stow marker the hidden props seat at
# until Free Roam re-seats them at real bays lives on HqCarpark (_prewarm_marker), which is
# its only user; the two flags below stay here because tests read them off the controller.
# True once every catalogue preview is warm in _car_cache (the deferred prewarm ran to
# completion, or _prewarm_free_roam was called synchronously). Read by tests; also lets a
# stray re-start of the deferred loop bail immediately.
@warning_ignore("unused_private_class_variable")  # shared with the hq_*.gd helpers
var _prewarm_complete := false
# True while the deferred (one-prop-per-frame) prewarm loop is in flight, so it can't be
# started twice and overlap itself.
@warning_ignore("unused_private_class_variable")  # shared with the hq_*.gd helpers
var _prewarm_running := false
# `Time.get_ticks_msec()` of the last input HQ saw from the player, stamped by _input (which
# sees events BEFORE any overlay button eats them, unlike _unhandled_input). Starts well in
# the past — "no input ever", i.e. idle — so a boot that lands on the static title shot keeps
# trickling its prewarm exactly as it does today. (A literal rather than -PREWARM_IDLE_MS so
# it stays "long ago" whatever that constant is retuned to, and so it is still in the past
# during the engine's first few hundred ms.)
var _last_input_ms := -100000
# How still the player has to be before the prewarm is allowed to spawn its next car, and
# how long it may be starved before it gives up waiting and finishes anyway (so the warm
# always completes, even for a player who never stops moving). See _prewarm_should_wait.
const PREWARM_IDLE_MS := 400
const PREWARM_MAX_STALL_MS := 15000

# Tuning-lift state: the selected car raised on the lift (a Car prop, separate from
# the car-park lineup), which OwnedCar it is, and which menu (TUNE / UPGRADES) is up.
var _lift_car: Node3D
var _lift_owned: Dictionary = {}
@warning_ignore("unused_private_class_variable")  # shared with hq_tuning_lift.gd
var _lift_car_instance_id := -2  # what _lift_car was built for (-2 = nothing yet)
# Deep hash of the owned dict _lift_car was built from. _ensure_lift_car reuses the
# prop only when BOTH the instance id and this hash match, so any in-place data change
# (repair, upgrade toggle, engine swap) auto-invalidates the prop — no mutator has to
# remember to force a respawn. Mirrors the car park's _obtain_parked_car / _car_cache.
@warning_ignore("unused_private_class_variable")  # shared with hq_tuning_lift.gd
var _lift_car_hash := 0
@warning_ignore("unused_private_class_variable")  # shared with hq_tuning_lift.gd
var _lift_page: int = LiftPage.HUB
# Lift animation: the car is LOWERED on the ground in the garage view and RAISED when
# the bay is entered (tweened over hq_lift_raise_time). _lift_raised is the current
# target pose; _lift_tween animates the car's height toward it.
@warning_ignore("unused_private_class_variable")  # shared with hq_tuning_lift.gd
var _lift_raised := false
@warning_ignore("unused_private_class_variable")  # shared with hq_tuning_lift.gd
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
@warning_ignore("unused_private_class_variable")  # shared with hq_map_table.gd / hq_table.gd
var _pins: Array = []           # the pin Node3Ds (each carries a "rally_id" meta)
# Everything the live pins were rendered FROM (_map_pins_stamp). A refresh whose stamp
# matches keeps the pins standing instead of rebuilding them — see _refresh_map_pins.
# `null` = nothing built yet, which can never compare equal to a real stamp.
@warning_ignore("unused_private_class_variable")  # shared with hq_map_table.gd / hq_table.gd
var _pins_stamp = null
# Focus cursor into _table_ui._table_targets() (the unlocked rally pins); -1 = none.
@warning_ignore("unused_private_class_variable")  # shared with the hq_*.gd helpers
var _table_focus_index := -1
# The pin node the focus highlight is currently PAINTED onto, so the per-frame pan path
# can skip repainting when nothing changed (hq_table.gd::_select_target_under_center).
# Keyed on the node rather than on _table_focus_index because _refresh_map_pins
# invalidates _table_targets_cache WITHOUT resetting the index — a rebuild reuses the
# same index with brand-new nodes, and those still need painting.
@warning_ignore("unused_private_class_variable")  # shared with hq_map_table.gd / hq_table.gd
var _table_focus_node: Node3D = null
# Cached _table_ui._table_targets() result. The target set only changes on pin rebuild
# (_refresh_map_pins), which sets this back
# to null; every access rebuilds lazily. Per-frame table panning (_process ->
# _table_ui._pan_table_step) reuses it instead of rebuilding a Dictionary-per-target array each frame.
@warning_ignore("unused_private_class_variable")  # shared with hq_map_table.gd / hq_table.gd
var _table_targets_cache = null

# Overlays (one CanvasLayer per station; only the active one is visible).
# The overlay/menu-layer builders live in HqOverlays (scripts/hq_overlays.gd),
# constructed with `self` in _ready so they can reach back into this controller.
var _overlays: HqOverlays
# The three cluster collaborators. These fields are the ONLY strong references keeping
# them alive: a Callable connected to one of their methods stores an ObjectID, not a
# reference, so clearing or reassigning one of these frees the instance and strands every
# signal connected to it (see _nav_cycle_focus). Hold them for the node's whole lifetime.
#
# The Rally Challenge screen (scripts/hq_challenge.gd). Functions live there; the
# `_challenge_*` state below stays here — see todo/hq-split.md for why.
var _challenge_ui: HqChallenge
# The Multiplayer entry screen (scripts/hq_multiplayer.gd). Functions live there; the
# widget state below stays here, same split as HqChallenge.
var _multiplayer_ui: HqMultiplayer
# The map table (scripts/hq_table.gd). Functions there; state stays here.
var _table_ui: HqTable
# The car park (scripts/hq_carpark.gd). Functions there; the lineup / prop-cache
# state (`_lineup`, `_car_cache`, `_eligible`, `_focus`, …) stays here.
var _carpark_ui: HqCarpark
# The map table's PIN LAYER (scripts/hq_map_table.gd) — pins, readout boxes, reveal links,
# exploration fog. Functions there; the pin state (`_pins`, `_pins_root`, `_map_plane`,
# `_pins_stamp`, …) stays here, since HqTable navigates it too.
var _map_table_ui: HqMapTable
# The tuning lift (scripts/hq_tuning_lift.gd). Functions there; the lift state and widgets
# (`_lift_car`, `_lift_page`, `_lift_row`, the cursors, the buttons hq_overlays.gd builds)
# stay here.
var _tuning_lift: HqTuningLift
# The present-box car reveal (scripts/hq_present_reveal.gd). Functions there; the four
# reveal state fields stay here (a test asserts on `_present_opened`, `_car_back` branches
# on it).
var _present_ui: HqPresentReveal
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
# Rally Challenge entry point (Daily/Weekly/Monthly, spec §7): a modal overlay over
# the garage, opened from the garage row's Challenge button, built as a dark detail-
# card sibling to the rally-detail panel (RallyDetail.build's MODAL_DIM + header +
# HSeparator + detail_heading/detail_wrap_label shape) rather than a flat button
# list. See hq_overlays.gd's build_challenge_overlay and the _challenge_ui._open_challenge_overlay
# family below.
var _challenge_layer: CanvasLayer
@warning_ignore("unused_private_class_variable")  # shared with the hq_*.gd helpers
var _challenge_kind: String = ChallengeLibrary.DAILY

# Multiplayer entry screen (features/multiplayer-lobby.md "Entry point"): a modal
# overlay over the garage, opened from the garage row's Multiplayer button, built
# the same way the Rally Challenge entry screen is. See hq_overlays.gd's
# build_multiplayer_overlay and the _multiplayer_ui._open_multiplayer_overlay family.
var _multiplayer_shown := false
var _multiplayer_layer: CanvasLayer
@warning_ignore("unused_private_class_variable")  # shared with hq_multiplayer.gd
var _multiplayer_title_label: Label
@warning_ignore("unused_private_class_variable")  # shared with hq_multiplayer.gd
var _multiplayer_subtitle_label: Label
@warning_ignore("unused_private_class_variable")  # shared with hq_multiplayer.gd
var _multiplayer_signin_label: Label
@warning_ignore("unused_private_class_variable")  # shared with hq_multiplayer.gd
var _multiplayer_race_button: Button
@warning_ignore("unused_private_class_variable")  # shared with hq_multiplayer.gd
var _multiplayer_spectate_button: Button
@warning_ignore("unused_private_class_variable")  # shared with hq_multiplayer.gd
var _multiplayer_back_button: Button
# The refresh generation and the per-period board caches that go with it now live on
# HqChallenge (scripts/hq_challenge.gd), which is their only user.
# The Daily/Weekly/Monthly tab row: real FOCUS_ALL buttons (so keyboard/gamepad focus
# can rest on and move across them via native left/right focus-neighbour nav — see
# menu_nav.gd) but mouse_filter = MOUSE_FILTER_IGNORE and no `pressed` wiring at all, so
# there is NO mouse hover/click interaction whatsoever — arriving via focus (each one's
# focus_entered calls _challenge_ui._select_challenge_kind) is the only way to pick a kind. See
# build_challenge_overlay. Order matches [DAILY, WEEKLY, MONTHLY] — _challenge_ui._challenge_kind_button.
@warning_ignore("unused_private_class_variable")  # shared with the hq_*.gd helpers
var _challenge_kind_buttons: Array[Button] = []
# Header: title ("Daily Challenge") + subtitle (the rolled ceiling), mirroring
# _detail_title/_detail_region's two-line shape.
@warning_ignore("unused_private_class_variable")  # shared with the hq_*.gd helpers
var _challenge_title_label: Label
@warning_ignore("unused_private_class_variable")  # shared with the hq_*.gd helpers
var _challenge_subtitle_label: Label
# Four concise sections, each one detail_heading + one/two detail_wrap_label rows:
# win condition, win reward, eligible cars, current progress. (The ceiling already
# rides on the header subtitle, so it doesn't get its own "entry requirement" row.)
@warning_ignore("unused_private_class_variable")  # shared with the hq_*.gd helpers
var _challenge_win_label: Label
@warning_ignore("unused_private_class_variable")  # shared with the hq_*.gd helpers
var _challenge_reward_label: Label
@warning_ignore("unused_private_class_variable")  # shared with the hq_*.gd helpers
var _challenge_eligible_label: Label
@warning_ignore("unused_private_class_variable")  # shared with the hq_*.gd helpers
var _challenge_progress_label: Label
@warning_ignore("unused_private_class_variable")  # shared with the hq_*.gd helpers
var _challenge_start_button: Button
var _garage_layer: CanvasLayer
var _table_layer: CanvasLayer
var _lift_layer: CanvasLayer
var _car_layer: CanvasLayer
var _settings_layer: CanvasLayer
# Settings page: the shared SettingsMenu (camera angle + mobile controls), reused by
# the in-run pause menu so both pages match.
var _settings_menu: SettingsMenu
var _settings_sub: Label             # subtitle, shown ONLY for the pre-rally gate
var _settings_action_button: Button  # bottom button: "< Back" (title) or "Start >" (gate)
# True when Settings was opened as the mandatory pre-rally control-scheme gate (vs.
# from the title screen) — the bottom button then starts the rally instead of going back.
var _settings_gate := false

var _map_meter: Label           # star-total meter on the table HUD
# THE RALLY-DETAIL PANEL, and everything it owns, now lives in RallyDetail
# (scripts/rally_detail.gd) so the overworld hub can open the same card. Built in _build_hq,
# filled by hq_table.gd::_show_detail.
var _detail_ui: RallyDetail
# The panel's widget handles + its open flag read at their OLD names, because the readers are
# spread across hq.gd, hq_table.gd, hq_challenge.gd (which this cut may not edit) and the menu
# tests — renaming ~40 access sites would have been the churn, not the boundary. These are one
# line each and forward to the panel; RallyDetail is where the state actually is.
#
# `_detail_open` needs a SETTER as well: every screen that leaves the table closes the panel by
# writing it (see the `_detail_open = false` lines below, hq_table.gd and hq_challenge.gd).
var _detail_open: bool:
	get:
		return _detail_ui != null and _detail_ui.open
	set(value):
		if _detail_ui != null:
			_detail_ui.open = value
var _detail_layer: CanvasLayer:
	get:
		if _detail_ui == null:
			return null
		return _detail_ui.layer
@warning_ignore("unused_private_class_variable")  # read from outside: see the RallyDetail forwarding note
var _detail_title: Label:
	get:
		if _detail_ui == null:
			return null
		return _detail_ui.title
# region tag under the title (muted)
@warning_ignore("unused_private_class_variable")  # read from outside: see the RallyDetail forwarding note
var _detail_region: Label:
	get:
		if _detail_ui == null:
			return null
		return _detail_ui.region
# gold "SPECIAL EVENT" chip on the header row
@warning_ignore("unused_private_class_variable")  # read from outside: see the RallyDetail forwarding note
var _detail_special: Label:
	get:
		if _detail_ui == null:
			return null
		return _detail_ui.special
# the eligibility restriction summary
@warning_ignore("unused_private_class_variable")  # read from outside: see the RallyDetail forwarding note
var _detail_restriction: Label:
	get:
		if _detail_ui == null:
			return null
		return _detail_ui.restriction
# the qualifying cars, named (GREEN / RED / muted)
@warning_ignore("unused_private_class_variable")  # read from outside: see the RallyDetail forwarding note
var _detail_qualify: Label:
	get:
		if _detail_ui == null:
			return null
		return _detail_ui.qualify
# "N need a drivetrain conversion" caution (GOLD, hidden when 0)
@warning_ignore("unused_private_class_variable")  # read from outside: see the RallyDetail forwarding note
var _detail_adjust: Label:
	get:
		if _detail_ui == null:
			return null
		return _detail_ui.adjust
# best-finish text beside the StarRow
@warning_ignore("unused_private_class_variable")  # read from outside: see the RallyDetail forwarding note
var _detail_record: Label:
	get:
		if _detail_ui == null:
			return null
		return _detail_ui.record
# medal row for the player's best finish
@warning_ignore("unused_private_class_variable")  # read from outside: see the RallyDetail forwarding note
var _detail_stars: StarRow:
	get:
		if _detail_ui == null:
			return null
		return _detail_ui.stars
# "Enter Rally" — disabled when no owned car qualifies
@warning_ignore("unused_private_class_variable")  # read from outside: see the RallyDetail forwarding note
var _detail_enter_button: Button:
	get:
		if _detail_ui == null:
			return null
		return _detail_ui.enter_button
var _rally_banner: Label
var _car_name_label: Label
var _car_stats_label: Label
# Carpark chrome: the hint line and the prev/label/next row.
@warning_ignore("unused_private_class_variable")  # shared with the hq_*.gd helpers
var _car_hint_label: Label
@warning_ignore("unused_private_class_variable")  # shared with the hq_*.gd helpers
var _car_nav_row: Control
# The car park's "< Back" button, kept so the present-box reveal can HIDE it — that beat is
# forced, and a visible Back the player cannot use is worse than none.
@warning_ignore("unused_private_class_variable")  # shared with hq_present_reveal.gd
var _car_back_button: Button
var _swap_preview_label: RichTextLabel
var _start_button: Button
var _title_start_button: Button  # EXTERIOR title Start — first cursor stop
# The rest of the title row (Free Roam / Settings / Exit Game) and the build watermark live on
# HqOverlays, which builds them and is their only user. _title_start_button stays here because
# hq.gd's own _title_start_index reads it.
# ITS OWN LAYER, not _title_layer. The watermark is not part of the title MENU — it is a
# corner stamp that has to be legible on whichever host the title is using. Parented to the
# title's flat layer it went invisible for the entire session the moment that screen migrated
# to a WorldPanel (WorldPanelHost stands the flat layer down), so the one readout that tells
# you WHICH BUILD you are looking at was missing from the shipped configuration. Shown/hidden
# with the title screen by update_overlays.
var _version_layer: CanvasLayer
var _no_eligible_label: Label
# Car-park damage UI: the "repair it at the lift" note on a badly-handling focused car.
var _car_warning_label: Label

# Title screen cursor: a single left/right cursor over Start / Settings / Free Roam /
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
# ONE level, one row: Back / Career / Garage / Online. This used to be
# two levels — a "Drive" button that swapped the row for Career / Free Roam / Online —
# which bought nothing but an extra press and an extra Back for every trip to a stage.
# Career and Online are flat alongside Garage now, and Free Roam moved to the title
# screen (it needs no garage state at all). See features/menus.md.
var _garage_cursor := ButtonCursor.new()
var _garage_focus := 1          # which garage action the cursor sits on (defaults to Career)
# Career's index in the row, recomputed on every rebuild (see _refresh_garage_row) rather
# than hardcoded, so adding or moving a button can't silently desync it.
var _garage_career_index := 1
var _garage_actions_row: HBoxContainer  # the row _refresh_garage_row rebuilds in place

# Tuning-lift overlay widgets.
@warning_ignore("unused_private_class_variable")  # shared with hq_tuning_lift.gd
var _lift_info_panel: VBoxContainer  # bottom-left car readout: selector row + stats row (hidden when a sub-menu is open)
@warning_ignore("unused_private_class_variable")  # shared with hq_tuning_lift.gd
var _lift_car_label: Label      # the selected car's name, in the selector row's middle box
@warning_ignore("unused_private_class_variable")  # shared with hq_tuning_lift.gd
var _lift_car_stats_label: Label  # that car's stats, on the row under the selector
@warning_ignore("unused_private_class_variable")  # shared with hq_tuning_lift.gd
var _lift_prev_button: Button   # the selector's "<" — previous owned car onto the lift
@warning_ignore("unused_private_class_variable")  # shared with hq_tuning_lift.gd
var _lift_next_button: Button   # the selector's ">" — next owned car onto the lift
@warning_ignore("unused_private_class_variable")  # shared with hq_tuning_lift.gd
var _lift_hub_controls: HBoxContainer  # the HUB page: one row of Back + Upgrades/Tuning + Test Drive buttons

# The HUB page is a TWO-ROW manual cursor, which is why there are two ButtonCursors and a
# row index rather than one flat row:
#
#   SELECTOR row:  [ < ]  CAR NAME  [ > ]      _lift_selector_cursor / _lift_selector_focus
#   ACTIONS row:   < Back | Upgrades | Tuning | Test Drive    _hub_cursor / _hub_focus
#
# left/right move WITHIN the active row, up/down move BETWEEN the rows, select fires the
# active row's item. Only the active row paints a highlight (_refresh_hub_focus), so there
# is never any doubt which of the two a press will hit. As elsewhere in the diegetic HQ,
# hq owns the indices (tests read them) and ButtonCursor owns the behaviour.
enum LiftRow { SELECTOR, ACTIONS }
@warning_ignore("unused_private_class_variable")  # shared with hq_tuning_lift.gd
var _lift_row: int = LiftRow.ACTIONS  # which row the cursor is on
@warning_ignore("unused_private_class_variable")  # shared with hq_tuning_lift.gd
var _hub_cursor := ButtonCursor.new()
@warning_ignore("unused_private_class_variable")  # shared with hq_tuning_lift.gd
var _hub_focus := 1             # which hub item the cursor sits on (0 = Back, 1 = Upgrades, 2 = Tune, 3 = Test Drive)
@warning_ignore("unused_private_class_variable")  # shared with hq_tuning_lift.gd
var _lift_selector_cursor := ButtonCursor.new()
@warning_ignore("unused_private_class_variable")  # shared with hq_tuning_lift.gd
var _lift_selector_focus := 0   # which chevron the cursor sits on (0 = prev, 1 = next)
# The body box of the sub-menu page (TUNE/UPGRADES). The page itself is a MenuPage — the
# shared house shape: a box that HUGS its contents with a gap to the screen edges, plus a
# gapped horizontal action row below it (see menu_page.gd). Only the box is held here,
# because its visibility is what shows/hides the page; reach the page as its parent.
@warning_ignore("unused_private_class_variable")  # shared with hq_tuning_lift.gd
var _lift_menu_bg: PanelContainer
# The heading's row. Held because VISIBILITY is toggled here, not on the label —
# see _refresh_lift_ui.
# A sub-page's bottom ACTION ROW: "< Back" always, plus the TUNE page's own actions (see
# HqOverlays.build_lift_overlay). It is a SIBLING of the body box rather than a child — that
# is what makes the gap between body and actions read as a gap — so its visibility is gated
# with the page rather than riding on _lift_menu_bg's.
@warning_ignore("unused_private_class_variable")  # shared with hq_tuning_lift.gd
var _lift_page_actions: HBoxContainer
@warning_ignore("unused_private_class_variable")  # shared with hq_tuning_lift.gd
var _lift_back_button: Button   # the shared "< Back", leading the row above
@warning_ignore("unused_private_class_variable")  # shared with hq_tuning_lift.gd
var _tune_action_buttons: Array[Button] = []  # TuningPanel's Reset / Wheels, placed in the row above
@warning_ignore("unused_private_class_variable")  # shared with hq_tuning_lift.gd
var _tune_panel: TuningPanel         # the TUNE menu (sliders) — shared with the start line
@warning_ignore("unused_private_class_variable")  # shared with hq_tuning_lift.gd
var _lift_upgrades_box: UpgradesGrid  # the UPGRADES page (shared UpgradesGrid component)


func _ready() -> void:
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
		if _maybe_redirect_to_overworld():
			return
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
	# The OVERWORLD hub redirect (dev flag, ships off). It sits HERE — after the cloud pull —
	# and the placement is load-bearing in four ways; see _maybe_redirect_to_overworld.
	#
	# The fourth was found the hard way: it used to run BEFORE _await_boot_pull, so it decided
	# using whatever stale local profile was on disk. On a machine whose local file had been
	# clobbered (a test writing a fresh default over it), it saw a profile with no cars and
	# declined — dropping the player into the map-table HQ even though their real, 10-car cloud
	# career arrived milliseconds later. The comment above says it outright: let the pull land
	# BEFORE anything reads the profile. A redirect gated on what the profile OWNS is exactly
	# such a read.
	if _maybe_redirect_to_overworld():
		loading.queue_free()
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
	# one prop per frame while they read the title (see _prewarm_free_roam_deferred), and
	# only while the player is actually STILL (_prewarm_should_wait).
	#
	# A boot that does NOT land on the title shot is a RETURN — the podium's Continue, or a
	# quit back to HQ — so the player is mid-career and heading somewhere (usually the map
	# table, a tap away) rather than reading a title. Stamp the arrival as interaction so the
	# trickle waits out one idle window instead of firing its heaviest frames into the first
	# thing they do.
	if _view != View.EXTERIOR:
		_last_input_ms = Time.get_ticks_msec()
	_carpark_ui._prewarm_free_roam_deferred()
	# Ask GitHub Pages whether a newer native build has shipped. NOT awaited: it is a
	# network round trip and boot must never wait on one — the player gets an
	# interactive HQ now, and the prompt (if any) arrives a beat later.
	_check_for_update()


# Tell the player when a newer NATIVE build is out — every native build, Play
# included: a Play testing track does not reliably push updates to its testers. Only
# the destination differs (UpdateCheck.store_url / store_label). All of the policy
# lives in UpdateCheck — see features/update-check.md; this is placement + modal.
func _check_for_update() -> void:
	if not UpdateCheck.applicable():
		return
	# Cloud.rest is the project's single HTTPRequest owner (one in-flight request,
	# queued callers) — reusing it keeps that invariant instead of adding a second
	# client for one GET per boot.
	var latest: int = await UpdateCheck.fetch_latest_build(Cloud.rest)
	if not is_inside_tree():
		return
	var current := UpdateCheck.current_build()
	var dismissed := int(Save.get_setting(UpdateCheck.DISMISSED_SETTING, 0))
	if not UpdateCheck.should_prompt(current, latest, dismissed):
		return
	# TITLE SHOT ONLY, re-checked AFTER the await: the fetch outlives the boot frame,
	# so by now the player may have walked into the garage or the map table. An update
	# notice landing on top of that is an interruption; the next boot to the title
	# raises it instead (nothing is recorded as dismissed until it is actually seen).
	if _view != View.EXTERIOR:
		return
	# Record the dismissal from the ACTIONS, not here — ConfirmPopup.open returns null
	# when another modal already owns the screen, and a prompt that never appeared must
	# not count as one the player has been shown.
	var remember := func() -> void:
		Save.set_setting(UpdateCheck.DISMISSED_SETTING, latest)
	ConfirmPopup.open(self, "Update available",
		UpdateCheck.prompt_body(current, latest),
		[
			# Leaving is left, proceeding is right (features/menus.md → "Button order");
			# Back routes to index 0, so Esc / gamepad-B is "Not now".
			{"label": "Not now", "callback": remember},
			{"label": UpdateCheck.store_label(), "callback": func() -> void:
				remember.call()
				OS.shell_open(UpdateCheck.store_url())},
		], 1)


# Hand this boot over to the OVERWORLD hub instead of the map-table HQ, and say whether we
# did. False (an ordinary HQ boot) whenever the dev flag is off, so with `overworld_enabled`
# false this is one bool read and nothing else changes.
#
# WHERE THIS IS CALLED FROM MATTERS, and the top of _ready is the wrong place — all four of
# these are real (docs/superpowers/specs/2026-08-17-overworld-hq-design.md → "Where the boot
# redirect goes"):
#   0. It must run AFTER _await_boot_pull(): this decision READS THE PROFILE (does it own a car
#      to field?), and a boot-time cloud pull is what settles the profile. Deciding first means
#      deciding on whatever stale local file is on disk — which on a machine whose local profile
#      had been clobbered meant refusing a player with a full cloud career, because the copy on
#      disk had no cars in it. This was a real bug, not a hypothetical.
#   1. It must run AFTER _ensure_selection(): the overworld fields the profile's selected car,
#      and Save.selected_car() is what heals an unset/stale selection into a real one.
#   2. It must run AFTER _should_autostart_benchmark(): redirecting first breaks the ?bench=1
#      web profiling boot, which is supposed to reach Benchmark.start() and nothing else.
#   3. It must not skip _build_hq's consumption of the RallySession one-shots. _build_hq is
#      the ONLY consumer of `return_to_garage` / `return_to_map` /
#      `pending_car_reveal_instance_id` / `pending_rally_pick_id`, so a redirect that bypasses
#      it leaves them set forever: the overworld's garage zone raises `return_to_garage` and
#      loads hq.tscn, which would bounce straight back to the overworld in an INFINITE LOOP;
#      the won-car present-box reveal would be silently lost; and a stale `return_to_map`
#      would later dump the player on the very map table the overworld replaces.
#
# So the one-shots are READ here (never cleared here — clearing is _build_hq's job, and
# consuming them in two places is how one of them goes missing) and any of them means "the
# player asked for hq.tscn": stay, and let _build_hq route to the garage / the table / the
# present box / the car picker as it already does. That "decline when return_to_garage is set"
# rule IS the infinite-loop guard.
#
# NOT gated on owning a car. It used to be (see the note at the gate below): a fresh profile had
# nothing to field and the starter picker existed only in hq.tscn's car park, so redirecting one
# stranded it. The overworld now runs the starter pick itself, in place, so a fresh profile is a
# case it handles rather than a reason to refuse. hq.tscn's own pickers are untouched and remain
# the shipped flow whenever `overworld_enabled` is off.
func _maybe_redirect_to_overworld() -> bool:
	if not Config.data.overworld_enabled:
		return false
	# NEVER redirect under --headless. The flag is a DEV switch that a developer leaves on for
	# days at a time (and `SettingsMenu._enter_overworld` flips it on the live config), while the
	# test suite reads that same authored config — so with it on, every one of the ~40 tests that
	# instantiates hq.tscn would be diverted to a scene it never asked for and the HQ would never
	# get built. The suite must be immune to the state of a dev flag.
	#
	# This does not hide the redirect from testing: its guards are pure and can be exercised by
	# calling this directly, and the overworld scene has its own coverage.
	if Platform.is_headless():
		return false
	# NO CAR GATE ANY MORE. This used to refuse a profile with no selected car, because the
	# overworld had nothing to field and no way to pick one — the starter picker lived only in
	# hq.tscn's car park. The overworld now picks a car IN PLACE (OverworldPicker), including the
	# STARTER pick, which it opens on boot when nothing is owned and grants through the same
	# Save seam. So "owns nothing" is no longer a reason to keep a player out; it is the case the
	# hub handles first. The shipped HQ keeps its own pickers intact for the flag-off path.
	if RallySession.return_to_garage or RallySession.return_to_map \
			or RallySession.pending_car_reveal_instance_id >= 0 \
			or RallySession.pending_rally_pick_id != "":
		return false
	Scenes.change_to(get_tree(), Scenes.OVERWORLD)
	return true


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
	# Resolution sweep: an explicit logical render height for this run (0/absent =
	# authored default). DisplayStretch applies it while Benchmark.active.
	Benchmark.render_height = int(data.get("render_height", 0))


# Push the dither grid + colour grade onto the PostProcess container's material, so
# the HQ's 3D world gets the same PS1 treatment as the driving stage (features/
# rendering.md → "Colour grade"). Shares GameConfig.apply_post_process with
# world.gd so the two screens can never grade differently. The station OVERLAYS are
# CanvasLayers drawn above the container and stay ungraded, exactly like the HUD.
func _apply_post_process() -> void:
	var container := get_node_or_null("PostProcess") as SubViewportContainer
	if container == null or container.material == null:
		return
	Config.data.apply_post_process(container.material as ShaderMaterial)


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
	_challenge_ui = HqChallenge.new(self)
	_multiplayer_ui = HqMultiplayer.new(self)
	_table_ui = HqTable.new(self)
	_carpark_ui = HqCarpark.new(self)
	# Constructed HERE, alongside the other station collaborators and BEFORE the overlays
	# are built: hq_overlays.gd wires the lift's buttons to the controller's forwarders
	# (_hq._lift_hub, _hq._cycle_lift_car, …), which delegate into _tuning_lift, and
	# _refresh_map_pins below runs through _map_table_ui.
	_map_table_ui = HqMapTable.new(self)
	_tuning_lift = HqTuningLift.new(self)
	_present_ui = HqPresentReveal.new(self)
	_overlays.build_title_overlay()
	_overlays.build_garage_overlay()
	_overlays.build_table_overlay()
	# The rally-detail panel is a shared component now (RallyDetail — the overworld hub opens
	# the same card), so it is CONSTRUCTED here with this host's three callbacks rather than
	# built inside HqOverlays: "< Map" hides it, "Enter Rally" walks to the car park, and the
	# dev "win" button is offered only because this host has a cheat to bind (the overworld
	# passes an empty Callable and gets no button).
	_detail_ui = RallyDetail.new()
	_detail_ui.build(self, _table_ui._hide_detail, _enter_car_screen,
		_dev_complete_selected_rally)
	_overlays.build_lift_overlay()
	_overlays.build_car_overlay()
	_overlays.build_settings_overlay()
	_overlays.build_challenge_overlay()
	_overlays.build_multiplayer_overlay()
	# Enable 3D mouse/touch picking so the table / lift / pins receive input_event.
	get_viewport().physics_object_picking = true
	_refresh_map_pins()
	# Returning from the podium's final Continue opens straight on the GARAGE view
	# (one-shot flag set by podium.gd); a normal boot opens the exterior title.
	# Read + clear it now so it never lingers past this boot.
	var want_garage: bool = RallySession.return_to_garage
	RallySession.return_to_garage = false
	# Returning from the OPENING rally goes one better and opens the MAP, because that
	# arrival IS the beat — first sight of the table, first rally already complete, its
	# neighbours revealing around it (todo/opening-rally.md). Takes priority over
	# `return_to_garage`, which the podium raises on every finish including this one.
	var want_map: bool = RallySession.return_to_map
	RallySession.return_to_map = false
	# A car was WON: open on the present box before anything else. It outranks both other
	# destinations because it is the payoff for the rally just driven, and the player is
	# held here until they open it (_car_back).
	var reveal_id: int = RallySession.pending_car_reveal_instance_id
	RallySession.pending_car_reveal_instance_id = -1
	# The overworld's "spawn me back at the rally I just drove" one-shot. THIS hub does not
	# use it, but it must still die here: a rally that ends while the overworld is disabled
	# (or under --headless, where hub_path forces this scene) lands on the HQ instead, leaving
	# the id set for the rest of the process. The player would then open the overworld later
	# from the settings/dev entry point and spawn at a rally they finished ages ago rather
	# than at the garage. Consumed alongside the other one-shots, for the same reason.
	RallySession.overworld_return_rally_id = ""
	# The OVERWORLD hub asked for a rally: a zone activation names the rally but NOT the car
	# (the car you drove there isn't necessarily the car you want to race), so boot straight
	# into that rally's car picker. Same destination the map table's "Enter Rally — choose car"
	# reaches, sourced from the one-shot instead of a pin tap. Read + cleared here because
	# _build_hq is the one place the session's one-shots are consumed — see
	# _maybe_redirect_to_overworld for why a redirect that skips this loops forever.
	var pick_id: String = RallySession.pending_rally_pick_id
	RallySession.pending_rally_pick_id = ""
	if reveal_id >= 0 and not Save.get_car(reveal_id).is_empty():
		_enter_present_box(reveal_id)
	elif pick_id != "" and not RallyLibrary.by_id(pick_id).is_empty():
		_selected_rally_id = pick_id
		_enter_car_screen()
	elif want_map:
		# Via _enter_table, not go_to(View.TABLE): the reveal parade is armed there, and
		# entering the view directly would show the neighbours already lit with no beat.
		_table_ui._enter_table()
	else:
		# Boot to the garage (returning from a rally) or the title shot. The collection is
		# unbounded, so there's no garage-full gate to clear first.
		go_to(View.GARAGE if want_garage else View.EXTERIOR, true)
	# Playing the WEB build in an Android browser: point the player at the itch.io
	# APK once per boot — the native build performs far better than mobile web.
	# Only over the title shot (a normal boot).
	if _should_show_android_app_notice() and _view == View.EXTERIOR:
		_show_android_app_notice()
	# Web fullscreen/landscape (the "tap to play" prompt) is handled globally by the
	# WebFullscreen autoload so it works in every scene, including while driving.


# Make sure a valid car is selected (the one raised on the lift). Save.selected_car
# self-heals to the first owned car when the stored id is unset/invalid.
func _ensure_selection() -> void:
	Save.selected_car()


# --- 3D world (built by HQEnvironment) ---------------------------------------

# World X of the centre of bay `i` (0 = left / −X). Delegates to HQEnvironment so the
# parked-car lineup (_build_lineup) and the painted bay dividers agree on the grid.
func _bay_center_x(i: int, bays: int) -> float:
	return HQEnvironment.bay_center_x(i, bays)


# --- Kept on HqController, NOT moved with the map-table cut ------------------
# The pin layer — every pin, readout box, reveal link and the exploration fog — is
# HqMapTable (scripts/hq_map_table.gd) now. Three things stayed behind:
#   * `build_fog_mask`, a STATIC re-export of MapFog.build. features/overworld.md and
#     features/hq.md both document it as `HqController.build_fog_mask(profile)`, and the
#     overworld's terrain shader is its second consumer, so the public name stays here.
#   * `PRIZE_CAR_FACING_TURN`, because overworld.gd and overworld_zones.gd read it as
#     `HqController.PRIZE_CAR_FACING_TURN` — hq.gd created that constant, and the overworld
#     deliberately shares it rather than inlining a second PI.
#   * `_stars_for` / `_entry_plan` / `_has_eligible_car` / `_refresh_meter`, which the map
#     is only ONE consumer of (hq_carpark.gd, hq_challenge.gd and the menu tests all call
#     them off the controller).
# The pin STATE (_pins, _pins_root, _map_plane, _pins_stamp, _table_focus_node,
# _table_targets_cache) also stays on this controller: HqTable navigates it and hq.gd's
# camera/overlay code reads it, so it is shared, not the pin layer's private bookkeeping.


# --- Map-table forwarders (the two names the pin layer is reached by) ---------
# hq_table.gd calls both of these as `_hq._refresh_map_pins` / `_hq._paint_pin_readout`, and
# the menu tests call `hq._refresh_map_pins()` directly. Those are the pin layer's public
# surface, so the NAMES stay on the controller and delegate — the cut is not allowed to move
# a call site.

# (Re)build the rally pins on the table's map plane. See HqMapTable._refresh_map_pins for
# what is drawn, the rebuild-skip stamp, and why `hold_locked` exists.
func _refresh_map_pins(hold_locked: Array = []) -> void:
	_map_table_ui._refresh_map_pins(hold_locked)


# Show or hide ONE pin's floating readout (and arm its off-screen viewport to match) — the
# single place a readout's visibility changes. See HqMapTable._paint_pin_readout.
func _paint_pin_readout(pin: Node3D, shown: bool) -> void:
	_map_table_ui._paint_pin_readout(pin, shown)


# Rasterise the lit region into a mask: 1 where explored, 0 in the dark, with a soft rim.
# Normalised map space, so it is the same mask whatever is sampling it — the map table's plane
# via UV, or the overworld's terrain via world position / overworld_size_m.
#
# Reads RallyLibrary.lit_sources — the SAME derivation that decides which rallies are
# enterable — so what the player can see lit and what they can actually enter can never
# disagree. That is the whole reason the predicate was factored out.
#
# MOVED to `scripts/map_fog.gd` (`MapFog.build`). It was only ever here because this is where
# the map fog was invented — it touches no HQ state, and slice 3 gave it a second consumer (the
# overworld's terrain shader), which made a hub-UI file the wrong home for it. This wrapper
# stays so the table's own call site and the tests that reach for it keep resolving.
static func build_fog_mask(profile: Dictionary) -> ImageTexture:
	return MapFog.build(profile)


# Half turn applied to a prize car's heading, because car.tscn's body faces -Z while the
# atan2(x, z) yaw that aims it is written for a +Z-forward node. Isolated as a constant so
# "the cars point the wrong way" is a one-value fix rather than an algebra puzzle. The yaw
# itself is derived in HqMapTable._attach_prize_car_marker (the table) and
# OverworldZones.facing_yaw (the overworld); both read this.
const PRIZE_CAR_FACING_TURN := PI

# Stars earned in a rally from the player's best finish: 1st → 3, 2nd → 2, 3rd → 1,
# anything else (or never placed) → 0.
#
# The derivation lives on RallyDetail (both hubs' panels need it); this is the name the pins,
# the table and the menu tests already call it by.
func _stars_for(rally_id: String) -> int:
	return RallyDetail.stars_for(rally_id)


# The eligibility decision for one owned `car` against `rally`, derived in ONE place so
# the pin-flag check (_has_eligible_car) and the car-park lineup (_build_eligible_lineup)
# can't drift. Returns {eligible}: whether the car, exactly as the player left it, can
# enter this rally.
#
# Entry is purely CATEGORICAL (body/country/doors/cylinders/displacement/drive mode), so
# there is no "too fast" or "too slow" car — only a car of the wrong kind. It judges the
# car AS BUILT and proposes nothing: a wrong-drivetrain car is simply ineligible, and
# converting it is a garage decision the player makes themselves, where the conversion's
# star price is on screen (features/upgrade-catalogue.md).
#
# This used to hand back a `drivetrain` field naming a mode the car park would silently
# switch to at the Start button and revert afterwards. That is gone — see
# hq_carpark.gd::_build_eligible_lineup.
#
# The rule itself lives on RallyDetail with the eligibility read-out it feeds, so the overworld's
# copy of that panel derives it identically. This is the name hq_carpark.gd and the tests use.
func _entry_plan(rally: Dictionary, car: Dictionary) -> Dictionary:
	return RallyDetail.entry_plan(rally, car)


# Whether the player owns at least one car that can enter `rally` — drives the pin
# flag's green (raceable) vs grey (unavailable) pennant.
func _has_eligible_car(rally: Dictionary) -> bool:
	for car in Save.profile.get(Save.KEY_CARS, []):
		if bool(_entry_plan(rally, car)["eligible"]):
			return true
	return false


func _refresh_meter() -> void:
	if _map_meter == null:
		return
	# The SPENDABLE balance, with no denominator. Stars are currency now, so what matters
	# is what the player can take to the present box — and there is no meaningful maximum
	# to divide by: the balance falls when they buy a car and the Rally Challenge tops it up
	# without bound. See todo/star-economy.md.
	# DIGITS ONLY: the word "Stars" is now the star polygon beside it (build_table_overlay).
	_map_meter.text = "%d" % Save.stars_available()


# --- 3D picking handlers (real play; tests call the targets directly) --------

func _on_table_input(_cam: Node, event: InputEvent, _pos: Vector3, _normal: Vector3, _shape: int) -> void:
	if _view == View.GARAGE and _is_click(event):
		_table_ui._enter_table()


func _on_lift_input(_cam: Node, event: InputEvent, _pos: Vector3, _normal: Vector3, _shape: int) -> void:
	if _view == View.GARAGE and _is_click(event):
		_enter_lift()


func _on_pin_input(_cam: Node, event: InputEvent, _pos: Vector3, _normal: Vector3, _shape: int, rally_id: String) -> void:
	# Select on RELEASE, and only if the press didn't turn into a pan-drag — so
	# dragging across the map to pan never accidentally opens a rally.
	if _view == View.TABLE and not _detail_open and not _revealing and not _table_dragged \
			and _is_release(event):
		_table_ui._on_rally_pin(rally_id)


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


# THE MODAL PAGE SHAPE: a content-hugging body box with the exit control PINNED in a
# horizontal action row below it. Delegates to MenuPage — read menu_page.gd for the layout
# rules; this wrapper exists to keep the existing callers' return contract.
#
# Returns [layer, body, footer, root] — put variable-height content in `body`, put the
# control that LEAVES the page (Back / Done / Close) in `footer`, and hand `root` to
# MenuNav.attach / UITheme.enforce as before.
#
# WHY this exists, and why it isn't optional for a modal page. Every overlay here is laid
# out against a LOGICAL canvas whose height is fixed by display_stretch.gd —
# DisplayStretch.DESIGN_HEIGHT, read from project.godot, the same on every target — while the WIDTH
# follows the device aspect and gets narrow on a phone, which makes autowrapped labels wrap
# to more lines. So a fixed, unscrolled column whose Back button is laid out AFTER the
# content doesn't overflow by device roulette: with a long restriction string or a server
# error spliced in, the exit is deterministically pushed off the bottom of the frame. And
# there is no second way out — `menu_back` binds Escape and gamepad B only (project.godot),
# so a touch player with the exit off-screen is simply TRAPPED in the page. Scrolling the body
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
	# MenuPage.open_modal is the shared implementation of BOTH halves of this shape — the
	# content-hugging body box with a gapped horizontal action row under it (see menu_page.gd
	# for the two layout rules and why they are not per-screen choices), AND the hosting: its
	# own CanvasLayer below ConfirmPopup, claiming the screen so a 3D WorldPanel underneath
	# cannot eat the page's clicks. This wrapper survives so the three existing callers keep
	# their [layer, body, footer, root] contract; new pages should call open_modal directly.
	var page := MenuPage.open_modal(self, {"margin": margin})
	return [page.get_parent(), page.body(), page.actions(), page]


# The widest a centred modal column may ask for on the CURRENT logical canvas. The frame's
# width is not a constant — it is DESIGN_HEIGHT * device_aspect / horizontal_stretch (see
# display_stretch.gd), so a narrow/portrait phone aspect can give well under the authored
# preferred width, and a hard-coded 460-wide column can already be wider than the whole
# screen. `chrome` is the horizontal space the surrounding container costs (overlay margins,
# panel padding). Desktop keeps the authored `preferred` width; only the narrow tiers shrink.
#
# `host` is the node the sized content will actually live under; it defaults to HQ itself,
# which resolves to the main viewport. Pass the real host if the content could ever sit on a
# WorldPanel — inside one, the canvas is the panel's `_frame`, unrelated to the main viewport
# width, and a column measured off the wrong one is either clipped or absurdly narrow.
func _modal_body_width(preferred: float, chrome := 88.0 * UITheme.UI_SCALE, host: Node = null) -> float:
	return RallyDetail.body_width(host if host != null else self, preferred, chrome)


# Let taps fall THROUGH an overlay to the 3D scene behind it — only buttons keep
# capturing input. Without this the full-rect container + its labels/spacer (all
# default MOUSE_FILTER_STOP) eat every touch and the 3D map (table / lift / pins,
# picked via Area3D) never receives a pick. Call after the overlay is populated.
func _passthrough_overlay(root: Control) -> void:
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for n in root.find_children("*", "Control", true, false):
		if not (n is BaseButton):
			(n as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE


# A plain Label with `text` and a `font_size` override — the Label.new() + font-size +
# add-child idiom repeated across the station overlays. Deliberately NOT UITheme.label,
# which forces a role colour + uppercase (a different look). Any further overrides
# (alignment, colour, autowrap, size flags) are applied by the caller after this returns.
func label(text: String, size: int) -> Label:
	return RallyDetail.plain_label(text, size)


# A quiet section heading for the rally-detail card. UITheme.enforce flattens every
# label to one size + uppercase, so a heading reads as a heading only by its dimmer
# colour and the grouping/spacing around it — not a larger font.
func detail_heading(text: String) -> Label:
	return RallyDetail.heading(text)


# A sidebar Label that wraps to its column width instead of drawing off the panel edge.
func detail_wrap_label() -> Label:
	return RallyDetail.wrap_label()


# A single-row "heading: value" pair — a fixed-width dim heading (detail_heading)
# beside the value (detail_wrap_label), added to `parent` as one HBoxContainer row.
# Used where the rally detail panel's heading-above-value-below shape (detail_heading
# + detail_wrap_label stacked) would cost more vertical space than the info is worth —
# the challenge screen's four sections, one line each instead of two. Returns the value
# Label for the caller to keep populating. Lives here beside the two builders it calls
# (and NOT with the challenge cut) because HqOverlays is its only caller.
func challenge_info_row(parent: VBoxContainer, heading_text: String) -> Label:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.px(8))
	parent.add_child(row)
	var heading := detail_heading(heading_text)
	heading.custom_minimum_size = Vector2(UITheme.px(140), 0)
	row.add_child(heading)
	var value := detail_wrap_label()
	row.add_child(value)
	return value


# True when the WEB build is running in an Android browser — the one case where the
# player could instead install the (much faster) APK from the itch.io page. iOS has
# no app to offer and desktop web performs fine, so neither gets the notice.
func _should_show_android_app_notice() -> bool:
	return OS.has_feature("web_android")


# One-per-boot notice over the title shot: mobile-web performance is poor, the APK
# is much faster. Stands the title screen down while it's up so its MenuNav can't fight
# this one for focus; dismissing restores the title (whose MenuNav re-grabs focus
# via visibility_changed).
#
# THROUGH update_overlays, NOT `_title_layer.visible = false` — the same correction the
# challenge overlay already carries (see update_overlays). With world menus on, the title
# TREE is not in that layer at all: it has been migrated into a 3D WorldPanel, and the flat
# layer is already hidden and empty. Writing it stood nothing down, so the notice was drawn
# over a live, still-navigable title menu with both MenuNavs answering the same keypress.
# The title's own visibility rule now reads `_android_notice_layer == null`, so it is one
# authoritative answer that reaches whichever host is actually holding the tree.
func _show_android_app_notice() -> void:
	if _android_notice_layer != null:
		return
	# Scrolled body + pinned footer (_make_modal_overlay): this is the FIRST thing a
	# mobile-web player sees, on a narrow portrait canvas, and a dismissal they can't
	# reach means they never get into the game at all.
	var made := _make_modal_overlay()
	_android_notice_layer = made[0]
	var root_box: VBoxContainer = made[1]
	var footer: HBoxContainer = made[2]
	var root: Control = made[3]  # the MenuPage itself — for MenuNav.attach / UITheme.enforce
	# _android_notice_layer is set above, so this stands the title down on whichever host is
	# holding it (flat layer or world panel).
	update_overlays()
	root_box.alignment = BoxContainer.ALIGNMENT_CENTER

	var msg := Label.new()
	msg.text = "Heads up: the browser version runs much slower on phones.\nFor smooth performance, install the free Android app from itch.io."
	msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	msg.add_theme_font_size_override("font_size", UITheme.px(22))
	root_box.add_child(msg)

	var get_app := Button.new()
	get_app.text = "Get the Android app"
	get_app.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	get_app.custom_minimum_size = Vector2(UITheme.px(320), UITheme.px(52))
	get_app.pressed.connect(func() -> void: OS.shell_open(ANDROID_APP_URL))
	root_box.add_child(get_app)

	# "Continue in browser" is the way OUT of this notice, so it is pinned in the footer
	# rather than laid out under a message that wraps to more lines on a narrow phone.
	var stay := Button.new()
	stay.text = "Continue in browser"
	stay.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	stay.custom_minimum_size = Vector2(UITheme.px(320), UITheme.px(44))
	stay.pressed.connect(_dismiss_android_app_notice)
	footer.alignment = BoxContainer.ALIGNMENT_CENTER
	footer.add_child(stay)

	MenuNav.attach(root, {first = get_app, on_back = _dismiss_android_app_notice})


func _dismiss_android_app_notice() -> void:
	if _android_notice_layer == null:
		return
	_android_notice_layer.queue_free()
	_android_notice_layer = null
	# update_overlays, not `_title_layer.visible = ...`: with world menus on, writing the
	# flat layer un-hid an EMPTY layer beside the live panel, breaking the "whichever host
	# isn't holding the tree must be hidden" invariant until the next view change.
	update_overlays()
	_refresh_title_focus()


# Build the ◄/► car-selector nav row for the car park (_build_car_overlay): a "<" prev
# button, a centred car-name label, and a ">" next button in an HBox, with prev/next
# wired to _cycle_focus(∓1). Returns [nav_row, center_label] so the caller stashes the
# label in its own member field (_car_name_label).
# Stable forwarder for the car-park nav row's < > buttons. A Godot Callable stores an
# ObjectID and does NOT hold a strong reference, so connecting the buttons straight to
# `_carpark_ui._cycle_focus` would leave them pointing at a FREED HqCarpark the moment
# anything reassigns `_carpark_ui` (which tests/headless/carpark_null_spawn_double.gd
# does). Routing through the node keeps the connection valid across a swap.
func _nav_cycle_focus(step: int) -> void:
	_carpark_ui._cycle_focus(step)


func _build_carpark_nav_row() -> Array:
	var nav := HBoxContainer.new()
	nav.add_theme_constant_override("separation", 8)
	var prev := Button.new()
	prev.text = "<"
	prev.focus_mode = Control.FOCUS_NONE
	prev.pressed.connect(_nav_cycle_focus.bind(-1))
	nav.add_child(prev)
	var center := label("", 18)
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# Wraps rather than clipping — the name + position ("SWERVE SURGER R/T  (1 OF 2)") is the
	# longest line on the car screen and was losing its tail off the edge of a world panel.
	center.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# Backed like the other bare labels, but EXPAND_FILL rather than SHRINK_CENTER: this one
	# is the stretchy middle of the chevron row, and shrinking it would let the < and >
	# collapse toward the centre.
	var center_backing := WorldPanel.text_backing(center)
	center_backing.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nav.add_child(center_backing)
	var next := Button.new()
	next.text = ">"
	next.focus_mode = Control.FOCUS_NONE
	next.pressed.connect(_nav_cycle_focus.bind(1))
	nav.add_child(next)
	return [nav, center]


# --- Settings page -----------------------------------------------------------


# Open the Settings page. `gate` = the mandatory pre-rally pick (bottom button starts
# the rally); otherwise it's the title-screen Settings (bottom button returns to the
# title). Always reset to the category list so each open starts at the top level.
func _open_settings(gate: bool) -> void:
	_settings_gate = gate
	# Shown only for the gate, where it explains the forced pick; otherwise hidden (see
	# hq_overlays._build_settings_overlay).
	_settings_sub.text = "Choose your touch controls to start:" if gate else ""
	_settings_sub.visible = gate
	# The pre-rally gate jumps straight to the mobile-controls page — the player only
	# needs to pick a touch layout, not wade through the full category list. The
	# title-screen / pause entry opens on the category list as usual.
	if gate:
		_settings_menu.show_schemes()  # emits page_changed → sets the bottom button label
	else:
		_settings_menu.show_list()
	go_to(View.SETTINGS)


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
	go_to(View.EXTERIOR)


# --- Confirmation dialog -----------------------------------------------------

# Show only the active station's overlay (detail is a TABLE sub-state).
func update_overlays() -> void:
	# NOTE: there is deliberately NO `var cfg := Config.data` local here. The closures below read
	# Config.data at call time instead, because the F8 hot reload swaps the whole GameConfig instance
	# — a captured one goes stale the moment it is pressed, which is exactly how a ui_scale retune
	# stopped reaching the panels. Same reason _sync_panel re-binds the callables on every sync.
	# The un-migrated screens set their layer directly; the MIGRATED ones go through _sync_panel,
	# which owns its layer's visibility because whichever host isn't holding the tree must be
	# hidden — an empty CanvasLayer or an unfed panel left armed is the bug this prevents.
	_table_layer.visible = _view == View.TABLE and not _detail_open
	_settings_layer.visible = _view == View.SETTINGS
	# THE RALLY DETAIL PAGE STAYS FLAT, deliberately — it is not a migration that was forgotten.
	# It is the densest page in the HQ (name, region, restriction, record, star row, reward line) read
	# at the map table, whose camera sits under 2 m from the table looking steeply DOWN; a panel there
	# is read at a punishing angle and has to be tiny to fit the shot. A full-frame page is simply the
	# better read for this one screen. See features/world-panel.md -> "Adoption rule".
	# Null-guarded because `update_overlays` can run BEFORE the detail panel is constructed:
	# _build_hq builds the overlays in sequence with awaits between them, so a caller that lands
	# mid-build (a test awaiting a single frame, a station entered early) sees the layers built so
	# far and not the ones after it. `_detail_open`'s getter already answers false for a missing
	# panel, so this is the same tolerance on the write side rather than a new concession.
	var detail_layer := _detail_layer
	if detail_layer != null:
		detail_layer.visible = _view == View.TABLE and _detail_open
	# THE ONLINE CHALLENGE SCREEN IS FLAT TOO, by the same choice as the rally detail: a dense
	# info page (period, ceiling, eligible cars, leaderboard) that reads better with the whole frame
	# than welded to a panel in the garage. Migrated, tried, reverted — see features/world-panel.md.
	#
	# Driven by _challenge_shown rather than by writing the layer from the open/close handlers, which
	# is KEPT from the migration on purpose: it is a modal rather than a View, and hq's own
	# _unhandled_input needs one authoritative answer to "is the challenge up?" so the garage below
	# cannot react to the same keypress.
	_challenge_layer.visible = _challenge_shown
	# The Multiplayer entry screen is flat too, same choice and same reason as the
	# Online challenge screen just above.
	_multiplayer_layer.visible = _multiplayer_shown
	# The title stands down while the ANDROID BOOT NOTICE is over it, for the same reason the
	# garage does under the challenge modal below: the modal owns the screen, and two live
	# MenuNavs would fight over one keypress. Driven from the notice's own existence rather
	# than by writing `_title_layer.visible` in its open/close handlers — that only ever
	# addressed the FLAT host, so with world menus on it stood nothing down at all.
	var title_shown := _view == View.EXTERIOR and _android_notice_layer == null
	_sync_panel("title", _title_layer, _title_root, title_shown,
		_title_panel_xform, _title_panel_spec)
	# The build watermark follows the title screen but lives on its own layer, so it is legible
	# on either host (see _version_layer).
	if _version_layer != null:
		_version_layer.visible = title_shown
	# The garage stands down while the CHALLENGE modal is over it — the modal owns the screen. This
	# used to be an ad-hoc `_garage_layer.visible = false` inside _open_challenge_overlay, which
	# stopped working the moment that function also had to call update_overlays (this function then
	# re-showed the garage a line later). It is a visibility RULE, so it belongs here with the rest.
	_sync_panel("garage", _garage_layer, _garage_root,
			_view == View.GARAGE and not _challenge_shown and not _multiplayer_shown,
		_garage_panel_xform, _garage_panel_spec)
	_sync_panel("lift", _lift_layer, _lift_root, _view == View.LIFT,
		_lift_panel_xform, _lift_panel_spec)
	_sync_panel("car", _car_layer, _car_root, _view == View.CARPARK,
		_car_panel_xform, _car_panel_spec)
	# BEFORE _normalize_menus: this writes dynamic text, so it has to run while the
	# house rules (uppercase) are still to come, not after them.
	_refresh_repair_button()
	_normalize_menus()


# Apply the design-system house rules (uppercase + one font size + fixed
# single-line button height) to every overlay. Re-run on each view change and
# after any dynamic text refresh so the rules keep holding as labels change.
func _normalize_menus() -> void:
	for layer in [_title_layer, _garage_layer, _table_layer, _detail_layer,
			_lift_layer, _car_layer, _settings_layer, _version_layer]:
		if layer != null:
			UITheme.enforce(layer)
	# A migrated tree may not be under its CanvasLayer at all (world-space host), and the
	# house rules have to reach it wherever it lives — enforce walks from a node DOWN, so an
	# empty layer enforces nothing.
	#
	# ASKS THE HOST, not the tree's parent. `tree.get_parent() != layer` was a second spelling
	# of "is this migrated?", duplicated from WorldPanelHost.release_tree and wrong the moment a
	# tree is parked anywhere but its two homes. WorldPanelHost.is_world() is the one answer.
	#
	# AND RE-APPLIES THE HOST STYLE (force). This function is the house convention for "content
	# changed, re-assert the rules" — hq.gd calls it after rebuilding the garage row, which
	# never goes through go_to. WorldPanel.apply_host_style's cheap
	# early-out keys off the tree ROOT, so nodes added by such a rebuild kept their flat
	# StyleBoxEmpty and never got centred: a bare label over a sunlit car park. Forcing the
	# re-walk here means every rebuild path already in the convention gets the panel pass too.
	for key in ["car", "lift", "title", "garage"]:
		var host := _panel_host(key)
		if host == null or host.tree == null or not host.is_world():
			continue
		UITheme.enforce(host.tree)
		WorldPanel.apply_host_style(host.tree, true, true)


# Re-read the authored config from disk and re-apply it, keeping the player where they are. The F8
# debug key (see _unhandled_input) and the tuning loop in features/world-panel.md.
#
# PRESERVES THE WORLD-MENU TOGGLE. `world_space_menus` is the one value here that F7 flips live, so a
# straight reload put it back to whatever the file says — F8 fought F7 and looked like "reload just resets it to
# the flat menus". The toggle is a live A/B switch for this session, not one of the values being
# tuned, so it survives the reload while everything else is taken from the file.
#
# Re-applies rather than merely reloading, because the two things NOT read per frame have to be
# poked: update_overlays re-syncs the panel hosts (panel height and ui_scale are baked in at
# construction, so retuning either rebuilds the panel), and the camera is re-posed because a
# station's pose is only recomputed when it moves. Panel offsets, yaw, pitch and the camera shifts
# need none of this — WorldPanel re-reads its anchor every frame.
func hot_reload_config() -> bool:
	var was_world := bool(Config.data.world_space_menus)
	if not Config.reload_from_disk():
		return false
	Config.data.world_space_menus = was_world
	update_overlays()
	_move_camera_to(_camera_target_xform() if _view == View.CARPARK
		else _station_xform(_view), true)
	return true


# --- World-space menu hosts ---------------------------------------------------
#
# Four migrated screens, each a WorldPanelHost (world_panel_host.gd) owning the swap between its
# flat CanvasLayer and a panel welded into the 3D scene. Everything generic — building and
# rebuilding the panel, moving the tree, restyling it, reverting cleanly — lives in that class
# and in WorldPanel.apply_host_style. The only per-station knowledge here is WHERE the panel
# hangs and HOW BIG it is.
#
# Hosts live in a dictionary rather than one field each: at two screens that was a toss-up, at
# six it is the difference between a table and a wall of copy-paste.
var _panel_hosts: Dictionary = {}


func _panel_host(key: String) -> WorldPanelHost:
	return _panel_hosts.get(key, null) as WorldPanelHost


# Put ONE screen on the host the config asks for, creating its host on first use. Idempotent and
# cheap, so it is safe to call from update_overlays on every view change.
func _sync_panel(key: String, layer: CanvasLayer, tree: Control, shown: bool,
		anchor: Callable, spec: Callable) -> void:
	if layer == null or tree == null:
		return
	var host := _panel_host(key)
	if host == null:
		host = WorldPanelHost.new({
			"flat_layer": layer, "tree": tree, "parent": self,
			"anchor": anchor, "spec": spec,
		})
		_panel_hosts[key] = host
	# RE-BIND EVERY SYNC, not just at birth. A host built once kept the Callables it was created
	# with — and the F8 hot reload REPLACES Config.data with a fresh GameConfig, so a spec closure
	# that had captured the old instance kept reporting the old height / ui_scale and the panel was
	# never rebuilt. Offsets and yaw appeared to work (their anchors read Config.data per call),
	# which made it look like only ui_scale was broken.
	host.anchor = anchor
	host.spec = spec
	if host.panel != null:
		host.panel.anchor = anchor
	host.sync(bool(Config.data.world_space_menus), shown)


# THE PANEL SIZE for each migrated screen, as (height_m, ui_scale).
#
# Methods, not closures. update_overlays runs on every view change, so building four lambdas there
# allocated four Callables per call and left each captured on a long-lived WorldPanelHost. These read
# Config.data at CALL time exactly as the lambdas did, which is what keeps them correct across the F8
# hot reload (it replaces the whole GameConfig instance, so a captured one goes stale) — and they
# allocate nothing.
#
# Every screen built of BUTTON ROWS carries its own ui_scale: an HBox cannot wrap, so it needs a wider
# canvas (a LOWER scale) than a screen of labels does. Only the car park uses the shared value.
func _title_panel_spec() -> Vector2:
	return Vector2(float(Config.data.world_panel_title_height),
		float(Config.data.world_panel_title_ui_scale))


func _garage_panel_spec() -> Vector2:
	return Vector2(float(Config.data.world_panel_garage_height),
		float(Config.data.world_panel_garage_ui_scale))


func _lift_panel_spec() -> Vector2:
	return Vector2(float(Config.data.world_panel_lift_height),
		float(Config.data.world_panel_lift_ui_scale))


# The wheel-fitting view gets its own HEIGHT for the same reason it gets its own offset: it is the one
# car-park mode that swaps the camera, so a different distance needs a different panel size.
func _car_panel_spec() -> Vector2:
	var cfg: GameConfig = Config.data
	return Vector2(
		float(cfg.world_panel_wheels_height if _carpark_mode == CarparkMode.WHEELS
			else cfg.world_panel_height),
		float(cfg.world_panel_ui_scale))


# Orientation for a placed panel: yaw about world up, then pitch about its own X.
#
# PITCH IS NOT DECORATION. The map-table camera sits under 2 m from the table looking steeply
# DOWN at it, so an upright panel there is read almost edge-on; pitching it back to lie toward
# the camera is what makes it legible (and reads better anyway — a sheet angled on the table
# rather than a screen standing on it).
func _panel_basis(yaw_deg: float, pitch_deg: float) -> Basis:
	return Basis(Vector3.UP, deg_to_rad(yaw_deg)) * Basis(Vector3.RIGHT, deg_to_rad(pitch_deg))


# THE CAR-PARK ANCHOR: the focused car's runtime Marker3D, offset to its front-left corner.
#
# A marker rather than an authored scene node because the lineup is BUILT AT RUNTIME (one marker
# per owned car, laid out along X), so there is nothing fixed in hq.tscn to weld to.
#
# MIND THE SIGNS: markers are built with `rotation.y = PI` so the car parks nose-out toward the
# camera (hq_carpark.gd::_render_lineup_page), which flips X and Z against the world — in this
# space -Z is the car's nose and -X is the car's left (world +X, screen-right). Get it backwards
# and the panel lands behind the car, off-screen, which reads as "the panel never appeared"
# rather than as a sign error.
func _car_panel_xform() -> Variant:
	if _markers.is_empty():
		return null
	var marker := _markers[clampi(_focus, 0, _markers.size() - 1)] as Marker3D
	if marker == null:
		return null
	var cfg: GameConfig = Config.data
	# THE WHEEL VIEW IS ITS OWN SHOT. CarparkMode.WHEELS swaps in a low SIDE-ON camera
	# (_camera_target_xform), so the placement welded for the front-3/4 lineup shot is edge-on or out
	# of frame there. It is the only car-park mode that moves the camera, so it is the only one that
	# needs its own offset and yaw.
	var wheels := _carpark_mode == CarparkMode.WHEELS
	var local := Transform3D(
		_panel_basis(float(cfg.world_panel_wheels_yaw_deg if wheels
			else cfg.world_panel_car_yaw_deg), 0.0),
		cfg.world_panel_wheels_offset if wheels else cfg.world_panel_car_offset)
	return marker.global_transform * local


# THE LIFT ANCHOR: hq_lift_pos in WORLD space. No marker and no axis flip here - the lift bay is
# a fixed place in the garage, and the car on it noses -Z.
func _lift_panel_xform() -> Variant:
	var cfg: GameConfig = Config.data
	return Transform3D(_panel_basis(float(cfg.world_panel_lift_yaw_deg), 0.0),
		cfg.hq_lift_pos + cfg.world_panel_lift_offset)


# THE STEP 3-4 ANCHORS (detail / challenge / garage / title) are all built the same way: from
# THEIR STATION'S EXISTING CAMERA LOOK TARGET plus an offset.
#
# That is a deliberate change of tactic from the first two stations. Welding to a car and then
# panning the camera to find the panel cost several eyeball passes per station; anchoring to the
# point the camera already aims at means the panel starts IN SHOT, and none of these four needs a
# camera shift at all.
func _looked_at_panel_xform(look: Vector3, offset: Vector3, yaw: float, pitch: float) -> Variant:
	return Transform3D(_panel_basis(yaw, pitch), look + offset)


func _garage_panel_xform() -> Variant:
	var cfg: GameConfig = Config.data
	return _looked_at_panel_xform(cfg.hq_garage_cam_look, Config.data.world_panel_garage_offset,
		float(Config.data.world_panel_garage_yaw_deg), float(Config.data.world_panel_garage_pitch_deg))


func _title_panel_xform() -> Variant:
	var cfg: GameConfig = Config.data
	# The title camera is posed RELATIVE to the leftmost parked car, so its look target moves with
	# the lineup; the panel has to follow it or it drifts off as the collection grows.
	return _looked_at_panel_xform(_first_car_anchor() + cfg.hq_exterior_cam_look,
		Config.data.world_panel_title_offset,
		float(Config.data.world_panel_title_yaw_deg), float(Config.data.world_panel_title_pitch_deg))


# Re-weld the car-park panel to the focused car. Called from hq_carpark.gd::_focus_changed - the
# one place the selection actually changes.
func _position_car_panel() -> void:
	var host := _panel_host("car")
	if host != null:
		host.place()


# DROP GUI FOCUS ON EVERY HOST, not just the main viewport.
#
# `get_viewport().gui_release_focus()` is answered by the viewport HQ itself sits in — but a
# migrated station's tree lives in its WorldPanel's SubViewport, which keeps its OWN focus
# owner. So the stale-focus bug this exists to prevent (a button on the station we just left
# still swallowing arrow keys / Enter in the next, spatially-navigated one) was live again in
# world-menu mode, and WorldPanel._unhandled_input goes on pumping keys into that stale owner
# for as long as the panel is visible.
func _release_all_focus() -> void:
	var vp := get_viewport()
	if vp != null:
		vp.gui_release_focus()
	for key in _panel_hosts:
		var host := _panel_hosts[key] as WorldPanelHost
		if host == null or host.panel == null:
			continue
		var sub := host.panel.viewport()
		if sub != null:
			sub.gui_release_focus()


# --- Station transitions -----------------------------------------------------

# WHICH STATION IS LIVE. The read-only half of the `_view` field, so a collaborator asking
# "am I the screen that's up?" — the commonest question they ask this controller — does not
# have to reach through `_hq._view` for it. The two places that SET it (hq_table's
# _enter_table, hq_challenge's _enter_challenge_car_screen) do so as one step of a bespoke
# station entry that go_to does not cover, so they still write the field directly rather than
# getting a setter that would look like an alternative to go_to.
func view() -> int:
	return _view


# Move to a station: update overlays + fly the camera there. CARPARK framing tracks
# the focused car, so it's driven by _focus_changed (after the lineup is built).
func go_to(view_id: int, snap := false) -> void:
	_view = view_id
	if view_id != View.TABLE:
		_detail_open = false
		# Leaving the map mid-parade banks the queue as seen (the player has had their
		# look, or chose to walk away) rather than replaying it on the next open.
		if _revealing:
			_table_ui._finish_reveals()
	# Drop any GUI focus when changing station. HQ hides overlays by toggling their
	# CanvasLayer, which does NOT clear a Control's focus (a CanvasLayer breaks the
	# visibility chain), so a button on the view we just left would otherwise keep
	# focus and silently swallow arrow keys / Enter in the next, spatially-navigated
	# station. The native-focus views (the title, below; Settings + lift sub-pages
	# via their own paths) re-grab a control immediately after.
	_release_all_focus()
	# The selected car sits on the lift whenever we're inside (garage/lift); it costs
	# nothing once frozen, so keep it around while inside and drop it otherwise. In the
	# garage it rests LOWERED on the ground; entering the bay (_enter_lift) raises it.
	#
	# ORDER MATTERS: this runs BEFORE the title lineup is built. _lift_car SHARES its
	# node with _car_cache, and _clear_lift_car hides + stows that node. Building the
	# lineup first meant the selected car was parked in a bay and then immediately
	# hidden by the clear below — and since set_selected_car promotes the selected car
	# to index 0, the FIRST slot on the title screen was always empty.
	if view_id == View.GARAGE:
		_ensure_lift_car()
		_lower_lift_car()
		_refresh_garage_row(true)  # seat the cursor on Career each time we enter
	elif view_id == View.LIFT:
		_ensure_lift_car()  # the slow raise is triggered by _enter_lift
	elif view_id == View.TABLE:
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
	if view_id == View.EXTERIOR:
		_carpark_ui._build_title_lineup()
		_title_focus = _title_start_index()  # seat the cursor on Start each time
		_refresh_title_focus()
	update_overlays()
	if view_id == View.CARPARK:
		return  # camera handled by _focus_changed once the lineup exists
	_move_camera_to(_station_xform(view_id), snap)


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
		_carpark_ui._clear_lineup()
		_carpark_mode = CarparkMode.RALLY
		go_to(View.EXTERIOR)
		return
	if _view == View.EXTERIOR:
		# NOT the boot path any more — _await_boot_pull holds the build until the
		# initial pull has settled, so a title built at boot is already built from the
		# downloaded career. What reaches here is a profile landing MID-SESSION: a
		# first sign-in from the account page, or "Use cloud" on a conflict, both of
		# which return the player to a title showing the old collection.
		_clear_lift_car()
		_carpark_ui._build_title_lineup()
	elif _view == View.GARAGE or _view == View.LIFT:
		_ensure_lift_car()
	# A restored career arrives with no reveal flags on it; without seeding, the next map
	# open would parade the whole roster at somebody who has already played it. The
	# backfill now runs INSIDE Save.adopt_profile itself (see
	# Save._seed_reveals_if_needed), so it has already happened by the time this handler
	# runs — nothing left for hq.gd to do here.
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
			go_to(View.GARAGE)
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
				go_to(View.GARAGE)  # "Use cloud" restored a real career
				return
		_enter_starter_pick()
	else:
		go_to(View.GARAGE)


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
	_carpark_ui._clear_lineup()
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
	Scenes.change_to(get_tree(), Scenes.MAIN)


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
	#
	# The region is drawn FIRST and seated onto the event dict, because a region can now
	# carry handling as well as look (the Alps drop every surface's grip and add deep
	# snow — features/snow-region.md) and apply_event_config resolves that off
	# event["region"], exactly as it resolves the waterline. Drawn afterwards, free roam
	# would get the white look with home grip: it would LOOK like snow and drive like
	# a summer forest.
	var regions := RegionLibrary.all()
	RallySession.free_roam_region_id = "" if regions.is_empty() \
		else String(regions[randi() % regions.size()].get("id", ""))
	RallySessionScript.apply_event_config(cfg, {
		"seed": randi(),
		"region": RallySession.free_roam_region_id,
		"straightness": base.free_roam_straightness,
		"forestiness": base.free_roam_forestiness,
		"surface_mix": base.free_roam_tarmac_fraction,
		"cliffiness": base.cliff_amount,
		"width": base.track_width,
		"water_level": randf_range(base.free_roam_water_level_min_m, base.free_roam_water_level_max_m),
		"terrain_layer1_amplitude": randf_range(base.free_roam_relief_min, base.free_roam_relief_max),
	})


# --- Kept on HqController, NOT moved with the table cut ----------------------
# _process is an ENGINE CALLBACK: on a RefCounted collaborator Godot would never call it,
# so the table pan and the reveal animation would silently stop advancing (and several
# tests drive hq._process(delta) directly). _eligibility_summary / _qualifying_cars_text
# are shared — hq_challenge.gd calls both, and test_rally_detail.gd calls them off the
# controller — so the NAMES stay here; the derivations moved to RallyDetail with the panel
# that is their main consumer. See todo/hq-split.md.

# Poll the held menu directions each frame and glide the table camera smoothly while
# any are down (no discrete jumps — hold a direction and the map slides under a fixed
# reticle). Only active in the TABLE view with the detail panel closed.
func _process(delta: float) -> void:
	if _view != View.TABLE or _detail_open or _revealing:
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
		_table_ui._pan_table_step(dir2, Config.data.hq_table_pan_glide * delta)


# How many of the player's owned `cars` can enter `rally`, tallied on top of
# _entry_plan so this agrees exactly with the green/grey map pin (_has_eligible_car)
# and the car-park lineup — the ONE eligibility decision, never re-derived here.
# Returns {total, qualify, adjust, names}: `total` counts owned cars whose model still
# resolves (a removed model is skipped, not counted); `qualify` = can enter as built
# (matches the pin); `adjust` = cars that CANNOT enter as built but WOULD after a
# drivetrain conversion. `names` lists the qualifying cars' display names, in roster
# order, so the panel can name them instead of just counting them.
#
# `adjust` used to be a subset of `qualify`, because the car park silently switched such a
# car at the Start button and counted it as qualifying. That switch is gone — a
# wrong-drivetrain car is simply ineligible — so `adjust` is now DISJOINT from `qualify`:
# it counts cars the player could convert themselves, which is exactly the prompt the
# panel line is for.
func _eligibility_summary(rally: Dictionary, cars: Array) -> Dictionary:
	return RallyDetail.eligibility_summary(rally, cars)


# Whether this car belongs in the rally's car-park lineup at all: it can enter as built, or
# it could be made to by an upgrade the player can actually buy. A car that can never enter
# — the wrong body, country, doors, cylinders — is excluded, because parking it offers the
# player nothing to do about it.
func _can_ever_enter(rally: Dictionary, car: Dictionary) -> bool:
	if rally.is_empty():
		return true
	if bool(_entry_plan(rally, car)["eligible"]):
		return true
	return _convertible_for(rally, car, CarLibrary.for_owned(car))


# Whether this car is ineligible ONLY on drive mode — i.e. converting it (which the player
# does themselves in the garage, for stars) would let it in. Requires the conversion
# capability to be unlocked at all, so the panel never suggests a fix the player cannot buy.
func _convertible_for(rally: Dictionary, car: Dictionary, entry: Dictionary) -> bool:
	return RallyDetail.convertible_for(rally, car, entry)


# The qualifying-car read-out: name the cars rather than counting them. Caps the list at
# MAX_QUALIFY_NAMES and tails the rest as "+N more" so a big garage can't blow the panel
# out. Callers only reach this with a non-empty list (empty is its own RED message).
func _qualifying_cars_text(names: Array) -> String:
	return RallyDetail.qualifying_cars_text(names)


# --- Tuning-lift forwarders (features/tuning.md / todo/menus.md rig 4) -------------
# The station itself is HqTuningLift (scripts/hq_tuning_lift.gd): entering the bay, the
# raise/lower rig, the two-row HUB cursor, the Upgrades / Tuning pages, the display car, the
# Repair action and Test Drive. Its LIFT input branch is reached from _unhandled_input as
# `_tuning_lift.handle_input(event)`, the same way HqTable's and HqCarpark's are.
#
# Everything below is a one-line delegate, and each one exists because something OUTSIDE this
# file already calls it by that name: hq_overlays.gd wires the lift's buttons to
# `_hq._lift_hub` / `_hq._cycle_lift_car` / `_hq._open_lift_page` / `_hq._test_drive` /
# `_hq._repair_selected_car` / `_hq._on_dev_car_upgraded`, go_to and update_overlays call the
# rig from this file, and test_menu_flow.gd / test_lineup_cache.gd /
# test_wheel_customization.gd drive most of them off the controller. Rewriting those call
# sites is not a behaviour-preserving move, so the names stay and the bodies moved.
#
# The lift's STATE and WIDGETS stay on this controller too (see `_lift_car`, `_lift_page`,
# `_lift_row`, `_lift_raised`, `_lift_tween`, `_hub_focus`, the cursors, `_lift_repair_button`,
# `_tune_panel`, `_lift_upgrades_box`): hq_overlays.gd builds the widgets and go_to /
# update_overlays read the flags, so they are shared, not the station's private bookkeeping.

# Enter the tuning bay (raise the car, frame it, show the HUB).
func _enter_lift() -> void:
	_tuning_lift._enter_lift()


func _raise_lift_car() -> void:
	_tuning_lift._raise_lift_car()


func _lower_lift_car() -> void:
	_tuning_lift._lower_lift_car()


# Move the lift car (and its beam) to the current target height. `animate` false snaps.
func _apply_lift_height(animate: bool) -> void:
	_tuning_lift._apply_lift_height(animate)


# Back out one level: a sub-menu page returns to the hub; the hub returns to the garage.
func _lift_back() -> void:
	_tuning_lift._lift_back()


# Open a sub-menu (LiftPage.TUNE / LiftPage.UPGRADES) as its own full-height page.
func _open_lift_page(page: int) -> void:
	_tuning_lift._open_lift_page(page)


# Return from a sub-menu to the bay hub.
func _lift_hub() -> void:
	_tuning_lift._lift_hub()


# Move the HUB cursor left/right within its row, or between the two rows, and fire it.
func _move_hub_focus(step: int) -> void:
	_tuning_lift._move_hub_focus(step)


func _move_lift_row(row: int) -> void:
	_tuning_lift._move_lift_row(row)


func _activate_hub_focus() -> void:
	_tuning_lift._activate_hub_focus()


func _refresh_hub_focus() -> void:
	_tuning_lift._refresh_hub_focus()


# Spawn (or keep / stow) the selected car on the lift. See HqTuningLift._ensure_lift_car for
# the cache key and the "car vanishes from the lift" bug it guards.
func _ensure_lift_car() -> void:
	_tuning_lift._ensure_lift_car()


func _clear_lift_car() -> void:
	_tuning_lift._clear_lift_car()


# Rebuild the whole lift menu for the current selected car.
func _refresh_lift_ui() -> void:
	_tuning_lift._refresh_lift_ui()


func _refresh_lift_car_label() -> void:
	_tuning_lift._refresh_lift_car_label()


# The lift's UpgradesGrid on_change, and the Dev-settings equivalent.
func _on_lift_upgrade_changed() -> void:
	_tuning_lift._on_lift_upgrade_changed()


func _on_dev_car_upgraded() -> void:
	_tuning_lift._on_dev_car_upgraded()


# Put the previous (-1) / next (+1) owned car on the lift, wrapping at both ends.
func _cycle_lift_car(step: int) -> void:
	_tuning_lift._cycle_lift_car(step)


# Repair the car on the lift for the flat star price, and repaint the button that offers it.
func _repair_selected_car() -> void:
	_tuning_lift._repair_selected_car()


func _refresh_repair_button() -> void:
	_tuning_lift._refresh_repair_button()


# Test Drive: free roam with the car currently on the lift. Awaited — it loads a scene.
func _test_drive() -> void:
	await _tuning_lift._test_drive()


# Move the title's left/right cursor across the row — Exit Game (non-web only) / Free
# Roam / Settings / Start — wrapping at the ends, and repaint it. Deliberately described
# by CONTENTS, not indices: Exit Game is absent on web, so every position shifts.
func _move_title_focus(step: int) -> void:
	_title_focus = _title_cursor.wrapped(_title_focus, step)
	_refresh_title_focus()


# Fire the title action the cursor sits on (Start flies into the garage, Free Roam opens
# the whole-catalogue picker, Settings opens the shared page, Exit Game quits).
func _activate_title_focus() -> void:
	_title_cursor.activate(_title_focus)


# Paint the manual title cursor (EXTERIOR is a spatially-navigated 3D station like the
# garage, so the whole row is highlighted by hand rather than via native focus).
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


# Rebuild the garage action row's buttons + ButtonCursor: Back / Career / Garage /
# Online. Called on entry and whenever the row needs a repaint. Frees the row's previous
# children each time (a plain HBoxContainer, not a MenuNav host, so nothing analogous to
# UpgradesGrid.rebuild()'s "preserve the MenuNav child" carve-out is needed here).
#
# This row used to be TWO levels — a "Drive" button that swapped it for Career / Free
# Roam / Online — but that only added a press in and a press back on the way to every
# stage. Career and Online sit flat alongside Garage now; Free Roam moved to the title
# screen, since it needs no garage state (see HqOverlays.build_title_overlay).
func _refresh_garage_row(seat_on_career := false) -> void:
	for c in _garage_actions_row.get_children():
		c.queue_free()
	var buttons: Array[Button] = []
	var actions: Array[Callable] = []
	var on_back := func() -> void: go_to(View.EXTERIOR)
	var back := UITheme.row_button("< Back", on_back)
	_garage_actions_row.add_child(back)
	buttons.append(back); actions.append(on_back)
	# Career: the rally table — a convenience button mirroring the clickable 3D table.
	var to_table := UITheme.row_button("Career", _table_ui._enter_table)
	_garage_actions_row.add_child(to_table)
	buttons.append(to_table); actions.append(_table_ui._enter_table)
	# Where Career ended up — asked of the array the cursor actually indexes into rather
	# than re-derived from the construction order, so adding or moving a button can't
	# silently desync it.
	_garage_career_index = buttons.find(to_table)
	# Garage: straight into the tuning lift bay for the currently selected car. This used to
	# open the car park FIRST to pick a car, but the lift's own selector chevrons change the
	# car on the lift in place now (_cycle_lift_car), which made the picker a press in and a
	# press back on the way to the only screen anyone wanted.
	var to_garage := UITheme.row_button("Garage", _enter_lift)
	_garage_actions_row.add_child(to_garage)
	buttons.append(to_garage); actions.append(_enter_lift)
	# Online LAST: the Daily/Weekly/Monthly seeded Rally Challenge entry point (a modal
	# overlay over the garage, see build_challenge_overlay / _challenge_ui._open_challenge_overlay).
	var to_online := UITheme.row_button("Online", _challenge_ui._open_challenge_overlay)
	_garage_actions_row.add_child(to_online)
	buttons.append(to_online); actions.append(_challenge_ui._open_challenge_overlay)
	# Multiplayer LAST: the drop-in lobby's entry screen (a modal overlay over the
	# garage, see build_multiplayer_overlay / _multiplayer_ui._open_multiplayer_overlay).
	var to_multiplayer := UITheme.row_button("Multiplayer", _multiplayer_ui._open_multiplayer_overlay)
	_garage_actions_row.add_child(to_multiplayer)
	buttons.append(to_multiplayer); actions.append(_multiplayer_ui._open_multiplayer_overlay)
	_garage_cursor.setup(buttons, actions)
	# Seat BEFORE the settle so the row is painted once, with the right cursor. Doing this
	# in the caller instead meant this function painted a stale focus that was immediately
	# overwritten and repainted (ButtonCursor.refresh walks every button each time).
	if seat_on_career:
		_garage_focus = _garage_career_index
	_garage_focus = _garage_cursor.settled(_garage_focus)
	_refresh_garage_focus()
	# Freshly-built buttons start life with raw (non-uppercase) text — _normalize_menus
	# (UITheme.enforce) is what applies the house rules, and it only runs on a view
	# change/dynamic-text refresh elsewhere; a row repaint doesn't go through go_to,
	# so it has to re-apply the rules itself here.
	_normalize_menus()


# Every owned car other than `current_id`. Used by engine-swap (_swap_targets), which
# offers the OTHER owned cars.
func _other_owned_cars(current_id: int) -> Array:
	var targets: Array = []
	for car in Save.profile.get(Save.KEY_CARS, []):
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
		# NO challenge-lock exclusion. A challenge locks the RUN to the car it started
		# with; it does not RESERVE the car. It stays fully usable in the garage, career
		# and free roam between stages — including upgrades and engine swaps — which the
		# design deliberately accepts (a challenge is a time competition, not a survival
		# one). So a car fielded by an active run is still a valid swap partner.
		out.append(car)
	return out


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
	_start_button.disabled = true
	_move_camera_to(_station_xform(View.CARPARK), true)


# Enter the car park for the chosen rally: park the ELIGIBLE owned cars (plus any
# over-powered car a detune would qualify — see _build_eligible_lineup) and frame
# the first. With none, show a hint + disable Start.
# DEV ONLY: mark the open rally as won outright (1st place, 3 stars) without driving it,
# then drop back to the map so the reveal it triggers plays exactly as a real win's would.
#
# Exists for MAP EXPLORATION: reveal is geometric, so one completion lights the circle
# around that rally's pin and opens its neighbours — walking the roster a pin at a time is
# the only way to check the exploration graph feels right, and the shipped map is 17 waves
# deep. The Settings "3-star all rallies" cheat lights everything at once and so cannot
# show the progression at all.
#
# Guarded on dev_tools_enabled() as well as the button being build-gated: the F10 action
# reaches this directly, so the gate has to live at the sink, not only at the button.
func _dev_complete_selected_rally() -> void:
	if not SettingsMenu.dev_tools_enabled() or _selected_rally_id == "":
		return
	Save.dev_three_star_rally(_selected_rally_id)
	# Back to the map, then rebuild the pins: whatever this win just lit has to appear, and
	# _hide_detail is also what re-runs the reveal queue for the newly-open rallies.
	_table_ui._hide_detail()
	_refresh_map_pins()


func _enter_car_screen() -> void:
	_carpark_mode = CarparkMode.RALLY
	_start_button.text = "Start Rally"
	_carpark_ui._build_eligible_lineup()
	var rally := RallyLibrary.by_id(_selected_rally_id)
	var done := Save.rally_podiumed(_selected_rally_id)
	_rally_banner.text = "%s%s — needs %s" % [
		rally.get("name", "?"), "  (done)" if done else "",
		_restriction_text(rally.get("restriction", {}))]
	_view = View.CARPARK
	_detail_open = false
	update_overlays()
	if _eligible.is_empty():
		_show_empty_carpark("No eligible car for this rally — win or pick a qualifying car.")
		return
	_no_eligible_label.visible = false
	_focus = 0
	_carpark_ui._focus_changed(true)  # snaps the camera onto the first car


@warning_ignore("unused_private_class_variable")  # shared with hq_tuning_lift.gd
var _lift_repair_button: Button   # the lift hub's Repair action; label carries the price


# Free Roam: open the car park across the WHOLE catalogue (owned cars and not) as base-
# model previews, framed on the currently-selected car's model. Start drops into a
# session-less drive in the picked car (see _start_free_roam); Back returns to the TITLE
# screen, which is where it is entered from (the EXTERIOR title row's Free Roam button —
# see HqOverlays.build_title_overlay). It deliberately needs no owned car, session or
# lift, which is why it doesn't live in the garage.
func _enter_free_roam() -> void:
	_carpark_mode = CarparkMode.FREEROAM
	var previews := _all_car_previews()
	_carpark_ui._build_lineup(previews, _index_of_model(previews, String(Save.selected_car().get("model_id", ""))))
	_rally_banner.text = "Free roam — pick any car"
	_no_eligible_label.visible = false
	_start_button.text = "Start Free Roam"
	_start_button.disabled = _lineup.is_empty()
	_view = View.CARPARK
	_detail_open = false
	update_overlays()
	# Fly (don't snap) — a tween carries the player smoothly from the garage into the shot.
	_carpark_ui._focus_changed(false)


# The index of the first preview whose model matches `model_id` within `cars`, or 0 when
# not present — used to seat the Free Roam cursor on the currently-selected car's model.
func _index_of_model(cars: Array, model_id: String) -> int:
	if model_id == "":
		return 0
	for i in cars.size():
		if String(cars[i].get("model_id", "")) == model_id:
			return i
	return 0


# --- Present-box car reveal (scripts/hq_present_reveal.gd) -------------------
# How a won car is handed over. The rally GRANTS it (rally_session), then HQ opens on a giant
# present in an empty car park with the car inside it. The podium used to do this with a
# slot-machine reel and a showroom turntable, on the results screen — away from the garage the
# car actually arrives in, and over in a moment. The box puts the reveal where the car is and
# makes the player perform it.
#
# The beat's functions live on HqPresentReveal; the four state fields below stay HERE because
# they are read from outside it — `_car_back` (just below) branches on `_present_opened`, as
# does `_on_start_pressed`, and test_menu_flow.gd asserts on it. Same split HqMultiplayer uses
# for `_multiplayer_shown`.
#
# There is no input branch for the present: it runs inside View.CARPARK
# (CarparkMode.PRESENT), so keyboard/gamepad input reaches it through
# `_carpark_ui.handle_input` and the two handlers below, exactly as before the cut.
@warning_ignore("unused_private_class_variable")  # shared with hq_present_reveal.gd
var _present_box: Node3D             # the openable box prop, live only in CarparkMode.PRESENT
@warning_ignore("unused_private_class_variable")  # shared with hq_present_reveal.gd
var _present_instance_id := -1       # the owned car waiting inside it
var _present_opened := false         # guards against opening one box twice
@warning_ignore("unused_private_class_variable")  # shared with hq_present_reveal.gd
var _present_marker: Marker3D        # the bay the box stands on AND the car is seated on


# Open on the present. `instance_id` is a car the player ALREADY OWNS — the box is a
# presentation, not a transaction. Called from _build_hq's reveal hand-off.
func _enter_present_box(instance_id: int) -> void:
	_present_ui._enter_present_box(instance_id)


# Open the box on the car inside it (the "Open it" button / menu_select).
func _open_present() -> void:
	_present_ui._open_present()


# Leave for the GARAGE rather than the map: the player has just been given a car.
func _leave_present_to_garage() -> void:
	_present_ui._leave_present_to_garage()


func _car_back() -> void:
	# The present is a FORCED beat: until the box is open there is nowhere to go back to —
	# the player arrived here straight from the rally they won it in. The Back button is
	# hidden too (_refresh_present_button); this covers the keyboard/gamepad Back action,
	# which does not go through the button.
	if _carpark_mode == CarparkMode.PRESENT:
		if not _present_opened:
			return
		_leave_present_to_garage()
		return
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
	_carpark_ui._clear_lineup()
	_selected_instance_id = -1
	var mode := _carpark_mode
	_carpark_mode = CarparkMode.RALLY  # leaving the park in every case
	match mode:
		CarparkMode.STARTER:
			go_to(View.EXTERIOR)
		CarparkMode.FREEROAM:
			# Free Roam is entered from the TITLE screen now, not the garage, so backing
			# out of its picker returns there (see HqOverlays.build_title_overlay).
			go_to(View.EXTERIOR)
		CarparkMode.SWAP, CarparkMode.WHEELS:
			_enter_lift()
		CarparkMode.CHALLENGE:
			go_to(View.GARAGE)
			_challenge_ui._open_challenge_overlay()
		_:
			go_to(View.TABLE)


# Open the car park to pick an engine-swap partner: all OTHER owned cars at full
# health (the current car is excluded — you can't swap with yourself). Confirming a
# target exchanges engines via Save.swap_engines. See features/engine-swap.md.
func _enter_engine_swap() -> void:
	_carpark_mode = CarparkMode.SWAP
	_selected_instance_id = -1  # no partner chosen yet; guards _select_swap_target
	var current_id := Save.selected_instance_id()
	var targets := _swap_targets(current_id)
	_carpark_ui._build_lineup(targets)
	_rally_banner.text = "Engine swap"
	_start_button.text = "Swap Engine"
	_view = View.CARPARK
	_detail_open = false
	update_overlays()
	# No partner to swap with (only one car owned) — show a hint + disable Swap instead of
	# a dead lot with an empty, no-op button (_select_swap_target bails on no selection).
	if _eligible.is_empty():
		_show_empty_carpark("No other car to swap engines with — this is your only car.")
		return
	_no_eligible_label.visible = false
	_focus = 0
	_carpark_ui._focus_changed(true)


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
	_carpark_ui._build_lineup([owned])
	_rally_banner.text = "Wheels"
	_start_button.text = "Fit Wheels"
	_view = View.CARPARK
	_detail_open = false
	update_overlays()
	if _eligible.is_empty():
		_show_empty_carpark("No car to fit wheels to.")
		return
	_no_eligible_label.visible = false
	_focus = 0
	# One full _focus_changed to seat the selection / camera / damage row, then the wheel
	# label takes over the name line. Subsequent cycling deliberately does NOT re-run
	# _focus_changed (it would rev the engine and rewrite the label "1 of 1" every flick).
	_carpark_ui._focus_changed(true)
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
# no unlock, no cost, no confirm popup. Writing the style into the owned dict
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
	_carpark_ui._clear_lineup()
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
	_carpark_ui._build_lineup(_starter_previews())
	_rally_banner.text = "Choose your starter car"
	_no_eligible_label.visible = false
	_start_button.text = "Choose This Car"
	_start_button.disabled = false
	_view = View.CARPARK
	_detail_open = false
	update_overlays()
	_focus = 0
	_carpark_ui._focus_changed(true)


# Commit the focused preview as the player's first car: grant it, record the choice,
# select it, then drive STRAIGHT INTO that car's own rally — the map is not shown yet.
#
# The starter pick is the player's first real decision, and this is what gives it weight:
# it does not just choose a car, it chooses WHERE ON THE MAP THEIR CAREER BEGINS. Pick the
# MX-5 and you open in the MX-5's corner. They arrive at the table afterwards with that
# rally already complete and its neighbours lighting up (todo/opening-rally.md).
#
# It also disposes of a dead reward: the rally awarding your starter can never hand you a
# car you don't have, yet completing it is what lights the pins around it. Rather than
# substituting the prize, the rally is reframed — it is not something to chase, it is the
# starting line.
#
# Falls back to the garage when the roster has no event for this model, which is a content
# gap rather than a broken profile — the player still gets their car.
func _confirm_starter() -> void:
	if _eligible.is_empty():
		return
	var model_id := String(_eligible[_focus].get("model_id", ""))
	if model_id == "":
		return
	var car := Save.grant_car(model_id)
	Save.profile["starter_picked"] = true
	Save.profile["starter_model_id"] = model_id
	var instance_id := int(car.get("instance_id", -1))
	Save.set_selected_car(instance_id)
	Save.save()
	_carpark_ui._clear_lineup()
	_carpark_mode = CarparkMode.RALLY
	var opening_id := RallyLibrary.opening_rally_id_for(model_id)
	if opening_id == "":
		_selected_instance_id = -1
		go_to(View.GARAGE)
		return
	# Field the car we just granted in the rally that awards it. Goes through the SHARED
	# start path (_proceed_with_start), not a private handoff, so the opening run picks up
	# the mobile control-scheme gate and the loading cover like every other start does —
	# this is the first drive a touch player ever takes, so it is the LAST place that gate
	# should be skipped.
	_selected_instance_id = instance_id
	_selected_rally_id = opening_id
	await _proceed_with_start()


# --- Kept on HqController, NOT moved with the carpark cut --------------------
# _log_boot_cost runs from _ready (an engine callback on this node), and the two stats
# helpers below are shared: _restriction_text is called by hq_table.gd and _car_stats_text
# by both the carpark and the lift readouts. The PREWARM logging moved to hq_carpark.gd
# with the prewarm it measures — only the boot log is HqController's.


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

# Print HQ's boot wall-clock and the resident cost of _car_cache at the current garage
# size. Cheap: the mesh walk reads ArrayMesh surface header counts
# (surface_get_array_len / surface_get_array_index_len) — it never copies a surface array
# — and it runs once, behind the loading cover.
func _log_boot_cost(build_ms: int) -> void:
	print("hq boot stage: %-22s %5d ms" % ["build", build_ms])
	print("hq boot total: %d ms" % build_ms)


# One-line car summary shown in the car-select overlay. DELEGATES to RallyDetail, which owns
# the logic and the reasoning behind each field — the overworld's in-place car picker needed the
# same line, and a second copy is how the garage's repair button quietly lost a web-export fix.
# Same shape as _restriction_text below. Original notes: drive layout,
# peak horsepower, kerb weight, and condition. Health reads as a percentage (kept
# distinct so it doesn't read as the horsepower figure now shown alongside it); a
# spent (0 HP) car is flagged so the lineup makes clear how badly it will drive.
# The power-to-weight ratio lives only in the upgrades-menu detune readout. A fitted
# nitrous bottle is named LAST, after health — it's invisible to effective_meta (never
# moves HP/kg/power-to-weight, see features/nitrous.md) so it can only ever be a trailing
# addition, never something the earlier fields need to account for. Omitted entirely
# when the car has none, so the common case stays exactly the line it was.
func _car_stats_text(owned: Dictionary, entry: Dictionary) -> String:
	return RallyDetail.car_stats_text(owned, entry)


# Human-readable summary of a rally's restriction (the detail panel + the car banner).
# Every gate is categorical — what KIND of car may enter, never how fast it is.
func _restriction_text(restriction: Dictionary) -> String:
	return RallyDetail.restriction_text(restriction)


# --- Camera ------------------------------------------------------------------

# A camera transform that sits at `eye` looking at `look`.
func _look_xform(eye: Vector3, look: Vector3) -> Transform3D:
	var t := Transform3D.IDENTITY
	t.origin = eye
	if eye.distance_to(look) < 0.001:
		return t
	return t.looking_at(look, Vector3.UP)  # looking_at keeps the origin (the eye)


# The camera pose for a station.
func _station_xform(view_id: int) -> Transform3D:
	var cfg: GameConfig = Config.data
	match view_id:
		# One framing now the garage row is a single level: the wide shell view. (The
		# low 3/4 hero shot that used to come with the "Drive" sub-level went with it —
		# see _refresh_garage_row.)
		View.GARAGE: return _look_xform(cfg.hq_garage_cam_eye, cfg.hq_garage_cam_look)
		View.TABLE: return _look_xform(cfg.hq_table_cam_eye + _table_pan, cfg.hq_table_cam_look + _table_pan)
		View.LIFT:
			# Same rule as the car park (_camera_target_xform): while world menus are on, PAN
			# THE AIM to bring the panel into frame rather than moving the eye, which would
			# recompose the whole bay shot. The garage is tighter than the car park, so this
			# shift matters more here, not less.
			var lift_look: Vector3 = cfg.hq_lift_cam_look
			var lift_eye: Vector3 = cfg.hq_lift_cam_eye
			if bool(cfg.world_space_menus):
				lift_look += Config.data.world_panel_lift_camera_look_shift
				# The ONE station where a world panel also moves the EYE. The bay is too tight
				# to solve by aim alone: the car's nose is ~1.2 m from the eye, so it covers a
				# wide wedge of screen and occludes any panel behind it. Pulling back shrinks
				# the car and separates the two.
				lift_eye += Config.data.world_panel_lift_camera_eye_shift
			return _look_xform(lift_eye, lift_look)
		View.CARPARK: return _camera_target_xform()
		# Title shot: eye + look are OFFSETS from the first (leftmost) parked car, so the
		# low ~45° "past the first car, down the line" framing tracks the lead car as the
		# centred lineup grows and its leftmost car slides toward −X (more cars owned).
		_:
			var anchor := _first_car_anchor()
			return _look_xform(anchor + cfg.hq_exterior_cam_eye, anchor + cfg.hq_exterior_cam_look)


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
	# A world-space menu stands off the car's front-left corner, so the shot that framed the
	# car alone leaves the panel at the edge of frame. PANS THE AIM, NOT THE EYE: moving the
	# camera's position recomposes the whole shot (and moves the car within it), where
	# shifting the look target just brings the panel into view from the same viewpoint.
	# Only while that mode is on, leaving the shipped flat framing exactly as it was.
	# Deliberately below the WHEELS branch above: that mode is a car-only inspection shot
	# with no panel in it to frame.
	var look: Vector3 = car_pos + Vector3.UP * cfg.menu_camera_look_height
	var eye: Vector3 = car_pos + cfg.menu_camera_offset
	if bool(cfg.world_space_menus):
		look += Config.data.world_panel_camera_look_shift
		# The eye shift is the SECOND-choice lever (see the field's comment): panning the aim keeps the
		# composition and just finds the panel, where moving the eye recomposes the shot. It exists for
		# what panning cannot fix — distance, and occlusion.
		eye += Config.data.world_panel_camera_eye_shift
	return _look_xform(eye, look)


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
		CarparkMode.STARTER:  # first run: commit the focused preview, then drive its rally
			await _confirm_starter()
			return
		CarparkMode.SWAP:  # exchange engines with the focused car
			_select_swap_target()
			return
		CarparkMode.WHEELS:  # fit the previewed cosmetic wheels (free, no confirm)
			_commit_wheels()
			return
		CarparkMode.FREEROAM:  # launch a session-less drive in the focused car
			await _start_free_roam()
			return
		CarparkMode.PRESENT:  # open the box on the car just won, then leave for the garage
			if _present_opened:
				_leave_present_to_garage()
			else:
				_open_present()
			return
		CarparkMode.CHALLENGE:  # commit the focused eligible car to a fresh challenge run
			if _detune_needed.get(_selected_instance_id, -1.0) > 0.0:
				_carpark_ui._show_over_limit_prompt(Save.get_car(_selected_instance_id))
				return
			await _challenge_ui._begin_challenge_start()
			return
	var owned := Save.get_car(_selected_instance_id)
	var rally := RallyLibrary.by_id(_selected_rally_id)
	if owned.is_empty() or rally.is_empty():
		return
	# NOTE: nothing auto-applies upgrades here. The car races exactly the build the
	# player left it on — switching parts on for them behind a loading screen is an edit
	# they never asked for and cannot see happen.
	# An over-powered car looks eligible in the park; pressing Start pops a prompt that
	# routes the player to the upgrades menu to shed power (detune / ballast / strip
	# parts), rather than launching. _detune_needed marks the over-cap-but-fixable cars.
	if _detune_needed.get(_selected_instance_id, -1.0) > 0.0:
		_carpark_ui._show_over_limit_prompt(owned)
		return
	# A car below the class p/w floor is now INELIGIBLE (the floor is judged at the car's
	# max potential), so it never reaches the car-park lineup — there's no under-powered
	# start to warn about here anymore (the old soft "Underpowered" prompt is retired).
	await _proceed_with_start()


# The restriction a challenge run is judged against, in the same synthetic
# {"rating_max": ceiling} shape world.gd::_build_start_line hands the start line — a
# challenge has no authored rally, and it is the ONE place a performance ceiling
# survives, now expressed as a CarPerformance rating rather than hp/tonne.
#
# Deliberately just the number: the comparison itself belongs to challenge_session.gd,
# and `rating_max` is NOT part of the shared rally restriction schema (which is purely
# categorical now) — nothing in RallyLibrary reads it.
func _challenge_restriction() -> Dictionary:
	# Called through the SCRIPT, not the autoload instance. `ChallengeSession` is an autoload, so
	# the bare name resolves to the node — and calling a `static func` on an instance raises
	# STATIC_CALLED_ON_INSTANCE, which GUT reports as a test failure (it was failing
	# test_render_smoke and test_upgrades_grid, and any other suite that checks for engine
	# errors while hq.gd is parsed). Same function, same result, no warning.
	var ceiling: int = ChallengeSessionScript.displayed_ceiling(
		_challenge_kind, int(Time.get_unix_time_from_system()))
	return {} if ceiling <= 0 else {"rating_max": float(ceiling)}


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
#
# `resume` MAY BE CALLED MUCH LATER — after the player has been to the settings screen and
# saved a scheme — so it must still work then. Anything it needs must SURVIVE that gap:
#
#   * BIND the state into the callable, the way the free-roam path does
#     (`_start_preflight(_launch_free_roam.bind(instance_id, model_id), instance_id)`), or
#   * leave it in a member that nothing clears in between.
#
# What does NOT work is parking the state in a member and clearing it before calling this.
# An attempt at a challenge-start confirmation did exactly that — set `_pending_challenge_start`,
# cleared it, then passed its own handler as `resume` — and the handler's opening
# `if _pending_challenge_start.is_empty(): return` swallowed the resume. On a touch device a
# first-time player confirmed, was sent to the picker, saved a scheme, and nothing happened.
# Headless tests never see it: the gate is behind `Platform.is_touch()`.
func _start_preflight(resume: Callable, select_instance_id: int = -1) -> bool:
	if Platform.is_touch() and Save.get_setting(MobileControls.SETTING_KEY, null) == null:
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


# Confirm the highlighted car as the engine-swap partner: exchange engines, then
# respawn the lift prop with its new engine and return to the upgrades page.
func _select_swap_target() -> void:
	var current_id := Save.selected_instance_id()
	if _selected_instance_id < 0:
		return
	_show_swap_confirm(current_id, _selected_instance_id)


# Perform the swap (Save.swap_engines), then respawn
# the lift prop with its new engine and return to the upgrades page.
func _commit_engine_swap(current_id: int, partner_id: int) -> void:
	Save.swap_engines(current_id, partner_id)
	_carpark_ui._clear_lineup()
	_selected_instance_id = -1
	_carpark_mode = CarparkMode.RALLY
	_ensure_lift_car()  # the engine data changed — the hash flips, so the prop respawns
	_enter_lift()


# Confirm popup for a chosen engine-swap partner. ONE gate: the CAPABILITY has to be
# unlocked (the star-gated special rally). Past that, swapping is free and unlimited, so
# there is nothing left to spend or count. Checked here as well as on the swap-row button —
# this popup stays defensive, since it is also reachable from the car-park swap station,
# not only the upgrades menu.
func _show_swap_confirm(current_id: int, partner_id: int) -> void:
	var body: String
	if not RallyLibrary.engine_swaps_unlocked(Save.profile):
		_pending_swap = {}
		# Name the rally to go and win — a destination is more actionable than "locked".
		# Only quotable if the gating rally actually resolves (it may not under a synthetic
		# test roster).
		var unlock_name := RallyLibrary.engine_swap_unlock_rally_name()
		body = ("Engine swapping is locked. Win %s." % unlock_name if unlock_name != ""
			else "Engine swapping is not unlocked yet.")
	else:
		_pending_swap = {"current": current_id, "partner": partner_id}
		body = "Exchange engines between these two cars?"
	ConfirmPopup.open(self, "Swap engines?", body,
		[ {"label": "Cancel", "callback": Callable()},
		  # Disabled whenever the swap CANNOT happen — i.e. the capability is still
		  # star-locked. Without this the button looked live and focusable and then silently
		  # no-opped, because the locked branch above clears _pending_swap.
		  {"label": "Swap", "callback": _on_swap_confirmed,
			"disabled": _pending_swap.is_empty()} ], 1, 0)


# OK on the swap-confirm popup: perform the swap.
func _on_swap_confirmed() -> void:
	if _pending_swap.is_empty():
		return
	var current_id := int(_pending_swap["current"])
	var partner_id := int(_pending_swap["partner"])
	_pending_swap = {}
	_commit_engine_swap(current_id, partner_id)


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

# Stamp "the player is doing something" for the prewarm's idle gate — see
# _prewarm_should_wait. This is `_input`, not `_unhandled_input`, on purpose: a click on a
# garage button or a modal is exactly the kind of interaction the prewarm must stay out of
# the way of, and those events never reach _unhandled_input. It reads the event and never
# consumes it, so it cannot affect what anything downstream receives.
#
# Bare mouse MOTION is not interaction — an idle hand nudging the mouse would otherwise
# starve the prewarm forever — but motion with a button held is a map drag, so the button
# mask decides.
func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and (event as InputEventMouseMotion).button_mask == 0:
		return
	_last_input_ms = Time.get_ticks_msec()


# Should the deferred Free Roam prewarm hold off spawning its next car?
#
# Each spawn is one indivisible `car.tscn` instantiate + mesh duplication — a ~100 ms frame
# on a slow device — so the ONLY thing that decides whether it reads as a hitch is what the
# player is doing while it lands. On the static title shot, nothing: that is the trade
# _prewarm_free_roam_deferred was built for. Mid-navigation it is the whole problem, and a
# PODIUM return is the worst case, because HQ boots straight into the garage and the player
# reaches for the map table within a second (features/menus.md -> "What a map-table entry
# costs"). So the loop waits for stillness instead of assuming it.
#
# "Busy" is: a reveal parade playing, a station/map camera glide in flight, a menu direction
# HELD (the table's held-pan glide moves the camera every frame with no tween to notice, and
# a long hold generates no repeat events for _input to stamp), or any input inside the last
# PREWARM_IDLE_MS.
func _prewarm_should_wait() -> bool:
	if _revealing:
		return true
	if _cam_tween != null and _cam_tween.is_valid():
		return true
	for action in ["menu_up", "menu_down", "menu_left", "menu_right"]:
		if Input.is_action_pressed(action):
			return true
	return Time.get_ticks_msec() - _last_input_ms < PREWARM_IDLE_MS


func _unhandled_input(event: InputEvent) -> void:
	# NOT BUILT YET. _build_hq runs behind the "Entering HQ…" cover, after two process
	# frames and a possible boot-time cloud pull — and this handler is live for that whole
	# window. A key pressed while the cover is up would otherwise reach station handlers
	# that do not exist yet and crash on a null.
	#
	# Guarded on the station objects rather than _hq_built, because that flag is set at the
	# TOP of _build_hq, several statements before these are constructed — it says "the build
	# started", which is exactly the window that crashes.
	if _challenge_ui == null or _table_ui == null or _carpark_ui == null \
			or _tuning_lift == null:
		return
	# While the player is typing (the account sign-in form is the only text input
	# in the game), the HQ must not read bare keys as station navigation, and Back
	# belongs to the field — MenuNav turns it into "stop typing". One shared
	# predicate so this guard cannot drift from the one MenuNav uses.
	if MenuNav.is_text_editing():
		return
	# WORLD-SPACE MENU A/B (F7), gated on SettingsMenu.dev_tools_enabled() — the same
	# shape as the wheel-force arrows' H toggle. Flips the config field
	# the host swap reads, then re-runs the swap so the tree moves immediately.
	if SettingsMenu.dev_tools_enabled() and event.is_action_pressed("toggle_world_menus"):
		Config.data.world_space_menus = not Config.data.world_space_menus
		update_overlays()
		# The car-park framing differs between the two modes (world_panel_camera_look_shift /
		# _eye_shift), so
		# re-seat the camera or the A/B compares the new host against the old shot. Snapped
		# rather than tweened, and NOT routed through _focus_changed — that would re-rev the
		# focused car's engine on every toggle.
		if _view == View.CARPARK:
			_snap_camera_to_focus()
		get_viewport().set_input_as_handled()
		return
	# HOT-RELOAD THE CONFIG (F8), gated on SettingsMenu.dev_tools_enabled() — the tuning loop for world-space menus. Edit
	# any value on config/game_config.tres in the inspector, press this, and the running game picks
	# it up: no restart, no losing your place in the HQ.
	#
	# Re-applies rather than merely reloading, because the two things that are NOT read per frame
	# have to be poked: update_overlays re-syncs the panel hosts (panel height and ui_scale are
	# baked in at construction, so a retune of either rebuilds the panel), and the camera is
	# re-posed because a station's pose is only recomputed when it moves. Panel offsets, yaw, pitch
	# and the camera shifts need none of this — WorldPanel re-reads its anchor every frame.
	if SettingsMenu.dev_tools_enabled() and event.is_action_pressed("reload_config"):
		hot_reload_config()
		get_viewport().set_input_as_handled()
		return
	# A ConfirmPopup / UsernamePopup is MODAL: it owns the input until dismissed, and its
	# own MenuNav handles select/back on its buttons. Normally the focused popup button
	# consumes ui_accept before this ever runs — but that relies on the popup HOLDING
	# focus, and when it doesn't (nothing focusable, focus released by a rebuild under
	# it), the same keypress fell through to the station rows below and fired a SECOND
	# action behind the popup. The rule: a station must not act on input while a modal is up,
	# because the second action's OWN confirm is then refused for stacking — so it runs
	# invisibly, and save mutations are not undoable. Guarded here, alongside the
	# challenge overlay, which owns input the same way.
	if ConfirmPopup.any_open(get_tree()) != null:
		return
	# ONE BRANCH PER STATION, and each cluster owns its own (todo/hq-split.md). Every handler
	# answers whether it CONSUMED the event, which is what lets the challenge modal below stand
	# every station down without this function reading its flag by hand. Nothing is chained off
	# the answer AFTER the match — _unhandled_input is the last stop in the chain, and the one
	# handler that must really mark the viewport handled (the reveal parade's press swallow)
	# does that itself.
	if _challenge_ui.handle_input(event):
		return
	if _multiplayer_ui.handle_input(event):
		return
	var _consumed := false
	match _view:
		View.EXTERIOR: _consumed = _exterior_input(event)
		View.SETTINGS: _consumed = _settings_input(event)
		View.GARAGE: _consumed = _garage_input(event)
		View.LIFT: _consumed = _tuning_lift.handle_input(event)
		View.TABLE: _consumed = _table_ui.handle_input(event)
		View.CARPARK: _consumed = _carpark_ui.handle_input(event)


# The EXTERIOR title row (Start / Free Roam / Account / Settings / Exit Game) is a single
# left/right cursor; select fires it. Same idiom as the garage row / lift hub — see
# HqOverlays.build_title_overlay. No menu_back: EXTERIOR is the root station.
func _exterior_input(event: InputEvent) -> bool:
	if event.is_action_pressed("menu_left"):
		_move_title_focus(-1)
	elif event.is_action_pressed("menu_right"):
		_move_title_focus(1)
	elif event.is_action_pressed("menu_select"):
		_activate_title_focus()
	else:
		return false
	return true


func _settings_input(event: InputEvent) -> bool:
	if not event.is_action_pressed("menu_back"):
		return false
	# In the pre-rally gate we show only the mobile-controls page (no category
	# list), so back cancels the gate straight back to the car park. Otherwise
	# a sub-page backs out to the category list first, then back exits to the garage.
	if _settings_gate:
		go_to(View.CARPARK)
		_settings_gate = false
	elif not _settings_menu.go_back():
		go_to(View.EXTERIOR)
	return true


# The garage's bottom action row is a single left/right cursor (one level — see
# _refresh_garage_row); select fires it, and menu_back leaves the station for the exterior,
# mirroring the row's own Back button.
func _garage_input(event: InputEvent) -> bool:
	if event.is_action_pressed("menu_left"):
		_move_garage_focus(-1)
	elif event.is_action_pressed("menu_right"):
		_move_garage_focus(1)
	elif event.is_action_pressed("menu_select"):
		_activate_garage_focus()
	elif event.is_action_pressed("menu_back"):
		go_to(View.EXTERIOR)
	else:
		return false
	return true


# Drag the map table around (mouse, or finger via emulate_mouse_from_touch). A drag
# sets _table_dragged so the release doesn't also open the pin under the finger.
func _table_pan_input(event: InputEvent) -> void:
	if _revealing:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_table_panning = event.pressed
		if event.pressed:
			_table_dragged = false
	elif event is InputEventMouseMotion and _table_panning:
		if event.relative.length() > 2.0:
			_table_dragged = true
		_pan_table(event.relative, event.position)


# Translate the table camera in the map plane (X/Z) by a screen-drag delta — grab the
# map and drag it. Clamped so the view stays over the map. Snaps (follows the finger).
#
# The delta is MEASURED ON THE MAP PLANE (_map_drag_delta) rather than by multiplying
# pixels by a fixed metres-per-pixel constant, so the map point under the pointer stays
# under the pointer for the whole drag. The old constant (`hq_table_pan_speed`, 0.012 m/px)
# could only ever be right for one camera height / FOV / viewport height, and for the
# shipped ones it was ~2.1x too fast across and ~1.9x down (the table camera is tilted, so
# the true scale isn't even the same on both axes): start a drag next to a pin and the pin
# had slid well away from your finger by the time you let go. Projecting gets it exact for
# free, and stays exact if the table camera is ever re-posed or the map gains a zoom.
#
# `screen_pos` is where the pointer ENDED UP; it defaults to the view centre for callers
# with no pointer of their own (the headless drag tests).
func _pan_table(rel: Vector2, screen_pos: Vector2 = Vector2.INF) -> void:
	var cfg: GameConfig = Config.data
	if screen_pos == Vector2.INF:
		screen_pos = get_viewport().get_visible_rect().size * 0.5
	var delta := _map_drag_delta(rel, screen_pos) * cfg.hq_table_pan_gain
	var half := cfg.hq_map_plane_size
	_table_pan.x = clampf(_table_pan.x + delta.x, -half.x * 0.5, half.x * 0.5)
	_table_pan.z = clampf(_table_pan.z + delta.z, -half.y * 0.5, half.y * 0.5)
	_move_camera_to(_station_xform(View.TABLE), true)
	_table_ui._select_target_under_center()  # selection tracks the view centre as the map slides


# The world (X/Z) offset the table camera must make for the map point that was under
# `screen_pos - rel` to end up under `screen_pos` — i.e. for the map to follow the finger.
# Translating the camera in the plane shifts the plane point under a FIXED pixel by the
# same vector, so the answer is just (where the drag started) − (where it is now), both
# raycast onto the map plane through the pre-move table pose.
#
# Measured over a bounded sample and scaled up for longer `rel`: a ray far off-screen can
# tilt above the horizon and never meet the plane at all (a clamp test drags by 100000 px),
# and one real frame of drag is a handful of pixels, where the mapping is linear anyway.
func _map_drag_delta(rel: Vector2, screen_pos: Vector2) -> Vector3:
	var step := rel.limit_length(64.0)
	if step.is_zero_approx():
		return Vector3.ZERO
	var to_hit = _map_point_at(screen_pos)
	var from_hit = _map_point_at(screen_pos - step)
	if to_hit == null or from_hit == null:
		return Vector3.ZERO  # degenerate pose (camera at/below the map plane, or looking away)
	var delta: Vector3 = (from_hit as Vector3) - (to_hit as Vector3)
	delta.y = 0.0
	return delta * (rel.length() / step.length())


# The point on the map plane a ray through `screen_pos` (viewport pixels) lands on, or null
# when that ray never meets the plane — it can tilt above the horizon well outside the
# viewport, which is what makes a naive "just hit both ends of the drag" unsafe.
#
# Cast from the pose the TABLE station describes (`_station_xform`), NOT from the camera's
# live transform, because the camera may be mid-flight into the table view: `_move_camera_to`
# eases over menu_camera_move_time, so a drag started on the way in would otherwise be
# measured against the garage — or, on the title shot, against an eye 9cm above the map
# plane, where a few pixels of grazing ray are worth metres. The station pose is the settled
# table view the pan is expressed in, and it already carries the live `_table_pan`.
# `project_local_ray_normal` is the camera's OWN projection maths in camera space, so FOV,
# aspect and viewport size still come from the real camera — only the pose is substituted.
func _map_point_at(screen_pos: Vector2) -> Variant:
	var xform := _station_xform(View.TABLE)
	var plane := Plane(Vector3.UP, _map_plane_y())
	return plane.intersects_ray(xform.origin,
		xform.basis * _camera.project_local_ray_normal(screen_pos))


# Height of the map plane the drag is measured against: the built plane where there is one,
# else the table top hq_environment lays it on (bar its 1cm lift, which is under a pixel of
# drag at this camera height) so this is still answerable before build() has run.
func _map_plane_y() -> float:
	if _map_plane != null:
		return _map_plane.global_position.y
	var cfg: GameConfig = Config.data
	return cfg.hq_table_pos.y + cfg.hq_table_size.y


func _cars_input(event: InputEvent) -> bool:
	if _lineup_pointer_input(event):
		return true
	if event.is_action_pressed("menu_left"):
		_carpark_ui._cycle_focus(-1)
	elif event.is_action_pressed("menu_right"):
		_carpark_ui._cycle_focus(1)
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
	else:
		return false
	return true


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
				_carpark_ui._cycle_focus(1 if _lineup_drag_accum.x < 0.0 else -1)
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
		_carpark_ui._focus_changed()


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
