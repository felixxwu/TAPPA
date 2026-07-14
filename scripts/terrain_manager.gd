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
const ROAD_SAMPLE_STEP_M := 0.25        # centerline sampling density for bake_road
# Cliffs & drops (features/terrain.md). The cliff pass walks the centerline coarser
# than the road (camber varies over cliff_wavelength_m ≫ a cell, and the stamp band
# is ~10-20× wider), so the sample density is the main cost lever.
const CLIFF_SAMPLE_STEP_M := 1.0
# Bearing buckets for the hairpin wrap test. Circular set-union of the vertex→sample
# bearings; the wrap span = 360° − largest empty arc. More buckets → finer span, so a
# straight (true span < 180°) never rounds up past 180° and false-fires contested.
const CLIFF_BEARING_BUCKETS := 48
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
var cliff_pinch_angle_deg: float = 45.0
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


# Bilinear height from the cached chunk grid; NAN when the point isn't covered.
func _cached_height_at(x: float, z: float) -> float:
	if _chunk_cache.is_empty():
		return NAN
	var coord := chunk_coord_for(Vector3(x, 0.0, z))
	if not _chunk_cache.has(coord):
		return NAN
	var heights: PackedFloat32Array = _chunk_cache[coord]["heights"]
	var lx := (x - coord.x * CHUNK_M) / CELL_M
	var lz := (z - coord.y * CHUNK_M) / CELL_M
	var xi := clampi(floori(lx), 0, SAMPLES - 2)
	var zi := clampi(floori(lz), 0, SAMPLES - 2)
	var fx := clampf(lx - xi, 0.0, 1.0)
	var fz := clampf(lz - zi, 0.0, 1.0)
	var a := heights[zi * SAMPLES + xi]
	var b := heights[zi * SAMPLES + xi + 1]
	var c := heights[(zi + 1) * SAMPLES + xi]
	var d := heights[(zi + 1) * SAMPLES + xi + 1]
	return lerpf(lerpf(a, b, fx), lerpf(c, d, fx), fz)


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
	if _chunk_cache.is_empty():
		return Color(0, 0, 0, -1.0)
	var coord := chunk_coord_for(Vector3(x, 0.0, z))
	if not _chunk_cache.has(coord):
		return Color(0, 0, 0, -1.0)
	var lights: PackedColorArray = _chunk_cache[coord].get("lights", PackedColorArray())
	if lights.is_empty():
		return Color(0, 0, 0, -1.0)
	var lx := (x - coord.x * CHUNK_M) / CELL_M
	var lz := (z - coord.y * CHUNK_M) / CELL_M
	var xi := clampi(floori(lx), 0, SAMPLES - 2)
	var zi := clampi(floori(lz), 0, SAMPLES - 2)
	var fx := clampf(lx - xi, 0.0, 1.0)
	var fz := clampf(lz - zi, 0.0, 1.0)
	var a := lights[zi * SAMPLES + xi]
	var b := lights[zi * SAMPLES + xi + 1]
	var c := lights[(zi + 1) * SAMPLES + xi]
	var d := lights[(zi + 1) * SAMPLES + xi + 1]
	var out := a.lerp(b, fx).lerp(c.lerp(d, fx), fz)
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


# One row of vertex_colors, written into `out` (shared so the incremental
# TerrainChunkBuilder can fill the colour array a row per frame).
func _vertex_color_row(coord: Vector2i, zi: int, lights: PackedColorArray, out: PackedColorArray) -> void:
	var per_edge := SAMPLES - 1
	var has_light := not lights.is_empty()
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
		var gx := coord.x * per_edge + xi
		var gz := coord.y * per_edge + zi
		var sum := 0.0
		var n := 0
		for cell in [
			Vector2i(gx - 1, gz - 1), Vector2i(gx, gz - 1),
			Vector2i(gx - 1, gz), Vector2i(gx, gz),
		]:
			if track_surface.has(cell):
				sum += track_surface[cell]
				n += 1
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


