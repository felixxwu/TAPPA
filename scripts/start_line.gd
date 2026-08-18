class_name StartLine
extends Node3D
# Docs: features/start-line.md — update in the same change as this file.
# Tests: tests/headless/test_rally_session.gd, tests/headless/test_stage_manager.gd, tests/headless/test_start_line.gd — extend in the same change.
# The pre-event start-line sequence (todo/menus.md location 2) — the cinematic
# moment between picking a car in HQ and the 3·2·1·GO countdown. It runs inside the
# live run scene (main.tscn) once the world is built and a session is active — a
# RallySession event OR a ChallengeSession stage (features/rally-challenge.md) —
# while the car is held locked by the StageManager's STAGING phase:
#
#   1. MENU     — black house-style panels offer Start / Upgrades / Tune Car under a
#      rally/event header, while an orbit camera idles on the player's car. The player
#      launches with the Start button, menu_select or a tap (eligibility gates first).
#   2. FLY_IN   — the camera flies from the orbit pose to a fixed low 3/4 shot in front
#      of the start line, facing the car on the line, and holds there.
#      A challenge stage runs this identical MENU — the same Upgrades / Tune Car
#      overlays on the same locked car — and then skips straight to the fade, since
#      it has no rival field to reveal (the empty-leaders path below).
#   3. REVEAL   — the three cars ahead of the player are the REAL top-three rivals for
#      this event (their actual cars). A card shows the front car's driver, the car and
#      the time to beat, with a Next button. Next sends that car off the line and REVEALS
#      the next opponent immediately — the field rolls up one gap underneath as ambience,
#      so the player can tap straight through P1 → P2 → P3 without waiting for each car to
#      physically line up. When only the player is left, the fade begins.
#   4. FADE     — the screen fades to black; at full black the camera hands back to the
#      player's SELECTED camera (via the CameraManager), the driving UI returns and
#      StageManager.begin_countdown() starts the countdown; then it fades back in.
#
# Created and wired by world.gd (session runs only). A plain dev boot of main.tscn
# never builds a StartLine and the StageManager goes straight to the countdown.

const CAR_SCENE := preload("res://car.tscn")

# How many cars line up ahead of the player (the real top-N rivals). Fewer if the
# field can't field this many (dev/test harnesses pass an empty leaders list).
const GRID_AHEAD := 3
# A departed car is despawned once it has driven this far past the start line (down
# the lead-in, before the first corner), so it never fights its axis-lock into a bend.

# Sequence phases. MENU/REVEAL wait for a press; the rest are time-driven in _process.
# REVEAL also rolls the remaining field up to its slots each frame (ambient motion — the
# reveal cadence is tap-driven, it does not wait for the cars to settle).
enum Seq { MENU, FLY_IN, REVEAL, FADE_OUT, FADE_IN, DONE }

var _seq: int = Seq.MENU
var _seq_t := 0.0          # seconds into the current timed phase
var _orbit_angle := 0.0    # accumulated orbit camera angle (rad), the MENU idle
var _launched := false     # Start pressed (past the eligibility gates)

# Refs handed in by world.gd (camera/HUD optional so tests can omit them).
var _player: Node3D
var _terrain: Node
var _stage_manager: Node
var _camera_manager: CameraManager
var _hud: CanvasLayer
var _mobile: CanvasLayer

# Nodes this scene owns.
var _orbit_cam: Camera3D
var _overlay: CanvasLayer
var _start_button: Button
var _tune_button: Button
var _tune_layer: CanvasLayer         # the pre-race tuning overlay (built lazily)
var _tune_panel: TuningPanel         # the shared handling-axis tuning sliders (detune is in Upgrades)
var _upgrades_button: Button
var _upgrades_layer: CanvasLayer     # the pre-race upgrades overlay (built lazily)
var _upgrades_menu: UpgradesGrid   # the shared upgrades page (same as the HQ garage)
var _upgrades_back: Button           # the upgrades overlay's Back/Done button (p/w-gated)
var _menu_last_back: Button          # back button _build_menu_overlay just created
var _pause_menu: PauseMenu           # for the Exit button; pause itself is off while staged
var _exit_button: Button
var _rally: Dictionary = {}          # this event's rally (its restriction gates launch)
var _subtitle_label: Label
var _fade: CanvasLayer
var _fade_rect: ColorRect

# The reveal card (shown per opponent during REVEAL): a compact top-centre card with a
# labelled stat column (time to beat / gap to P1 / overall championship rank), and a
# simple Next button hugging the bottom — so the card never covers the car on the line.
var _reveal_overlay: CanvasLayer
var _reveal_name_label: Label       # "P{n}   Driver"
var _reveal_car_label: Label        # the rival's car
var _reveal_time_label: Label       # this event's time-to-beat value
var _reveal_gap_label: Label        # gap to the fastest rival value
var _reveal_overall_label: Label    # overall championship position value
var _reveal_overall_row: Control    # the OVERALL row, hidden when the rank is unknown
var _next_button: Button

# The leaders (top-three rivals for this event), each { name, car_id, car_name, time_ms }.
var _leaders: Array = []
# This event's index (0-based) and each rival's overall championship position so far
# (driver name → placed), for the reveal card's OVERALL stat. Empty on event 1.
var _event_index := 0
var _overall_rank: Dictionary = {}
# The grid, front-first: the opponent cars ahead of the player followed by the player
# itself as the tail. On each Next the front car drives off and is removed; the rest
# (incl. the player) roll up one slot. When only the player remains, the fade begins.
var _grid: Array[Node3D] = []
var _grid_car_ids: Array[String] = []   # ids of the opponent grid cars (test readout)
var _departed: Array[Node3D] = []        # cars driving off, despawned past the line
var _reveal_index := 0                   # which leader is currently on the line

# Camera fly: the orbit pose captured when Start is pressed, and the anchored target.
var _fly_from := Transform3D.IDENTITY
var _fly_from_fov := 70.0
var _anchor_xform := Transform3D.IDENTITY

# The player's start pose, captured at setup (the grid lays out around it). The player
# is staged GRID_AHEAD gaps behind this line and rolls up to it as the field departs.
var _start_xform: Transform3D
var _player_staged := false   # true once the player is scripted for the roll-up
var _player_auto_was := false # the player's gearbox auto flag, restored at hand-off

