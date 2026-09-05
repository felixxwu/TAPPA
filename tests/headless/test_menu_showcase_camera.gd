extends GutTest
# Mirrors test_replay_camera.gd's shape for the shot-rotation contract, but for
# MenuShowcaseCamera's fixed-point shots (no followed target).

var _cam: MenuShowcaseCamera


func before_each() -> void:
	_cam = MenuShowcaseCamera.new()
	add_child_autofree(_cam)


func _two_shots() -> Array:
	return [
		{"pos": Vector3(0, 5, 0), "look_at": Vector3(10, 0, 0)},
		{"pos": Vector3(50, 5, 0), "look_at": Vector3(60, 0, 0)},
	]


func test_ticks_to_a_finite_transform_facing_the_shot() -> void:
	_cam.setup(_two_shots())
	_cam._tick(0.016)
	assert_true(_cam.global_position.is_finite(), "camera position finite")
	var look: Vector3 = _two_shots()[0]["look_at"]
	var to_look := (look - _cam.global_position)
	if to_look.length() > 0.01:
		assert_gt((-_cam.global_transform.basis.z).dot(to_look.normalized()), 0.0,
			"camera faces the shot's look_at point")


func test_advances_shots_on_the_fixed_dwell() -> void:
	_cam.setup(_two_shots())
	assert_eq(_cam.current_shot(), 0, "starts on the first shot")
	_cam._tick(MenuShowcaseCamera.SHOT_DWELL - 0.1)
	assert_eq(_cam.current_shot(), 0, "still on the first shot just before the dwell")
	_cam._tick(0.2)
	assert_eq(_cam.current_shot(), 1, "advanced to the next shot once the dwell elapsed")


func test_shot_rotation_wraps_around() -> void:
	_cam.setup(_two_shots())
	_cam._tick(MenuShowcaseCamera.SHOT_DWELL + 0.1)
	assert_eq(_cam.current_shot(), 1)
	_cam._tick(MenuShowcaseCamera.SHOT_DWELL + 0.1)
	assert_eq(_cam.current_shot(), 0, "wraps back to the first shot")


func test_empty_shot_list_does_not_crash() -> void:
	_cam.setup([])
	_cam._tick(0.016)
	assert_eq(_cam.shot_count(), 0)
