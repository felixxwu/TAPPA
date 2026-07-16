@tool
extends Node3D
class_name TerrainManager

# Owns the procedural terrain: noise state, height sampling, and the lifecycle
# of the TerrainChunk children loaded around the car. The terrain is precomputed
# over a bounded corridor (see _chunk_cache / precompute_corridor); the RADIUS-ring
# of chunks around the focus is a render/physics window into that cache, not a
# generation stream.

const CHUNK_M := 50.0                        # chunk edge length in metres
const CELL_M := 1.0                          # grid cell size (PS1 low-poly terrain)
const SAMPLES := int(CHUNK_M / CELL_M) + 1   # 51 height vertices per edge
const RADIUS := 3                            # ring radius -> (2*RADIUS+1)^2 = 7x7
# Cliffs & drops (features/terrain.md). The cliff bake is a distance field: each band
# vertex finds its nearest centerline point via a segment spatial hash whose cells are
# CLIFF_GRID_M wide (a whole number of terrain cells). Bigger cells → fewer ring
# expansions per vertex but fatter segment lists to scan; smaller → the reverse.
# ~24 m measured fastest for typical fade radii (a couple of rings, modest lists).
const CLIFF_GRID_M := 24.0
# Salt mixed into track_seed for the camber noise, so the whole stage (track shape,
# surface split, cliffs) is one deterministic function of track_seed.
const CLIFF_SEED_SALT := 0x5C1FF

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
# Per-cell tarmac-ness in [0,1] at the cell's nearest centerline point: 0 = gravel,
# 1 = tarmac, feathered across the single surface switch (see TrackSurface). Keyed
# like track_weights (same road/band cells); read by surface_grip_at() and baked
# into the mesh UV2.x by surface_uv2()/compute_chunk_data so the shader fades the
# gravel texture to the flat tarmac colour the same way the road fades from grass.
var track_surface: Dictionary = {}

# Cliffs & drops (features/terrain.md). A signed per-vertex height offset added on
# top of the noise height (before the road flatten) by bake_track's cliff pass, so a
# stage can run along a ledge — a wall rising on one side, ground falling away on the
# other. Keyed in the same GLOBAL vertex-index space as road_heights (seam-safe by
# construction). Empty when cliff_enabled is off or the effective height is 0.
var cliff_offsets: Dictionary = {}   # global vertex index (Vector2i) -> signed offset (m)
# Cliff params, set from GameConfig.apply_cliffs before bake_track (like the Lighting
# group). cliff_amount is the runtime per-event scale on cliff_max_height_m (0..1),
# written by RallySession from the event's cliffiness; cliff_seed derives the camber
# noise from the stage's track_seed.
var cliff_enabled: bool = false
var cliff_wavelength_m: float = 60.0
var cliff_gain: float = 1.6
var cliff_max_height_m: float = 8.0
var cliff_run_m: float = 6.0
var cliff_fade_m: float = 6.0
# Radius (m) of the post-bake morphological "open" that knocks down thin tall cliff
# walls — e.g. the wall a hairpin's inner crook would otherwise leave. Walls narrower
# than ~2× this in either axis are removed; wider cliffs/drops survive. 0 disables.
var cliff_open_radius_m: float = 4.0
var cliff_amount: float = 1.0
var cliff_seed: int = 1

# Baked terrain lighting. The terrain and the sun never move, so the fake
# directional+hemisphere shading (mirroring shaders/ps1_models_lit.gdshader) is
# computed ONCE per vertex at generation time and folded into the vertex
# colour's RGB — which the flat terrain shader already multiplies into ALBEDO.
# So it costs nothing per frame (unlike the car, which rotates and must light in
# its shader). light_amount 0 = flat (the bake becomes a no-op white multiply).
# Set from GameConfig's Lighting group by world.gd before build_initial().
var light_amount: float = 0.0
var sun_dir: Vector3 = Vector3(0.4, 0.9, 0.35).normalized()
var sun_color: Color = Color(0.5, 0.5, 0.5)
var sky_color: Color = Color(0.5, 0.5, 0.5)
var ground_color: Color = Color(0.35, 0.35, 0.35)

# Terrain LOD (features/terrain.md). The display mesh is decimated by distance:
# each loaded chunk carries one MeshInstance per TerrainLod.LOD_STRIDES level, and
# the engine picks the level by real camera distance via visibility_range (a HARD
# cutoff — the dithered fade is a Forward+/Mobile feature the Compatibility renderer
# ignores, and the alpha-hash discard would defeat early-Z on our opaque terrain).
# `lod_band_ends_m` is the far cutoff (metres) for each level EXCEPT the last (the
# coarsest draws to the ring edge); size = levels - 1. `lod_skirt_m` is the downward
# seam skirt that hides the crack between neighbours at different levels. Set from
# GameConfig.apply_terrain_lod. Collision is a per-frame-free near-band cost: only
# chunks within `collision_ring` (Chebyshev, in chunks) of the focus get live
# collision — farther loaded chunks are render-only.
var lod_band_ends_m: PackedFloat32Array = PackedFloat32Array([20.0, 45.0, 80.0, 130.0])
var lod_skirt_m: float = 3.0
var collision_ring: int = 1

# Debug chunk-border overlay (H toggle, debug builds). Lazily created on first use.
var _border_debug: ChunkBorderDebug = null

# Node whose position drives chunk loading (the car). Resolved lazily.
@export var focus_path: NodePath = NodePath("../Car")

# coord (Vector2i) -> TerrainChunk
var _chunks: Dictionary = {}
var _last_focus_coord: Vector2i = Vector2i(2147483647, 0)  # force first reconcile
# When true, _ready does NOT build the initial ring — a parent (world.gd) builds
# it via build_initial() after the track is applied, so flattening is baked in on
# the first build. The editor always previews terrain regardless of this flag.
@export var defer_initial_build: bool = false
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

# Precomputed terrain: coord -> the data dict compute_chunk_data returns. Filled
# behind the loading screen (world.gd) for the whole reachable corridor — the
# play area is bounded by the off-track reset leash, so this is the complete set
# of chunks the level can request. Runtime chunk loads are then cache lookups
# (~0.2 ms node build), and height_at/light_at serve from it (it is the terrain
# the player actually sees: road flattening included, unlike the raw noise).
var _chunk_cache: Dictionary = {}
# The coords the cache covers, kept so _rebuild_loaded can refill after a
# terrain-param change (seed/layers) instead of serving stale arrays.
var _corridor_coords: Array[Vector2i] = []