# The live StartLine for this run, if any — set in setup(), cleared in _exit_tree().
# engine_audio.gd reads this to tell whether ITS car is sitting in the reveal queue
# (as opposed to already racing), so it can tighten the proximity radius for the
# cars waiting behind the one currently on the reveal card. A plain dev boot never
# calls setup(), so this stays null and engine_audio falls back to its normal radius.
# Emitted when the pre-countdown sequence has fully handed back (camera, HUD, player
# control) and the countdown is about to run. world.gd re-arms the pause menu on this —
# pause is suppressed for the whole staged window, because the start line has its own
# full-screen menu and a second one stacked over it just fights for the same taps.
signal sequence_finished

static var active_instance: StartLine = null


func _cfg() -> GameConfig:
	return Config.data


# The OwnedCar being driven this stage — the ONE place this scene resolves "whose
# car is on the line". A challenge run fields ChallengeSession's locked car
# (spec §2); a rally event fields RallySession's. Every consumer (the launch
# eligibility gate, the Tune Car panel, the Upgrades menu and its live refit) goes
# through this rather than branching for itself, so there is a single answer.
#
# Free roam is deliberately NOT folded in here: it is session-less, never stages
# (world.gd._should_stage() requires an active session, so no StartLine is ever
# built for it), and its car may be a bare catalogue MODEL that isn't an OwnedCar
# at all (RallySession.free_roam_model_id) — a different question with a different
# answer, resolved once in world.gd's fielding chain.
func _driven_car() -> Dictionary:
	return DrivingContext.driven_car()


# Total stages in this event set: the rally's own authored event list, or — for a
# challenge, which has no authored events — the active run's stage count.
func _stage_total(rally: Dictionary) -> int:
	var total: int = rally.get("events", []).size()
	if total > 0:
		return total
	if ChallengeSession.is_active():
		return ChallengeSession.stage_count()
	return RallySession.EVENTS_PER_RALLY


# Build the start-line sequence around the fielded car. `leaders` is the top-three
# rivals to beat for this event (RallySession.current_event_leaders()), each
# { name, car_id, car_name, time_ms }; `terrain` (optional) sits the grid cars on the
# ground; `camera_manager` / `hud` / `mobile` are handed back at the fade (the
# camera via the manager, so the player's chosen mode — not always chase — resumes).
func setup(player: Node3D, terrain: Node, stage_manager: Node, rally: Dictionary,
		event_index: int, leaders: Array, camera_manager: CameraManager = null,
		hud: CanvasLayer = null, mobile: CanvasLayer = null,
		pause_menu: PauseMenu = null) -> void:
	active_instance = self
	_pause_menu = pause_menu
	_player = player
	_terrain = terrain
	_rally = rally  # kept so launch() can re-check eligibility after a pre-race edit
	_stage_manager = stage_manager
	_camera_manager = camera_manager
	_hud = hud
	_mobile = mobile
	_leaders = leaders
	_event_index = event_index
	_build_overall_ranks()
	_start_xform = player.global_transform
	# Seat the start-line cars a small clearance ABOVE the road at spawn so they settle
	# onto their wheels instead of spawning clipped into the ground. Anchoring it on
	# _start_xform here cascades everywhere: the staged player and the grid props read
	# their ride height off it (via _ground), and the countdown pose is reset_to it at
	# the hand-off — so the player is clear before AND during the countdown.
	if terrain != null and terrain.has_method("height_at"):
		_start_xform.origin.y = terrain.height_at(_start_xform.origin.x, _start_xform.origin.z) + _cfg().start_spawn_clearance
	# Hide the driving UI; the reveal is camera-only until the fade hands it back.
	if _hud != null:
		_hud.visible = false
	if _mobile != null:
		_mobile.visible = false
	_build_orbit_camera()
	_build_overlay(rally, event_index)
	_build_reveal_overlay()
	_build_fade()
	_stage_player(terrain)
	_spawn_grid(terrain)
	_update_orbit()


# Re-seat keyboard/gamepad focus on the Start button. Used by world.gd after a
# between-event popup (RepairReveal) that was shown ON TOP of this menu closes: the
# popup's own MenuNav focus dies with its CanvasLayer, and nothing else re-grabs the
# cursor onto this (already-built, already-attached) overlay since MenuNav only
# re-grabs on ITS OWN root's visibility_changed — this menu's root never toggles
# visibility here, so the popup closing would otherwise leave the cursor dead.
func grab_start_focus() -> void:
	if is_instance_valid(_start_button):
		_start_button.grab_focus()


# How many opponent cars actually line up ahead of the player: the top three, or fewer
# if the field is short (dev/test harnesses pass an empty leaders list).
func _grid_ahead_count() -> int:
	return mini(GRID_AHEAD, _leaders.size())


# Roll-up start: stage the player a full grid of gaps BEHIND the line (directly behind
# the last opponent) so it rolls the whole way up as the field departs instead of
# sitting still. Scripted + axis-locked like the grid cars while staging; cleared at the
# hand-off so the run drives normally. No-op for a non-Car player (test stubs).
func _stage_player(terrain: Node) -> void:
	if not (_player is VehicleBody3D) or not ("ai_controlled" in _player):
		return
	var setback := _cfg().start_queue_gap * float(_grid_ahead_count())
	# reset_to (pending teleport) so the staged pose survives the physics server; a bare
	# global_transform write on a VehicleBody3D is discarded (see car.gd reset_to). The
	# test stub has no reset_to, so fall back to the bare write there.
	var staged := Transform3D(_start_xform.basis, _ground(_start_xform * Vector3(0, 0, setback), terrain))
	if _player.has_method("reset_to"):
		_player.reset_to(staged)
	else:
		_player.global_transform = staged
	_player.ai_controlled = true
	_player.ai_throttle = 0.0
	_player.ai_steer = 0.0
	_player.ai_handbrake = false
	_player.axis_lock_linear_x = true
	_player.axis_lock_angular_y = true
	if "drivetrain" in _player and _player.drivetrain != null and _player.drivetrain.engine != null:
		_player_auto_was = _player.drivetrain.engine.auto
		_player.drivetrain.engine.auto = true  # so throttle pulls forward; restored at hand-off
	_player_staged = true


