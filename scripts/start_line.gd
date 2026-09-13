class_name StartLine
extends Node3D
# Docs: features/start-line.md — update in the same change as this file.
# Tests: tests/headless/test_stage_manager.gd, tests/headless/test_start_line.gd — extend in the same change.
# The pre-event start-line sequence (todo/menus.md location 2) — the cinematic
# moment between picking a car in HQ and the 3·2·1·GO countdown. It runs inside the
# live run scene (main.tscn) once the world is built and a RunSession stage is
# active (features/rally-challenge.md), while the car is held locked by the
# StageManager's STAGING phase:
#
#   1. MENU     — black house-style panels offer Start / Tune Car under a
#      rally/event header, while an orbit camera idles on the player's car. The rival
#      ghost is parked ON THE GRID, one gap down the lead-in ahead of the player.
#      The orbit runs until Start is pressed — nothing auto-advances.
#   2. FLY_IN   — on Start, the camera flies from the (now frozen) orbit pose to a
#      fixed low 3/4 shot in front of the rival on the grid. The menu row stays
#      live so Start remains reachable for the send-off.
#   3. REVEAL   — arrived at the rival, the rival card appears: the driver's name,
#      the car they wear, and the gold time to beat. Start (button only) sends the
#      rival off.
#   4. DEPART   — the rival drives off down the lead-in under its own power, and the
#      player rolls up onto the line behind it (the restored grid shuffle — see
#      _roll_player_up). Only once it is properly away (start_lead_in_ahead_m past
#      the line) does the fade begin — the player never sees the countdown before
#      the rival has left.
#   5. FADE     — the screen fades to black; at full black the camera hands back
#      to the player's SELECTED camera (via the CameraManager), the driving UI returns
#      and StageManager.begin_countdown() starts the countdown; then it fades back in.
#
# Created and wired by world.gd (session runs only). A plain dev boot of main.tscn
# never builds a StartLine and the StageManager goes straight to the countdown.
#
# THE RIVAL REVEAL — the per-opponent FLY_IN + REVEAL the pivot deleted with the
# rival field it dramatized (todo/roguelike-pivot.md decision 5) — the three real
# top-three rivals queued behind the line, walked through one Next press at a time —
# is REVIVED here in the pivot's own terms: ONE rival, the ghost, parked on the grid
# ahead of the player, ONE fly on Start, the card arriving when the camera does,
# and — as before — the rival actually DRIVES OFF (DEPART) before the countdown
# runs, rather than waiting frozen for the run to pose it.
#
# THE RIVAL GHOST (features/rival-ghost.md) is that one rival: `world.gd` hands
# `setup()` a `RivalGhost` it owns (outliving this node — the ghost keeps posing
# through RUNNING for the live HUD delta). This node parks it ON the grid
# (`RivalGhost.pose_at_distance`) for MENU/FLY_IN/REVEAL, then drives it off in
# DEPART — and for THAT phase alone it is a real, simulated car (full physics, real
# suspension load, real dirt and tyre marks: `RivalGhost.begin_live_departure`) rather
# than a posed one. At the end of the departure
# it is hidden and gated (`mark_departed_at`) until the run's own clock catches up
# to where the drive-off left it — so it never pops back onto the line, and
# world.gd/StageManager take over (`RivalGhost.pose_at`, off `StageManager.elapsed()`)
# seamlessly once it re-enters.
#
# THE RIVAL CARD — the deleted per-opponent reveal card (driver, car, gold time),
# trimmed to the ONE rival the pivot kept and revealed when the fly lands (not for
# the whole MENU any more): the ghost wears a real CarLibrary car whose benchmark
# pace matches the target (RivalGhost.pick_rival), so the card can honestly name WHO
# you're racing, WHAT they drive, and the exact time to beat. Hidden entirely when
# there is no ghost.

## Car scene path lives in Scenes.CAR (scripts/scenes.gd); loaded via Scenes.car_scene()
## below since preload() cannot take that reference (needs a literal string).

# Sequence phases. MENU orbits the player until Start is pressed; Start flies to
# the rival's reveal, and a second press sends the rival off — the countdown only
# begins once it has driven away; the rest are time-driven in _process.
enum Seq { MENU, FLY_IN, REVEAL, DEPART, FADE_OUT, FADE_IN, DONE }

var _seq: int = Seq.MENU
var _seq_t := 0.0          # seconds into the current timed phase
var _orbit_angle := 0.0    # accumulated orbit camera angle (rad), the MENU idle
var _launched := false     # Start pressed (past the eligibility gates)

