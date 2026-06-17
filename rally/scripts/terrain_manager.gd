@tool
extends Node3D
class_name TerrainManager

# Owns the procedural terrain: noise state, height sampling, and the lifecycle
# of the TerrainChunk children loaded around the car. The terrain is infinite in
# theory (height_at is pure noise over world coords); only a RADIUS-ring of
# chunks around the focus is ever built.

const CHUNK_M := 50.0                        # chunk edge length in metres
const CELL_M := 1.0                          # grid cell size (PS1 low-poly terrain)
const SAMPLES := int(CHUNK_M / CELL_M) + 1   # 51 height vertices per edge
const RADIUS := 1                            # ring radius -> (2*RADIUS+1)^2 = 3x3
const MAX_INTEGRATIONS_PER_FRAME := 1   # cap chunk node creation per frame
const ROAD_SAMPLE_STEP_M := 0.25        # centerline sampling density for bake_road

const ChunkScript := preload("res://scripts/terrain_chunk.gd")

@export var noise_seed: int = 1337:
	set(value):
		noise_seed = value
		_rebuild_loaded()

@export var layers: Array[TerrainLayer] = []:
	set(value):
		layers = value
		_connect_layer_signals()
		_rebuild_loaded()

@export var texture_tile_per_meter: float = 0.125:
	set(value):
		texture_tile_per_meter = value
		_rebuild_loaded()

# Material applied to every chunk mesh. Set in main.tscn to the shared floor
# material so it survives runtime mesh assignment (see test_smoke).
@export var chunk_material: Material

# Track overlay: global cell coords (Vector2i) painted as track. The road is
# rendered by cross-fading the ground texture to the road texture in the shader
# (ps1_models.gdshader); the blend weight per vertex is carried in the vertex
# colour's ALPHA channel (see vertex_colors). `default_cell_color` is a plain
# RGB ground tint (white = grass unmodified). Setting these does NOT regenerate
# terrain — see set_track().
var default_cell_color: Color = Color(1, 1, 1)
# Weighted road fields, built by bake_track(), read by compute_chunk_data() /
# vertex_colors(). All weights ramp 1 (on the road) -> 0 (outer edge of the
# transition band); entries with weight 0 are omitted. Empty = no track.
var road_heights: Dictionary = {}   # vertex index (Vector2i) -> nearest road Y
var road_blend: Dictionary = {}     # vertex index -> height blend weight [0,1]
var track_weights: Dictionary = {}  # cell index -> colour blend weight [0,1]

# Node whose position drives chunk loading (the car). Resolved lazily.
@export var focus_path: NodePath = NodePath("../Car")

# coord (Vector2i) -> TerrainChunk
var _chunks: Dictionary = {}
var _last_focus_coord: Vector2i = Vector2i(2147483647, 0)  # force first reconcile
# Runtime generates chunks on worker threads; the editor always stays synchronous
# (enforced in _reconcile via Engine.is_editor_hint(), NOT by mutating this flag —
# see _ready). Tests set this false explicitly.
@export var use_threaded_generation: bool = true
# When true, _ready does NOT build the initial ring — a parent (world.gd) builds
# it via build_initial() after the track is applied, so flattening is baked in on
# the first build. The editor always previews terrain regardless of this flag.
@export var defer_initial_build: bool = false
var _pending: Dictionary = {}          # coord -> WorkerThreadPool task id
var _results: Dictionary = {}          # coord -> data Dictionary (worker-written)
var _results_mutex: Mutex = Mutex.new()
# Total chunk nodes spawned (mesh + collision built on the main thread). Read by
# PerfOverlay to correlate frame-time spikes with terrain integration work.
var integrations_total: int = 0

# Main-thread noise cache for height_at(): FastNoiseLite instances are expensive
# to build, and height_at used to rebuild all layers on every call (it is hit
# once per centerline sample in bake_track). The cache is invalidated by every
# terrain mutation path via _rebuild_loaded. NOT shared with the worker threads:
# compute_chunk_data / build_heights build their own local instances via
# _build_noises (FastNoiseLite is shared mutable state), so the cache only ever
# serves the main thread.
var _cached_noises: Array[FastNoiseLite] = []
var _cached_amplitudes: PackedFloat32Array = PackedFloat32Array()
var _noise_cache_valid := false


