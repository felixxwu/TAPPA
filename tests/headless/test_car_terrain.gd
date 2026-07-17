extends GutTest
# Car-meets-terrain integration tests on the real main.tscn. These are the
# canary for terrain generation changes that break gameplay at spawn (car
# underground, launched, or falling forever). They are terrain-relative by
# design — pure car behavior is tested on the flat fixture in test_car.gd.

var _scene: Node3D
var _car: VehicleBody3D
var _settled: Transform3D


func before_all() -> void:
	# Generate the real track/terrain ONCE (no foliage — these tests never look
	# at trees/bushes), cold-settle the car, and cache its resting pose. Each test
	# restores that pose in before_each rather than re-instantiating main.tscn and
	# re-settling from the spawn clearance (the warm-restore idea from sim_test.gd).
	SceneTestHelpers.no_foliage_world()
	_scene = load("res://main.tscn").instantiate()
	add_child(_scene)
	_car = _scene.get_node("Car")
	await _wait_physics(150)  # let the car drop onto its suspension and settle
	_settled = _car.global_transform


func after_all() -> void:
	_scene.free()
	Config.reset()  # don't leak the zeroed foliage into later files


func before_each() -> void:
	# Restore the cached resting pose and re-stabilise briefly.
	_car.global_transform = _settled
	_car.linear_velocity = Vector3.ZERO
	_car.angular_velocity = Vector3.ZERO
	await _wait_physics(20)


func _wait_physics(frames: int):
	for i in frames:
		await get_tree().physics_frame


func test_car_settles_on_terrain() -> void:
	# Terrain-relative: the spawn can sit on a slope (the car may legitimately
	# slide sideways downhill on low grip), so assert it rides on the surface
	# at suspension height and hasn't launched, sunk, or exploded into jitter.
	var floor_node: Node = _scene.get_node("Floor")
	var ground: float = floor_node.height_at(_car.global_position.x, _car.global_position.z)
	assert_between(_car.global_position.y - ground, 0.1, 1.5,
		"car rides on the terrain surface, not sunk/launched")
	assert_lt(_car.linear_velocity.length(), 2.0, "car at most creeping after settling")


func test_world_border_catches_car_beyond_terrain() -> void:
	# The flat border plane under the hills must stop the car falling forever
	# once it drives off the 200x200m hilly patch.
	_car.global_position = Vector3(300.0, 5.0, 300.0)
	_car.linear_velocity = Vector3.ZERO
	await _wait_physics(600)  # fall 17m and damp out on the border plane (the
	# default MX-5's small wheels settle a violent drop slower than the old car)
	# The chaotic landing can leave the car free-rolling horizontally for a
	# long time (only engine braking slows a driverless coast), so assert the
	# border CAUGHT it — on the plane, no longer falling or bouncing — rather
	# than racing the coast-down to a stop.
	assert_gt(_car.global_position.y, -13.0, "car rests on the border, not in the void")
	assert_lt(absf(_car.linear_velocity.y), 0.5, "car no longer falling or bouncing")
