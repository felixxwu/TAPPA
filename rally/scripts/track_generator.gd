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
const MAX_STEPS := 4000                              # placement+backtrack cap per attempt
const MAX_RESTARTS := 8                              # random restarts before giving up


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
static func generate(start_pos: Vector2, start_heading: Vector2, seed_value: int,
		turn_count: int, width: float, clearance: float = 0.0) -> Dictionary:
	var coll_width := width + 2.0 * clearance
	var corners := _turn_corners()
	for restart in MAX_RESTARTS:
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_value + restart
		var result := _search(start_pos, start_heading, turn_count, coll_width, corners, rng)
		if result["complete"]:
			return result
	# Last attempt's partial result (never hangs); caller can still render it.
	var rng_final := RandomNumberGenerator.new()
	rng_final.seed = seed_value + MAX_RESTARTS
	var partial := _search(start_pos, start_heading, turn_count, coll_width, corners, rng_final)
	push_warning("TrackGenerator: only placed %d/%d corners" % [partial["pieces"].size(), turn_count])
	return partial


# The library corners eligible as "turns" (everything except the plain Straight).
static func _turn_corners() -> Array:
	var out: Array = []
	for spec in CornerLibrary.CORNERS:
		if spec["name"] != "Straight":
			out.append(spec)
	return out


# All candidate pieces for one step, shuffled deterministically.
static func _candidates(corners: Array, rng: RandomNumberGenerator) -> Array:
	var list: Array = []
	for ci in corners.size():
		for flip in [false, true]:
			for sl in STRAIGHT_OPTIONS_M:
				list.append({ "corner_index": ci, "flip": flip, "straight": sl })
	# Fisher-Yates with the seeded rng for determinism.
	for i in range(list.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = list[i]; list[i] = list[j]; list[j] = tmp
	return list


# Build the world points + cells a candidate would add, given the current frame.
# Returns { "points": Array of [pos,in,out], "cells": Dictionary,
#           "exit_pos": Vector2, "exit_heading": Vector2, "merge_out": Vector2 }.
# `points` are the NEW control points to append after the current last point;
# `merge_out` is the out-handle to set on the current last point (the join).
static func _build_candidate(cand: Dictionary, corners: Array, frame_pos: Vector2,
		frame_heading: Vector2, width: float) -> Dictionary:
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
	var cells := rasterize_cells(poly, width)
	return {
		"points": appended,
		"cells": cells,
		"exit_pos": appended[appended.size() - 1][0],
		"exit_heading": exit_heading(poly),
		"merge_out": merge_out,
	}


# DFS backtracking. Builds the world polybezier point-by-point.
static func _search(start_pos: Vector2, start_heading: Vector2, turn_count: int,
		width: float, corners: Array, rng: RandomNumberGenerator) -> Dictionary:
	# world_points: Array of [pos, in, out]; starts with the spawn point.
	var world_points: Array = [[start_pos, Vector2.ZERO, Vector2.ZERO]]
	var occupied: Dictionary = {}
	var pieces: Array = []
	var frame_pos := start_pos
	var frame_heading := start_heading.normalized()
	var stack: Array = []  # one entry per placed corner (plus the frontier)
	var steps := 0

	while pieces.size() < turn_count:
		steps += 1
		if steps > MAX_STEPS:
			break
		# Ensure the current depth has a candidate iterator (the frontier).
		if stack.size() == pieces.size():
			stack.append({ "cands": _candidates(corners, rng), "idx": 0 })
		var top: Dictionary = stack[stack.size() - 1]
		var placed := false
		while top["idx"] < top["cands"].size():
			var cand: Dictionary = top["cands"][top["idx"]]
			top["idx"] += 1
			var built := _build_candidate(cand, corners, frame_pos, frame_heading, width)
			# Overlap test, ignoring cells within a join buffer of the entry.
			var collides := false
			for cell in built["cells"]:
				if not occupied.has(cell):
					continue
				var centre := Vector2((cell.x + 0.5) * CELL_M, (cell.y + 0.5) * CELL_M)
				if centre.distance_to(frame_pos) > width:
					collides = true
					break
			if collides:
				continue
			# Commit.
			var prev_out: Vector2 = world_points[world_points.size() - 1][2]
			world_points[world_points.size() - 1][2] = built["merge_out"]
			var added_cells: Array = []
			for cell in built["cells"]:
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