# --- Camera (orbit idle → fly-in → anchored reveal shot) ---------------------

func _build_orbit_camera() -> void:
	_orbit_cam = Camera3D.new()
	_orbit_cam.fov = _cfg().start_orbit_fov
	_orbit_cam.current = true  # take over from the chase camera for the reveal
	add_child(_orbit_cam)


# Place the orbit camera on its idle circle around the car (the MENU phase only).
func _update_orbit() -> void:
	if _orbit_cam == null:
		return
	var cfg := _cfg()
	var center := _player.global_position if _player != null else _start_xform.origin
	center += Vector3.UP * (cfg.start_orbit_height * 0.4)
	var eye := center + Vector3(
		cos(_orbit_angle) * cfg.start_orbit_radius,
		cfg.start_orbit_height,
		sin(_orbit_angle) * cfg.start_orbit_radius)
	_orbit_cam.look_at_from_position(eye, center, Vector3.UP)


func _advance_orbit(delta: float) -> void:
	_orbit_angle += delta * _cfg().start_orbit_speed
	_update_orbit()


# The fixed low 3/4 shot in front of the start line, looking back at the car on the
# line. Local −Z is down the lead-in (ahead of the line), so a negative Z places the
# camera AHEAD of the line; a lateral offset gives the 3/4 angle; a low height keeps it
# close to the ground.
func _compute_anchor() -> Transform3D:
	var cfg := _cfg()
	var eye := _start_xform * Vector3(cfg.start_reveal_cam_side_m, cfg.start_reveal_cam_height_m, -cfg.start_reveal_cam_front_m)
	var look := _start_xform.origin + Vector3.UP * cfg.start_reveal_cam_look_height_m
	return Transform3D(Basis(), eye).looking_at(look, Vector3.UP)


# --- Overlay (MENU: Start / Upgrades / Tune Car) -----------------------------

# The MENU UI follows the design system (UITheme): pure-black, sharp-cornered panels,
# the one house font size, uppercase text. It hugs the TOP (a rally/event header) and
# BOTTOM (the action buttons) of the screen, leaving the centre band clear so the
# orbiting car shows through.
func _build_overlay(rally: Dictionary, event_index: int) -> void:
	_overlay = CanvasLayer.new()
	_overlay.layer = 5  # above the HUD (2) / mobile (3), below the fade
	add_child(_overlay)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = UITheme.MARGIN
	root.offset_top = UITheme.MARGIN
	root.offset_right = -UITheme.MARGIN
	root.offset_bottom = -UITheme.MARGIN
	root.add_theme_constant_override("separation", UITheme.GAP)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(root)

	# --- TOP card: the rally + event header ----------------------------------
	var top_panel := UITheme.panel(UITheme.PANEL.a)
	top_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	root.add_child(top_panel)

	var top_box := VBoxContainer.new()
	top_box.add_theme_constant_override("separation", UITheme.GAP_TIGHT)
	top_panel.add_child(top_box)

	var total := _stage_total(rally)
	_subtitle_label = UITheme.title("%s — Stage %d of %d" % [String(rally.get("name", "Rally")), event_index + 1, total])
	top_box.add_child(_subtitle_label)
	# --- Clear band: lets the orbiting car show between the cards -------------
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(spacer)

	# --- BOTTOM: one horizontal action row -----------------------------------
	# Laid out across the bottom, exit-first-primary-last, the same shape the garage row
	# (< Back / Drive / Garage / Mystery Box) and the lift hub (< Back / Upgrades /
	# Tuning / Test Drive) use. Stacked vertically these four would eat most of a phone
	# screen and cover the very car the staging shot exists to show.
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", UITheme.GAP)
	root.add_child(actions)

	# EXIT lives here because the pause menu is suppressed while staged (see
	# sequence_finished) — without it the player would be stuck on the start line with no
	# way out but finishing the stage. Routed through the pause menu's own
	# confirm_quit_to_hq so the "abandon vs. pause a challenge" wording and the
	# benchmark/challenge/rally branching stay in exactly one place.
	_exit_button = _row_button("< Exit", _on_exit_pressed)
	actions.add_child(_exit_button)

	_upgrades_button = _row_button("Upgrades", _open_upgrades)
	actions.add_child(_upgrades_button)

	_tune_button = _row_button("Tune Car", _open_tune)
	actions.add_child(_tune_button)

	_start_button = _row_button("Start", launch)
	actions.add_child(_start_button)

	UITheme.enforce(_overlay)  # house rules: uppercase + one font size + fixed button height
	MenuNav.attach(root, {"first": _start_button})


# One button in the bottom action row — see UITheme.row_button for why a horizontal row
# must not carry BUTTON_MIN_W. This used to build via UITheme.button and then strip the
# width floor back off, which is the same idiom UITheme.row_button encapsulates;
# both now go through the shared helper.
func _row_button(text: String, on_press: Callable) -> Button:
	return UITheme.row_button(text, on_press)


# Leave the stage before it starts. Delegates to the pause menu's confirm-then-quit so
# there is one implementation of "what does abandoning mean here". With no pause menu
# (tests, bare harness) this is a no-op rather than a half-quit.
func _on_exit_pressed() -> void:
	if _pause_menu != null:
		_pause_menu.confirm_quit_to_hq()


# Is the pre-countdown sequence still running? The node is NOT freed when it finishes —
# it keeps hosting the overlay — so `is_instance_valid(start_line)` only ever means "one
# was built at some point", never "one owns the screen right now". Callers gating on the
# staged window (world.gd suppressing pause) must ask this instead.
func is_staging() -> bool:
	return _seq != Seq.DONE


# --- Reveal card (shown per opponent during REVEAL) --------------------------

