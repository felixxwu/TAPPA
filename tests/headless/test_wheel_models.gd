extends GutTest
# Cars whose spec names a wheel_model show that model on every wheel in place of the textured cylinder,
# sized to the spec's wheel_radius and turned so its outer face points away from the car.

const SceneHelpers = preload("res://tests/headless/scene_helpers.gd")
const WHEEL := "res://tests/headless/fixtures/test_wheel.tscn"  # a radius-0.5 cylinder on an x axle

var _car: VehicleBody3D
var _cars: Array[Dictionary]


func before_each() -> void:
	CarLibrary.reset()
	EngineLibrary.reset()
	CarFixtures.install()
	_cars = CarFixtures.cars()
	_cars[0]["wheel_model"] = WHEEL
	CarLibrary.override_for_test(_cars)
	SceneHelpers.minimal_world()
	var scene: Node3D = load("res://main.tscn").instantiate()
	add_child_autofree(scene)
	_car = scene.get_node("Car")
	await get_tree().physics_frame


func after_each() -> void:
	Config.reset()
	CarFixtures.restore()


func _wheels() -> Array:
	return _car.find_children("*", "VehicleWheel3D", false)


func test_wheel_model_car_hides_the_cylinder_and_shows_the_model() -> void:
	_car.apply_car(0)
	for wheel in _wheels():
		var model := wheel.get_node_or_null("Visual/WheelModel") as Node3D
		assert_not_null(model, "%s has a wheel model" % wheel.name)
		assert_true(model != null and model.visible, "%s shows it" % wheel.name)
		assert_false((wheel.get_node("Visual/Tire") as Node3D).visible, "%s hides the cylinder" % wheel.name)


func test_cylinder_car_after_a_wheel_model_car_restores_the_cylinder() -> void:
	_car.apply_car(0)
	_car.apply_car(1)
	for wheel in _wheels():
		assert_null(wheel.get_node_or_null("Visual/WheelModel"), "%s dropped the wheel model" % wheel.name)
		assert_true((wheel.get_node("Visual/Tire") as Node3D).visible, "%s shows the cylinder again" % wheel.name)
	_car.apply_car(0)
	for wheel in _wheels():
		var models := (wheel.get_node("Visual") as Node).get_children().filter(func(n): return n.name.begins_with("WheelModel"))
		assert_eq(models.size(), 1, "%s has exactly one wheel model" % wheel.name)


func test_wheel_model_scales_to_the_spec_radius() -> void:
	for radius in [0.30, 0.42]:
		_cars[0]["wheel_radius"] = radius
		_car.apply_car(0)
		for wheel in _wheels():
			var height := _global_height(wheel.get_node("Visual/WheelModel"))
			assert_almost_eq(height, 2.0 * radius, 0.01, "%s model is %.2f m tall for radius %.2f" % [wheel.name, height, radius])


func test_wheel_model_outer_face_points_away_from_the_car() -> void:
	_car.apply_car(0)
	for wheel in _wheels():
		var model := wheel.get_node("Visual/WheelModel") as Node3D
		var outward := model.global_basis.x.dot(_car.global_basis.x)
		assert_eq(signf(outward), signf(wheel.position.x), "%s model's outer face points away from the car" % wheel.name)


func _global_height(model: Node3D) -> float:
	var lo := INF
	var hi := -INF
	for mi in model.find_children("*", "MeshInstance3D", true):
		var box: AABB = (mi as MeshInstance3D).global_transform * (mi as MeshInstance3D).get_aabb()
		lo = minf(lo, box.position.y)
		hi = maxf(hi, box.end.y)
	return hi - lo


func test_missing_wheel_model_falls_back_to_the_cylinder() -> void:
	_cars[0]["wheel_model"] = "res://tests/headless/fixtures/no_such_wheel.glb"
	_car.apply_car(0)
	for wheel in _wheels():
		assert_null(wheel.get_node_or_null("Visual/WheelModel"), "%s has no wheel model" % wheel.name)
		assert_true((wheel.get_node("Visual/Tire") as Node3D).visible, "%s keeps the cylinder" % wheel.name)
