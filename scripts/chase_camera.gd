extends Camera3D
# Docs: features/camera.md — update in the same change as this file.
# Tests: tests/headless/test_chase_camera_aim.gd, tests/headless/test_chase_camera_fov.gd, tests/headless/test_chase_camera_look.gd — extend in the same change. These are the PRIMARY ones, not all of them: before you change behaviour here, `grep -rn 'chase_camera' tests/headless/` and read the assertions that pin what you are about to change (5 test files touch this script).

@export var target: Node3D
## The on-screen touch controls, if any: a touch that lands on one of them is driving, not looking.
@export var mobile_controls: Node

## Minimum horizontal speed (m/s) before the direction of travel is trusted.
## Below this the car's facing direction is used instead, so the camera stays
## stable when stationary or crawling rather than chasing velocity noise.
const MIN_TRAVEL_SPEED := 1.0

var _distance: float
var _height_ratio: float
var _smoothing: float

# FOV modulation: base FOV widens toward _base_fov + _fov_speed_boost as the car
# approaches _fov_speed, easing per frame at _fov_smoothing.
var _base_fov: float
var _fov_speed_boost: float
var _fov_speed: float
# Fixed extra FOV (degrees) while nitrous is delivering. See GameConfig.chase_fov_nitrous_boost.
var _fov_nitrous_boost: float
var _fov_smoothing: float
var _dolly_mix: float
# How far forward along the car's facing the look-at point sits, as a multiple of
# the car's half length. See GameConfig.chase_look_ahead_ratio.
var _look_ahead_ratio: float

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

# Camera shake. ONE amplitude that every source pushes into (see _update_shake), applied as
# rotation after the aim. Impulsive sources charge _shake_impulse, which decays; continuous
# ones are re-read every tick and never latch. See features/camera.md.
var _shake_max: float        # radians at full intensity
var _shake_frequency: float
var _shake_decay: float
var _shake_g_threshold: float
var _shake_g_gain: float
var _shake_speed_gain: float
var _shake_wheelspin_gain: float
var _shake_nitrous_gain: float
var _shake_impulse := 0.0    # decaying intensity from g-force spikes (0..1)
var _shake_phase := 0.0      # seconds, advanced by delta — drives the oscillation
var _prev_vel := Vector3.ZERO
var _have_prev_vel := false
var _gravity: float
# The target the cached _prev_vel belongs to; when it changes (a car swap via
# CameraManager.retarget) the history is dropped so the first frame on the new
# car doesn't read a bogus acceleration spike off the old car's velocity.
var _tilt_vel_target: Node = null

# Last known horizontal direction of travel (pointing the way the car moves).
var _travel_dir := Vector3.FORWARD

# The car height the camera currently seats on, eased toward the car's so suspension jolts and
# small bumps become a gentle float rather than a jolt. NAN until the first placement.
var _seated_base := NAN
var _height_smoothing: float

# Free look: a yaw swivel (radians) added on top of the follow direction, driven by the mouse, a
# touch drag off the on-screen controls, or the right stick, and eased back to 0 once look input
# stops. See features/camera.md -> "Free look".
var _look_yaw := 0.0
var _look_idle := INF        # seconds since the last look input
var _look_pointer = null     # the touch index driving the look, or null
var _look_mouse_sens: float
var _look_touch_sens: float
var _look_stick_speed: float # radians per second
var _look_hold: float
var _look_return: float


