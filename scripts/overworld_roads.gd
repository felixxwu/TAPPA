class_name OverworldRoads
extends RefCounted
# The overworld's ROAD NETWORK: the deterministic set of roads that link every rally pin
# (and the garage at RallyLibrary.HQ_MAP_POS) across the drivable 4 km map, plus the
# per-point queries the terrain carve needs. Geometry and queries ONLY — nothing here
# touches the scene tree, the terrain, or a material. A second pass (the carve) consumes
# `road_at` / `height_bias_at` / `segments_in_rect` per chunk and writes the terrain fields.
#
# WHY A SEPARATE GRAPH FROM `reveal_link_pairs`
#
# The edges use the SAME pairing rule as RallyLibrary.reveal_link_pairs — two pins are
# linked when `dist(a, b) <= max(reveal_radius_of(a), reveal_radius_of(b))`, which is the
# progression graph the HQ map table already draws as dashed lines — but WITHOUT its
# lit/revealed filter. A road is authored geography: the tarmac does not appear under the
# player's wheels because they happened to finish a rally somewhere else. The reveal graph
# grows; the road network is fixed for a given pin field.
#
# DETERMINISM
#
# Pure and order-independent. No RNG object and no reliance on roster order: every random
# choice (an edge's curve offsets, whether an edge is tarmac) is a seeded ScatterMath.hash01
# of the edge's own QUANTISED endpoint positions, so the same pin field always yields the
# same network no matter what order `RallyLibrary.all()` returns it in. Edge processing
# order is a canonical sort, not the discovery order.
#
# CONVENTIONS MATCHED (do not drift from these — the shader reads them)
#
# `road_at` returns the same two numbers `TerrainManager.surface_at` does, in the same
# units and with the same feathering:
#   road_weight   1 on the road, smooth-ramping to 0 across the shoulder — `COLOR.a` in
#                 ps1_models.gdshader, i.e. TerrainManager.track_weights.
#   tarmac_weight 0 = gravel, 1 = tarmac — `UV2.x`, i.e. TerrainManager.track_surface.
# The ramp is literally TerrainManager.smooth_ramp(d, half_width, half_width + shoulder),
# so an overworld road feathers exactly like a staged one.
#
# TUNABLES
#
# There are no overworld road fields in GameConfig yet, so widths / feather / curviness /
# tarmac share are CONSTRUCTOR PARAMETERS with the documented defaults below.
# `from_config` derives the two that DO have stage equivalents (`track_width`,
# `track_transition_cells`) plus the shared `track_seed` from a GameConfig, so a designer
# retuning the stage road moves the overworld road with it. TODO: promote the rest to
# GameConfig (`overworld_road_width_m`, `overworld_road_shoulder_m`,
# `overworld_road_curve_frac`, `overworld_road_tarmac_share`) once the carve lands and the
# numbers have been driven.

# --- Defaults (see "TUNABLES") ---------------------------------------------------------

## Full driving width of an overworld road, metres. Wider than a stage road (GameConfig
## `track_width`, 6 m) reads badly at 4 km scale; `from_config` uses track_width directly.
const DEFAULT_WIDTH_M := 7.0
## Feather band OUTSIDE the road edge, metres — the grass↔road transition. The stage
## equivalent is `track_transition_cells` * TrackGenerator.CELL_M (3 m).
const DEFAULT_SHOULDER_M := 4.0
## Peak sideways bend of an edge as a fraction of its straight-line length. Small on
## purpose: the road must still read as "this pin to that pin". 0 = dead straight.
const DEFAULT_CURVE_FRAC := 0.055
## Hard ceiling on that bend, metres, so a very long edge does not sweep across the map.
const DEFAULT_CURVE_MAX_M := 140.0
## Interior control points per edge (the bend is a Catmull-Rom through these).
const DEFAULT_CURVE_POINTS := 3
## Polyline sampling step, metres. Segment length drives the spatial-grid cell size and
## therefore the per-query cost — see `road_at`.
const DEFAULT_SAMPLE_STEP_M := 20.0
## Share of edges surfaced as tarmac (the rest gravel), in [0, 1]. Picked per edge from a
## seeded hash, so which roads are paved is stable but not authored.
const DEFAULT_TARMAC_SHARE := 0.35
## Prune an edge A-B when a two-hop path A-C-B exists no longer than this multiple of it.
## 1.0 would prune nothing; large values thin the web to a spine. 1.35 removes the long
## side of a near-degenerate triangle while keeping genuine alternative routes. Measured on
## the shipped 38-rally roster (+ garage): 85 raw edges -> 68 kept, mean degree 4.1 -> 3.5,
## still one connected component. 1.2 barely thins it (82); 2.0 strips it to a near-spine (52).
const DEFAULT_DETOUR_RATIO := 1.6

