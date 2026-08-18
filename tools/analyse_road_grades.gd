extends SceneTree
# ROAD GRADE ANALYSIS for the overworld HQ.
#
# Walks every road in the overworld network and reports the STEEPNESS the car actually meets
# along the centreline — the number that decides whether a road is drivable. Written to turn
# "I saw a steep bit in game" into coordinates, and to tell a pad-made grade apart from the
# terrain's own.
#
# RUN IT (no scene, no tests, ~1 min at the shipped size):
#
#   /Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot --headless \
#       --path . -s tools/analyse_road_grades.gd
#
# Switches, appended after the script path as `++name=value` (Godot eats bare `--`):
#   ++step=4.0     sampling step along the centreline, metres (default 4)
#   ++worst=15     how many worst spots to list (default 15)
#   ++nopads       build with NO pad source — the before/after lever for a smoothing change
#   ++noroads      build with NO road source, to see the ground the carve is hiding
#   ++size=1000    override the world edge length (default: GameConfig.overworld_size_m)
#
# ---------------------------------------------------------------------------------------------
# WHICH HEIGHT THIS READS, AND WHY IT MATTERS
#
# There are TWO height pipelines in TerrainManager and they legitimately disagree:
#
#   grid   compute_chunk_data:  road carve -> pad flatten -> coast taper -> region -> quantum
#   scalar _noise_height_at:                  pad flatten -> coast taper
#
# The ROAD CARVE EXISTS ONLY IN THE GRID PASS. The mesh, the HeightMapShape3D and therefore the
# car all come from the grid; `height_at` serves the grid for any built chunk and silently falls
# back to the scalar path for anything else. So sampling `height_at` on a manager with no chunks
# built measures the RAW GROUND ALONG THE ROAD'S PATH — not the road. An earlier version of this
# tool did exactly that and overstated every grade.
#
# This tool therefore builds the real chunk grid (`compute_chunk_data`, cached per coord) with
# the SAME sources `Overworld._ready` attaches, and reads the nearest grid vertex. That is the
# surface the car drives on.
#
# ---------------------------------------------------------------------------------------------
# TYPING NOTE. Everything below is deliberately UNTYPED and loaded with `load()` at runtime.
# `-s` compiles this script before the SceneTree exists, so a static reference to TerrainManager
# / GameConfig / Overworld would drag in scripts that touch the `Config` and `PerfLog` autoloads
# at class scope — which do not exist yet — and the whole compile fails. The same reason
# tools/render_ground_feather.gd keeps its config untyped.

const GRADE_CLIMB_LIMIT := 0.22   # ~ what a FWD car climbs at snow grip (rally_library.gd)
const GRADE_DROP_LIMIT := 0.30    # a drop steeper than this launches the car

var _tm = null
var _chunks: Dictionary = {}      # Vector2i -> PackedFloat32Array of grid heights
var _chunk_m := 50.0
var _cell_m := 1.0
var _samples_per_edge := 51


func _initialize() -> void:
	# One frame so the autoloads have registered before anything is loaded.
	await process_frame
	_run()
	# ALWAYS quit, even if _run bailed out on a script error above: an un-quit SceneTree idles
	# forever and the run has to be killed by hand, which is how this tool ate two 7-minute
	# timeouts before anyone saw its first line of output.
	quit()


