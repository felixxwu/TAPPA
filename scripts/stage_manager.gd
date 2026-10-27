class_name StageManager
extends Node
# Docs: features/stage.md — update in the same change as this file.
# Tests: tests/headless/test_stage_manager.gd, tests/headless/test_countdown_hold.gd — extend in the same change.
# The dev stage's start/end flow: holds the car on the line through a countdown, times the
# run, and re-locks the car when track progress reaches the finish. It drives the car's
# control lock only; it shows nothing.
#
# Created and wired by world.gd once the car and TrackProgress exist.

enum Phase { COUNTDOWN, RUNNING, COMPLETE }

var _phase: int = Phase.COUNTDOWN
var _countdown_left := 0.0   # seconds remaining in the countdown
var _elapsed := 0.0          # stage time, accrues only while RUNNING

var _car: Node          # a Car (VehicleBody3D) — toggles controls_locked
var _progress: Node     # a TrackProgress — progress_percent() drives the end edge
var _armed := false     # true once setup() has wired the refs and locked the car


signal stage_started   # countdown finished, timer running


func _cfg() -> GameConfig:
	return Config.data


# Wire the manager to the live scene and arm the flow, locking the car from the
# first frame so it can't be driven before GO. Initialisation lives here (not
# _ready) because add_child runs _ready before world.gd hands over these refs.
func setup(car: Node, progress: Node) -> void:
	_car = car
	_progress = progress
	_elapsed = 0.0
	if car != null and "finish_stop" in car:
		car.finish_stop = false
	# Countdown: hold only the handbrake so the player can rev up and launch on GO.
	if _car != null:
		_car.controls_locked = false
		_car.handbrake_locked = true
	_phase = Phase.COUNTDOWN
	_countdown_left = _cfg().stage_countdown_seconds
	_mark_progress_start()  # car is on the line now -> progress reads 0% from here
	_armed = true


# Re-anchor track progress to 0% at the car's current (on-the-line) position, so
# the lead-in behind the start and any roll-up settle don't count. Guarded so the
# stub progress in tests (without the method) is a no-op.
func _mark_progress_start() -> void:
	if _progress != null and _progress.has_method("mark_start"):
		_progress.mark_start()


func _process(delta: float) -> void:
	var __t := Time.get_ticks_usec()
	_timed_process(delta)
	PerfLog.track(&"stage_manager", Time.get_ticks_usec() - __t)


func _timed_process(delta: float) -> void:
	if not _armed:
		return
	match _phase:
		Phase.COUNTDOWN:
			_tick_countdown(delta)
		Phase.RUNNING:
			_tick_running(delta)


func _tick_countdown(delta: float) -> void:
	_countdown_left -= delta
	if _countdown_left > 0.0:
		return
	_phase = Phase.RUNNING
	if _car != null:
		_car.controls_locked = false
		_car.handbrake_locked = false
	stage_started.emit()


func _tick_running(delta: float) -> void:
	_elapsed += delta
	# progress_percent() is a 0..1 fraction (TrackProgress), so scale to the 0..100
	# stage_complete_percent. Monotonic, so this is a one-way edge.
	if _progress != null and _progress.progress_percent() * 100.0 >= _cfg().stage_complete_percent:
		_complete()


# Trip the finish: freeze the timer and re-lock the car so it skids to a stop in the runoff.
func _complete() -> void:
	_phase = Phase.COMPLETE
	if _car != null:
		_car.controls_locked = true
		_car.handbrake_locked = false
		# Brake to a stop (foot brake + handbrake) with the clutch kept engaged so the
		# engine winds down instead of free-revving; the foot brake releases once
		# stopped. See Car.finish_stop.
		if "finish_stop" in _car:
			_car.finish_stop = true


func phase() -> int:
	return _phase


func elapsed() -> float:
	return _elapsed
