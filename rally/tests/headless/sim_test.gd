extends GutTest
# Shared base for physics-scene tests on the flat test-track fixture.
#
# WHY THIS EXISTS — the cost of physics tests is wall-clock, not CPU. Godot's
# headless physics loop is paced to real time at the tick rate: every awaited
# physics frame costs ~1/60 s of wall-clock regardless of how trivial the scene
# is. There is NO engine setting that runs the same fixed-delta sim faster —
# Engine.time_scale and a higher physics_ticks_per_second both change the
# per-step delta (verified: time_scale=8 makes delta 8x bigger), which would
# alter the physics the tuned assertions depend on. The only safe lever is to
# await FEWER frames.
#
# So instead of dropping the car from its 2.5 m spawn clearance and waiting
# ~150 frames to settle in every before_each, we settle ONCE, cache the resting
# transform, and on later setups just restore that pose and stabilise in a
# handful of frames. The cached pose is shared across every script that extends
# this base (all use the same baseline car on the same flat fixture).

const FIXTURE := "res://tests/fixtures/test_track.tscn"
const SETTLE_FRAMES := 150  # full drop + settle from the spawn clearance (cold path)
const RESTORE_FRAMES := 10  # stabilise a car placed AT a known settled pose (warm path)

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
	Config.reset()
	_make_scene()
	if _has_settled:
		_car.global_transform = _settled_xform
		_car.linear_velocity = Vector3.ZERO
		_car.angular_velocity = Vector3.ZERO
		await _wait_physics(RESTORE_FRAMES)
	else:
		await _wait_physics(SETTLE_FRAMES)
		_settled_xform = _car.global_transform
		_has_settled = true
