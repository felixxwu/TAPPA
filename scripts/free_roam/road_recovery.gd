class_name RoadRecovery
extends Node
# Docs: features/free-roam.md — update in the same change as this file.
# Tests: tests/headless/test_free_roam.gd — extend in the same change.
# Puts the car back on the road network: on request (R, or the pause menu's "Reset to road"),
# and by itself when the car is stuck. It's the free-roam stand-in for TrackProgress' recovery,
# which assumes a single stage centreline. "Stuck" uses the same GameConfig rule and fields
# (recovery_*): stationary AND unable to get out by itself (flipped, flooring it and going
# nowhere, or fallen below the ground) for recovery_timeout_s. A recovery is free: Car.reset_to
# suppresses impact damage.

@export var car: VehicleBody3D
@export var streamer: TerrainStreamer

var _stuck_time := 0.0


func _physics_process(delta: float) -> void:
	if car == null or streamer == null:
		return
	if is_stuck_step(delta):
		reset_now()


# Advance the stuck timer by `delta`; true when it has run out (and it starts again).
func is_stuck_step(delta: float) -> bool:
	var cfg: GameConfig = Config.data
	if not cfg.recovery_enabled:
		_stuck_time = 0.0
		return false
	var stationary := car.linear_velocity.length() < cfg.recovery_speed_mps
	var pos := car.global_position
	var below := pos.y < streamer.height_at(pos.x, pos.z) - cfg.recovery_depth_m
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


# Put the car on the nearest road, facing along it in the direction closest to where it was
# pointing.
func reset_now() -> void:
	_stuck_time = 0.0
	var p := Vector2(car.global_position.x, car.global_position.z)
	car.reset_to(road_pose(streamer, p, -car.global_transform.basis.z))


# A pose on the nearest road to `p`, facing along the road in the direction closest to `facing`.
static func road_pose(st: TerrainStreamer, p: Vector2, facing: Vector3) -> Transform3D:
	var net := st.network
	if not net.nearest(p.x, p.y, 100000.0):
		return Transform3D(Basis.IDENTITY, Vector3(p.x, st.height_at(p.x, p.y) + 2.0, p.y))
	var q := net.hit_q
	var dir := Vector3(net.hit_dir.x, 0.0, net.hit_dir.y)
	if dir.dot(facing) < 0.0:
		dir = -dir
	var pos := Vector3(q.x, st.height_at(q.x, q.y) + 1.0, q.y)
	return Transform3D(Basis.looking_at(dir, Vector3.UP), pos)
