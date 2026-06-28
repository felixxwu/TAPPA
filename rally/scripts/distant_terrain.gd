class_name DistantTerrain
extends MeshInstance3D
# A coarse, low-resolution "backdrop" of the terrain that extends far past the
# detailed TerrainManager chunk ring (which only reaches ~75 m, see RADIUS=1 /
# CHUNK_M=50). It exists purely to give the SKY a distant horizon to sit above:
# without it, reducing the fog would reveal the hard edge where the 3x3 detail
# ring ends. See todo/distant-terrain-and-sky.md §1.
#
# Cheap by design: one indexed mesh (one draw call), built at a coarse cell size
# from the SAME noise as the real terrain (TerrainManager.height_at), with NO
# collision (the car never leaves the detailed ring, which follows it). The coarse
# geometry re-centres on every focus CHUNK crossing, and CUTS A HOLE only over the
# chunks the detail ring has ACTUALLY LOADED (TerrainManager.loaded_coords), NOT
# the whole wanted ring. That distinction matters: detail chunks integrate one per
# frame, so on a crossing the leading chunks don't exist for several frames — if we
# holed the wanted footprint up front, those not-yet-loaded cells would show the
# SKYBOX through the ground until the hi-res chunk arrived. Holing only loaded
# chunks means the coarse backdrop always covers anything the detail ring hasn't
# filled yet, so there is never a gap. As each chunk integrates the hole grows to
# match via a cheap index-only rebuild (_recut_hole) — the coarse vertices don't
# change between crossings, so no noise is re-sampled for the grow-in.
#
# A one-coarse-cell underlap is kept around each loaded chunk's edge so there's no
# gap at the seam, with the coarse mesh sunk slightly (sink_m) so the detail ring
# always wins the overlap.
#
# Reuses the terrain's chunk_material so it gets the same grass texture, baked
# light (via TerrainManager.light_at) and fog/post-process as everything else.
# Vertex-colour alpha is 0 (no road blend out here).

var _terrain: TerrainManager
var _focus: Node3D
var radius_m := 250.0       # half-extent of the backdrop square (m)
var cell_m := 10.0          # coarse grid spacing (m) — blocky is fine at distance
var sink_m := 0.5           # drop below true height so the detail ring wins the overlap

var _focus_chunk := Vector2i(2147483647, 0)  # force first build
# Cached coarse geometry (recomputed only on a focus chunk crossing); the hole
# (indices) is re-cut against the live loaded set without touching these.
var _verts: PackedVector3Array
var _uvs: PackedVector2Array
var _colors: PackedColorArray
var _samples := 0
var _per_edge := 0
var _grid_min := Vector2.ZERO  # world XZ of vertex (0, 0)
var _last_integrations := -1   # TerrainManager.integrations_total at the last hole cut


# `terrain` supplies height_at/light_at + the shared chunk material; `focus` (the
# car) drives rebuilds. Builds the first backdrop immediately.
func setup(terrain: TerrainManager, focus: Node3D) -> void:
	_terrain = terrain
	_focus = focus
	if terrain != null and terrain.chunk_material != null:
		material_override = terrain.chunk_material
	var center := _focus.global_position if _focus != null else Vector3.ZERO
	rebuild_around(center)


# Re-centre the coarse geometry on a focus chunk crossing; otherwise just re-cut
# the hole when the detail ring has loaded (or freed) a chunk since the last cut,
# so the hole tracks the actual hi-res coverage and never bares the skybox.
func _process(_delta: float) -> void:
	if _focus == null or _terrain == null:
		return
	var chunk := _terrain.chunk_coord_for(_focus.global_position)
	if chunk != _focus_chunk:
		rebuild_around(_focus.global_position)
	elif _terrain.integrations_total != _last_integrations:
		_recut_hole()


