class_name StartLine
extends Node3D
# Docs: features/start-line.md — update in the same change as this file.
# Tests: tests/headless/test_stage_manager.gd, tests/headless/test_start_line.gd — extend in the same change.
# The pre-event start-line sequence (todo/menus.md location 2) — the cinematic
# moment between picking a car in HQ and the 3·2·1·GO countdown. It runs inside the
# live run scene (main.tscn) once the world is built and a ChallengeSession stage is
# active (features/rally-challenge.md), while the car is held locked by the
# StageManager's STAGING phase:
#
#   1. MENU     — black house-style panels offer Start / Tune Car under a
#      rally/event header, while an orbit camera idles on the player's car. The player
#      launches with the Start button, menu_select or a tap (eligibility gates first).
#   2. FADE     — Start fades the screen to black; at full black the camera hands back
#      to the player's SELECTED camera (via the CameraManager), the driving UI returns
#      and StageManager.begin_countdown() starts the countdown; then it fades back in.
#
# Created and wired by world.gd (session runs only). A plain dev boot of main.tscn
# never builds a StartLine and the StageManager goes straight to the countdown.
#
# THE RIVAL REVEAL — a per-opponent FLY_IN + REVEAL phase between MENU and the fade,
# showing the three real top-three rivals lined up ahead in their actual cars — is
# DELETED along with the rival field it dramatized (todo/roguelike-pivot.md decision
# 5; decision 29 keeps this MENU, only the reveal goes). `setup()` no longer takes a
# `leaders` argument.

## Car scene path lives in Scenes.CAR (scripts/scenes.gd); loaded via Scenes.car_scene()
## below since preload() cannot take that reference (needs a literal string).

# Sequence phases. MENU waits for a press; the rest are time-driven in _process.
enum Seq { MENU, FADE_OUT, FADE_IN, DONE }

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
var _tune_panel: TuningPanel         # the shared handling-axis tuning sliders
var _menu_last_back: Button          # back button _build_menu_overlay just created
var _pause_menu: PauseMenu           # for the Exit button; pause itself is off while staged
var _exit_button: Button
var _rally: Dictionary = {}          # this event's rally (its restriction gates launch)
var _subtitle_label: Label
var _fade: CanvasLayer
var _fade_rect: ColorRect

# This event's index (0-based), for the header's "Stage X of N".
var _event_index := 0

# The player's start pose, captured at setup. The player is staged at this pose,
# axis-locked so it can't drift during the MENU orbit, and released at hand-off.
var _start_xform: Transform3D
var _player_staged := false   # true once the player is scripted for staging
var _player_auto_was := false # the player's gearbox auto flag, restored at hand-off

# The live StartLine for this run, if any — set in setup(), cleared in _exit_tree().
# engine_audio.gd used to read this to tell whether ITS car was sitting in the
# (now-deleted) reveal queue.
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
# (spec §2) — the only session StartLine stages for now that RallySession is
# deleted (todo/roguelike-pivot.md decision 5). Every consumer (the launch
# eligibility gate and the Tune Car panel) goes
# through this rather than branching for itself, so there is a single answer.
#
# Free roam is deliberately NOT folded in here: it is session-less, never stages
# (world.gd._should_stage() requires an active session, so no StartLine is ever
# built for it).
func _driven_car() -> Dictionary:
	return DrivingContext.driven_car()


# Total stages in this event set: the rally's own authored event list, or — for a
# challenge, which has no authored events — the active run's stage count. Only a
# challenge stage reaches here at all now (RallySession, the career caller, is
# deleted — todo/roguelike-pivot.md decision 5), so `rally` never carries an
# `events` list in practice; the fallback is what actually renders.
func _stage_total(rally: Dictionary) -> int:
	var total: int = rally.get("events", []).size()
	if total > 0:
		return total
	if ChallengeSession.is_active():
		return ChallengeSession.stage_count()
	return 1


