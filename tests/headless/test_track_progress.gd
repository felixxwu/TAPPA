extends GutTest
# TrackProgress: monotonic progress along the road centerline + the off-track
# reset. Driven against a Curve2D built directly here with a stub car, so the
# math is tested without the full scene. See todo/track-progress-and-reset.md.


# Minimal stand-in for the Car: exposes global_transform (read for position) and
# records reset_to() calls so the off-track reset can be asserted.
class StubCar:
	extends Node3D
	var reset_calls: Array = []
	var linear_velocity := Vector3.ZERO   # read by the stuck watchdog
	var throttling := false                # is_throttling() return
	func reset_to(xform: Transform3D) -> void:
		reset_calls.append(xform)
	func is_throttling() -> bool:
		return throttling


var _car: StubCar
var _curve: Curve2D


func before_each() -> void:
	Config.reset()
	# A straight road 100 m along +Z (curve points are Vector2(world_x, world_z)).
	_curve = Curve2D.new()
	_curve.add_point(Vector2(0, 0))
	_curve.add_point(Vector2(0, 100))
	_car = StubCar.new()
	add_child_autofree(_car)  # global_transform requires being in the tree


func after_each() -> void:
	Config.reset()


func _make_progress() -> TrackProgress:
	var tp := TrackProgress.new()
	add_child_autofree(tp)
	tp.setup(_curve, _car, null)  # null terrain -> ground height 0
	return tp


func _put_car(x: float, z: float) -> void:
	_car.transform.origin = Vector3(x, 0.0, z)


func test_progress_advances_on_road_and_is_monotonic() -> void:
	_put_car(0, 0)
	var tp := _make_progress()
	_put_car(0, 10)
	tp._physics_process(0.0)
	assert_almost_eq(tp.progress_offset(), 10.0, 0.5, "progress advances to ~10 m")
	_put_car(0, 30)
	tp._physics_process(0.0)
	assert_almost_eq(tp.progress_offset(), 30.0, 0.5, "progress advances to ~30 m")
	# Driving backwards must NOT lower the recorded progress.
	_put_car(0, 20)
	tp._physics_process(0.0)
	assert_almost_eq(tp.progress_offset(), 30.0, 0.5, "backward travel does not reduce progress")


func test_jump_to_finish_pins_progress_to_100_percent() -> void:
	# The dev skip-to-finish cheat: jump_to_finish() pins progress to the end of the
	# curve (100%) and returns the finish pose, without needing the car to be there.
	_put_car(0, 0)
	var tp := _make_progress()
	assert_almost_eq(tp.progress_percent(), 0.0, 0.001, "starts at 0%")
	var pose := tp.jump_to_finish()
	assert_almost_eq(tp.progress_percent(), 1.0, 0.001, "progress pinned to 100%")
	assert_almost_eq(tp.progress_offset(), tp.baked_length(), 0.5, "offset at the finish")
	# The returned pose sits on the road at the end of the curve (~z = 100).
	assert_almost_eq(pose.origin.z, 100.0, 1.0, "finish pose is at the end of the road")


func test_progress_reaches_100_percent_at_finish_offset_before_curve_end() -> void:
	# Curve is 100 m long (before_each), but the finish is at 60 m: the last 40 m is
	# runoff road the car rolls into after finishing.
	_put_car(0, 0)
	var tp := TrackProgress.new()
	add_child_autofree(tp)
	tp.setup(_curve, _car, null, 60.0)
	assert_almost_eq(tp.progress_percent(), 0.0, 0.001, "starts at 0%")
	# Drive to the finish offset (~60 m): progress is 100% even though road continues.
	_put_car(0, 60)
	tp._physics_process(0.0)
	assert_almost_eq(tp.progress_percent(), 1.0, 0.01,
		"reaching the finish offset reads 100% though the curve extends further")


func test_jump_to_finish_uses_the_finish_offset() -> void:
	_put_car(0, 0)
	var tp := TrackProgress.new()
	add_child_autofree(tp)
	tp.setup(_curve, _car, null, 60.0)
	var pose := tp.jump_to_finish()
	assert_almost_eq(tp.progress_percent(), 1.0, 0.001, "jump pins to 100% at the finish")
	assert_almost_eq(pose.origin.z, 60.0, 1.0, "finish pose is at the finish offset, not the curve end")


