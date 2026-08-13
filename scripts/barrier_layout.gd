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

# Where the nearer hill-or-drop probe sits, as a fraction of `slope_probe_m`. It exists
# to catch a bank that starts climbing close to the road; the drop itself is judged at
# the full distance (see _land_falls_away).
const NEAR_PROBE_FRAC := 0.55


# Plan every barrier module for a stage. `params` is GameConfig.barrier_render_params().
#
# `tarmac_at` is an optional `func(pos: Vector2) -> float` returning the 0..1
# tarmac-ness of the road at a centerline point (TerrainManager.surface_at().y);
# when it is not supplied every module falls back to the gravel style.
#
# `ground_at` is an optional `func(pos: Vector2) -> float` returning the terrain
# height at a world XZ (TerrainManager.height_at). It decides whether a stretch is
# barriered at all: a barrier belongs where the land FALLS AWAY, so a module is
# dropped unless the ground outboard of it sits `drop_min_m` below the road. With no
# sampler (a flat test/harness world) the check is skipped and every module is kept.
static func plan(centerline: Curve2D, pieces: Array, params: Dictionary,
		tarmac_at := Callable(), ground_at := Callable()) -> Array:
	var out: Array = []
	if centerline == null:
		return out
	var length := centerline.get_baked_length()
	var pitch: float = maxf(float(params.get("section_length_m", 2.0)), 0.1)
	if length <= 0.0 or length < pitch:
		return out
	var lead: float = float(params.get("lead_m", 0.0))
	var threshold: float = float(params.get("tarmac_threshold", 0.5))
	var half_w: float = float(params.get("track_width", 7.0)) * 0.5
	var probe: float = float(params.get("slope_probe_m", 5.0))
	var drop_min: float = float(params.get("drop_min_m", 0.0))
	var hill_tol: float = float(params.get("hill_tolerance_m", 0.0))
	var min_run: int = maxi(int(params.get("min_run_modules", 1)), 1)
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
		# length rather than the centerline's — in 3D, so a climb counts too.
		var walk := _barrier_walk(centerline, length, start_off, end_off, side, lateral,
			ground_at)
		var total: float = float(walk[walk.size() - 1]["s"])
		var count := int(floor(total / pitch))
		if count <= 0:
			continue
		# Centre the whole-module run in the available arc, so the barrier is
		# symmetric about the corner rather than biased to its entry.
		var run_start: float = (total - count * pitch) * 0.5
		# Candidates first, then the terrain filter, then the surviving stretches are
		# emitted as runs — so a corner that is banked for half its length yields a
		# barrier over the falling half only.
		var candidates: Array = []
		for k in range(count):
			var offset := _offset_at_distance(walk, run_start + (k + 0.5) * pitch)
			var pos := centerline.sample_baked(offset)
			var tangent := _tangent_at(centerline, offset, length)
			var tarmac := 0.0
			if tarmac_at.is_valid():
				tarmac = float(tarmac_at.call(pos))
			candidates.append({
				"pos": pos,
				"tangent": tangent,
				"side": side,
				"style": BarrierSection.style_for_tarmac(tarmac, threshold),
				"keep": _land_falls_away(pos, tangent, side, ground_at, half_w, probe,
					drop_min, hill_tol),
			})
		run = _emit_stretches(out, candidates, run, min_run)
		prev_end = _offset_at_distance(walk, run_start + count * pitch)
	return out


# Copy each stretch of consecutive KEPT candidates into `out`, numbering it as its own
# run, and drop any stretch shorter than `min_run` modules. Returns the next free run
# index. Short stretches go because a lone module (or a pair) reads as debris dropped on
# the verge rather than as a barrier — better no barrier than two metres of one.
static func _emit_stretches(out: Array, candidates: Array, run: int, min_run: int) -> int:
	var stretch: Array = []
	for entry in candidates:
		if bool(entry["keep"]):
			stretch.append(entry)
			continue
		run = _flush_stretch(out, stretch, run, min_run)
		stretch = []
	return _flush_stretch(out, stretch, run, min_run)


