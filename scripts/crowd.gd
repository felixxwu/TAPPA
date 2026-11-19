class_name Crowd
extends RefCounted
# The shared crowd-figure mesh and its ground foot-offset, so every crowd uses the same model at the same size.

const SPECTATOR_SCENE := preload("res://blender/spectator/spectator.glb")

const LEVEL_SPECTATORS := preload("res://models/spectators/spectators.glb")
const LIT_SHADER := preload("res://shaders/ps1_models_lit.gdshader")

static var _mesh_cache: Mesh
static var _level_meshes: Array[Mesh] = []


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


# The 10 baked limbless spectators (tools/bake_spectators.js), in node order, feet at y=0, real metres, vertex-coloured.
static func level_meshes() -> Array[Mesh]:
	if _level_meshes.is_empty():
		var mat := ShaderMaterial.new()
		mat.shader = LIT_SHADER
		var root := LEVEL_SPECTATORS.instantiate()
		for child in root.get_children():
			var mi := child as MeshInstance3D
			if mi == null:
				continue
			var m := mi.mesh.duplicate() as Mesh
			for s in m.get_surface_count():
				m.surface_set_material(s, mat)
			_level_meshes.append(m)
		root.free()
	return _level_meshes