# A compact house-style card at the TOP of the screen naming the front opponent and their
# car, with a labelled stat column (time to beat / gap to P1 / overall rank), and a Next
# button hugging the BOTTOM so nothing covers the car on the line. Built once, hidden
# until the first reveal, its text refreshed per opponent.
func _build_reveal_overlay() -> void:
	_reveal_overlay = CanvasLayer.new()
	_reveal_overlay.layer = 5
	_reveal_overlay.visible = false
	add_child(_reveal_overlay)

	# Full-rect column: the rival card hugging the TOP, an expanding clear band the car
	# shows through, then the Next button hugging the bottom edge.
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = UITheme.MARGIN
	root.offset_top = UITheme.MARGIN
	root.offset_right = -UITheme.MARGIN
	root.offset_bottom = -UITheme.MARGIN
	root.add_theme_constant_override("separation", UITheme.GAP)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_reveal_overlay.add_child(root)

	# --- TOP: the rival card -------------------------------------------------
	var panel := UITheme.panel(UITheme.PANEL.a)
	panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	root.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", UITheme.GAP_TIGHT)
	box.custom_minimum_size = Vector2(360, 0)  # width for the stat rows to lay label|value
	panel.add_child(box)

	_reveal_name_label = UITheme.label("", "ink")
	_reveal_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_reveal_name_label)

	_reveal_car_label = UITheme.label("", "dim")
	_reveal_car_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_reveal_car_label)

	# A thin gap between the header and the stat block.
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, UITheme.GAP_TIGHT)
	box.add_child(gap)

	var time_row := _stat_row("Time to beat", "gold")
	_reveal_time_label = time_row["value"]
	box.add_child(time_row["row"])

	var gap_row := _stat_row("Gap to P1", "ink")
	_reveal_gap_label = gap_row["value"]
	box.add_child(gap_row["row"])

	var overall_row := _stat_row("Overall", "ink")
	_reveal_overall_label = overall_row["value"]
	_reveal_overall_row = overall_row["row"]
	box.add_child(_reveal_overall_row)

	# --- clear band ----------------------------------------------------------
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(spacer)

	# --- BOTTOM: the Next button --------------------------------------------
	_next_button = UITheme.button("Next")
	_next_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_next_button.pressed.connect(next_car)
	root.add_child(_next_button)

	UITheme.enforce(_reveal_overlay)


# A labelled stat row for the reveal card: a left-aligned caption (dim) and a
# right-aligned value tinted by `role`. Returns { row, value } so the card can refresh
# the value per opponent.
func _stat_row(caption: String, role: String) -> Dictionary:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.GAP_WIDE)
	var cap := UITheme.label(caption, "dim")
	cap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var value := UITheme.label("", role)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(cap)
	row.add_child(value)
	return {"row": row, "value": value}


# Show the reveal card for the opponent currently on the line (`_reveal_index`): the
# header names them (P{n} + driver + car), the gold time-to-beat, the gap to the fastest
# rival (P1 reads FASTEST), and — from event 2 on — their overall championship position.
func _show_reveal_card() -> void:
	if _reveal_index >= _leaders.size():
		return
	var e: Dictionary = _leaders[_reveal_index]
	var car := String(e.get("car_name", ""))
	_reveal_name_label.text = "P%d   %s" % [_reveal_index + 1, String(e.get("name", "Rival"))]
	_reveal_car_label.text = car
	_reveal_car_label.visible = car != ""
	var mine := int(e.get("time_ms", -1))
	_reveal_time_label.text = UITheme.format_time(mine, "—")
	# Gap to the fastest rival — _leaders is fastest-first, so _leaders[0] is the benchmark.
	var fastest := int((_leaders[0] as Dictionary).get("time_ms", -1)) if not _leaders.is_empty() else -1
	_reveal_gap_label.text = _format_gap(mine, fastest)
	# Overall championship position so far (event 2+); hide the row when it's not known.
	var placed := int(_overall_rank.get(String(e.get("name", "")), -1))
	_reveal_overall_row.visible = placed >= 1
	if placed >= 1:
		_reveal_overall_label.text = _ordinal(placed)
	UITheme.enforce(_reveal_overlay)  # re-uppercase the freshly-set text
	_reveal_overlay.visible = true
	get_viewport().gui_release_focus()
	MenuNav.attach(_reveal_overlay.get_child(0), {"first": _next_button})
	_next_button.grab_focus.call_deferred()


# The gap between a rival's time and the fastest rival's, as "+m:ss.cc" (or "+s.cc"
# under a minute). The fastest rival (and any non-time) reads FASTEST.
func _format_gap(time_ms: int, fastest_ms: int) -> String:
	if time_ms < 0 or fastest_ms < 0 or time_ms <= fastest_ms:
		return "FASTEST"
	var s := (time_ms - fastest_ms) / 1000.0
	if s < 60.0:
		return "+%.2f" % s
	var m := int(s / 60.0)
	return "+%d:%05.2f" % [m, s - m * 60.0]


# An ordinal championship position: 1 -> "1ST", 2 -> "2ND", 3 -> "3RD", 11..13 -> "TH".
func _ordinal(n: int) -> String:
	var suffix := "TH"
	if n % 100 < 11 or n % 100 > 13:
		match n % 10:
			1: suffix = "ST"
			2: suffix = "ND"
			3: suffix = "RD"
	return "%d%s" % [n, suffix]


# Map driver name → overall championship position from the standings so far, for the
# reveal card's OVERALL stat. Empty on event 1 (nothing raced yet → everyone tied, so the
# ranking is meaningless) or when no rally is active (dev/test, or a challenge run — which
# has no rival field at all, spec §3, so it passes no leaders and never reveals a card) —
# the card hides the row rather than showing a bogus "1ST" for everyone.
func _build_overall_ranks() -> void:
	_overall_rank = {}
	if _event_index <= 0 or not RallySession.is_active():
		return
	for row in RallySession.current_standings():
		var nm := String(row.get("name", ""))
		if nm != "":
			_overall_rank[nm] = int(row.get("placed", -1))


# --- Fade-to-black overlay ---------------------------------------------------

func _build_fade() -> void:
	_fade = CanvasLayer.new()
	_fade.layer = 100  # above everything, so the transition fully covers the screen
	add_child(_fade)
	_fade_rect = ColorRect.new()
	_fade_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade_rect.color = Color(0, 0, 0, 0)
	_fade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade.add_child(_fade_rect)


# --- Grid cars (the real top-three rivals ahead of the player) ---------------

