class_name TrackGenerator
extends RefCounted
# Pure-2D rally track search. Chains CornerLibrary corners with connecting
# straights (corner -> straight -> corner) from a start frame, hard-avoiding
# cell overlaps via DFS backtracking (see generate()). Works in a 2D plane that
# maps directly to world XZ: x -> world x, y -> world z. No scene nodes, no
# terrain. This file holds the geometry helpers and generate(), which drives the
# search.

const CornerLibrary = preload("res://scripts/corner_library.gd")

const CELL_M := 0.5                                  # global cell grid size
const STRAIGHT_OPTIONS_M := [0.0, 5.0, 10.0, 20.0]   # connecting straight lengths
const RASTER_STEP_M := 0.25                          # centerline sampling for cells
# Per-attempt placement+backtrack budget = STEPS_BASE + turn_count * STEPS_PER_TURN.
# A healthy search places each corner first- or second-try, completing in roughly
# `turn_count` steps; a seed that boxes itself in backtracks exponentially and blows
# past this. The budget gives generous headroom over a healthy run yet abandons a
# thrashing one fast, so generate() can restart it with a fresh, far-apart seed (which
# almost always completes quickly) instead of grinding. (One unlucky seed used to need
# ~274 steps for a 14-corner track and took minutes; a fresh seed does it in ~14.)
const STEPS_BASE := 20
const STEPS_PER_TURN := 3
const MAX_RESTARTS := 24                             # random restarts before giving up
# Restarts are spread far apart in seed space (not seed+1, seed+2, …) so each explores
# a genuinely different search rather than a neighbouring one that tends to fail the
# same way. Restart 0 stays at the authored seed, so tracks that already generate fast
# keep their exact layout.
const RESTART_SEED_STRIDE := 1_000_003
# Strength of the straightness bias (see _candidates). At straightness 1.0 the
# straightest candidate carries this much extra sampling weight over a hairpin, so
# the search tries gentle corners + long straights first. Tuned so the bias is
# clearly felt without ever excluding a candidate (the DFS can still backtrack onto
# a sharp corner when nothing gentle fits).
const STRAIGHTNESS_BIAS := 6.0


# Transform2D mapping local corner space (x = right, y = forward/heading) to
# world, anchored at `pos` with the +Y axis along the unit `heading`.
static func frame_transform(pos: Vector2, heading: Vector2) -> Transform2D:
	var fwd := heading.normalized()
	var right := Vector2(fwd.y, -fwd.x)
	return Transform2D(right, fwd, pos)


# Copy a corner's [pos, in_control, out_control] points, negating every x when
# `flip` (turning a right-hand corner into a left-hand one).
static func mirror_points(points: Array, flip: bool) -> Array:
	if not flip:
		return points.duplicate(true)
	var out: Array = []
	for p in points:
		out.append([
			Vector2(-p[0].x, p[0].y),
			Vector2(-p[1].x, p[1].y),
			Vector2(-p[2].x, p[2].y),
		])
	return out


# Every global cell (Vector2i) within half `width` of the polyline.
static func rasterize_cells(polyline: PackedVector2Array, width: float) -> Dictionary:
	var cells: Dictionary = {}
	var half := width / 2.0
	var reach := int(ceil(half / CELL_M)) + 1
	for i in range(1, polyline.size()):
		var a := polyline[i - 1]
		var b := polyline[i]
		var seg_len := a.distance_to(b)
		var steps := int(ceil(seg_len / RASTER_STEP_M)) + 1
		for s in steps + 1:
			var t := float(s) / float(steps) if steps > 0 else 0.0
			var p := a.lerp(b, t)
			var cx := floori(p.x / CELL_M)
			var cz := floori(p.y / CELL_M)
			for dz in range(-reach, reach + 1):
				for dx in range(-reach, reach + 1):
					var cell := Vector2i(cx + dx, cz + dz)
					# Already stamped by a nearby sample? Adjacent samples (every
					# RASTER_STEP_M) re-cover most of the same cells, so this skip avoids
					# ~half/RASTER_STEP redundant distance checks per cell.
					if cells.has(cell):
						continue
					# Cell centre in world space.
					var centre := Vector2((cell.x + 0.5) * CELL_M, (cell.y + 0.5) * CELL_M)
					if centre.distance_to(p) <= half:
						cells[cell] = true
	return cells