func _connect_layer_signals() -> void:
	for layer in layers:
		if layer == null:
			continue
		if not layer.changed.is_connected(_rebuild_loaded):
			layer.changed.connect(_rebuild_loaded)


func _default_layers() -> Array[TerrainLayer]:
	var result: Array[TerrainLayer] = []
	for params in [[60.0, 1.5], [15.0, 0.4], [3.0, 0.1]]:
		var layer := TerrainLayer.new()
		layer.wavelength_m = params[0]
		layer.amplitude_m = params[1]
		result.append(layer)
	return result


func _is_valid_layer(layer: TerrainLayer) -> bool:
	return layer != null and layer.wavelength_m > 0.0


func _make_noise(layer_index: int) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.fractal_type = FastNoiseLite.FRACTAL_NONE
	noise.seed = noise_seed + layer_index
	noise.frequency = 1.0 / layers[layer_index].wavelength_m
	return noise


# Build a matched (noises, amplitudes) pair, one entry per valid layer, as
# [Array[FastNoiseLite], PackedFloat32Array]. Worker threads call this so they
# get their own FastNoiseLite instances (the type is shared mutable state); the
# main thread reuses the cached pair via _ensure_noise_cache.
func _build_noises() -> Array:
	var noises: Array[FastNoiseLite] = []
	var amplitudes: PackedFloat32Array = PackedFloat32Array()
	for i in layers.size():
		if not _is_valid_layer(layers[i]):
			continue
		noises.append(_make_noise(i))
		amplitudes.append(layers[i].amplitude_m)
	return [noises, amplitudes]


# Sum the layer noises at a world XZ into a height. noises/amplitudes are a
# matched pair from _build_noises (or the main-thread cache).
static func _sample_height(noises: Array, amplitudes: PackedFloat32Array, x: float, z: float) -> float:
	var h := 0.0
	for i in noises.size():
		h += noises[i].get_noise_2d(x, z) * amplitudes[i]
	return h


# Lazily (re)build the main-thread noise cache. Invalidated by _rebuild_loaded.
func _ensure_noise_cache() -> void:
	if _noise_cache_valid:
		return
	var pair := _build_noises()
	_cached_noises = pair[0]
	_cached_amplitudes = pair[1]
	_noise_cache_valid = true


# Single-sample height (main thread). Uses the cached noises rather than
# rebuilding all layers per call — bake_track hits this thousands of times.
func height_at(x: float, z: float) -> float:
	_ensure_noise_cache()
	return _sample_height(_cached_noises, _cached_amplitudes, x, z)


# SAMPLES x SAMPLES heights centred on `center` (a chunk centre), sampled at
# absolute world coords so adjacent chunks agree on shared edges. Noises are
# built once here (height_at rebuilds per call — fine for single samples, too
# slow for 40k).
func build_heights(center: Vector3) -> PackedFloat32Array:
	var pair := _build_noises()
	var noises: Array = pair[0]
	var amplitudes: PackedFloat32Array = pair[1]

	var heights := PackedFloat32Array()
	heights.resize(SAMPLES * SAMPLES)
	var half := CHUNK_M / 2.0
	for zi in SAMPLES:
		var z := center.z - half + zi * CELL_M
		for xi in SAMPLES:
			var x := center.x - half + xi * CELL_M
			heights[zi * SAMPLES + xi] = _sample_height(noises, amplitudes, x, z)
	return heights