# Spawn the opponent cars that line up ahead of the player: the real top-N rivals for
# this event, each in its ACTUAL car. They are LIVE, scripted, silenced car props (so
# they load their suspension as they drive off / roll up). Front-first: grid[0] sits on
# the line and drives off first.
func _spawn_grid(terrain: Node) -> void:
	_grid = []
	_grid_car_ids = []
	var gap := _cfg().start_queue_gap
	var n := _grid_ahead_count()
	# Each prop's apply_car() mutates a GameConfig (gearbox, mass, grip, …), and one that
	# somehow missed use_isolated_config() would reach the SHARED global Config.data. The
	# player is already fielded, so snapshot the live config's VALUES here and restore them
	# after the props are built.
	#
	# VALUES restored IN PLACE, never `Config.data = <duplicate>`: the fielded player car
	# holds this exact object as its `config` (car.gd), so swapping the reference splits the
	# two — the car (and the pre-race Upgrades menu's refit_upgrades) keeps writing the old
	# object while the HUD, engine audio and save layer read the new one. That is what used
	# to leave a turbo bought at this menu working but with no boost gauge until the next
	# stage rebuilt the world. See GameConfig.snapshot_values().
	var player_cfg := Config.data.snapshot_values()
	for i in n:
		var car_id := String((_leaders[i] as Dictionary).get("car_id", ""))
		var index := CarLibrary.index_of(car_id)
		if index < 0:
			continue  # unknown id (fixture/synthetic leaders) — skip rather than spawn a bogus car
		var pos := _ground(_start_xform * Vector3(0, 0, gap * float(i)), terrain)
		# The rival's FITTED engine, not the car's stock one — see _spawn_prop.
		var car := _spawn_prop(index, pos, String((_leaders[i] as Dictionary).get("engine_id", "")))
		_grid.append(car)
		_grid_car_ids.append(car_id)
	Config.data.restore_values(player_cfg)
	# The player is the tail of the grid — it rolls up as the opponents depart.
	if _player != null:
		_grid.append(_player)
	# Drive on the terrain, but never shove (or get shoved by) the player or each other.
	if _player is PhysicsBody3D:
		for car in _grid:
			if car != _player and car is PhysicsBody3D:
				(car as PhysicsBody3D).add_collision_exception_with(_player)
	for a in _grid.size():
		for b in range(a + 1, _grid.size()):
			if _grid[a] is PhysicsBody3D and _grid[b] is PhysicsBody3D:
				(_grid[a] as PhysicsBody3D).add_collision_exception_with(_grid[b])


# Drop a world point onto the terrain, keeping the player's ride height above it.
func _ground(pos: Vector3, terrain: Node) -> Vector3:
	if terrain != null and terrain.has_method("height_at"):
		var ride: float = _start_xform.origin.y - terrain.height_at(_start_xform.origin.x, _start_xform.origin.z)
		pos.y = terrain.height_at(pos.x, pos.z) + ride
	return pos


# A live, scripted, silent car prop facing the start heading. Runs full physics but
# reads scripted throttle/steer instead of player Input, axis-locked to a straight line
# so it can't veer (start heading is world −Z, so lock lateral world-X + yaw world-Y).
func _spawn_prop(model_index: int, pos: Vector3, engine_id := "") -> Node3D:
	var car := CAR_SCENE.instantiate()
	add_child(car)
	if car.has_method("apply_car"):
		# Isolate this prop's config so its reshape can't clobber the player car's
		# engine/gearbox in the shared global Config.data (see car.gd `config`).
		car.use_isolated_config()
		# Defer the engine-voice build to fit_engine below, which fits the rival's
		# SWAPPED engine (rivals run engine swaps — features/rally-roster.md) and then
		# builds the voice once. Without it the prop idles and pulls away on the car's
		# stock engine while the reveal card names the swapped one.
		car.apply_car(model_index, false)
		if car.has_method("fit_engine"):
			car.fit_engine(engine_id)
	# Place via reset_to (the pending-teleport path), NOT a bare global_transform write:
	# car._ready() captures its spawn pose at ADD-CHILD time (the origin), and a plain
	# global_transform write on a VehicleBody3D is discarded by the physics server (see
	# car.gd reset_to), so every prop would otherwise snap back to the origin and stack.
	var place := Transform3D(_start_xform.basis, pos)
	if car.has_method("reset_to"):
		car.reset_to(place)
	else:
		car.global_transform = place
	car.freeze = false
	car.ai_controlled = true
	car.ai_throttle = 0.0
	car.ai_steer = 0.0
	car.ai_handbrake = false
	car.axis_lock_linear_x = true
	car.axis_lock_angular_y = true
	if car.drivetrain != null and car.drivetrain.engine != null:
		car.drivetrain.engine.auto = true  # auto box so throttle pulls away
	# The car idles audibly in the queue; proximity attenuation (engine_audio.gd)
	# scales its loudness by distance from the reveal camera — no bespoke muting.
	return car


# --- Sequence ----------------------------------------------------------------

func _process(delta: float) -> void:
	var __t := Time.get_ticks_usec()
	_timed_process(delta)
	PerfLog.track(&"start_line", Time.get_ticks_usec() - __t)


func _timed_process(delta: float) -> void:
	match _seq:
		Seq.MENU:
			_advance_orbit(delta)
		Seq.FLY_IN:
			_seq_t += delta
			var fly := maxf(_cfg().start_reveal_fly_seconds, 0.0001)
			var s := smoothstep(0.0, 1.0, clampf(_seq_t / fly, 0.0, 1.0))
			_orbit_cam.global_transform = Transform3D(
				_fly_from.basis.slerp(_anchor_xform.basis, s),
				_fly_from.origin.lerp(_anchor_xform.origin, s))
			_orbit_cam.fov = lerpf(_fly_from_fov, _cfg().start_reveal_cam_fov, s)
			if _seq_t >= fly:
				_orbit_cam.global_transform = _anchor_xform
				_orbit_cam.fov = _cfg().start_reveal_cam_fov
				_enter_reveal()
		Seq.REVEAL:
			# Waits for Next (or a tap) to advance the card, but keeps rolling the
			# remaining field (opponents + player) up toward their slots underneath, so the
			# grid catches up as ambient motion without gating the reveal.
			_roll_grid_to_slots()
			_prune_departed()
		Seq.FADE_OUT:
			_seq_t += delta
			var fade := maxf(_cfg().start_fade_seconds, 0.0001)
			_fade_rect.color.a = clampf(_seq_t / fade, 0.0, 1.0)
			if _seq_t >= _cfg().start_fade_seconds:
				_handoff()
				_seq = Seq.FADE_IN
				_seq_t = 0.0
		Seq.FADE_IN:
			_seq_t += delta
			var fade := maxf(_cfg().start_fade_seconds, 0.0001)
			_fade_rect.color.a = clampf(1.0 - _seq_t / fade, 0.0, 1.0)
			if _seq_t >= _cfg().start_fade_seconds:
				_fade.visible = false
				_seq = Seq.DONE
				# Nothing left to drive: stop paying for a _process call (and its
				# PerfLog wrapper) every frame for the rest of the run.
				set_process(false)
		Seq.DONE:
			pass


