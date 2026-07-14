@tool
extends StaticBody3D
class_name TerrainChunk

# One tile of the chunked terrain, built at runtime by TerrainManager. Centred
# on its chunk so the centred mesh + HeightMapShape3D span exactly the tile.
#
# LOD: the chunk carries one MeshInstance3D per LOD level (TerrainLod.LOD_STRIDES),
# each with a visibility_range distance band + dither crossfade, so the ENGINE
# selects and blends the right level by real camera distance every frame at zero
# script cost. Collision is a single HeightMapShape3D built from the full-res L0
# heights, ENABLED only when the chunk is near the car (TerrainManager gates it) —
# far chunks are render-only, so shrinking/keeping collision doesn't grow the
# broadphase.

var coord: Vector2i
var _mesh_instances: Array[MeshInstance3D] = []
var _collision: CollisionShape3D


func _init() -> void:
	_collision = CollisionShape3D.new()
	_collision.name = "CollisionShape3D"
	# HeightMapShape3D spans (SAMPLES-1) cells of 1 unit; scale cells to CELL_M.
	# Scaling collision shapes is discouraged in Godot but is the standard
	# workaround since HeightMapShape3D has no cell-size property.
	_collision.scale = Vector3(TerrainManager.CELL_M, 1.0, TerrainManager.CELL_M)
	add_child(_collision)


func setup(manager: TerrainManager, chunk_coord: Vector2i) -> void:
	apply_data(manager, chunk_coord, manager.compute_chunk_data(chunk_coord))


# Main-thread only: assemble the per-level GPU meshes + collision from precomputed
# arrays. `data["lod_meshes"]` is prebaked (TerrainLod.build_all) when the chunk
# comes from the corridor cache; built on demand otherwise (editor / tests).
func apply_data(manager: TerrainManager, chunk_coord: Vector2i, data: Dictionary) -> void:
	coord = chunk_coord
	position = data["center"]

	var meshes: Array = data.get("lod_meshes", [])
	if meshes.is_empty():
		meshes = TerrainLod.build_all(data, manager.lod_skirt_m)
	_ensure_mesh_instances(meshes.size())
	var bands: PackedFloat32Array = manager.lod_band_ends()
	for i in _mesh_instances.size():
		var mi := _mesh_instances[i]
		mi.mesh = meshes[i]
		mi.material_override = manager.chunk_material
		# Band: level i is visible from the previous band's end out to bands[i],
		# HARD cutoff (no fade). The dithered visibility-range fade is a Forward+/
		# Mobile feature — the Compatibility renderer this game uses IGNORES it and
		# hard-cuts anyway, and the dither is an alpha-hash `discard` that would
		# defeat early-Z on tile GPUs (bad on our opaque terrain). The pop is small
		# and hidden by construction: coarse levels are EXACT subsamples (shared
		# vertices don't move), the terrain is gentle, skirts cover the crack, and
		# fog softens distance. Indices clamped so a bands/levels length mismatch
		# can't range-error (deepest levels then share the last boundary).
		var begin := bands[mini(i - 1, bands.size() - 1)] if i > 0 else 0.0
		var end := bands[i] if i < bands.size() else 0.0  # last level: no far cutoff
		mi.visibility_range_begin = begin
		mi.visibility_range_end = end
		mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED

	var shape := HeightMapShape3D.new()
	shape.map_width = TerrainManager.SAMPLES
	shape.map_depth = TerrainManager.SAMPLES
	shape.map_data = data["heights"]
	_collision.shape = shape


# Grow/shrink the pool of per-level MeshInstance3D children to `count`.
func _ensure_mesh_instances(count: int) -> void:
	while _mesh_instances.size() < count:
		var mi := MeshInstance3D.new()
		mi.name = "LOD%d" % _mesh_instances.size()
		add_child(mi)
		_mesh_instances.append(mi)
	while _mesh_instances.size() > count:
		_mesh_instances.pop_back().queue_free()


# Enable/disable this chunk's collision. Far chunks are render-only (disabled), so
# their heightfield is not a live broadphase entry. Cheap toggle, no shape rebuild.
func set_collision_enabled(on: bool) -> void:
	_collision.disabled = not on
