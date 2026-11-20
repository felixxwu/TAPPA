extends GutTest
# CarShadow: the blob laid on the ground under the car (features/car-shadow.md). Driven against a
# stub car over a flat static floor; no authored darkness or size is asserted.


class StubCar:
	extends Node3D
	func half_width() -> float:
		return 0.9
	func half_length() -> float:
		return 2.0


var _car: StubCar
var _shadow: CarShadow


func before_each() -> void:
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = WorldBoundaryShape3D.new()
	floor_body.add_child(shape)
	add_child_autofree(floor_body)
	_car = StubCar.new()
	add_child_autofree(_car)
	_shadow = CarShadow.new()
	add_child_autofree(_shadow)
	_shadow.setup(_car)


func test_lies_on_the_ground_under_the_car() -> void:
	_car.global_position = Vector3(3.0, 0.8, -2.0)
	await wait_physics_frames(2)
	assert_true(_shadow.visible)
	assert_almost_eq(_shadow.global_position.x, 3.0, 0.01)
	assert_almost_eq(_shadow.global_position.z, -2.0, 0.01)
	assert_between(_shadow.global_position.y, 0.0, 0.2)


func test_hidden_once_the_car_is_out_of_range_of_the_ground() -> void:
	_car.global_position = Vector3(0.0, Config.data.car_shadow_fade_height_m + 5.0, 0.0)
	await wait_physics_frames(2)
	assert_false(_shadow.visible)


func test_matches_the_body_footprint_and_heading() -> void:
	_car.global_transform = Transform3D(Basis(Vector3.UP, deg_to_rad(70.0)), Vector3(0.0, 0.8, 0.0))
	await wait_physics_frames(2)
	var soft := 2.0 * Config.data.car_shadow_soft_m
	var along := _shadow.global_basis.z
	assert_almost_eq(along.length(), _car.half_length() * 2.0 + soft, 0.01)
	assert_almost_eq(_shadow.global_basis.x.length(), _car.half_width() * 2.0 + soft, 0.01)
	assert_almost_eq(absf(along.normalized().dot(_car.global_basis.z)), 1.0, 0.001)