# Enter the REVEAL phase for the opponent now on the line: show the card and wait.
func _enter_reveal() -> void:
	_seq = Seq.REVEAL
	_seq_t = 0.0
	_show_reveal_card()


# Roll every remaining grid car up toward its slot (front-first: grid[i] → slot i). Run
# each REVEAL frame so the field catches up as ambient motion behind the card.
func _roll_grid_to_slots() -> void:
	for i in _grid.size():
		_roll_car_to(_grid[i], _ground(_start_xform * Vector3(0, 0, _cfg().start_queue_gap * float(i)), _terrain))


# Roll a scripted car UP TO `target` and brake to a stop ON it, instead of flooring it
# and coasting past. Drives forward while well behind, coasts into a speed-aware brake
# point, then brakes+holds — easing to a halt at it.
func _roll_car_to(car, target: Vector3) -> void:
	if car == null or not is_instance_valid(car) or not ("ai_controlled" in car):
		return
	var cfg := _cfg()
	var fwd := (-_start_xform.basis.z).normalized()
	var dist: float = (target - car.global_position).dot(fwd)
	var v: float = car.linear_velocity.length()
	var brake_dist: float = v * v / cfg.start_roll_decel_divisor + cfg.start_roll_brake_margin_m
	if dist <= brake_dist:
		# On/at the target: brake to a stop, then hold on the handbrake. Cut the brake
		# pedal once nearly stopped so the auto box doesn't grab reverse against the hold.
		car.ai_throttle = -1.0 if v > cfg.start_roll_creep_speed else 0.0
		car.ai_handbrake = true
	elif dist > brake_dist + cfg.start_roll_coast_band_m:
		car.ai_throttle = 1.0    # well behind: roll up
		car.ai_handbrake = false
	else:
		car.ai_throttle = 0.0    # coast into the brake point
		car.ai_handbrake = false


# Despawn departed cars once they've driven past the start line down the lead-in (before
# the first corner), so they never fight their axis-lock into a bend and cost nothing.
func _prune_departed() -> void:
	var margin := _cfg().start_lead_in_ahead_m
	var kept: Array[Node3D] = []
	for car in _departed:
		if car == null or not is_instance_valid(car):
			continue
		var local := _start_xform.affine_inverse() * car.global_position
		if local.z < -margin:  # driven past the lead-in ahead of the line
			if car.has_method("silence_engine_audio"):
				car.silence_engine_audio()  # no live note to hard-cut when it frees
			car.queue_free()
		else:
			kept.append(car)
	_departed = kept


func _unhandled_input(event: InputEvent) -> void:
	# A pointer tap advances the REVEAL phase (sends the front car off) for touch/mouse
	# players; keyboard/gamepad use the focused buttons.
	#
	# It deliberately does NOT start the run. Tapping anywhere on the MENU phase used to
	# call launch(), which meant a stray tap — reaching for UPGRADES or TUNE CAR and missing,
	# or an idle tap while reading the stage banner — committed the player to the stage with
	# no confirmation and no way back. Starting is now the START button's job alone (it is a
	# real Button, so touch players reach it directly). The REVEAL phase keeps tap-to-advance
	# because the run has already begun there: the worst a stray tap does is show the next
	# rival sooner.
	if not ((event is InputEventScreenTouch and event.pressed) \
			or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT)):
		return
	if _seq == Seq.REVEAL:
		next_car()


# Begin the launch: run the eligibility gates, then fly the camera to the reveal shot
# (or, with no opponents to reveal, straight to the fade). Idempotent — only fires from
# the waiting MENU phase, so a second tap during the sequence is ignored.
func launch() -> void:
	if _launched or _seq != Seq.MENU:
		return
	if not _rally.is_empty():
		var owned := _driven_car()
		if not owned.is_empty():
			var entry := CarLibrary.for_owned(owned)
			var meta := UpgradeLibrary.effective_meta(owned, entry)
			# Entry is categorical (body / country / doors / engine / drive mode), so a
			# mid-rally upgrade can only break eligibility by changing the KIND of car —
			# an engine swap or a drivetrain conversion. Route those to the upgrades menu.
			var reason := RallyLibrary.ineligibility_reason(_rally, meta)
			if reason != "":
				ConfirmPopup.open(self, "Can't start", reason,
					[ {"label": "Cancel", "callback": Callable()},
					  {"label": "Change Upgrades", "callback": _open_upgrades} ], 1, 0)
				return
	_launched = true
	if _overlay != null:
		_overlay.visible = false
	if _grid_ahead_count() <= 0:
		# No opponents to reveal — the player is already on the line. Straight to the fade.
		_seq = Seq.FADE_OUT
		_seq_t = 0.0
		return
	# Fly the camera from the (now frozen) orbit pose to the anchored reveal shot.
	_fly_from = _orbit_cam.global_transform
	_fly_from_fov = _orbit_cam.fov
	_anchor_xform = _compute_anchor()
	_seq = Seq.FLY_IN
	_seq_t = 0.0