# Build the coarse backdrop centred on `center`, snapped to the cell grid so the
# surface doesn't swim. Heights/light come from the terrain noise (matches the
# detail ring at the seam). Caches the geometry, then cuts the hole over whatever
# detail chunks are currently loaded.
func rebuild_around(center: Vector3) -> void:
	if _terrain == null:
		return
	_focus_chunk = _terrain.chunk_coord_for(center)
	var cx := snappedf(center.x, cell_m)
	var cz := snappedf(center.z, cell_m)
	_per_edge = int(round((radius_m * 2.0) / cell_m))
	_samples = _per_edge + 1
	_grid_min = Vector2(cx - radius_m, cz - radius_m)
	var tile: float = _terrain.texture_tile_per_meter
	var count := _samples * _samples

	_verts = PackedVector3Array(); _verts.resize(count)
	_uvs = PackedVector2Array(); _uvs.resize(count)
	_colors = PackedColorArray(); _colors.resize(count)
	for zi in _samples:
		var wz := _grid_min.y + zi * cell_m
		for xi in _samples:
			var wx := _grid_min.x + xi * cell_m
			var idx := zi * _samples + xi
			_verts[idx] = Vector3(wx, _terrain.height_at(wx, wz) - sink_m, wz)
			_uvs[idx] = Vector2(wx, wz) * tile
			var lgt := _terrain.light_at(wx, wz)
			_colors[idx] = Color(lgt.r, lgt.g, lgt.b, 0.0)  # alpha 0 = no road blend

	_rebuild_mesh()


# Re-cut the hole against the live loaded set, reusing the cached coarse vertices
# (no noise re-sampling). Called each time a chunk integrates so the hole grows in
# step with the hi-res coverage rather than racing ahead of it.
func _recut_hole() -> void:
	if _verts.is_empty():
		return
	_rebuild_mesh()


# Assemble the mesh from the cached vertices and a freshly cut index buffer, and
# stamp the integration count the hole now matches.
func _rebuild_mesh() -> void:
	_last_integrations = _terrain.integrations_total
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _verts
	arrays[Mesh.ARRAY_TEX_UV] = _uvs
	arrays[Mesh.ARRAY_COLOR] = _colors
	arrays[Mesh.ARRAY_INDEX] = _build_indices()
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = am


# Two triangles per coarse cell, except cells whose centre sits inside a LOADED
# detail chunk (inset by one coarse cell so the coarse mesh underlaps the chunk
# edge — no seam gap). Cells over not-yet-loaded chunks stay solid, so the skybox
# is never exposed during the chunk load-in.
func _build_indices() -> PackedInt32Array:
	var cm := TerrainManager.CHUNK_M
	var loaded := {}
	for c in _terrain.loaded_coords():
		loaded[c] = true
	var indices := PackedInt32Array()
	for zi in _per_edge:
		var cell_wz := _grid_min.y + (zi + 0.5) * cell_m
		for xi in _per_edge:
			var cell_wx := _grid_min.x + (xi + 0.5) * cell_m
			if _over_loaded_chunk(cell_wx, cell_wz, cm, loaded):
				continue  # under a loaded detail chunk — leave a hole
			var a := zi * _samples + xi
			var b := a + 1
			var c := a + _samples
			var d := c + 1
			indices.append(a); indices.append(b); indices.append(c)
			indices.append(b); indices.append(d); indices.append(c)
	return indices


# True when world point (wx, wz) sits inside a loaded chunk's footprint, inset by
# one coarse cell on every side so a one-cell coarse underlap survives at the edge.
func _over_loaded_chunk(wx: float, wz: float, cm: float, loaded: Dictionary) -> bool:
	var coord := Vector2i(floori(wx / cm), floori(wz / cm))
	if not loaded.has(coord):
		return false
	return (
		wx > coord.x * cm + cell_m and wx < (coord.x + 1) * cm - cell_m
		and wz > coord.y * cm + cell_m and wz < (coord.y + 1) * cm - cell_m)
