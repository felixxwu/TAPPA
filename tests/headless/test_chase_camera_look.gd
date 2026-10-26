extends GutTest
# Chase camera free look (chase_camera.gd -> _input / look_by / _update_look). Mouse, a touch drag
# off the on-screen controls, or the right stick swivels the camera round the car on top of the
# follow direction; with no look input the swivel eases back to 0; only while the chase cam is in use.

const DT := 1.0 / 60.0

var _cam: Camera3D
var _target: Node3D
var _controls: Node


# Stands in for MobileControls: everything left of x = 100 is a control.
class Controls extends Node:
	func owns_point(pos: Vector2) -> bool:
		return pos.x < 100.0


func before_each() -> void:
	_target = Node3D.new()
	add_child(_target)
	_controls = Controls.new()
	add_child(_controls)
	_cam = load("res://scripts/chase_camera.gd").new()
	_cam.target = _target
	_cam.mobile_controls = _controls
	add_child(_cam)
	_cam.set_physics_process(false)
	_cam.make_current()
	_cam._height_ratio = 0.2  # well under 1, so the camera sits off to one side of the car


func after_each() -> void:
	_cam.free()
	_controls.free()
	_target.free()


# The camera's horizontal direction from the car.
func _offset_dir() -> Vector3:
	var d := _cam.global_position - _target.global_position
	d.y = 0.0
	return d.normalized()


func _tick(n: int, keep_looking := false) -> void:
	for i in n:
		if keep_looking:
			_cam.look_by(0.0)
		_cam._timed_physics_process(DT)


func test_with_no_look_the_camera_sits_behind_the_car() -> void:
	_tick(1)
	# The bare Node3D faces -Z, so behind it is +Z.
	assert_almost_eq(_offset_dir().dot(Vector3.BACK), 1.0, 0.001)


func test_a_swivel_moves_the_camera_round_the_car() -> void:
	_tick(1)
	_cam.look_by(PI * 0.5)
	_tick(1)
	assert_almost_eq(_offset_dir().dot(Vector3.BACK.rotated(Vector3.UP, PI * 0.5)), 1.0, 0.001)


func test_the_swivel_adds_to_the_follow_direction() -> void:
	_cam.look_by(PI * 0.5)
	_target.rotate_y(PI * 0.5)  # now facing -X, so behind it is +X
	_tick(600, true)
	var behind := Vector3.RIGHT
	assert_almost_eq(_offset_dir().dot(behind.rotated(Vector3.UP, PI * 0.5)), 1.0, 0.01,
			"the camera follows the car's new heading and keeps the swivel on top")


func test_the_swivel_holds_briefly_then_returns_to_zero() -> void:
	_cam.look_by(1.0)
	_tick(1)
	assert_almost_eq(_cam._look_yaw, 1.0, 0.001, "held right after the input")
	_tick(int((_cam._look_hold + 5.0) / DT))
	assert_almost_eq(_cam._look_yaw, 0.0, 0.01, "eased back to the default view")


func test_mouse_motion_right_turns_the_view_right() -> void:
	var e := InputEventMouseMotion.new()
	e.relative = Vector2(50.0, 0.0)
	_cam._input(e)
	assert_lt(_cam._look_yaw, 0.0, "a negative yaw turns the look direction clockwise (right)")


func test_mouse_motion_synthesised_from_a_touch_is_ignored() -> void:
	var e := InputEventMouseMotion.new()
	e.device = InputEvent.DEVICE_ID_EMULATION
	e.relative = Vector2(50.0, 0.0)
	_cam._input(e)
	assert_eq(_cam._look_yaw, 0.0)


func _touch(index: int, pos: Vector2, pressed: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = index
	e.position = pos
	e.pressed = pressed
	_cam._input(e)


func _drag(index: int, rel: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = index
	e.relative = rel
	_cam._input(e)


func test_a_drag_off_the_controls_swivels_and_holds_while_the_finger_is_down() -> void:
	_touch(0, Vector2(500.0, 300.0), true)
	_drag(0, Vector2(40.0, 0.0))
	var yaw: float = _cam._look_yaw
	assert_lt(yaw, 0.0, "drag right turns the view right")
	_tick(int((_cam._look_hold + 2.0) / DT))
	assert_almost_eq(_cam._look_yaw, yaw, 0.001, "a finger still down keeps the swivel")
	_touch(0, Vector2(540.0, 300.0), false)
	_tick(int((_cam._look_hold + 5.0) / DT))
	assert_almost_eq(_cam._look_yaw, 0.0, 0.01, "lifting it lets the view return")


func test_a_drag_on_the_controls_does_not_look() -> void:
	_touch(1, Vector2(50.0, 300.0), true)
	_drag(1, Vector2(40.0, 0.0))
	assert_eq(_cam._look_yaw, 0.0)


func test_no_look_while_another_camera_is_in_use() -> void:
	var other := Camera3D.new()
	add_child(other)
	other.make_current()
	var e := InputEventMouseMotion.new()
	e.relative = Vector2(50.0, 0.0)
	_cam._input(e)
	_tick(1)
	assert_eq(_cam._look_yaw, 0.0)
	other.free()