# --- Parameters (immutable after construction) -----------------------------------------

var _width_m: float
var _shoulder_m: float
var _curve_frac: float
var _curve_max_m: float
var _curve_points: int
var _sample_step_m: float
var _tarmac_share: float
var _detour_ratio: float
var _seed: int

# --- Built state -----------------------------------------------------------------------

var _size_m := 0.0
var _built := false
# Nodes: [{ "id": String, "map_pos": Vector2, "world": Vector2, "is_hq": bool }]
var _nodes: Array[Dictionary] = []
# Edges: [{ "a": int, "b": int, "points": PackedVector2Array, "length_m": float,
#           "tarmac": float }]  (a/b index into _nodes; points are world XZ)
var _edges: Array[Dictionary] = []
# How many edges the connectivity pass had to invent (0 on a well-fitted pin field).
var _joins_added := 0

# Flat segment arrays (one entry per polyline segment of every edge), so the hot query
# path allocates nothing: A, delta, 1/|delta|², owning edge.
var _seg_ax := PackedFloat32Array()
var _seg_ay := PackedFloat32Array()
var _seg_dx := PackedFloat32Array()
var _seg_dy := PackedFloat32Array()
var _seg_inv := PackedFloat32Array()
var _seg_edge := PackedInt32Array()
# Segment midpoints, binned by SpatialGrid — the index in the grid IS the segment index.
var _seg_mid := PackedVector2Array()
var _grid := {}
var _grid_cell := 0.0


## `width_m` / `shoulder_m` are the road's full driving width and the feather band just
## outside its edge. The rest are the curviness / surface / pruning knobs documented above.
## Prefer `from_config` so the stage tunables drive the shared ones.
## Parameters are `p_`-prefixed where they would otherwise shadow the same-named getter
## below (`width_m()` / `shoulder_m()`); warnings are errors in this project.
func _init(seed_value: int = 0,
		p_width_m: float = DEFAULT_WIDTH_M,
		p_shoulder_m: float = DEFAULT_SHOULDER_M,
		curve_frac: float = DEFAULT_CURVE_FRAC,
		curve_max_m: float = DEFAULT_CURVE_MAX_M,
		curve_points: int = DEFAULT_CURVE_POINTS,
		sample_step_m: float = DEFAULT_SAMPLE_STEP_M,
		tarmac_share: float = DEFAULT_TARMAC_SHARE,
		detour_ratio: float = DEFAULT_DETOUR_RATIO) -> void:
	_seed = seed_value
	_width_m = maxf(0.5, p_width_m)
	_shoulder_m = maxf(0.0, p_shoulder_m)
	_curve_frac = maxf(0.0, curve_frac)
	_curve_max_m = maxf(0.0, curve_max_m)
	_curve_points = maxi(0, curve_points)
	_sample_step_m = maxf(1.0, sample_step_m)
	_tarmac_share = clampf(tarmac_share, 0.0, 1.0)
	_detour_ratio = maxf(1.0, detour_ratio)


## Build a network whose shared tunables come from `cfg` (null = all defaults): the road
## width from `track_width`, the shoulder from `track_transition_cells`, the seed from
## `track_seed`. Does NOT read `overworld_size_m` — the caller passes `size_m` to `build`,
## so Overworld stays the single owner of the coordinate mapping.
static func from_config(cfg: GameConfig) -> OverworldRoads:
	if cfg == null:
		return OverworldRoads.new()
	var shoulder := float(cfg.track_transition_cells) * TrackGenerator.CELL_M
	return OverworldRoads.new(int(cfg.track_seed), cfg.track_width, shoulder)


## Build the network in WORLD space for a map `size_m` metres on a side. Idempotent:
## calling it again rebuilds from scratch. Safe headless; no scene tree, no nodes.
## `hq_map_pos` is INJECTED rather than read from RallyLibrary's const: the garage now stands
## beside the player's first-car rally (RallyLibrary.hq_map_pos), and this file must not learn to
## read a profile — it is a pure geometric builder whose output is folded into the chunk cache key.
# Where the garage stands, injected by build(). See that function.
var _hq_map_pos := RallyLibrary.HQ_MAP_POS


