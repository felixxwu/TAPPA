extends GutTest

var _target: Node3D
var _rec: ReplayRecorder
var _cam: ReplayCamera

func before_each() -> void:
	_target = Node3D.new()
	add_child_autofree(_target)
	_rec = ReplayRecorder.new()
	add_child_autofree(_rec)
	# Synthetic straight path so the camera has points to frame.
	for i in 10:
		_rec._push_test_frame(float(i) * 0.1, Vector3(i, 0, 0))
	_cam = ReplayCamera.new()
	add_child_autofree(_cam)
	_cam.setup(_target, _rec)

func test_camera_produces_finite_transform() -> void:
	_target.global_position = Vector3(5, 0, 0)
	_cam._tick(0.016)
	assert_true(_cam.global_position.is_finite(), "camera position finite")
	# Camera looks toward the target (forward roughly points at it).
	var to_target := (_target.global_position - _cam.global_position)
	if to_target.length() > 0.01:
		assert_gt((-_cam.global_transform.basis.z).dot(to_target.normalized()), 0.0,
			"camera faces the target")

func test_shot_cycles_after_dwell() -> void:
	var first := _cam.current_shot()
	# Advance past one dwell in one tick.
	_cam._tick(ReplayCamera.SHOT_DWELL + 0.1)
	assert_ne(_cam.current_shot(), first, "shot advances after dwell elapses")
