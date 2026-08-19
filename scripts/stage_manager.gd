class_name StageManager
extends Node
# Docs: features/stage.md, features/sfx.md, todo/audio.md — update in the same change as this file. (Audio cues in this file go through the `Audio` autoload — never a hand-rolled AudioStreamGenerator; see the AUDIO HOOK note at the GO transition.)
# Tests: tests/headless/test_hud.gd, tests/headless/test_stage_manager.gd, tests/headless/test_start_line.gd — extend in the same change. These are the PRIMARY ones, not all of them: before you change behaviour here, `grep -rn 'StageManager' tests/headless/` and read the assertions that pin what you are about to change (5 test files touch this script).
# Owns the per-stage start/end flow on top of the always-live world:
#   0. STAGING   — (optional) the car is locked while the pre-event start-line
#      scene (briefing + presence cars, scripts/start_line.gd) holds, until the
#      player launches and StartLine calls begin_countdown(). Skipped unless the
#      manager is set up `staged` (a session run with start_line_enabled); a plain
#      dev boot goes straight to COUNTDOWN exactly as before.
#   1. COUNTDOWN — the handbrake is forced on but driver input stays live (so the
#      player can rev up and launch on GO) while a big centered 3·2·1·GO counts
#      down on the HUD.
#   2. RUNNING   — controls unlock, an elapsed timer runs (small, top-right).
#   3. COMPLETE  — when track progress reaches the finish, the timer freezes,
#      the car re-locks, and a placeholder stage-complete panel shows.
#
# It drives the car's control lock and the HUD, and reads TrackProgress for the
# end condition; it contains no gameplay physics or UI layout. The post-stage
# flow (standings, podium, rewards, back to HQ) is OUT OF SCOPE here — this only
# surfaces the `stage_completed(elapsed_seconds)` signal a future rally/menu
# layer (features/rally-session.md) hangs off. See todo/stage-start-and-end.md.
#
# Created and wired by world.gd once the car, HUD and TrackProgress exist.

enum Phase { STAGING, COUNTDOWN, RUNNING, COMPLETE }

# How long the "GO" stays on screen after controls unlock, before it's hidden.
# A small flash; kept a const (not a config knob) to match the spec's three-knob
# Stage config surface.
const GO_FLASH_SECONDS := 0.5

var _phase: int = Phase.COUNTDOWN
var _countdown_left := 0.0   # seconds remaining in the countdown
var _elapsed := 0.0          # stage time, accrues only while RUNNING
var _go_flash_left := 0.0    # seconds the "GO" flash stays up into RUNNING
var _penalty_s := 0.0        # corner-cut penalty for this event, snapshot at _complete()
var _reported_seconds := 0.0 # _elapsed + _penalty_s, frozen at the finish crossing

var _car: Node          # a Car (VehicleBody3D) — toggles controls_locked
var _hud: Node          # the HUD CanvasLayer — countdown / timer / complete panel
# HUD method availability, resolved once in setup() instead of has_method()-ing
# every frame in the countdown/running tick. Keyed by method name.
var _hud_can: Dictionary = {}
var _progress: Node     # a TrackProgress — progress_percent() drives the end edge
var _armed := false     # true once setup() has wired the refs and locked the car
var _results_emitted := false  # true once proceed_to_results() has fired stage_completed

# The leader's pace table, wired by setup_splits() for a session run that has a P1
# rival; empty for a plain dev boot. _turn_progress[i] is the progress fraction (0..1)
# at the end of turn i; _turn_time_frac[i] is the rival's cumulative time fraction at
# that turn (so the rival's time there ≈ p1 total × that). See
# RallyLibrary.derive_turn_splits, and LiveStandings for what the table is read for.
var _turn_progress: Array = []
var _turn_time_frac: Array = []
var _p1_total_ms := 0
# Every classified rival's event time (ms, ascending), from setup_live_standings() —
# the whole field, which is what turns the leader-relative projection above into a
# POSITION. Empty means no live standings readout (a dev boot, or a field of DNFs).
var _field_times: Array = []

