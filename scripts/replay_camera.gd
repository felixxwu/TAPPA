class_name ReplayCamera
extends Camera3D

enum Shot { ORBIT, FLYBY, WHEEL, HIGH_WIDE, ROADSIDE }

const SHOT_DWELL := 4.0

# ROADSIDE — a planted "someone filming from the verge" shot. Unlike the other shots
# (which track the car every frame), the camera STAYS PUT at a fixed spot beside the
# road a little further up, locks onto the car the whole way through, and only cuts to
# the next plant once the car has passed it and driven off for a bit. It shows a few
# such trackside positions, then the rotation moves on to the other shot types.
const ROADSIDE_AHEAD := 35.0        # plant this far up the road ahead of the car
const ROADSIDE_SIDE := 0.0          # lateral offset from the car's line (off the road)
const ROADSIDE_HEIGHT := 1.6        # height ABOVE the terrain surface — a standing spectator
const ROADSIDE_REPLANT_AHEAD := 40.0  # car must drive this far PAST the plant to cut
const ROADSIDE_PLANTS := 3          # trackside positions to show before rotating away

var _target: Node3D
var _rec: ReplayRecorder
# Terrain used to seat the roadside plant on the actual ground (its XZ can be metres off
# the road, on higher/lower verge, so the car's road height would sink or float it).
# Optional: without it the plant falls back to the car's height + ROADSIDE_HEIGHT.
var _terrain: TerrainManager
# Lake water surface height. The plant is never seated below this, so a spot over a
# submerged basin puts the camera above the water rather than under it. -INF = no water.
var _water_level := -INF
var _shot := 0
var _shot_age := 0.0
var _orbit_angle := 0.0

# Smoothed unit direction the car is travelling, tracked from its frame-to-frame
# movement so the roadside plant can be placed ahead of (and beside) the real path —
# no dependency on the car's facing (it can be sideways in a slide) or on the recorder.
var _travel_dir := Vector3.ZERO
var _prev_car_pos := Vector3.ZERO
var _have_prev := false

# ROADSIDE state: the current planted world position, which side of the road it sits on
# (flips each re-plant), whether a plant is live, and how many plants this stint has run.
var _plant_pos := Vector3.ZERO
var _plant_side := 1
var _has_plant := false
var _roadside_plants := 0

func setup(target: Node3D, recorder: ReplayRecorder, terrain: TerrainManager = null,
		water_level := -INF) -> void:
	_target = target
	_rec = recorder
	_terrain = terrain
	_water_level = water_level
	_shot = 0
	_shot_age = 0.0
	_have_prev = false
	_travel_dir = Vector3.ZERO
	_reset_roadside()

func current_shot() -> int:
	return _shot

func _process(delta: float) -> void:
	_tick(delta)

# Deterministic, testable per-frame update (no RNG, no engine clock).
func _tick(delta: float) -> void:
	if _target == null:
		return
	var c := _target.global_position
	_update_travel_dir(c)
	_shot_age += delta
	# ROADSIDE cuts are driven by the car passing the plant, not by the dwell timer;
	# every other shot rotates on the fixed dwell.
	if _shot != Shot.ROADSIDE and _shot_age >= SHOT_DWELL:
		_advance_shot()
	_orbit_angle += delta * 0.4
	var pos := c
	# Most shots frame the car itself; the wheel cam instead looks FORWARD down the track.
	var look_target := c
	match _shot:
		Shot.ORBIT:
			pos = c + Vector3(cos(_orbit_angle), 0.35, sin(_orbit_angle)) * 9.0
		Shot.FLYBY:
			pos = c + Vector3(6.0, 2.0, 6.0)
		Shot.WHEEL:
			var b := _target.global_transform.basis
			var fwd := (-b.z).normalized()
			var right := b.x.normalized()
			var up := b.y.normalized()
			# Onboard rig down and BEHIND the front wheel: low (near hub/ground height) and in
			# line with the wheel laterally, sitting back toward the car's middle so the front
			# wheel (ahead of the body origin, at the front axle) is actually in shot in the
			# near foreground, looking ahead along the road.
			pos = c + fwd * 0.2 + right * 0.95 + up * 0.2
			look_target = c + fwd * 14.0 + right * 0.5
		Shot.HIGH_WIDE:
			pos = c + Vector3(0.0, 14.0, 16.0)
		Shot.ROADSIDE:
			pos = _roadside_position(c)
	global_position = pos
	if pos.distance_to(look_target) > 0.01:
		look_at(look_target, Vector3.UP)

