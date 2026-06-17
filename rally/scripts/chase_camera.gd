extends Camera3D

@export var target: Node3D

## Minimum horizontal speed (m/s) before the direction of travel is trusted.
## Below this the car's facing direction is used instead, so the camera stays
## stable when stationary or crawling rather than chasing velocity noise.
const MIN_TRAVEL_SPEED := 1.0

var _distance: float
var _height: float
var _smoothing: float

# Last known horizontal direction of travel (pointing the way the car moves).
var _travel_dir := Vector3.FORWARD


func _ready() -> void:
	var cfg: GameConfig = Config.data
	_distance = cfg.follow_distance
	_height = cfg.follow_height
	_smoothing = cfg.smoothing


func _physics_process(delta: float) -> void:
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

	# Place the camera behind the (smoothed) orbital direction, offset by a
	# horizontal distance and a height, then point it straight at the car.
	global_position = target.global_position - _travel_dir * _distance + Vector3.UP * _height
	look_at(target.global_position, Vector3.UP)