func _run() -> void:
	var args := _switches()
	var step: float = maxf(float(args.get("step", "4.0")), 0.25)
	var worst_n: int = maxi(int(args.get("worst", "15")), 1)
	var use_pads: bool = not args.has("nopads")
	var use_roads: bool = not args.has("noroads")

	var cfg = load("res://config/game_config.tres")
	var size_m: float = float(args["size"]) if args.has("size") else cfg.overworld_size_m

	print("=== overworld road grade analysis ===")
	print("size=%.0f m  step=%.2f m  pads=%s  roads=%s"
		% [size_m, step, "ON" if use_pads else "OFF", "ON" if use_roads else "OFF"])

	_tm = _terrain(cfg, size_m)
	_chunk_m = _tm.CHUNK_M
	_cell_m = _tm.CELL_M
	_samples_per_edge = _tm.SAMPLES

	var roads = load("res://scripts/overworld_roads.gd").from_config(cfg)
	roads.build(size_m)
	# The carve is the whole reason this tool builds the grid — see the header.
	if use_roads:
		_tm.set_road_source(roads)
	var pads = null
	if use_pads:
		pads = load("res://scripts/overworld_pads.gd").from_config(cfg)
		# BUILD THEN ATTACH, exactly as Overworld._ready does: `build` samples the pure generator,
		# which applies the pads, so attaching first would feed them their own output.
		pads.build(size_m, _to_world_callable(size_m), Callable(_tm, "_noise_height_at"))
		_tm.set_pad_source(pads)
	print("roads: %d edges, %d nodes | pads: %d"
		% [roads.edges().size(), roads.nodes().size(), pads.pad_count() if pads != null else 0])
	if pads != null:
		_report_feathers(pads)

	var samples := _walk(roads, pads, step)
	print("chunks built: %d | cliff offsets baked: %d"
		% [_chunks.size(), _tm.cliff_offsets.size()])
	_report(samples, worst_n, step)
	if args.has("probe"):
		_probe(String(args["probe"]), pads, float(args.get("probe_len", "24.0")))


# `++probe=x,z` — dump the height PIPELINE along a short east-west transect through a spot, so a
# steep sample can be attributed to a specific term rather than guessed at. Prints, per metre:
# the grid height the car drives on, the scalar generator's height (pad + taper, NO road carve),
# and the pad weight/target there. Where the first two disagree, the carve is the difference.
func _probe(spec: String, pads, length_m: float) -> void:
	var parts := spec.split(",")
	if parts.size() != 2:
		print("++probe wants x,z")
		return
	var cx := float(parts[0])
	var cz := float(parts[1])
	print("\n--- probe around (%.0f, %.0f) ---" % [cx, cz])
	print("   x       grid_h   scalar_h    pad_w   pad_target")
	var prev := NAN
	for i in range(int(-length_m * 0.5), int(length_m * 0.5) + 1):
		var x := cx + float(i)
		var gh := _grid_height(x, cz)
		var sh: float = _tm._noise_height_at(x, cz)
		var hit: Vector2 = pads.pad_at(x, cz) if pads != null else Vector2.ZERO
		var mark := ""
		if not is_nan(prev) and absf(gh - prev) > 0.22:
			mark = "   <== step %+.3f" % (gh - prev)
		prev = gh
		print("  %+6.0f   %8.3f   %8.3f   %6.3f   %8.3f%s"
			% [x, gh, sh, hit.x, hit.y, mark])


# `++k=v` / `++k` switches. Godot consumes bare `--flags` itself, hence the `++`.
func _switches() -> Dictionary:
	var out: Dictionary = {}
	for raw in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		var a := String(raw)
		if not a.begins_with("++"):
			continue
		a = a.substr(2)
		var eq := a.find("=")
		if eq < 0:
			out[a] = "1"
		else:
			out[a.substr(0, eq)] = a.substr(eq + 1)
	return out


