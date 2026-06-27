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
# collision (the car never leaves the detailed ring, which follows it). It is
# rebuilt in lockstep with the detail ring — on every focus CHUNK crossing — and
# CUTS A HOLE over the currently-loaded chunk footprint, so the coarse mesh never
# overlaps (and pokes through) the accurate detailed chunks. A one-coarse-cell
# overlap is kept under the ring's edge so there's no gap at the seam, with the
# coarse mesh sunk slightly there so the detail ring always wins.
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


# `terrain` supplies height_at/light_at + the shared chunk material; `focus` (the
# car) drives rebuilds. Builds the first backdrop immediately.
func setup(terrain: TerrainManager, focus: Node3D) -> void:
	_terrain = terrain
	_focus = focus
	if terrain != null and terrain.chunk_material != null:
		material_override = terrain.chunk_material
	var center := _focus.global_position if _focus != null else Vector3.ZERO
	rebuild_around(center)


# Rebuild only when the focus crosses into a new chunk — so the cut-out hole stays
# aligned with the detail ring (which re-centres on the same crossings).
func _process(_delta: float) -> void:
	if _focus == null or _terrain == null:
		return
	var chunk := _terrain.chunk_coord_for(_focus.global_position)
	if chunk != _focus_chunk:
		rebuild_around(_focus.global_position)


# Build the coarse backdrop centred on `center`, snapped to the cell grid so the
# surface doesn't swim. Heights/light come from the terrain noise (matches the
# detail ring at the seam). Triangles whose centre falls within the loaded chunk
# footprint are skipped, leaving a hole the detail ring fills.
func rebuild_around(center: Vector3) -> void:
	if _terrain == null:
		return
	_focus_chunk = _terrain.chunk_coord_for(center)
	var cx := snappedf(center.x, cell_m)
	var cz := snappedf(center.z, cell_m)

	# Loaded-chunk footprint (world AABB), inset by one coarse cell so the coarse
	# mesh still underlaps the detail ring's edge (no gap) without overlapping its
	# interior. Cells whose centre lies inside this rect are not emitted.
	var cm := TerrainManager.CHUNK_M
	var r := TerrainManager.RADIUS
	var hole_min_x := (_focus_chunk.x - r) * cm + cell_m
	var hole_max_x := (_focus_chunk.x + r + 1) * cm - cell_m
	var hole_min_z := (_focus_chunk.y - r) * cm + cell_m
	var hole_max_z := (_focus_chunk.y + r + 1) * cm - cell_m

	var per_edge := int(round((radius_m * 2.0) / cell_m))
	var samples := per_edge + 1
	var tile: float = _terrain.texture_tile_per_meter
	var count := samples * samples

	var vertices := PackedVector3Array(); vertices.resize(count)
	var uvs := PackedVector2Array(); uvs.resize(count)
	var colors := PackedColorArray(); colors.resize(count)
	for zi in samples:
		var wz := cz - radius_m + zi * cell_m
		for xi in samples:
			var wx := cx - radius_m + xi * cell_m
			var idx := zi * samples + xi
			vertices[idx] = Vector3(wx, _terrain.height_at(wx, wz) - sink_m, wz)
			uvs[idx] = Vector2(wx, wz) * tile
			var lgt := _terrain.light_at(wx, wz)
			colors[idx] = Color(lgt.r, lgt.g, lgt.b, 0.0)  # alpha 0 = no road blend

	# Emit two triangles per cell, except where the cell centre is inside the hole.
	var indices := PackedInt32Array()
	for zi in per_edge:
		var cell_wz := cz - radius_m + (zi + 0.5) * cell_m
		var z_in := cell_wz > hole_min_z and cell_wz < hole_max_z
		for xi in per_edge:
			var cell_wx := cx - radius_m + (xi + 0.5) * cell_m
			if z_in and cell_wx > hole_min_x and cell_wx < hole_max_x:
				continue  # under the detail ring — leave a hole
			var a := zi * samples + xi
			var b := a + 1
			var c := a + samples
			var d := c + 1
			indices.append(a); indices.append(b); indices.append(c)
			indices.append(b); indices.append(d); indices.append(c)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = am
