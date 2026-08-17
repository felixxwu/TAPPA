extends GutTest

# A terrain stub with a raised, constant surface so the roadside plant's height can be
# checked against SAMPLED ground rather than the car's road height.
class FlatTerrain:
	extends TerrainManager
	var surface_y := 100.0
	func height_at(_x: float, _z: float) -> float:
		return surface_y

# A synthetic replay target exposing half_width(), like Car, but with a controllable
# body width — so the WHEEL shot's clearance behaviour can be checked across a RANGE of
# widths without pinning to any one authored CarLibrary car.
class WideTarget:
	extends Node3D
	var body_half_width := 0.0
	func half_width() -> float:
		return body_half_width

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


func test_wheel_cam_clears_the_car_body_across_a_range_of_widths() -> void:
	# Regression: the WHEEL shot used to mount at a FIXED lateral offset regardless of
	# the fielded car's actual width, so a wide enough car's body would reach out to (or
	# past) the camera's mount point -- the rig would sit at/inside the body mesh. The
	# mount must now scale with the target's own half_width() plus a clearance margin,
	# for ANY reasonable body width (not a specific authored car's dimensions).
	var wide := WideTarget.new()
	add_child_autofree(wide)
	var cam := ReplayCamera.new()
	add_child_autofree(cam)
	cam.setup(wide, _rec)
	cam._shot = ReplayCamera.Shot.WHEEL
	cam._shot_age = 0.0
	var clearance: float = Config.data.wheel_cam_lateral_clearance
	for half_width in [0.3, 0.6, 0.95, 1.2, 1.6]:
		wide.body_half_width = half_width
		wide.global_position = Vector3(0, 0, 0)
		cam._tick(0.016)
		var right := wide.global_transform.basis.x.normalized()
		var lateral_reach := (cam.global_position - wide.global_position).dot(right)
		assert_almost_eq(lateral_reach, half_width + clearance, 0.01,
			"wheel cam lateral reach (%s) must clear half-width %s by the configured margin"
				% [lateral_reach, half_width])
		assert_gt(lateral_reach, half_width,
			"wheel cam must sit strictly outside the car's half-width (no clipping)")


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


# Tick with the FOV snap forced, so a single frame lands on the framing target rather than
# part-way through the easing — the assertions below are about WHICH lens the framing rule
# picks, not how fast the ease gets there.
func _drive_to_snapped(z: float) -> void:
	_cam._fov_snap = true
	_drive_to(z)


# The on-screen height (as a fraction of the viewport) that a subject of the configured
# nominal size spans at `distance` under a given FOV. Holding this constant as the distance
# changes is the entire point of the framed shots.
func _screen_fraction(distance: float, fov_deg: float) -> float:
	var size: float = Config.data.replay_frame_subject_size
	return size / (2.0 * distance * tan(deg_to_rad(fov_deg) * 0.5))


# True when the FOV is pinned at one end of the configured lens range, where the framing
# rule is deliberately overridden and the exact subject size no longer holds.
func _at_lens_limit(fov_deg: float) -> bool:
	return absf(fov_deg - Config.data.replay_frame_fov_min) < 0.001 \
		or absf(fov_deg - Config.data.replay_frame_fov_max) < 0.001


func test_roadside_zooms_in_when_the_car_is_far_and_out_as_it_arrives() -> void:
	# The headline behaviour: a planted trackside camera rides the zoom rocker. The car
	# starts far up the road (long lens), sweeps past (wide), then drives away (long again).
	_enter_roadside()
	_drive_to_snapped(0.0)         # plants ROADSIDE_AHEAD up the road; car is far off
	var fov_far := _cam.fov
	_drive_to_snapped(-20.0)       # closing on the plant
	var fov_near := _cam.fov
	_drive_to_snapped(-55.0)       # past it and driving away again
	var fov_leaving := _cam.fov
	assert_gt(fov_near, fov_far, "FOV widens (zooms out) as the car closes on the plant")
	assert_lt(fov_leaving, fov_near, "FOV narrows again (zooms back in) as the car leaves")