# Next: send the front car off the line and REVEAL the next opponent immediately. The
# departed car and the rest of the field roll on underneath (see the REVEAL phase) — the
# reveal does NOT wait for them to line up, so the player can tap straight through. Once
# only the player remains, the fade begins. Only from the waiting REVEAL phase.
func next_car() -> void:
	if _seq != Seq.REVEAL or _grid.size() <= 1:
		return
	var front := _grid.pop_front() as Node3D
	if front != null and "ai_controlled" in front:
		front.ai_throttle = 1.0
		front.ai_handbrake = false
	if front != null:
		# The car pulls away sounding its own engine; proximity attenuation lets its
		# note recede naturally with distance as it drives off down the lead-in.
		_departed.append(front)
	_reveal_index += 1
	if _grid.size() <= 1:
		# Only the player is left — it's on (or rolling onto) the line. Begin the fade;
		# the hand-off snaps the player exactly onto the line, so any remaining roll-up is
		# just cosmetic under the black.
		if _reveal_overlay != null:
			_reveal_overlay.visible = false
		_seq = Seq.FADE_OUT
		_seq_t = 0.0
	else:
		# Reveal the next opponent right away; its car rolls up into the shot underneath.
		_show_reveal_card()


# At full black: hand the camera back to the player's selected mode, restore the driving
# UI, and start the countdown. (The StageManager has been waiting in STAGING.)
func _handoff() -> void:
	if _orbit_cam != null:
		_orbit_cam.current = false
	if _camera_manager != null:
		_camera_manager.activate_current()
	if _hud != null:
		_hud.visible = Config.data.hud_enabled
	if _mobile != null:
		_mobile.visible = true
	_release_player()  # hand the player back to normal driving for the run
	sequence_finished.emit()  # world.gd re-arms the pause menu here
	_despawn_grid()    # gone under cover of the black, so they cost nothing during the run
	if _stage_manager != null and _stage_manager.has_method("begin_countdown"):
		_stage_manager.begin_countdown()


# Undo the roll-up scripting so the run drives normally, and snap the player exactly onto
# the start line (hidden by the fade). The StageManager forces the handbrake through the
# countdown, so the car holds at the line until GO.
func _release_player() -> void:
	if not _player_staged or not (_player is VehicleBody3D) or not ("ai_controlled" in _player):
		return
	_player.ai_controlled = false
	_player.ai_throttle = 0.0
	_player.ai_steer = 0.0
	_player.axis_lock_linear_x = false
	_player.axis_lock_angular_y = false
	if "drivetrain" in _player and _player.drivetrain != null and _player.drivetrain.engine != null:
		_player.drivetrain.engine.auto = _player_auto_was
	if _player.has_method("reset_to"):
		_player.reset_to(_start_xform)
	_player_staged = false


# Free every opponent car (grid remainder + departed). The player is never freed.
func _despawn_grid() -> void:
	for car in _grid + _departed:
		if car != null and car != _player and is_instance_valid(car):
			car.queue_free()
	_grid = []
	_departed = []


# --- Pre-race menus (Upgrades / Tune Car) ------------------------------------

# The CarPerformance rating ceiling for the pre-race tune / upgrades menus (-1 = none).
# A thin wrapper over DrivingContext.rating_limit(), which answers for whichever session
# is fielding the car — only a challenge period's rolled ceiling today, since career
# entry is categorical — so this screen never has to branch.
func _rating_limit() -> float:
	return DrivingContext.rating_limit()


# Body width both pre-race menu overlays use. Sized for the narrow logical UI canvas rather
# than the window (see features/menus.md -> "Upgrades / Tune panel width"); it was previously
# a 520.0 default that no call site used, with the real 380.0 duplicated at both of them.
const MENU_OVERLAY_WIDTH := 380.0

# Build a pre-race menu overlay: a CanvasLayer (layer 6, above the start overlay) with a
# centred house panel wrapping a titled `component` and a Back button wired to `on_back`.
func _build_menu_overlay(title: String, component: Control, on_back: Callable, connect_back := true,
		width := MENU_OVERLAY_WIDTH) -> CanvasLayer:
	var layer := CanvasLayer.new()
	layer.layer = 6   # above the start overlay (layer 5)
	add_child(layer)
	# MenuPage owns this shape now — a titled body box sized to its contents, with the page's
	# ACTIONS in ONE centred horizontal row gapped off the box below it. See menu_page.gd for
	# the two rules and why they aren't per-screen choices; this screen used to hand-roll the
	# same CenterContainer + panel + gap-spacer + HBox stack.
	var page := MenuPage.new({"title": title, "width": width, "alpha": UITheme.PANEL.a})
	layer.add_child(page)
	page.body().add_child(component)

	# Back leads, the component's own actions follow, so "leaving" is always leftmost.
	var back := UITheme.row_button("Back", Callable())
	back.focus_mode = Control.FOCUS_ALL  # these pages navigate by native focus (MenuNav)
	if connect_back:
		back.pressed.connect(on_back)
	page.add_action(back)
	# A component may contribute its own actions (TuningPanel's Reset / Wheels). It builds
	# them but never parents them, precisely so they can land in this row.
	if component.has_method("action_buttons"):
		for b in component.action_buttons():
			page.add_action(b)
	_menu_last_back = back
	UITheme.enforce(layer)
	return layer


# Show a pre-race menu overlay: hide the start overlay, reveal the page, release focus,
# and wire its MenuNav so it's keyboard/gamepad navigable.
func _open_menu(layer: CanvasLayer, first: Control, on_back: Callable) -> void:
	if _overlay != null:
		_overlay.visible = false
	layer.visible = true
	get_viewport().gui_release_focus()
	MenuNav.attach(layer.get_child(0), {"first": first, "on_back": on_back})


# Close a pre-race menu overlay: hide the page, restore the start overlay, re-focus the
# button that opened it.
func _close_menu(layer: CanvasLayer, return_button: Button) -> void:
	if layer != null:
		layer.visible = false
	if _overlay != null:
		_overlay.visible = true
	if return_button != null:
		return_button.grab_focus.call_deferred()


func _open_tune() -> void:
	if _seq != Seq.MENU:
		return
	if _tune_layer == null:
		_build_tune_overlay()
	var owned := _driven_car()
	_tune_panel.setup(owned, _on_tune_changed.bind(owned))
	_tune_panel.refresh()
	_open_menu(_tune_layer, _tune_panel.first_slider(), _close_tune)