# Rally pacenote strip (features/hud.md), wired by setup_pacenotes() from world.gd on
# every run (no P1 rival needed — pacenotes are just track reading). _pace_fracs[i] is
# the progress fraction (0..1) of turn i's corner entry, ascending. _pace_cursor is the
# number of corners passed = the current-turn index the HUD strip reads from.
var _pace_fracs: Array = []
var _pace_cursor := 0

signal stage_started                            # countdown finished, timer running
signal finish_reached                           # car crossed the finish (phase -> COMPLETE, before the NEXT button)
signal stage_completed(elapsed_seconds: float)  # NEXT pressed on the finish panel; post-stage flow begins


func _cfg() -> GameConfig:
	return Config.data


# Wire the manager to the live scene and arm the flow, locking the car from the
# first frame so it can't be driven before GO. Initialisation lives here (not
# _ready) because add_child runs _ready before world.gd hands over these refs.
#
# `staged` holds the car in STAGING (no countdown yet) so the pre-event start-line
# scene can show its briefing first; StartLine calls begin_countdown() to proceed.
# When false (the default — a plain dev boot, or a car swap) the countdown arms
# immediately, exactly as before the start-line scene existed.
func setup(car: Node, hud: Node, progress: Node, staged := false) -> void:
	_car = car
	_hud = hud
	_hud_can.clear()
	for m in ["show_countdown", "hide_countdown", "show_elapsed",
			"show_stage_complete", "show_position", "hide_position", "show_cut_flash",
			"show_pacenotes", "show_off_road", "hide_off_road"]:
		_hud_can[m] = _hud != null and _hud.has_method(m)
	# Clear any warning left up by the previous arm (a car swap / new event) — the
	# fresh car is on the line, so its off-road clock starts at zero.
	_hide_off_road_warning()
	_progress = progress
	_elapsed = 0.0
	_go_flash_left = 0.0
	_penalty_s = 0.0
	_reported_seconds = 0.0
	_results_emitted = false
	# Clear any finish-stop braking from a previous arm (car swap / new event).
	if car != null and "finish_stop" in car:
		car.finish_stop = false
	# Clear any pace table / field from a previous arm (a car swap / new event); a session
	# run re-wires them via setup_splits() + setup_live_standings() after this.
	_turn_progress = []
	_turn_time_frac = []
	_p1_total_ms = 0
	_field_times = []
	if _hud_can.get("hide_position", false):
		_hud.hide_position()
	# Clear pacenotes from a previous arm; world.gd re-wires them via setup_pacenotes().
	_pace_fracs = []
	_pace_cursor = 0
	if staged:
		# Wait at the start line, fully held; the countdown only arms once StartLine launches.
		if _car != null:
			_car.controls_locked = true
			_car.handbrake_locked = false
		_phase = Phase.STAGING
		_countdown_left = _cfg().stage_countdown_seconds
	else:
		# Countdown: hold only the handbrake so the player can rev up and launch on GO.
		if _car != null:
			_car.controls_locked = false
			_car.handbrake_locked = true
		_phase = Phase.COUNTDOWN
		_countdown_left = _cfg().stage_countdown_seconds
		_mark_progress_start()  # car is on the line now -> progress reads 0% from here
		if _hud_can["show_countdown"]:
			_hud.show_countdown(_countdown_left)
	if _progress != null and _progress.has_signal("cut_billed") \
			and not _progress.cut_billed.is_connected(_on_cut_billed):
		_progress.cut_billed.connect(_on_cut_billed)
	_armed = true


