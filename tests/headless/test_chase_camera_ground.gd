extends GutTest
# Chase camera ground seating (chase_camera.gd -> _ground_height_at / _eased_ground). The
# camera seats on the terrain below it and nothing else (the water level used to clamp the
# seat upward and floated the camera above the car), and eases toward changes in it.

var _cam: Camera3D
var _target: Node3D
var _saved_water := 0.0


func before_each() -> void:
	_saved_water = Config.data.track_water_level_m
	_target = Node3D.new()
	add_child(_target)
	_cam = load("res://scripts/chase_camera.gd").new()
	_cam.target = _target
	add_child(_cam)
	_cam.set_physics_process(false)


func after_each() -> void:
	Config.data.track_water_level_m = _saved_water
	_cam.free()
	_target.free()


func test_a_water_level_above_the_ground_does_not_lift_the_seat() -> void:
	# No terrain sibling here, so the ground reads 0.
	Config.data.track_water_level_m = 50.0
	assert_almost_eq(_cam._ground_height_at(0.0, 0.0), 0.0, 0.001)


func test_the_first_seat_snaps_to_the_ground() -> void:
	assert_almost_eq(_cam._eased_ground(12.0, 1.0 / 60.0), 12.0, 0.001)


func test_a_small_rise_is_eased_toward_not_jumped_to() -> void:
	_cam._eased_ground(0.0, 1.0 / 60.0)
	var seated: float = _cam._eased_ground(4.0, 1.0 / 60.0)
	assert_gt(seated, 0.0, "it moves toward the new ground")
	assert_lt(seated, 4.0, "but does not jump straight to it")
	for i in 600:
		seated = _cam._eased_ground(4.0, 1.0 / 60.0)
	assert_almost_eq(seated, 4.0, 0.01, "and settles on it")


func test_a_huge_jump_snaps_instead_of_drifting() -> void:
	_cam._eased_ground(0.0, 1.0 / 60.0)
	assert_almost_eq(_cam._eased_ground(_cam.SNAP_M * 2.0, 1.0 / 60.0), _cam.SNAP_M * 2.0, 0.001)
