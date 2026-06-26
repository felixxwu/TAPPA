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


# Place a wheel at a world XZ. The car stays at the origin (its linear_velocity
# stub drives the speed gate independently), so a wheel's local position IS its
# world position — and the road frame, sampled at the car, stays at the origin
# with a constant normal along this straight road, so the lateral gate is just |x|.
func _put_wheel(i: int, x: float, z: float) -> void:
	_wheels[i].position = Vector3(x, 0.0, z)


func test_collects_four_wheels() -> void:
	var tm := _make()
	assert_eq(tm.wheel_count(), 4, "one ribbon per wheel")


func test_marks_accumulate_on_gravel() -> void:
	var tm := _make()
	# Wheels straddle the centerline (|x| <= 3.3 gate) — on the gravel — advancing
	# 1 m per tick (> the 0.5 m segment step).
	for s in 6:
		_put_wheel(0, -0.8, s); _put_wheel(1, 0.8, s); _put_wheel(2, -0.8, s); _put_wheel(3, 0.8, s)
		tm._physics_process(0.0)
	for i in 4:
		assert_gt(tm.segment_count(i), 1, "wheel %d lays a ribbon on the gravel" % i)


func test_no_marks_off_the_gravel() -> void:
	var tm := _make()
	# Wheels far to the side (x = 10 m > 3.3 gate).
	for s in 6:
		for i in 4:
			_put_wheel(i, 10.0, s)
		tm._physics_process(0.0)
	for i in 4:
		assert_eq(tm.segment_count(i), 0, "wheel %d off the gravel lays no marks" % i)


func test_sub_step_movement_adds_no_segment() -> void:
	var tm := _make()
	_put_wheel(0, 0, 0)
	tm._physics_process(0.0)           # first point
	var after_first := tm.segment_count(0)
	_put_wheel(0, 0, 0.1)
	tm._physics_process(0.0)           # moved 0.1 m < 0.5 m step
	assert_eq(tm.segment_count(0), after_first, "no new segment until the wheel moves a full step")


func test_ring_buffer_caps_segments() -> void:
	Config.data.tire_mark_max_segments = 5
	var tm := _make()
	for s in 50:
		_put_wheel(0, 0, s)
		tm._physics_process(0.0)
	assert_eq(tm.segment_count(0), 5, "the per-wheel ribbon is capped to max_segments")


func test_below_min_speed_lays_nothing() -> void:
	var tm := _make()
	_car.linear_velocity = Vector3(0, 0, 0.5)  # below the 2 m/s floor
	for s in 6:
		_put_wheel(0, 0, s)
		tm._physics_process(0.0)
	assert_eq(tm.segment_count(0), 0, "no marks below the speed floor")


func test_airborne_wheel_stops_marking() -> void:
	var tm := _make()
	_put_wheel(0, 0, 0); tm._physics_process(0.0)
	_put_wheel(0, 0, 1); tm._physics_process(0.0)
	var before := tm.segment_count(0)
	_wheels[0]._contact = false  # lift the wheel off the ground
	_put_wheel(0, 0, 2); tm._physics_process(0.0)
	assert_eq(tm.segment_count(0), before, "an airborne wheel lays no new segment")
