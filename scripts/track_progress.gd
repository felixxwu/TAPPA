class_name TrackProgress
extends Node
# Docs: features/progress.md — update in the same change as this file.
# Tests: tests/headless/test_track_progress.gd — extend in the same change. These are the PRIMARY ones, not all of them: before you change behaviour here, `grep -rn 'TrackProgress' tests/headless/` and read the assertions that pin what you are about to change (5 test files touch this script).
# Tracks how far along the generated road the car has driven, and snaps it back
# onto the road when it has been off it too long. Both behaviours run off the road
# centerline (a Curve2D in the XZ plane, from TrackGenerator), but off two DIFFERENT
# thresholds:
#   - progress accrues within Config.data.track_progress_max_dist_m of the centerline
#     (generous — running wide still banks the metres);
#   - the off-track reset fires after Config.data.off_road_reset_timeout_s spent
#     continuously beyond the road EDGE (the road is a fixed width, so that edge is
#     just track_width * 0.5 + off_road_margin_m).
# See todo/track-progress-and-reset.md.
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

# --- Centerline point table --------------------------------------------------
#
# The window scan above probes the centerline ~181 times per physics tick, and
# TireMarks scans it another ~255 times: at 60 Hz that was ~26k Curve2D.sample_baked
# calls per second, and on wasm the engine-call overhead dominates the actual maths.
# The centerline is STATIC for the whole event, so it is resampled ONCE into a flat
# PackedVector2Array and every per-tick lookup reads that array instead.
#
# The table is linearly INTERPOLATED, never truncated to a cell — quantising to the
# cell size would coarsen progress, split timing and tyre-mark placement. Curve2D
# itself only stores baked points every `bake_interval` (5 m by default) and lerps
# between them, so a ~1 m table lerped the same way tracks sample_baked very closely
# (asserted in tests/headless/test_centerline_table.gd).
#
# Owned here and shared with TireMarks through the static cache below, so the two
# systems resample the same curve once between them.
const BAKE_STEP_M := 1.0

static var _table_curve: WeakRef = null
static var _table_length := -1.0
static var _table_pts := PackedVector2Array()


# The centerline resampled to ~BAKE_STEP_M spacing. Cached on the curve instance (and
# its baked length), so TrackProgress and TireMarks share one table per track; a new
# (or re-baked) curve rebuilds it.
static func baked_points(curve: Curve2D) -> PackedVector2Array:
	if curve == null:
		return PackedVector2Array()
	var length := curve.get_baked_length()
	if _table_curve != null and _table_curve.get_ref() == curve and is_equal_approx(_table_length, length):
		return _table_pts
	var pts := PackedVector2Array()
	if length <= 0.0:
		pts.append(curve.sample_baked(0.0))
	else:
		# One extra point so the LAST sample lands exactly on the baked length, and every
		# cell is the same (slightly sub-BAKE_STEP_M) width — that keeps point_on()'s
		# index/fraction split exact right to the end of the curve.
		var n := maxi(2, int(ceil(length / BAKE_STEP_M)) + 1)
		var step := length / float(n - 1)
		pts.resize(n)
		for i in n:
			pts[i] = curve.sample_baked(minf(i * step, length))
	_table_curve = weakref(curve)
	_table_length = length
	_table_pts = pts
	return pts


# Point at a baked `offset` on a table built by baked_points() for a curve of
# `length` metres — the drop-in replacement for Curve2D.sample_baked(offset).
static func point_on(pts: PackedVector2Array, length: float, offset: float) -> Vector2:
	var n := pts.size()
	if n == 0:
		return Vector2.ZERO
	if n == 1 or length <= 0.0:
		return pts[0]
	var t := clampf(offset, 0.0, length) / (length / float(n - 1))
	var i := int(t)
	if i >= n - 1:
		return pts[n - 1]
	return pts[i].lerp(pts[i + 1], t - float(i))


var _centerline: Curve2D
var _baked_length: float
var _pts := PackedVector2Array()   # centerline point table (see baked_points)
var _car: Node            # a Car (VehicleBody3D) — uses global_transform + reset_to
var _terrain: Node        # a TerrainManager (height_at), or null on flat fixtures

# Furthest baked offset (metres along the curve) ever reached while on-road —
# this IS the monotonic progress counter. Driving backwards lowers the live
# offset but never this.
var _best_offset := 0.0
# The arc offset that reads as 0% — the start line, not the curve's start. The
# progress centerline includes a straight lead-in BEHIND the start (so the queue
# car sits on road), so the curve begins a little before the line;
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

# Seconds the car has been CONTINUOUSLY off the road — the off-track reset clock
# (features/progress.md). Accumulates in _update_off_road while the car is beyond
# off_road_edge_m(), fires the reset at off_road_reset_timeout_s. Zeroed the moment
# the car is back on the road, and
# on every reset/re-anchor path so a fresh run never starts part-way through.
var _off_road_time := 0.0


# Wire the manager to a freshly generated track. Seeds progress at the offset
# nearest the spawn so the car doesn't read as starting mid-track.
func setup(centerline: Curve2D, car: Node, terrain: Node, finish_off := -1.0) -> void:
	_centerline = centerline
	_baked_length = centerline.get_baked_length()
	_pts = baked_points(centerline)
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
	_off_road_time = 0.0
	_stuck_time = 0.0


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
	# The car has just been placed on the line; anything it accumulated while being
	# staged (reset onto a grid slot, settling) is not the player's off-road time.
	_off_road_time = 0.0
	_stuck_time = 0.0