# Unit heading of the final segment of a world-space polyline.
static func exit_heading(polyline: PackedVector2Array) -> Vector2:
	var n := polyline.size()
	if n < 2:
		return Vector2(0.0, 1.0)
	return (polyline[n - 1] - polyline[n - 2]).normalized()


# Run the search. Returns:
#   { "centerline": Curve2D, "cells": Dictionary (Vector2i -> true),
#     "pieces": Array (each { "corner": String, "flip": bool,
#                             "straight": float, "cells": Array[Vector2i] }),
#     "complete": bool }
# Deterministic for a given (start_pos, start_heading, seed, turn_count, width).
# `clearance` (m) inflates the collision footprint beyond the visible track so
# non-adjacent sections must keep that much extra gap; it does NOT widen the
# rendered road (cells here feed only the overlap test, not Floor.set_track).
# `reserve_behind_m` (m) pre-occupies a straight corridor directly BEHIND the
# start (at the collision width), so the search can't loop the track back across
# the start-line lead-in stub the run scene prepends there (todo/start-line). It
# is defined RELATIVE to the start frame, so the generated SHAPE is identical for
# any (start_pos, start_heading) — keeping the opponents' derived target times
# (computed at a canonical pose with the same value) in sync with the run track.
# `straightness` (0..1) biases the search toward gentler corners + longer
# connecting straights (see _candidates): 0 = no bias (the original layout), higher
# = an easier, less twisty track. It changes the generated SHAPE, so the same value
# must be passed wherever a track's target time is derived.
static func generate(start_pos: Vector2, start_heading: Vector2, seed_value: int,
		turn_count: int, width: float, clearance: float = 0.0,
		reserve_behind_m: float = 0.0, straightness: float = 0.0) -> Dictionary:
	var coll_width := width + 2.0 * clearance
	var corners := _turn_corners()
	# Cells of the lead-in corridor behind the start (empty when not staged). Cells
	# within the join buffer of the start are still allowed to overlap (the track
	# emerges from there); only loop-backs further out are blocked.
	var reserved: Dictionary = {}
	if reserve_behind_m > 0.0:
		var back := start_pos - start_heading.normalized() * reserve_behind_m
		reserved = rasterize_cells(PackedVector2Array([start_pos, back]), coll_width)
	# Track the deepest partial across restarts so a give-up still renders the best
	# attempt (not just the last one). Each restart is bounded by the per-attempt step
	# budget (see _search / STEPS_PER_TURN), so trying many is cheap.
	var best_partial: Dictionary = {}
	for restart in MAX_RESTARTS:
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_value + restart * RESTART_SEED_STRIDE
		var result := _search(start_pos, start_heading, turn_count, coll_width, corners, rng, reserved, straightness)
		if result["complete"]:
			return result
		if best_partial.is_empty() or result["pieces"].size() > best_partial["pieces"].size():
			best_partial = result
	push_warning("TrackGenerator: only placed %d/%d corners" % [best_partial["pieces"].size(), turn_count])
	return best_partial


# The library corners eligible as "turns" (everything except the plain Straight).
static func _turn_corners() -> Array:
	var out: Array = []
	for spec in CornerLibrary.CORNERS:
		if spec["name"] != "Straight":
			out.append(spec)
	return out


