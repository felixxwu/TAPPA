extends GutTest
# StageManager: the per-stage COUNTDOWN -> RUNNING -> COMPLETE flow. Driven by
# calling _process(dt) directly against stub car/HUD/progress, so the state
# machine and timing are tested without driving the whole track (the completion
# edge uses a fake progress source). See todo/stage-start-and-end.md.

# StageManager is referenced via its global class_name (registered by the class
# cache); preloading it under the same name would shadow the global identifier.
const SceneHelpers = preload("res://tests/headless/scene_helpers.gd")


# Records controls_locked toggles (the only thing StageManager does to the car).
class StubCar:
	extends Node3D
	var controls_locked := false


# Captures the HUD calls so they can be asserted without a real HUD scene.
class StubHud:
	extends Node
	var last_countdown := -999.0
	var hide_countdown_calls := 0
	var elapsed_calls := 0
	var last_elapsed := -1.0
	var complete_time := -1.0
	func show_countdown(seconds_left: float) -> void:
		last_countdown = seconds_left
	func hide_countdown() -> void:
		hide_countdown_calls += 1
	func show_elapsed(seconds: float) -> void:
		elapsed_calls += 1
		last_elapsed = seconds
	func show_stage_complete(seconds: float) -> void:
		complete_time = seconds


# Stand-in for TrackProgress: progress_percent() returns a settable 0..1 fraction.
class StubProgress:
	extends Node
	var pct := 0.0
	func progress_percent() -> float:
		return pct


var _car: StubCar
var _hud: StubHud
var _progress: StubProgress
var _boot_scene: Node3D


# Build the real main.tscn ONCE here (not in a test body) for the boot
# integration check below. Instantiating in before_all means the first compile
# of the world's scripts — including a pre-existing shadowed-global warning in
# track_generator.gd — is attributed to setup, not a test (the same convention
# test_smoke.gd relies on). minimal_world keeps the track/foliage cheap.
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
	_hud = StubHud.new()
	add_child_autofree(_hud)
	_progress = StubProgress.new()
	add_child_autofree(_progress)


func after_each() -> void:
	Config.reset()


func _make() -> StageManager:
	var sm := StageManager.new()
	add_child_autofree(sm)
	sm.set_process(false)  # drive _process manually for deterministic timing
	sm.setup(_car, _hud, _progress)
	return sm


func _to_running(sm: StageManager) -> void:
	sm._process(Config.data.stage_countdown_seconds)  # exhaust the countdown


func test_car_locked_during_countdown() -> void:
	var sm := _make()
	assert_true(_car.controls_locked, "car is locked from setup")
	assert_eq(sm.phase(), StageManager.Phase.COUNTDOWN, "starts in COUNTDOWN")
	sm._process(1.0)  # partial tick (default countdown is 3 s)
	assert_true(_car.controls_locked, "still locked mid-countdown")
	assert_eq(sm.phase(), StageManager.Phase.COUNTDOWN, "still COUNTDOWN before the timer elapses")


func test_countdown_unlocks_and_starts_timer() -> void:
	var sm := _make()
	var started := [false]
	sm.stage_started.connect(func() -> void: started[0] = true)
	_to_running(sm)
	assert_eq(sm.phase(), StageManager.Phase.RUNNING, "phase flips to RUNNING at GO")
	assert_false(_car.controls_locked, "controls unlock when the countdown ends")
	assert_true(started[0], "stage_started fired at GO")
	assert_eq(_hud.last_countdown, 0.0, "HUD shown GO (0.0) at the transition")


func test_timer_accrues_only_while_running() -> void:
	var sm := _make()
	_to_running(sm)
	assert_almost_eq(sm.elapsed(), 0.0, 0.0001, "no time accrues on the GO frame")
	sm._process(0.5)
	sm._process(0.5)
	assert_almost_eq(sm.elapsed(), 1.0, 0.0001, "elapsed accrues in RUNNING")
	assert_almost_eq(_hud.last_elapsed, 1.0, 0.0001, "HUD shows the running time")


func test_go_flash_hides_after_a_moment() -> void:
	var sm := _make()
	_to_running(sm)
	assert_eq(_hud.hide_countdown_calls, 0, "GO still on screen right after the transition")
	sm._process(StageManager.GO_FLASH_SECONDS)  # hold elapses
	assert_eq(_hud.hide_countdown_calls, 1, "GO hidden once the flash time passes")


func test_completion_freezes_timer_relocks_and_signals() -> void:
	var sm := _make()
	_to_running(sm)
	sm._process(2.0)  # elapsed 2.0, progress still 0 -> running
	assert_eq(sm.phase(), StageManager.Phase.RUNNING, "running while short of the finish")
	var completed := [-1.0]
	sm.stage_completed.connect(func(t: float) -> void: completed[0] = t)
	_progress.pct = 1.0  # 100% >= 99% default
	sm._process(1.0)     # elapsed reaches 3.0 on the completing frame
	assert_eq(sm.phase(), StageManager.Phase.COMPLETE, "reaching the finish completes the stage")
	assert_almost_eq(completed[0], 3.0, 0.0001, "stage_completed carries the final time")
	assert_almost_eq(sm.elapsed(), 3.0, 0.0001, "timer frozen at the completion time")
	assert_true(_car.controls_locked, "car re-locked on completion")
	assert_almost_eq(_hud.complete_time, 3.0, 0.0001, "complete panel shows the final time")
	# Further ticks must not advance the frozen timer.
	sm._process(5.0)
	assert_almost_eq(sm.elapsed(), 3.0, 0.0001, "no time accrues after completion")


func test_completion_uses_configured_percent() -> void:
	Config.data.stage_complete_percent = 50.0
	var sm := _make()
	_to_running(sm)
	_progress.pct = 0.4  # 40% < 50% -> not yet
	sm._process(0.1)
	assert_eq(sm.phase(), StageManager.Phase.RUNNING, "below the threshold stays RUNNING")
	_progress.pct = 0.6  # 60% >= 50% -> complete
	sm._process(0.1)
	assert_eq(sm.phase(), StageManager.Phase.COMPLETE, "crossing the configured percent completes")


# Integration: booting main.tscn wires a StageManager that locks the real car
# from the first frame (the scene is built once in before_all).
func test_main_scene_locks_car_at_boot() -> void:
	var sm := _boot_scene.get_node_or_null("StageManager")
	assert_not_null(sm, "world.gd wires a StageManager into the scene")
	var car: VehicleBody3D = _boot_scene.get_node("Car")
	assert_true(car.controls_locked, "car starts locked during the boot countdown")
