class_name RoadBarriers
extends RefCounted
# Docs: features/free-roam.md — update in the same change as this file.
# Tests: tests/headless/test_free_roam.gd — extend in the same change.
# Crash barriers for the free-roam network, planned once at boot from the whole graph and built
# chunk by chunk (TerrainStreamer). The same rules as the stage's corner barriers
# (features/barriers.md): only on the OUTSIDE of sharp bends, and only where the land falls away
# (BarrierLayout._land_falls_away). The modules and their collision are the stage's BarrierField.
#
# A free-roam road is a polyline whose corners are rounded into runs of gentle vertices, so a sharp
# bend is such a run that turns by more than `barrier_turn_min_deg` in total. Its barrier runs along
# the outside of the chord before the bend, round each vertex and between them, and along the chord
# after it, each side reaching `barrier_lead_m + BEND_REACH_M` from the bend. Junctions, and the pads of rest stops, loot
# slots and dead ends, stay open.

const BEND_REACH_M := 14.0
const JUNCTION_CLEAR_M := 20.0
const PAD_CLEAR_M := 4.0
const FALLS_SAMPLE_EVERY := 3

# Every module, as the BarrierField layout entries ({pos, tangent, side, style, run}).
var modules: Array = []
var _by_chunk := {}  # Vector2i -> Array of module entries
var _chunk_m := 64.0


func plan(s: FreeRoamSettings, net: RoadNetwork, terrain: RoadTerrain, sites: RoadSites, params: Dictionary) -> void:
	modules.clear()
	_by_chunk.clear()
	_chunk_m = s.chunk_m
	var pitch: float = maxf(float(params.get("section_length_m", 2.0)), 0.1)
	var half_w: float = float(params.get("track_width", 7.0)) * 0.5
	var reach: float = float(params.get("lead_m", 5.0)) + BEND_REACH_M
	var probe: float = float(params.get("slope_probe_m", 5.0))
	var drop_min: float = float(params.get("drop_min_m", 1.0))
	var hill_tol: float = float(params.get("hill_tolerance_m", 0.15))
	var min_run: int = int(params.get("min_run_modules", 3))
	var road_gap: float = float(params.get("road_gap_m", 0.4))
	var turn_min := deg_to_rad(s.barrier_turn_min_deg)
	var run := 0
	for ei in net.edges.size():
		var pts := net.polyline(ei)
		var cum := PackedFloat64Array([0.0])
		for i in pts.size() - 1:
			cum.append(cum[i] + pts[i].distance_to(pts[i + 1]))
		var length := cum[cum.size() - 1]
		for bend: Vector2i in _bends(pts, cum, reach, turn_min):
			var v0 := bend.x
			var v1 := bend.y
			# Outside of the bend: the road turns toward +perp when the turn is positive.
			var side := -1 if _turn(pts, v0) > 0.0 else 1
			var stretch: Array = []
			# Before the bend, along the incoming chord.
			var a := maxf(cum[v0] - reach, JUNCTION_CLEAR_M)
			while a < cum[v0] - pitch * 0.25:
				stretch.append(_entry(pts, cum, a, side))
				a += pitch
			var arc_r := half_w + road_gap
			for v in range(v0, v1 + 1):
				# Round the arc the road edge makes about each vertex, then follow the chord to the next.
				var t0 := (pts[v] - pts[v - 1]).normalized()
				var turn := _turn(pts, v)
				var steps := ceili(absf(turn) * arc_r / pitch)
				for k in steps:
					var tangent := t0.rotated(turn * (k + 0.5) / steps)
					stretch.append({"pos": pts[v], "tangent": tangent, "side": side, "style": BarrierSection.Style.ARMCO})
				var b := cum[v] + pitch * 0.5
				var end := minf(cum[v] + reach, length - JUNCTION_CLEAR_M) if v == v1 else cum[v + 1] - pitch * 0.25
				while b <= end:
					stretch.append(_entry(pts, cum, b, side))
					b += pitch
			# Keep only modules over falling land and clear of every pad, in runs of min_run or more.
			# The bend's road candidates are gathered once, so each height sample scans a short list.
			var span := cum[v1] - cum[v0]
			var cands := net.candidates_for(pts[v0].x, pts[v0].y, reach + span + half_w + probe + 2.0, s.mountain_dist_m)
			var ground := func(p: Vector2) -> float: return terrain.height(p.x, p.y, cands, true)
			var kept: Array = []
			# Whether the land falls away is judged once per FALLS_SAMPLE_EVERY modules (at the middle
			# one) and shared by the group: height samples are the expensive part of planning.
			var falls := PackedByteArray()
			falls.resize(stretch.size())
			for g in range(0, stretch.size(), FALLS_SAMPLE_EVERY):
				var mid: Dictionary = stretch[mini(g + floori(FALLS_SAMPLE_EVERY / 2.0), stretch.size() - 1)]
				var f := BarrierLayout._land_falls_away(mid["pos"], mid["tangent"], side, ground, half_w, probe, drop_min, hill_tol)
				for k in range(g, mini(g + FALLS_SAMPLE_EVERY, stretch.size())):
					falls[k] = 1 if f else 0
			for mi in stretch.size():
				var m: Dictionary = stretch[mi]
				var p: Vector2 = m["pos"]
				var tg: Vector2 = m["tangent"]
				var perp := Vector2(-tg.y, tg.x) * float(side)
				var edge := p + perp * (half_w + road_gap)
				var ok := falls[mi] == 1 and sites.is_clear(edge, PAD_CLEAR_M)
				if ok:
					kept.append(m)
				elif not kept.is_empty():
					run = _flush(kept, run, min_run)
					kept = []
			if not kept.is_empty():
				run = _flush(kept, run, min_run)


