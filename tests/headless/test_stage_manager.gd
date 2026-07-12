extends GutTest
# StageManager: the per-stage COUNTDOWN -> RUNNING -> COMPLETE flow. Driven by
# calling _process(dt) directly against stub car/HUD/progress, so the state
# machine and timing are tested without driving the whole track (the completion
# edge uses a fake progress source). See todo/stage-start-and-end.md.

# StageManager is referenced via its global class_name (registered by the class
# cache); preloading it under the same name would shadow the global identifier.
const SceneHelpers = preload("res://tests/headless/scene_helpers.gd")


# Records the control-lock toggles StageManager does to the car: the full lock
# (STAGING / COMPLETE) and the handbrake-only lock (COUNTDOWN, so the player can
# rev up and launch on GO).
class StubCar:
	extends Node3D
	var controls_locked := false
	var handbrake_locked := false
	var finish_stop := false


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
	var stage_deltas: Array = []
	func show_stage_delta(delta_ms: int) -> void:
		stage_deltas.append(delta_ms)


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


func test_car_handbrake_held_during_countdown() -> void:
	var sm := _make()
	# The handbrake is forced but input stays live, so the player can rev and launch on GO.
	assert_true(_car.handbrake_locked, "handbrake forced from setup")
	assert_false(_car.controls_locked, "input not fully locked during the countdown")
	assert_eq(sm.phase(), StageManager.Phase.COUNTDOWN, "starts in COUNTDOWN")
	sm._process(1.0)  # partial tick (default countdown is 3 s)
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


func test_completion_freezes_relocks_and_defers_the_signal() -> void:
	var sm := _make()
	_to_running(sm)
	sm._process(2.0)  # elapsed 2.0, progress still 0 -> running
	assert_eq(sm.phase(), StageManager.Phase.RUNNING, "running while short of the finish")
	var completed := [-1.0]
	sm.stage_completed.connect(func(t: float) -> void: completed[0] = t)
	_progress.pct = 1.0  # 100% >= 99% default
	sm._process(1.0)     # elapsed reaches 3.0 on the completing frame
	assert_eq(sm.phase(), StageManager.Phase.COMPLETE, "reaching the finish completes the stage")
	assert_almost_eq(sm.elapsed(), 3.0, 0.0001, "timer frozen at the completion time")
	assert_true(_car.controls_locked, "the finished car is re-locked (handbrake skid)")
	assert_true(_car.finish_stop, "the finished car brakes itself to a stop (foot + handbrake)")
	assert_almost_eq(_hud.complete_time, 3.0, 0.0001, "the finish panel shows the final time")
	assert_eq(completed[0], -1.0, "stage_completed is NOT emitted until the player proceeds")
	# Further ticks must not advance the frozen timer.
	sm._process(5.0)
	assert_almost_eq(sm.elapsed(), 3.0, 0.0001, "no time accrues after completion")
	# Pressing NEXT proceeds to the results flow with the final time.
	sm.proceed_to_results()
	assert_almost_eq(completed[0], 3.0, 0.0001, "proceed_to_results emits stage_completed with the final time")


func test_finish_reached_fires_on_crossing_before_stage_completed() -> void:
	# The replay recorder stops on finish_reached, so it MUST fire the instant the
	# line is crossed (phase -> COMPLETE) — not when NEXT is pressed. Otherwise the
	# post-finish skid + idle gets recorded as a stationary tail on the replay.
	var sm := _make()
	_to_running(sm)
	var finished := [0]
	var completed := [0]
	sm.finish_reached.connect(func() -> void: finished[0] += 1)
	sm.stage_completed.connect(func(_t: float) -> void: completed[0] += 1)
	_progress.pct = 1.0  # cross the finish
	sm._process(0.5)
	assert_eq(sm.phase(), StageManager.Phase.COMPLETE, "crossing the line completes the stage")
	assert_eq(finished[0], 1, "finish_reached fires once on the crossing frame")
	assert_eq(completed[0], 0, "stage_completed is still deferred to the NEXT button")
	# Extra ticks under the finish panel must not re-fire finish_reached.
	sm._process(3.0)
	assert_eq(finished[0], 1, "finish_reached does not re-fire while idling on the panel")
	sm.proceed_to_results()
	assert_eq(completed[0], 1, "NEXT emits stage_completed, distinct from finish_reached")