# The overworld's terrain, configured as Overworld._ready configures it — seed, layers, light,
# LOD, cliffs, the bounded world (which switches the coastline taper on) and the height quantum.
# Anything skipped here would measure a different world than the player drives.
func _terrain(cfg, size_m: float):
	var tm = load("res://scripts/terrain_manager.gd").new()
	tm.focus_path = NodePath("")
	tm.defer_initial_build = true
	# The OVERWORLD's noise, matching overworld.gd — NOT the stages' track_seed /
	# terrain_layers. This tool exists to measure the ground the player drives in the hub, and
	# it has already been wrong once by sampling a surface the hub never generates.
	tm.noise_seed = cfg.overworld_terrain_seed
	# TYPED on purpose: TerrainManager.layers is `Array[TerrainLayer]` and rejects a bare Array.
	# Naming the type here is safe (unlike TerrainManager itself) because terrain_layer.gd is a
	# leaf Resource that touches no autoload — see the TYPING NOTE in the header.
	var layers: Array[TerrainLayer] = []
	for params in cfg.overworld_terrain_layers():
		var layer := TerrainLayer.new()
		layer.wavelength_m = params.x
		layer.amplitude_m = params.y
		layers.append(layer)
	tm.layers = layers
	cfg.apply_terrain_light(tm)
	cfg.apply_terrain_lod(tm)
	cfg.apply_cliffs(tm)
	var half := size_m * 0.5
	tm.apply_overworld_bounds(cfg, Rect2(-half, -half, size_m, size_m))
	tm.height_quantum = 1.0 / load("res://scripts/overworld_cache.gd").HEIGHT_SCALE
	return tm


# The pads' coordinate mapping — Overworld's own `world_xz`, called through the loaded script so
# this tool never re-derives the map_pos -> world conversion.
func _to_world_callable(size_m: float) -> Callable:
	var overworld = load("res://scripts/overworld.gd")
	return func(map_pos: Vector2) -> Vector3: return overworld.world_xz(map_pos, size_m)


func _report_feathers(pads) -> void:
	var widest := 0.0
	var narrowest := INF
	var total := 0.0
	for i in pads.pad_count():
		var f: float = pads.pad_feather(i)
		widest = maxf(widest, f)
		narrowest = minf(narrowest, f)
		total += f
	print("pad feathers: min %.1f m, mean %.1f m, max %.1f m (authored min %.1f m, cap %.1f m)"
		% [narrowest, total / maxf(pads.pad_count(), 1.0), widest, pads.feather_m(),
			pads.max_feather_m()])


# THE GROUND THE CAR DRIVES ON: the built grid, cached per chunk. Nearest grid vertex rather than
# a bilinear read — the mesh is flat-shaded triangles at 1 m cells, so the vertex IS the surface
# to within half a cell, and interpolating would smooth over the very steps being hunted.
func _grid_height(x: float, z: float) -> float:
	var coord := Vector2i(int(floor(x / _chunk_m)), int(floor(z / _chunk_m)))
	if not _chunks.has(coord):
		var data: Dictionary = _tm.compute_chunk_data(coord)
		_chunks[coord] = data.get("heights", PackedFloat32Array())
	var heights: PackedFloat32Array = _chunks[coord]
	if heights.is_empty():
		return 0.0
	# Chunk centre, then chunk-local, then the grid index — the same conversion the carve and
	# the pad pass use to put a local vertex back into world space, run backwards.
	var cx := (coord.x + 0.5) * _chunk_m
	var cz := (coord.y + 0.5) * _chunk_m
	var half := _chunk_m * 0.5
	var xi := int(round((x - cx + half) / _cell_m))
	var zi := int(round((z - cz + half) / _cell_m))
	xi = clampi(xi, 0, _samples_per_edge - 1)
	zi = clampi(zi, 0, _samples_per_edge - 1)
	return heights[zi * _samples_per_edge + xi]


# One entry per step along every road: the signed grade, where it is, and how far beyond the
# nearest pad's outer edge the spot lies (negative = inside that pad's influence).
func _walk(roads, pads, step: float) -> Array:
	var out: Array = []
	var edges: Array = roads.edges()
	for ei in edges.size():
		var pts: PackedVector2Array = roads.polyline(ei)
		if pts.size() < 2:
			continue
		# Re-sample at a FIXED arc-length step so grades are comparable between roads regardless
		# of how the network happened to space its control points.
		var carry := 0.0
		var prev_p: Vector2 = pts[0]
		var prev_h := _grid_height(prev_p.x, prev_p.y)
		var travelled := 0.0
		for si in range(pts.size() - 1):
			var a: Vector2 = pts[si]
			var b: Vector2 = pts[si + 1]
			var seg_len := a.distance_to(b)
			if seg_len <= 0.0001:
				continue
			var t := carry
			while t < seg_len:
				var p: Vector2 = a.lerp(b, t / seg_len)
				var d := prev_p.distance_to(p)
				if d > 0.0001:
					var h := _grid_height(p.x, p.y)
					travelled += d
					out.append({
						"edge": ei,
						"pos": p,
						"grade": (h - prev_h) / d,
						"pad_gap": _pad_gap(pads, p),
						"along_m": travelled,
					})
					prev_p = p
					prev_h = h
				t += step
			carry = t - seg_len
	return out


