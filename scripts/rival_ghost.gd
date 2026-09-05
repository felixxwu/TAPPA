class_name RivalGhost
extends Node
# Docs: features/rival-ghost.md — update in the same change as this file.
# Tests: tests/headless/test_rival_ghost.gd — extend in the same change.
#
# Makes the run's one fail state — the fixed clock in RegionRunMode.stage_target_ms
# (todo/roguelike-pivot.md decision 4/11) — visible as a "rival": a second, posed-not-
# simulated Car driving the pace-scaled profile RegionRunMode.stage_target_profile()
# produces. See features/rival-ghost.md for the full picture (start-line reveal +
# live HUD delta); this file is just the maths + the Car it drives.
#
# The maths is two pure inversions of the profile's parallel {"s","t"} arrays (no
# live Car needed, so they're tested without instancing one):
#   distance_at_time(profile, t) -> s   poses the ghost at a race time
#   time_at_distance(profile, s) -> t   the HUD delta: the rival's time AT THE
#                                        PLAYER'S distance, compared to the player's
#                                        actual elapsed time
# Both binary-search the monotonic array and lerp between the bracketing samples.
# profile["t"] is non-decreasing by construction (LapTimeModel's forward solve never
# runs time backwards) and profile["s"] is evenly spaced (LapTimeModel.SAMPLE_STEP_M),
# so a plain lerp between neighbours is exact for "s" and a good approximation for the
# (non-linear) "t" — the same accuracy the profile is sampled at everywhere else.

# Lateral offset (m) the ghost is nudged by at spawn, so it doesn't sit exactly on
# top of the player at t=0/s=0 during the start-line reveal (both begin at the same
# point on the centerline). Purely cosmetic — the ghost's own along-track pose is
# otherwise identical to the profile.
const GHOST_LATERAL_OFFSET_M := 2.5
# How far ahead along the centerline the tangent sample is taken, for facing.
const TANGENT_EPS_M := 0.5

var _car: Node3D = null  # a Car (VehicleBody3D + car.gd), Node3D-typed like start_line.gd's _player -- ungualified so script-only members (kinematic_pose, freeze) resolve dynamically
# TrackProgress — read via origin_offset()/sample_at() only (duck-typed so a bare
# test double works), never written. See features/rival-ghost.md for why the ghost
# is posed in TrackProgress's arc-length space rather than the raw generated
# centerline's.
var _track_progress: Node = null
var _terrain: Node = null
var _profile: Dictionary = {}   # {"s","t"} pace-scaled, from RunSession.stage_target_profile()
var _t := 0.0
var _looping := false


# --- Pure profile maths (testable with a synthetic {"s","t"} dict) ----------------

# [lo_index, frac] such that `x` sits `frac` of the way from arr[lo] to arr[lo+1].
# Clamps at both ends (frac 0 at/before the first sample, 1 at/after the last) rather
# than extrapolating, so a `t`/`s` past the profile's range holds at the profile's own
# edge value instead of running off it.
static func _bracket(arr: PackedFloat32Array, x: float) -> Array:
	var n := arr.size()
	if n == 0:
		return [-1, 0.0]
	if n == 1 or x <= arr[0]:
		return [0, 0.0]
	if x >= arr[n - 1]:
		return [n - 2, 1.0]
	var lo := 0
	var hi := n - 1
	while hi - lo > 1:
		var mid := (lo + hi) / 2
		if arr[mid] <= x:
			lo = mid
		else:
			hi = mid
	var span: float = arr[hi] - arr[lo]
	var frac := 0.0 if span <= 0.0 else (x - arr[lo]) / span
	return [lo, frac]


# Distance (m) along the track the rival has covered at race time `t` (s), per
# `profile` ({"s","t"} from RegionRunMode.stage_target_profile). 0.0 for an
# empty/degenerate profile.
static func distance_at_time(profile: Dictionary, t: float) -> float:
	var t_arr: PackedFloat32Array = profile.get("t", PackedFloat32Array())
	var s_arr: PackedFloat32Array = profile.get("s", PackedFloat32Array())
	if t_arr.is_empty() or s_arr.is_empty():
		return 0.0
	var b := _bracket(t_arr, t)
	var lo: int = b[0]
	var frac: float = b[1]
	return lerpf(s_arr[lo], s_arr[lo + 1], frac)


# Race time (s) the rival reaches distance `s_m`, per `profile`. 0.0 for an
# empty/degenerate profile. This is the HUD delta's other half: world.gd/
# stage_manager.gd call this at the PLAYER's live distance and compare the result
# against the player's own elapsed stage time.
static func time_at_distance(profile: Dictionary, s_m: float) -> float:
	var s_arr: PackedFloat32Array = profile.get("s", PackedFloat32Array())
	var t_arr: PackedFloat32Array = profile.get("t", PackedFloat32Array())
	if s_arr.is_empty() or t_arr.is_empty():
		return 0.0
	var b := _bracket(s_arr, s_m)
	var lo: int = b[0]
	var frac: float = b[1]
	return lerpf(t_arr[lo], t_arr[lo + 1], frac)