static func _flush_stretch(out: Array, stretch: Array, run: int, min_run: int) -> int:
	if stretch.size() < min_run:
		return run
	for entry in stretch:
		out.append({
			"pos": entry["pos"],
			"tangent": entry["tangent"],
			"side": entry["side"],
			"style": entry["style"],
			"run": run,
		})
	return run + 1


# Does the land fall away on the barrier's side here? A barrier earns its place where
# running wide means dropping off the road; where the corner is CUT INTO A BANK the
# hillside already stops the car, and a guardrail buried in the slope looks wrong.
#
# Two separate conditions against the road surface at `pos`, both read outboard of the
# barrier — they are NOT the same test, which is why there are two samples:
#
#   1. NO HILL. Neither sample may sit more than `hill_tol` above the road. Any real rise
#      on that side means the corner is cut into a slope, so no barrier — near sample
#      included, since a bank usually starts climbing right at the road edge. The
#      tolerance is there because terrain noise lifts a verge a few cm above road level
#      even where the land genuinely falls away further out.
#   2. A COMMITTED DROP. The FAR sample must sit at least `drop_min` below the road.
#      Judged on the far sample alone, because the drop RAMPS IN: the carve pass's
#      cliff band only reaches full depth about 2 m past the flatten band, so the near
#      sample is still partway down the slope and would veto perfectly good cliffs.
#      This is also the flat-ground cutoff — level verge has no drop, so no barrier.
#
# The probes must reach BEYOND the road's flatten band (`track_transition_cells`, 3 m
# outside the road edge by default): inside it the carve pass has blended the ground to
# road height, so every corner would read as flat. `slope_probe_m` is measured out from
# the road EDGE for exactly that reason.
static func _land_falls_away(pos: Vector2, tangent: Vector2, side: int,
		ground_at: Callable, half_w: float, probe: float, drop_min: float,
		hill_tol := 0.0) -> bool:
	if not ground_at.is_valid():
		return true   # no terrain to read (flat harness/test world): keep everything
	var road_h := float(ground_at.call(pos))
	var outward := Vector2(-tangent.y, tangent.x) * float(side)
	var near_h := float(ground_at.call(pos + outward * (half_w + probe * NEAR_PROBE_FRAC)))
	var far_h := float(ground_at.call(pos + outward * (half_w + probe)))
	if maxf(near_h, far_h) > road_h + hill_tol:
		return false                          # 1. a bank on that side
	return road_h - far_h >= drop_min         # 2. a real drop to guard


# Sample the BARRIER LINE — the centerline pushed `lateral` metres toward `side` —
# from `start_off` to `end_off`, returning `[{off, s}]`: the centerline arc offset of
# each sample and the cumulative distance along the barrier line to it. This is the
# lookup that lets modules be spaced along the line they actually stand on.
#
# The distance is measured in 3D when a `ground_at` sampler is available, because a
# module is a rigid `pitch`-long bar: laid on a climb it covers only `pitch * cos(slope)`
# of GROUND, so spacing centres by horizontal distance leaves a gap at every joint that
# grows with the gradient (2 cm at 15%, past the joint overlap by 25%). Spacing them by
# distance along the sloping ground instead makes the run continuous on any gradient.
static func _barrier_walk(centerline: Curve2D, length: float, start_off: float,
		end_off: float, side: int, lateral: float, ground_at := Callable()) -> Array:
	var out: Array = []
	var steps: int = maxi(1, int(ceil((end_off - start_off) / WALK_STEP_M)))
	var prev := Vector3.ZERO
	var s := 0.0
	for i in range(steps + 1):
		var off: float = lerpf(start_off, end_off, float(i) / float(steps))
		var pos := centerline.sample_baked(off)
		var tangent := _tangent_at(centerline, off, length)
		var flat: Vector2 = pos + float(side) * Vector2(-tangent.y, tangent.x) * lateral
		var height := 0.0
		if ground_at.is_valid():
			height = float(ground_at.call(flat))
		var point := Vector3(flat.x, height, flat.y)
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
