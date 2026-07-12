class_name TerrainChunkBuilder
extends RefCounted

# Builds ONE terrain chunk's data: heights, mesh arrays, per-vertex colours and
# tarmac weights, and (when lit) baked light. Kept out of TerrainManager for size;
# it only ever READS TerrainManager fields that are static after the track bake
# (noise params, road/surface fields, light params).
#
# Each builder is a LOCAL instance owned by its caller and never shared.

var coord: Vector2i

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
var _has_cliffs: bool                 # cheap gate: skip cliff lookups when none baked
var _cliff_offsets: Dictionary        # captured once (avoids a per-vertex property deref)


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
	_cliff_offsets = manager.cliff_offsets
	_has_cliffs = not _cliff_offsets.is_empty()
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


# Run every phase in order: halo rows (lit only), vertex rows, colour rows, uv2 rows.
func build() -> void:
	if _lit:
		for hzi in _hs:
			_halo_row(hzi)
	for zi in _samples:
		_vertex_row(zi)
	for zi in _samples:
		_m._vertex_color_row(coord, zi, _lights, _colors)
	for zi in _samples:
		_m._surface_uv2_row(coord, zi, _uv2s)


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
		"lights": _lights,   # per-vertex baked light (empty when unlit) — served by light_at
	}


func _halo_row(hzi: int) -> void:
	var per_edge := _samples - 1
	var gz := coord.y * per_edge + (hzi - 1)
	var pz := _center.z - _half + (hzi - 1) * _cell_m
	var base := hzi * _hs
	for hxi in _hs:
		var gx := coord.x * per_edge + (hxi - 1)
		var px := _center.x - _half + (hxi - 1) * _cell_m
		# noise + cliff offset (NOT the road flatten): the light normal must include
		# the cliff so steep cliffs shade as cliffs, while the near-flat road stays
		# excluded (as today) so seams stay consistent.
		var h := TerrainManager._sample_height(_noises, _amplitudes, px, pz)
		if _has_cliffs:
			h += _cliff_offsets.get(Vector2i(gx, gz), 0.0)
		_ph[base + hxi] = h


func _vertex_row(zi: int) -> void:
	var per_edge := _samples - 1
	var lz := -_half + zi * _cell_m
	var wz := _center.z + lz
	for xi in _samples:
		var lx := -_half + xi * _cell_m
		var wx := _center.x + lx
		var idx := zi * _samples + xi
		var vidx := Vector2i(coord.x * per_edge + xi, coord.y * per_edge + zi)
		var h: float
		if _lit:
			# Centre of this vertex in the halo (offset by 1 for the border); its four
			# ±1-cell neighbours are ±1 (x) and ±_hs (z) — the same world coords the
			# per-vertex light bake used, so the output is bit-identical. The halo already
			# carries noise + cliff, so h includes the cliff offset here.
			var c := (zi + 1) * _hs + (xi + 1)
			h = _ph[c]
			_lights[idx] = _m._light_from_neighbours(_ph[c - 1], _ph[c + 1], _ph[c - _hs], _ph[c + _hs])
		else:
			# Unlit: no halo, so add the cliff offset onto the pure noise directly.
			h = TerrainManager._sample_height(_noises, _amplitudes, wx, wz)
			if _has_cliffs:
				h += _cliff_offsets.get(vidx, 0.0)
		# Blend road vertices toward the baked road height by their weight.
		if _m.road_blend.has(vidx):
			h = lerpf(h, _m.road_heights[vidx], _m.road_blend[vidx])
		_heights[idx] = h
		_vertices[idx] = Vector3(lx, h, lz)
		_uvs[idx] = Vector2(wx, wz) * _tile
