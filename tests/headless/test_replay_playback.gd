extends "res://tests/headless/sim_test.gd"

func test_drivetrain_replay_omega_overrides_live() -> void:
	await setup_settled_car()
	var dt = _car.drivetrain
	var w = dt.front_wheels[0]
	dt.replay_omega = {w: 42.0}
	assert_almost_eq(dt.wheel_omega(w), 42.0, 0.001, "replay omega wins when set")
	dt.replay_omega = {}
	# With the override cleared the live value is whatever the sim reports (finite).
	assert_true(is_finite(dt.wheel_omega(w)), "live omega is finite after clear")

func _recorded_run() -> ReplayRecorder:
	var rec := ReplayRecorder.new()
	add_child_autofree(rec)
	rec.setup(_car)
	rec.start()
	_car.ai_controlled = true
	_car.ai_throttle = 1.0
	await _wait_physics(150)   # long enough that start / mid / end are clearly distinct
	rec.stop()
	_car.ai_controlled = false
	_car.ai_throttle = 0.0
	return rec

func test_replay_follows_recorded_line_and_reports_recorded_velocity() -> void:
	await setup_settled_car()
	var rec: ReplayRecorder = await _recorded_run()
	var target := rec.sample_at(rec.duration() * 0.5)
	_car.begin_replay(rec)
	assert_true(_car.replay_playback, "replay mode active after begin_replay")
	# Advance to ~mid-recording and confirm the body tracks the recorded pose.
	await _wait_physics(int(rec.duration() * 0.5 * 60.0))
	assert_lt(_car.global_position.distance_to(target["xform"].origin), 3.0,
		"body tracks the recorded line")
	assert_gt(_car.linear_velocity.length(), 0.0,
		"car reports recorded velocity (not the frozen zero)")
	_car.end_replay()
	assert_false(_car.replay_playback, "replay mode cleared after end_replay")
	assert_true(_car.drivetrain.replay_omega.is_empty(), "replay omega cleared")

func test_replay_loops_at_end() -> void:
	await setup_settled_car()
	var rec: ReplayRecorder = await _recorded_run()
	_car.begin_replay(rec)
	# Run past the end; cursor should wrap rather than run off.
	await _wait_physics(int(rec.duration() * 60.0) + 30)
	assert_lt(_car.replay_cursor(), rec.duration() + 0.5, "cursor wrapped, did not run away")
	_car.end_replay()

func test_replay_ghost_takes_no_damage_and_never_wrecks() -> void:
	# Regression: the frozen ghost is teleported along the path each frame, which
	# _integrate_forces would otherwise read as a huge deceleration and chip HP until
	# the car "wrecks" mid-replay (firing the wreck screen / a spurious DNF). The
	# replay guard must make the ghost take zero damage.
	await setup_settled_car()
	var rec: ReplayRecorder = await _recorded_run()
	_car.begin_replay(rec)
	# A large stale pre-replay approach velocity is exactly what _integrate_forces
	# reads as a per-frame deceleration once the body is frozen at zero velocity.
	_car._approach_velocity = Vector3(60.0, 0.0, 0.0)
	var wrecked_fired := [false]
	_car.wrecked.connect(func() -> void: wrecked_fired[0] = true)
	var hp0: float = _car.damage.hp
	await _wait_physics(120)
	assert_eq(_car.damage.hp, hp0, "the frozen replay ghost must take zero damage")
	assert_false(wrecked_fired[0], "the ghost must never wreck during replay")
	_car.end_replay()

func test_replay_sets_and_restores_process_priority() -> void:
	# The car must process before its _process observers (camera, terrain focus) so they
	# read the fresh replayed pose; begin_replay lowers process_priority and end_replay
	# must restore it (a stuck low priority would starve everything else afterward).
	await setup_settled_car()
	var rec: ReplayRecorder = await _recorded_run()
	var saved: int = _car.process_priority
	_car.begin_replay(rec)
	assert_eq(_car.process_priority, _car.REPLAY_PROCESS_PRIORITY, "car processes first during replay")
	_car.end_replay()
	assert_eq(_car.process_priority, saved, "process priority restored after replay")

# A stand-in for a _process reader of the car (like TerrainManager's chunk-load focus).
class Probe extends Node3D:
	var target: Node3D
	var max_delta := 0.0
	var _first := Vector3.INF
	func _process(_d: float) -> void:
		if target == null:
			return
		if _first == Vector3.INF:
			_first = target.global_position
		max_delta = maxf(max_delta, _first.distance_to(target.global_position))

func test_process_readers_see_the_replay_car_move() -> void:
	# Regression for the "terrain loads at the finish while the car drives off" bug: a
	# _process reader at default priority must observe the replay car MOVE (the car
	# updates its transform in _process, before default-priority readers, via
	# REPLAY_PROCESS_PRIORITY). Headless-viable: this is a _process-order fact, not a
	# render fact. Asserts movement > 0 and the priority ordering — no pinned magnitude.
	await setup_settled_car()
	var rec: ReplayRecorder = await _recorded_run()
	var probe := Probe.new()
	add_child_autofree(probe)
	probe.target = _car
	_car.begin_replay(rec)
	assert_lt(_car.process_priority, probe.process_priority, "car processes before default-priority readers")
	await _wait_physics(int(rec.duration() * 0.6 * 60.0))
	assert_gt(probe.max_delta, 0.5, "a _process reader observes the replay car moving")
	_car.end_replay()

func test_replay_spins_the_wheels() -> void:
	# drivetrain.step() (which advances wheel visual spin) doesn't run during replay, so
	# the car drives replay_spin() from the recorded omega. Assert the visual spin angle
	# advances for a wheel that had non-zero recorded omega. Behavioural, no pinned value.
	await setup_settled_car()
	var rec: ReplayRecorder = await _recorded_run()
	var dt = _car.drivetrain
	var w = dt.front_wheels[0]
	dt.spin_angle[w] = 0.0
	var before: float = dt.spin_angle[w]
	_car.begin_replay(rec)
	await _wait_physics(60)
	assert_ne(dt.spin_angle[w], before, "wheel visual spin advances during replay")
	_car.end_replay()
