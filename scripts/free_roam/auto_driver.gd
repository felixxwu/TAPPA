class_name AutoDriver
extends Node
# Docs: features/free-roam.md — update in the same change as this file.
# Tests: tests/headless/test_free_roam.gd — extend in the same change.
# Drives the car along the road network by itself, as fast as the road allows, and keeps score
# of how well the streamer keeps up: frames over the terrain budget, and ticks where the car was
# over a chunk with no collision yet (a "hole" — the one thing streaming must never let happen).
#
# The route is planned once from the network (`plan_route`): from the nearest junction it walks
# road to road, preferring links it hasn't driven and that lead away from spawn, until it has
# `route_length_m` of road. Steering is pure pursuit towards a point ahead on the route, and the
# target speed drops before bends (how much the route turns over the next stretch). Started from
# the command line with `--auto-drive` (free_roam.gd), or by tests.

const LOOKAHEAD_MIN_M := 8.0
const LOOKAHEAD_PER_MPS := 0.45
# Speed planning: the fastest the car may take a bend is sqrt(LATERAL_ACCEL / curvature), and it
# must be able to brake down to every such limit ahead of it at BRAKE_DECEL.
const LATERAL_ACCEL := 6.5
const BRAKE_DECEL := 5.5
const PLAN_WINDOW_M := 250.0
const MIN_SPEED_MPS := 8.0
# Stuck: below this speed, or making no progress along the route, for this long, the car is put
# back on the route a little ahead.
const STUCK_SPEED_MPS := 1.5
const STUCK_SECONDS := 4.0
const NO_PROGRESS_SECONDS := 8.0

signal finished(report: Dictionary)

@export var top_speed_mps := 45.0
@export var route_length_m := 3000.0
## Print the report every this many physics ticks (0 = never).
@export var log_every_ticks := 0

var car: VehicleBody3D
var streamer: TerrainStreamer

var route := PackedVector2Array()
var route_cum := PackedFloat64Array()  # arc length at each route point

# The score.
var holes := 0          # physics ticks with the car over a chunk with no collision
var resets := 0         # times the car got stuck and was put back on the route
var driven_m := 0.0
var ticks := 0
var running := false

var _idx := 0
var _stuck_t := 0.0
var _no_progress_t := 0.0
var _last_pos := Vector3.ZERO
var _overruns_at_start := 0
var _frames_at_start := 0


func start(p_car: VehicleBody3D, p_streamer: TerrainStreamer) -> void:
	car = p_car
	streamer = p_streamer
	var p := Vector2(car.global_position.x, car.global_position.z)
	route = plan_route(streamer.network, _nearest_node(streamer.network, p), route_length_m, streamer.settings.world_seed)
	route_cum = cumulative(route)
	_idx = 0
	holes = 0
	resets = 0
	driven_m = 0.0
	ticks = 0
	_stuck_t = 0.0
	_no_progress_t = 0.0
	car.controls_locked = false
	car.handbrake_locked = false
	car.ai_controlled = true
	car.ai_throttle = 0.0
	car.ai_steer = 0.0
	car.ai_handbrake = false
	if "drivetrain" in car and car.drivetrain != null and car.drivetrain.engine != null:
		car.drivetrain.engine.auto = true
	_last_pos = car.global_position
	_overruns_at_start = streamer.stat_overruns
	_frames_at_start = streamer.stat_frames
	running = route.size() >= 2


func report() -> Dictionary:
	return {
		"driven_m": driven_m,
		"route_m": route_cum[route_cum.size() - 1] if not route_cum.is_empty() else 0.0,
		"progress_m": route_cum[_idx] if not route_cum.is_empty() else 0.0,
		"holes": holes,
		"resets": resets,
		"ticks": ticks,
		"frames": streamer.stat_frames - _frames_at_start,
		"overruns": streamer.stat_overruns - _overruns_at_start,
		"worst_ms": streamer.stat_worst_us / 1000.0,
		"overrun_by": streamer.stat_overrun_by,
		"overshoot_ms": streamer.stat_overshoot_us / 1000.0,
		"spikes": streamer.stat_spikes,
		"spike_by": streamer.stat_spike_by,
	}


func _physics_process(delta: float) -> void:
	if not running or not is_instance_valid(car):
		return
	ticks += 1
	if log_every_ticks > 0 and ticks % log_every_ticks == 0:
		print("auto drive: ", report(), " speed ", roundi(car.linear_velocity.length() * 3.6), " km/h")
	var pos := car.global_position
	driven_m += Vector2(pos.x - _last_pos.x, pos.z - _last_pos.z).length()
	_last_pos = pos
	if not streamer.has_collision_at(pos.x, pos.z):
		holes += 1
	var p := Vector2(pos.x, pos.z)
	var was := _idx
	_idx = advance(route, _idx, p)
	if _idx >= route.size() - 2 and p.distance_to(route[route.size() - 1]) < 15.0:
		_finish()
		return
	var speed := car.linear_velocity.length()
	var aim := point_ahead(route, route_cum, _idx, p, LOOKAHEAD_MIN_M + speed * LOOKAHEAD_PER_MPS)
	car.ai_steer = BenchmarkRunner.steer_toward(car.global_transform, aim)
	var target := clampf(safe_speed(route, route_cum, _idx, PLAN_WINDOW_M, LATERAL_ACCEL, BRAKE_DECEL), MIN_SPEED_MPS, top_speed_mps)
	car.ai_throttle = BenchmarkRunner.throttle_for(speed, target)
	_stuck_t = _stuck_t + delta if speed < STUCK_SPEED_MPS else 0.0
	_no_progress_t = _no_progress_t + delta if _idx == was else 0.0
	if _stuck_t > STUCK_SECONDS or _no_progress_t > NO_PROGRESS_SECONDS:
		_unstick()


