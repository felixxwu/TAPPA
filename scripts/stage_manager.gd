class_name StageManager
extends Node
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

# In-stage "vs P1" pace popup (HUD), wired by setup_splits() for a session run that
# has a P1 rival; empty for a plain dev boot (no popup). _turn_progress[i] is the
# progress fraction (0..1) at the end of turn i; _turn_time_frac[i] is the rival's
# cumulative time fraction at that turn (so the rival's time there ≈ p1 total ×
# that). The popup fires every _split_interval turns; _split_cursor counts how many
# turn boundaries the player has crossed so far. See RallyLibrary.derive_turn_splits.
var _turn_progress: Array = []
var _turn_time_frac: Array = []
var _p1_total_ms := 0
var _split_cursor := 0
var _split_interval := 5

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
			"show_stage_complete", "show_stage_delta", "show_cut_flash"]:
		_hud_can[m] = _hud != null and _hud.has_method(m)
	_progress = progress
	_elapsed = 0.0
	_go_flash_left = 0.0
	_penalty_s = 0.0
	_reported_seconds = 0.0
	_results_emitted = false
	# Clear any finish-stop braking from a previous arm (car swap / new event).
	if car != null and "finish_stop" in car:
		car.finish_stop = false
	# Clear any pace-popup splits from a previous arm (a car swap / new event); a
	# session run re-wires them via setup_splits() after this.
	_turn_progress = []
	_turn_time_frac = []
	_p1_total_ms = 0
	_split_cursor = 0
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


# Wire the in-stage "vs P1" pace popup: the per-turn progress thresholds + the
# rival's cumulative time fraction at each turn (both from RallyLibrary.derive_turn_splits,
# converted to fractions by world.gd) and the P1 rival's total event time (ms). Called
# by world.gd only for a session run that has a classified P1 rival. With these wired,
# RUNNING fires hud.show_stage_delta() every stage_delta_interval_turns turns.
func setup_splits(turn_progress: Array, turn_time_frac: Array, p1_total_ms: int) -> void:
	_turn_progress = turn_progress
	_turn_time_frac = turn_time_frac
	_p1_total_ms = p1_total_ms
	_split_cursor = 0
	_split_interval = maxi(1, _cfg().stage_delta_interval_turns)


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
	# Audio hook (todo/audio.md): a countdown beep per tick + a GO sting would
	# fire here once the Audio autoload exists; thin and silent until then.
	stage_started.emit()


func _tick_running(delta: float) -> void:
	_elapsed += delta
	if _hud_can["show_elapsed"]:
		_hud.show_elapsed(_elapsed)
	_maybe_show_split()
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


# Drive the "vs P1" pace popup. Advance past every turn boundary the player has now
# crossed (progress is monotonic, so each is crossed once); when the count reaches a
# whole interval (every Nth turn) fire the popup, showing the latest crossed turn.
# The rival's estimated time AT that turn is its total event time scaled by the par
# time fraction reached there — the same turn-based estimate the targets come from.
func _maybe_show_split() -> void:
	if _turn_progress.is_empty() or _p1_total_ms <= 0:
		return
	var frac := 0.0
	if _progress != null and _progress.has_method("progress_percent"):
		frac = _progress.progress_percent()
	var fire_idx := -1
	while _split_cursor < _turn_progress.size() and frac >= float(_turn_progress[_split_cursor]):
		_split_cursor += 1  # _split_cursor now equals the number of turns passed
		if _split_cursor % _split_interval == 0:
			fire_idx = _split_cursor - 1
	if fire_idx < 0 or not _hud_can["show_stage_delta"]:
		return
	var player_ms := int(round(_elapsed * 1000.0))
	var p1_est_ms := int(round(_p1_total_ms * float(_turn_time_frac[fire_idx])))
	_hud.show_stage_delta(player_ms - p1_est_ms)


# --- Readouts (for tests / a future rally layer) -----------------------------

func phase() -> int:
	return _phase


func elapsed() -> float:
	return _elapsed