# Leave STAGING and start the 3·2·1·GO countdown. Called by StartLine when the
# player launches the event; the car stays locked through the countdown as usual.
# No-op unless we're actually staging, so a double-launch can't restart the run.
func begin_countdown() -> void:
	if not _armed or _phase != Phase.STAGING:
		return
	# Drop the full hold to a handbrake-only hold so the player can rev and launch on GO.
	if _car != null:
		_car.controls_locked = false
		_car.handbrake_locked = true
	_phase = Phase.COUNTDOWN
	_countdown_left = _cfg().stage_countdown_seconds
	# The start-line sequence has just snapped the car onto the line; anchor 0% here.
	_mark_progress_start()
	if _hud_can["show_countdown"]:
		_hud.show_countdown(_countdown_left)


# Leave STAGING and GO on the very next tick, skipping the 3-2-1. The multiplayer
# lobby uses this: its own countdown ran on the shared wall clock (every client
# counting to the SAME agreed instant), so stacking the standard countdown on top
# would just delay everyone three seconds past the moment they agreed on.
func launch_immediately() -> void:
	if not _armed or _phase != Phase.STAGING:
		return
	begin_countdown()
	_countdown_left = 0.0


# Wire the leader's pace table: the per-turn progress thresholds + the rival's cumulative
# time fraction at each turn (both from RallyLibrary.derive_turn_splits, converted to
# fractions by world.gd) and the P1 rival's total event time (ms). Called by world.gd only
# for a session run that has a classified P1 rival.
func setup_splits(turn_progress: Array, turn_time_frac: Array, p1_total_ms: int) -> void:
	_turn_progress = turn_progress
	_turn_time_frac = turn_time_frac
	_p1_total_ms = p1_total_ms


# Wire the live standings readout with the field the player is racing: every classified
# rival's event time (ms), from RallySession.current_event_field_times_ms(). With this
# AND setup_splits() wired, RUNNING drives hud.show_position() every frame.
#
# Separate from setup_splits because the two answer different questions and arrive at
# different times — the pace table can only be built once the rival pace is solved at GO,
# while the field is known as soon as the event is set up.
func setup_live_standings(field_times_ms: Array) -> void:
	_field_times = field_times_ms


# Wire the HUD pacenote strip: the per-corner progress fractions (0..1) of each turn
# entry, ascending (from Pacenotes.build + Pacenotes.notes_to_fracs in world.gd). Unlike
# the pace popup this needs no P1 rival — it's called on every run so the strip shows
# from the start line. Seeds the strip at the first turn; RUNNING advances it.
func setup_pacenotes(fracs: Array) -> void:
	_pace_fracs = fracs
	_pace_cursor = 0
	if _hud_can["show_pacenotes"]:
		_hud.show_pacenotes(0)


# Re-anchor track progress to 0% at the car's current (on-the-line) position, so
# the lead-in behind the start and any roll-up settle don't count. Guarded so the
# stub progress in tests (without the method) is a no-op.
func _mark_progress_start() -> void:
	if _progress != null and _progress.has_method("mark_start"):
		_progress.mark_start()


# Relay a billed corner-cut incident to the HUD as a live flash, but only while
# the stage is actually RUNNING — post-finish coast or a pre-GO countdown cut
# (if that's ever possible) shouldn't pop a flash the player can't act on.
func _on_cut_billed(incident_s: float, total_s: float) -> void:
	if _phase != Phase.RUNNING:
		return
	if _hud_can["show_cut_flash"]:
		_hud.show_cut_flash(incident_s, total_s)


# Mirror TrackProgress's off-road clock onto the HUD: an OFF TRACK warning with the
# seconds left before the car is snapped back (features/progress.md). Held back by
# off_road_warning_after_s so the everyday rally excursions — running wide, landing a
# jump on the verge, a tail-out slide — pass without flashing a warning every corner;
# by the time it appears the player really is off the road and needs to know a reset
# is coming. Polled rather than signal-driven because it's a continuously-changing
# readout, not an event. Only while RUNNING: TrackProgress keeps its own clock in every
# phase (the reset still fires post-finish), but a warning the player can't act on
# during a countdown or under the finish panel is just noise.
func _update_off_road_warning() -> void:
	if _progress == null or not _progress.has_method("off_road_time"):
		return
	var elapsed_off: float = _progress.off_road_time()
	if elapsed_off < _cfg().off_road_warning_after_s or elapsed_off <= 0.0:
		_hide_off_road_warning()
		return
	if _hud_can["show_off_road"]:
		_hud.show_off_road(_progress.off_road_seconds_left())


