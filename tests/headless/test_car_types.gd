extends "res://tests/headless/sim_test.gd"
# Per-car smoke tests: every CarLibrary entry, once selected, must put its four
# wheels in the right places, sit on the ground, and actually drive. Cars are
# selected the way the game does it — by re-instantiating the car (Car.respawn)
# — so this also guards the swap path: an earlier in-place reshape accumulated
# stale suspension state and left some cars spinning in place, undrivable.
#
# `_wait`/settle constants come from sim_test.gd. Each car type has its own
# resting pose, so we cache one settled transform PER car index (keyed in
# `_settled_by_index`) and restore it on later selections instead of dropping
# every car from its spawn clearance in every test.


var _spawn: Transform3D

# index -> settled global transform, populated lazily the first time a car is
# settled. Static so the cache survives across this script's tests.
static var _settled_by_index := {}


func before_each() -> void:
	Config.reset()
	_make_scene()
	_spawn = _car.transform


func after_each() -> void:
	for action in ["accelerate", "steer_left", "steer_right"]:
		Input.action_release(action)


func _wait(frames: int) -> void:
	await _wait_physics(frames)


# Select car `index` the same way the game does: a fresh instance, configured
# once. Updates _car to the new node.
func _select(index: int) -> void:
	_car = _car.respawn(_car, index, _spawn)


# Select car `index` AND leave it fully settled on its suspension. First touch
# of an index settles the slow way (drop from spawn clearance) and caches the
# resting pose; later touches restore that pose and stabilise in RESTORE_FRAMES.
func _select_settled(index: int) -> void:
	_select(index)
	if _settled_by_index.has(index):
		_car.global_transform = _settled_by_index[index]
		_car.linear_velocity = Vector3.ZERO
		_car.angular_velocity = Vector3.ZERO
		await _wait(RESTORE_FRAMES)
	else:
		await _wait(SETTLE_FRAMES)
		_settled_by_index[index] = _car.global_transform


func test_every_car_places_its_wheels_at_track_and_wheelbase() -> void:
	for i in CarLibrary.CARS.size():
		var spec: Dictionary = CarLibrary.CARS[i]
		_select(i)
		await _wait(5)
		var half_track: float = float(spec["track"]) * 0.5
		var half_base: float = float(spec["wheelbase"]) * 0.5
		for wheel in _car.find_children("*", "VehicleWheel3D", false):
			assert_almost_eq(absf(wheel.position.x), half_track, 0.01,
				"%s: %s sits at half-track" % [spec["name"], wheel.name])
			assert_almost_eq(absf(wheel.position.z), half_base, 0.01,
				"%s: %s sits at half-wheelbase" % [spec["name"], wheel.name])


# Regression for a bug where wheel radius/track looked wrong only in events:
# car.tscn's wheel Tire/Spoke meshes are shared sub-resources across ALL
# car.tscn instances (not just the four wheels within one car), and apply_car
# used to resize them in place. start_line.gd's queue spawns extra car
# instances (leader/trailer) and calls apply_car on THEM too, after the
# player's own car was already sized — corrupting the player's wheel visuals
# to the last-applied car's dimensions. car.gd._ready() now gives every
# instance its own mesh copies up front so apply_car can never leak across
# instances; simulate the queue (two cars, two different specs) and assert
# the first car's wheel meshes keep ITS OWN radius/width, not the second's.
func test_apply_car_on_a_second_instance_does_not_resize_the_first(
		) -> void:
	var i_first := 0
	var i_second := 1 if CarLibrary.CARS.size() > 1 else 0
	assert_ne(i_first, i_second, "fixture needs at least two distinct car specs")
	_select(i_first)
	var first := _car
	var second: Node = load("res://car.tscn").instantiate()
	add_child_autofree(second)
	second.apply_car(i_second)

	var first_spec: Dictionary = CarLibrary.CARS[i_first]
	for wheel in first.find_children("*", "VehicleWheel3D", false):
		var tire := wheel.get_node_or_null("Visual/Tire") as MeshInstance3D
		var cyl := tire.mesh as CylinderMesh
		assert_almost_eq(cyl.top_radius, float(first_spec["wheel_radius"]), 0.001,
			"%s: %s tire mesh keeps its own radius after a second car is spawned"
				% [first_spec["name"], wheel.name])
		assert_almost_eq(wheel.wheel_radius, float(first_spec["wheel_radius"]), 0.001,
			"%s: %s physics radius keeps its own value" % [first_spec["name"], wheel.name])