# The pose the off-track / stuck recovery would snap the car to: on the centerline
# at the furthest progress reached so far, facing along the road. Shared with the
# pause menu's "Reset to track" button so a manual reset lands the car back on the
# road at its current progress (not all the way back at the start line).
func recovery_pose() -> Transform3D:
	return _best_reset


# The pose the pause-menu "Reset to track" button snaps the car to: the centerline
# beside the car's CURRENT position, facing along the road — "the middle of the road,
# regardless of where the car is right now". Unlike recovery_pose() (pinned to the
# furthest offset reached, which freezes the moment the car leaves the leash and so
# can sit anywhere relative to a strayed car), this does a fresh global nearest-point
# query, so a car sitting off-road — behind or ahead of its best progress — always
# resets to the road right where it is. Falls back to the recovery pose if the track
# isn't set up yet.
func manual_reset_pose() -> Transform3D:
	if _centerline == null or _car == null:
		return _best_reset
	var p: Vector3 = _car.global_transform.origin
	var offset := _centerline.get_closest_offset(Vector2(p.x, p.z))
	return _reset_xform_at(offset)


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
	var p: Vector3 = _car.global_transform.origin
	# Fallen into water/off the world entirely: just check the Y coordinate,
	# independent of the lateral off-track leash below (a car can be perfectly
	# on-line laterally but have dropped straight down through a lake). On a
	# track with water, the per-track flood height (`track_water_level_m`, set
	# per rally event — see features/lakes.md) is the relevant threshold, not a
	# fixed constant, since it varies per track. `fell_off_world_y` is the
	# fallback for tracks with no water at all (a sheer drop off the map).
	var cfg: GameConfig = Config.data
	var underwater := cfg.water_enabled \
		and p.y < cfg.track_water_level_m - cfg.water_submersion_reset_depth_m
	if underwater or p.y < cfg.fell_off_world_y:
		_car.reset_to(_best_reset)
		_stuck_time = 0.0
		_off_road_time = 0.0  # already back on the road; don't carry the clock over
		return
	var here := Vector2(p.x, p.z)
	var offset := _local_closest_offset(here)
	var on_curve := _point_at(offset)
	var dist := here.distance_to(on_curve)
	if dist <= cfg.track_progress_max_dist_m:
		if offset > _best_offset:
			_best_offset = offset
			_best_reset = _reset_xform_at(offset)
	# The reset already teleported the car back onto the road, so the stuck watchdog
	# has nothing left to judge this tick — skip it rather than let both fire.
	if _update_off_road(delta, dist):
		return
	_update_recovery(delta, p, on_curve)


# Lateral distance from the centerline, in metres, at which the car counts as OFF
# the road. The road is a FIXED width, so this is pure geometry: half that width
# plus off_road_margin_m, which keeps a wheel clipping the verge or a tail-out slide
# from starting the clock.
func off_road_edge_m() -> float:
	var cfg: GameConfig = Config.data
	return cfg.track_width * 0.5 + cfg.off_road_margin_m


# Time-based off-track reset (features/progress.md). Accumulate _off_road_time while
# the car is beyond the road edge and snap it back to the last on-road pose once that
# passes off_road_reset_timeout_s; being back on the road zeroes the clock.
#
# TIME, not distance, is the trigger. A distance leash left the worst case unhandled:
# bogged in a ditch a couple of metres off the verge, the car can neither climb back
# onto the road nor get far enough out to trip the leash, so the run just stalls with
# no way out. The stuck watchdog below doesn't catch it either — that one requires the
# car to be STATIONARY, and a car thrashing back and forth in a ditch isn't. A clock
# always expires. It also makes the rule legible: you get N seconds off the road, and
# how far out you went never enters into it.
#
# Returns true when it fired a reset, so the caller can skip the stuck watchdog.
func _update_off_road(delta: float, dist: float) -> bool:
	var cfg: GameConfig = Config.data
	if not cfg.off_track_reset_enabled or dist <= off_road_edge_m():
		_off_road_time = 0.0
		return false
	_off_road_time += delta
	if _off_road_time < cfg.off_road_reset_timeout_s:
		return false
	_car.reset_to(_best_reset)
	_off_road_time = 0.0
	_stuck_time = 0.0  # the teleport already recovered it; don't double-fire
	return true


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
		var d := here.distance_squared_to(_point_at(o))
		if d < best_d:
			best_d = d
			best_o = o
		o += SEARCH_STEP_M
	# Always test the exact far edge of the window too. The stepped loop stops up to
	# SEARCH_STEP_M short of `hi`, so at the very end of the curve (hi == baked_length)
	# progress would otherwise cap ~1 m short — never quite 100%. Sampling `hi`
	# exactly lets progress reach the finish line (and the 100% stage-complete edge).
	var d_hi := here.distance_squared_to(_point_at(hi))
	if d_hi < best_d:
		best_o = hi
	return best_o


# Point on the centerline at a baked offset — reads the resampled table (see
# baked_points), so a per-tick window scan costs array maths, not engine calls.
func _point_at(offset: float) -> Vector2:
	return point_on(_pts, _baked_length, offset)


# Convert a baked offset on the 2D curve into a 3D pose on the road facing along
# the road's forward tangent (a Node3D faces -Z, so -Z ends up down the road).
func _reset_xform_at(offset: float) -> Transform3D:
	var here := _point_at(offset)
	# Forward tangent: sample a little further along, falling back to behind at
	# the very end of the curve.
	var ahead := _point_at(minf(offset + 1.0, _baked_length))
	var dir2 := ahead - here
	if dir2.length() < 0.001:
		dir2 = here - _point_at(maxf(offset - 1.0, 0.0))
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


# Seconds the car has been continuously off the road — 0 whenever it's on the road
# (or the reset is disabled).
func off_road_time() -> float:
	return _off_road_time