func build(size_m: float, hq_map_pos: Vector2 = RallyLibrary.HQ_MAP_POS) -> void:
	_hq_map_pos = hq_map_pos
	_size_m = size_m
	_nodes = []
	_edges = []
	_joins_added = 0
	_built = true
	_build_nodes()
	if _nodes.size() < 2 or size_m <= 0.0:
		_build_segments()
		return
	var pairs := _build_edges()
	pairs = _prune_redundant(pairs)
	pairs = _join_components(pairs)
	for pair in pairs:
		_edges.append(_make_edge(int(pair.x), int(pair.y)))
	_build_segments()


## Whether `build` has been called.
func is_built() -> bool:
	return _built


## The map size the network was built for, metres.
func size_m() -> float:
	return _size_m


## The graph nodes, in roster order with the garage last: dictionaries of
## { id, map_pos, world (Vector2 world XZ), is_hq }. Read-only by convention.
func nodes() -> Array[Dictionary]:
	return _nodes


## The graph edges: { a, b (indices into `nodes()`), points (PackedVector2Array, the world-XZ
## polyline INCLUDING both endpoints), length_m (along the polyline), tarmac (0/1) }.
func edges() -> Array[Dictionary]:
	return _edges


## How many edges the connectivity pass had to add to make every rally road-reachable from
## the garage. Non-zero means the pin fit (tools/fit_map_pins.py) and this pairing rule
## disagree — `build` also pushes a warning to the log when it happens.
func joins_added() -> int:
	return _joins_added


## The polyline of edge `index`, world XZ. Empty for an out-of-range index.
func polyline(index: int) -> PackedVector2Array:
	if index < 0 or index >= _edges.size():
		return PackedVector2Array()
	return _edges[index]["points"]


## Index of the garage / HQ node in `nodes()`, or -1 before `build`. It is appended last by
## `_build_nodes`, but callers should ask rather than assume.
func hq_index() -> int:
	for i in _nodes.size():
		if bool(_nodes[i]["is_hq"]):
			return i
	return -1


## The UNIT direction (world XZ) in which each road LEAVES node `index` — one entry per edge
## touching it, in edge order. Read off the edge polyline rather than the straight pin-to-pin
## line, so a curved edge reports the direction the tarmac actually heads in at the node, which
## is what "the road runs past here on this bearing" means on the ground.
##
## `min_step_m` is how far along the polyline to look before taking the bearing: far enough that
## a sampling wobble does not dominate, near enough that the answer is still local to the node.
## Pure and deterministic — same network, same array, same order.
func approach_dirs(index: int, min_step_m: float = 25.0) -> Array[Vector2]:
	var out: Array[Vector2] = []
	if index < 0 or index >= _nodes.size():
		return out
	for edge in _edges:
		var pts: PackedVector2Array = edge["points"]
		if pts.size() < 2:
			continue
		var forward := int(edge["a"]) == index
		if not forward and int(edge["b"]) != index:
			continue
		var origin: Vector2 = pts[0] if forward else pts[pts.size() - 1]
		var dir := Vector2.ZERO
		for k in range(1, pts.size()):
			var p: Vector2 = pts[k] if forward else pts[pts.size() - 1 - k]
			var d := p - origin
			var l := d.length()
			if l <= 0.0:
				continue
			dir = d / l
			if l >= min_step_m:
				break
		if dir != Vector2.ZERO:
			out.append(dir)
	return out


## Full driving width / feather band, metres — what the carve should widen its chunk rect by.
func width_m() -> float:
	return _width_m


func shoulder_m() -> float:
	return _shoulder_m


## The distance from a road centreline beyond which `road_at` is guaranteed to answer zero.
## Use it to inflate a chunk rect before calling `segments_in_rect`.
func influence_m() -> float:
	return _width_m * 0.5 + _shoulder_m


# --- Queries ---------------------------------------------------------------------------

## The polyline segments that could touch `rect` (world XZ), as
## [{ "a": Vector2, "b": Vector2, "edge": int, "tarmac": float }]. Backed by SpatialGrid, so
## a 50 m chunk tests a handful of segments rather than the whole network. The rect is
## inflated by `influence_m()` internally, so pass the raw chunk rect.
func segments_in_rect(rect: Rect2) -> Array:
	var out: Array = []
	_scan_rect(rect, out, false)
	return out


