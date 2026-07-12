class_name ReplayCamera
extends Camera3D

enum Shot { ORBIT, FLYBY, LOW_CHASE, HIGH_WIDE }

const SHOT_DWELL := 4.0

var _target: Node3D
var _rec: ReplayRecorder
var _shot := 0
var _shot_age := 0.0
var _orbit_angle := 0.0

func setup(target: Node3D, recorder: ReplayRecorder) -> void:
	_target = target
	_rec = recorder
	_shot = 0
	_shot_age = 0.0

func current_shot() -> int:
	return _shot

func _process(delta: float) -> void:
	_tick(delta)

# Deterministic, testable per-frame update (no RNG, no engine clock).
func _tick(delta: float) -> void:
	if _target == null:
		return
	_shot_age += delta
	if _shot_age >= SHOT_DWELL:
		_shot_age = 0.0
		_shot = (_shot + 1) % Shot.size()
	_orbit_angle += delta * 0.4
	var c := _target.global_position
	var pos := c
	match _shot:
		Shot.ORBIT:
			pos = c + Vector3(cos(_orbit_angle), 0.35, sin(_orbit_angle)) * 9.0
		Shot.FLYBY:
			pos = c + Vector3(6.0, 2.0, 6.0)
		Shot.LOW_CHASE:
			var back := _target.global_transform.basis.z.normalized()
			pos = c + back * 7.0 + Vector3.UP * 1.2
		Shot.HIGH_WIDE:
			pos = c + Vector3(0.0, 14.0, 16.0)
	global_position = pos
	if pos.distance_to(c) > 0.01:
		look_at(c, Vector3.UP)
