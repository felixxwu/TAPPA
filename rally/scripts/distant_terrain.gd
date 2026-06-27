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
# sunk slightly so the accurate detail ring always renders on top in the overlap,
# and re-centres on the focus (car) only when it has moved far enough — the far
# backdrop doesn't need to track every metre.
#
# Reuses the terrain's chunk_material so it gets the same grass texture, baked
# light (via TerrainManager.light_at) and fog/post-process as everything else.
# Vertex-colour alpha is 0 (no road blend out here).

var _terrain: TerrainManager
var _focus: Node3D
var radius_m := 250.0       # half-extent of the backdrop square (m)
var cell_m := 10.0          # coarse grid spacing (m) — blocky is fine at distance
var recenter_m := 100.0     # rebuild once the focus moves this far from the last centre
var sink_m := 0.5           # drop below true height so the detail ring wins the overlap

var _built_center := Vector3(INF, 0, INF)


# `terrain` supplies height_at/light_at + the shared chunk material; `focus` (the
# car) drives re-centring. Builds the first backdrop immediately.
func setup(terrain: TerrainManager, focus: Node3D) -> void:
	_terrain = terrain
	_focus = focus
	if terrain != null and terrain.chunk_material != null:
		material_override = terrain.chunk_material
	# Distant backdrop is pure scenery: never let it block raycasts/physics queries.
	var center := _focus.global_position if _focus != null else Vector3.ZERO
	rebuild_around(center)


func _process(_delta: float) -> void:
	if _focus == null or _terrain == null:
		return
	var pos := _focus.global_position
	if Vector2(pos.x - _built_center.x, pos.z - _built_center.z).length() >= recenter_m:
		rebuild_around(pos)


# Build the coarse backdrop mesh centred on `center` (snapped to the cell grid so
# the surface doesn't swim as it re-centres). Heights/light come from the terrain
# noise, so it matches the detail ring at the seam (hidden by haze regardless).
func rebuild_around(center: Vector3) -> void:
	if _terrain == null:
		return
	var cx := snappedf(center.x, cell_m)
	var cz := snappedf(center.z, cell_m)
	_built_center = Vector3(cx, 0.0, cz)

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

	var indices := PackedInt32Array(); indices.resize(per_edge * per_edge * 6)
	var ii := 0
	for zi in per_edge:
		for xi in per_edge:
			var a := zi * samples + xi
			var b := a + 1
			var c := a + samples
			var d := c + 1
			indices[ii + 0] = a; indices[ii + 1] = b; indices[ii + 2] = c
			indices[ii + 3] = b; indices[ii + 4] = d; indices[ii + 5] = c
			ii += 6

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = am
