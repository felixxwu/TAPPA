class_name TrackProgress
extends Node
# Tracks how far along the generated road the car has driven, and snaps it back
# onto the road when it strays too far. Both behaviours run off the road
# centerline (a Curve2D in the XZ plane, from TrackGenerator) and a single
# distance threshold: within Config.data.track_progress_max_dist_m progress
# accrues; crossing beyond it triggers the off-track reset. See
# todo/track-progress-and-reset.md.
#
# Created and wired by world.gd._generate_track once the centerline exists.

# The off-track distance is measured against a LOCAL window of the centerline
# around the current progress, not a global nearest-point query — so a wide reset
# tolerance can't snap onto a different part of the track that happens to pass by
# spatially (a hairpin, a parallel straight). The window slides forward with
# progress; these bound how far back/ahead it samples and at what resolution.
const SEARCH_BACK_M := 40.0
const SEARCH_FWD_M := 140.0
const SEARCH_STEP_M := 1.0

var _centerline: Curve2D
var _baked_length: float
var _car: Node            # a Car (VehicleBody3D) — uses global_transform + reset_to
var _terrain: Node        # a TerrainManager (height_at), or null on flat fixtures

# Furthest baked offset (metres along the curve) ever reached while on-road —
# this IS the monotonic progress counter. Driving backwards lowers the live
# offset but never this.
var _best_offset := 0.0
# The arc offset that reads as 0% — the start line, not the curve's start. The
# progress centerline includes a straight lead-in BEHIND the start (so the queue
# car sits on road), so the curve begins ~start_lead_in_behind_m before the line;
# anchoring progress here keeps the stage from reading several % before the off.
# Re-anchored at the race start by mark_start() so the off is always exactly 0%.
var _origin_offset := 0.0
# The arc offset that reads as 100% — the finish line. Defaults to the curve's
# baked length, but is set SHORTER when the rendered centerline extends past the
# finish (the post-finish runoff road, features/track.md): progress must hit 100%
# at the arch, not at the end of the runoff.
var _finish_offset := 0.0
# The 3D pose to restore on an off-track event: on the centerline at
# _best_offset, lifted to ground + spawn_clearance, facing along the road.
var _best_reset: Transform3D

# Seconds the car has been stuck (stationary AND unable to self-recover) — the stuck
# watchdog (features/progress.md). Accumulates in _update_recovery, fires a free reset
# at recovery_timeout_s. Zeroed the moment the car moves or recovers.
var _stuck_time := 0.0


# Wire the manager to a freshly generated track. Seeds progress at the offset
# nearest the spawn so the car doesn't read as starting mid-track.
func setup(centerline: Curve2D, car: Node, terrain: Node, finish_off := -1.0) -> void:
	_centerline = centerline
	_baked_length = centerline.get_baked_length()
	_finish_offset = _baked_length if finish_off < 0.0 else minf(finish_off, _baked_length)
	_car = car
	_terrain = terrain
	# Seed progress at the spawn. A global nearest-point query is safe here: the car
	# starts on the road at the track's beginning, so there's no ambiguity. From then
	# on the per-tick query is windowed (see _local_closest_offset).
	var p: Vector3 = car.global_transform.origin
	_best_offset = _centerline.get_closest_offset(Vector2(p.x, p.z))
	_origin_offset = _best_offset
	_best_reset = _reset_xform_at(_best_offset)


# Re-anchor 0% to the car's current position — called when the stage actually
# starts (StageManager, on GO), so any roll-up/settle during the start-line
# sequence is zeroed out and the off reads exactly 0%. A global nearest-point
# query is safe here for the same reason as setup(): the car is at the start.
func mark_start() -> void:
	if _centerline == null or _car == null:
		return
	var p: Vector3 = _car.global_transform.origin
	_origin_offset = _centerline.get_closest_offset(Vector2(p.x, p.z))
	_best_offset = _origin_offset
	_best_reset = _reset_xform_at(_best_offset)


# Re-point at a freshly spawned car on the same track (a car swap), resetting
# progress to the new car's spawn offset.
func retarget(car: Node, terrain: Node) -> void:
	setup(_centerline, car, terrain, _finish_offset)


func _physics_process(delta: float) -> void:
	var __t := Time.get_ticks_usec()
	_timed_physics_process(delta)
	PerfLog.track(&"track_progress", Time.get_ticks_usec() - __t)


func _timed_physics_process(delta: float) -> void:
	if _centerline == null or _car == null:
		return
	# During a replay the car is a passive ghost driven along a recording; the loop-wrap
	# jump (finish → start) would trip the off-track leash / stuck watchdog and teleport
	# it mid-replay. Progress tracking is meaningless for the ghost, so skip entirely.
	if _car.get("replay_playback"):
		return
	var p: Vector3 = _car.global_transform.origin
	var here := Vector2(p.x, p.z)
	var offset := _local_closest_offset(here)
	var on_curve := _centerline.sample_baked(offset)
	var dist := here.distance_to(on_curve)
	if dist <= Config.data.track_progress_max_dist_m:
		if offset > _best_offset:
			_best_offset = offset
			_best_reset = _reset_xform_at(offset)
	elif Config.data.off_track_reset_enabled:
		_car.reset_to(_best_reset)
		_stuck_time = 0.0  # lateral reset already recovered it; don't double-fire
		return
	_update_recovery(delta, p, on_curve)


