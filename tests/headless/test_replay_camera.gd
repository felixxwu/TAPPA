extends GutTest

# A terrain stub with a raised, constant surface so the roadside plant's height can be
# checked against SAMPLED ground rather than the car's road height.
class FlatTerrain:
	extends TerrainManager
	var surface_y := 100.0
	func height_at(_x: float, _z: float) -> float:
		return surface_y

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

func test_wheel_cam_mounts_at_the_front_and_looks_forward() -> void:
	# The wheel cam replaces the old chase shot: an onboard rig by the front wheel that
	# looks FORWARD down the road (so the wheel + fender frame the shot), not back at the
	# car. Target basis is identity, so the car's forward is -Z.
	_target.global_position = Vector3(0, 0, 0)
	_cam._shot = ReplayCamera.Shot.WHEEL
	_cam._shot_age = 0.0
	_cam._tick(0.016)
	var fwd := -_target.global_transform.basis.z  # car forward
	# Mounted toward the front of the car (ahead of its origin along forward).
	assert_gt((_cam.global_position - _target.global_position).dot(fwd), 0.0,
		"wheel cam sits at the front of the car")
	# Aimed forward down the track, not back at the car body.
	assert_gt((-_cam.global_transform.basis.z).dot(fwd.normalized()), 0.5,
		"wheel cam looks forward past the wheel, not back at the car")


func test_shot_cycles_after_dwell() -> void:
	var first := _cam.current_shot()
	# Advance past one dwell in one tick.
	_cam._tick(ReplayCamera.SHOT_DWELL + 0.1)
	assert_ne(_cam.current_shot(), first, "shot advances after dwell elapses")


# Drive the target one step along -Z (the default travel direction) and tick the camera.
func _drive_to(z: float) -> void:
	_target.global_position = Vector3(0, 0, z)
	_cam._tick(0.016)


func _enter_roadside() -> void:
	_cam._shot = ReplayCamera.Shot.ROADSIDE
	_cam._shot_age = 0.0
	_cam._reset_roadside()


func test_roadside_camera_stays_planted_while_car_approaches() -> void:
	_enter_roadside()
	_drive_to(0.0)          # plants a fixed spot ahead of the car
	var planted := _cam.global_position
	assert_true(planted.is_finite(), "roadside plant is finite")
	# The car creeps forward but hasn't reached/passed the camera yet: the shot must
	# hold perfectly still (that's the whole point of a trackside camera).
	_drive_to(-3.0)
	assert_true(_cam.global_position.is_equal_approx(planted),
		"roadside camera stays put while the car approaches")
	# ...and it keeps the car locked as its look target.
	var to_car := _target.global_position - _cam.global_position
	if to_car.length() > 0.01:
		assert_gt((-_cam.global_transform.basis.z).dot(to_car.normalized()), 0.0,
			"roadside camera stays locked on the car")


func test_roadside_camera_replants_after_car_passes() -> void:
	_enter_roadside()
	_drive_to(0.0)
	var first_plant := _cam.global_position
	# Drive the car well past the camera and off up the road — it must cut to a new spot.
	_drive_to(-200.0)
	assert_false(_cam.global_position.is_equal_approx(first_plant),
		"roadside camera cuts to a new position once the car has passed and driven off")
	assert_true(_cam.global_position.is_finite(), "the re-planted position is finite")


func test_roadside_hands_back_to_rotation_after_enough_plants() -> void:
	_enter_roadside()
	# Each big step drives the car far past the current plant, forcing a re-plant. After a
	# few trackside positions the shot must hand back to the rest of the rotation.
	var z := 0.0
	for _i in ReplayCamera.ROADSIDE_PLANTS + 2:
		_drive_to(z)
		z -= 300.0
	assert_ne(_cam.current_shot(), ReplayCamera.Shot.ROADSIDE,
		"roadside rotates back to the other shots after showing enough positions")


func test_roadside_camera_on_a_cliff_seats_at_the_terrain_top() -> void:
	# The plant lands where the ground is RAISED above the track (a cliff/verge). It must
	# seat head-height above that higher terrain, not at the car's road height.
	var terrain := FlatTerrain.new()
	autofree(terrain)
	terrain.surface_y = 100.0      # ground here is well above the track (car at y = 0)
	_cam.setup(_target, _rec, terrain)
	_enter_roadside()
	_drive_to(0.0)   # target (track height) is at y = 0
	assert_almost_eq(_cam.global_position.y, terrain.surface_y + ReplayCamera.ROADSIDE_HEIGHT,
		0.001, "on a cliff the camera seats head-height above the raised ground")


func test_roadside_camera_in_a_pit_is_clamped_up_to_track_height() -> void:
	# The plant lands where the ground is BELOW the track (a pit). The camera must be lifted
	# to the track height, not left buried at the bottom of the hole where it can't see.
	var terrain := FlatTerrain.new()
	autofree(terrain)
	terrain.surface_y = -20.0      # deep pit floor, below the track
	_cam.setup(_target, _rec, terrain)
	_enter_roadside()
	_drive_to(0.0)   # track height (car) is y = 0
	assert_gt(_cam.global_position.y, terrain.surface_y,
		"the camera is not left at the bottom of the pit")
	assert_almost_eq(_cam.global_position.y, _target.global_position.y + ReplayCamera.ROADSIDE_HEIGHT,
		0.001, "it is clamped up to head-height above the track, not the pit floor")


func test_roadside_camera_is_forced_above_the_water_surface() -> void:
	# The plant lands over a submerged basin: the terrain AND the track height sit below the
	# water level. The camera must seat above the water surface, not under it.
	var terrain := FlatTerrain.new()
	autofree(terrain)
	terrain.surface_y = -30.0      # deep basin floor
	var water_level := 5.0         # water above both the basin floor and the track (y = 0)
	_cam.setup(_target, _rec, terrain, water_level)
	_enter_roadside()
	_drive_to(0.0)
	assert_gt(_cam.global_position.y, water_level,
		"roadside camera is lifted above the water surface over a submerged basin")
	assert_almost_eq(_cam.global_position.y, water_level + ReplayCamera.ROADSIDE_HEIGHT, 0.001,
		"it sits head-height above the water, not the sunken basin floor")
