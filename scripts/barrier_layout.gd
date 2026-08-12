class_name BarrierLayout
extends RefCounted
# Pure, scene-free planner for the corner barriers (features/barriers.md). Given a
# generated track (centerline Curve2D + pieces, from TrackGenerator.generate) it
# returns one placement dict per 2 m BarrierSection module, forming a continuous
# run along the OUTSIDE of each sharp corner. Mirrors SignLayout / TreeScatter: all
# static, no nodes, unit-testable without a scene. BarrierField (the Node3D) turns
# these placements into meshes + collision.
#
# Each placement:
#   { "pos": Vector2,     # centerline point (XZ) at this module's arc offset
#     "tangent": Vector2, # unit road direction there
#     "side": int,        # +1 / -1 : which road edge — the OUTSIDE of the corner
#     "style": int,       # BarrierSection.Style, from the road surface here
#     "run": int }        # which corner's run this module belongs to (0-based)
#
# `side` uses the same convention as SignLayout/SignField: the edge is
# `pos + side * Vector2(-tangent.y, tangent.x) * distance`.

# Corners that earn a barrier: the SHARP ones, where running wide actually costs
# you. Deliberately a tighter set than SignLayout.TURN_CORNERS (which signs "4 or
# sharper") — a grade 3/4 sweeper doesn't need armco. Names match CornerLibrary.
const BARRIER_CORNERS := ["1", "2", "Square", "Hairpin"]

# Arc step used to estimate the road tangent by finite difference.
const TANGENT_EPS_M := 0.5

# Arc step used either side of a corner's mid-point to measure which way it turns.
# Wide enough that a sharp corner's curvature dwarfs the baked-curve sampling noise.
const CURVE_EPS_M := 3.0

# Resolution the barrier line is walked at when converting between centerline arc
# offsets and distance along the barrier line (see _barrier_walk).
const WALK_STEP_M := 0.25


# Plan every barrier module for a stage. `params` is GameConfig.barrier_render_params().
# `tarmac_at` is an optional `func(pos: Vector2) -> float` returning the 0..1
# tarmac-ness of the road at a centerline point (TerrainManager.surface_at().y);
# when it is not supplied every module falls back to the gravel style.
static func plan(centerline: Curve2D, pieces: Array, params: Dictionary,
		tarmac_at := Callable()) -> Array:
	var out: Array = []
	if centerline == null:
		return out
	var length := centerline.get_baked_length()
	var pitch: float = maxf(float(params.get("section_length_m", 2.0)), 0.1)
	if length <= 0.0 or length < pitch:
		return out
	var lead: float = float(params.get("lead_m", 0.0))
	var threshold: float = float(params.get("tarmac_threshold", 0.5))
	# How far off the centerline the barrier line runs. Modules must be pitched along
	# THAT line, not along the centerline: on the outside of a corner it is the longer
	# arc, so centerline-pitched modules would fan apart. At a 12 m corner with a 4.2 m
	# offset the outer arc is 35% longer — a 0.7 m hole at every joint.
	var lateral: float = float(params.get("track_width", 7.0)) * 0.5 \
		+ float(params.get("road_gap_m", 0.0))

	# Runs are laid in track order, so each can be clamped against the previous
	# one's end and two adjacent sharp corners never stack two barriers on the
	# same stretch of verge.
	var prev_end := 0.0
	var run := 0
	for i in range(pieces.size()):
		var piece: Dictionary = pieces[i]
		if not BARRIER_CORNERS.has(String(piece.get("corner", ""))):
			continue
		var span := _corner_arc(centerline, pieces, i, length)
		var start_off: float = maxf(span.x - lead, prev_end)
		var end_off: float = minf(span.y + lead, length)
		if end_off - start_off < pitch * 0.5:
			continue
		var side := _outside_side(centerline, (span.x + span.y) * 0.5, length)
		# Walk the barrier line over the run so modules can be spaced by ITS arc
		# length rather than the centerline's.
		var walk := _barrier_walk(centerline, length, start_off, end_off, side, lateral)
		var total: float = float(walk[walk.size() - 1]["s"])
		var count := int(floor(total / pitch))
		if count <= 0:
			continue
		# Centre the whole-module run in the available arc, so the barrier is
		# symmetric about the corner rather than biased to its entry.
		var run_start: float = (total - count * pitch) * 0.5
		for k in range(count):
			var offset := _offset_at_distance(walk, run_start + (k + 0.5) * pitch)
			var pos := centerline.sample_baked(offset)
			var tarmac := 0.0
			if tarmac_at.is_valid():
				tarmac = float(tarmac_at.call(pos))
			out.append({
				"pos": pos,
				"tangent": _tangent_at(centerline, offset, length),
				"side": side,
				"style": BarrierSection.style_for_tarmac(tarmac, threshold),
				"run": run,
			})
		prev_end = _offset_at_distance(walk, run_start + count * pitch)
		run += 1
	return out