func test_every_car_sits_on_the_ground() -> void:
	for i in CarLibrary.CARS.size():
		var spec: Dictionary = CarLibrary.CARS[i]
		await _select_settled(i)  # drop from the spawn clearance and settle (cached)
		var grounded := 0
		for wheel in _car.find_children("*", "VehicleWheel3D", false):
			if wheel.is_in_contact():
				grounded += 1
		assert_eq(grounded, 4, "%s: all four wheels rest on the ground" % spec["name"])


func test_every_car_suspension_absorbs_a_one_metre_drop() -> void:
	# Drop each car 1 m onto flat ground: the suspension must be stiff and long
	# enough that the chassis collision box never reaches the ground. The box is
	# body.height - 0.3 tall, centred on the car origin, so its underside sits at
	# car.y - (body.y/2 - 0.15); if that hits y=0 the body has bottomed out.
	for i in CarLibrary.CARS.size():
		var spec: Dictionary = CarLibrary.CARS[i]
		await _select_settled(i)  # settle on its suspension first (cached)
		var box_bottom_offset: float = float(spec["body"]["y"]) * 0.5 - 0.15
		# Lift by a metre and release from rest.
		_car.global_position += Vector3(0.0, 1.0, 0.0)
		_car.linear_velocity = Vector3.ZERO
		_car.angular_velocity = Vector3.ZERO
		var lowest := INF
		for f in 120:  # fall, impact and rebound
			await get_tree().physics_frame
			lowest = minf(lowest, _car.global_position.y)
		# A little margin so a near-miss still counts as a fail.
		assert_gt(lowest, box_bottom_offset + 0.03,
			"%s: chassis stays off the ground through a 1m drop (lowest body y %.2f, box underside at %.2f)"
			% [spec["name"], lowest, box_bottom_offset])


func test_every_car_stays_upright_while_cornering() -> void:
	# Accelerate hard and crank full steering: the car may slide, but it must not
	# tip over. We track the body's up vector — up.y = cos(roll); staying above
	# 0.5 means it never leans past ~60 degrees, i.e. never rolls onto its side.
	for i in CarLibrary.CARS.size():
		var spec: Dictionary = CarLibrary.CARS[i]
		await _select_settled(i)  # settle (cached)
		Input.action_press("accelerate")
		await _wait(120)  # build speed first
		Input.action_press("steer_left")  # then throw it into a hard turn
		var min_up := INF
		for f in 240:
			await get_tree().physics_frame
			min_up = minf(min_up, _car.global_transform.basis.y.y)
		Input.action_release("steer_left")
		Input.action_release("accelerate")
		assert_gt(min_up, 0.5,
			"%s: stays upright through a hard cornering manoeuvre (min up.y %.2f)"
			% [spec["name"], min_up])


func test_every_car_drives_forward() -> void:
	for i in CarLibrary.CARS.size():
		var spec: Dictionary = CarLibrary.CARS[i]
		await _select_settled(i)  # settle on its suspension (cached)
		var start: Vector3 = _car.global_position
		Input.action_press("accelerate")
		await _wait(120)
		Input.action_release("accelerate")
		var travelled := Vector2(
			_car.global_position.x - start.x, _car.global_position.z - start.z
		).length()
		assert_gt(travelled, 2.0, "%s: drives forward under throttle" % spec["name"])


func test_every_car_applies_its_own_shift_time() -> void:
	# Selecting a car overlays its gearbox shift_time onto the live config, so
	# each car shifts at its own speed rather than a single global value.
	var seen := {}
	for i in CarLibrary.CARS.size():
		var spec: Dictionary = CarLibrary.CARS[i]
		_select(i)
		await _wait(5)
		assert_almost_eq(Config.data.shift_time, float(spec["shift_time"]), 0.0001,
			"%s: applies its own shift_time" % spec["name"])
		seen[float(spec["shift_time"])] = true
	assert_gt(seen.size(), 1, "cars use a range of shift times, not one shared value")


