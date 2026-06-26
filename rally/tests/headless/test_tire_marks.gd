extends GutTest
# TireMarks: gravel ruts laid behind the wheels (todo/tire-marks.md). Driven
# against a straight Curve2D with a stub car + stub wheels, so the gating /
# emission / ring-buffer logic is tested without a real vehicle or rendering.

const TireMarks = preload("res://scripts/tire_marks.gd")


# Stub wheel: duck-typed like VehicleWheel3D (is_in_contact + global_position).
class StubWheel:
	extends Node3D
	var _contact := true
	func is_in_contact() -> bool:
		return _contact


# Stub car: just the bits TireMarks reads — a velocity and a position.
class StubCar:
	extends Node3D
	var linear_velocity := Vector3(0, 0, 10.0)  # moving, above the speed floor


var _car: StubCar
var _curve: Curve2D
var _wheels: Array = []


func before_each() -> void:
	Config.reset()
	Config.data.tire_marks_enabled = true
	# A straight road 200 m along +Z (curve points are Vector2(world_x, world_z)).
	_curve = Curve2D.new()
	_curve.add_point(Vector2(0, 0))
	_curve.add_point(Vector2(0, 200))
	_car = StubCar.new()
	add_child_autofree(_car)
	_wheels = []
	for i in 4:
		var w := StubWheel.new()
		_car.add_child(w)  # in-tree so global_position resolves
		_wheels.append(w)


func after_each() -> void:
	Config.reset()


func _make(half_width := 3.0) -> TireMarks:
	var tm := TireMarks.new()
	add_child_autofree(tm)
	tm.setup(_curve, _car, null, half_width)  # null terrain -> ground height 0
	return tm


# Drive the car (and its wheels) to world z and tick. Wheels are children of the
# car, so each wheel's local x with the car at z puts it at world (x, 0, z) — car
# and wheels advance together (the gravel gate searches the centerline around the
# CAR's offset, so the wheels must stay near the car, as in real play). `xs` is the
# per-wheel lateral offset from the centerline; pass fewer to leave wheels at 0.
func _drive(tm: TireMarks, z: float, xs: Array) -> void:
	_car.position = Vector3(0.0, 0.0, z)
	for i in _wheels.size():
		var x: float = xs[i] if i < xs.size() else 0.0
		_wheels[i].position = Vector3(x, 0.0, 0.0)  # local; world == (x, 0, z)
	tm._physics_process(0.0)


func test_collects_four_wheels() -> void:
	var tm := _make()
	assert_eq(tm.wheel_count(), 4, "one ribbon per wheel")


func test_marks_accumulate_on_gravel() -> void:
	var tm := _make()
	# Wheels straddle the centerline (|x| <= 3.3 gate) — on the gravel — advancing
	# 1 m per tick (> the 0.5 m segment step).
	for s in 6:
		_drive(tm, s, [-0.8, 0.8, -0.8, 0.8])
	for i in 4:
		assert_gt(tm.segment_count(i), 1, "wheel %d lays a ribbon on the gravel" % i)


func test_no_marks_off_the_gravel() -> void:
	var tm := _make()
	# Wheels far to the side (x = 10 m > 3.3 gate) while the car drives the road.
	for s in 6:
		_drive(tm, s, [10.0, 10.0, 10.0, 10.0])
	for i in 4:
		assert_eq(tm.segment_count(i), 0, "wheel %d off the gravel lays no marks" % i)


func test_corner_wheel_on_road_ahead_still_marks() -> void:
	# Curved road: up +Z to (0,40), then a 90-degree turn running +X. A wheel that's
	# on the post-bend road but well ahead of the car along the curve must still mark
	# — it's gated by ITS OWN nearest road point (distance 0 here), not the car's
	# tangent (against which it reads ~5 m off-axis and would be wrongly rejected).
	var curve := Curve2D.new()
	curve.add_point(Vector2(0, 0))
	curve.add_point(Vector2(0, 40))
	curve.add_point(Vector2(40, 40))
	var tm := TireMarks.new()
	add_child_autofree(tm)
	tm.setup(curve, _car, null, 3.0)
	_car.position = Vector3(0, 0, 35)            # just before the bend
	_wheels[0].global_position = Vector3(5, 0, 40)  # on the post-bend road, 5 m along +X
	tm._physics_process(0.0)
	assert_gt(tm.segment_count(0), 0, "a wheel on the road ahead of the bend still marks")


func test_sub_step_movement_adds_no_segment() -> void:
	var tm := _make()
	_drive(tm, 0.0, [])           # first point
	var after_first := tm.segment_count(0)
	_drive(tm, 0.1, [])           # moved 0.1 m < 0.5 m step
	assert_eq(tm.segment_count(0), after_first, "no new segment until the wheel moves a full step")


func test_ring_buffer_caps_segments() -> void:
	Config.data.tire_mark_max_segments = 5
	var tm := _make()
	for s in 50:
		_drive(tm, s, [])
	assert_eq(tm.segment_count(0), 5, "the per-wheel ribbon is capped to max_segments")


func test_below_min_speed_lays_nothing() -> void:
	var tm := _make()
	_car.linear_velocity = Vector3(0, 0, 0.5)  # below the 2 m/s floor
	for s in 6:
		_drive(tm, s, [])
	assert_eq(tm.segment_count(0), 0, "no marks below the speed floor")


func test_pressure_darkens_the_mark_under_load() -> void:
	var tm := _make()
	var base: Color = Config.data.tire_mark_color
	var heavy: Color = Config.data.tire_mark_color_heavy
	var static_load := 3000.0
	assert_eq(tm._blend_for_load(static_load, static_load), base, "static load -> light base colour")
	assert_eq(tm._blend_for_load(static_load * Config.data.tire_mark_heavy_load_ratio, static_load), heavy,
		"heavy load (ratio x static) -> dark heavy colour")
	var mid: Color = tm._blend_for_load(static_load * 1.5, static_load)  # ratio 2 -> t = 0.5
	assert_lt(mid.r, base.r, "partial load is darker than the base")
	assert_gt(mid.r, heavy.r, "partial load is lighter than full heavy load")
	assert_eq(tm._blend_for_load(0.0, static_load), base, "no force (no drivetrain) -> base colour")


func test_airborne_wheel_stops_marking() -> void:
	var tm := _make()
	_drive(tm, 0.0, [])
	_drive(tm, 1.0, [])
	var before := tm.segment_count(0)
	_wheels[0]._contact = false  # lift the wheel off the ground
	_drive(tm, 2.0, [])
	assert_eq(tm.segment_count(0), before, "an airborne wheel lays no new segment")
