extends GutTest
# TrackProgress: monotonic progress along the road centerline + the off-track
# reset. Driven against a Curve2D built directly here with a stub car, so the
# math is tested without the full scene. See todo/track-progress-and-reset.md.

const TrackProgress = preload("res://scripts/track_progress.gd")


# Minimal stand-in for the Car: exposes global_transform (read for position) and
# records reset_to() calls so the off-track reset can be asserted.
class StubCar:
	extends Node3D
	var reset_calls: Array = []
	func reset_to(xform: Transform3D) -> void:
		reset_calls.append(xform)


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