func test_every_car_applies_its_own_suspension() -> void:
	# Selecting a car overlays its spring travel + stiffness onto the live config
	# AND onto all four wheels (dampers re-derived from stiffness), so each car
	# rides on its own suspension rather than one shared global setup.
	var travels := {}
	var stiffnesses := {}
	for i in CarLibrary.CARS.size():
		var spec: Dictionary = CarLibrary.CARS[i]
		_select(i)
		await _wait(5)
		var travel: float = float(spec["suspension_travel"])
		var stiffness: float = float(spec["suspension_stiffness"])
		assert_almost_eq(Config.data.suspension_travel, travel, 0.0001,
			"%s: applies its own suspension_travel" % spec["name"])
		assert_almost_eq(Config.data.suspension_stiffness, stiffness, 0.0001,
			"%s: applies its own suspension_stiffness" % spec["name"])
		for wheel in _car.find_children("*", "VehicleWheel3D", false):
			assert_almost_eq(wheel.suspension_travel, travel, 0.0001,
				"%s: %s travel set" % [spec["name"], wheel.name])
			assert_almost_eq(wheel.wheel_rest_length, travel, 0.0001,
				"%s: %s rest length matches travel" % [spec["name"], wheel.name])
			assert_almost_eq(wheel.suspension_stiffness, stiffness, 0.0001,
				"%s: %s stiffness set" % [spec["name"], wheel.name])
			assert_almost_eq(wheel.damping_compression, sqrt(stiffness), 0.0001,
				"%s: %s compression damper derived from stiffness" % [spec["name"], wheel.name])
			assert_almost_eq(wheel.damping_relaxation, 1.5 * sqrt(stiffness), 0.0001,
				"%s: %s rebound damper derived from stiffness" % [spec["name"], wheel.name])
		travels[travel] = true
		stiffnesses[stiffness] = true
	assert_gt(travels.size(), 1, "cars use a range of spring travels, not one shared value")
	assert_gt(stiffnesses.size(), 1, "cars use a range of spring rates, not one shared value")


func test_every_car_applies_its_own_engine_volume() -> void:
	# Selecting a car overlays its engine volume_db onto the live config, so each
	# car's engine voice plays at its own master level rather than one global one.
	var seen := {}
	for i in CarLibrary.CARS.size():
		var spec: Dictionary = CarLibrary.CARS[i]
		_select(i)
		await _wait(5)
		assert_almost_eq(Config.data.engine_volume_db, float(spec["volume_db"]), 0.0001,
			"%s: applies its own engine volume_db" % spec["name"])
		seen[float(spec["volume_db"])] = true
	assert_gt(seen.size(), 1, "cars use a range of engine volumes, not one shared value")


func test_every_car_applies_its_own_noise_level() -> void:
	# Selecting a car overlays its per-car noise floor (authored in dB) onto the
	# live config as a linear amplitude, so each car controls its white-noise
	# input to the soft clipper independently of the engine voice. Cars are
	# initialised to a shared placeholder, so we assert the overlay happens.
	for i in CarLibrary.CARS.size():
		var spec: Dictionary = CarLibrary.CARS[i]
		_select(i)
		await _wait(5)
		assert_almost_eq(Config.data.engine_noise_level, db_to_linear(float(spec["noise_db"])), 0.0001,
			"%s: applies its own noise_db as a linear noise level" % spec["name"])


func test_every_car_applies_its_own_soft_clip_post_gain() -> void:
	# The soft clipper's post-amp is per-car (its pre-amp / drive stays global),
	# so selecting a car overlays its soft_clip_post_gain onto the live config.
	for i in CarLibrary.CARS.size():
		var spec: Dictionary = CarLibrary.CARS[i]
		_select(i)
		await _wait(5)
		assert_almost_eq(Config.data.engine_soft_clip_post_gain, float(spec["soft_clip_post_gain"]), 0.0001,
			"%s: applies its own soft_clip_post_gain" % spec["name"])