# Transient scratch for bake_track's unified nearest-segment search (_nearest_seg). Set
# up at the top of a bake and only valid for its duration — never read outside a bake.
# Per-segment: endpoint (ax,ay), delta (dx,dy), 1/len², arc length at start, unit tangent.
var _cv_ax: PackedFloat32Array
var _cv_ay: PackedFloat32Array
var _cv_dx: PackedFloat32Array
var _cv_dy: PackedFloat32Array
var _cv_inv: PackedFloat32Array
var _cv_len: PackedFloat32Array
var _cv_arc: PackedFloat32Array
var _cv_tx: PackedFloat32Array
var _cv_ty: PackedFloat32Array
var _cv_grid: Array           # spatial-hash cell (flat) -> PackedInt32Array of segment idx
var _cv_gw: int
var _cv_gh: int
var _cv_gx0: int
var _cv_gz0: int
var _cv_G: float
var _cv_R: int
# Out-params of _nearest_seg (avoids a per-call Array allocation in the hot path).
var _cv_best_t: float
var _cv_best_dsq: float


func _connect_layer_signals() -> void:
	for layer in layers:
		if layer == null:
			continue
		if not layer.changed.is_connected(_rebuild_loaded):
			layer.changed.connect(_rebuild_loaded)


# A layerless manager: no noise, so height_at is a flat y = 0 everywhere. Used by
# the podium / HQ dressing to seat Foliage instances on level ground.
static func flat() -> TerrainManager:
	var tm := TerrainManager.new()
	tm.layers = [] as Array[TerrainLayer]
	return tm


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


# PURE noise height — the generator. bake_track and chunk building MUST use
# this (the flattening is derived from it; cache-first there would be circular).
func _noise_height_at(x: float, z: float) -> float:
	_ensure_noise_cache()
	return _sample_height(_cached_noises, _cached_amplitudes, x, z)


# Public height query — CACHE-FIRST. The cached grid is the terrain the player
# actually sees and collides with (road flattening included); the noise is just
# the helper that created it. Outside the corridor (distant backdrop, editor,
# tests without precompute) this silently falls back to pure noise.
func height_at(x: float, z: float) -> float:
	var cached := _cached_height_at(x, z)
	if not is_nan(cached):
		return cached
	return _noise_height_at(x, z)


# Scratch outputs for _resolve_bilinear — reused across calls instead of returning
# a Dictionary, so the cache-first accessors below (called per physics frame via
# height_at) stay allocation-free. Value types (Vector2i / int / float) live inline
# in the fields, no heap churn. Safe as bare instance state: these accessors run one
# at a time on the main thread (the threaded chunk build uses build_heights, not these).
var _bl_coord: Vector2i
var _bl_xi: int
var _bl_zi: int
var _bl_fx: float
var _bl_fz: float


# Resolves the cached-grid chunk + bilinear cell indices/fractions for world XZ into
# the _bl_* scratch fields. Returns false when the point isn't covered (empty cache
# or the owning chunk isn't loaded) so callers fall back. No allocation.
func _resolve_bilinear(x: float, z: float) -> bool:
	if _chunk_cache.is_empty():
		return false
	var coord := chunk_coord_for(Vector3(x, 0.0, z))
	if not _chunk_cache.has(coord):
		return false
	var lx := (x - coord.x * CHUNK_M) / CELL_M
	var lz := (z - coord.y * CHUNK_M) / CELL_M
	_bl_coord = coord
	_bl_xi = clampi(floori(lx), 0, SAMPLES - 2)
	_bl_zi = clampi(floori(lz), 0, SAMPLES - 2)
	_bl_fx = clampf(lx - _bl_xi, 0.0, 1.0)
	_bl_fz = clampf(lz - _bl_zi, 0.0, 1.0)
	return true


# Bilinear height from the cached chunk grid; NAN when the point isn't covered.
func _cached_height_at(x: float, z: float) -> float:
	if not _resolve_bilinear(x, z):
		return NAN
	var heights: PackedFloat32Array = _chunk_cache[_bl_coord]["heights"]
	var xi := _bl_xi
	var zi := _bl_zi
	var a := heights[zi * SAMPLES + xi]
	var b := heights[zi * SAMPLES + xi + 1]
	var c := heights[(zi + 1) * SAMPLES + xi]
	var d := heights[(zi + 1) * SAMPLES + xi + 1]
	return lerpf(lerpf(a, b, _bl_fx), lerpf(c, d, _bl_fx), _bl_fz)


# Baked light tint at a world XZ (main thread), mirroring the per-vertex bake in
# compute_chunk_data so the distant backdrop (DistantTerrain) shades identically
# to the near chunks. White (a no-op) when light_amount is 0. CACHE-FIRST like
# height_at; falls back to a fresh noise-based bake when uncovered or unlit.
func light_at(x: float, z: float) -> Color:
	if light_amount <= 0.0:
		return Color(1, 1, 1)
	var cached := _cached_light_at(x, z)
	if cached.a >= 0.0:
		return cached
	_ensure_noise_cache()
	return _bake_light(_cached_noises, _cached_amplitudes, x, z)


# Bilinear baked light from the cache; alpha -1 signals "not covered" (Color has
# no NAN sentinel). Falls through when the chunk is unlit (empty lights array).
func _cached_light_at(x: float, z: float) -> Color:
	if not _resolve_bilinear(x, z):
		return Color(0, 0, 0, -1.0)
	var lights: PackedColorArray = _chunk_cache[_bl_coord].get("lights", PackedColorArray())
	if lights.is_empty():
		return Color(0, 0, 0, -1.0)
	var xi := _bl_xi
	var zi := _bl_zi
	var a := lights[zi * SAMPLES + xi]
	var b := lights[zi * SAMPLES + xi + 1]
	var c := lights[(zi + 1) * SAMPLES + xi]
	var d := lights[(zi + 1) * SAMPLES + xi + 1]
	var out := a.lerp(b, _bl_fx).lerp(c.lerp(d, _bl_fx), _bl_fz)
	out.a = 1.0
	return out


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


