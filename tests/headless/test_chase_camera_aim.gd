extends GutTest
# Chase camera aim point (chase_camera.gd -> _aim_point). Behaviour contract only:
# the look-ahead ratio is set to synthetic values per test, so nothing here pins
# the authored GameConfig.chase_look_ahead_ratio.

const HALF_LENGTH := 2.0

var _cam: Camera3D
var _target: Node3D


# A stand-in car: exposes half_length() (the only thing _aim_point asks of the
# target beyond its transform) without depending on the real Car / catalogue.
class StubCar:
	extends Node3D

	func half_length() -> float:
		return 2.0


func before_each() -> void:
	_target = StubCar.new()
	add_child(_target)
	_cam = load("res://scripts/chase_camera.gd").new()
	_cam.target = _target
	add_child(_cam)  # _ready() caches config into the _* fields
	_cam.set_physics_process(false)


func after_each() -> void:
	_cam.free()
	_target.free()


func test_aim_sits_ahead_of_the_body_origin_along_the_facing() -> void:
	_cam._look_ahead_ratio = 1.0
	_target.global_position = Vector3(10.0, 0.0, -5.0)
	# Identity basis: the car faces -Z, so the aim point must be offset that way.
	var aim: Vector3 = _cam._aim_point()
	var offset := aim - _target.global_position
	assert_almost_eq(offset.length(), HALF_LENGTH, 0.001,
		"aim sits half_length ahead at ratio 1.0")
	assert_gt(offset.normalized().dot(-_target.global_transform.basis.z), 0.999,
		"the offset points along the car's facing")


func test_aim_follows_the_cars_yaw_not_the_world_axes() -> void:
	# The whole point of the nose aim: when the car is yawed (as in a drift, where
	# its facing differs from its direction of travel), the aim point swings with
	# the facing rather than staying on a fixed world axis.
	_cam._look_ahead_ratio = 1.0
	var straight: Vector3 = _cam._aim_point() - _target.global_position
	_target.rotate_y(deg_to_rad(30.0))
	var yawed: Vector3 = _cam._aim_point() - _target.global_position
	assert_almost_eq(yawed.length(), straight.length(), 0.001,
		"yawing only rotates the aim offset, it doesn't change its reach")
	assert_lt(yawed.normalized().dot(straight.normalized()), 0.999,
		"the aim offset rotated with the car")
	assert_gt(yawed.normalized().dot(-_target.global_transform.basis.z), 0.999,
		"and it still points along the (new) facing")


func test_zero_ratio_aims_at_the_body_origin() -> void:
	_cam._look_ahead_ratio = 0.0
	_target.global_position = Vector3(3.0, 1.0, 4.0)
	_target.rotate_y(deg_to_rad(45.0))
	assert_almost_eq(_cam._aim_point().distance_to(_target.global_position), 0.0, 0.001,
		"ratio 0 keeps the old centre-of-car aim")


func test_target_without_half_length_aims_at_its_origin() -> void:
	# Flat fixtures (a bare Node3D) have no body to aim ahead of — no crash, no offset.
	var plain := Node3D.new()
	add_child(plain)
	_cam.target = plain
	_cam._look_ahead_ratio = 1.0
	plain.global_position = Vector3(-2.0, 0.5, 7.0)
	assert_almost_eq(_cam._aim_point().distance_to(plain.global_position), 0.0, 0.001,
		"a target without half_length() falls back to its origin")
	plain.free()


func test_look_at_points_the_camera_at_the_aim_not_the_origin() -> void:
	# End-to-end through a physics step: the camera's view ray must hit the aim
	# point, so a yawed car really does slide off frame centre.
	_cam._look_ahead_ratio = 1.0
	_cam._distance = 6.0
	_cam._height = 2.0
	_cam._base_fov = 80.0
	_cam._fov_speed_boost = 0.0
	_cam._fov_speed = 50.0
	_cam._fov_smoothing = 8.0
	_cam.fov = _cam._base_fov
	_target.rotate_y(deg_to_rad(40.0))
	_cam._physics_process(1.0 / 60.0)

	var forward := -_cam.global_transform.basis.z
	var aim: Vector3 = _cam._aim_point()
	var to_aim := (aim - _cam.global_position).normalized()
	var to_origin := (_target.global_position - _cam.global_position).normalized()
	assert_gt(forward.dot(to_aim), 0.999, "the camera looks straight at the aim point")
	assert_lt(forward.dot(to_origin), 0.999, "which is NOT straight at the body origin")
