class_name TerrainChunkBuilder
extends RefCounted

# Resumable builder for ONE terrain chunk's data: the same work as the body of
# TerrainManager.compute_chunk_data, but advanced a few grid ROWS at a time so the
# single-threaded web export can spread a chunk's CPU cost across frames instead of
# stalling on the whole chunk in one tick (which, on a phone, overruns a frame on
# its own even at one chunk per frame). Run to completion in a single call it is
# byte-identical to the old monolithic compute — compute_chunk_data does exactly
# that, so the worker-thread, synchronous and editor paths are unchanged; only the
# budgeted web pump steps it incrementally across frames.
#
# Each builder is a LOCAL instance owned by its caller and never shared, so the
# threaded path's concurrent compute_chunk_data calls don't race on shared state.
# It only ever READS TerrainManager fields that are static after the track bake
# (noise params, road/surface fields, light params) — exactly what compute_chunk_data
# has always read off a worker thread.

# Phases walked in order; each spans a number of grid rows. HALO samples the PURE
# height field over a 1-cell border (lit only — see TerrainManager.compute_chunk_data);
# VERTS builds the mesh vertices/uvs/heights/light; COLORS and UV2 bake the per-vertex
# road-blend and gravel/tarmac weights. Then DONE.
enum { PH_HALO, PH_VERTS, PH_COLORS, PH_UV2, PH_DONE }

var coord: Vector2i
var complete := false

var _m: TerrainManager
var _samples: int
var _cell_m: float
var _center: Vector3
var _half: float
var _tile: float
var _noises: Array
var _amplitudes: PackedFloat32Array
var _lit: bool
var _hs: int                          # halo edge length = SAMPLES + 2
var _count: int
var _heights: PackedFloat32Array
var _vertices: PackedVector3Array
var _uvs: PackedVector2Array
var _lights: PackedColorArray         # empty when unlit (vertex_colors treats as white)
var _colors: PackedColorArray
var _uv2s: PackedVector2Array
var _ph: PackedFloat32Array           # pure-height halo (lit only)
var _phase: int = PH_HALO
var _row: int = 0


func _init(manager: TerrainManager, chunk_coord: Vector2i) -> void:
	_m = manager
	coord = chunk_coord
	_samples = TerrainManager.SAMPLES
	_cell_m = TerrainManager.CELL_M
	var chunk_m: float = TerrainManager.CHUNK_M
	_center = Vector3((coord.x + 0.5) * chunk_m, 0.0, (coord.y + 0.5) * chunk_m)
	_half = chunk_m / 2.0
	_tile = manager.texture_tile_per_meter
	var pair := manager._build_noises()
	_noises = pair[0]
	_amplitudes = pair[1]
	_lit = manager.light_amount > 0.0
	_hs = _samples + 2
	_count = _samples * _samples
	_heights = PackedFloat32Array(); _heights.resize(_count)
	_vertices = PackedVector3Array(); _vertices.resize(_count)
	_uvs = PackedVector2Array(); _uvs.resize(_count)
	_colors = PackedColorArray(); _colors.resize(_count)
	_uv2s = PackedVector2Array(); _uv2s.resize(_count)
	_lights = PackedColorArray()
	if _lit:
		_lights.resize(_count)
		_ph = PackedFloat32Array(); _ph.resize(_hs * _hs)
	else:
		_phase = PH_VERTS  # no halo to sample when lighting is off


# Advance up to `max_rows` grid rows of work; returns how many rows were actually
# processed (0 once complete). Sets `complete` when the final phase finishes.
func step(max_rows: int) -> int:
	var budget := max_rows
	while budget > 0 and _phase != PH_DONE:
		match _phase:
			PH_HALO:
				_halo_row(_row)
			PH_VERTS:
				_vertex_row(_row)
			PH_COLORS:
				_m._vertex_color_row(coord, _row, _lights, _colors)
			PH_UV2:
				_m._surface_uv2_row(coord, _row, _uv2s)
		_row += 1
		budget -= 1
		var rows_in_phase := _hs if _phase == PH_HALO else _samples
		if _row >= rows_in_phase:
			_row = 0
			_phase += 1
	if _phase == PH_DONE:
		complete = true
	return max_rows - budget


# Run every remaining row in one go (the synchronous / worker / editor path).
func run_to_completion() -> void:
	while not complete:
		step(_count)  # _count >> the row total, so this finishes in one pass


# The finished chunk arrays, in the shape TerrainChunk.apply_data expects. Indices
# are pure arithmetic, so they're built here once at the end rather than sliced.
func data() -> Dictionary:
	var per_edge := _samples - 1
	var indices := PackedInt32Array(); indices.resize(per_edge * per_edge * 6)
	var ii := 0
	for zi in per_edge:
		for xi in per_edge:
			var a := zi * _samples + xi
			var b := a + 1
			var c := a + _samples
			var d := c + 1
			# Clockwise winding a,b,c / b,d,c (matches the mesh in compute_chunk_data).
			indices[ii + 0] = a; indices[ii + 1] = b; indices[ii + 2] = c
			indices[ii + 3] = b; indices[ii + 4] = d; indices[ii + 5] = c
			ii += 6
	return {
		"center": _center,
		"heights": _heights,
		"vertices": _vertices,
		"uvs": _uvs,
		"colors": _colors,
		"uv2s": _uv2s,
		"indices": indices,
	}


func _halo_row(hzi: int) -> void:
	var pz := _center.z - _half + (hzi - 1) * _cell_m
	var base := hzi * _hs
	for hxi in _hs:
		var px := _center.x - _half + (hxi - 1) * _cell_m
		_ph[base + hxi] = TerrainManager._sample_height(_noises, _amplitudes, px, pz)


func _vertex_row(zi: int) -> void:
	var per_edge := _samples - 1
	var lz := -_half + zi * _cell_m
	var wz := _center.z + lz
	for xi in _samples:
		var lx := -_half + xi * _cell_m
		var wx := _center.x + lx
		var idx := zi * _samples + xi
		var h: float
		if _lit:
			# Centre of this vertex in the halo (offset by 1 for the border); its four
			# ±1-cell neighbours are ±1 (x) and ±_hs (z) — the same world coords the
			# per-vertex light bake used, so the output is bit-identical.
			var c := (zi + 1) * _hs + (xi + 1)
			h = _ph[c]
			_lights[idx] = _m._light_from_neighbours(_ph[c - 1], _ph[c + 1], _ph[c - _hs], _ph[c + _hs])
		else:
			h = TerrainManager._sample_height(_noises, _amplitudes, wx, wz)
		# Blend road vertices toward the baked road height by their weight.
		var vidx := Vector2i(coord.x * per_edge + xi, coord.y * per_edge + zi)
		if _m.road_blend.has(vidx):
			h = lerpf(h, _m.road_heights[vidx], _m.road_blend[vidx])
		_heights[idx] = h
		_vertices[idx] = Vector3(lx, h, lz)
		_uvs[idx] = Vector2(wx, wz) * _tile