func test_progress_gated_by_distance() -> void:
	_put_car(0, 0)
	var tp := _make_progress()
	# Far along the road but well outside the lateral threshold (x = 40 m > 25 m).
	_put_car(40, 50)
	tp._physics_process(0.0)
	assert_almost_eq(tp.progress_offset(), 0.0, 0.5, "off-road position does not advance progress")


func test_wide_tolerance_keeps_running_wide_on_track() -> void:
	# The reset tolerance is deliberately generous (rally): running wide onto the
	# verge (x = 15 m, inside the 25 m threshold) still counts as on-track — it
	# advances progress and does NOT snap back.
	_put_car(0, 0)
	var tp := _make_progress()
	_put_car(15, 40)
	tp._physics_process(0.0)
	assert_almost_eq(tp.progress_offset(), 40.0, 0.5, "running wide within tolerance still advances progress")
	assert_eq(_car.reset_calls.size(), 0, "no reset while within the wide tolerance")


func test_off_track_triggers_reset_to_last_progress_pose() -> void:
	_put_car(0, 0)
	var tp := _make_progress()
	_put_car(0, 30)  # progress to ~30 m, on-road
	tp._physics_process(0.0)
	_put_car(40, 30)  # stray well off-road (x = 40 m > 25 m)
	tp._physics_process(0.0)
	assert_eq(_car.reset_calls.size(), 1, "off-track stray triggers exactly one reset")
	var xform: Transform3D = _car.reset_calls[0]
	# XZ matches the centerline at the recorded progress (~0, ~30).
	assert_almost_eq(xform.origin.x, 0.0, 0.5, "reset X on the centerline")
	assert_almost_eq(xform.origin.z, 30.0, 0.5, "reset Z at recorded progress")
	# Lifted by spawn_clearance above ground (0 on the null-terrain fixture).
	assert_almost_eq(xform.origin.y, Config.data.spawn_clearance, 0.01, "reset lifted by spawn_clearance")
	# The car's forward (-Z) points down the road (+Z here).
	var forward := -xform.basis.z
	assert_almost_eq(forward, Vector3(0, 0, 1), Vector3(0.02, 0.02, 0.02), "reset faces along the road")


func test_off_track_reset_can_be_disabled() -> void:
	_put_car(0, 0)
	var tp := _make_progress()
	Config.data.off_track_reset_enabled = false
	_put_car(40, 30)  # well off-road (x = 40 m > 25 m)
	tp._physics_process(0.0)
	assert_eq(_car.reset_calls.size(), 0, "no reset fires when off_track_reset_enabled is false")


func test_progress_percent_tracks_fraction() -> void:
	_put_car(0, 0)
	var tp := _make_progress()
	_put_car(0, 50)
	tp._physics_process(0.0)
	assert_almost_eq(tp.progress_percent(), 0.5, 0.02, "halfway down a 100 m road ~= 0.5")


func test_progress_reads_zero_at_the_start_line_despite_the_lead_in() -> void:
	# The progress centerline includes a straight lead-in behind the start, so the
	# car spawns partway along the curve (here 20 m), not at the curve origin.
	# Progress must read 0% at that start line, not 20%.
	_put_car(0, 20)
	var tp := _make_progress()  # seeds the origin at the spawn (the start line)
	tp._physics_process(0.0)
	assert_almost_eq(tp.progress_percent(), 0.0, 0.01, "0% at the start line, not at the curve origin")
	# The far end of the curve is still the finish (100%).
	_put_car(0, 100)
	tp._physics_process(0.0)
	assert_almost_eq(tp.progress_percent(), 1.0, 0.01, "100% at the finish")