# Pure CPU work for one chunk: heights + mesh arrays. Reads only the
# (runtime-static) noise params. The row-by-row work itself lives in
# TerrainChunkBuilder (kept out of this file for size).
func compute_chunk_data(coord: Vector2i) -> Dictionary:
	var builder := TerrainChunkBuilder.new(self, coord)
	builder.build()
	return builder.data()


# Per-vertex colours for one chunk's indexed mesh. RGB carries default_cell_color
# (a flat ground tint); ALPHA carries the road blend weight — the average of the
# (up to 4) cell weights around each grid vertex — which the shader uses to fade
# the ground texture toward the road texture. track_weights is keyed by GLOBAL
# cell coords, so a shared edge vertex averages the same four global cells from
# either chunk -> weights match exactly across seams (no stitching). Smoothly
# ramped rather than stepped.
func vertex_colors(coord: Vector2i, lights: PackedColorArray = PackedColorArray()) -> PackedColorArray:
	var colors := PackedColorArray()
	colors.resize(SAMPLES * SAMPLES)
	for zi in SAMPLES:
		_vertex_color_row(coord, zi, lights, colors)
	return colors


# Scratch keys for _vertex_cells — the four global cells meeting at one grid vertex,
# reused by _vertex_color_row / _surface_uv2_row instead of a per-vertex Array (which
# would be ~800k allocs across the corridor). Value-type Vector2i fields, no heap churn;
# both callers run on the main thread and consume the keys inline before the next vertex.
var _vc0: Vector2i
var _vc1: Vector2i
var _vc2: Vector2i
var _vc3: Vector2i


# Fills _vc0.._vc3 with the four global cells meeting at grid vertex (gx, gz).
func _vertex_cells(gx: int, gz: int) -> void:
	_vc0 = Vector2i(gx - 1, gz - 1)
	_vc1 = Vector2i(gx, gz - 1)
	_vc2 = Vector2i(gx - 1, gz)
	_vc3 = Vector2i(gx, gz)


# One row of vertex_colors, written into `out` (shared so the incremental
# TerrainChunkBuilder can fill the colour array a row per frame).
func _vertex_color_row(coord: Vector2i, zi: int, lights: PackedColorArray, out: PackedColorArray) -> void:
	var per_edge := SAMPLES - 1
	var has_light := not lights.is_empty()
	for xi in SAMPLES:
		_vertex_cells(coord.x * per_edge + xi, coord.y * per_edge + zi)
		# Average of the four cells meeting at this vertex.
		var w: float = (
			track_weights.get(_vc0, 0.0)
			+ track_weights.get(_vc1, 0.0)
			+ track_weights.get(_vc2, 0.0)
			+ track_weights.get(_vc3, 0.0)
		) / 4.0
		# RGB = ground tint × baked light; ALPHA = road blend weight.
		var idx := zi * SAMPLES + xi
		var lgt := lights[idx] if has_light else Color(1, 1, 1)
		out[idx] = Color(
			default_cell_color.r * lgt.r,
			default_cell_color.g * lgt.g,
			default_cell_color.b * lgt.b,
			w)


# Per-vertex tarmac weight for one chunk's mesh, carried in UV2.x (the shader
# mixes the gravel texture toward the flat tarmac colour by it). Like
# vertex_colors' alpha, each vertex averages the (up to 4) surrounding cells'
# track_surface values — but only over the cells that ARE road/band cells (present
# in track_surface), so the gravel/tarmac split isn't dragged toward gravel by the
# bare grass cells off the road edge. UV2.y is unused (0). Keyed by GLOBAL cell
# coords, so a shared edge vertex averages the same cells from either chunk (seam-safe).
func surface_uv2(coord: Vector2i) -> PackedVector2Array:
	var uv2s := PackedVector2Array()
	uv2s.resize(SAMPLES * SAMPLES)
	for zi in SAMPLES:
		_surface_uv2_row(coord, zi, uv2s)
	return uv2s


# One row of surface_uv2, written into `out` (shared so the incremental
# TerrainChunkBuilder can fill the tarmac-weight array a row per frame).
func _surface_uv2_row(coord: Vector2i, zi: int, out: PackedVector2Array) -> void:
	var per_edge := SAMPLES - 1
	for xi in SAMPLES:
		_vertex_cells(coord.x * per_edge + xi, coord.y * per_edge + zi)
		# The four cells meeting at this vertex, averaged over only those that are
		# road/band cells (present in track_surface). Explicit lookups against the
		# _vc* scratch keys — NOT a `for cell in [...]` literal, which would allocate
		# an Array + 4 Vector2i per vertex (~800k allocations across the corridor).
		var sum := 0.0
		var n := 0
		if track_surface.has(_vc0):
			sum += track_surface[_vc0]; n += 1
		if track_surface.has(_vc1):
			sum += track_surface[_vc1]; n += 1
		if track_surface.has(_vc2):
			sum += track_surface[_vc2]; n += 1
		if track_surface.has(_vc3):
			sum += track_surface[_vc3]; n += 1
		var tarmac := sum / float(n) if n > 0 else 0.0
		out[zi * SAMPLES + xi] = Vector2(tarmac, 0.0)


# The surface at a world XZ as (road_weight, tarmac_weight), each in [0,1]:
#   road_weight   — 0 = bare grass (off the road), 1 = full road, ramped across
#                   the perpendicular grass↔road feather band.
#   tarmac_weight — 0 = gravel, 1 = tarmac, ramped across the lengthwise switch.
# Off any track both are 0 (grass / gravel defaults). Pure (no Config), so this
# @tool script stays editor-safe; the drivetrain turns it into a grip multiplier
# (Drivetrain.surface_grip) using the configured per-surface μ scales.
func surface_at(x: float, z: float) -> Vector2:
	var cell := Vector2i(floori(x / CELL_M), floori(z / CELL_M))
	return Vector2(track_weights.get(cell, 0.0), track_surface.get(cell, 0.0))