# All candidate pieces for one step, shuffled deterministically. `straightness`
# (0..1) biases the order toward straighter pieces (gentler corners + longer
# connecting straights), so the search TRIES them first and the placed track
# favours easy turns; 0 leaves the order an unbiased shuffle (the original layout).
static func _candidates(corners: Array, rng: RandomNumberGenerator,
		straightness: float = 0.0) -> Array:
	var list: Array = []
	for ci in corners.size():
		for flip in [false, true]:
			for sl in STRAIGHT_OPTIONS_M:
				list.append({ "corner_index": ci, "flip": flip, "straight": sl })
	if straightness <= 0.0:
		# Fisher-Yates with the seeded rng for determinism (unbiased).
		for i in range(list.size() - 1, 0, -1):
			var j := rng.randi_range(0, i)
			var tmp = list[i]; list[i] = list[j]; list[j] = tmp
		return list
	# Straightness-weighted shuffle. Each candidate gets a sampling weight rising
	# with how straight it is; ordering is an Efraimidis-Spirakis weighted draw
	# (key = u^(1/weight), sorted high→low), which stays fully seeded → deterministic.
	# Every candidate is still present, just reordered, so the DFS can backtrack onto
	# a sharp corner when a gentle one won't fit and completeness is unaffected.
	var w := clampf(straightness, 0.0, 1.0)
	var keyed: Array = []
	for cand in list:
		var weight := 1.0 + w * STRAIGHTNESS_BIAS * _candidate_straightness(corners, cand)
		var u := maxf(rng.randf(), 1e-9)  # u in (0, 1]; guard pow against 0
		keyed.append({ "cand": cand, "key": pow(u, 1.0 / weight) })
	keyed.sort_custom(func(a, b): return a["key"] > b["key"])
	var out: Array = []
	for e in keyed:
		out.append(e["cand"])
	return out


# Straightness of one candidate piece in [0, 1]: 1 = dead straight (a gentle corner
# off a long straight), 0 = a hairpin with no connecting straight. Blends the
# corner's gentleness (most of the weight) with the length of its connecting straight.
static func _candidate_straightness(corners: Array, cand: Dictionary) -> float:
	var corner_score := _corner_straightness(corners[cand["corner_index"]])
	var straight_score: float = float(cand["straight"]) / float(STRAIGHT_OPTIONS_M[STRAIGHT_OPTIONS_M.size() - 1])
	return clampf(0.7 * corner_score + 0.3 * straight_score, 0.0, 1.0)


# Gentleness of a library corner in [0, 1]: 1 = no turn, 0 = a 180° hairpin.
# Derived from the corner's total heading change (entry heads +Y), so it needs no
# hand-maintained per-corner table and tracks the authored shapes automatically.
static func _corner_straightness(spec: Dictionary) -> float:
	var poly := CornerLibrary.build_curve(spec).tessellate()
	var angle := absf(Vector2(0.0, 1.0).angle_to(exit_heading(poly)))
	return clampf(1.0 - angle / PI, 0.0, 1.0)


# Build the world points + tessellated polyline a candidate would add, given the
# current frame. Returns { "points": Array of [pos,in,out], "poly": PackedVector2Array,
#           "exit_pos": Vector2, "exit_heading": Vector2, "merge_out": Vector2 }.
# `points` are the NEW control points to append after the current last point;
# `merge_out` is the out-handle to set on the current last point (the join). The
# footprint cells + overlap test are deferred to _collide_and_cells (early-exit).
static func _build_candidate(cand: Dictionary, corners: Array, frame_pos: Vector2,
		frame_heading: Vector2) -> Dictionary:
	# 1. Connecting straight.
	var straight_len: float = cand["straight"]
	var straight_end := frame_pos + frame_heading * straight_len
	# 2. Corner control points transformed into world space at the straight end.
	var spec: Dictionary = corners[cand["corner_index"]]
	var local := mirror_points(spec["points"], cand["flip"])
	var xf := frame_transform(straight_end, frame_heading)
	var world_pts: Array = []
	for p in local:
		world_pts.append([xf * p[0], xf.basis_xform(p[1]), xf.basis_xform(p[2])])
	# The corner's first point sits at straight_end; its out-handle becomes the
	# join's out-handle, and its remaining points are what we append.
	var merge_out: Vector2 = world_pts[0][2]
	var appended: Array = []
	if straight_len > 0.0:
		# Insert the straight end as its own point (linear from the previous
		# point), then the corner points after it.
		appended.append([straight_end, Vector2.ZERO, merge_out])
		for i in range(1, world_pts.size()):
			appended.append(world_pts[i])
		merge_out = Vector2.ZERO  # previous point leaves straight (no handle)
	else:
		for i in range(1, world_pts.size()):
			appended.append(world_pts[i])
	# 3. Tessellate the new portion for cells + exit heading. Build a temp curve
	# from the join point (with merge_out) through the appended points.
	var temp := Curve2D.new()
	temp.add_point(frame_pos, Vector2.ZERO, merge_out)
	for ap in appended:
		temp.add_point(ap[0], ap[1], ap[2])
	var poly := temp.tessellate()
	# NB: the footprint cells are NOT rasterized here — _search does that lazily via
	# _collide_and_cells so a colliding candidate bails on the first overlap instead of
	# paying to rasterize its whole footprint (the dominant cost under backtracking).
	return {
		"points": appended,
		"poly": poly,
		"exit_pos": appended[appended.size() - 1][0],
		"exit_heading": exit_heading(poly),
		"merge_out": merge_out,
	}