## True when ANY segment could touch `rect` — the per-chunk REJECT the terrain carve runs before
## its per-vertex loop. `segments_in_rect(rect).is_empty()` answers the same question, but it
## first builds an Array of freshly allocated Dictionaries the caller then throws away; the vast
## majority of a ~1,600-chunk map is road-free, so that allocation was pure waste on the common
## path. Stops at the first hit.
func has_segments_in_rect(rect: Rect2) -> bool:
	var sink: Array = []
	return _scan_rect(rect, sink, true)


# The one implementation of the rect scan. Appends every touching segment to `out` and returns
# whether at least one was found; with `stop_at_first` it returns as soon as one is, appending
# nothing further. Keeping segments_in_rect and has_segments_in_rect over one scan is what stops
# the cheap reject from drifting away from the list it is meant to predict.
func _scan_rect(rect: Rect2, out: Array, stop_at_first: bool) -> bool:
	if _grid.is_empty() or _grid_cell <= 0.0:
		return false
	var pad := influence_m()
	var grown := rect.grow(pad)
	var lo := SpatialGrid.cell_key(grown.position, _grid_cell)
	var hi := SpatialGrid.cell_key(grown.position + grown.size, _grid_cell)
	# One extra ring: a segment is binned by its MIDPOINT, so its ends reach up to half a
	# segment length outside its own cell.
	for cz in range(lo.y - 1, hi.y + 2):
		for cx in range(lo.x - 1, hi.x + 2):
			var idx: PackedInt32Array = _grid.get(Vector2i(cx, cz), PackedInt32Array())
			for i in idx:
				var a := Vector2(_seg_ax[i], _seg_ay[i])
				var b := a + Vector2(_seg_dx[i], _seg_dy[i])
				if not grown.intersects(Rect2(Vector2(minf(a.x, b.x), minf(a.y, b.y)),
						Vector2(absf(b.x - a.x), absf(b.y - a.y))).grow(0.001)):
					continue
				if stop_at_first:
					return true
				var e: Dictionary = _edges[_seg_edge[i]]
				out.append({"a": a, "b": b, "edge": _seg_edge[i], "tarmac": e["tarmac"]})
	return not out.is_empty()


## THE query the carve runs per cell. The feathered road weighting at world point (x, z):
##   road_weight    1 on the road, smooth-ramping to 0 at width/2 + shoulder (COLOR.a /
##                  TerrainManager.track_weights — same smooth_ramp as bake_track).
##   tarmac_weight  0 gravel, 1 tarmac (UV2.x / TerrainManager.track_surface), blended
##                  across overlapping roads so a gravel road meeting a paved one does not
##                  produce a hard seam at the junction.
##   distance_m     distance to the nearest centreline (INF when no segment is in range).
##   foot           the nearest point ON a centreline (Vector2 world XZ); the carve should
##                  sample its PURE noise height there for the roadbed, exactly as
##                  TerrainManager.bake_track fills `road_heights`. Vector2.ZERO when off.
## Off-road answers { road_weight: 0.0, tarmac_weight: 0.0, distance_m: INF,
## foot: Vector2.ZERO } without touching a segment beyond the 3x3 bin scan.
func road_at(x: float, z: float) -> Dictionary:
	var probe: Array = [0.0, 0.0, 0.0, 0.0, 0.0]
	road_at_into(x, z, probe)
	return {
		"road_weight": probe[PROBE_ROAD_WEIGHT],
		"tarmac_weight": probe[PROBE_TARMAC_WEIGHT],
		"distance_m": probe[PROBE_DISTANCE_M],
		"foot": Vector2(probe[PROBE_FOOT_X], probe[PROBE_FOOT_Y]),
	}


## Slot layout of the `out` array `road_at_into` fills. Named so a caller never indexes by
## a bare integer.
const PROBE_ROAD_WEIGHT := 0
const PROBE_TARMAC_WEIGHT := 1
const PROBE_DISTANCE_M := 2
const PROBE_FOOT_X := 3
const PROBE_FOOT_Y := 4
## Number of slots `out` must have.
const PROBE_SLOTS := 5