# Sample the terrain densely along the 2D centerline (x -> world x, y -> world z)
# and build the weighted road fields:
#   road_heights[v]  = nearest centerline sample's terrain height (per grid vertex)
#   road_blend[v]    = height blend weight (1 on road -> 0 at outer band edge)
#   track_weights[c] = colour blend weight per cell (same ramp, by cell centre)
# `transition_m` is the band width OUTSIDE width/2. Straight spans tessellate to
# just their endpoints, so each segment is sub-sampled at ROAD_SAMPLE_STEP_M.
func bake_track(centerline: Curve2D, width: float, transition_m: float, tarmac_fraction: float = 0.0, tarmac_first: bool = false, surface_feather_m: float = 6.0, should_yield: bool = false, on_progress: Callable = Callable()) -> void:
	var rh: Dictionary = {}
	var rb: Dictionary = {}
	var tw: Dictionary = {}
	var ts: Dictionary = {}        # cell -> tarmac weight at its nearest centerline point
	var v_best: Dictionary = {}  # vertex -> nearest distance so far
	var c_best: Dictionary = {}  # cell -> nearest distance so far
	var inner := width / 2.0
	var outer := inner + transition_m
	var reach := int(ceil(outer / CELL_M)) + 1
	var poly := centerline.tessellate()
	# Total polyline length, so each sample's cumulative distance maps to a fraction
	# along the track for the gravel/tarmac split. Summed from the same tessellation
	# the samples walk, so the switch lands where TrackSurface expects.
	var total_m := 0.0
	for i in range(1, poly.size()):
		total_m += poly[i - 1].distance_to(poly[i])
	var dist_m := 0.0  # cumulative distance to the start of the current segment
	# Release the main thread ~40 times across the walk (only when should_yield) so the
	# loading overlay repaints during this multi-second bake instead of freezing.
	var yield_stride := maxi(1, (poly.size() - 1) / 40)
	var denom := maxf(float(poly.size() - 1), 1.0)
	# Carve progress spans BOTH bake passes: the flatten walk fills the first half
	# (0 -> 0.5) when a cliff pass will follow, else the whole bar (0 -> 1); _bake_cliffs
	# fills 0.5 -> 1. So the preview line keeps advancing through the cliff pass instead
	# of sitting full-white while it runs.
	var flatten_ceiling := 0.5 if _cliffs_active() else 1.0
	for i in range(1, poly.size()):
		if i % yield_stride == 0:
			# Report carve progress (fraction of the centerline flattened so far) and,
			# on the interactive path, release the main thread so the overlay repaints.
			if on_progress.is_valid():
				on_progress.call(float(i) / denom * flatten_ceiling)
			if should_yield:
				await get_tree().process_frame
		var a := poly[i - 1]
		var b := poly[i]
		var seg_len := a.distance_to(b)
		var steps := int(ceil(seg_len / ROAD_SAMPLE_STEP_M)) + 1
		for s in steps + 1:
			var t := float(s) / float(steps) if steps > 0 else 0.0
			var p := a.lerp(b, t)
			var y := _noise_height_at(p.x, p.y)
			# Tarmac-ness at this point's distance along the track (feathered switch).
			var tarmac := TrackSurface.tarmac_weight(
				dist_m + t * seg_len, total_m, tarmac_fraction, tarmac_first, surface_feather_m)
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
					# Cell (centre) -> colour + surface fields (same nearest sample).
					var c := Vector2i(cbx + dx, cbz + dz)
					var dc := Vector2((c.x + 0.5) * CELL_M, (c.y + 0.5) * CELL_M).distance_to(p)
					var wc := smooth_ramp(dc, inner, outer)
					if wc > 0.0 and (not c_best.has(c) or dc < c_best[c]):
						c_best[c] = dc
						tw[c] = wc
						ts[c] = tarmac
		dist_m += seg_len
	road_heights = rh
	road_blend = rb
	track_weights = tw
	track_surface = ts
	await _bake_cliffs(centerline, width, transition_m, should_yield, on_progress)


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


# The hairpin-crook flatten weight in [0, 1] from the vertex's bearing wrap span: 0
# while the road stays within a half-plane (span ≤ 180° — straights and the OUTSIDE
# of bends keep their cliff), ramping to 1 over cliff_pinch_angle_deg as the road wraps
# further around the vertex (inside crook / loop-back → flatten). Feathered so the
# taper to flat is continuous (a boolean would trade the wedge seam for a step seam).
func _contested_from_span(span_deg: float) -> float:
	if cliff_pinch_angle_deg <= 0.0:
		return 1.0 if span_deg > 180.0 else 0.0
	return clampf((span_deg - 180.0) / cliff_pinch_angle_deg, 0.0, 1.0)


# Circular bearing span in degrees from a bitmask of occupied buckets: 360° − the
# largest run of consecutive EMPTY buckets (the biggest gap the road leaves around the
# vertex). Order-independent (set union) and wrap-safe (unlike min/max of the angle).
static func _bucket_span_deg(mask: int) -> float:
	if mask == 0:
		return 0.0
	var max_empty := 0
	var cur := 0
	# Walk twice around the circle so a gap straddling bucket 0 is measured whole.
	for i in CLIFF_BEARING_BUCKETS * 2:
		if mask & (1 << (i % CLIFF_BEARING_BUCKETS)) == 0:
			cur += 1
			max_empty = maxi(max_empty, cur)
		else:
			cur = 0
	# mask is non-empty, so at least one bucket is occupied and the empty run can never
	# reach CLIFF_BEARING_BUCKETS (a full mask gives max_empty 0 → 360°) — no clamp needed.
	return float(CLIFF_BEARING_BUCKETS - max_empty) * (360.0 / CLIFF_BEARING_BUCKETS)