func _unstick() -> void:
	_stuck_t = 0.0
	_no_progress_t = 0.0
	resets += 1
	var i := mini(_idx + 2, route.size() - 2)
	var a := route[i]
	var dir := (route[i + 1] - a).normalized()
	var pos := Vector3(a.x, streamer.height_at(a.x, a.y) + 1.0, a.y)
	car.reset_to(Transform3D(Basis.looking_at(Vector3(dir.x, 0.0, dir.y), Vector3.UP), pos))
	_last_pos = pos
	_idx = i


func _finish() -> void:
	running = false
	car.ai_throttle = -1.0
	car.ai_steer = 0.0
	finished.emit(report())


# --- route planning (pure) -------------------------------------------------------------------

static func _nearest_node(net: RoadNetwork, p: Vector2) -> int:
	var best := 0
	var best_d := INF
	for i in net.node_x.size():
		var d := Vector2(net.node_x[i] - p.x, net.node_y[i] - p.y).length_squared()
		if d < best_d:
			best_d = d
			best = i
	return best


# A drive along the network from `start_node`: at each junction take a link not yet driven,
# preferring the one that ends furthest from spawn (ties broken by the seed) and avoiding dead
# ends; when every link there has been driven, take any. The drive stops at a dead end. Returns the concatenated polyline, at least `length_m` long
# unless the walk runs out of road.
static func plan_route(net: RoadNetwork, start_node: int, length_m: float, rng_seed: int) -> PackedVector2Array:
	var adj := {}  # node -> Array of edge ids
	for ei in net.edges.size():
		var e := net.edges[ei]
		if not adj.has(e.x): adj[e.x] = []
		if not adj.has(e.y): adj[e.y] = []
		adj[e.x].append(ei)
		adj[e.y].append(ei)
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	var used := {}
	var out := PackedVector2Array()
	var at := start_node
	var total := 0.0
	var prev_edge := -1
	while total < length_m and adj.has(at):
		var best := -1
		var best_score := -INF
		for ei: int in adj[at]:
			var e := net.edges[ei]
			var other := e.y if e.x == at else e.x
			var score := Vector2(net.node_x[other], net.node_y[other]).length() + rng.randf() * 50.0
			if used.has(ei):
				score -= 1.0e6
			if (adj[other] as Array).size() == 1:
				score -= 5.0e5  # a dead end: only worth it when nothing else is new
			if ei == prev_edge:
				score -= 4.0e6
			if score > best_score:
				best_score = score
				best = ei
		if best < 0 or best == prev_edge:
			break  # a dead end: the drive stops here rather than turning round
		used[best] = true
		var pts := net.polyline(best)
		if net.edges[best].x != at:
			pts.reverse()
		for k in pts.size():
			if out.is_empty() or k > 0:
				if not out.is_empty():
					total += out[out.size() - 1].distance_to(pts[k])
				out.append(pts[k])
		var link := net.edges[best]
		at = link.y if link.x == at else link.x
		prev_edge = best
	return out


static func cumulative(pts: PackedVector2Array) -> PackedFloat64Array:
	var cum := PackedFloat64Array()
	var c := 0.0
	for i in pts.size():
		if i > 0:
			c += pts[i - 1].distance_to(pts[i])
		cum.append(c)
	return cum


# The route segment the car is on: the nearest one from `idx` to a few segments ahead. Never
# goes back, and looks only a short way forward so a route that comes back near itself never
# jumps.
static func advance(pts: PackedVector2Array, idx: int, p: Vector2) -> int:
	var best := idx
	var best_d := INF
	for i in range(idx, mini(idx + 6, pts.size() - 1)):
		var d := p.distance_squared_to(Geometry2D.get_closest_point_to_segment(p, pts[i], pts[i + 1]))
		if d < best_d - 1e-6:
			best_d = d
			best = i
	return best


# The point `ahead_m` beyond the car's projection onto segment `idx`.
static func point_ahead(pts: PackedVector2Array, cum: PackedFloat64Array, idx: int, p: Vector2, ahead_m: float) -> Vector2:
	var a := pts[idx]
	var ab := pts[idx + 1] - a
	var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
	var s := cum[idx] + t * ab.length() + ahead_m
	var i := idx
	while i < pts.size() - 2 and cum[i + 1] < s:
		i += 1
	var seg := cum[i + 1] - cum[i]
	var u := clampf((s - cum[i]) / maxf(seg, 1e-6), 0.0, 1.0)
	return pts[i].lerp(pts[i + 1], u)


# The fastest the car can be going now and still make every bend in the next `window_m`: each
# route point's corner limit sqrt(lateral_accel / curvature), raised by what braking at
# `decel` over the distance to it allows.
static func safe_speed(pts: PackedVector2Array, cum: PackedFloat64Array, idx: int, window_m: float,
		lateral_accel: float, decel: float) -> float:
	var best := INF
	var i := idx + 1
	var end_s := cum[idx] + window_m
	while i < pts.size() - 1 and cum[i] < end_s:
		var d0 := pts[i] - pts[i - 1]
		var d1 := pts[i + 1] - pts[i]
		var turn := absf(d0.angle_to(d1))
		var curvature := turn / maxf(0.5 * (d0.length() + d1.length()), 1.0)
		if curvature > 1e-5:
			var corner := sqrt(lateral_accel / curvature)
			var dist := maxf(0.0, cum[i] - cum[idx] - 0.5 * d0.length())
			best = minf(best, sqrt(corner * corner + 2.0 * decel * dist))
		i += 1
	return best