# Bake the static terrain shading for one vertex into a light tint. Mirrors the
# math in shaders/ps1_models_lit.gdshader (hemisphere ambient + one directional
# sun), but on the CPU at generation time using a normal taken from the noise
# height field via central differences — continuous across world coords, so it
# matches at chunk seams with no stitching. Returns white when light_amount is 0
# (a no-op multiply). The road-flattened heights are ignored for the normal: the
# road is near-flat anyway and sampling the pure field keeps seams consistent.
func _bake_light(noises: Array, amplitudes: PackedFloat32Array, wx: float, wz: float) -> Color:
	if light_amount <= 0.0:
		return Color(1, 1, 1)
	var hl := _sample_height(noises, amplitudes, wx - CELL_M, wz)
	var hr := _sample_height(noises, amplitudes, wx + CELL_M, wz)
	var hd := _sample_height(noises, amplitudes, wx, wz - CELL_M)
	var hu := _sample_height(noises, amplitudes, wx, wz + CELL_M)
	return _light_from_neighbours(hl, hr, hd, hu)


# The lighting core: turn the four 1-cell-spaced neighbour heights of a vertex
# into a baked light tint (hemisphere ambient + one directional sun). Split out
# of _bake_light so compute_chunk_data can feed it neighbours read from a shared
# pure-height halo (no per-vertex re-sampling) while light_at still samples them
# directly. White (a no-op) when light_amount is 0. The neighbours must be the
# PURE (pre-flatten) field for seam consistency — see _bake_light's note.
func _light_from_neighbours(hl: float, hr: float, hd: float, hu: float) -> Color:
	if light_amount <= 0.0:
		return Color(1, 1, 1)
	var n := Vector3(hl - hr, 2.0 * CELL_M, hd - hu).normalized()
	var hemi := n.y * 0.5 + 0.5
	var ambient := ground_color.lerp(sky_color, hemi)
	var ndl: float = maxf(n.dot(sun_dir), 0.0)
	var lit := Color(
		ambient.r + sun_color.r * ndl,
		ambient.g + sun_color.g * ndl,
		ambient.b + sun_color.b * ndl)
	return Color(1, 1, 1).lerp(lit, light_amount)


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


# Every chunk coord the runtime ring can request while the car stays within
# `leash_m` of the centerline (the off-track reset leash) — plus one chunk of
# margin for the physics tick between crossing the leash and the reset firing.
# The margin is derived from the LIVE leash value, never hard-coded: the
# invariant this region guarantees depends on that tunable. Straight spans
# tessellate to just their endpoints, so each polyline segment is sub-sampled
# at half a chunk so no interior chunk is skipped.
func corridor_coords(centerline: Curve2D, leash_m: float) -> Array[Vector2i]:
	var margin := RADIUS + int(ceil(leash_m / CHUNK_M)) + 1
	var seen: Dictionary = {}
	var out: Array[Vector2i] = []
	var poly := centerline.tessellate()
	for i in range(1, poly.size()):
		var a := poly[i - 1]
		var b := poly[i]
		var steps := int(ceil(a.distance_to(b) / (CHUNK_M / 2.0))) + 1
		for s in steps + 1:
			var t := float(s) / float(steps) if steps > 0 else 0.0
			var p := a.lerp(b, t)
			var c := chunk_coord_for(Vector3(p.x, 0.0, p.y))
			for dz in range(-margin, margin + 1):
				for dx in range(-margin, margin + 1):
					var cc := c + Vector2i(dx, dz)
					if not seen.has(cc):
						seen[cc] = true
						out.append(cc)
	return out


# Store the corridor and reset the cache; cache_chunk() fills it (world.gd
# batches the fills with frame awaits so the loading bar paints).
func set_corridor(coords: Array[Vector2i]) -> void:
	_corridor_coords = coords
	_chunk_cache.clear()


# The coords the current corridor covers (empty when no precompute has run).
func corridor() -> Array[Vector2i]:
	return _corridor_coords


# The per-level far-cutoff distances (metres). Read by TerrainChunk to configure
# each level MeshInstance's visibility_range band.
func lod_band_ends() -> PackedFloat32Array:
	return lod_band_ends_m


func cache_chunk(coord: Vector2i) -> void:
	var data := compute_chunk_data(coord)
	# Prebake the decimated LOD display meshes at load (behind the loading screen),
	# so runtime chunk spawns are a cheap node build + mesh assign, not a mesh build.
	data["lod_meshes"] = TerrainLod.build_all(data, lod_skirt_m)
	_chunk_cache[coord] = data


# Synchronous convenience: compute + cache the whole corridor in one call.
func precompute_corridor(centerline: Curve2D, leash_m: float) -> void:
	set_corridor(corridor_coords(centerline, leash_m))
	for coord in _corridor_coords:
		cache_chunk(coord)


# World-XZ AABB of the precomputed corridor (zero rect when no corridor is set).
# world.gd dilates this by the backdrop margin for the static DistantTerrain.
func corridor_bounds() -> Rect2:
	if _corridor_coords.is_empty():
		return Rect2()
	var lo := _corridor_coords[0]
	var hi := _corridor_coords[0]
	for c in _corridor_coords:
		lo = Vector2i(mini(lo.x, c.x), mini(lo.y, c.y))
		hi = Vector2i(maxi(hi.x, c.x), maxi(hi.y, c.y))
	return Rect2(lo.x * CHUNK_M, lo.y * CHUNK_M,
		(hi.x - lo.x + 1) * CHUNK_M, (hi.y - lo.y + 1) * CHUNK_M)


func has_cached(coord: Vector2i) -> bool:
	return _chunk_cache.has(coord)


# Total cached bytes across all chunks' packed arrays, in MB — logged at load so
# memory regressions are visible.
func cache_size_mb() -> float:
	var total := 0
	for data in _chunk_cache.values():
		for value in data.values():
			if value is PackedFloat32Array or value is PackedInt32Array:
				total += value.size() * 4
			elif value is PackedVector2Array:
				total += value.size() * 8
			elif value is PackedVector3Array:
				total += value.size() * 12
			elif value is PackedColorArray:
				total += value.size() * 16
	return total / 1.0e6


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