func _ready() -> void:
	_gravity = Platform.gravity()
	var cfg: GameConfig = Config.data
	_distance = cfg.follow_distance
	_height_ratio = cfg.follow_height_ratio
	_smoothing = cfg.smoothing
	_height_smoothing = cfg.chase_height_smoothing
	_look_mouse_sens = cfg.chase_look_mouse_sensitivity
	_look_touch_sens = cfg.chase_look_touch_sensitivity
	_look_stick_speed = deg_to_rad(cfg.chase_look_stick_speed)
	_look_hold = cfg.chase_look_hold_s
	_look_return = cfg.chase_look_return_rate
	_base_fov = cfg.chase_fov
	_fov_speed_boost = cfg.chase_fov_speed_boost
	_fov_speed = cfg.chase_fov_speed
	_fov_nitrous_boost = cfg.chase_fov_nitrous_boost
	_fov_smoothing = cfg.chase_fov_smoothing
	_dolly_mix = cfg.chase_dolly_mix
	_look_ahead_ratio = cfg.chase_look_ahead_ratio
	_tilt_roll_gain = cfg.chase_tilt_roll_gain
	_tilt_pitch_gain = cfg.chase_tilt_pitch_gain
	_tilt_max = deg_to_rad(cfg.chase_tilt_max_deg)
	_tilt_smoothing = cfg.chase_tilt_smoothing
	_shake_max = deg_to_rad(cfg.shake_max_deg)
	_shake_frequency = cfg.shake_frequency
	_shake_decay = cfg.shake_decay
	_shake_g_threshold = cfg.shake_g_threshold
	_shake_g_gain = cfg.shake_g_gain
	_shake_speed_gain = cfg.shake_speed_gain
	_shake_wheelspin_gain = cfg.shake_wheelspin_gain
	_shake_nitrous_gain = cfg.shake_nitrous_gain
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
	_update_look(delta)
	# The free-look swivel turns the orbit on top of the follow direction, so the camera keeps
	# following the car while it looks at it from the side.
	var orbit_dir := _travel_dir.rotated(Vector3.UP, _look_yaw)

	# Widen the FOV with horizontal speed to sell a sense of speed. The target
	# FOV ramps linearly from _base_fov (stationary) to _base_fov +
	# _fov_speed_boost at _fov_speed, then eased frame-rate-independently.
	# Nitrous adds a further FIXED amount for as long as it's delivering, so the boost
	# punches the view out at any speed rather than being swallowed by the speed ramp
	# (which is already near its ceiling by the time nitrous is worth using).
	var speed_frac := clampf(vel.length() / maxf(_fov_speed, 0.001), 0.0, 1.0)
	var target_fov := _base_fov + _fov_speed_boost * speed_frac
	if _fov_nitrous_boost != 0.0 and _nitrous_delivering():
		target_fov += _fov_nitrous_boost
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
	# so its nose/tail stays in frame. The camera is PLACED relative to the body
	# origin (the wheelbase centre), so half the body length reaches from there to
	# the tip. (The look-at aims further forward — see _aim_point.)
	var base_distance := _distance
	if target.has_method("half_length"):
		base_distance += target.half_length()
	var distance := base_distance * ratio

	# Place the camera behind the (smoothed) orbital direction, a fixed height above the car
	# (eased, see _eased_base). The height is a share of the same length-adjusted, dolly-zoomed
	# distance, so the camera looks down at the same angle on every car and as it pulls in. `distance` (the dolly-zoom-adjusted follow distance) is the EUCLIDEAN
	# (straight-line) distance to the car, so the horizontal reach is what is left of it after the
	# height: sqrt(distance^2 - height^2).
	var origin := target.global_position
	var height := distance * _height_ratio
	var horizontal := sqrt(maxf(0.0, distance * distance - height * height))
	var final_pos := origin - orbit_dir * horizontal
	final_pos.y = _eased_base(origin.y, delta) + height
	global_position = final_pos

	# Point at the car's nose rather than its centre (un-smoothed). The aim point
	# follows the car's FACING while the camera sits behind its direction of TRAVEL,
	# so under a drift the nose is off to one side of the travel axis and the framing
	# slides with the slip angle instead of staying dead-centre. Guard the degenerate
	# cases look_at can't handle: the camera coinciding with the aim point, or sitting
	# directly above/below it (view direction parallel to UP) — both leave the aim
	# from the previous frame rather than erroring.
	var aim := _aim_point()
	var to_target := aim - global_position
	if to_target.length() > 0.001 and absf(to_target.normalized().dot(Vector3.UP)) < 0.999:
		look_at(aim, Vector3.UP)

	# Shake goes LAST, on top of the aimed-and-leaned view: it is a disturbance of the shot the
	# rest of this function composed, not an input to it.
	_update_shake(delta, _apply_gforce_tilt(delta))