# Pure CPU work for one chunk: heights + mesh arrays. Safe to call from a worker
# thread — it reads only the (runtime-static) noise params and builds its own
# FastNoiseLite instances, touching no scene state.
func compute_chunk_data(coord: Vector2i) -> Dictionary:
	var half := CHUNK_M / 2.0
	var center := Vector3((coord.x + 0.5) * CHUNK_M, 0.0, (coord.y + 0.5) * CHUNK_M)
	var tile := texture_tile_per_meter

	var pair := _build_noises()
	var noises: Array = pair[0]
	var amplitudes: PackedFloat32Array = pair[1]

	var count := SAMPLES * SAMPLES
	var heights := PackedFloat32Array()
	heights.resize(count)
	# Indexed mesh: one shared vertex per grid sample (1/4 the vertices of the
	# old de-indexed mesh — the big PS1 vertex-throughput win). UVs use world
	# coords (continuous checker). Colours are per-vertex (Gouraud), so the road
	# tint now blends smoothly across cells instead of stepping per square.
	var vertices := PackedVector3Array(); vertices.resize(count)
	var uvs := PackedVector2Array(); uvs.resize(count)
	for zi in SAMPLES:
		var lz := -half + zi * CELL_M
		var wz := center.z + lz
		for xi in SAMPLES:
			var lx := -half + xi * CELL_M
			var wx := center.x + lx
			var h := _sample_height(noises, amplitudes, wx, wz)
			# Blend road vertices toward the baked road height by their weight
			# (mesh + collision): w=1 fully flat, w=0 true terrain, between ramps.
			var vidx := Vector2i(coord.x * (SAMPLES - 1) + xi, coord.y * (SAMPLES - 1) + zi)
			if road_blend.has(vidx):
				h = lerpf(h, road_heights[vidx], road_blend[vidx])
			var idx := zi * SAMPLES + xi
			heights[idx] = h
			vertices[idx] = Vector3(lx, h, lz)
			uvs[idx] = Vector2(wx, wz) * tile

	var per_edge := SAMPLES - 1
	var cells := per_edge * per_edge
	var indices := PackedInt32Array(); indices.resize(cells * 6)
	var ii := 0
	for zi in per_edge:
		for xi in per_edge:
			var a := zi * SAMPLES + xi
			var b := a + 1
			var c := a + SAMPLES
			var d := c + 1
			# Clockwise winding a,b,c / b,d,c (matches the previous mesh).
			indices[ii + 0] = a; indices[ii + 1] = b; indices[ii + 2] = c
			indices[ii + 3] = b; indices[ii + 4] = d; indices[ii + 5] = c
			ii += 6

	var colors := vertex_colors(coord)

	return {
		"center": center,
		"heights": heights,
		"vertices": vertices,
		"uvs": uvs,
		"colors": colors,
		"indices": indices,
	}


# Per-vertex colours for one chunk's indexed mesh. RGB carries default_cell_color
# (a flat ground tint); ALPHA carries the road blend weight — the average of the
# (up to 4) cell weights around each grid vertex — which the shader uses to fade
# the ground texture toward the road texture. track_weights is keyed by GLOBAL
# cell coords, so a shared edge vertex averages the same four global cells from
# either chunk -> weights match exactly across seams (no stitching). Smoothly
# ramped rather than stepped.
func vertex_colors(coord: Vector2i) -> PackedColorArray:
	var per_edge := SAMPLES - 1
	var colors := PackedColorArray()
	colors.resize(SAMPLES * SAMPLES)
	for zi in SAMPLES:
		for xi in SAMPLES:
			var gx := coord.x * per_edge + xi
			var gz := coord.y * per_edge + zi
			# The four cells meeting at this vertex (global cell coords).
			var w: float = (
				track_weights.get(Vector2i(gx - 1, gz - 1), 0.0)
				+ track_weights.get(Vector2i(gx, gz - 1), 0.0)
				+ track_weights.get(Vector2i(gx - 1, gz), 0.0)
				+ track_weights.get(Vector2i(gx, gz), 0.0)
			) / 4.0
			colors[zi * SAMPLES + xi] = Color(
				default_cell_color.r, default_cell_color.g, default_cell_color.b, w)
	return colors


# Chunk coordinate (integer grid) containing a world position.
func chunk_coord_for(pos: Vector3) -> Vector2i:
	return Vector2i(floori(pos.x / CHUNK_M), floori(pos.z / CHUNK_M))


# The (2*RADIUS+1)^2 coords that should be loaded around a centre coord.
func target_coords(center: Vector2i) -> Array:
	var result: Array = []
	for dz in range(-RADIUS, RADIUS + 1):
		for dx in range(-RADIUS, RADIUS + 1):
			result.append(center + Vector2i(dx, dz))
	return result


func loaded_coords() -> Array:
	return _chunks.keys()


