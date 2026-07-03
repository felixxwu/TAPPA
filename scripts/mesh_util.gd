class_name MeshUtil
extends RefCounted

## Shared helpers for pulling meshes out of imported (glb/scene) PackedScenes.


# Instantiate `scene`, recursively walk its node tree to find the first
# MeshInstance3D, and return that instance's `.mesh` (or null if the scene is
# null or contains no MeshInstance3D). The temporary instance is always freed.
#
# Mirrors the extraction logic used across the project (world._tree_mesh /
# world._bush_mesh, spectator_group._extract_mesh, and the car/hq/podium mesh
# pulls): a depth-first search that returns the first mesh found.
static func first_mesh(scene: PackedScene) -> Mesh:
	if scene == null:
		return null
	var inst := scene.instantiate()
	var mi := _find_mesh_instance(inst)
	var mesh: Mesh = mi.mesh if mi != null else null
	inst.free()
	return mesh


# Depth-first search for the first MeshInstance3D at or below `n`.
static func _find_mesh_instance(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n as MeshInstance3D
	for c in n.get_children():
		var found := _find_mesh_instance(c)
		if found != null:
			return found
	return null
