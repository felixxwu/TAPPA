extends SimTest
# The countdown hold: while StageManager holds the car on the line
# (`handbrake_locked`, see features/stage.md), the car must sit STILL — it must not
# ring back and forth, and it must not rotate away from the direction it was placed
# facing. Both were reported from real play: a visible vibration during 3·2·1, and a
# car that could be pointing the wrong way by GO.
#
# These assert BEHAVIOUR that must hold for any reasonable tuning of
# parking_hold_stiffness / parking_hold_damping / parking_hold_grip — never a
# specific displacement or a specific damping number. A designer retuning the hold
# should not be able to make these fail without genuinely reintroducing the bug.

const NUDGE_FRAMES := 120  # 2 s at 60 Hz — long enough for ringing to show


func before_each() -> void:
	await setup_settled_car()
	_car.handbrake_locked = true
	await _wait_physics(10)


# Count how many times the car crosses back over its own anchor: a critically (or
# over-) damped hold overshoots at most once, an under-damped one oscillates.
func _sign_changes_after_nudge(impulse: Vector3) -> int:
	var anchor := _car.global_position
	_car.apply_central_impulse(impulse)
	var crossings := 0
	var last_sign := 0
	for i in NUDGE_FRAMES:
		await get_tree().physics_frame
		var offset := _car.global_position - anchor
		offset.y = 0.0
		if offset.length() < 0.01:
			continue  # inside the noise floor; no meaningful side to be on
		var s: int = signi(int(signf(offset.dot(impulse.normalized()))))
		if last_sign != 0 and s != 0 and s != last_sign:
			crossings += 1
		if s != 0:
			last_sign = s
	return crossings


func test_a_held_car_does_not_oscillate_after_a_nudge() -> void:
	# A shove the size of a settling jolt. The hold must absorb it, not ring on it:
	# more than one crossing back over the anchor IS the vibration the player sees.
	var crossings := await _sign_changes_after_nudge(Vector3(1.0, 0.0, 0.0) * _car.mass * 2.0)
	assert_lte(crossings, 1,
		"the hold absorbs a nudge instead of ringing (crossings=%d)" % crossings)


func test_a_held_car_holds_its_heading() -> void:
	# Yaw was completely unconstrained by the hold, which only ever anchored
	# POSITION — so anything that turned the car (a kerb, a steering input, an
	# uneven surface) left it pointing somewhere else by GO, with nothing to
	# recover it.
	var heading := _car.global_transform.basis.z
	_car.apply_torque_impulse(Vector3(0.0, 1.0, 0.0) * _car.mass * 2.0)
	await _wait_physics(NUDGE_FRAMES)
	var drift := rad_to_deg(absf(heading.signed_angle_to(_car.global_transform.basis.z,
		Vector3.UP)))
	assert_lt(drift, 5.0, "the car still faces where it was placed (drift=%.1f deg)" % drift)


func test_the_hold_still_releases() -> void:
	# The guard against over-correcting the above: a held car that can never be
	# moved again would break the launch. Once the hold is off, the car is free.
	_car.handbrake_locked = false
	_car.apply_central_impulse(Vector3(1.0, 0.0, 0.0) * _car.mass * 5.0)
	await _wait_physics(30)
	assert_gt(_car.linear_velocity.length(), 0.5, "released, the car moves freely")