# Blend weight for a feature `d` metres from the road centerline: 1 at/inside
# `inner` (= width/2), 0 at/beyond `outer` (= inner + transition), smoothstep
# between. Pure/static for easy testing.
static func smooth_ramp(d: float, inner: float, outer: float) -> float:
	if d <= inner:
		return 1.0
	if d >= outer:
		return 0.0
	var raw := (outer - d) / (outer - inner)
	return raw * raw * (3.0 - 2.0 * raw)


# Sample the terrain densely along the 2D centerline (x -> world x, y -> world z)
# and build the weighted road fields:
#   road_heights[v]  = nearest centerline sample's terrain height (per grid vertex)
#   road_blend[v]    = height blend weight (1 on road -> 0 at outer band edge)
#   track_weights[c] = colour blend weight per cell (same ramp, by cell centre)
# `transition_m` is the band width OUTSIDE width/2. Straight spans tessellate to
# just their endpoints, so each segment is sub-sampled at ROAD_SAMPLE_STEP_M.
func bake_track(centerline: Curve2D, width: float, transition_m: float) -> void:
	var rh: Dictionary = {}
	var rb: Dictionary = {}
	var tw: Dictionary = {}
	var v_best: Dictionary = {}  # vertex -> nearest distance so far
	var c_best: Dictionary = {}  # cell -> nearest distance so far
	var inner := width / 2.0
	var outer := inner + transition_m
	var reach := int(ceil(outer / CELL_M)) + 1
	var poly := centerline.tessellate()
	for i in range(1, poly.size()):
		var a := poly[i - 1]
		var b := poly[i]
		var seg_len := a.distance_to(b)
		var steps := int(ceil(seg_len / ROAD_SAMPLE_STEP_M)) + 1
		for s in steps + 1:
			var t := float(s) / float(steps) if steps > 0 else 0.0
			var p := a.lerp(b, t)
			var y := height_at(p.x, p.y)
			var vbx := roundi(p.x / CELL_M)
			var vbz := roundi(p.y / CELL_M)
			var cbx := floori(p.x / CELL_M)
			var cbz := floori(p.y / CELL_M)
			for dz in range(-reach, reach + 1):
				for dx in range(-reach, reach + 1):
					# Vertex (grid point) -> height field.
					var v := Vector2i(vbx + dx, vbz + dz)
					var dv := Vector2(v.x * CELL_M, v.y * CELL_M).distance_to(p)
					var wv := smooth_ramp(dv, inner, outer)
					if wv > 0.0 and (not v_best.has(v) or dv < v_best[v]):
						v_best[v] = dv
						rh[v] = y
						rb[v] = wv
					# Cell (centre) -> colour field.
					var c := Vector2i(cbx + dx, cbz + dz)
					var dc := Vector2((c.x + 0.5) * CELL_M, (c.y + 0.5) * CELL_M).distance_to(p)
					var wc := smooth_ramp(dc, inner, outer)
					if wc > 0.0 and (not c_best.has(c) or dc < c_best[c]):
						c_best[c] = dc
						tw[c] = wc
	road_heights = rh
	road_blend = rb
	track_weights = tw


# Apply a track: bake the weighted height + road-blend fields from the centerline,
# then rebuild any currently-loaded chunks (mesh + collision) so the texture fade
# takes effect. At startup the ring is deferred (see build_initial), so _chunks is
# empty here and nothing rebuilds; chunks loaded later read the baked fields in
# compute_chunk_data / vertex_colors at build time.
func set_track(centerline: Curve2D, width: float, transition_m: float) -> void:
	bake_track(centerline, width, transition_m)
	for coord in _chunks:
		_chunks[coord].setup(self, coord)


func _ready() -> void:
	# NB: do NOT write use_threaded_generation here. This is a @tool script, so in
	# the editor _ready runs and any mutation of an exported property gets
	# serialized back into the .tscn on the next save (flipping the shipped value).
	# The editor/test "stay synchronous" rule is enforced at the use site in
	# _reconcile via Engine.is_editor_hint() instead.
	if layers.is_empty():
		layers = _default_layers()
	else:
		_connect_layer_signals()
	# Build the initial ring now unless a parent will drive it (defer). The editor
	# always previews, so it builds regardless of the flag.
	if Engine.is_editor_hint() or not defer_initial_build:
		build_initial()


