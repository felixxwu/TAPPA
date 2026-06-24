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

var _centerline: Curve2D
var _baked_length: float
var _car: Node            # a Car (VehicleBody3D) — uses global_transform + reset_to
var _terrain: Node        # a TerrainManager (height_at), or null on flat fixtures

# Furthest baked offset (metres along the curve) ever reached while on-road —
# this IS the monotonic progress counter. Driving backwards lowers the live
# offset but never this.
var _best_offset := 0.0
# The 3D pose to restore on an off-track event: on the centerline at
# _best_offset, lifted to ground + spawn_clearance, facing along the road.
var _best_reset: Transform3D


# Wire the manager to a freshly generated track. Seeds progress at the offset
# nearest the spawn so the car doesn't read as starting mid-track.
func setup(centerline: Curve2D, car: Node, terrain: Node) -> void:
	_centerline = centerline
	_baked_length = centerline.get_baked_length()
	_car = car
	_terrain = terrain
	var p: Vector3 = car.global_transform.origin
	_best_offset = _centerline.get_closest_offset(Vector2(p.x, p.z))
	_best_reset = _reset_xform_at(_best_offset)
	# Safety: the global nearest-point query is only reliable while the threshold
	# stays well inside the generator's section spacing.
	assert(Config.data.track_progress_max_dist_m < Config.data.track_clearance,
		"track_progress_max_dist_m must stay below track_clearance")


# Re-point at a freshly spawned car on the same track (a car swap), resetting
# progress to the new car's spawn offset.
func retarget(car: Node, terrain: Node) -> void:
	setup(_centerline, car, terrain)


func _physics_process(_delta: float) -> void:
	if _centerline == null or _car == null:
		return
	var p: Vector3 = _car.global_transform.origin
	var here := Vector2(p.x, p.z)
	var offset := _centerline.get_closest_offset(here)
	var on_curve := _centerline.sample_baked(offset)
	var dist := here.distance_to(on_curve)
	if dist <= Config.data.track_progress_max_dist_m:
		if offset > _best_offset:
			_best_offset = offset
			_best_reset = _reset_xform_at(offset)
	elif Config.data.off_track_reset_enabled:
		_car.reset_to(_best_reset)


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


# 0.0 .. 1.0 fraction of the track reached. Used by the HUD and (later) the
# stage-completion gate (todo/stage-start-and-end.md).
func progress_percent() -> float:
	return _best_offset / _baked_length if _baked_length > 0.0 else 0.0