# Free look input. Mouse motion and a touch drag that started off the on-screen controls swivel
# the camera; every one turns the view the way the input moves (right turns the view right), as
# photo mode's look does. Mouse events the engine synthesised from a touch are skipped, or a finger
# would count twice. Only while this camera is the one in use.
func _input(event: InputEvent) -> void:
	if not current:
		return
	if event is InputEventMouseMotion:
		if event.device != InputEvent.DEVICE_ID_EMULATION:
			look_by(-event.relative.x * _look_mouse_sens)
	elif event is InputEventScreenTouch:
		if event.pressed:
			if event.index == _look_pointer or (_look_pointer == null and not _on_controls(event.position)):
				_look_pointer = event.index
		elif event.index == _look_pointer:
			_look_pointer = null
	elif event is InputEventScreenDrag and event.index == _look_pointer:
		look_by(-event.relative.x * _look_touch_sens)


# Swivel the view by `yaw` radians and count it as look input (holds off the return to centre).
func look_by(yaw: float) -> void:
	_look_yaw = wrapf(_look_yaw + yaw, -PI, PI)
	_look_idle = 0.0


func _on_controls(pos: Vector2) -> bool:
	return is_instance_valid(mobile_controls) and mobile_controls.has_method("owns_point") \
			and mobile_controls.owns_point(pos)


# The stick swivels at a rate; with no look input for _look_hold seconds (and no finger held on a
# look drag) the swivel eases back to 0, so the view always returns to the default. Not in use
# (bonnet cam): no swivel at all.
func _update_look(delta: float) -> void:
	if not current:
		_look_yaw = 0.0
		_look_pointer = null
		_look_idle = INF
		return
	var stick := Input.get_axis(&"look_left", &"look_right")
	if stick != 0.0:
		look_by(-stick * _look_stick_speed * delta)
	else:
		_look_idle += delta
	if _look_pointer == null and _look_idle > _look_hold:
		_look_yaw = lerpf(_look_yaw, 0.0, 1.0 - exp(-_look_return * delta))


# Whether the target car is actually delivering nitrous this tick. Reads EngineSim's
# LATCHED nitrous_delivering rather than re-deriving it from the input action, so the view
# only widens when the boost is really being made (holding the button with a dry tank, off
# throttle, or under a fuel cut moves nothing and must move the camera no more than it
# moves the car). Guarded for targets with no drivetrain — the test fixtures and the
# replay/ghost bodies this camera can be pointed at are plain RigidBody3Ds.
func _nitrous_delivering() -> bool:
	# Deliberately NOT gated on _fov_nitrous_boost: this answers "is nitrous delivering", and the
	# FOV punch is only one of its consumers (the shake is another). Folding one consumer's
	# disable switch in here silently killed the other.
	if target == null or target.get("drivetrain") == null:
		return false
	var engine: EngineSim = target.drivetrain.engine
	return engine != null and engine.nitrous_delivering


# The world point the camera aims at: _look_ahead_ratio × the car's half length
# forward along its own facing, from the body origin (the wheelbase centre).
# Falls back to the origin for targets that don't expose half_length().
func _aim_point() -> Vector3:
	var origin: Vector3 = target.global_position
	if _look_ahead_ratio == 0.0 or not target.has_method("half_length"):
		return origin
	var forward: Vector3 = -target.global_transform.basis.z
	return origin + forward * (target.half_length() * _look_ahead_ratio)


# Lean the (already aimed) camera into the car's acceleration: roll toward
# lateral g, pitch with forward g. Acceleration is the frame-to-frame change in
# the car's velocity projected onto its local axes; the resulting target angles
# are clamped and eased so the tilt settles back to level when the g-forces drop.
# Returns the car's acceleration magnitude in g this tick (0 when it cannot be measured), so
# the shake can key off the SAME measurement rather than deriving a second, subtly different
# one from its own velocity history.
func _apply_gforce_tilt(delta: float) -> float:
	var target_roll := 0.0
	var target_pitch := 0.0
	var accel_g := 0.0
	if delta > 0.0 and target is RigidBody3D:
		if target != _tilt_vel_target:
			_have_prev_vel = false
			_tilt_vel_target = target
		var cur_vel := (target as RigidBody3D).linear_velocity
		if _have_prev_vel:
			var accel := (cur_vel - _prev_vel) / delta
			# The FULL 3D magnitude, unlike the tilt's two projections below: a hard landing is
			# almost entirely VERTICAL, and it is one of the impacts the shake most needs to
			# catch. Gravity is deliberately not subtracted — a car in free flight reads a
			# steady 1 g, which sits below any sensible shake_g_threshold, and the landing spike
			# that follows is what matters. Same convention as DamageModel's deceleration rule.
			accel_g = accel.length() / _gravity
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
	return accel_g


