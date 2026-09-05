class_name MenuShowcaseCamera
extends Camera3D
# Docs: features/menu-showcase.md — update in the same change as this file.
# Tests: tests/headless/test_menu_showcase_camera.gd — extend in the same change.
#
# The shot-rotation director for the menu background showcase
# (todo/menu-background-showcase.md). Modelled on scripts/replay_camera.gd's shape
# (a deterministic, testable _tick(delta), a fixed per-shot dwell, look_at per shot)
# but with no followed target: shots are fixed points authored by the caller
# (MenuShowcase._build_shots), not a car being tracked.

const SHOT_DWELL := 6.0
# A gentle circular drift added around each shot's own position, so a held shot
# reads as a slow crane move rather than a locked-off photograph. Small relative to
# the distances shots are framed at.
const DRIFT_RADIUS_M := 1.2
const DRIFT_SPEED := 0.15  # rad/s

# Each entry: {"pos": Vector3, "look_at": Vector3}, authored by the caller.
var _shots: Array = []
var _shot := 0
var _shot_age := 0.0
var _drift_angle := 0.0


func setup(shots: Array) -> void:
	_shots = shots
	_shot = 0
	_shot_age = 0.0
	_drift_angle = 0.0


func current_shot() -> int:
	return _shot


func shot_count() -> int:
	return _shots.size()


func _process(delta: float) -> void:
	_tick(delta)


# Deterministic, testable per-frame update (no RNG, no engine-clock reads) —
# mirrors ReplayCamera._tick's contract.
func _tick(delta: float) -> void:
	if _shots.is_empty():
		return
	_shot_age += delta
	if _shot_age >= SHOT_DWELL:
		_advance_shot()
	_drift_angle += delta * DRIFT_SPEED
	var shot: Dictionary = _shots[_shot]
	var base_pos: Vector3 = shot["pos"]
	var look_target: Vector3 = shot["look_at"]
	var drift := Vector3(cos(_drift_angle), 0.0, sin(_drift_angle)) * DRIFT_RADIUS_M
	var pos := base_pos + drift
	global_position = pos
	if pos.distance_to(look_target) > 0.01:
		look_at(look_target, Vector3.UP)


func _advance_shot() -> void:
	_shot_age = 0.0
	_shot = (_shot + 1) % _shots.size()