# Build the initial 3x3 ring synchronously around the focus (the car), so there
# is always ground under the car at spawn; later boundary crossings use the
# threaded queue.
func build_initial() -> void:
	var focus := _focus_node()
	var origin: Vector3 = focus.global_position if focus != null else Vector3.ZERO
	_reconcile(chunk_coord_for(origin), true)
	_last_focus_coord = chunk_coord_for(origin)


func _process(_delta: float) -> void:
	var focus := _focus_node()
	if focus != null:
		update_focus(focus.global_position)
	_integrate_ready()


func _focus_node() -> Node3D:
	if focus_path.is_empty():
		return null
	return get_node_or_null(focus_path) as Node3D


# Reconcile the loaded 3x3 set to be centred on `pos`. Cheap to call every
# frame: only does work when the focus crosses into a new chunk.
func update_focus(pos: Vector3) -> void:
	var center := chunk_coord_for(pos)
	if center == _last_focus_coord and not _chunks.is_empty():
		return
	_last_focus_coord = center
	_reconcile(center)


func _reconcile(center: Vector2i, force_sync: bool = false) -> void:
	var wanted := target_coords(center)
	# Free chunks outside the ring.
	for coord in _chunks.keys():
		if not wanted.has(coord):
			_chunks[coord].queue_free()
			_chunks.erase(coord)
	# Pending requests are intentionally NOT cancelled here: their task id stays
	# in _pending until the worker finishes so _exit_tree can wait on it and so a
	# coord that briefly leaves and re-enters the ring is never requested twice.
	# _integrate_ready discards the result if the coord is no longer wanted.
	# Schedule / build missing chunks.
	for coord in wanted:
		if _chunks.has(coord) or _pending.has(coord):
			continue
		# Editor always previews synchronously (deterministic, no worker threads in
		# the tool context); runtime uses the worker pool when enabled.
		if use_threaded_generation and not force_sync and not Engine.is_editor_hint():
			_request_chunk(coord)
		else:
			_spawn_chunk(coord, compute_chunk_data(coord))


func _request_chunk(coord: Vector2i) -> void:
	_pending[coord] = WorkerThreadPool.add_task(_generate_on_worker.bind(coord))


# Runs on a worker thread.
func _generate_on_worker(coord: Vector2i) -> void:
	var data := compute_chunk_data(coord)
	_results_mutex.lock()
	_results[coord] = data
	_results_mutex.unlock()


func _spawn_chunk(coord: Vector2i, data: Dictionary) -> void:
	var chunk: TerrainChunk = ChunkScript.new()
	add_child(chunk)
	chunk.apply_data(self, coord, data)
	_chunks[coord] = chunk
	integrations_total += 1


# Main thread: turn up to MAX_INTEGRATIONS_PER_FRAME finished worker results into
# chunk nodes. Results for coords no longer wanted are discarded.
func _integrate_ready() -> void:
	var integrated := 0
	_results_mutex.lock()
	var ready_coords: Array = _results.keys()
	_results_mutex.unlock()
	var wanted := target_coords(_last_focus_coord)
	for coord in ready_coords:
		if integrated >= MAX_INTEGRATIONS_PER_FRAME:
			break
		_results_mutex.lock()
		var data: Dictionary = _results[coord]
		_results.erase(coord)
		_results_mutex.unlock()
		# The task for this coord is done; release its pending slot.
		_pending.erase(coord)
		if not wanted.has(coord) or _chunks.has(coord):
			continue  # left the ring, or already built — discard
		_spawn_chunk(coord, data)
		integrated += 1


func _exit_tree() -> void:
	# Ensure no worker writes into freed state after the manager leaves the tree.
	for coord in _pending:
		WorkerThreadPool.wait_for_task_completion(_pending[coord])
	_pending.clear()
	_results.clear()


func _rebuild_loaded() -> void:
	_noise_cache_valid = false  # seed / layers / wavelength changed
	for chunk in _chunks.values():
		chunk.setup(self, chunk.coord)