# The rival's drive-off (DEPART): the track distance it has reached (it starts ON
# the line, s=0), advancing at the profile's own speed, and the distance at which
# it's far enough down the lead-in for the fade to take over (start_lead_in_ahead_m).
var _depart_s := 0.0
var _depart_target := 0.0

# The reveal fly: the orbit pose it departs from (transform + fov), and the shot it
# lands on — a low 3/4 in front of the rival on its grid slot (_compute_anchor).
var _fly_from := Transform3D.IDENTITY
var _fly_from_fov := 70.0
var _anchor_xform := Transform3D.IDENTITY

# Refs handed in by world.gd (camera/HUD optional so tests can omit them).
var _player: Node3D
var _terrain: Node
var _stage_manager: Node
var _camera_manager: CameraManager
var _hud: CanvasLayer
var _mobile: CanvasLayer
# The rival ghost (features/rival-ghost.md), owned by world.gd and handed in so it
# can keep posing after this node's own sequence is DONE. Null for a plain dev boot
# or a degenerate track (RivalGhost.has_profile() false) — either way the reveal
# below is skipped and the MENU simply never auto-flies.
var _ghost: RivalGhost

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
var _subtitle_label: Label
var _fade: CanvasLayer
var _fade_rect: ColorRect

# The rival card (MENU only): who you're racing, what they drive, the time to beat.
# Filled by _refresh_rival_card() from the wired ghost; hidden with no ghost.
var _rival_card: PanelContainer = null
var _rival_name_label: Label
var _rival_car_label: Label
var _rival_time_label: Label

# This event's index (0-based), for the header's "Stage X of N".
var _event_index := 0

# The player's start pose, captured at setup. The player is staged one grid gap
# BEHIND this (see setup — the rival owns the line), axis-locked so it can't drift
# during the MENU orbit, and snapped UP ONTO the line by reset_to at hand-off.
var _start_xform: Transform3D
var _stage_xform: Transform3D  # the staged (one-gap-back) pose the MENU orbits
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
# car is on the line". A challenge run fields RunSession's locked car
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
	if RunSession.is_active():
		return RunSession.stage_count()
	return 1


# Build the start-line sequence around the fielded car. `terrain` (optional) sits
# the player on the ground; `camera_manager` / `hud` / `mobile` are handed back at
# the fade (the camera via the manager, so the player's chosen mode — not always
# chase — resumes).
func setup(player: Node3D, terrain: Node, stage_manager: Node, rally: Dictionary,
		event_index: int, camera_manager: CameraManager = null,
		hud: CanvasLayer = null, mobile: CanvasLayer = null,
		pause_menu: PauseMenu = null, ghost: RivalGhost = null) -> void:
	active_instance = self
	_pause_menu = pause_menu
	_player = player
	_terrain = terrain
	_ghost = ghost
	if is_instance_valid(_ghost) and _ghost.has_profile():
		# The rival sits ON THE LINE — the pre-pivot grid's front slot — posed BY THE
		# TRACK (pose_at_distance walks the centerline sample), so it sits on the road
		# whatever the geometry does, dead in the player's wheel tracks. It holds
		# there, scripted-solid, through MENU/FLY_IN/REVEAL — nothing re-poses it
		# until DEPART drives it off. The PLAYER stages one queue gap BEHIND it (see
		# _stage_xform), the pre-pivot grid order: rival on the line, player queued.
		_ghost.pose_at_distance(0.0)
	_stage_manager = stage_manager
	_camera_manager = camera_manager
	_hud = hud
	_mobile = mobile
	_event_index = event_index
	_start_xform = player.global_transform
	# Seat the start-line pose a small clearance ABOVE the road at spawn so the car
	# settles onto its wheels instead of spawning clipped into the ground. The
	# countdown pose is reset_to it at the hand-off, so the player is clear during
	# the countdown.
	if terrain != null and terrain.has_method("height_at"):
		_start_xform.origin.y = terrain.height_at(_start_xform.origin.x, _start_xform.origin.z) + _cfg().start_spawn_clearance
	# The staged pose — one grid gap BEHIND the line, behind the parked rival, the
	# pre-pivot grid order. The hand-off (under the fade) snaps the player up onto
	# the line itself via reset_to(_start_xform).
	_stage_xform = _start_xform.translated_local(Vector3(0.0, 0.0, _cfg().start_queue_gap))
	if terrain != null and terrain.has_method("height_at"):
		_stage_xform.origin.y = terrain.height_at(_stage_xform.origin.x, _stage_xform.origin.z) + _cfg().start_spawn_clearance
	# Hide the driving UI; the menu is camera-only until the fade hands it back.
	if _hud != null:
		_hud.visible = false
	if _mobile != null:
		_mobile.visible = false
	_build_orbit_camera()
	_build_overlay(rally, event_index)
	_build_fade()
	_stage_player()
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
#
# Takes no arguments: it used to accept the `terrain` its caller has and never read it
# (the staged pose comes from `_stage_xform`, which setup() already solved against the
# ground), and an unused parameter is a GDScript warning the test runner treats as a
# failure.
func _stage_player() -> void:
	if not (_player is VehicleBody3D) or not ("ai_controlled" in _player):
		return
	# reset_to (pending teleport) so the staged pose survives the physics server; a bare
	# global_transform write on a VehicleBody3D is discarded (see car.gd reset_to). The
	# test stub has no reset_to, so fall back to the bare write there.
	if _player.has_method("reset_to"):
		_player.reset_to(_stage_xform)
	else:
		_player.global_transform = _stage_xform
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