# Total profile duration (s) — the last sample of profile["t"], or 0.0 for an
# empty/degenerate profile (no target, nothing to show).
static func profile_duration(profile: Dictionary) -> float:
	var t_arr: PackedFloat32Array = profile.get("t", PackedFloat32Array())
	return t_arr[t_arr.size() - 1] if not t_arr.is_empty() else 0.0


# --- Live instance (owns a Car, poses it every frame) -----------------------------

# Build (once) and wire the ghost's Car. `track_progress` supplies the arc-length
# space (origin_offset/sample_at) the ghost is posed in; `terrain` seats it on the
# ground the same way start_line.gd seats the player. Safe to call again with a new
# `profile` on a stage change — the Car is reused, not rebuilt.
func setup(track_progress: Node, terrain: Node, profile: Dictionary) -> void:
	_track_progress = track_progress
	_terrain = terrain
	_profile = profile
	if _car == null:
		_car = Scenes.car_scene().instantiate() as Node3D
		_car.kinematic_pose = true
		# The ghost is never simulated by the physics server: kinematic_pose stops
		# THIS car's own script from stepping its drivetrain/engine, but the body is
		# still a VehicleBody3D the physics server would otherwise integrate gravity
		# and collisions on between our per-frame transform writes below. FREEZE_MODE
		# _KINEMATIC turns it into a driven-by-script body the server never moves on
		# its own, and zeroing the layers/mask means it can never push (or be pushed
		# by) the player's real car. See features/rival-ghost.md.
		_car.freeze = true
		_car.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		_car.collision_layer = 0
		_car.collision_mask = 0
		add_child(_car)
	_car.visible = true


func has_car() -> bool:
	return is_instance_valid(_car)


func car() -> Node3D:
	return _car


# Whether this ghost has anything to show — an empty profile means the stage's
# track was degenerate (no target, per RegionRunMode.stage_target_ms), so there is
# no rival to pose.
func has_profile() -> bool:
	return not _profile.is_empty() and profile_duration(_profile) > 0.0


# Reset the ghost's own clock to the start of the profile. `looping` selects the
# start-line reveal's fmod(t, duration) idle (advance()); a live run instead drives
# the ghost from an EXTERNAL clock via pose_at(), which ignores this entirely.
func reset(looping := false) -> void:
	_t = 0.0
	_looping = looping


func hide_ghost() -> void:
	if is_instance_valid(_car):
		_car.visible = false


func free_ghost() -> void:
	if is_instance_valid(_car):
		_car.queue_free()
	_car = null


# Advance the ghost's OWN clock by `delta` and repose it — the start-line idle
# (looping) and, if a caller chooses to keep driving it that way, a live run
# (un-looped: it holds at the finish once `t` passes the profile's duration, rather
# than looping mid-run). No-op with no car or nothing to show.
func advance(delta: float) -> void:
	if not is_instance_valid(_car) or not has_profile():
		return
	_t += delta
	if _looping:
		_t = fmod(_t, profile_duration(_profile))
	pose_at(_t)


# Pose the ghost at an EXTERNAL race time (StageManager.elapsed(), during RUNNING) —
# the counterpart to advance()'s self-driven clock. No-op with no car, no profile,
# or no track_progress (a bare test/dev harness with no live track).
func pose_at(t: float) -> void:
	if not is_instance_valid(_car) or not has_profile() or _track_progress == null:
		return
	_pose_car_at_distance(distance_at_time(_profile, t))


func _pose_car_at_distance(s: float) -> void:
	if not (_track_progress.has_method("origin_offset") and _track_progress.has_method("sample_at")):
		return
	var origin: float = _track_progress.origin_offset()
	var here: Vector2 = _track_progress.sample_at(origin + s)
	var ahead: Vector2 = _track_progress.sample_at(origin + s + TANGENT_EPS_M)
	var fwd := Vector3(ahead.x - here.x, 0.0, ahead.y - here.y)
	if fwd.length() < 0.001:
		fwd = -_car.global_transform.basis.z
	var basis := Basis.looking_at(fwd, Vector3.UP)
	var pos := Vector3(here.x, _ground_y(here.x, here.y), here.y)
	# Nudge sideways off the centerline, purely cosmetic (see GHOST_LATERAL_OFFSET_M) —
	# applied in the car's own right vector so it stays a consistent lane-width offset
	# through corners rather than a fixed world-space nudge.
	pos += basis.x * GHOST_LATERAL_OFFSET_M
	_car.global_transform = Transform3D(basis, pos)


func _ground_y(x: float, z: float) -> float:
	if _terrain != null and _terrain.has_method("height_at"):
		return _terrain.height_at(x, z) + Config.data.start_spawn_clearance
	return Config.data.start_spawn_clearance
