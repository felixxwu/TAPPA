class_name Crowd
extends RefCounted
# The shared crowd-figure mesh and its ground foot-offset, so every crowd uses the same model at the same size.

const SPECTATOR_SCENE := preload("res://blender/spectator/spectator.glb")

static var _mesh_cache: Mesh


# The shared crowd-figure mesh, extracted once from the GLB and reused everywhere
# (a shared, immutable render resource). May be null if the GLB has no mesh.
static func mesh() -> Mesh:
	if _mesh_cache == null:
		_mesh_cache = MeshUtil.first_mesh(SPECTATOR_SCENE)
	return _mesh_cache


# How far to lift the figure so its feet sit on the ground: its feet are this far
# above its own origin (the negated mesh-AABB bottom). 0.0 for a null mesh.
static func foot_offset(m: Mesh) -> float:
	return -m.get_aabb().position.y if m != null else 0.0
