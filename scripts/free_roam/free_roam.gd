extends Node3D
# Docs: features/free-roam.md — update in the same change as this file.
# Tests: tests/headless/test_free_roam.gd — extend in the same change.
# Free-roam prototype: boots straight onto the streamed road-first island with the first
# library car. Press R to put the car back on the nearest road.
# See todo/2026-10-19-free-roam-pivot.md.

@onready var _streamer: TerrainStreamer = $Terrain
@onready var _car: VehicleBody3D = $Car
@onready var _stats: Label = $HUD/Stats
@onready var _water: MeshInstance3D = $Water


func _ready() -> void:
	_car.apply_car(maxi(0, CarLibrary.index_of(_streamer.settings.car_id)))
	_streamer.focus = _car
	var spawn := _road_pose(Vector2.ZERO, Vector3.FORWARD)
	_car.global_transform = spawn
	var t0 := Time.get_ticks_msec()
	_streamer.prefill()
	print("free roam: prefill %d ms" % (Time.get_ticks_msec() - t0))
	_car.reset_to(spawn)
	_water.position.y = _streamer.settings.water_level_m


func _process(_delta: float) -> void:
	_water.position.x = snappedf(_car.global_position.x, 64.0)
	_water.position.z = snappedf(_car.global_position.z, 64.0)
	var counts := _streamer.chunk_counts()
	var s := _streamer
	_stats.text = "%d km/h\n" % roundi(_car.linear_velocity.length() * 3.6) \
		+ "terrain  %.2f ms this frame (budget %.2f)\n" % [s.stat_used_us / 1000.0, s.settings.budget_us / 1000.0] \
		+ "worst    %.2f ms   over budget %d / %d frames\n" % [s.stat_worst_us / 1000.0, s.stat_overruns, s.stat_frames] \
		+ "queue    %d jobs\n" % s.queued() \
		+ "chunks   %d near  %d far  %d collision\n" % [counts.x, counts.y, counts.z] \
		+ "sample   %.1f µs\n" % s.stat_us_per_sample \
		+ "network  %d nodes  %d links  %.0f km (%d ms)\n" % [
			s.network.nodes.size(), s.network.edges.size(), s.network.total_length_m / 1000.0, s.stat_build_ms] \
		+ "R = back to road"


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		var p := Vector2(_car.global_position.x, _car.global_position.z)
		_car.reset_to(_road_pose(p, -_car.global_transform.basis.z))


# A pose on the nearest road to `p`, facing along the road in the direction closest to `facing`.
func _road_pose(p: Vector2, facing: Vector3) -> Transform3D:
	var net := _streamer.network
	if not net.nearest(p.x, p.y, 100000.0):
		return Transform3D(Basis.IDENTITY, Vector3(p.x, _streamer.height_at(p.x, p.y) + 2.0, p.y))
	var q := net.hit_q
	var dir := Vector3(net.hit_dir.x, 0.0, net.hit_dir.y)
	if dir.dot(facing) < 0.0:
		dir = -dir
	var pos := Vector3(q.x, _streamer.height_at(q.x, q.y) + 1.0, q.y)
	return Transform3D(Basis.looking_at(dir, Vector3.UP), pos)


func _exit_tree() -> void:
	var s := _streamer
	print("free roam: %d frames, %d over budget, worst %.2f ms, %.1f us/sample, %d jobs queued" % [
		s.stat_frames, s.stat_overruns, s.stat_worst_us / 1000.0, s.stat_us_per_sample, s.queued()])
	print("free roam: unit costs (us) ", s._est)
