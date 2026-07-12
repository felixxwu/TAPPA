extends GutTest
# BushField: the proximity interaction that makes brushing a (pass-through) bush apply a
# small speed-scaled DRAG IMPULSE + a side-based yaw drag torque. The drag's deceleration
# feeds the unified damage rule (car._integrate_forces); the field no longer drains HP
# directly. Pure helper (drag_torque) and the enter/leave one-shot logic are exercised
# against a stub car — no scene / physics body needed. See scripts/bush_field.gd,
# features/damage.md.


# Minimal stand-in for the car: a Node3D (so it has global_transform) with the bits
# BushField reads — a DamageModel, a linear_velocity, and recording apply_torque_impulse /
# apply_soft_drag.
class FakeCar:
	extends Node3D
	var damage: DamageModel
	var linear_velocity := Vector3.ZERO
	var torque_calls: Array[Vector3] = []
	var soft_drag_calls := 0
	func apply_torque_impulse(t: Vector3) -> void:
		torque_calls.append(t)
	func apply_soft_drag(strength: float) -> void:
		soft_drag_calls += 1
		var v_h := Vector3(linear_velocity.x, 0.0, linear_velocity.z)
		linear_velocity -= v_h * clampf(strength, 0.0, 1.0)


func _make_car(hp := 1000.0, speed_mps := 20.0) -> FakeCar:
	var car := FakeCar.new()
	car.damage = DamageModel.new()
	car.damage.field(hp, hp)
	car.linear_velocity = Vector3(0, 0, -speed_mps)  # driving forward at speed
	add_child_autofree(car)
	return car


func _place(car: FakeCar, x: float, z: float) -> void:
	# Face -Z (forward), positioned at (x, z) in world XZ.
	car.global_transform = Transform3D(Basis.IDENTITY, Vector3(x, 0.0, z))


# --- drag_torque (pure) ------------------------------------------------------

func test_drag_torque_sign_is_side_based() -> void:
	var fwd := Vector2(0, -1)  # car facing -Z
	# Bush off to the car's RIGHT (+X) swings the nose right (negative Y torque);
	# bush to the LEFT (-X) swings it left (positive) — opposite signs.
	var right := BushField.drag_torque(fwd, Vector2(1, 0), 100.0)
	var left := BushField.drag_torque(fwd, Vector2(-1, 0), 100.0)
	assert_lt(right, 0.0, "a bush on the right yaws the nose toward it (negative Y torque)")
	assert_gt(left, 0.0, "a bush on the left yaws the nose the other way")
	assert_almost_eq(right, -left, 1e-6, "mirror-image bushes give equal-and-opposite torque")


func test_drag_torque_zero_head_on_and_scales_with_magnitude() -> void:
	var fwd := Vector2(0, -1)
	assert_almost_eq(BushField.drag_torque(fwd, Vector2(0, -1), 100.0), 0.0, 1e-6,
		"a bush dead ahead barely twists the car")
	# Peaks at a right-angle; magnitude scales linearly.
	var m1 := absf(BushField.drag_torque(fwd, Vector2(1, 0), 100.0))
	var m2 := absf(BushField.drag_torque(fwd, Vector2(1, 0), 200.0))
	assert_almost_eq(m2, m1 * 2.0, 1e-6, "torque scales with the magnitude coefficient")


func test_drag_torque_zero_on_degenerate_input() -> void:
	assert_eq(BushField.drag_torque(Vector2.ZERO, Vector2(1, 0), 100.0), 0.0, "no forward → no torque")
	assert_eq(BushField.drag_torque(Vector2(0, -1), Vector2.ZERO, 100.0), 0.0, "bush on top → no torque")


# --- proximity / one-shot ----------------------------------------------------

func _field(car: FakeCar) -> BushField:
	var bf := BushField.new()
	# One bush at the origin, hit radius 1 m, drag strength 0.04, torque coeff 60/(m/s),
	# 5 km/h min speed.
	bf.setup(PackedVector2Array([Vector2(0, 0)]), car, 1.0, 0.04, 60.0, 5.0 / DamageModel.MPS_TO_KMH)
	add_child_autofree(bf)
	return bf


func test_entering_a_bush_applies_drag_and_torque_once() -> void:
	var car := _make_car()
	var bf := _field(car)
	_place(car, 0.5, 0.0)  # inside the 1 m radius, off to the right of a -Z heading
	bf._physics_process(1.0 / 60.0)
	assert_eq(car.soft_drag_calls, 1, "entering the bush sheds a little speed (soft drag)")
	assert_eq(car.torque_calls.size(), 1, "a drag torque is applied on entry")
	assert_ne(car.torque_calls[0].y, 0.0, "the applied torque has a yaw component")
	# Staying inside the same bush does NOT re-apply.
	bf._physics_process(1.0 / 60.0)
	assert_eq(car.soft_drag_calls, 1, "sitting in the bush is not a fresh hit")
	assert_eq(car.torque_calls.size(), 1, "no extra torque while still inside")


func test_leaving_and_re_entering_re_arms() -> void:
	var car := _make_car()
	var bf := _field(car)
	_place(car, 0.5, 0.0)
	bf._physics_process(1.0 / 60.0)
	assert_eq(car.soft_drag_calls, 1, "first entry applies drag")
	_place(car, 10.0, 0.0)  # well clear of the bush
	bf._physics_process(1.0 / 60.0)
	assert_eq(car.soft_drag_calls, 1, "no drag while away")
	_place(car, 0.5, 0.0)   # back in
	bf._physics_process(1.0 / 60.0)
	assert_eq(car.soft_drag_calls, 2, "re-entering the bush applies drag again")


func test_below_min_speed_does_not_drag_or_tug() -> void:
	var car := _make_car(1000.0, 0.5)  # crawling, under the 5 km/h floor
	var bf := _field(car)
	_place(car, 0.5, 0.0)
	bf._physics_process(1.0 / 60.0)
	assert_eq(car.soft_drag_calls, 0, "a crawl through a bush sheds no speed")
	assert_eq(car.torque_calls.size(), 0, "and applies no drag torque")


func test_far_from_any_bush_is_a_noop() -> void:
	var car := _make_car()
	var bf := _field(car)
	_place(car, 50.0, 50.0)
	bf._physics_process(1.0 / 60.0)
	assert_eq(car.soft_drag_calls, 0, "no bush nearby → no drag")
	assert_eq(car.torque_calls.size(), 0, "and no torque")
