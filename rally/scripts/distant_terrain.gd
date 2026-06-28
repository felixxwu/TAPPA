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
# geometry re-centres on every focus CHUNK crossing and is a FULL, UNCUT grid:
# it underlaps the entire detail ring rather than holing out the loaded chunks.
#
# To stop the coarse mesh poking through the detailed ring, the WHOLE backdrop is
# sunk `sink_m` (1-2 m) below true terrain height. The detail ring renders at true
# height on top, so it always wins the overlap; the coarse mesh stays hidden
# beneath it. At the ring's outer edge the coarse surface steps down by `sink_m`,
# but that edge is ~75 m away and softened by fog, so the step is imperceptible.
#
# This deliberately trades a tiny, constant bit of (occluded) coarse overdraw under
# the detail ring for ZERO per-crossing hole-cutting work: there is no longer any
# loaded-chunk tracking, index re-cut on chunk integration, or skybox-flash race
# to manage — the backdrop only rebuilds when the focus crosses a chunk.
#
# Reuses the terrain's chunk_material so it gets the same grass texture, baked
# light (via TerrainManager.light_at) and fog/post-process as everything else.
# Vertex-colour alpha is 0 (no road blend out here).

var _terrain: TerrainManager
var _focus: Node3D
var radius_m := 250.0       # half-extent of the backdrop square (m)
var cell_m := 10.0          # coarse grid spacing (m) — blocky is fine at distance
var sink_m := 1.5           # drop the whole backdrop below true height so the detail ring wins

var _focus_chunk := Vector2i(2147483647, 0)  # force first build
var _per_edge := 0


# `terrain` supplies height_at/light_at + the shared chunk material; `focus` (the
# car) drives rebuilds. Builds the first backdrop immediately.
func setup(terrain: TerrainManager, focus: Node3D) -> void:
	_terrain = terrain
	_focus = focus
	if terrain != null and terrain.chunk_material != null:
		material_override = terrain.chunk_material
	var center := _focus.global_position if _focus != null else Vector3.ZERO
	rebuild_around(center)


# Re-centre the coarse geometry on a focus chunk crossing; otherwise nothing to do
# (the backdrop is a full uncut grid that doesn't track the detail ring's load-in).
func _process(_delta: float) -> void:
	if _focus == null or _terrain == null:
		return
	var chunk := _terrain.chunk_coord_for(_focus.global_position)
	if chunk != _focus_chunk:
		rebuild_around(_focus.global_position)


# Build the coarse backdrop centred on `center`, snapped to the cell grid so the
# surface doesn't swim. Heights/light come from the terrain noise (matches the
# detail ring at the seam, minus the uniform sink). A full uncut grid: no holes.
func rebuild_around(center: Vector3) -> void:
	if _terrain == null:
		return
	_focus_chunk = _terrain.chunk_coord_for(center)
	var cx := snappedf(center.x, cell_m)
	var cz := snappedf(center.z, cell_m)
	_per_edge = int(round((radius_m * 2.0) / cell_m))
	var samples := _per_edge + 1
	var grid_min := Vector2(cx - radius_m, cz - radius_m)
	var tile: float = _terrain.texture_tile_per_meter
	var count := samples * samples

	var verts := PackedVector3Array(); verts.resize(count)
	var uvs := PackedVector2Array(); uvs.resize(count)
	var colors := PackedColorArray(); colors.resize(count)
	for zi in samples:
		var wz := grid_min.y + zi * cell_m
		for xi in samples:
			var wx := grid_min.x + xi * cell_m
			var idx := zi * samples + xi
			verts[idx] = Vector3(wx, _terrain.height_at(wx, wz) - sink_m, wz)
			uvs[idx] = Vector2(wx, wz) * tile
			var lgt := _terrain.light_at(wx, wz)
			colors[idx] = Color(lgt.r, lgt.g, lgt.b, 0.0)  # alpha 0 = no road blend

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = _build_indices(samples)
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = am


# Two triangles per coarse cell, full grid (no holes cut). `samples` is the vertex
# count per edge (_per_edge + 1).
func _build_indices(samples: int) -> PackedInt32Array:
	var indices := PackedInt32Array()
	for zi in _per_edge:
		for xi in _per_edge:
			var a := zi * samples + xi
			var b := a + 1
			var c := a + samples
			var d := c + 1
			indices.append(a); indices.append(b); indices.append(c)
			indices.append(b); indices.append(d); indices.append(c)
	return indices