func test_mark_start_rezeros_progress_at_the_cars_position() -> void:
	# Any roll-up / settle before the off advances progress; mark_start() (called on
	# GO) re-anchors 0% to wherever the car is, so the off is always exactly 0%.
	_put_car(0, 0)
	var tp := _make_progress()
	_put_car(0, 30)
	tp._physics_process(0.0)
	assert_gt(tp.progress_percent(), 0.0, "progress accrued during the roll-up")
	tp.mark_start()
	assert_almost_eq(tp.progress_percent(), 0.0, 0.01, "mark_start re-zeros progress at the off")
	# Advancing further now counts from the new origin: (65-30)/(100-30) = 0.5.
	_put_car(0, 65)
	tp._physics_process(0.0)
	assert_almost_eq(tp.progress_percent(), 0.5, 0.05, "progress counts from the new start origin")


# --- Stuck-car recovery watchdog ---------------------------------------------

# Step the watchdog until it either resets or the wait elapses; returns whether it reset.
func _run_ticks(tp: TrackProgress, seconds: float, dt := 0.5) -> bool:
	var before: int = _car.reset_calls.size()
	var t := 0.0
	while t < seconds:
		tp._physics_process(dt)
		if _car.reset_calls.size() > before:
			return true
		t += dt
	return false


func test_flooring_it_and_going_nowhere_recovers() -> void:
	# Stationary + throttle held → recovers after the timeout.
	_put_car(0, 20)
	var tp := _make_progress()
	_car.linear_velocity = Vector3.ZERO
	_car.throttling = true
	assert_true(_run_ticks(tp, Config.data.recovery_timeout_s + 1.0),
		"a car flooring it and going nowhere auto-recovers")


func test_does_not_recover_before_the_timeout() -> void:
	_put_car(0, 20)
	var tp := _make_progress()
	_car.linear_velocity = Vector3.ZERO
	_car.throttling = true
	# Just under the timeout: no reset yet.
	assert_false(_run_ticks(tp, Config.data.recovery_timeout_s - 0.6, 0.5),
		"no recovery before the stuck timeout elapses")


func test_flipped_car_recovers() -> void:
	_put_car(0, 20)
	var tp := _make_progress()
	_car.linear_velocity = Vector3.ZERO
	_car.throttling = false
	# Roll it onto its roof: up-vector points down.
	_car.global_transform = Transform3D(Basis(Vector3(1, 0, 0), PI), Vector3(0, 0, 20))
	assert_true(_run_ticks(tp, Config.data.recovery_timeout_s + 1.0),
		"a flipped, stationary car auto-recovers even with no throttle")


func test_car_in_a_pit_recovers_without_throttle() -> void:
	_put_car(0, 20)
	var tp := _make_progress()  # null terrain → road height 0
	_car.linear_velocity = Vector3.ZERO
	_car.throttling = false
	# Well below the road surface (0) − recovery_depth_m.
	_car.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, -Config.data.recovery_depth_m - 5.0, 20))
	assert_true(_run_ticks(tp, Config.data.recovery_timeout_s + 1.0),
		"a car fallen into a pit auto-recovers even with no input")


func test_parked_upright_on_road_never_recovers() -> void:
	# Stationary but upright, on the road, not throttling → leave it. Covers both a
	# player who just stopped AND a car deliberately held at the line (staging /
	# countdown): a held car reports is_throttling() == false (see Car.is_held), so
	# from the watchdog's view it is indistinguishable from a parked car and must
	# never be auto-reset. (Regression: revving through the countdown once fired it.)
	_put_car(0, 20)
	var tp := _make_progress()
	_car.linear_velocity = Vector3.ZERO
	_car.throttling = false
	assert_false(_run_ticks(tp, Config.data.recovery_timeout_s + 2.0),
		"a deliberately parked car is never auto-reset")


func test_moving_car_never_recovers() -> void:
	# Even flooring it, a car that's actually moving is not stuck.
	_put_car(0, 20)
	var tp := _make_progress()
	_car.linear_velocity = Vector3(0, 0, 5.0)  # driving
	_car.throttling = true
	assert_false(_run_ticks(tp, Config.data.recovery_timeout_s + 2.0),
		"a moving car is never treated as stuck")