# Bake the weighted road + cliff fields from the centerline in ONE distance-field pass.
# The road flatten and the cliff offset are BOTH functions of a vertex's nearest point on
# the centerline, so we find that nearest point ONCE per band vertex (via a segment spatial
# hash + early-terminated ring search) and derive everything from it:
#   road_heights[v]  = noise height at the vertex's EXACT perpendicular foot on the centerline
#   road_blend[v]    = height blend weight (1 on road -> 0 at the outer transition edge)
#   track_weights[c] = colour blend weight per CELL (same ramp, at the cell centre)
#   track_surface[c] = tarmac weight per CELL at its nearest centerline arc-length
#   cliff_offsets[v] = signed cliff/drop offset (0 under the road + transition band)
# Because the height is taken at the TRUE nearest foot (not a discrete along-arc sample),
# the road cross-section is laterally flat regardless of tessellation density — there is no
# sampling-step knob to tune. All fields are keyed by GLOBAL grid index so adjacent chunks
# agree on shared edges with no stitching. `transition_m` is the band width OUTSIDE width/2.
func bake_track(centerline: Curve2D, width: float, transition_m: float, tarmac_fraction: float = 0.0, tarmac_first: bool = false, surface_feather_m: float = 6.0, should_yield: bool = false, on_progress: Callable = Callable()) -> void:
	road_heights = {}
	road_blend = {}
	track_weights = {}
	track_surface = {}
	cliff_offsets = {}
	var poly := centerline.tessellate()
	if poly.size() < 2:
		return

	# Band radii. Flatten: road half-width (inner, full weight) -> outer transition edge.
	# Cliff (if active): starts at the transition edge, rises over cliff_run to full ±1,
	# fades over cliff_fade back to natural grade. The search band covers whichever reaches
	# furthest so a single sweep feeds both.
	var f_inner := width / 2.0
	var f_outer := f_inner + transition_m
	var cliffs := _cliffs_active()
	var eff_max := (cliff_max_height_m * clampf(cliff_amount, 0.0, 1.0)) if cliffs else 0.0
	var c_inner := f_outer
	var c_rise := c_inner + cliff_run_m
	var c_outer := c_rise + cliff_fade_m
	var outer := maxf(f_outer, c_outer) if cliffs else f_outer
	var f_outer_sq := f_outer * f_outer
	var outer_sq := outer * outer

	# --- Segments: endpoint, delta, 1/len², arc length at start, unit tangent, total length
	# (the last for the gravel/tarmac split). Stored in the _cv_* scratch for _nearest_seg. ---
	var n_seg := poly.size() - 1
	_cv_ax = PackedFloat32Array(); _cv_ax.resize(n_seg)
	_cv_ay = PackedFloat32Array(); _cv_ay.resize(n_seg)
	_cv_dx = PackedFloat32Array(); _cv_dx.resize(n_seg)
	_cv_dy = PackedFloat32Array(); _cv_dy.resize(n_seg)
	_cv_inv = PackedFloat32Array(); _cv_inv.resize(n_seg)
	_cv_len = PackedFloat32Array(); _cv_len.resize(n_seg)
	_cv_tx = PackedFloat32Array(); _cv_tx.resize(n_seg)
	_cv_ty = PackedFloat32Array(); _cv_ty.resize(n_seg)
	_cv_arc = PackedFloat32Array(); _cv_arc.resize(n_seg)
	var total_m := 0.0
	for i in n_seg:
		var a := poly[i]
		var b := poly[i + 1]
		var dx := b.x - a.x
		var dy := b.y - a.y
		var l2 := dx * dx + dy * dy
		var l := sqrt(l2)
		_cv_ax[i] = a.x; _cv_ay[i] = a.y; _cv_dx[i] = dx; _cv_dy[i] = dy
		_cv_inv[i] = (1.0 / l2) if l2 > 0.0 else 0.0
		_cv_len[i] = l
		_cv_tx[i] = (dx / l) if l > 0.0 else 0.0
		_cv_ty[i] = (dy / l) if l > 0.0 else 0.0
		_cv_arc[i] = total_m
		total_m += l

	# --- Camber LUT (cliffs only). Camber is a smooth 1-D function of arc length
	# (wavelength ≫ a metre), so sample it once every camber_step and lerp per vertex. ---
	var camber_step := 0.5
	var camber_lut := PackedFloat32Array()
	var lut_n := 0
	if cliffs:
		var camber_noise := _make_camber_noise()
		lut_n = int(ceil(total_m / camber_step)) + 2
		camber_lut.resize(lut_n)
		for k in lut_n:
			camber_lut[k] = _camber(camber_noise, float(k) * camber_step)

	# --- Segment spatial hash: grid of CLIFF_GRID_M cells -> the segments crossing them.
	# A query only checks segments in the (2R+1)² block of cells around it. G is a whole
	# number of terrain cells so each grid cell holds an exact Gc×Gc block of vertices. ---
	var G := CLIFF_GRID_M
	var Gc := int(G / CELL_M)
	var R := int(ceil(outer / G))
	var min_gx := 0x7fffffff
	var min_gz := 0x7fffffff
	var max_gx := -0x7fffffff
	var max_gz := -0x7fffffff
	for pt in poly:
		var cgx := floori(pt.x / G)
		var cgz := floori(pt.y / G)
		min_gx = mini(min_gx, cgx); max_gx = maxi(max_gx, cgx)
		min_gz = mini(min_gz, cgz); max_gz = maxi(max_gz, cgz)
	_cv_gx0 = min_gx - R - 1
	_cv_gz0 = min_gz - R - 1
	_cv_gw = (max_gx - min_gx) + 2 * (R + 1) + 1
	_cv_gh = (max_gz - min_gz) + 2 * (R + 1) + 1
	_cv_G = G
	_cv_R = R
	var gw := _cv_gw
	var gh := _cv_gh
	_cv_grid = []
	_cv_grid.resize(gw * gh)
	var occupied := PackedInt32Array()
	for i in n_seg:
		var l := _cv_len[i]
		var walk_steps := maxi(1, int(ceil(l / (G * 0.5))))
		var last_cell := -1
		for w in walk_steps + 1:
			var tt := float(w) / float(walk_steps)
			var px := _cv_ax[i] + _cv_dx[i] * tt
			var pz := _cv_ay[i] + _cv_dy[i] * tt
			var cell := (floori(pz / G) - _cv_gz0) * gw + (floori(px / G) - _cv_gx0)
			if cell == last_cell:
				continue
			last_cell = cell
			var segs = _cv_grid[cell]
			if segs == null:
				segs = PackedInt32Array()
				occupied.append(cell)
			segs.append(i)
			_cv_grid[cell] = segs

	# --- Candidate cells: only cells within R of an occupied cell can hold band vertices. ---
	var vx0 := _cv_gx0 * Gc
	var vz0 := _cv_gz0 * Gc
	var vw := gw * Gc
	var vh := gh * Gc
	var cand := PackedByteArray()
	cand.resize(gw * gh)
	for oc in occupied:
		var ocx := oc % gw
		var ocz := oc / gw
		for rz in range(-R, R + 1):
			var cz := ocz + rz
			if cz < 0 or cz >= gh:
				continue
			for rx in range(-R, R + 1):
				var cxg := ocx + rx
				if cxg >= 0 and cxg < gw:
					cand[cz * gw + cxg] = 1
	var cand_total := 0
	for c in cand:
		cand_total += c
	var progress_stride := maxi(1, cand_total / 40)

	# --- Cliff offset field (flat, only allocated when cliffs are active) + its band bbox. ---
	var off := PackedFloat32Array()
	if cliffs:
		off.resize(vw * vh)
	var tvx0 := 0x7fffffff
	var tvx1 := -0x7fffffff
	var tvz0 := 0x7fffffff
	var tvz1 := -0x7fffffff

	# --- Vertex sweep: per candidate vertex, find the nearest centerline point ONCE, then
	# emit the flatten fields (road band) and the cliff offset (cliff band) from it. ---
	var cand_seen := 0
	for cgz in gh:
		for cgx in gw:
			if cand[cgz * gw + cgx] == 0:
				continue
			cand_seen += 1
			if cand_seen % progress_stride == 0:
				if on_progress.is_valid():
					on_progress.call(float(cand_seen) / maxf(float(cand_total), 1.0))
				if should_yield:
					await get_tree().process_frame
			# Seed each grid cell's search from -1; adjacent vertices reuse the winner.
			var seed_seg := -1
			for lz in Gc:
				var vz := cgz * Gc + lz
				var qz := float(vz0 + vz) * CELL_M
				for lx in Gc:
					var vx := cgx * Gc + lx
					var qx := float(vx0 + vx) * CELL_M
					var seg := _nearest_seg(qx, qz, seed_seg)
					if seg < 0 or _cv_best_dsq > outer_sq:
						continue
					seed_seg = seg
					var t := _cv_best_t
					var footx := _cv_ax[seg] + _cv_dx[seg] * t
					var footz := _cv_ay[seg] + _cv_dy[seg] * t
					var d := sqrt(_cv_best_dsq)
					# Flatten: pull road-band vertices to the noise height at their exact foot.
					if _cv_best_dsq < f_outer_sq:
						var gv := Vector2i(vx0 + vx, vz0 + vz)
						road_heights[gv] = _noise_height_at(footx, footz)
						road_blend[gv] = smooth_ramp(d, f_inner, f_outer)
					# Cliff offset: side · camber(arc) · profile(d) · eff_max.
					if cliffs:
						var s := _cv_arc[seg] + t * _cv_len[seg]
						var sc := s / camber_step
						var k0 := clampi(int(sc), 0, lut_n - 2)
						var camber := lerpf(camber_lut[k0], camber_lut[k0 + 1], sc - float(k0))
						var cross := _cv_tx[seg] * (qz - footz) - _cv_ty[seg] * (qx - footx)
						var val := signf(cross) * camber * _cliff_profile(d, c_inner, c_rise, c_outer) * eff_max
						if val != 0.0:
							off[vz * vw + vx] = val
							tvx0 = mini(tvx0, vx); tvx1 = maxi(tvx1, vx)
							tvz0 = mini(tvz0, vz); tvz1 = maxi(tvz1, vz)

	# --- Cell sweep: colour blend + tarmac weight per CELL (cells sit half a cell off the
	# vertex grid and drive the texture fade, keyed by global cell coord). Only cells that
	# TOUCH a flattened road vertex can fall in the road band, so we drive this off the
	# road_blend keys (a few thousand band vertices) and search each candidate cell centre
	# once — far cheaper than a second full ring-search sweep over every grid vertex. Each
	# vertex touches its 4 surrounding cells; `seen` dedups the overlap. ---
	var seen: Dictionary = {}
	for gv in road_blend:
		var vgx: int = gv.x
		var vgz: int = gv.y
		for cell in [
				Vector2i(vgx - 1, vgz - 1), Vector2i(vgx, vgz - 1),
				Vector2i(vgx - 1, vgz), Vector2i(vgx, vgz)]:
			if seen.has(cell):
				continue
			seen[cell] = true
			var qx := (float(cell.x) + 0.5) * CELL_M
			var qz := (float(cell.y) + 0.5) * CELL_M
			var seg := _nearest_seg(qx, qz, -1)
			if seg < 0 or _cv_best_dsq >= f_outer_sq:
				continue
			var t := _cv_best_t
			var d := sqrt(_cv_best_dsq)
			var s := _cv_arc[seg] + t * _cv_len[seg]
			track_weights[cell] = smooth_ramp(d, f_inner, f_outer)
			track_surface[cell] = TrackSurface.tarmac_weight(
				s, total_m, tarmac_fraction, tarmac_first, surface_feather_m)

	# --- Cliffs: knock down thin tall walls (morphological open over the band ribbon), then
	# emit the sparse offset dict in the shared GLOBAL vertex-index space. ---
	if cliffs and tvx1 >= tvx0:
		var r := int(round(cliff_open_radius_m / CELL_M))
		var ex0 := maxi(0, tvx0 - r)
		var ex1 := mini(vw - 1, tvx1 + r)
		var ez0 := maxi(0, tvz0 - r)
		var ez1 := mini(vh - 1, tvz1 + r)
		var sw := ex1 - ex0 + 1
		var sh := ez1 - ez0 + 1
		if r > 0:
			var sub := PackedFloat32Array()
			sub.resize(sw * sh)
			for z in sh:
				for x in sw:
					sub[z * sw + x] = off[(ez0 + z) * vw + (ex0 + x)]
			_open_thin_offsets(sub, sw, sh, cliff_open_radius_m)
			for z in sh:
				for x in sw:
					off[(ez0 + z) * vw + (ex0 + x)] = sub[z * sw + x]
		for z in range(ez0, ez1 + 1):
			var world_z := vz0 + z
			for x in range(ex0, ex1 + 1):
				var val := off[z * vw + x]
				if absf(val) > 0.0001:
					cliff_offsets[Vector2i(vx0 + x, world_z)] = val

	# Release the scratch (large packed arrays + the grid) — it's only valid during a bake.
	_cv_grid = []