func _close_tune() -> void:
	_close_menu(_tune_layer, _tune_button)


func _build_tune_overlay() -> void:
	_tune_panel = TuningPanel.new()
	# Same 380 as the Upgrades overlay (_build_upgrades_overlay): TuningPanel's rows are
	# the same SliderRow shape as the detune row (180px label + an expand-fill slider), so
	# the old shared 520 floor stretched this slider bar just as unnecessarily wide.
	_tune_layer = _build_menu_overlay("Tune Car", _tune_panel, _close_tune)


# An edit was made in the tune panel. Re-apply ONLY the tuning to the live config
# (retune) — NOT apply_owned, which would reshape and corrupt the staged body.
func _on_tune_changed(owned: Dictionary) -> void:
	if _player != null and _player.has_method("retune"):
		_player.retune(owned)


func _open_upgrades() -> void:
	if _seq != Seq.MENU:
		return
	if _upgrades_layer == null:
		_build_upgrades_overlay()
	var owned := _driven_car()
	_upgrades_menu.setup(owned, _on_upgrade_changed, Callable(), _rating_limit())
	_upgrades_menu.bind_close_button(_upgrades_back, _close_upgrades)
	_open_menu(_upgrades_layer, _upgrades_menu.first_control(), _upgrades_menu.request_close)


# Closing the Upgrades page is the commit point for an edit made ON THE GRID, so the
# rival field has to be re-drawn against the build the player is actually about to race.
# The grid is matched to the player's rating (features/car-performance.md), so without
# this a turbo fitted here would leave them racing a field picked for the car they
# arrived in — the matching would stop meaning anything exactly when the player engages
# with it. RallySession decides whether a re-draw is allowed (it refuses mid-rally, where
# it would rewrite standings already raced) and whether anything actually changed.
func _close_upgrades() -> void:
	_close_menu(_upgrades_layer, _upgrades_button)
	if RallySession.is_active() and RallySession.refield_opponents():
		_restage_grid()


# Re-stage the cars physically sitting on the grid after the field has been re-drawn.
#
# The props are spawned ONCE from `_leaders` when the start line is built, so a re-draw
# would otherwise change who the player is racing while leaving the old cars parked in
# front of them — the grid would be lying about the field. `_leaders` itself is re-read
# here too; the reveal cards index into it lazily, so refreshing the array is enough for
# those (no overlay rebuild needed).
#
# The player is the tail of `_grid` and must survive: it is the live car, not a prop.
func _restage_grid() -> void:
	for car in _grid:
		if car == _player or not is_instance_valid(car):
			continue
		# remove_child BEFORE queue_free: the free is deferred to end-of-frame, so a bare
		# queue_free would leave the outgoing prop sitting on the grid — visibly clipping
		# through the replacement _spawn_grid stages at the same slot this same frame.
		remove_child(car)
		car.queue_free()
	_grid = []
	_grid_car_ids = []
	_leaders = RallySession.current_event_leaders()
	_build_overall_ranks()
	_spawn_grid(_terrain)


func _build_upgrades_overlay() -> void:
	_upgrades_menu = UpgradesGrid.new()
	# Narrower than Tune Car's default 520: the 3x3 tile grid asks for far less room than
	# the handling-axis sliders, and the shared 520 floor only stretched it across leftover
	# width — reading as an oversized panel.
	# No page title: UpgradesGrid draws its own heading, and that heading is what carries
	# the star balance beside the prices its slot pickers quote (UpgradesGrid.build_title_row).
	_upgrades_layer = _build_menu_overlay("", _upgrades_menu, _close_upgrades, false)
	_upgrades_back = _menu_last_back


# An upgrade edit. Re-field the live car's upgrade state WITHOUT reshaping the staged
# body (refit_upgrades, NOT apply_owned).
func _on_upgrade_changed() -> void:
	if _player != null and _player.has_method("refit_upgrades"):
		_player.refit_upgrades(_driven_car())


# --- Readouts (for tests) ----------------------------------------------------

func sequence_phase() -> int:
	return _seq


func has_launched() -> bool:
	return _launched


# The number of opponent cars ahead of the player still on the grid (excludes the
# player tail and any car that has already driven off).
func queue_count() -> int:
	var n := 0
	for car in _grid:
		if car != _player:
			n += 1
	return n


# The car ids of the opponent grid cars, front-first as spawned (test readout).
func queue_car_ids() -> Array[String]:
	return _grid_car_ids


func reveal_index() -> int:
	return _reveal_index


# The car actually under the reveal camera's focus right now, while REVEAL is waiting
# for Next — null outside REVEAL (or with nothing left to show). engine_audio.gd uses
# this to exempt the focus car from the tightened reveal-queue radius: it's the one the
# player is looking at, so it should keep sounding at its normal, pre-reveal loudness
# while the cars waiting behind it get quieter.
#
# NOT simply `_grid[0]`: next_car() advances the reveal index (and the card) the
# instant the front car is waved off, but the NEW front car takes a moment to physically
# roll up into the shot from its old queue slot (_roll_grid_to_slots), and the departing
# car takes a moment to actually pull away. So for a brief window after every tap,
# `_grid[0]` is the data-correct "next" car while the car still nearest the camera — the
# one actually on screen — is the one that just departed. Picking `_grid[0]` there
# exempted the wrong car: the player heard the (still-attenuated) car one slot behind
# the one their eyes were on. Instead, pick whichever car — queued or just-departed —
# is physically nearest the reveal camera; the exemption then hands over naturally at
# the moment the new front car actually arrives in shot, matching what's on screen.
func reveal_focus_car() -> Node3D:
	if _seq != Seq.REVEAL:
		return null
	var cam_pos: Vector3 = _orbit_cam.global_position if _orbit_cam != null else _start_xform.origin
	var best: Node3D = null
	var best_d2 := INF
	for car in _grid + _departed:
		if car == null or not is_instance_valid(car):
			continue
		var d2: float = cam_pos.distance_squared_to(car.global_position)
		if d2 < best_d2:
			best = car
			best_d2 = d2
	return best


func _exit_tree() -> void:
	if active_instance == self:
		active_instance = null