# Bake the signed cliff offset per vertex over a band ~R wide either side of the road.
# One coarse centerline walk (CLIFF_SAMPLE_STEP_M): at each sample compute the camber,
# and per stamped vertex keep the NEAREST sample's side·camber·profile plus a set of
# occupied bearing buckets. After the walk, fold the wrap span into the contested
# flatten and scale by the effective max height. Cleared + skipped when disabled or 0.
# Whether the cliff pass will actually stamp offsets (used by bake_track to decide
# whether the flatten pass owns the whole carve bar or just its first half).
func _cliffs_active() -> bool:
	return cliff_enabled and cliff_max_height_m * clampf(cliff_amount, 0.0, 1.0) > 0.0


func _bake_cliffs(centerline: Curve2D, width: float, transition_m: float, should_yield: bool = false, on_progress: Callable = Callable()) -> void:
	cliff_offsets = {}
	if not cliff_enabled:
		return
	var eff_max := cliff_max_height_m * clampf(cliff_amount, 0.0, 1.0)
	if eff_max <= 0.0:
		return
	var inner := width / 2.0 + transition_m   # cliff starts at the outer band edge
	var rise := inner + cliff_run_m           # full ±1 here
	var outer := rise + cliff_fade_m          # back to 0 here = influence radius R
	var outer_sq := outer * outer             # reject the box corners without a sqrt
	var reach := int(ceil(outer / CELL_M)) + 1
	var camber_noise := _make_camber_noise()

	var v_best: Dictionary = {}   # vertex -> nearest sample distance so far
	var base: Dictionary = {}     # vertex -> side·camber·profile at the nearest sample
	var buckets: Dictionary = {}  # vertex -> bitmask of occupied bearing buckets
	var bucket_span := TAU / float(CLIFF_BEARING_BUCKETS)

	var poly := centerline.tessellate()
	var dist_m := 0.0
	var yield_stride := maxi(1, (poly.size() - 1) / 40)
	var denom := maxf(float(poly.size() - 1), 1.0)
	for i in range(1, poly.size()):
		if i % yield_stride == 0:
			# Second half of the carve bar (0.5 -> 1): the cliff pass continues the
			# progress the flatten pass left at 0.5.
			if on_progress.is_valid():
				on_progress.call(0.5 + float(i) / denom * 0.5)
			if should_yield:
				await get_tree().process_frame
		var a := poly[i - 1]
		var b := poly[i]
		var seg_len := a.distance_to(b)
		if seg_len <= 0.0:
			continue
		var tangent := (b - a) / seg_len
		var steps := maxi(int(ceil(seg_len / CLIFF_SAMPLE_STEP_M)), 1)
		for sidx in steps + 1:
			var t := float(sidx) / float(steps)
			var p := a.lerp(b, t)
			var camber := _camber(camber_noise, dist_m + t * seg_len)
			var vbx := roundi(p.x / CELL_M)
			var vbz := roundi(p.y / CELL_M)
			for dz in range(-reach, reach + 1):
				for dx in range(-reach, reach + 1):
					var v := Vector2i(vbx + dx, vbz + dz)
					var off := Vector2(v.x * CELL_M, v.y * CELL_M) - p
					if off.length_squared() > outer_sq:   # corner reject before the sqrt
						continue
					var dv := off.length()
					# Bearing bucket for the wrap test (vertex → sample direction).
					if dv > 0.0001:
						var ang := atan2(-off.y, -off.x) + PI   # 0..TAU
						var bit := int(ang / bucket_span) % CLIFF_BEARING_BUCKETS
						buckets[v] = int(buckets.get(v, 0)) | (1 << bit)
					if not v_best.has(v) or dv < v_best[v]:
						v_best[v] = dv
						# side = sign of the tangent × offset cross product.
						var cross := tangent.x * off.y - tangent.y * off.x
						base[v] = signf(cross) * camber * _cliff_profile(dv, inner, rise, outer)
		dist_m += seg_len

	for v in base.keys():
		var span := _bucket_span_deg(int(buckets.get(v, 0)))
		var val: float = base[v] * (1.0 - _contested_from_span(span)) * eff_max
		if absf(val) > 0.0001:
			cliff_offsets[v] = val


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