func test_framed_zoom_holds_the_car_at_a_constant_screen_size() -> void:
	# Not merely "it changes in the right direction" — the zoom is DERIVED so the car keeps
	# the same share of the frame at every distance, which is why the shot reads as one
	# operator holding framing rather than the car ballooning and shrinking. Checked
	# straight against the rule across a wide distance sweep; wherever the lens range
	# deliberately overrides the rule, the FOV must sit exactly on that limit instead.
	_cam._shot = ReplayCamera.Shot.ROADSIDE
	var wanted: float = Config.data.replay_frame_screen_fraction
	var unclamped := 0
	for distance in [2.0, 5.0, 10.0, 20.0, 35.0, 60.0, 120.0, 400.0]:
		var f: float = _cam._target_fov(distance)
		assert_between(f, Config.data.replay_frame_fov_min, Config.data.replay_frame_fov_max,
			"framed FOV stays inside the lens range at %s m" % distance)
		if _at_lens_limit(f):
			continue
		unclamped += 1
		assert_almost_eq(_screen_fraction(distance, f), wanted, 0.001,
			"at %s m the car spans the configured share of the screen" % distance)
	assert_gt(unclamped, 1, "the sweep exercised the framing rule at more than one distance")


func test_high_wide_zooms_in_by_the_same_framing_rule() -> void:
	# The helicopter shot sits far back and up, so at the plain base FOV the car was a dot.
	# It now frames by the same constant-size rule as the roadside cam — a tighter lens the
	# further out it parks.
	_target.global_position = Vector3.ZERO
	_cam._shot = ReplayCamera.Shot.HIGH_WIDE
	_cam._shot_age = 0.0
	_cam._fov_snap = true
	_cam._tick(0.016)
	var dist := _cam.global_position.distance_to(_target.global_position)
	assert_gt(dist, 1.0, "the high wide shot really is pulled back")
	assert_almost_eq(_cam.fov, _cam._target_fov(dist), 0.001,
		"high wide's lens comes from the framing rule at its own distance")
	if not _at_lens_limit(_cam.fov):
		assert_almost_eq(_screen_fraction(dist, _cam.fov),
			Config.data.replay_frame_screen_fraction, 0.001,
			"high wide frames the car to the configured share of the screen")


func test_fixed_offset_shots_use_the_plain_base_fov() -> void:
	# Only the two varying-distance shots ride the zoom. The fixed-offset tracking shots sit
	# at a constant distance, so they must be handed the plain base FOV — including right
	# after a framed shot, so a tight lens can't leak into the next shot.
	for shot in [ReplayCamera.Shot.ORBIT, ReplayCamera.Shot.FLYBY, ReplayCamera.Shot.WHEEL]:
		_cam._shot = shot
		_cam._shot_age = 0.0
		_cam.fov = 12.0        # as if the previous shot had zoomed right in
		_cam._fov_snap = true
		_cam._tick(0.016)
		assert_almost_eq(_cam.fov, Config.data.replay_fov, 0.001,
			"shot %s uses the base replay FOV" % shot)


func test_fov_snaps_on_a_cut_rather_than_easing_across_it() -> void:
	# A cut is a new camera with a new lens: the first frame of a shot must land on its own
	# framing, not ramp in from whatever the previous shot was sitting at. Easing at any sane
	# rate cannot cover a big gap in one 16 ms frame — only a snap can.
	_cam._shot = ReplayCamera.Shot.HIGH_WIDE
	_cam._shot_age = 0.0
	_cam.fov = 120.0
	_cam._advance_shot()       # ...which is what a cut does
	_cam._shot = ReplayCamera.Shot.HIGH_WIDE
	_cam._tick(0.016)
	var dist := _cam.global_position.distance_to(_target.global_position)
	assert_almost_eq(_cam.fov, _cam._target_fov(dist), 0.001,
		"the shot's first frame is already on its own lens, not easing in from 120 deg")


func test_fov_eases_between_frames_within_a_shot() -> void:
	# Between cuts the zoom is smoothed, so a distance change reads as a rocker being nudged
	# rather than a snap. One short frame must move the FOV toward the target without
	# arriving (with easing disabled in config it snaps, which is that setting's contract).
	_cam._shot = ReplayCamera.Shot.HIGH_WIDE
	_cam._shot_age = 0.0
	_cam._fov_snap = false
	_cam.fov = 110.0
	_cam._tick(0.016)
	var dist := _cam.global_position.distance_to(_target.global_position)
	var target: float = _cam._target_fov(dist)
	assert_lt(_cam.fov, 110.0, "the FOV moves toward the framing target")
	if Config.data.replay_fov_smoothing > 0.0:
		assert_gt(_cam.fov, target, "...but eases rather than snapping mid-shot")


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