# Shake the (already aimed and leaned) camera. ONE amplitude, fed by every source, applied as
# three small rotations — see features/camera.md for the whole design.
#
# ROTATION ONLY, never position. A positional shake fights the dolly zoom (which sets the
# follow distance precisely so the car holds its on-screen size) and, on a close mount, walks
# the camera through the bodywork. Rotating the view is also what a head does.
#
# TWO KINDS OF SOURCE, and the distinction is the whole structure:
#   - IMPULSIVE (the g-force term). A crash, a hard landing, a clipped bush and a kerb strike
#     are all one spike in the car's acceleration, so ONE source covers every impact in the
#     game with no per-event plumbing and nothing to forget to wire up. It charges a decaying
#     envelope, because an impact is over in a tick but must be FELT for a moment after.
#   - CONTINUOUS (speed, wheelspin, nitrous). Re-read every tick and never latched, so they
#     stop the instant the condition does.
# Both add into one intensity, which is clamped to 1 — sources stack, but simultaneous events
# can never multiply into nausea, and shake_max_deg alone bounds how violent it can ever be.
#
# The oscillation is DETERMINISTIC (layered sines on a phase accumulator, not randf): three
# incommensurate frequencies per axis, which reads as irregular vibration without a random
# stream, so a replay of the same run shakes the same way and a test can assert on it. The
# frequencies differ per axis so pitch/yaw/roll never move as one — that would read as a
# single wobble rather than a rattle.
func _update_shake(delta: float, accel_g: float) -> void:
	if _shake_max <= 0.0:
		return
	# Impulsive: charge from the g-force excess, then decay. max() rather than += so a long
	# scrape holds its level instead of integrating up to full.
	# Clamped to 1 as it is CHARGED, not merely where it is read. A 300 g arrest would otherwise
	# store an envelope of hundreds, and the decay would then spend seconds coming back down
	# through that headroom with the shake pinned at full amplitude the whole way — a big crash
	# would rattle the camera long after the car had stopped.
	var spike := maxf(accel_g - _shake_g_threshold, 0.0) * _shake_g_gain
	_shake_impulse = clampf(maxf(_shake_impulse * exp(-_shake_decay * delta), spike), 0.0, 1.0)

	var intensity := _shake_impulse
	var vel := Vector3.ZERO
	if target is RigidBody3D:
		vel = (target as RigidBody3D).linear_velocity
	vel.y = 0.0
	intensity += _shake_speed_gain * clampf(vel.length() / maxf(_fov_speed, 0.001), 0.0, 1.0)
	# Duck-typed rather than `as Drivetrain`, deliberately: this camera is pointed at replay and
	# ghost stand-ins as well as the player's car, and the reading is optional — a target that
	# cannot report wheelspin simply contributes none, instead of the camera needing to know
	# which kinds of target exist.
	var dt: Object = target.get("drivetrain") if target != null else null
	if dt != null and dt.has_method("drive_wheelspin_excess"):
		intensity += _shake_wheelspin_gain * float(dt.drive_wheelspin_excess())
	if _nitrous_delivering():
		intensity += _shake_nitrous_gain
	intensity = clampf(intensity, 0.0, 1.0)
	if intensity <= 0.0:
		return

	_shake_phase += delta
	var amplitude := _shake_max * intensity
	var w := TAU * _shake_frequency * _shake_phase
	rotate_object_local(Vector3.RIGHT, amplitude * sin(w * 1.00))
	rotate_object_local(Vector3.UP, amplitude * sin(w * 1.37 + 1.7))
	rotate_object_local(Vector3.FORWARD, amplitude * sin(w * 0.83 + 3.1))


# Ease the seated car height toward `base`. A jump bigger than SNAP_M (a reset, a teleport, the
# first frame) snaps instead, so the camera never drifts in from far away.
const SNAP_M := 30.0
func _eased_base(base: float, delta: float) -> float:
	if is_nan(_seated_base) or absf(base - _seated_base) > SNAP_M:
		_seated_base = base
	else:
		_seated_base = lerpf(_seated_base, base, 1.0 - exp(-_height_smoothing * delta))
	return _seated_base