## ALLOCATION-FREE twin of `road_at`, and the one place the scan is actually implemented —
## `road_at` is a thin Dictionary wrapper over it, so the two can never drift.
##
## Fills `out` (a caller-owned Array with at least PROBE_SLOTS entries) with
## [road_weight, tarmac_weight, distance_m, foot.x, foot.y] — exactly the four values
## `road_at`'s dictionary carries, in the same order as the PROBE_* constants.
##
## WHY IT EXISTS. `road_at` allocates a fresh 4-key Dictionary (and a Vector2) per call, and
## the overworld carve calls it once PER VERTEX — 2,601 times per chunk. That allocation was
## measured as the dominant cost of rehydrating a cached chunk. Same reasoning as
## `OverworldPads.pad_at` returning a Vector2 instead of a dict.
##
## WHY AN OUT-PARAM AND NOT A SCRATCH FIELD ON THIS OBJECT. Not thread-safety — terrain
## generation is entirely single-threaded (`WorkerThreadPool` / `Thread` appear nowhere in the
## terrain path). A reused scratch field, `Drivetrain.surface_tire_params`-style, would work; an
## out-param is preferred on merit, because it carries no "read it immediately, never hold two
## results at once" hazard for the caller and costs 5 integer-indexed reads rather than a
## Dictionary's key hashing per vertex. `Array` and not `PackedFloat32Array`: plain Arrays are
## passed by REFERENCE in GDScript, while Packed arrays are copy-on-write values whose
## in-function writes the caller would never see.
func road_at_into(x: float, z: float, out: Array) -> void:
	if out.size() < PROBE_SLOTS:
		out.resize(PROBE_SLOTS)
	var inner := _width_m * 0.5
	var outer := inner + _shoulder_m
	var best_dsq := INF
	var best_seg := -1
	var best_t := 0.0
	var w_sum := 0.0
	var tarmac_sum := 0.0
	if _grid_cell > 0.0 and not _grid.is_empty():
		var outer_sq := outer * outer
		var base := SpatialGrid.cell_key(Vector2(x, z), _grid_cell)
		for oz in range(-1, 2):
			for ox in range(-1, 2):
				var idx: PackedInt32Array = _grid.get(Vector2i(base.x + ox, base.y + oz),
					PackedInt32Array())
				for i in idx:
					var wx := x - _seg_ax[i]
					var wz := z - _seg_ay[i]
					var t := clampf((wx * _seg_dx[i] + wz * _seg_dy[i]) * _seg_inv[i], 0.0, 1.0)
					var ex := wx - _seg_dx[i] * t
					var ez := wz - _seg_dy[i] * t
					var dsq := ex * ex + ez * ez
					if dsq < best_dsq:
						best_dsq = dsq
						best_seg = i
						best_t = t
					if dsq >= outer_sq:
						continue
					var w := TerrainManager.smooth_ramp(sqrt(dsq), inner, outer)
					if w <= 0.0:
						continue
					w_sum += w
					tarmac_sum += w * float(_edges[_seg_edge[i]]["tarmac"])
	if best_seg < 0:
		out[PROBE_ROAD_WEIGHT] = 0.0
		out[PROBE_TARMAC_WEIGHT] = 0.0
		out[PROBE_DISTANCE_M] = INF
		out[PROBE_FOOT_X] = 0.0
		out[PROBE_FOOT_Y] = 0.0
		return
	var dist := sqrt(best_dsq)
	out[PROBE_ROAD_WEIGHT] = TerrainManager.smooth_ramp(dist, inner, outer)
	out[PROBE_TARMAC_WEIGHT] = (tarmac_sum / w_sum) if w_sum > 0.0 else 0.0
	out[PROBE_DISTANCE_M] = dist
	out[PROBE_FOOT_X] = _seg_ax[best_seg] + _seg_dx[best_seg] * best_t
	out[PROBE_FOOT_Y] = _seg_ay[best_seg] + _seg_dy[best_seg] * best_t


## Distance from (x, z) to the nearest road centreline, metres — INF when nothing is within
## the 3x3 bin neighbourhood (i.e. comfortably off-road). For the carve's flatten falloff
## and for keeping foliage / scatter off the road.
func distance_to_road_m(x: float, z: float) -> float:
	return float(road_at(x, z)["distance_m"])