# Track a smoothed travel direction from the car's movement, so a slide (car facing away
# from travel) or a stationary frame doesn't throw off where the roadside cam plants.
func _update_travel_dir(c: Vector3) -> void:
	if _have_prev:
		var move := c - _prev_car_pos
		if move.length() > 1e-4:
			var dir := move.normalized()
			_travel_dir = dir if _travel_dir == Vector3.ZERO else _travel_dir.lerp(dir, 0.15).normalized()
	_prev_car_pos = c
	_have_prev = true
	if _travel_dir == Vector3.ZERO:
		# No motion yet — fall back to the car's facing, then to a fixed forward.
		_travel_dir = -_target.global_transform.basis.z
		if _travel_dir.length() < 1e-4:
			_travel_dir = Vector3.FORWARD
		else:
			_travel_dir = _travel_dir.normalized()

# The planted roadside position for this frame. Plants on first use / after a re-plant,
# then holds still until the car has driven ROADSIDE_REPLANT_AHEAD past it — at which
# point it re-plants further up on the opposite side, or hands back to the rotation once
# ROADSIDE_PLANTS positions have been shown.
func _roadside_position(c: Vector3) -> Vector3:
	if not _has_plant:
		_plant(c)
	# How far the car is along the travel direction relative to the plant: negative while
	# approaching, ~0 abreast, positive once it has passed and is driving away.
	var along := (c - _plant_pos).dot(_travel_dir)
	if along > ROADSIDE_REPLANT_AHEAD:
		_roadside_plants += 1
		if _roadside_plants >= ROADSIDE_PLANTS:
			_advance_shot()  # seen enough trackside angles — back to the rotation
			return global_position
		_plant_side = -_plant_side  # next operator films from the other verge
		_plant(c)
	return _plant_pos

# Plant a fixed camera spot beside the road, ROADSIDE_AHEAD up the car's travel line and
# ROADSIDE_SIDE off to the current side, seated ROADSIDE_HEIGHT above the ground. The seat
# height is the sampled terrain surface, but CLAMPED UP to the track height (the car's
# current road height): on a CLIFF (terrain above the track) the camera spawns at the top,
# but in a PIT (terrain below the track) it's lifted to track level so it isn't buried in a
# hole where it can't see the car. Also never seated below the water surface (a spot over a
# lake sits above the water). Foliage the plant lands in dithers out near the camera (the
# tree / bush near-fade shaders), so the camera stays close to the road rather than being
# pushed out to dodge it. Falls back to the car's height when no terrain is wired.
func _plant(c: Vector3) -> void:
	var right := _travel_dir.cross(Vector3.UP)
	if right.length() < 1e-4:
		right = Vector3.RIGHT
	right = right.normalized()
	var spot := c + _travel_dir * ROADSIDE_AHEAD + right * (_plant_side * ROADSIDE_SIDE)
	var ground := c.y
	if _terrain != null:
		# Cliff: keep the (higher) terrain top. Pit: clamp up to the track height (c.y) so
		# the camera isn't sunk in a deep hole with no view.
		ground = maxf(_terrain.height_at(spot.x, spot.z), c.y)
	# Never below the water surface either: over a submerged basin the camera sits above it.
	ground = maxf(ground, _water_level)
	_plant_pos = Vector3(spot.x, ground + ROADSIDE_HEIGHT, spot.z)
	_has_plant = true

func _advance_shot() -> void:
	_shot_age = 0.0
	_shot = (_shot + 1) % Shot.size()
	_reset_roadside()

func _reset_roadside() -> void:
	_has_plant = false
	_roadside_plants = 0
	_plant_side = 1