# Nearest centerline segment to world point (qx, qz), via the _cv_* spatial hash: an
# early-terminated ring search over the (2R+1)² block of grid cells, culling any cell whose
# nearest point is already beyond the best distance. `seed_seg` (the previous query's winner,
# or -1) is projected first to tighten the initial bound — adjacent queries almost always
# share a nearest segment. Returns the segment index (-1 if none) and writes the clamped
# projection parameter + squared distance to _cv_best_t / _cv_best_dsq (out-params, so the
# 155k-call hot path allocates nothing). while-loops avoid per-ring range() allocations.
func _nearest_seg(qx: float, qz: float, seed_seg: int) -> int:
	var gw := _cv_gw
	var gh := _cv_gh
	var G := _cv_G
	var R := _cv_R
	var cgx := clampi(floori(qx / G) - _cv_gx0, 0, gw - 1)
	var cgz := clampi(floori(qz / G) - _cv_gz0, 0, gh - 1)
	var best_dsq := INF
	var best_seg := -1
	var best_t := 0.0
	if seed_seg >= 0:
		var swx := qx - _cv_ax[seed_seg]
		var swz := qz - _cv_ay[seed_seg]
		var st := clampf((swx * _cv_dx[seed_seg] + swz * _cv_dy[seed_seg]) * _cv_inv[seed_seg], 0.0, 1.0)
		var sex := swx - _cv_dx[seed_seg] * st
		var sez := swz - _cv_dy[seed_seg] * st
		best_dsq = sex * sex + sez * sez
		best_seg = seed_seg
		best_t = st
	var ring := 0
	while ring <= R:
		var lo_z := cgz - ring
		var hi_z := cgz + ring
		var lo_x := cgx - ring
		var hi_x := cgx + ring
		var zhi := mini(gh - 1, hi_z)
		var xhi := mini(gw - 1, hi_x)
		var ccz := maxi(0, lo_z)
		while ccz <= zhi:
			var edge_row := ccz == lo_z or ccz == hi_z
			var ccx := maxi(0, lo_x)
			while ccx <= xhi:
				if edge_row or ccx == lo_x or ccx == hi_x:
					var segs = _cv_grid[ccz * gw + ccx]
					if segs != null:
						var cwx0 := float(_cv_gx0 + ccx) * G
						var cwz0 := float(_cv_gz0 + ccz) * G
						var ddx := maxf(0.0, maxf(cwx0 - qx, qx - cwx0 - G))
						var ddz := maxf(0.0, maxf(cwz0 - qz, qz - cwz0 - G))
						if ddx * ddx + ddz * ddz < best_dsq:
							for si in segs:
								var wx := qx - _cv_ax[si]
								var wz := qz - _cv_ay[si]
								var tproj := clampf((wx * _cv_dx[si] + wz * _cv_dy[si]) * _cv_inv[si], 0.0, 1.0)
								var ex := wx - _cv_dx[si] * tproj
								var ez := wz - _cv_dy[si] * tproj
								var dsq := ex * ex + ez * ez
								if dsq < best_dsq:
									best_dsq = dsq
									best_seg = si
									best_t = tproj
				ccx += 1
			ccz += 1
		if best_seg >= 0 and best_dsq <= float(ring * G) * float(ring * G):
			break
		ring += 1
	_cv_best_t = best_t
	_cv_best_dsq = best_dsq
	return best_seg