## How hard the carve should pull the terrain toward the ROAD's own height at (x, z), in
## [0, 1]: 1 on the road (fully levelled roadbed), ramping to 0 at the shoulder edge.
## Intended use, mirroring TerrainManager.bake_track's road_heights / road_blend pair:
##
##     var hit := roads.road_at(wx, wz)
##     var bias := roads.height_bias_at(wx, wz)          # == hit.road_weight today
##     if bias > 0.0:
##         var road_h := terrain_noise_height_at(hit.foot)   # PURE field at the foot
##         h = lerpf(h, road_h, bias)
##
## Kept a separate function (rather than reusing road_weight) because the flatten band and
## the COLOUR band are allowed to diverge later — the caller should not have to care.
func height_bias_at(x: float, z: float) -> float:
	return float(road_at(x, z)["road_weight"])


## A stable hash of EVERYTHING the geometry derives from: every node id and quantised pin
## position, the reveal radius that decides its edges, the widths, the curve knobs, the
## seed and `size_m`. The overworld chunk cache keys off this (see
## OverworldCache.invalidation_key, whose string-parts style this follows), so a moved pin
## invalidates the cached chunks. Order-independent: node parts are sorted.
func network_hash() -> int:
	var parts := PackedStringArray()
	parts.append("v=1")
	parts.append("size=%.4f" % _size_m)
	parts.append("seed=%d" % _seed)
	parts.append("w=%.4f,%.4f" % [_width_m, _shoulder_m])
	parts.append("curve=%.5f,%.4f,%d,%.4f" % [_curve_frac, _curve_max_m, _curve_points,
		_sample_step_m])
	parts.append("surface=%.5f" % _tarmac_share)
	parts.append("prune=%.5f" % _detour_ratio)
	var node_parts := PackedStringArray()
	for node in _nodes:
		var mp: Vector2 = node["map_pos"]
		node_parts.append("n=%s,%.6f,%.6f,%.6f" % [String(node["id"]), mp.x, mp.y,
			float(node["radius"])])
	node_parts.sort()
	for p in node_parts:
		parts.append(p)
	return hash("|".join(parts))


# --- Graph construction ----------------------------------------------------------------

# Nodes: every rally's pin (through the Registry.Seam, so a synthetic test roster works),
# plus the garage. Rallies are opaque input — only map_pos, reveal radius and id are read,
# and no particular catalogue entry is assumed.
func _build_nodes() -> void:
	for rally in RallyLibrary.all():
		var mp := RallyLibrary.map_pos_of(rally)
		_nodes.append({
			"id": String(rally.get("id", "")),
			"map_pos": mp,
			"world": _world_of(mp),
			"radius": RallyLibrary.reveal_radius_of(rally),
			"is_hq": false,
		})
	# The garage. Its radius matches the roster default so the rule reads the same at both
	# ends of an HQ edge (RallyLibrary.reveal_radius_of({}) resolves the GameConfig default).
	_nodes.append({
		"id": "__hq__",
		"map_pos": _hq_map_pos,
		"world": _world_of(_hq_map_pos),
		"radius": RallyLibrary.reveal_radius_of({}),
		"is_hq": true,
	})


func _world_of(map_pos: Vector2) -> Vector2:
	var w := Overworld.world_xz(map_pos, _size_m)
	return Vector2(w.x, w.z)


# The pairing rule, WITHOUT reveal_link_pairs' lit filter: dist(a, b) <= max(radius_a,
# radius_b), in normalised map units. Returns canonical Vector2i(a, b) pairs with a < b,
# sorted longest-first so pruning is order-independent.
func _build_edges() -> Array[Vector2i]:
	var pairs: Array[Vector2i] = []
	for a in _nodes.size():
		var pa: Vector2 = _nodes[a]["map_pos"]
		for b in range(a + 1, _nodes.size()):
			var pb: Vector2 = _nodes[b]["map_pos"]
			var reach: float = maxf(float(_nodes[a]["radius"]), float(_nodes[b]["radius"]))
			if pa.distance_squared_to(pb) > reach * reach:
				continue
			if pa.distance_squared_to(pb) <= 0.0:
				continue  # coincident pins (a synthetic roster authoring no map_pos)
			pairs.append(Vector2i(a, b))
	pairs.sort_custom(_longest_first)
	return pairs


func _longest_first(p: Vector2i, q: Vector2i) -> bool:
	var lp := _map_len(p)
	var lq := _map_len(q)
	if not is_equal_approx(lp, lq):
		return lp > lq
	if p.x != q.x:
		return p.x < q.x
	return p.y < q.y


