class_name SimTest
extends GutTest
# Shared base for physics-scene tests on the flat test-track fixture.
# Tests may `extends SimTest` (or the existing path form
# `extends "res://tests/headless/sim_test.gd"` — both resolve to this base).
#
# WHY THIS EXISTS — the runner's --fixed-fps 60 already decouples the loop from
# wall-clock (frames run at CPU speed, same 1/60 delta), so the remaining cost is
# the CPU per physics step. Awaiting FEWER frames is still the lever: settling a
# car from the spawn clearance takes ~150 frames of solver work, and paying that
# in every before_each adds up. (time_scale / a higher physics_ticks_per_second
# are NOT alternatives — both change the per-step delta, altering the physics the
# tuned assertions depend on.)
#
# So instead of dropping the car from its 2.5 m spawn clearance and waiting
# ~150 frames to settle in every before_each, we settle ONCE, cache the resting
# transform, and on later setups just restore that pose and stabilise in a
# handful of frames. The cached pose is shared across every script that extends
# this base (all use the same baseline car on the same flat fixture).

const FIXTURE := "res://tests/fixtures/test_track.tscn"
const SETTLE_FRAMES := 150  # full drop + settle from the spawn clearance (cold path)
const RESTORE_FRAMES := 10  # minimum stabilise for a car placed AT a known settled pose

# Warm-restore convergence (see _wait_until_at_rest). RESTORE_FRAMES is a MINIMUM, not the
# whole wait: the restore is only finished once the car is measurably at rest, because a car
# that is still moving is not the "settled car" this base promises and every physics
# assertion is written against.
const REST_CHECK_FRAMES := 2       # frames between successive rest checks
const REST_MAX_FRAMES := 120       # give up and cold-settle instead beyond this
const REST_SPEED_MPS := 0.05       # linear speed under which the car counts as stopped
const REST_DRIFT_M := 0.001        # ride-height change per check under which it counts as still

var _scene: Node3D
var _car: VehicleBody3D

# Resting transform of the baseline car, captured on the first cold settle and
# reused by every later setup. Static so it is computed once per whole GUT run,
# not once per script.
static var _settled_xform := Transform3D()
static var _has_settled := false


func _wait_physics(frames: int) -> void:
	for i in frames:
		await get_tree().physics_frame


# Instantiate the fixture and expose `_scene` / `_car` (auto-freed after the test).
func _make_scene() -> void:
	_scene = load(FIXTURE).instantiate()
	add_child_autofree(_scene)
	_car = _scene.get_node("Car")


# Build a fresh, fully-settled baseline car. The first call settles the slow way
# and caches the resting transform; every later call restores that pose and
# stabilises in RESTORE_FRAMES instead of SETTLE_FRAMES.
func setup_settled_car() -> void:
	SceneTestHelpers.use_test_config()
	_make_scene()
	if _has_settled:
		# THE POSE MUST BE WRITTEN THROUGH car.gd's reset_to, NOT a bare global_transform
		# assignment. car.gd documents why on reset_to itself: the physics server DISCARDS a
		# plain global_transform write made outside the physics step, re-asserting the body's
		# own ongoing integration instead. Whether the write happened to land therefore
		# depended on the frame phase this was called from — so the warm path sometimes left
		# the car wherever it already was rather than at the cached resting pose.
		#
		# That is a nasty failure mode because it is SILENT and INTERMITTENT: the car is still
		# a settled car on flat ground, so most assertions still pass, and only a test reading
		# something pose-sensitive notices. It cost a real flake — the climbing-FWD steering
		# test in test_grip_servo_steering.gd read a yaw rate of ~0 in one full-suite run and
		# passed in isolation and on re-run, because its two other assertions could not tell
		# the difference.
		#
		# reset_to queues the pose for _integrate_forces (the physics-authoritative write
		# point), and also does the rest of the job this path was doing by hand and
		# incompletely: it wakes the body (a sleeping body never runs _integrate_forces, so a
		# queued pose would never be applied), zeroes both velocities, and additionally
		# re-zeroes steering, the wheel omegas and the engine sim — so a warm-restored car is
		# a genuinely fresh car rather than one carrying the previous state of everything
		# except its position.
		_car.reset_to(_settled_xform)
		if not await _wait_until_at_rest():
			# The restore did not converge, so this car is NOT the settled car the caller
			# asked for. Pay for a real drop-and-settle rather than handing out a bouncing
			# one — correctness first, and the cost is only ever paid on the rare miss.
			_car._reset()
			await _wait_physics(SETTLE_FRAMES)
	else:
		await _wait_physics(SETTLE_FRAMES)
		_settled_xform = _car.global_transform
		_has_settled = true


# Wait for the warm-restored car to actually come to rest; true once it has, false if it
# hasn't within REST_MAX_FRAMES.
#
# WHY THIS IS NOT A FIXED FRAME COUNT. It was `await _wait_physics(RESTORE_FRAMES)`, on the
# assumption that a car placed AT its own cached resting pose is already at rest and just
# needs a few frames to stabilise. That assumption does not hold: measured across a full
# suite run, most scripts warm-restored to y=0.7031 (the true rest height) but two —
# test_grip_servo_steering.gd and test_kinematic_pose.gd — landed at y=0.813, a tenth of a
# metre high and still moving, with the same mass, wheel radius, tyre mu and roster as
# everyone else. Ten frames is simply not always enough to damp whatever the teleport leaves
# in the suspension.
#
# The consequence is a SILENT, POSE-SENSITIVE flake rather than an obvious failure: a
# bouncing car's wheels carry far less normal force than a rested one's (10.5 kN vs 14.4 kN
# measured), so it has proportionally less grip while the engine's torque is unchanged — it
# spins its wheels where a rested car drives. That is what made the climbing-FWD steering
# test fail in a full run and pass in isolation, and it would bite any assertion that depends
# on available grip.
#
# So the warm path now measures the thing it was assuming. Cheap in the common case (the
# first check usually passes, so the cost is RESTORE_FRAMES as before) and self-correcting in
# the rare one.
func _wait_until_at_rest() -> bool:
	await _wait_physics(RESTORE_FRAMES)
	var waited := RESTORE_FRAMES
	while waited < REST_MAX_FRAMES:
		var y_before := _car.global_position.y
		await _wait_physics(REST_CHECK_FRAMES)
		waited += REST_CHECK_FRAMES
		if _car.linear_velocity.length() < REST_SPEED_MPS \
				and absf(_car.global_position.y - y_before) < REST_DRIFT_M:
			return true
	return false
