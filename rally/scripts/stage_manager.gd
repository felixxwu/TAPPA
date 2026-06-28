class_name StageManager
extends Node
# Owns the per-stage start/end flow on top of the always-live world:
#   0. STAGING   — (optional) the car is locked while the pre-event start-line
#      scene (briefing + presence cars, scripts/start_line.gd) holds, until the
#      player launches and StartLine calls begin_countdown(). Skipped unless the
#      manager is set up `staged` (a session run with start_line_enabled); a plain
#      dev boot goes straight to COUNTDOWN exactly as before.
#   1. COUNTDOWN — the car is locked (handbrake forced) while a big centered
#      3·2·1·GO counts down on the HUD.
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

var _car: Node          # a Car (VehicleBody3D) — toggles controls_locked
var _hud: Node          # the HUD CanvasLayer — countdown / timer / complete panel
var _progress: Node     # a TrackProgress — progress_percent() drives the end edge
var _armed := false     # true once setup() has wired the refs and locked the car

signal stage_started                            # countdown finished, timer running
signal stage_completed(elapsed_seconds: float)  # finish line reached


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
	_progress = progress
	_elapsed = 0.0
	_go_flash_left = 0.0
	if _car != null:
		_car.controls_locked = true
	if staged:
		# Wait at the start line; the countdown only arms once StartLine launches.
		_phase = Phase.STAGING
		_countdown_left = _cfg().stage_countdown_seconds
	else:
		_phase = Phase.COUNTDOWN
		_countdown_left = _cfg().stage_countdown_seconds
		if _hud != null and _hud.has_method("show_countdown"):
			_hud.show_countdown(_countdown_left)
	_armed = true


# Leave STAGING and start the 3·2·1·GO countdown. Called by StartLine when the
# player launches the event; the car stays locked through the countdown as usual.
# No-op unless we're actually staging, so a double-launch can't restart the run.
func begin_countdown() -> void:
	if not _armed or _phase != Phase.STAGING:
		return
	_phase = Phase.COUNTDOWN
	_countdown_left = _cfg().stage_countdown_seconds
	if _hud != null and _hud.has_method("show_countdown"):
		_hud.show_countdown(_countdown_left)


func _process(delta: float) -> void:
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
		if _hud != null and _hud.has_method("show_countdown"):
			_hud.show_countdown(_countdown_left)
		return
	# Countdown done: unlock, start the timer, flash "GO" briefly.
	_phase = Phase.RUNNING
	if _car != null:
		_car.controls_locked = false
	if _hud != null and _hud.has_method("show_countdown"):
		_hud.show_countdown(0.0)  # "GO"
	_go_flash_left = GO_FLASH_SECONDS
	# Audio hook (todo/audio.md): a countdown beep per tick + a GO sting would
	# fire here once the Audio autoload exists; thin and silent until then.
	stage_started.emit()


func _tick_running(delta: float) -> void:
	_elapsed += delta
	if _hud != null and _hud.has_method("show_elapsed"):
		_hud.show_elapsed(_elapsed)
	# Hold the "GO" flash a moment, then clear it.
	if _go_flash_left > 0.0:
		_go_flash_left -= delta
		if _go_flash_left <= 0.0 and _hud != null and _hud.has_method("hide_countdown"):
			_hud.hide_countdown()
	# End condition: progress_percent() is a 0..1 fraction (TrackProgress), so
	# scale to the 0..100 stage_complete_percent. Monotonic, so this is a one-way
	# edge — once tripped the phase never leaves COMPLETE.
	if _progress != null and _progress.progress_percent() * 100.0 >= _cfg().stage_complete_percent:
		_phase = Phase.COMPLETE
		# Re-lock so the finished car doesn't keep driving under the panel.
		if _car != null:
			_car.controls_locked = true
		if _hud != null and _hud.has_method("show_stage_complete"):
			_hud.show_stage_complete(_elapsed)
		stage_completed.emit(_elapsed)


# --- Readouts (for tests / a future rally layer) -----------------------------

func phase() -> int:
	return _phase


func elapsed() -> float:
	return _elapsed