# Stuck-car recovery watchdog (features/progress.md). A car can get trapped INSIDE the
# lateral leash — nose-down in a pit, flipped, or pinned against a wall — where the
# check above never fires. Accumulate _stuck_time while the car is stationary AND can't
# recover on its own (flooring it and going nowhere, flipped, or fallen below the road);
# once it passes recovery_timeout_s, teleport it to the last on-road pose. FREE — a plain
# reset_to (no penalty), and reset_to suppresses impact damage so the recovery costs no HP.
func _update_recovery(delta: float, car_pos: Vector3, nearest_pt: Vector2) -> void:
	var cfg: GameConfig = Config.data
	if not cfg.recovery_enabled or not ("linear_velocity" in _car):
		return
	var stationary: bool = (_car.linear_velocity as Vector3).length() < cfg.recovery_speed_mps
	if not stationary:
		_stuck_time = 0.0
		return
	var road_y := _ground_height(nearest_pt.x, nearest_pt.y)
	var in_pit := car_pos.y < road_y - cfg.recovery_depth_m
	var flipped: bool = _car.global_transform.basis.y.dot(Vector3.UP) < cfg.recovery_upright_dot
	var throttling: bool = _car.has_method("is_throttling") and _car.is_throttling()
	if not (in_pit or flipped or throttling):
		_stuck_time = 0.0
		return
	_stuck_time += delta
	if _stuck_time >= cfg.recovery_timeout_s:
		_car.reset_to(_best_reset)
		_stuck_time = 0.0


# Nearest centerline offset to `here`, searched only within a window around the
# current progress (best_offset − SEARCH_BACK_M .. + SEARCH_FWD_M). Sampling
# locally — rather than Curve2D.get_closest_offset over the whole curve — keeps a
# wide off-track tolerance from snapping onto a spatially-near but along-track-far
# section. Resolution is SEARCH_STEP_M, ample against the metres-wide threshold.
func _local_closest_offset(here: Vector2) -> float:
	var lo := maxf(0.0, _best_offset - SEARCH_BACK_M)
	var hi := minf(_baked_length, _best_offset + SEARCH_FWD_M)
	var best_o := lo
	var best_d := INF
	var o := lo
	while o <= hi:
		var d := here.distance_squared_to(_centerline.sample_baked(o))
		if d < best_d:
			best_d = d
			best_o = o
		o += SEARCH_STEP_M
	# Always test the exact far edge of the window too. The stepped loop stops up to
	# SEARCH_STEP_M short of `hi`, so at the very end of the curve (hi == baked_length)
	# progress would otherwise cap ~1 m short — never quite 100%. Sampling `hi`
	# exactly lets progress reach the finish line (and the 100% stage-complete edge).
	var d_hi := here.distance_squared_to(_centerline.sample_baked(hi))
	if d_hi < best_d:
		best_o = hi
	return best_o


# Dev cheat (F key): jump progress straight to the finish line. Pins progress to
# 100% (so the stage-completion gate trips) and returns the finish pose so the
# caller can teleport the car there. The local-window search in _physics_process
# can't discover a far teleport on its own, so we set _best_offset directly.
func jump_to_finish() -> Transform3D:
	if _centerline == null:
		return Transform3D.IDENTITY
	_best_offset = _finish_offset
	_best_reset = _reset_xform_at(_finish_offset)
	return _best_reset


# Convert a baked offset on the 2D curve into a 3D pose on the road facing along
# the road's forward tangent (a Node3D faces -Z, so -Z ends up down the road).
func _reset_xform_at(offset: float) -> Transform3D:
	var here := _centerline.sample_baked(offset)
	# Forward tangent: sample a little further along, falling back to behind at
	# the very end of the curve.
	var ahead := _centerline.sample_baked(minf(offset + 1.0, _baked_length))
	var dir2 := ahead - here
	if dir2.length() < 0.001:
		dir2 = here - _centerline.sample_baked(maxf(offset - 1.0, 0.0))
	var fwd := Vector3(dir2.x, 0.0, dir2.y)
	if fwd.length() < 0.001:
		fwd = Vector3(0.0, 0.0, 1.0)  # degenerate curve guard
	fwd = fwd.normalized()
	var ground := _ground_height(here.x, here.y)
	var pos := Vector3(here.x, ground + Config.data.spawn_clearance, here.y)
	return Transform3D(Basis.looking_at(fwd, Vector3.UP), pos)


func _ground_height(x: float, z: float) -> float:
	if _terrain != null and _terrain.has_method("height_at"):
		return _terrain.height_at(x, z)
	return 0.0


# --- Readouts (HUD / stage-completion gate) ----------------------------------

func progress_offset() -> float:
	return _best_offset


func baked_length() -> float:
	return _baked_length


# Arc offset of the finish line (100%). Shorter than baked_length() when the
# rendered centerline extends past the finish (the post-finish runoff road).
func finish_offset() -> float:
	return _finish_offset


# 0.0 .. 1.0 fraction of the track reached, measured from the start line
# (_origin_offset) to the finish (baked length) — so the off reads 0% and the
# finish line reads 100%. Used by the HUD and the stage-completion gate.
func progress_percent() -> float:
	var span := _finish_offset - _origin_offset
	if span <= 0.0:
		return 0.0
	return clampf((_best_offset - _origin_offset) / span, 0.0, 1.0)
