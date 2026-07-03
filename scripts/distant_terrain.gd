class_name DistantTerrain
extends Node3D
# A coarse, static backdrop of the terrain covering the WHOLE reachable play
# area (the precomputed corridor) plus a margin — so the thin fog reveals a
# horizon for the sky instead of the hard edge of the 3x3 detail ring.
#
# The play area is bounded (off-track reset leash), so unlike the old version
# this never re-centres or rebuilds: it is built ONCE at level load, behind the
# loading screen, as a grid of tile meshes. Tiles (rather than one huge mesh)
# keep the backdrop frustum-cullable — a single mesh covering a whole stage
# would submit every triangle every frame through one giant AABB.
#
# Heights/light sample TerrainManager.height_at / light_at — cache-first inside
# the corridor, silently falling back to pure noise beyond it (scenery only, no
# collision). The whole backdrop is sunk sink_m below true height so the detail
# ring always renders above it (see the sink note in features/terrain.md).

var cell_m := 10.0    # coarse grid spacing (m) — blocky is fine at distance
var sink_m := 1.5     # drop below true height so the detail ring wins overlap
var tile_m := 250.0   # tile edge length (m) — the frustum-culling granularity


# Build the static tile grid covering `bounds` (world-XZ rect, already dilated
# by the caller's chosen margin). Synchronous — runs behind the loading screen.
func build_static(terrain: TerrainManager, bounds: Rect2) -> void:
	for child in get_children():
		child.queue_free()
	if terrain == null or bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return
	var tiles_x := int(ceil(bounds.size.x / tile_m))
	var tiles_z := int(ceil(bounds.size.y / tile_m))
	for tz in tiles_z:
		for tx in tiles_x:
			var origin := Vector2(bounds.position.x + tx * tile_m,
				bounds.position.y + tz * tile_m)
			_build_tile(terrain, origin)


# One tile: an indexed coarse grid mesh with its own local origin (so its AABB
# is tile-sized and the frustum can cull it). Vertex colours carry the baked
# light in RGB and alpha 0 (no road blend out here), like the old backdrop.
func _build_tile(terrain: TerrainManager, origin: Vector2) -> void:
	var per_edge := int(round(tile_m / cell_m))
	var samples := per_edge + 1
	var count := samples * samples
	var verts := PackedVector3Array(); verts.resize(count)
	var uvs := PackedVector2Array(); uvs.resize(count)
	var colors := PackedColorArray(); colors.resize(count)
	var tile_uv := terrain.texture_tile_per_meter
	for zi in samples:
		var wz := origin.y + zi * cell_m
		var base := zi * samples
		for xi in samples:
			var wx := origin.x + xi * cell_m
			var idx := base + xi
			verts[idx] = Vector3(xi * cell_m, terrain.height_at(wx, wz) - sink_m, zi * cell_m)
			uvs[idx] = Vector2(wx, wz) * tile_uv
			var lgt := terrain.light_at(wx, wz)
			colors[idx] = Color(lgt.r, lgt.g, lgt.b, 0.0)
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
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = am
	mi.position = Vector3(origin.x, 0.0, origin.y)
	if terrain.chunk_material != null:
		mi.material_override = terrain.chunk_material
	add_child(mi)