func _map_len(p: Vector2i) -> float:
	var a: Vector2 = _nodes[p.x]["map_pos"]
	var b: Vector2 = _nodes[p.y]["map_pos"]
	return a.distance_to(b)


# Drop the long side of a near-degenerate triangle: edge A-B goes when some kept two-hop
# path A-C-B is no longer than `_detour_ratio` * |A-B|. Longest edges are considered first
# (so the biggest redundancy goes), and a dropped edge is removed from the adjacency
# immediately, so a chain of near-collinear pins keeps its links. Connectivity is preserved
# by construction: the substitute path is made of edges still in the set.
func _prune_redundant(pairs: Array[Vector2i]) -> Array[Vector2i]:
	var adj: Array[Dictionary] = []
	for i in _nodes.size():
		adj.append({})
	for p in pairs:
		var l := _map_len(p)
		adj[p.x][p.y] = l
		adj[p.y][p.x] = l
	var kept: Array[Vector2i] = []
	for p in pairs:
		var direct: float = float(adj[p.x][p.y])
		var redundant := false
		# Walk the SMALLER neighbourhood — the pin field is dense in places.
		var near: int = p.x if adj[p.x].size() <= adj[p.y].size() else p.y
		var far: int = p.y if near == p.x else p.x
		var via: Dictionary = adj[near]
		for c in via:
			if int(c) == far:
				continue
			var second: Variant = adj[far].get(c)
			if second == null:
				continue
			if float(via[c]) + float(second) <= direct * _detour_ratio:
				redundant = true
				break
		if redundant:
			adj[p.x].erase(p.y)
			adj[p.y].erase(p.x)
		else:
			kept.append(p)
	return kept


# Guarantee every rally is road-reachable from the garage. tools/fit_map_pins.py fits the
# pins so the reveal closure covers the roster, so this SHOULD be a no-op — but a pin field
# is data, so verify rather than assume: union-find the kept edges, then repeatedly join the
# two components whose closest pins are closest (an MST-style pass over components). Logs a
# warning per added edge, because an add means the pin fit and this pairing rule disagree.
func _join_components(pairs: Array[Vector2i]) -> Array[Vector2i]:
	var parent := PackedInt32Array()
	parent.resize(_nodes.size())
	for i in _nodes.size():
		parent[i] = i
	for p in pairs:
		_union(parent, p.x, p.y)
	var out := pairs.duplicate()
	while true:
		# Cheapest edge between two different components. O(n²) over ~39 pins per join.
		var best := Vector2i(-1, -1)
		var best_len := INF
		for a in _nodes.size():
			for b in range(a + 1, _nodes.size()):
				if _find(parent, a) == _find(parent, b):
					continue
				var l := _map_len(Vector2i(a, b))
				if l < best_len or (is_equal_approx(l, best_len) and a < best.x):
					best_len = l
					best = Vector2i(a, b)
		if best.x < 0:
			break
		_union(parent, best.x, best.y)
		out.append(best)
		_joins_added += 1
		push_warning("OverworldRoads: pin '%s' was not road-reachable; joined to '%s' (%.4f map units). The pin fit and the road pairing rule disagree — check tools/fit_map_pins.py."
			% [String(_nodes[best.y]["id"]), String(_nodes[best.x]["id"]), best_len])
	return out


func _find(parent: PackedInt32Array, i: int) -> int:
	var root := i
	while parent[root] != root:
		root = parent[root]
	var walk := i
	while parent[walk] != root:
		var next := parent[walk]
		parent[walk] = root
		walk = next
	return root


func _union(parent: PackedInt32Array, a: int, b: int) -> void:
	var ra := _find(parent, a)
	var rb := _find(parent, b)
	if ra != rb:
		parent[maxi(ra, rb)] = mini(ra, rb)


# --- Geometry --------------------------------------------------------------------------

