extends Camera3D

@export var target: Node3D

## Minimum horizontal speed (m/s) before the direction of travel is trusted.
## Below this the car's facing direction is used instead, so the camera stays
## stable when stationary or crawling rather than chasing velocity noise.
const MIN_TRAVEL_SPEED := 1.0

var _distance: float
var _height: float
var _smoothing: float

# FOV modulation: base FOV widens toward _base_fov + _fov_speed_boost as the car
# approaches _fov_speed, easing per frame at _fov_smoothing.
var _base_fov: float
var _fov_speed_boost: float
var _fov_speed: float
var _fov_smoothing: float
var _dolly_mix: float

# G-force lean: the view rolls into lateral acceleration and pitches with
# forward acceleration (brake dips the nose, throttle lifts it). Gains are
# degrees per m/s², clamped to _tilt_max, eased toward the target at
# _tilt_smoothing. See features/camera.md.
var _tilt_roll_gain: float
var _tilt_pitch_gain: float
var _tilt_max: float
var _tilt_smoothing: float
var _roll := 0.0     # current eased roll (radians)
var _pitch := 0.0    # current eased pitch (radians)
var _prev_vel := Vector3.ZERO
var _have_prev_vel := false
# The target the cached _prev_vel belongs to; when it changes (a car swap via
# CameraManager.retarget) the history is dropped so the first frame on the new
# car doesn't read a bogus acceleration spike off the old car's velocity.
var _tilt_vel_target: Node = null

# Last known horizontal direction of travel (pointing the way the car moves).
var _travel_dir := Vector3.FORWARD

# Cached sibling that exposes height_at (the hilly Floor); resolved once on first
# use so the per-frame ground query doesn't re-scan the sibling list.
var _terrain: Node = null

# Lake water surface height — the ground the camera seats above is never taken below
# this, so over a submerged basin the camera stays above the water instead of dunking
# under it (matches the roadside replay cam). Read from config on ready.
var _water_level := -INF


func _ready() -> void:
	var cfg: GameConfig = Config.data
	_distance = cfg.follow_distance
	_height = cfg.follow_distance * cfg.follow_height_ratio
	_smoothing = cfg.smoothing
	_water_level = cfg.track_water_level_m
	_base_fov = cfg.chase_fov
	_fov_speed_boost = cfg.chase_fov_speed_boost
	_fov_speed = cfg.chase_fov_speed
	_fov_smoothing = cfg.chase_fov_smoothing
	_dolly_mix = cfg.chase_dolly_mix
	_tilt_roll_gain = cfg.chase_tilt_roll_gain
	_tilt_pitch_gain = cfg.chase_tilt_pitch_gain
	_tilt_max = deg_to_rad(cfg.chase_tilt_max_deg)
	_tilt_smoothing = cfg.chase_tilt_smoothing
	fov = _base_fov


func _physics_process(delta: float) -> void:
	var __t := Time.get_ticks_usec()
	_timed_physics_process(delta)
	PerfLog.track(&"chase_camera", Time.get_ticks_usec() - __t)