func test_recovery_disabled_never_recovers() -> void:
	Config.data.recovery_enabled = false
	_put_car(0, 20)
	var tp := _make_progress()
	_car.linear_velocity = Vector3.ZERO
	_car.throttling = true
	assert_false(_run_ticks(tp, Config.data.recovery_timeout_s + 2.0),
		"no auto-recovery when the watchdog is disabled")


func test_recovery_target_is_the_last_on_road_pose() -> void:
	_put_car(0, 20)
	var tp := _make_progress()
	tp._physics_process(0.0)  # bank progress + _best_reset at ~20 m
	var expected := tp._reset_xform_at(20.0)
	_car.linear_velocity = Vector3.ZERO
	_car.throttling = true
	assert_true(_run_ticks(tp, Config.data.recovery_timeout_s + 1.0), "recovers")
	var got: Transform3D = _car.reset_calls[-1]
	assert_almost_eq(got.origin, expected.origin, Vector3.ONE * 0.5,
		"recovery teleports to the last on-road pose, not the start")


func _hairpin_curve() -> Curve2D:
	# Out along +Z to z=50, a short neck across to x=6, then back down to z=0.
	# Arc length ~= 50 + 6 + 50 = ~106 m; the two legs sit 6 m apart at the neck.
	var c := Curve2D.new()
	c.add_point(Vector2(0, 0))
	c.add_point(Vector2(0, 50))
	c.add_point(Vector2(6, 50))
	c.add_point(Vector2(6, 0))
	return c


func _progress_on(curve: Curve2D) -> TrackProgress:
	var tp := TrackProgress.new()
	add_child_autofree(tp)
	tp.setup(curve, _car, null)
	return tp


func test_clean_straight_drive_bills_no_cut() -> void:
	# Realistic per-tick motion: the nearest-point offset advances only a little
	# each tick, so no tick's jump reaches cut_jump_threshold_m — no cut.
	_put_car(0, 0)
	var tp := _make_progress()   # straight 100 m curve from before_each
	var z := 0.0
	while z < 90.0:
		z += 0.5                 # small step, well under the jump threshold
		_put_car(0, z)
		tp._physics_process(0.0)
	assert_almost_eq(tp.cut_excess_m(), 0.0, 0.001, "no excess on a clean straight")
	assert_almost_eq(tp.cut_penalty_s(), 0.0, 0.001, "no penalty on a clean straight")


func test_cutting_the_neck_bills_the_stolen_metres() -> void:
	var curve := _hairpin_curve()
	_put_car(0, 0)
	var tp := _progress_on(curve)
	# Drive a little up the entry leg (legit), then in ONE tick the nearest point
	# flips across the neck to the exit leg — a huge single-tick progress jump.
	_put_car(0, 5)
	tp._physics_process(0.0)
	var before := tp.cut_excess_m()
	assert_almost_eq(before, 0.0, 0.001, "legit travel up the entry leg bills nothing")
	_put_car(6, 3)   # nearest offset leaps from ~5 to ~103 in a single tick
	tp._physics_process(0.0)
	var stolen := tp.cut_excess_m()
	assert_gt(stolen, 50.0, "cutting the neck bills a large chunk of stolen metres")
	# Penalty is exactly the stolen metres over the (config) reference speed.
	assert_almost_eq(tp.cut_penalty_s(),
		stolen / Config.data.cut_reference_speed_mps, 0.001,
		"penalty = stolen metres / reference speed")


func test_cut_penalty_disabled_never_bills() -> void:
	Config.data.cut_penalty_enabled = false
	var curve := _hairpin_curve()
	_put_car(0, 5)
	var tp := _progress_on(curve)
	_put_car(6, 3)
	tp._physics_process(0.0)
	assert_almost_eq(tp.cut_penalty_s(), 0.0, 0.001, "disabled -> no penalty")


func test_setup_resets_accumulated_excess() -> void:
	var curve := _hairpin_curve()
	_put_car(0, 5)
	var tp := _progress_on(curve)
	_put_car(6, 3)
	tp._physics_process(0.0)
	assert_gt(tp.cut_excess_m(), 0.0, "excess accumulated")
	tp.setup(curve, _car, null)   # re-arm for a new event
	assert_almost_eq(tp.cut_excess_m(), 0.0, 0.001, "setup clears excess")
