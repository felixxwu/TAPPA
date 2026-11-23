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
			_level_meshes.append(_with_base_shade(mi.mesh, mat))
		root.free()
	return _level_meshes


# The mesh with its vertex colours darkened toward the feet, the same fake AO the level bakes into buildings.
static func _with_base_shade(src: Mesh, mat: Material) -> ArrayMesh:
	var dark: float = Config.data.level_ao_spectator_base
	var reach: float = maxf(Config.data.level_ao_spectator_base_height_m, 0.01)
	var out := ArrayMesh.new()
	for s in src.get_surface_count():
		var arrays := src.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		if cols.is_empty():
			cols.resize(verts.size())
			cols.fill(Color.WHITE)
		for i in verts.size():
			var shade := 1.0 - dark * (1.0 - smoothstep(0.0, reach, verts[i].y))
			cols[i] = Color(cols[i].r * shade, cols[i].g * shade, cols[i].b * shade, cols[i].a)
		arrays[Mesh.ARRAY_COLOR] = cols
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		out.surface_set_material(s, mat)
	return out