# The camber signal's FastNoiseLite: a 1-D value along the track's arc length,
# analogous to TrackSurface.tarmac_weight being a pure function of distance. Seeded
# off track_seed so the whole stage is deterministic.
func _make_camber_noise() -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.fractal_type = FastNoiseLite.FRACTAL_NONE
	noise.seed = cliff_seed ^ CLIFF_SEED_SALT
	noise.frequency = 1.0 / maxf(cliff_wavelength_m, 0.001)
	return noise


# The camber value in [-1, 1] at arc length `s`: raw 1-D noise scaled by cliff_gain
# then clamped. Higher gain → the signal spends more time saturated at ±1 (frequent
# full-height cliffs); the clamp makes ±1 a hard ceiling. Carries the sign, so as it
# slides through 0 a left-cliff/right-drop becomes level becomes a right-cliff.
func _camber(noise: FastNoiseLite, s: float) -> float:
	return clampf(noise.get_noise_1d(s) * cliff_gain, -1.0, 1.0)


# The cross-section shape as a function of perpendicular distance |d| from the
# centerline: 0 under the road AND across the full feathered transition band (so the
# shoulder isn't tilted and the cliff only begins where the road has met the grass),
# rising 0→1 over cliff_run_m, then falling 1→0 over cliff_fade_m back to natural grade
# (a localized berm/ditch, not an infinite shelf). 0 again past the influence radius R.
static func _cliff_profile(d: float, inner: float, rise: float, outer: float) -> float:
	if d <= inner or d >= outer:
		return 0.0
	if d < rise:
		return smoothstep(inner, rise, d)
	return 1.0 - smoothstep(rise, outer, d)


# Whether the cliff pass will actually stamp offsets (used by bake_track to decide
# whether the flatten pass owns the whole carve bar or just its first half).
func _cliffs_active() -> bool:
	return cliff_enabled and cliff_max_height_m * clampf(cliff_amount, 0.0, 1.0) > 0.0


# Morphological grayscale OPENING (erosion then dilation) on the signed offset field,
# applied to |offset| with the sign restored, using a square structuring element of
# radius `radius_m`. Opening is anti-extensive (never raises |offset|, never creates an
# offset where there was none), so it only knocks DOWN features narrower than 2·radius
# in either axis — the thin walls a hairpin crook would otherwise leave — while wide
# cliffs and drops are preserved. Acting on the magnitude keeps walls and drops
# symmetric. A separable square element makes each pass a pair of 1-D min/max sweeps.
func _open_thin_offsets(off: PackedFloat32Array, w: int, h: int, radius_m: float) -> void:
	var r := int(round(radius_m / CELL_M))
	if r <= 0 or off.is_empty():
		return
	var mag := PackedFloat32Array()
	mag.resize(off.size())
	for i in off.size():
		mag[i] = absf(off[i])
	var eroded := _sep_window(mag, w, h, r, true)    # erosion = window minimum
	var opened := _sep_window(eroded, w, h, r, false) # dilation = window maximum
	for i in off.size():
		off[i] = signf(off[i]) * opened[i]