# Sample the BARRIER LINE — the centerline pushed `lateral` metres toward `side` —
# from `start_off` to `end_off`, returning `[{off, s}]`: the centerline arc offset of
# each sample and the cumulative distance along the barrier line to it. This is the
# lookup that lets modules be pitched along the line they actually stand on.
static func _barrier_walk(centerline: Curve2D, length: float, start_off: float,
		end_off: float, side: int, lateral: float) -> Array:
	var out: Array = []
	var steps: int = maxi(1, int(ceil((end_off - start_off) / WALK_STEP_M)))
	var prev := Vector2.ZERO
	var s := 0.0
	for i in range(steps + 1):
		var off: float = lerpf(start_off, end_off, float(i) / float(steps))
		var pos := centerline.sample_baked(off)
		var tangent := _tangent_at(centerline, off, length)
		var point: Vector2 = pos + float(side) * Vector2(-tangent.y, tangent.x) * lateral
		if i > 0:
			s += point.distance_to(prev)
		prev = point
		out.append({"off": off, "s": s})
	return out


# Invert the walk: the centerline arc offset at distance `s` along the barrier line,
# linearly interpolated between samples (`s` is monotonic along the walk).
static func _offset_at_distance(walk: Array, s: float) -> float:
	for i in range(1, walk.size()):
		var s1: float = float(walk[i]["s"])
		if s1 >= s:
			var s0: float = float(walk[i - 1]["s"])
			var f: float = 0.0 if s1 - s0 < 1e-6 else (s - s0) / (s1 - s0)
			return lerpf(float(walk[i - 1]["off"]), float(walk[i]["off"]), f)
	return float(walk[walk.size() - 1]["off"])


# The arc interval (start, end) the corner in `pieces[i]` occupies. A piece is a
# connecting STRAIGHT of `straight` metres followed by the corner itself, so the
# corner starts `straight` along the piece's entry heading and ends where the NEXT
# piece's entry pose begins (the last piece runs to the end of the centerline).
static func _corner_arc(centerline: Curve2D, pieces: Array, i: int, length: float) -> Vector2:
	var piece: Dictionary = pieces[i]
	var entry_pos: Vector2 = piece["entry_pos"]
	var entry_heading: Vector2 = piece["entry_heading"]
	var corner_entry: Vector2 = entry_pos + entry_heading.normalized() * float(piece["straight"])
	var start_off := centerline.get_closest_offset(corner_entry)
	var end_off := length
	if i + 1 < pieces.size():
		end_off = centerline.get_closest_offset(pieces[i + 1]["entry_pos"])
	# A degenerate//out-of-order sample can invert the interval; keep it sane.
	if end_off < start_off:
		var t := start_off
		start_off = end_off
		end_off = t
	return Vector2(clampf(start_off, 0.0, length), clampf(end_off, 0.0, length))


# Which road edge is the OUTSIDE of the corner at `offset`: -1 or +1 in the
# `pos + side * Vector2(-tangent.y, tangent.x)` convention.
#
# Derived from the curve itself rather than the piece's `flip` flag, so it cannot
# drift from whatever handedness TrackGenerator.mirror_points happens to use. The
# 2D cross product of the tangents before and after the offset says which way the
# road bends: cross > 0 turns toward +perp, so the centre of the corner (the
# inside) is that way and the outside is the other. A straight stretch (cross ~ 0)
# falls back to +1 rather than returning 0, which would put the run on the
# centerline.
static func _outside_side(centerline: Curve2D, offset: float, length: float) -> int:
	var before: float = clampf(offset - CURVE_EPS_M, 0.0, length)
	var after: float = clampf(offset + CURVE_EPS_M, 0.0, length)
	var t0 := _tangent_at(centerline, before, length)
	var t1 := _tangent_at(centerline, after, length)
	var cross := t0.cross(t1)
	return -1 if cross > 0.0 else 1


# Unit road direction at an arc offset, by forward finite difference (backward near
# the end of the curve). Same helper shape as SignLayout._tangent_at.
static func _tangent_at(centerline: Curve2D, offset: float, length: float) -> Vector2:
	var pos := centerline.sample_baked(offset)
	var tangent: Vector2
	if offset + TANGENT_EPS_M <= length:
		tangent = centerline.sample_baked(offset + TANGENT_EPS_M) - pos
	else:
		tangent = pos - centerline.sample_baked(maxf(0.0, offset - TANGENT_EPS_M))
	if tangent.length() < 1e-5:
		return Vector2(0.0, 1.0)
	return tangent.normalized()