# The sharp bends of one road, as [first, last] vertex. Rounding splits a sharp corner into several
# gentle vertices a few metres apart, so a bend is a run of vertices turning the same way within
# `window` metres whose turns add up to turn_min; the ends of the road stay open for junctions.
static func _bends(pts: PackedVector2Array, cum: PackedFloat64Array, window: float, turn_min: float) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var last := cum[cum.size() - 1] - JUNCTION_CLEAR_M
	var v := 1
	while v < pts.size() - 1:
		var sign := signf(_turn(pts, v))
		var total := _turn(pts, v)
		var w := v
		while w + 1 < pts.size() - 1 and cum[w + 1] - cum[v] <= window and signf(_turn(pts, w + 1)) == sign:
			w += 1
			total += _turn(pts, w)
		if absf(total) >= turn_min and cum[v] >= JUNCTION_CLEAR_M and cum[w] <= last:
			out.append(Vector2i(v, w))
			v = w + 1
		else:
			v += 1
	return out


static func _turn(pts: PackedVector2Array, v: int) -> float:
	return (pts[v] - pts[v - 1]).angle_to(pts[v + 1] - pts[v])


func _entry(pts: PackedVector2Array, cum: PackedFloat64Array, arc: float, side: int) -> Dictionary:
	var i := clampi(cum.bsearch(arc) - 1, 0, pts.size() - 2)
	var seg := cum[i + 1] - cum[i]
	var p := pts[i].lerp(pts[i + 1], clampf((arc - cum[i]) / maxf(seg, 1e-6), 0.0, 1.0))
	return {"pos": p, "tangent": (pts[i + 1] - pts[i]).normalized(), "side": side, "style": BarrierSection.Style.ARMCO}


func _flush(kept: Array, run: int, min_run: int) -> int:
	if kept.size() < min_run:
		return run
	for m: Dictionary in kept:
		m["run"] = run
		modules.append(m)
		var p: Vector2 = m["pos"]
		var key := Vector2i(floori(p.x / _chunk_m), floori(p.y / _chunk_m))
		if not _by_chunk.has(key):
			_by_chunk[key] = []
		_by_chunk[key].append(m)
	return run + 1


# The modules a chunk builds: those whose road point lies in it.
func in_chunk(coord: Vector2i) -> Array:
	return _by_chunk.get(coord, [])
