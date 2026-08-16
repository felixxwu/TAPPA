extends RefCounted
class_name BenchmarkTrack

# The fixed test track behind CarPerformance's rating — a Forza-style benchmark lap.
# See docs/superpowers/specs/2026-08-15-car-performance-rating-design.md.
#
# Layout, in order:
#   1. a straight  — acceleration and top speed
#   2. a hairpin   — low-speed cornering and corner exit
#   3. N sweepers  — high-speed cornering, where downforce shows up
#
# The sections are NOT timed individually: the rating comes from the single total
# time. Their only job is to make one lap exercise all three regimes, so that the
# lengths/radii become the balance levers (GameConfig.benchmark_*).
#
# WHY THIS ISN'T TrackFixtures: the fixture helpers each return an independently
# ORIGINATED curve, so chaining them would butt two curves together at an arbitrary
# angle. LapTimeModel._curvature_profile reads heading change per sample, so a kink
# reads as an enormous kappa, and the nonlinear mu_g/kappa cap turns that into a hard
# arbitrary slowdown that would dominate the benchmark. Every segment here is joined
# with continuous POSITION and TANGENT, and carries real Bezier handles the way
# TrackGenerator builds real track.
#
# Handedness is cosmetic. _curvature_profile takes absf(), so a right hairpin and a
# left sweeper are indistinguishable to the solver; the signs below match the design's
# description for readability and nothing asserts on them.

const _LEFT := 1.0
const _RIGHT := -1.0

# Points per quarter-turn of arc. Handles do the curving, but the (4/3)*tan(dtheta/4)*r
# approximation ripples in CURVATURE between points even where position error is tiny,
# and LapTimeModel caps speed on curvature — so this is set by how flat kappa needs to
# be, not by how close the path is. At 8 per quarter (~11 degrees a segment) the ripple
# is well inside the tightest authored corner's own curvature.
const ARC_STEPS_PER_QUARTER := 8


# The benchmark track for the current GameConfig, as the {"centerline", "pieces"} dict
# LapTimeModel consumes.
static func build(cfg: GameConfig = null) -> Dictionary:
	var c: GameConfig = cfg if cfg != null else Config.data
	return build_from(c.benchmark_straight_m, c.benchmark_hairpin_radius_m,
		c.benchmark_sweeper_radius_m, c.benchmark_sweeper_count)


# Explicit-parameter form, so calibration tooling can sweep the knobs without writing
# to the live config.
static func build_from(straight_m: float, hairpin_radius_m: float,
		sweeper_radius_m: float, sweeper_count: int) -> Dictionary:
	# Each entry is {pos, tan, h_in, h_out}; merged at junctions so a shared point keeps
	# one tangent and never doubles up.
	var pts: Array[Dictionary] = []
	var pos := Vector2.ZERO
	var tan := Vector2(0.0, -1.0)   # world -Z, matching TrackFixtures' convention

	var state := {"pos": pos, "tan": tan}
	_add_straight(pts, state, maxf(straight_m, 0.0))
	_add_arc(pts, state, maxf(hairpin_radius_m, 0.1), PI * _RIGHT)
	for _i in maxi(sweeper_count, 0):
		_add_arc(pts, state, maxf(sweeper_radius_m, 0.1), (PI * 0.5) * _LEFT)

	var curve := Curve2D.new()
	for p in pts:
		var t: Vector2 = p["tan"]
		curve.add_point(p["pos"], -t * float(p["h_in"]), t * float(p["h_out"]))
	return {"centerline": curve, "pieces": []}


# Append a point, merging into the previous one when they coincide. The merge is what
# keeps the joins tangent-continuous: the junction is ONE curve point carrying the
# incoming handle and the outgoing handle, not two stacked points.
static func _push(pts: Array[Dictionary], pos: Vector2, tan: Vector2, h_in: float, h_out: float) -> void:
	if not pts.is_empty():
		var last: Dictionary = pts[-1]
		if (last["pos"] as Vector2).distance_to(pos) < 0.001:
			last["h_out"] = h_out
			# The incoming tangent wins: a straight->arc join must leave along the arc.
			last["tan"] = tan
			return
	pts.append({"pos": pos, "tan": tan, "h_in": h_in, "h_out": h_out})


static func _add_straight(pts: Array[Dictionary], state: Dictionary, length: float) -> void:
	if length <= 0.0:
		return
	var pos: Vector2 = state["pos"]
	var tan: Vector2 = state["tan"]
	# Zero handles: a straight must stay straight, and the junction's other side
	# supplies the handle that curves into the next segment.
	_push(pts, pos, tan, 0.0, 0.0)
	var end := pos + tan * length
	_push(pts, end, tan, 0.0, 0.0)
	state["pos"] = end


# A circular arc of `radius`, turning by `sweep_rad` (signed: + left, - right), starting
# from the current position and tangent so the join is smooth by construction.
static func _add_arc(pts: Array[Dictionary], state: Dictionary, radius: float, sweep_rad: float) -> void:
	if is_zero_approx(sweep_rad):
		return
	var pos: Vector2 = state["pos"]
	var tan: Vector2 = state["tan"]
	var turn_sign := signf(sweep_rad)
	# Centre sits perpendicular to the tangent, on the inside of the turn.
	var left_perp := Vector2(-tan.y, tan.x)
	var centre := pos + left_perp * radius * turn_sign
	var spoke := pos - centre

	var steps := maxi(int(ceil(absf(sweep_rad) / (PI * 0.5) * ARC_STEPS_PER_QUARTER)), 2)
	var dtheta := sweep_rad / float(steps)
	var h := radius * (4.0 / 3.0) * tan_abs_quarter(dtheta)

	_push(pts, pos, tan, 0.0, h)
	for i in range(1, steps + 1):
		var a := dtheta * float(i)
		var p := centre + spoke.rotated(a)
		var t := tan.rotated(a)
		var is_last := i == steps
		_push(pts, p, t, h, 0.0 if is_last else h)
		if is_last:
			state["pos"] = p
			state["tan"] = t


# Bezier handle length factor for a circular arc segment spanning dtheta radians.
static func tan_abs_quarter(dtheta: float) -> float:
	return tan(absf(dtheta) / 4.0)