func test_force_complete_also_fires_finish_reached() -> void:
	# The dev skip-to-finish cheat runs the same _complete() path, so the recorder
	# stop must fire there too.
	var sm := _make()
	_to_running(sm)
	var finished := [0]
	sm.finish_reached.connect(func() -> void: finished[0] += 1)
	sm.force_complete()
	assert_eq(finished[0], 1, "force_complete fires finish_reached via _complete()")


func test_force_complete_shows_panel_and_defers_the_signal() -> void:
	# The dev skip-to-finish cheat: force_complete() runs the same completion path
	# as crossing the line — lock + panel now, results only on NEXT.
	var sm := _make()
	_to_running(sm)
	sm._process(1.5)  # elapsed 1.5, progress still 0 -> nowhere near the finish
	assert_eq(sm.phase(), StageManager.Phase.RUNNING, "still running before the cheat")
	var completed := [-1.0]
	sm.stage_completed.connect(func(t: float) -> void: completed[0] = t)
	sm.force_complete()
	assert_eq(sm.phase(), StageManager.Phase.COMPLETE, "force_complete finishes the stage")
	assert_true(_car.controls_locked, "car re-locked on the forced finish")
	assert_almost_eq(_hud.complete_time, 1.5, 0.0001, "finish panel shown")
	assert_eq(completed[0], -1.0, "stage_completed deferred until NEXT")
	sm.proceed_to_results()
	assert_almost_eq(completed[0], 1.5, 0.0001, "proceed emits the elapsed time so far")


func test_proceed_is_a_noop_before_completion_and_idempotent_after() -> void:
	var sm := _make()
	_to_running(sm)
	var count := [0]
	sm.stage_completed.connect(func(_t: float) -> void: count[0] += 1)
	sm.proceed_to_results()  # not COMPLETE yet
	assert_eq(count[0], 0, "proceed does nothing before the stage completes")
	sm.force_complete()
	sm.proceed_to_results()
	sm.proceed_to_results()  # second press
	assert_eq(count[0], 1, "proceed emits exactly once")


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


# --- In-stage "vs P1" pace popup (every N turns) -----------------------------

# Twelve turns at evenly-spaced progress / time fractions, so the default interval
# of 5 fires at turn 5 (index 4) and turn 10 (index 9). p1 total = 120 s, so the
# rival's estimate at turn t is 120 s × t/12 = t × 10 s.
func _wire_even_splits(sm: StageManager) -> void:
	var prog: Array[float] = []
	var tfrac: Array[float] = []
	for i in 12:
		prog.append(float(i + 1) / 12.0)
		tfrac.append(float(i + 1) / 12.0)
	sm.setup_splits(prog, tfrac, 120000)


func test_no_popup_without_splits() -> void:
	var sm := _make()
	_to_running(sm)
	_progress.pct = 1.0
	sm._process(30.0)
	assert_eq(_hud.stage_deltas.size(), 0, "a plain run (no splits wired) shows no popup")


func test_popup_fires_every_five_turns_with_ahead_delta() -> void:
	var sm := _make()
	_to_running(sm)
	_wire_even_splits(sm)
	# Past turn 5 (frac 5/12) but short of turn 10: one popup, player 30 s vs P1 50 s.
	_progress.pct = 0.5
	sm._process(30.0)
	assert_eq(_hud.stage_deltas.size(), 1, "crossing turn 5 fires one popup")
	assert_eq(int(_hud.stage_deltas[0]), -20000, "ahead by 20 s reads negative (30 s − 50 s)")
	# Past turn 10 (frac 10/12): a second popup, player 60 s vs P1 100 s.
	_progress.pct = 0.9
	sm._process(30.0)
	assert_eq(_hud.stage_deltas.size(), 2, "crossing turn 10 fires the second popup")
	assert_eq(int(_hud.stage_deltas[1]), -40000, "still ahead (60 s − 100 s)")


