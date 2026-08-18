extends "res://tests/headless/sim_test.gd"
# car.gd's kinematic_pose mode — the rival ghost's posing mode
# (features/rival-ghost.md).
#
# Deliberately DISTINCT from replay_playback, for two reasons the ghost cannot work
# around: replay_playback requires a ReplayRecorder (_step_replay early-returns without
# one, so nothing would feed the wheel spin), and it is read outside car.gd by
# track_progress.gd — a second car asserting it risks interfering with the player's
# progress tracking.
#
# These tests pin the gates a scripted, teleported car needs. Each one corresponds to a
# way the ghost would otherwise misbehave in the live world.


func test_kinematic_pose_is_not_replay_playback() -> void:
	# The whole point of a separate flag: nothing that keys off replay_playback (notably
	# TrackProgress) may see a ghost and think the player is in a replay.
	await setup_settled_car()
	_car.kinematic_pose = true
	assert_false(_car.replay_playback,
			"kinematic posing must not imply replay_playback")

func test_the_ghost_ignores_live_player_input() -> void:
	# The gate an earlier draft of the design missed. _driver_input_live() is the ONE
	# predicate every input site funnels through, and a ghost is neither controls_locked
	# nor ai_controlled — so without kinematic_pose in that predicate the ghost would run
	# the full drive sim on the player's held keyboard/gamepad input while the scripted
	# pose fought it.
	await setup_settled_car()
	_car.kinematic_pose = true
	assert_false(_car._driver_input_live(),
			"a kinematically posed car is dead to live driver input")

func test_the_ghost_takes_no_damage() -> void:
	# Teleporting a body along a path each frame reads as an enormous deceleration, which
	# would otherwise drain the ghost's HP (the same trap the replay ghost hit) and leave
	# a scripted car misfiring and rev-capped for no reason. It must take ZERO HP loss.
	await setup_settled_car()
	var hp0: float = _car.damage.hp if _car.damage != null else 1.0
	var losses := [0.0]
	if _car.damage != null:
		_car.damage.damaged.connect(func(loss: float, _pt: Vector3) -> void: losses[0] += loss)
	_car.kinematic_pose = true
	_car.custom_integrator = true
	# Yank the car a long way each tick, which is exactly what posing does.
	for i in 30:
		_car.global_position += Vector3(0.0, 0.0, -4.0)
		await _wait_physics(1)
	if _car.damage != null:
		assert_almost_eq(_car.damage.hp, hp0, 0.001,
				"a kinematically posed car takes zero damage")
		assert_eq(losses[0], 0.0, "and registers no impact at all")

func test_the_ghost_does_not_run_the_drive_sim() -> void:
	# _physics_process must early-return, or the drivetrain/engine/watchdog stack runs on
	# a car whose position is being written from outside.
	await setup_settled_car()
	_car.kinematic_pose = true
	_car.custom_integrator = true
	var engine = _car.drivetrain.engine
	var before: float = engine.rpm() if engine != null else 0.0
	_car.ai_controlled = false
	await _wait_physics(30)
	if engine != null:
		assert_almost_eq(engine.rpm(), before, 1.0,
				"the engine is not being stepped while posed")

func test_wheels_spin_from_the_supplied_omega_while_posed() -> void:
	# Without this the ghost's wheels sit dead still while the body slides along the
	# road. drivetrain.step() does not run in this mode, so replay_spin must.
	await setup_settled_car()
	var dt = _car.drivetrain
	var wheel = dt.visuals.keys()[0]
	# spin_angle is a DICTIONARY (wheel -> accumulated angle), not a method. Guarding on
	# has_method("spin_angle") made this test assert nothing at all and pass as "risky".
	var spin_before: float = float(dt.spin_angle.get(wheel, 0.0))
	_car.kinematic_pose = true
	_car.custom_integrator = true
	dt.replay_omega = {}
	for w in dt.visuals:
		dt.replay_omega[w] = 30.0
	await _wait_physics(20)
	assert_true(float(dt.spin_angle.get(wheel, 0.0)) != spin_before,
			"the wheel meshes turn from the supplied omega")

func test_leaving_kinematic_pose_restores_the_car() -> void:
	await setup_settled_car()
	var priority := _car.process_priority
	_car.kinematic_pose = true
	_car.kinematic_pose = false
	assert_eq(_car.process_priority, priority,
			"process priority is restored when the mode is left")
	assert_true(_car._driver_input_live() or _car.controls_locked or _car.ai_controlled,
			"input is live again once the mode is cleared")
