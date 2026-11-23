extends GutTest
# Hidden bump travel must add stroke before bottoming without visibly raising the car.

const CAR_SCENE := preload("res://car.tscn")


func before_each() -> void:
	Config.reset()
	CarFixtures.install()


func after_each() -> void:
	CarFixtures.restore()
	Config.reset()


func _settled(hidden: float) -> Dictionary:
	Config.data.hidden_bump_travel = hidden
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(100.0, 1.0, 100.0)
	shape.shape = box
	shape.position.y = -0.5
	floor_body.add_child(shape)
	add_child_autofree(floor_body)
	var car := CAR_SCENE.instantiate()
	add_child_autofree(car)
	await get_tree().physics_frame
	car.apply_car(0, false)
	car.global_transform = Transform3D(Basis(), Vector3(0.0, 1.0, 0.0))
	car.linear_velocity = Vector3.ZERO
	for i in 240:
		await get_tree().physics_frame
	var wheel: VehicleWheel3D = car.get_node("WheelFL")
	var result := {
		"body_y": car.global_position.y,
		"stroke": (car.global_transform * car.wheel_mount(wheel)).y - wheel.get_contact_point().y - wheel.wheel_radius,
		"all_grounded": car.wheels_in_contact() == 4,
	}
	floor_body.queue_free()
	car.queue_free()
	await get_tree().physics_frame
	return result


func test_hidden_travel_keeps_ride_height_and_adds_stroke() -> void:
	var plain: Dictionary = await _settled(0.0)
	var hidden: Dictionary = await _settled(0.2)
	assert_true(plain["all_grounded"] and hidden["all_grounded"], "both cars settle on all four wheels")
	assert_lt(absf(hidden["body_y"] - plain["body_y"]), 0.2 * 0.25, "ride height barely moves")
	assert_gt(hidden["stroke"] - plain["stroke"], 0.2 * 0.9, "bump stroke grows by about the hidden travel")