func test_popup_behind_reads_positive() -> void:
	var sm := _make()
	_to_running(sm)
	_wire_even_splits(sm)
	# Reach turn 5 (P1 estimate 50 s) having taken 70 s: 20 s behind -> positive.
	_progress.pct = 0.5
	sm._process(70.0)
	assert_eq(_hud.stage_deltas.size(), 1, "one popup at turn 5")
	assert_eq(int(_hud.stage_deltas[0]), 20000, "behind by 20 s reads positive (70 s − 50 s)")


func test_popup_interval_is_configurable() -> void:
	Config.data.stage_delta_interval_turns = 3
	var sm := _make()
	_to_running(sm)
	_wire_even_splits(sm)
	# Interval 3 over 12 turns -> turns 3, 6, 9, 12. Advance one interval per frame
	# (as real progress does) so each boundary fires its own popup.
	for boundary in [3, 6, 9, 12]:
		_progress.pct = float(boundary) / 12.0
		sm._process(1.0)
	assert_eq(_hud.stage_deltas.size(), 4, "interval 3 fires at turns 3/6/9/12")


# --- Staged mode (the pre-event start-line scene holds before the countdown) --

func _make_staged() -> StageManager:
	var sm := StageManager.new()
	add_child_autofree(sm)
	sm.set_process(false)  # drive _process manually for deterministic timing
	sm.setup(_car, _hud, _progress, true)
	return sm


func test_staged_setup_holds_in_staging() -> void:
	var sm := _make_staged()
	assert_eq(sm.phase(), StageManager.Phase.STAGING, "a staged run starts in STAGING")
	assert_true(_car.controls_locked, "car is locked at the start line")
	assert_eq(_hud.last_countdown, -999.0, "no countdown shown yet while staging")
	# Time passing must not advance the countdown or the timer while staging.
	sm._process(5.0)
	assert_eq(sm.phase(), StageManager.Phase.STAGING, "still STAGING — time alone never launches")
	assert_almost_eq(sm.elapsed(), 0.0, 0.0001, "timer doesn't run while staging")


func test_begin_countdown_leaves_staging() -> void:
	var sm := _make_staged()
	sm.begin_countdown()
	assert_eq(sm.phase(), StageManager.Phase.COUNTDOWN, "begin_countdown() arms the countdown")
	assert_true(_car.handbrake_locked, "handbrake held through the countdown")
	assert_false(_car.controls_locked, "full lock drops so the player can rev on the line")
	assert_almost_eq(_hud.last_countdown, Config.data.stage_countdown_seconds, 0.0001,
		"the full countdown shows when it arms")
	# From here the normal flow runs.
	_to_running(sm)
	assert_eq(sm.phase(), StageManager.Phase.RUNNING, "countdown then proceeds to RUNNING")
	assert_false(_car.controls_locked, "controls unlock at GO")


func test_begin_countdown_is_noop_outside_staging() -> void:
	# A non-staged run is already counting down; a stray begin_countdown() mustn't
	# restart it, and one after the run has started mustn't rewind it.
	var sm := _make()  # staged=false -> COUNTDOWN
	sm._process(1.0)
	var left_before := sm._countdown_left
	sm.begin_countdown()
	assert_eq(sm.phase(), StageManager.Phase.COUNTDOWN, "still counting down")
	assert_almost_eq(sm._countdown_left, left_before, 0.0001, "countdown not restarted")
	_to_running(sm)
	sm.begin_countdown()
	assert_eq(sm.phase(), StageManager.Phase.RUNNING, "a launch during the run is ignored")


# Integration: booting main.tscn wires a StageManager that holds the real car on
# the line from the first frame (the scene is built once in before_all). The boot
# is a non-staged countdown, so the handbrake is forced while input stays live.
func test_main_scene_holds_car_at_boot() -> void:
	var sm := _boot_scene.get_node_or_null("StageManager")
	assert_not_null(sm, "world.gd wires a StageManager into the scene")
	var car: VehicleBody3D = _boot_scene.get_node("Car")
	assert_true(car.handbrake_locked, "car's handbrake is held during the boot countdown")