func _hide_off_road_warning() -> void:
	if _hud_can.get("hide_off_road", false):
		_hud.hide_off_road()


func _process(delta: float) -> void:
	var __t := Time.get_ticks_usec()
	_timed_process(delta)
	PerfLog.track(&"stage_manager", Time.get_ticks_usec() - __t)


func _timed_process(delta: float) -> void:
	if not _armed:
		return
	match _phase:
		Phase.STAGING:
			pass  # held at the start line until StartLine calls begin_countdown()
		Phase.COUNTDOWN:
			_tick_countdown(delta)
		Phase.RUNNING:
			_tick_running(delta)
		Phase.COMPLETE:
			pass


func _tick_countdown(delta: float) -> void:
	_countdown_left -= delta
	if _countdown_left > 0.0:
		if _hud_can["show_countdown"]:
			_hud.show_countdown(_countdown_left)
		return
	# Countdown done: unlock, start the timer, flash "GO" briefly.
	_phase = Phase.RUNNING
	if _car != null:
		_car.controls_locked = false
		_car.handbrake_locked = false
	if _hud_can["show_countdown"]:
		_hud.show_countdown(0.0)  # "GO"
	_go_flash_left = GO_FLASH_SECONDS
	# AUDIO HOOK — the countdown beep / GO sting belongs here (and per integer tick
	# in the countdown branch above). DO NOT hand-roll an AudioStreamGenerator,
	# AudioStreamPlayer or PCM loop in this file: call the `Audio` autoload —
	# `Audio.play_beep()` for a tick, `Audio.play_beep(<higher hz>)` for GO. It owns
	# the SFX bus, the headless guard and the play()/get_stream_playback() order.
	# See scripts/audio.gd + features/sfx.md; the planned cue set is in todo/audio.md.
	stage_started.emit()


func _tick_running(delta: float) -> void:
	_elapsed += delta
	if _hud_can["show_elapsed"]:
		_hud.show_elapsed(_elapsed)
	_update_live_standings()
	_maybe_advance_pacenotes()
	_update_off_road_warning()
	# Hold the "GO" flash a moment, then clear it.
	if _go_flash_left > 0.0:
		_go_flash_left -= delta
		if _go_flash_left <= 0.0 and _hud_can["hide_countdown"]:
			_hud.hide_countdown()
	# End condition: progress_percent() is a 0..1 fraction (TrackProgress), so
	# scale to the 0..100 stage_complete_percent. Monotonic, so this is a one-way
	# edge — once tripped the phase never leaves COMPLETE.
	if _progress != null and _progress.progress_percent() * 100.0 >= _cfg().stage_complete_percent:
		_complete()


