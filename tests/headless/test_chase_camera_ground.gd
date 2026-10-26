extends GutTest
# Chase camera height (chase_camera.gd -> _eased_base). The camera sits a fixed height above
# the car, whatever the ground under the camera does, and eases toward changes in the car's height.

var _cam: Camera3D
var _target: Node3D
var _hill: Node


# A terrain sibling that reports a hill everywhere: the camera must not seat on it.
class Hill extends Node:
	func height_at(_x: float, _z: float) -> float:
		return 20.0


func before_each() -> void:
	_target = Node3D.new()
	add_child(_target)
	_hill = Hill.new()
	add_child(_hill)
	_cam = load("res://scripts/chase_camera.gd").new()
	_cam.target = _target
	add_child(_cam)
	_cam.set_physics_process(false)


func after_each() -> void:
	_cam.free()
	_hill.free()
	_target.free()


func test_the_camera_sits_its_height_above_the_car_not_the_ground() -> void:
	_target.global_position = Vector3(0.0, 5.0, 0.0)
	_cam._timed_physics_process(1.0 / 60.0)
	assert_almost_eq(_cam.global_position.y, 5.0 + _cam._height, 0.001)


func test_the_first_seat_snaps_to_the_car() -> void:
	assert_almost_eq(_cam._eased_base(12.0, 1.0 / 60.0), 12.0, 0.001)


func test_a_small_rise_is_eased_toward_not_jumped_to() -> void:
	_cam._eased_base(0.0, 1.0 / 60.0)
	var seated: float = _cam._eased_base(4.0, 1.0 / 60.0)
	assert_gt(seated, 0.0, "it moves toward the car's new height")
	assert_lt(seated, 4.0, "but does not jump straight to it")
	for i in 600:
		seated = _cam._eased_base(4.0, 1.0 / 60.0)
	assert_almost_eq(seated, 4.0, 0.01, "and settles on it")


func test_a_huge_jump_snaps_instead_of_drifting() -> void:
	_cam._eased_base(0.0, 1.0 / 60.0)
	assert_almost_eq(_cam._eased_base(_cam.SNAP_M * 2.0, 1.0 / 60.0), _cam.SNAP_M * 2.0, 0.001)
