class_name RoadRecovery
extends Node
# Docs: features/level-editor.md — update in the same change as this file.
# Tests: tests/headless/test_level_view.gd — extend in the same change.
# Puts the car back on the level's roads: on request (R, or the pause menu's "Reset to road"),
# and by itself when the car is stuck. "Stuck" uses the same GameConfig rule and fields
# (recovery_*): stationary AND unable to get out by itself (flipped, flooring it and going
# nowhere, or fallen below the ground) for recovery_timeout_s. A car far below the ground
# (recovery_void_depth_m: it fell through a gap in the streamed collision) goes back at once,
# moving or not. A host with is_off_road (LevelView) also gets the stage's off-road clock: off the
# road for off_road_reset_timeout_s, moving or not, puts it back. A recovery is free: Car.reset_to suppresses impact damage.

@export var car: VehicleBody3D
@export var streamer: Node  # any node with height_at and road_pose (LevelView)

# A reset moved the car to this XZ (hosts reset their swept pickup / rest-stop checks).
signal reset_done(p: Vector2)

var _stuck_time := 0.0
var _off_road_time := 0.0


func _physics_process(delta: float) -> void:
	if car == null or streamer == null:
		return
	if is_wrecked():
		_stuck_time = 0.0
		return
	if is_stuck_step(delta) or off_road_step(delta) or fell_out_of_world():
		reset_now()


# Advance the off-road clock by `delta`; true when the car has been off the road for off_road_reset_timeout_s.
func off_road_step(delta: float) -> bool:
	var cfg: GameConfig = Config.data
	var pos := car.global_position
	if not cfg.off_track_reset_enabled or not streamer.has_method("is_off_road") or not streamer.is_off_road(Vector2(pos.x, pos.z)):
		_off_road_time = 0.0
		return false
	_off_road_time += delta
	return _off_road_time >= cfg.off_road_reset_timeout_s


# Seconds the car has been continuously off the road (0 on it), for a countdown to the reset.
func off_road_seconds() -> float:
	return _off_road_time


# The last-ditch net under the streamed world: the car is far below the ground, which only
# happens by falling through a gap in the collision. Unlike the stuck rule, it doesn't wait for
# the car to stop, because a falling car never does.
func fell_out_of_world() -> bool:
	var cfg: GameConfig = Config.data
	if not cfg.recovery_enabled:
		return false
	var pos := car.global_position
	return pos.y < streamer.height_at(pos.x, pos.z) - cfg.recovery_void_depth_m


# Advance the stuck timer by `delta`; true when it has run out (and it starts again).
func is_stuck_step(delta: float) -> bool:
	var cfg: GameConfig = Config.data
	if not cfg.recovery_enabled:
		_stuck_time = 0.0
		return false
	var stationary := car.linear_velocity.length() < cfg.recovery_speed_mps
	var pos := car.global_position
	var below: bool = pos.y < streamer.height_at(pos.x, pos.z) - cfg.recovery_depth_m
	var flipped := car.global_transform.basis.y.dot(Vector3.UP) < cfg.recovery_upright_dot
	var throttling: bool = car.has_method("is_throttling") and car.is_throttling()
	if not stationary or not (below or flipped or throttling):
		_stuck_time = 0.0
		return false
	_stuck_time += delta
	if _stuck_time < cfg.recovery_timeout_s:
		return false
	_stuck_time = 0.0
	return true


# A car that has given up stays where it is until its Respawn: no reset may revive it.
func is_wrecked() -> bool:
	var dmg: DamageModel = car.get("damage")
	return dmg != null and dmg.thermal and dmg.hp <= 0.0


# Put the car on the nearest road, facing along it in the direction closest to where it was
# pointing. The nitrous tank keeps its charge: only a respawn or travel refills it.
func reset_now() -> void:
	_stuck_time = 0.0
	_off_road_time = 0.0
	if is_wrecked():
		return
	var engine = car.drivetrain.engine
	var charge: float = engine.nitrous_charge
	var p := Vector2(car.global_position.x, car.global_position.z)
	var facing := -car.global_transform.basis.z
	var pose: Transform3D = streamer.road_pose(p, facing)
	car.reset_to(pose)
	engine.nitrous_charge = charge
	reset_done.emit(Vector2(pose.origin.x, pose.origin.z))