# Trip the finish: freeze the timer, re-lock the car and show the finish panel.
# Reached either by crossing the finish (the gate above) or by the dev skip-to-finish
# cheat (force_complete). stage_completed is DEFERRED to proceed_to_results() (the
# panel's NEXT button), so the leaderboard/podium flow only starts once the player
# dismisses the time — the car skids to a stop in the runoff behind the overlay.
func _complete() -> void:
	_phase = Phase.COMPLETE
	# The run is over; a lingering OFF TRACK warning would sit under the finish panel
	# with nothing the player can do about it. (TrackProgress keeps its clock running,
	# so a car that crossed the line off-road is still recovered — just silently.)
	_hide_off_road_warning()
	# The projection is over too: the finish panel is showing the real time, and a live
	# "position" derived from a frozen clock would just sit there being wrong.
	if _hud_can.get("hide_position", false):
		_hud.hide_position()
	# Re-lock so the finished car skids to a stop under the panel (controls_locked
	# forces the handbrake on) instead of driving on. It stays visible behind the
	# overlay; the runoff road (features/track.md) gives it room to stop.
	if _car != null:
		_car.controls_locked = true
		_car.handbrake_locked = false
		# Brake to a stop (foot brake + handbrake) with the clutch kept engaged so the
		# engine winds down instead of free-revving; the foot brake releases once
		# stopped. See Car.finish_stop.
		if "finish_stop" in _car:
			_car.finish_stop = true
	if _progress != null and _progress.has_method("cut_penalty_s"):
		_penalty_s = _progress.cut_penalty_s()
	_reported_seconds = _elapsed + _penalty_s
	if _hud_can["show_stage_complete"]:
		_hud.show_stage_complete(_elapsed, _penalty_s)
	# The timed run is over the instant the line is crossed; anything after this
	# (the skid to a stop in the runoff, idling under the finish panel until NEXT)
	# is NOT part of the driven run. Fire finish_reached so the replay recorder
	# stops here rather than at stage_completed (the NEXT button), which would tack
	# a stationary tail onto the recording. See features/event-replay.md.
	finish_reached.emit()


# Advance from the finish panel into the post-stage flow (standings → podium): emit
# stage_completed, which the session layer (world.gd) hangs the results flow off.
# Fired by the HUD finish panel's NEXT button. Guarded so it only fires while
# COMPLETE and only once, so a double-press can't re-enter the flow.
func proceed_to_results() -> void:
	if _phase != Phase.COMPLETE or _results_emitted:
		return
	_results_emitted = true
	stage_completed.emit(_reported_seconds)


# Dev cheat: complete the event immediately, no matter the current phase (unless
# already finished). Runs the same completion path as crossing the finish line,
# so the rally/reward/progression flow fires exactly as it would on a real run.
func force_complete() -> void:
	if not _armed or _phase == Phase.COMPLETE:
		return
	_complete()


# Drive the permanent standings readout: project the player's finishing time from their
# live gap to the leader (LiveStandings.project_total_ms, which reads the pace table), slot
# that projection into the rival field, and hand the HUD the position and the gap that
# matters. Polled every frame rather than pulsed at turn boundaries — it is a live state
# readout like the run timer, and the HUD change-gates its own string building.
#
# Needs BOTH wirings: the pace table (no projection without it) and the field (no position
# without it). Silently does nothing otherwise, which is the dev-boot case.
func _update_live_standings() -> void:
	if _field_times.is_empty() or _turn_progress.is_empty() or _p1_total_ms <= 0:
		return
	if not _hud_can["show_position"]:
		return
	var frac := 0.0
	if _progress != null and _progress.has_method("progress_percent"):
		frac = _progress.progress_percent()
	var projected := LiveStandings.project_total_ms(int(round(_elapsed * 1000.0)), frac,
			_turn_progress, _turn_time_frac, _p1_total_ms)
	var st := LiveStandings.standing(projected, _field_times)
	_hud.show_position(int(st["position"]), int(st["field"]), int(st["gap_ms"]),
			bool(st["leading"]))


# Advance the pacenote strip: count how many corner entries the car's progress has now
# passed (monotonic, so each is crossed once) and, when that count changes, tell the
# HUD the new current-turn index so the strip slides left. The current turn is the
# first not-yet-passed corner.
func _maybe_advance_pacenotes() -> void:
	if _pace_fracs.is_empty() or not _hud_can["show_pacenotes"]:
		return
	var frac := 0.0
	if _progress != null and _progress.has_method("progress_percent"):
		frac = _progress.progress_percent()
	var cursor := _pace_cursor
	while cursor < _pace_fracs.size() and frac >= float(_pace_fracs[cursor]):
		cursor += 1
	if cursor != _pace_cursor:
		_pace_cursor = cursor
		_hud.show_pacenotes(_pace_cursor)


# --- Readouts (for tests / a future rally layer) -----------------------------

func phase() -> int:
	return _phase


func elapsed() -> float:
	return _elapsed
