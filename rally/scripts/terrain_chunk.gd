@tool
extends StaticBody3D
class_name TerrainChunk

# One tile of the chunked terrain, built at runtime by TerrainManager. Centred
# on its chunk so the centred mesh + HeightMapShape3D span exactly the tile.

var coord: Vector2i
var _mesh_instance: MeshInstance3D
var _collision: CollisionShape3D


func _init() -> void:
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "MeshInstance3D"
	add_child(_mesh_instance)
	_collision = CollisionShape3D.new()
	_collision.name = "CollisionShape3D"
	# HeightMapShape3D spans (SAMPLES-1) cells of 1 unit; scale cells to CELL_M.
	# Scaling collision shapes is discouraged in Godot but is the standard
	# workaround since HeightMapShape3D has no cell-size property.
	_collision.scale = Vector3(TerrainManager.CELL_M, 1.0, TerrainManager.CELL_M)
	add_child(_collision)


func setup(manager: TerrainManager, chunk_coord: Vector2i) -> void:
	apply_data(manager, chunk_coord, manager.compute_chunk_data(chunk_coord))


# Main-thread only: assemble the GPU mesh + collision from precomputed arrays.
func apply_data(manager: TerrainManager, chunk_coord: Vector2i, data: Dictionary) -> void:
	coord = chunk_coord
	position = data["center"]
	_mesh_instance.material_override = manager.chunk_material

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = data["vertices"]
	arrays[Mesh.ARRAY_TEX_UV] = data["uvs"]
	arrays[Mesh.ARRAY_COLOR] = data["colors"]
	arrays[Mesh.ARRAY_INDEX] = data["indices"]
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh_instance.mesh = mesh

	var shape := HeightMapShape3D.new()
	shape.map_width = TerrainManager.SAMPLES
	shape.map_depth = TerrainManager.SAMPLES
	shape.map_data = data["heights"]
	_collision.shape = shape
