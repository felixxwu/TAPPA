extends GutTest
# A car in water gets extra drag and can still drive out; no reset is triggered.
# Injects an "always in water" predicate into the car and checks it slows.

const SceneHelpers = preload("res://tests/headless/scene_helpers.gd")

var _scene: Node3D
var _car: VehicleBody3D

func before_each() -> void:
	CarLibrary.reset()
	SceneHelpers.minimal_world()
	_scene = load("res://main.tscn").instantiate()
	add_child_autofree(_scene)
	_car = _scene.get_node("Car")
	await get_tree().physics_frame

func after_each() -> void:
	Config.reset()

func test_drag_applied_in_water_and_recoverable() -> void:
	_car.set_water_query(func(_pos): return true)
	Config.data.water_drag = _car.mass  # 1 m/s² per m/s: clearly measurable in 20 frames
	_car.linear_velocity = Vector3(0, 0, -20)
	for i in 20:
		await get_tree().physics_frame
	assert_lt(absf(_car.linear_velocity.z), 20.0, "water drag slowed the car")
	assert_gt(absf(_car.global_position.z), 0.0, "car kept moving, no reset to origin")