# Build the start-line sequence around the fielded car. `terrain` (optional) sits
# the player on the ground; `camera_manager` / `hud` / `mobile` are handed back at
# the fade (the camera via the manager, so the player's chosen mode — not always
# chase — resumes).
func setup(player: Node3D, terrain: Node, stage_manager: Node, rally: Dictionary,
		event_index: int, camera_manager: CameraManager = null,
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
	_event_index = event_index
	_start_xform = player.global_transform
	# Seat the start-line car a small clearance ABOVE the road at spawn so it settles
	# onto its wheels instead of spawning clipped into the ground. Anchoring it on
	# _start_xform here cascades everywhere: the staged player reads its ride height
	# off it (via _ground), and the countdown pose is reset_to it at the hand-off —
	# so the player is clear before AND during the countdown.
	if terrain != null and terrain.has_method("height_at"):
		_start_xform.origin.y = terrain.height_at(_start_xform.origin.x, _start_xform.origin.z) + _cfg().start_spawn_clearance
	# Hide the driving UI; the menu is camera-only until the fade hands it back.
	if _hud != null:
		_hud.visible = false
	if _mobile != null:
		_mobile.visible = false
	_build_orbit_camera()
	_build_overlay(rally, event_index)
	_build_fade()
	_stage_player(terrain)
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


# Stage the player at the start line, axis-locked so it can't drift during the MENU
# orbit. Scripted like a grid car used to be; cleared at the hand-off so the run
# drives normally. No-op for a non-Car player (test stubs).
func _stage_player(terrain: Node) -> void:
	if not (_player is VehicleBody3D) or not ("ai_controlled" in _player):
		return
	# reset_to (pending teleport) so the staged pose survives the physics server; a bare
	# global_transform write on a VehicleBody3D is discarded (see car.gd reset_to). The
	# test stub has no reset_to, so fall back to the bare write there.
	if _player.has_method("reset_to"):
		_player.reset_to(_start_xform)
	else:
		_player.global_transform = _start_xform
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


# --- Camera (orbit idle) -----------------------------------------------------

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


# --- Overlay (MENU: Start / Tune Car) ----------------------------------------

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
	# Laid out across the bottom, exit-first-primary-last. Stacked vertically these would
	# eat most of a phone screen and cover the very car the staging shot exists to show.
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


# --- Sequence ----------------------------------------------------------------

func _process(delta: float) -> void:
	var __t := Time.get_ticks_usec()
	_timed_process(delta)
	PerfLog.track(&"start_line", Time.get_ticks_usec() - __t)


func _timed_process(delta: float) -> void:
	match _seq:
		Seq.MENU:
			_advance_orbit(delta)
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


# Begin the launch: run the eligibility gates, then fade to the countdown. Idempotent
# — only fires from the waiting MENU phase, so a second tap during the sequence is
# ignored. Used to fly the camera to a per-opponent reveal shot first; that phase is
# deleted with the rival field it revealed (todo/roguelike-pivot.md decision 5), so
# launch now goes straight to the fade.
func launch() -> void:
	if _launched or _seq != Seq.MENU:
		return
	if not _rally.is_empty():
		var owned := _driven_car()
		if not owned.is_empty():
			var entry := CarLibrary.for_owned(owned)
			var meta := UpgradeLibrary.effective_meta(owned, entry)
			# Entry is categorical (body / country / doors / engine / drive mode). Nothing
			# reachable from this screen can change the KIND of car any more — the Upgrades
			# page went with the parts model (decision 29: the start line offers Tune Car
			# only) — so an ineligible car is simply refused with no route to fix it here.
			var reason := RallyLibrary.ineligibility_reason(_rally, meta)
			if reason != "":
				ConfirmPopup.open(self, "Can't start", reason,
					[ {"label": "Cancel", "callback": Callable()} ], 0, 0)
				return
	_launched = true
	if _overlay != null:
		_overlay.visible = false
	_seq = Seq.FADE_OUT
	_seq_t = 0.0


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
	if _stage_manager != null and _stage_manager.has_method("begin_countdown"):
		_stage_manager.begin_countdown()


# Undo the staging scripting so the run drives normally, and snap the player exactly onto
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


# --- Pre-race menu (Tune Car) ------------------------------------------------

# The CarPerformance rating ceiling for the pre-race tune menu (-1 = none).
# A thin wrapper over DrivingContext.rating_limit(), which answers for whichever session
# is fielding the car — only a challenge period's rolled ceiling today, since career
# entry is categorical — so this screen never has to branch.
func _rating_limit() -> float:
	return DrivingContext.rating_limit()


# Body width the pre-race menu overlay uses. Sized for the narrow logical UI canvas rather
# than the window (see features/menus.md -> "Upgrades / Tune panel width").
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
	_tune_layer = _build_menu_overlay("Tune Car", _tune_panel, _close_tune)


# An edit was made in the tune panel. Re-apply ONLY the tuning to the live config
# (retune) — NOT apply_owned, which would reshape and corrupt the staged body.
func _on_tune_changed(owned: Dictionary) -> void:
	if _player != null and _player.has_method("retune"):
		_player.retune(owned)


# THE UPGRADES PAGE IS GONE (todo/roguelike-pivot.md decision 29: "the start line offers
# Tune Car only"). `_open_upgrades` / `_close_upgrades` / `_build_upgrades_overlay` /
# `_on_upgrade_changed` hosted an UpgradesGrid here; upgrades have nothing to show once
# parts are deleted and boosts are picked between stages instead. Tune Car below survives
# and is per-stage useful. Car.refit_upgrades — the live re-derive this page drove — is
# kept for stage 5 to apply a picked boost through; see its comment.


# --- Readouts (for tests) ----------------------------------------------------

func sequence_phase() -> int:
	return _seq


func has_launched() -> bool:
	return _launched


# queue_count(), queue_car_ids(), reveal_index() and reveal_focus_car() — test/audio
# readouts for the grid of opponent cars and the per-opponent reveal card — are
# deleted along with the rival field and the reveal itself
# (todo/roguelike-pivot.md decision 5). engine_audio.gd no longer reads
# reveal_focus_car(); see its attenuation code for the replacement note.


func _exit_tree() -> void:
	if active_instance == self:
		active_instance = null