# Distance from `p` to the nearest pad's OUTER edge (radius + that pad's own feather).
# Negative inside the band, 0 at the lip, positive out in open terrain. INF with no pads.
func _pad_gap(pads, p: Vector2) -> float:
	if pads == null:
		return INF
	var best := INF
	for i in pads.pad_count():
		var reach: float = pads.pad_radius(i) + pads.pad_feather(i)
		best = minf(best, p.distance_to(pads.pad_centre(i)) - reach)
	return best


func _report(samples: Array, worst_n: int, step: float) -> void:
	if samples.is_empty():
		print("no samples — is the network empty?")
		return
	var climbs: Array = []
	var drops: Array = []
	var over_climb := 0
	var over_drop := 0
	var sum_abs := 0.0
	for s in samples:
		var g: float = s["grade"]
		sum_abs += absf(g)
		if g >= 0.0:
			climbs.append(s)
			if g > GRADE_CLIMB_LIMIT:
				over_climb += 1
		else:
			drops.append(s)
			if -g > GRADE_DROP_LIMIT:
				over_drop += 1
	climbs.sort_custom(func(x, y): return x["grade"] > y["grade"])
	drops.sort_custom(func(x, y): return x["grade"] < y["grade"])

	print("\n%d samples at %.2f m | mean |grade| %.3f"
		% [samples.size(), step, sum_abs / samples.size()])
	print("over the climb limit (%.2f): %d (%.2f%%) | over the drop limit (%.2f): %d (%.2f%%)"
		% [GRADE_CLIMB_LIMIT, over_climb, 100.0 * over_climb / samples.size(),
			GRADE_DROP_LIMIT, over_drop, 100.0 * over_drop / samples.size()])
	_print_worst("WORST CLIMBS", climbs, worst_n)
	_print_worst("WORST DROPS", drops, worst_n)
	_print_attribution(samples)


func _print_worst(title: String, sorted_samples: Array, n: int) -> void:
	print("\n--- %s ---" % title)
	for i in mini(n, sorted_samples.size()):
		var s = sorted_samples[i]
		var p: Vector2 = s["pos"]
		var gap: float = s["pad_gap"]
		var where := "open terrain (%.0f m clear of any pad)" % gap
		if gap <= 0.0:
			where = "INSIDE a pad band (%.0f m in from its lip)" % -gap
		print("  grade %+.3f  edge %-3d  at (%.0f, %.0f)  %s"
			% [s["grade"], s["edge"], p.x, p.y, where])


# Is the steepness the PADS' fault or the terrain's? This is the line that says whether changing
# the smoothing can help at all.
func _print_attribution(samples: Array) -> void:
	var in_n := 0
	var in_worst := 0.0
	var in_sum := 0.0
	var out_n := 0
	var out_worst := 0.0
	var out_sum := 0.0
	for s in samples:
		var g: float = absf(s["grade"])
		if float(s["pad_gap"]) <= 0.0:
			in_n += 1
			in_sum += g
			in_worst = maxf(in_worst, g)
		else:
			out_n += 1
			out_sum += g
			out_worst = maxf(out_worst, g)
	print("\n--- attribution ---")
	print("  inside a pad band : %5d samples | mean |grade| %.3f | worst %.3f"
		% [in_n, in_sum / maxf(in_n, 1), in_worst])
	print("  open terrain      : %5d samples | mean |grade| %.3f | worst %.3f"
		% [out_n, out_sum / maxf(out_n, 1), out_worst])
