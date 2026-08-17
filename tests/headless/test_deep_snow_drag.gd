extends GutTest
# Deep-snow ploughing drag, applied PER WHEEL so lopsided burial drags the car round
# (features/snow-region.md). Drivetrain.deep_snow_force is the whole rule, pure and static,
# so everything here runs without a physics scene, a car or a terrain.
#
# Nothing here pins snow_deep_drag: every coefficient is supplied by the test. What is
# asserted is the SHAPE of the rule — feather, symmetry, magnitude conservation — which
# must hold for any value a designer picks.

# A representative wheel layout: half-track 0.8 m, half-wheelbase 1.2 m, hub 0.3 m below
# the chassis centre. Contact offsets are all that the rule reads about geometry.
const FL := Vector3(-0.8, -0.3, -1.2)
const FR := Vector3(0.8, -0.3, -1.2)
const RL := Vector3(-0.8, -0.3, 1.2)
const RR := Vector3(0.8, -0.3, 1.2)

const PER_WHEEL := 25.0
const V := Vector3(0.0, 0.0, 20.0)  # 20 m/s straight down the car's rearward axis


# --- The feather -------------------------------------------------------------


func test_a_wheel_fully_on_the_road_never_ploughs() -> void:
	assert_eq(Drivetrain.deep_snow_force(V, Vector3.ZERO, FL, 1.0, PER_WHEEL), Vector3.ZERO,
		"road weight 1.0 is fully on the road — there is no snow to plough")


func test_a_fully_buried_wheel_drags_against_its_motion() -> void:
	var f := Drivetrain.deep_snow_force(V, Vector3.ZERO, FL, 0.0, PER_WHEEL)
	assert_gt(f.length(), 0.0, "a buried wheel resists")
	assert_lt(f.normalized().dot(V.normalized()), -0.99, "and it resists OPPOSITE the motion")


# Feathered, not a hard edge: the bog has to ramp in across the same band the visual snow
# is drawn rising, or the physics and the picture disagree at the roadside.
func test_the_drag_ramps_smoothly_with_burial() -> void:
	var light := Drivetrain.deep_snow_force(V, Vector3.ZERO, FL, 0.75, PER_WHEEL).length()
	var half := Drivetrain.deep_snow_force(V, Vector3.ZERO, FL, 0.5, PER_WHEEL).length()
	var deep := Drivetrain.deep_snow_force(V, Vector3.ZERO, FL, 0.0, PER_WHEEL).length()
	assert_gt(half, light, "deeper burial drags harder")
	assert_gt(deep, half, "and deeper still harder again")


func test_a_stationary_car_is_not_pushed_by_the_snow() -> void:
	assert_eq(Drivetrain.deep_snow_force(Vector3.ZERO, Vector3.ZERO, FL, 0.0, PER_WHEEL),
		Vector3.ZERO, "ploughing resists motion; it cannot create it")


# --- Magnitude is conserved --------------------------------------------------


# The reason the coefficient is divided by the WHEEL COUNT: with the car evenly buried the
# total must equal the single central force this replaced, so snow_deep_drag keeps its
# existing meaning and the change is purely about asymmetry.
func test_four_evenly_buried_wheels_sum_to_the_old_central_force() -> void:
	var total := Vector3.ZERO
	for offset in [FL, FR, RL, RR]:
		total += Drivetrain.deep_snow_force(V, Vector3.ZERO, offset, 0.0, PER_WHEEL)
	var central := -V * (PER_WHEEL * 4.0)  # what one central force at the full coefficient gave
	assert_almost_eq(total.distance_to(central), 0.0, 0.001,
		"even burial must not change the car's straight-line deceleration")


# --- Asymmetry produces yaw --------------------------------------------------


# Net torque about the vertical axis, summed over a set of [offset, road_weight] pairs —
# the quantity that actually rotates the car.
func _yaw_torque(pairs: Array, ang_vel := Vector3.ZERO) -> float:
	var torque := Vector3.ZERO
	for p in pairs:
		var f: Vector3 = Drivetrain.deep_snow_force(V, ang_vel, p[0], p[1], PER_WHEEL)
		torque += (p[0] as Vector3).cross(f)
	return torque.y


func test_even_burial_produces_no_yaw() -> void:
	var torque := _yaw_torque([[FL, 0.0], [FR, 0.0], [RL, 0.0], [RR, 0.0]])
	assert_almost_eq(torque, 0.0, 0.001,
		"a car buried equally on both sides should be slowed, not turned")


func test_burying_one_side_yaws_the_car() -> void:
	# Left wheels in the drift, right wheels still on the road.
	var torque := _yaw_torque([[FL, 0.0], [RL, 0.0], [FR, 1.0], [RR, 1.0]])
	assert_gt(absf(torque), 0.001, "one side ploughing must drag the car round")


# The two sides must pull opposite ways — a rule that yawed the same direction whichever
# side was buried would be a sign error, and the magnitude test above would not catch it.
func test_the_two_sides_yaw_in_opposite_directions() -> void:
	var left := _yaw_torque([[FL, 0.0], [RL, 0.0], [FR, 1.0], [RR, 1.0]])
	var right := _yaw_torque([[FR, 0.0], [RR, 0.0], [FL, 1.0], [RL, 1.0]])
	assert_ne(signf(left), signf(right), "burying the other side must turn the car the other way")
	assert_almost_eq(left, -right, 0.001, "and by a mirrored amount")


# Burying only the FRONT wheels (or only the rear) is symmetric across the centreline, so
# it must slow the car without turning it — the yaw comes from left/right asymmetry alone.
func test_burying_one_axle_slows_without_yawing() -> void:
	var torque := _yaw_torque([[FL, 0.0], [FR, 0.0], [RL, 1.0], [RR, 1.0]])
	assert_almost_eq(torque, 0.0, 0.001, "an axle buried evenly should not turn the car")


# --- Spin damping ------------------------------------------------------------


# The force reads the velocity AT THE CONTACT, so a car already rotating has that rotation
# resisted too. Without this deep snow could start a slew and never arrest it.
func test_a_spinning_car_has_its_spin_damped() -> void:
	var spin := Vector3(0.0, 1.5, 0.0)  # yawing about the vertical axis
	var pairs := [[FL, 0.0], [FR, 0.0], [RL, 0.0], [RR, 0.0]]
	var torque := _yaw_torque(pairs, spin)
	assert_lt(torque, 0.0, "a car spinning one way must feel a torque the other way")
	# And the opposite spin must be resisted the opposite way.
	assert_gt(_yaw_torque(pairs, -spin), 0.0, "…and symmetrically for the opposite spin")


func test_contact_point_velocity_differs_from_chassis_velocity_under_rotation() -> void:
	var spin := Vector3(0.0, 1.5, 0.0)
	var spinning := Drivetrain.deep_snow_force(V, spin, FL, 0.0, PER_WHEEL)
	var straight := Drivetrain.deep_snow_force(V, Vector3.ZERO, FL, 0.0, PER_WHEEL)
	assert_gt(spinning.distance_to(straight), 0.001,
		"rotation must change what a given corner feels, or the drag is not really per-wheel")
