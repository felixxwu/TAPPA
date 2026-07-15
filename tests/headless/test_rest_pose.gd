extends GutTest
# Guards Car.settled_ride_height() — the analytic rest pose that replaced the fragile
# "drop a live physics body and freeze it seconds later" staging for display/prop cars
# (roadside wreck, podium, HQ lineup). The analytic height must match where Godot's
# VehicleWheel3D solver ACTUALLY settles a car, across a range of suspension configs.
# If a Godot upgrade shifts the suspension solver, SUSPENSION_COMPRESSION_COEFF no
# longer matches and this test fails loudly rather than shipping floating/sunk props.

const CAR_SCENE := "res://car.tscn"
const TOL := 0.05  # metres; props tolerate a couple cm, and geometry drift is ~±0.02


func _floor_at(y: float) -> StaticBody3D:
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20, 1, 20)
	cs.shape = box
	body.add_child(cs)
	body.position = Vector3(0, y - 0.5, 0)
	return body


# Settle a fresh car on a flat floor at y=0 and return BOTH the actual settled
# body-origin height and the analytic prediction, for the given suspension tweaks.
func _actual_and_predicted(stiffness: float, travel: float, radius: float) -> Array:
	var floor_body := _floor_at(0.0)
	add_child_autofree(floor_body)
	var car: Variant = load(CAR_SCENE).instantiate()
	add_child_autofree(car)
	car.use_isolated_config()
	car.apply_car(0)
	var cfg: GameConfig = car.config
	cfg.suspension_stiffness = stiffness
	cfg.suspension_travel = travel
	cfg.wheel_radius = radius
	for w in car.find_children("*", "VehicleWheel3D", false):
		w.wheel_radius = radius
	car._sync_suspension_to_wheels()
	var predicted: float = car.settled_ride_height()
	car.controls_locked = true
	car.global_position = Vector3(0, radius + travel + 0.4, 0)
	car.freeze = false
	for _i in 160:
		await get_tree().physics_frame
	var actual: float = car.global_position.y
	car.queue_free()
	floor_body.queue_free()
	await get_tree().process_frame
	return [actual, predicted]


func test_analytic_height_matches_the_real_settle_across_configs() -> void:
	# Default-ish, stiffer, softer, bigger wheels, longer travel — the analytic helper
	# must track Godot's actual settled height within tolerance for all of them.
	var cases := [
		[10.0, 0.42, 0.30],
		[20.0, 0.42, 0.30],
		[10.0, 0.55, 0.30],
		[10.0, 0.42, 0.40],
	]
	for c in cases:
		var r := await _actual_and_predicted(c[0], c[1], c[2])
		var actual: float = r[0]
		var predicted: float = r[1]
		assert_almost_eq(predicted, actual, TOL,
			"analytic rest height matches Godot's settle for k=%.0f travel=%.2f r=%.2f (got %.3f, settled %.3f)" % [
				c[0], c[1], c[2], predicted, actual])


# A frozen prop's solver never runs, so its wheel VISUALS stay at the authored mount —
# ~travel too high, so the car reads as sitting on over-compressed suspension. Car.
# settle_wheel_visuals() droops each Visual to where Godot's live solver renders it, so
# a parked prop matches the driven car. This pins WHEEL_DROOP_COEFF against a real settle:
# for each config, settle a live car (records the actual rendered wheel height), then a
# frozen prop placed at settled_ride_height() + settle_wheel_visuals() must land its wheel
# Visuals at the same world height. Fails loudly if a Godot upgrade shifts the wheel render.
func test_frozen_prop_wheel_visuals_match_the_live_settle() -> void:
	var cases := [
		[10.0, 0.42, 0.30],
		[20.0, 0.42, 0.30],
		[10.0, 0.55, 0.30],
	]
	for c in cases:
		var floor_body := _floor_at(0.0)
		add_child_autofree(floor_body)
		# Live-settled reference: median rendered wheel-Visual world Y.
		var live: Variant = load(CAR_SCENE).instantiate()
		add_child_autofree(live)
		live.use_isolated_config()
		live.apply_car(0)
		_tune(live, c[0], c[1], c[2])
		live.controls_locked = true
		live.global_position = Vector3(0, c[2] + c[1] + 0.4, 0)
		live.freeze = false
		for _i in 160:
			await get_tree().physics_frame
		var live_wheel_y: float = _first_visual_y(live)
		live.queue_free()
		# Frozen prop: placed analytically, then wheel visuals drooped.
		var prop: Variant = load(CAR_SCENE).instantiate()
		add_child_autofree(prop)
		prop.use_isolated_config()
		prop.apply_car(0)
		_tune(prop, c[0], c[1], c[2])
		prop.controls_locked = true
		prop.freeze = true
		prop.global_position = Vector3(0, prop.settled_ride_height(), 0)
		prop.settle_wheel_visuals()
		await get_tree().physics_frame
		var prop_wheel_y: float = _first_visual_y(prop)
		prop.queue_free()
		floor_body.queue_free()
		await get_tree().process_frame
		assert_almost_eq(prop_wheel_y, live_wheel_y, TOL,
			"frozen prop wheel visual matches live settle for k=%.0f travel=%.2f r=%.2f (prop %.3f, live %.3f)" % [
				c[0], c[1], c[2], prop_wheel_y, live_wheel_y])


func _tune(car: Variant, stiffness: float, travel: float, radius: float) -> void:
	var cfg: GameConfig = car.config
	cfg.suspension_stiffness = stiffness
	cfg.suspension_travel = travel
	cfg.wheel_radius = radius
	for w in car.find_children("*", "VehicleWheel3D", false):
		w.wheel_radius = radius
	car._sync_suspension_to_wheels()


func _first_visual_y(car: Variant) -> float:
	for w in car.find_children("*", "VehicleWheel3D", false):
		var visual: Node3D = w.get_node_or_null("Visual")
		if visual != null:
			return visual.global_position.y
	return NAN


func test_rest_height_is_independent_of_mass() -> void:
	# Godot normalises the suspension spring by chassis mass, so the settled height must
	# not change with mass — the analytic helper (which ignores mass) relies on this.
	var floor_body := _floor_at(0.0)
	add_child_autofree(floor_body)
	var heights: Array[float] = []
	for m in [900.0, 2400.0]:
		var car: Variant = load(CAR_SCENE).instantiate()
		add_child_autofree(car)
		car.use_isolated_config()
		car.apply_car(0)
		car.mass = m
		car.controls_locked = true
		var cfg: GameConfig = car.config
		car.global_position = Vector3(0, cfg.wheel_radius + cfg.axle_travel(true) + 0.4, 0)
		car.freeze = false
		for _i in 160:
			await get_tree().physics_frame
		heights.append(car.global_position.y)
		car.queue_free()
		await get_tree().process_frame
	assert_almost_eq(heights[0], heights[1], 0.02,
		"settled height is the same for a light and a heavy car (mass-normalised spring)")