# Place the orbit camera on its idle circle around the car (the MENU phase only). The
# ghost is deliberately NOT driven here — it parks on its grid slot for the whole
# sequence (see setup); only the run's own clock moves it.
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

	# --- Rival card: the target clock, worn by a real car --------------------
	# The deleted per-opponent reveal card's shape (name / car / gold stat row),
	# trimmed to the single surviving rival — the target-clock ghost. Sits under
	# the stage header so the orbit shot keeps its clear band below.
	_rival_card = UITheme.panel(UITheme.PANEL.a)
	_rival_card.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	root.add_child(_rival_card)

	var rival_box := VBoxContainer.new()
	rival_box.add_theme_constant_override("separation", UITheme.GAP_TIGHT)
	rival_box.custom_minimum_size = Vector2(UITheme.px(300), 0)  # width for the stat row to lay caption|value
	_rival_card.add_child(rival_box)

	_rival_name_label = UITheme.label("", "ink")
	_rival_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rival_box.add_child(_rival_name_label)

	_rival_car_label = UITheme.label("", "dim")
	_rival_car_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rival_box.add_child(_rival_car_label)

	var time_row := _stat_row("Time to beat", "gold")
	_rival_time_label = time_row["value"]
	rival_box.add_child(time_row["row"])

	_refresh_rival_card()
	# The CARD itself is the REVEAL phase's to show: hidden through MENU and the fly,
	# visible only once the camera has arrived at the rival (_enter_reveal). The
	# content above is filled now and re-filled on entry.
	_rival_card.visible = false

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


# A labelled stat row for the rival card: a left-aligned caption (dim) and a
# right-aligned value tinted by `role`. Returns { row, value } so the card can point
# a label at the value. Revived verbatim from the deleted per-opponent reveal card.
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


# Fill the rival card from the wired ghost: the driver's name, the car they wear
# (RivalGhost.pick_rival's real CarLibrary entry), and the gold time to beat — the
# profile's own total, i.e. exactly the clock the HUD delta races. Empty lines are
# hidden rather than left blank. With no ghost or no target (challenge stages,
# degenerate tracks, plain dev boots) there is nothing to fill and the card never
# shows — the reveal itself is skipped and the old header + clear-band MENU shape
# is what the player sees. The CARD's overall visibility belongs to the phase
# (built hidden, shown by _enter_reveal); this only fills the content.
func _refresh_rival_card() -> void:
	if _rival_card == null:
		return
	var should_show: bool = is_instance_valid(_ghost) and _ghost.has_profile() and _ghost.target_ms() > 0
	if not should_show:
		return
	_rival_name_label.text = _ghost.rival_name()
	_rival_name_label.visible = _rival_name_label.text != ""
	_rival_car_label.text = _rival_car_name_text()
	_rival_car_label.visible = _rival_car_label.text != ""
	_rival_time_label.text = UITheme.format_time(_ghost.target_ms(), "—")
	# This refresh can run after the page's own UITheme.enforce pass (the profile
	# is wired before build today, but nothing guarantees that forever), so
	# re-uppercase the freshly-set text the way the deleted per-opponent reveal
	# card did — enforce is idempotent and cheap, per its doc.
	if _overlay != null:
		UITheme.enforce(_overlay)