# Separable 1-D min (is_min) / max sliding-window over a w×h grid, horizontal then
# vertical, window half-width r. Edges clamp to the valid range (the band never reaches
# the padded border, so clamping only ever touches zeros).
func _sep_window(src: PackedFloat32Array, w: int, h: int, r: int, is_min: bool) -> PackedFloat32Array:
	var tmp := PackedFloat32Array()
	tmp.resize(src.size())
	for y in h:
		var base := y * w
		for x in w:
			var acc := src[base + x]
			for k in range(maxi(0, x - r), mini(w - 1, x + r) + 1):
				var v := src[base + k]
				acc = minf(acc, v) if is_min else maxf(acc, v)
			tmp[base + x] = acc
	var out := PackedFloat32Array()
	out.resize(src.size())
	for x in w:
		for y in h:
			var acc := tmp[y * w + x]
			for k in range(maxi(0, y - r), mini(h - 1, y + r) + 1):
				var v := tmp[k * w + x]
				acc = minf(acc, v) if is_min else maxf(acc, v)
			out[y * w + x] = acc
	return out


# Apply a track: bake the weighted height + road-blend fields from the centerline,
# then rebuild any currently-loaded chunks (mesh + collision) so the texture fade
# takes effect. At startup the ring is deferred (see build_initial), so _chunks is
# empty here and nothing rebuilds; chunks loaded later read the baked fields in
# compute_chunk_data / vertex_colors at build time.
# `should_yield` (true only on the interactive staged load, never headless) makes the
# heavy bake release the main thread periodically so the loading overlay keeps painting
# instead of freezing. It never changes the baked RESULT — only the pacing — but because
# the bake then contains `await`, set_track/bake_track are always coroutines: call them
# with `await` (with should_yield=false they never actually suspend, completing same-frame).
func set_track(centerline: Curve2D, width: float, transition_m: float, tarmac_fraction: float = 0.0, tarmac_first: bool = false, surface_feather_m: float = 6.0, should_yield: bool = false, on_progress: Callable = Callable()) -> void:
	await bake_track(centerline, width, transition_m, tarmac_fraction, tarmac_first, surface_feather_m, should_yield, on_progress)
	for coord in _chunks:
		_chunks[coord].setup(self, coord)


func _ready() -> void:
	if layers.is_empty():
		layers = _default_layers()
	else:
		_connect_layer_signals()
	# Build the initial ring now unless a parent will drive it (defer). The editor
	# always previews, so it builds regardless of the flag.
	if Engine.is_editor_hint() or not defer_initial_build:
		build_initial()


# Build the initial 3x3 ring synchronously around the focus (the car), so there
# is always ground under the car at spawn.
func build_initial() -> void:
	var focus := _focus_node()
	var origin: Vector3 = focus.global_position if focus != null else Vector3.ZERO
	_reconcile(chunk_coord_for(origin))
	_last_focus_coord = chunk_coord_for(origin)


func _process(delta: float) -> void:
	var __t := Time.get_ticks_usec()
	_timed_process(delta)
	PerfLog.track(&"terrain_manager", Time.get_ticks_usec() - __t)


func _timed_process(_delta: float) -> void:
	# H (`toggle_debug_arrows`, the shared debug key) toggles the chunk-border
	# overlay in debug builds — lazily created so release/editor pay nothing.
	if OS.is_debug_build() and not Engine.is_editor_hint() \
			and Input.is_action_just_pressed("toggle_debug_arrows"):
		_toggle_chunk_borders()
	var focus := _focus_node()
	if focus != null:
		update_focus(focus.global_position)


# Create-on-first-use, then flip visibility; rebuild when turning on.
func _toggle_chunk_borders() -> void:
	if _border_debug == null:
		_border_debug = ChunkBorderDebug.new()
		_border_debug.name = "ChunkBorderDebug"
		add_child(_border_debug)
	_border_debug.visible = not _border_debug.visible
	_border_debug.rebuild(self, _chunks.keys(), _last_focus_coord)


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


func _reconcile(center: Vector2i) -> void:
	var wanted := target_coords(center)
	for coord in _chunks.keys():
		if not wanted.has(coord):
			_chunks[coord].queue_free()
			_chunks.erase(coord)
	for coord in wanted:
		if _chunks.has(coord):
			continue
		if _chunk_cache.has(coord):
			_spawn_chunk(coord, _chunk_cache[coord])
		elif _chunk_cache.is_empty():
			# Editor / tests / pre-precompute: silent on-demand build.
			_spawn_chunk(coord, compute_chunk_data(coord))
		else:
			push_error("terrain cache miss at %s — corridor region/leash invariant broke" % coord)
			_spawn_chunk(coord, compute_chunk_data(coord))
	# Collision only on the near band: chunks within `collision_ring` of the focus
	# carry live collision, farther loaded (render-only) chunks disable theirs.
	for coord in _chunks:
		var d := maxi(absi(coord.x - center.x), absi(coord.y - center.y))
		_chunks[coord].set_collision_enabled(d <= collision_ring)
	# Keep the debug overlay in sync when the loaded set changes (crossing).
	if _border_debug != null and _border_debug.visible:
		_border_debug.rebuild(self, _chunks.keys(), center)


func _spawn_chunk(coord: Vector2i, data: Dictionary) -> void:
	var chunk: TerrainChunk = ChunkScript.new()
	add_child(chunk)
	chunk.apply_data(self, coord, data)
	_chunks[coord] = chunk
	integrations_total += 1


func _rebuild_loaded() -> void:
	_noise_cache_valid = false  # seed / layers / wavelength changed
	# Stale cached arrays must never survive a terrain-param change; refill for
	# the stored corridor (dev-time synchronous hitch is fine — this only fires
	# from the inspector / tests).
	_chunk_cache.clear()
	for coord in _corridor_coords:
		cache_chunk(coord)
	for chunk in _chunks.values():
		chunk.setup(self, chunk.coord)
