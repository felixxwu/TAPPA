extends GutTest
# StageManager: the dev stage's COUNTDOWN -> RUNNING -> COMPLETE flow. Driven by calling
# _process(dt) directly against stub car/progress, so the state machine and timing are
# tested without driving the whole track (the completion edge uses a fake progress source).

const SceneHelpers = preload("res://tests/headless/scene_helpers.gd")


# Records the control-lock toggles StageManager does to the car: the full lock
# (COMPLETE) and the handbrake-only lock (COUNTDOWN, so the player can
# rev up and launch on GO).
class StubCar:
	extends Node3D
	var controls_locked := false
	var handbrake_locked := false
	var finish_stop := false


# Stand-in for TrackProgress: progress_percent() returns a settable 0..1 fraction.
class StubProgress:
	extends Node
	var pct := 0.0
	func progress_percent() -> float:
		return pct


var _car: StubCar
var _progress: StubProgress
var _boot_scene: Node3D


# Build the real main.tscn ONCE here (not in a test body) for the boot integration check
# below. minimal_world keeps the track/foliage cheap.
func before_all() -> void:
	SceneHelpers.minimal_world()
	_boot_scene = load("res://main.tscn").instantiate()
	add_child(_boot_scene)


func after_all() -> void:
	_boot_scene.free()
	Config.reset()


func before_each() -> void:
	Config.reset()
	_car = StubCar.new()
	add_child_autofree(_car)
	_progress = StubProgress.new()
	add_child_autofree(_progress)


func after_each() -> void:
	Config.reset()


func _make() -> StageManager:
	var sm := StageManager.new()
	add_child_autofree(sm)
	sm.set_process(false)  # drive _process manually for deterministic timing
	sm.setup(_car, _progress)
	return sm


func _to_running(sm: StageManager) -> void:
	sm._process(Config.data.stage_countdown_seconds)  # exhaust the countdown


func test_car_handbrake_held_during_countdown() -> void:
	var sm := _make()
	assert_true(_car.handbrake_locked, "handbrake forced from setup")
	assert_false(_car.controls_locked, "input not fully locked during the countdown")
	assert_eq(sm.phase(), StageManager.Phase.COUNTDOWN, "starts in COUNTDOWN")
	sm._process(Config.data.stage_countdown_seconds * 0.5)
	assert_true(_car.handbrake_locked, "handbrake still held mid-countdown")
	assert_false(_car.controls_locked, "still not fully locked mid-countdown")
	assert_eq(sm.phase(), StageManager.Phase.COUNTDOWN, "still COUNTDOWN before the timer elapses")


func test_countdown_unlocks_and_starts_timer() -> void:
	var sm := _make()
	var started := [false]
	sm.stage_started.connect(func() -> void: started[0] = true)
	_to_running(sm)
	assert_eq(sm.phase(), StageManager.Phase.RUNNING, "phase flips to RUNNING at GO")
	assert_false(_car.controls_locked, "controls unlock when the countdown ends")
	assert_false(_car.handbrake_locked, "handbrake releases at GO so the car launches")
	assert_true(started[0], "stage_started fired at GO")


func test_timer_accrues_only_while_running() -> void:
	var sm := _make()
	_to_running(sm)
	assert_almost_eq(sm.elapsed(), 0.0, 0.0001, "no time accrues on the GO frame")
	sm._process(0.5)
	sm._process(0.5)
	assert_almost_eq(sm.elapsed(), 1.0, 0.0001, "elapsed accrues in RUNNING")


func test_completion_freezes_the_timer_and_relocks_the_car() -> void:
	var sm := _make()
	_to_running(sm)
	sm._process(2.0)
	assert_eq(sm.phase(), StageManager.Phase.RUNNING, "running while short of the finish")
	_progress.pct = 1.0
	sm._process(1.0)
	assert_eq(sm.phase(), StageManager.Phase.COMPLETE, "reaching the finish completes the stage")
	assert_almost_eq(sm.elapsed(), 3.0, 0.0001, "timer frozen at the completion time")
	assert_true(_car.controls_locked, "the finished car is re-locked (handbrake skid)")
	assert_true(_car.finish_stop, "the finished car brakes itself to a stop (foot + handbrake)")
	sm._process(5.0)
	assert_almost_eq(sm.elapsed(), 3.0, 0.0001, "no time accrues after completion")


func test_completion_uses_configured_percent() -> void:
	Config.data.stage_complete_percent = 50.0
	var sm := _make()
	_to_running(sm)
	_progress.pct = 0.4
	sm._process(0.1)
	assert_eq(sm.phase(), StageManager.Phase.RUNNING, "below the threshold stays RUNNING")
	_progress.pct = 0.6
	sm._process(0.1)
	assert_eq(sm.phase(), StageManager.Phase.COMPLETE, "crossing the configured percent completes")


# Integration: booting main.tscn wires a StageManager that holds the real car on the line
# from the first frame. The boot is a countdown, so the handbrake is forced while input
# stays live.
func test_main_scene_holds_car_at_boot() -> void:
	var sm := _boot_scene.get_node_or_null("StageManager")
	assert_not_null(sm, "world.gd wires a StageManager into the scene")
	var car: VehicleBody3D = _boot_scene.get_node("Car")
	assert_true(car.handbrake_locked, "car's handbrake is held during the boot countdown")
	# world.gd locks the car for the loading window (controls_locked = true before
	# generation), but a boot must END with input LIVE — StageManager.setup clears the full
	# lock, leaving only the handbrake hold.
	assert_false(car.controls_locked, "boot leaves input live (loading lock is cleared)")