# The rival's car line: the car's display name, or — when the ghost wears the neutral
# baseline (no pickable car) — nothing at all rather than a bogus model name.
func _rival_car_name_text() -> String:
	if not is_instance_valid(_ghost) or _ghost.rival_car_index() < 0:
		return ""
	return _ghost.rival_car_name()


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
			# The orbit is the whole MENU: it idles on the player's car until Start is
			# pressed (launch flies to the rival). Nothing auto-advances here — the
			# reveal is a reward for pressing Start, not an intro that plays itself.
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
			pass  # holds on the rival shot; Start (launch) sends the rival off
		Seq.DEPART:
			# The rival drives off down the lead-in at its profile pace, and the
			# player rolls up onto the line behind it — the restored grid shuffle:
			# what the player watches happen is the pose control resumes from, so
			# the handoff never has to teleport the car (see _release_player).
			# Only once the rival is properly away does the fade begin — the player
			# never sees the countdown until the rival has left.
			_seq_t += delta
			_roll_player_up()
			if is_instance_valid(_ghost):
				# The rival is a REAL, simulated car for this one phase (see
				# _begin_departure): it launches under its own power, so the distance
				# comes back MEASURED off the body rather than integrated off the pace
				# profile. Everything downstream of here is unchanged.
				_depart_s = _ghost.drive_departure(delta)
			# A simulated launch can go wrong in ways a posed one could not — a spin, a
			# barrier, a stall — so the phase is also bounded by a timeout. Without it a
			# rival that never reaches the lead-in mark would strand the player on the
			# start line with no countdown and no way out.
			var away := _depart_s >= _depart_target
			var timed_out := _seq_t >= _cfg().start_depart_timeout_seconds
			if away or timed_out or not is_instance_valid(_ghost):
				if is_instance_valid(_ghost):
					# Hidden under the coming fade, and gated off until the run's own
					# clock reaches this far (see RivalGhost.mark_departed_at).
					_ghost.mark_departed_at(_depart_s)
				_begin_fade()
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


# --- Rival reveal (the deleted per-opponent sequence's phases, one rival wide) --

# A profiled ghost is revealable at all — there is card content to show.
func _rival_ready() -> bool:
	return is_instance_valid(_ghost) and _ghost.has_profile()

# ...and has a body worth flying the camera to. The neutral-baseline ghost (no
# pickable roster car) reveals the time without the fly: nothing to frame.
func _rival_car_ready() -> bool:
	return _rival_ready() and is_instance_valid(_ghost.car())

# Capture the orbit pose and fly to the rival's reveal shot.
func _begin_reveal_fly() -> void:
	_fly_from = _orbit_cam.global_transform
	_fly_from_fov = _orbit_cam.fov
	_anchor_xform = _compute_anchor()
	_seq = Seq.FLY_IN
	_seq_t = 0.0

# Arrive at the rival: the card appears (only now — "what time do I need?" lands
# with the car it belongs to, exactly as the deleted per-opponent reveal staged it).
func _enter_reveal() -> void:
	_seq = Seq.REVEAL
	_seq_t = 0.0
	_refresh_rival_card()  # fresh content in case the ghost was rewired post-build
	if _rival_ready() and _rival_card != null:
		_rival_card.visible = true

# The reveal shot: a low 3/4 in FRONT of the rival on its grid slot — the deleted
# per-opponent anchor re-framed on the one ghost. The eye sits front-right-up of
# the rival (its own heading), looking back at it just above wheel height.
func _compute_anchor() -> Transform3D:
	var cfg := _cfg()
	var rival := _ghost.car().global_transform
	var eye := rival * Vector3(cfg.start_reveal_cam_side_m, cfg.start_reveal_cam_height_m,
		-cfg.start_reveal_cam_front_m)
	var look := rival.origin + Vector3.UP * cfg.start_reveal_cam_look_height_m
	return Transform3D(Basis(), eye).looking_at(look, Vector3.UP)

# Begin the launch: run the eligibility gates, then fly the camera to the rival's
# reveal shot (or, with no rival to reveal, straight to the fade). Idempotent —
# only fires from the waiting MENU or REVEAL phase, so a second press during the
# fly/departure is ignored. From REVEAL the press sends the rival off (DEPART):
# the countdown waits until it has driven away.
func launch() -> void:
	if not (_seq == Seq.MENU or _seq == Seq.REVEAL):
		return
	if _seq == Seq.REVEAL:
		# The commitment press already happened (MENU); this one sends the rival off.
		_begin_departure()
		return
	if _seq == Seq.REVEAL:
		_begin_departure()
		return
	_launched = true
	if _rival_car_ready():
		# Start means go: fly the camera from the (now frozen) orbit pose to the
		# rival's reveal shot. The overlay stays up through FLY_IN/REVEAL so Start
		# remains reachable for the send-off press; _begin_departure hides it.
		_begin_reveal_fly()
	elif _rival_ready():
		_enter_reveal()
	else:
		# No rival to reveal — the player is already on the line. Straight to the fade.
		if _overlay != null:
			_overlay.visible = false
		_begin_fade()