func _timed_physics_process(delta: float) -> void:
	if target == null:
		return

	# Target direction of travel, flattened to the horizontal plane. Fall back to
	# the car's facing direction when too slow for velocity to be meaningful.
	var target_dir := _travel_dir
	var vel := Vector3.ZERO
	if target is RigidBody3D:
		vel = (target as RigidBody3D).linear_velocity
	vel.y = 0.0
	if vel.length() >= MIN_TRAVEL_SPEED:
		target_dir = vel.normalized()
	else:
		var facing: Vector3 = -target.global_transform.basis.z
		facing.y = 0.0
		if facing.length() > 0.0:
			target_dir = facing.normalized()

	# Smooth WHERE the camera sits around the car: ease the orbital direction
	# toward the travel direction instead of snapping when it changes suddenly.
	# `smoothing` drives the rate; `1 - exp(-rate·dt)` keeps it frame-rate
	# independent. The look-at itself is NOT smoothed (see below).
	var weight := 1.0 - exp(-_smoothing * delta)
	_travel_dir = _travel_dir.slerp(target_dir, weight).normalized()

	# Widen the FOV with horizontal speed to sell a sense of speed. The target
	# FOV ramps linearly from _base_fov (stationary) to _base_fov +
	# _fov_speed_boost at _fov_speed, then eased frame-rate-independently.
	var speed_frac := clampf(vel.length() / maxf(_fov_speed, 0.001), 0.0, 1.0)
	var target_fov := _base_fov + _fov_speed_boost * speed_frac
	var fov_weight := 1.0 - exp(-_fov_smoothing * delta)
	fov = lerpf(fov, target_fov, fov_weight)

	# Dolly zoom: as the FOV widens with speed, pull the camera IN so the car
	# keeps roughly the same on-screen size. An object of fixed size subtends an
	# angle ~ proportional to 1/(distance · tan(fov/2)); holding that product
	# constant at the base (standstill) value means distance ∝ tan(base/2)/tan(fov/2).
	# So the wider the FOV, the closer the camera sits — the classic dolly-zoom trade.
	# `chase_dolly_mix` blends between no correction (1.0, distance stays put — pure
	# FOV zoom, the car grows) and the full dolly ratio (the car keeps its size), so
	# an over-eager pull-in can be softened.
	var half_base := deg_to_rad(_base_fov) * 0.5
	var half_now := deg_to_rad(fov) * 0.5
	var full_ratio := tan(half_base) / maxf(tan(half_now), 0.0001)
	var ratio := lerpf(1.0, full_ratio, _dolly_mix)
	# Give longer cars more room: add the car's half length to the follow distance
	# so its nose/tail stays in frame. The look-at anchors on the body origin (the
	# wheelbase centre), so half the body length reaches from there to the tip.
	var base_distance := _distance
	if target.has_method("half_length"):
		base_distance += target.half_length()
	var distance := base_distance * ratio

	# Place the camera behind the (smoothed) orbital direction. The height is
	# measured from the terrain directly below the camera (not from the car), so
	# the camera keeps a constant clearance over the ground it is flying over.
	# `distance` (the dolly-zoom-adjusted follow distance) is the EUCLIDEAN
	# (straight-line) distance to the car, so we trade off horizontal reach against
	# the vertical gap: the bigger the height difference, the closer in the camera
	# sits horizontally to keep the same true distance. Because the camera height
	# depends on the terrain under it (which depends on the horizontal offset), solve
	# it with a couple of fixed-point iterations starting from the full distance.
	var origin := target.global_position
	var horizontal := distance
	for _i in 2:
		var pos := origin - _travel_dir * horizontal
		pos.y = _ground_height_at(pos.x, pos.z) + _height
		var dy := pos.y - origin.y
		# Solve sqrt(horizontal^2 + dy^2) = distance for the horizontal reach.
		horizontal = sqrt(max(0.0, distance * distance - dy * dy))
	var final_pos := origin - _travel_dir * horizontal
	final_pos.y = _ground_height_at(final_pos.x, final_pos.z) + _height
	global_position = final_pos

	# Point straight at the car (un-smoothed). Guard the degenerate cases look_at
	# can't handle: the camera coinciding with the car, or sitting directly
	# above/below it (view direction parallel to UP) — both leave the aim from the
	# previous frame rather than erroring.
	var to_target := target.global_position - global_position
	if to_target.length() > 0.001 and absf(to_target.normalized().dot(Vector3.UP)) < 0.999:
		look_at(target.global_position, Vector3.UP)

	_apply_gforce_tilt(delta)


# Lean the (already aimed) camera into the car's acceleration: roll toward
# lateral g, pitch with forward g. Acceleration is the frame-to-frame change in
# the car's velocity projected onto its local axes; the resulting target angles
# are clamped and eased so the tilt settles back to level when the g-forces drop.
func _apply_gforce_tilt(delta: float) -> void:
	var target_roll := 0.0
	var target_pitch := 0.0
	if delta > 0.0 and target is RigidBody3D:
		if target != _tilt_vel_target:
			_have_prev_vel = false
			_tilt_vel_target = target
		var cur_vel := (target as RigidBody3D).linear_velocity
		if _have_prev_vel:
			var accel := (cur_vel - _prev_vel) / delta
			var car_basis := target.global_transform.basis
			var lateral := accel.dot(car_basis.x)       # + = accelerating rightward
			var longitudinal := accel.dot(-car_basis.z) # + = speeding up forward
			# Roll with lateral g (the default gain is negative, so the view leans
			# outward — away from the turn), pitch nose-up under throttle /
			# nose-down under braking. Gains are deg per m/s².
			target_roll = clampf(deg_to_rad(lateral * _tilt_roll_gain), -_tilt_max, _tilt_max)
			target_pitch = clampf(deg_to_rad(longitudinal * _tilt_pitch_gain), -_tilt_max, _tilt_max)
		_prev_vel = cur_vel
		_have_prev_vel = true

	var weight := 1.0 - exp(-_tilt_smoothing * delta)
	_roll = lerpf(_roll, target_roll, weight)
	_pitch = lerpf(_pitch, target_pitch, weight)
	rotate_object_local(Vector3.RIGHT, _pitch)
	rotate_object_local(Vector3.FORWARD, _roll)


# Terrain surface height at a world (x, z), used to seat the camera a fixed
# distance above the ground below it. Looks for a sibling that exposes height_at
# (the hilly Floor in the main scene); on flat test fixtures there is none, so it
# falls back to 0. Clamped up to the water surface so the camera never seats below a
# lake (it would otherwise dunk under the water plane over a submerged basin).
func _ground_height_at(x: float, z: float) -> float:
	if not is_instance_valid(_terrain):
		_terrain = null
		var parent := get_parent()
		if parent != null:
			for sibling in parent.get_children():
				if sibling != self and sibling.has_method("height_at"):
					_terrain = sibling
					break
	var ground: float = _terrain.height_at(x, z) if _terrain != null else 0.0
	return maxf(ground, _water_level)
