extends GutTest
# Car.retune: re-apply a CHANGED per-car tuning to the already-fielded LIVE config
# WITHOUT reshaping the body. Regression for the start-line Tune Car menu, which used
# to call apply_owned — that relocates the wheels (detach/re-attach from the tree) and
# resets the pose on the staged, simulating VehicleBody3D, corrupting its suspension so
# the wheels dropped through the floor. retune must leave the body untouched and only
# re-derive the tuned config fields (all read live each physics step). Uses the
# synthetic CarFixtures roster so no shipped catalogue entry is depended on.

const SceneHelpers = preload("res://tests/headless/scene_helpers.gd")
const CarFixtures = preload("res://tests/headless/car_fixtures.gd")

var _scene: Node3D
var _car: VehicleBody3D


func before_each() -> void:
	SceneHelpers.minimal_world()
	CarFixtures.install()
	_scene = load("res://main.tscn").instantiate()
	add_child_autofree(_scene)
	_car = _scene.get_node("Car")
	# Field a fixture car from an owned dict so retune has its pre-tune baseline snapshot.
	_car.apply_owned({"model_id": "fx_light_rwd", "instance_id": 1, "tuning": {}, "upgrades": {}})


func after_each() -> void:
	CarFixtures.restore()
	Config.reset()


func test_retune_applies_the_changed_tuning_to_the_live_config() -> void:
	var front_before: float = _car.config.wheel_friction_slip_front
	var rear_before: float = _car.config.wheel_friction_slip_rear
	_car.retune({"model_id": "fx_light_rwd", "instance_id": 1, "tuning": {"grip_balance": 1.0}, "upgrades": {}})
	assert_lt(_car.config.wheel_friction_slip_front, front_before, "oversteer shifts grip off the front, live")
	assert_gt(_car.config.wheel_friction_slip_rear, rear_before, "oversteer shifts grip onto the rear, live")


func test_retune_is_idempotent_and_does_not_compound() -> void:
	var owned := {"model_id": "fx_light_rwd", "instance_id": 1, "tuning": {"grip_balance": 0.7}, "upgrades": {}}
	_car.retune(owned)
	var front_once: float = _car.config.wheel_friction_slip_front
	_car.retune(owned)  # same tuning again
	assert_almost_eq(_car.config.wheel_friction_slip_front, front_once, 0.0001,
		"re-applying the same tuning restores the baseline first, so it never compounds")


func test_retune_does_not_reshape_or_reset_the_body() -> void:
	# The crux of the bug: retune must NOT relocate wheels or reset the pose (apply_owned
	# does both, which broke the live body). Capture the wheel node identities + the
	# body transform, retune, and assert nothing moved.
	var wheels_before := _car.find_children("*", "VehicleWheel3D", false)
	var xform_before: Transform3D = _car.global_transform
	_car.retune({"model_id": "fx_light_rwd", "instance_id": 1, "tuning": {"grip_balance": 1.0, "engine_detune": 0.5}, "upgrades": {}})
	var wheels_after := _car.find_children("*", "VehicleWheel3D", false)
	assert_eq(wheels_after.size(), wheels_before.size(), "no wheels added/removed")
	for w in wheels_before:
		assert_true(wheels_after.has(w), "the SAME wheel nodes remain (not re-instantiated / re-parented)")
	assert_eq(_car.global_transform, xform_before, "the body pose is untouched (no reset_to)")