# Send the rival off the line (DEPART): it drives off down the lead-in at its
# profile pace while the camera holds on the player, and the fade (then the
# countdown) only begins once it is properly away. The overlay goes now — the
# player has committed; the remaining beats are cinematic.
func _begin_departure() -> void:
	_launched = true
	if _overlay != null:
		_overlay.visible = false
	if _rival_card != null:
		_rival_card.visible = false
	_depart_s = 0.0
	_depart_target = _cfg().start_lead_in_ahead_m
	# The rival stops being a posed ghost here and becomes a real car for the length of
	# the send-off — the camera is parked on it from a low 3/4 and the launch IS the
	# shot, so the suspension squat, the dirt off the driven wheels and the ruts it
	# leaves all have to be the real thing (features/rival-ghost.md). It goes back to
	# posed at mark_departed_at, before the run's HUD delta ever reads it.
	if is_instance_valid(_ghost):
		_ghost.begin_live_departure(_depart_s)
	_seq = Seq.DEPART
	_seq_t = 0.0


# The restored DEPART shuffle (pre-pivot _roll_grid_to_slots rolled every remaining
# grid car one slot forward per frame; the one-rival revival only ever has the player
# to roll). Target is the line itself, grounded like every other grid pose was.
func _roll_player_up() -> void:
	if not _player_staged:
		return
	_roll_car_to(_player, _ground(_start_xform.origin))


# Roll a scripted car UP TO `target` and brake to a stop ON it, instead of flooring it
# and coasting past — ported verbatim from the pre-pivot grid. Drives forward while
# well behind, coasts into a speed-aware brake point, then brakes+holds — easing to a
# halt at the target. The staging's lateral/yaw axis locks keep it on rails; forward
# (local -Z) stays free, which is exactly the one DOF a shuffle wants.
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


# Drop a world point onto the terrain, keeping the player's ride height above it —
# ported from the pre-pivot grid so the roll-up's target sits on the actual road.
func _ground(pos: Vector3) -> Vector3:
	if _terrain != null and is_instance_valid(_terrain) and _terrain.has_method("height_at"):
		var ride: float = _start_xform.origin.y - _terrain.height_at(
			_start_xform.origin.x, _start_xform.origin.z)
		pos.y = _terrain.height_at(pos.x, pos.z) + ride
	return pos


func _begin_fade() -> void:
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


# Undo the staging scripting so the run drives normally, and square the player up
# exactly onto the start line (hidden by the fade). The DEPART roll-up has already
# brought the car here, so this is a last-inches correction of any residual creep or
# brake-dive — NOT the move itself; before the roll-up was restored this reset was a
# full queue-gap teleport the fade had to hide. The StageManager forces the handbrake
# through the countdown, so the car holds at the line until GO.
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
	else:
		# Same fallback _stage_player uses: a body without reset_to (a test stub, or
		# any non-physics stand-in) takes the bare transform write, which sticks
		# wherever the physics server is not authoritative over it.
		_player.global_transform = _start_xform
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
	# Reachable from REVEAL too: the time to beat on the card is what the player is
	# tuning against, so the panel must open while it's up.
	if _seq != Seq.MENU and _seq != Seq.REVEAL:
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


# --- Rival card readouts (for tests) -----------------------------------------

func rival_card_visible() -> bool:
	return _rival_card != null and _rival_card.visible


func rival_card_name() -> String:
	return _rival_name_label.text if _rival_name_label != null else ""


func rival_card_car() -> String:
	return _rival_car_label.text if _rival_car_label != null else ""


func rival_card_time() -> String:
	return _rival_time_label.text if _rival_time_label != null else ""


# queue_count(), queue_car_ids(), reveal_index() and reveal_focus_car() — test/audio
# readouts for the grid of opponent cars and the per-opponent reveal card — are
# deleted along with the rival field and the reveal itself
# (todo/roguelike-pivot.md decision 5). engine_audio.gd no longer reads
# reveal_focus_car(); see its attenuation code for the replacement note.


func _exit_tree() -> void:
	if active_instance == self:
		active_instance = null