# Squared distance from point p to segment a-b.
static func _point_seg_dist_sq(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var denom := ab.length_squared()
	var t := 0.0
	if denom > 0.0:
		t = clampf((p - a).dot(ab) / denom, 0.0, 1.0)
	return p.distance_squared_to(a + ab * t)


# Rasterize a candidate's footprint AND test it against `occupied` in one pass, bailing
# the instant an overlapping cell is found outside the join buffer (cells within
# `width` of the entry `frame_pos`, where touching the existing track is expected).
# Returns { collides: bool, cells: Dictionary }; on a collision `cells` is partial
# (the candidate is rejected, so it's discarded anyway); otherwise `cells` is the full
# footprint, ready to commit.
#
# Each segment scans its bounding box ONCE (point-to-segment distance), rather than
# stamping a reach×reach block at every RASTER_STEP_M sample — the old way re-tested
# the same cells ~half/RASTER_STEP times over, which made each candidate ~70 ms and
# turned a heavy-backtracking seed into a multi-minute hang.
static func _collide_and_cells(polyline: PackedVector2Array, width: float,
		occupied: Dictionary, reserved: Dictionary, frame_pos: Vector2) -> Dictionary:
	var cells: Dictionary = {}
	var half := width / 2.0
	var half_sq := half * half
	var buffer_sq := width * width
	for i in range(1, polyline.size()):
		var a := polyline[i - 1]
		var b := polyline[i]
		var cx0 := floori((minf(a.x, b.x) - half) / CELL_M)
		var cx1 := floori((maxf(a.x, b.x) + half) / CELL_M)
		var cz0 := floori((minf(a.y, b.y) - half) / CELL_M)
		var cz1 := floori((maxf(a.y, b.y) + half) / CELL_M)
		for cz in range(cz0, cz1 + 1):
			for cx in range(cx0, cx1 + 1):
				var cell := Vector2i(cx, cz)
				if cells.has(cell):
					continue
				var centre := Vector2((cx + 0.5) * CELL_M, (cz + 0.5) * CELL_M)
				if _point_seg_dist_sq(centre, a, b) > half_sq:
					continue
				cells[cell] = true
				# Collide against placed track OR the reserved lead-in corridor; cells
				# within the join buffer of the current frame are allowed to touch.
				if (occupied.has(cell) or reserved.has(cell)) \
						and centre.distance_squared_to(frame_pos) > buffer_sq:
					return { "collides": true, "cells": cells }
	return { "collides": false, "cells": cells }


# DFS backtracking. Builds the world polybezier point-by-point.
static func _search(start_pos: Vector2, start_heading: Vector2, turn_count: int,
		width: float, corners: Array, rng: RandomNumberGenerator,
		reserved: Dictionary = {}, straightness: float = 0.0) -> Dictionary:
	# world_points: Array of [pos, in, out]; starts with the spawn point.
	var world_points: Array = [[start_pos, Vector2.ZERO, Vector2.ZERO]]
	var occupied: Dictionary = {}
	var pieces: Array = []
	var frame_pos := start_pos
	var frame_heading := start_heading.normalized()
	var stack: Array = []  # one entry per placed corner (plus the frontier)
	var steps := 0
	# Per-attempt budget scaled by track length. A healthy search completes well within
	# this; one that exceeds it is grinding a doomed subtree, so we bail and let the
	# caller restart with a fresh, far-apart seed (cheap — see generate()).
	var max_steps: int = STEPS_BASE + turn_count * STEPS_PER_TURN

	while pieces.size() < turn_count:
		steps += 1
		if steps > max_steps:
			break
		# Ensure the current depth has a candidate iterator (the frontier).
		if stack.size() == pieces.size():
			stack.append({ "cands": _candidates(corners, rng, straightness), "idx": 0 })
		var top: Dictionary = stack[stack.size() - 1]
		var placed := false
		while top["idx"] < top["cands"].size():
			var cand: Dictionary = top["cands"][top["idx"]]
			top["idx"] += 1
			var built := _build_candidate(cand, corners, frame_pos, frame_heading)
			# Overlap test (early-exits on the first overlapping cell) + footprint cells.
			var hit := _collide_and_cells(built["poly"], width, occupied, reserved, frame_pos)
			if hit["collides"]:
				continue
			# Commit.
			var prev_out: Vector2 = world_points[world_points.size() - 1][2]
			world_points[world_points.size() - 1][2] = built["merge_out"]
			var added_cells: Array = []
			for cell in hit["cells"]:
				if not occupied.has(cell):
					occupied[cell] = true
					added_cells.append(cell)
			for ap in built["points"]:
				world_points.append(ap)
			top["restore"] = {
				"prev_out": prev_out,
				"points_added": built["points"].size(),
				"cells_added": added_cells,
				"frame_pos": frame_pos,
				"frame_heading": frame_heading,
			}
			pieces.append({
				"corner": corners[cand["corner_index"]]["name"],
				"flip": cand["flip"],
				"straight": cand["straight"],
				"cells": added_cells,
				# Entry pose of this piece (the connecting straight's start). The
				# corner itself begins after `straight` metres along `entry_heading`.
				# Additive — used by SignLayout (todo/roadside-signs.md §1); existing
				# consumers ignore it.
				"entry_pos": frame_pos,
				"entry_heading": frame_heading,
			})
			frame_pos = built["exit_pos"]
			frame_heading = built["exit_heading"]
			placed = true
			break
		if placed:
			continue
		# Dead end: discard this depth's exhausted candidate iterator, then undo
		# the last PLACED corner so we can retry its next candidate.
		stack.pop_back()
		if pieces.is_empty():
			break  # nothing placed and no candidate worked -> unsolvable
		# The placed corner's entry is now the top; keep it on the stack so its
		# iterator (already advanced) resumes next loop, and undo its placement.
		var entry: Dictionary = stack[stack.size() - 1]
		var restore: Dictionary = entry["restore"]
		for _i in restore["points_added"]:
			world_points.pop_back()
		world_points[world_points.size() - 1][2] = restore["prev_out"]
		for cell in restore["cells_added"]:
			occupied.erase(cell)
		frame_pos = restore["frame_pos"]
		frame_heading = restore["frame_heading"]
		pieces.pop_back()
		# stack.size() == pieces.size() + 1 now, so the loop does NOT append a new
		# iterator — it resumes `entry` at its next untried candidate.

	var centerline := Curve2D.new()
	for wp in world_points:
		centerline.add_point(wp[0], wp[1], wp[2])
	return {
		"centerline": centerline,
		"cells": occupied,
		"pieces": pieces,
		"complete": pieces.size() == turn_count,
	}