# One edge's world polyline: a Catmull-Rom through the two pins plus `_curve_points`
# interior control points, each offset PERPENDICULAR to the straight line by a seeded
# amount. Amplitude is capped at min(_curve_frac * length, _curve_max_m) so the road bends
# without wandering away from the pins it exists to connect (both endpoints are exact).
func _make_edge(a: int, b: int) -> Dictionary:
	var pa: Vector2 = _nodes[a]["world"]
	var pb: Vector2 = _nodes[b]["world"]
	var straight := pb - pa
	var length := straight.length()
	var ctrl := PackedVector2Array()
	ctrl.append(pa)
	if length > 0.0 and _curve_points > 0:
		var dir := straight / length
		var normal := Vector2(-dir.y, dir.x)
		var amp: float = minf(_curve_frac * length, _curve_max_m)
		for k in _curve_points:
			var t := float(k + 1) / float(_curve_points + 1)
			# Taper the offset to 0 at both ends (sin bell), so the pins stay exact and the
			# road leaves them roughly along the straight line.
			var taper := sin(t * PI)
			var off := (_edge_hash(a, b, 101 + k) * 2.0 - 1.0) * amp * taper
			ctrl.append(pa + straight * t + normal * off)
	ctrl.append(pb)
	var points := _catmull_rom(ctrl, length)
	var total := 0.0
	for i in range(1, points.size()):
		total += points[i].distance_to(points[i - 1])
	return {
		"a": a,
		"b": b,
		"points": points,
		"length_m": total,
		"tarmac": 1.0 if _edge_hash(a, b, 7) < _tarmac_share else 0.0,
	}


# A seeded pseudo-random in [0, 1) for an edge, keyed off the QUANTISED endpoint positions
# rather than node indices, so the value survives a reordered roster. Canonicalised
# (min/max) so A-B and B-A hash the same.
func _edge_hash(a: int, b: int, salt: int) -> float:
	var pa: Vector2 = _nodes[a]["map_pos"]
	var pb: Vector2 = _nodes[b]["map_pos"]
	var ka := _pos_key(pa)
	var kb := _pos_key(pb)
	return ScatterMath.hash01(mini(ka, kb), maxi(ka, kb), _seed, salt)


func _pos_key(map_pos: Vector2) -> int:
	return int(hash([roundi(map_pos.x * 100000.0), roundi(map_pos.y * 100000.0)]))


# Uniform-ish sampling of a Catmull-Rom spline through `ctrl` (endpoints duplicated), at
# roughly `_sample_step_m` metres. Pure; no Curve2D resource.
func _catmull_rom(ctrl: PackedVector2Array, straight_len: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	if ctrl.size() < 2:
		return ctrl
	var spans := ctrl.size() - 1
	var per_span: int = maxi(1, int(ceil((straight_len / _sample_step_m) / float(spans))))
	out.append(ctrl[0])
	for s in spans:
		var p0 := ctrl[maxi(s - 1, 0)]
		var p1 := ctrl[s]
		var p2 := ctrl[s + 1]
		var p3 := ctrl[mini(s + 2, ctrl.size() - 1)]
		for step in range(1, per_span + 1):
			var t := float(step) / float(per_span)
			out.append(_catmull_point(p0, p1, p2, p3, t))
	return out


func _catmull_point(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * ((2.0 * p1) + (-p0 + p2) * t
		+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
		+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)


# Flatten every edge polyline into the segment arrays and bin the midpoints with
# SpatialGrid. The cell size is half the longest segment plus the influence radius, so the
# 3x3 neighbourhood around any query point is guaranteed to contain every segment that
# could be within `influence_m()` of it.
func _build_segments() -> void:
	_seg_ax = PackedFloat32Array()
	_seg_ay = PackedFloat32Array()
	_seg_dx = PackedFloat32Array()
	_seg_dy = PackedFloat32Array()
	_seg_inv = PackedFloat32Array()
	_seg_edge = PackedInt32Array()
	_seg_mid = PackedVector2Array()
	_grid = {}
	_grid_cell = 0.0
	var longest := 0.0
	for ei in _edges.size():
		var pts: PackedVector2Array = _edges[ei]["points"]
		for i in range(1, pts.size()):
			var a := pts[i - 1]
			var d := pts[i] - a
			var l2 := d.length_squared()
			if l2 <= 0.0:
				continue
			_seg_ax.append(a.x)
			_seg_ay.append(a.y)
			_seg_dx.append(d.x)
			_seg_dy.append(d.y)
			_seg_inv.append(1.0 / l2)
			_seg_edge.append(ei)
			_seg_mid.append(a + d * 0.5)
			longest = maxf(longest, sqrt(l2))
	if _seg_mid.is_empty():
		return
	_grid_cell = longest * 0.5 + influence_m()
	_grid = SpatialGrid.of_indices(_seg_mid, _grid_cell)
