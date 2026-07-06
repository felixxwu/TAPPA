class_name BillboardField
extends MultiMeshInstance3D
# Renders scattered positions as cylindrical billboards in a single MultiMesh
# (one draw call), using a caller-supplied texture. Each instance is lifted onto
# the terrain via TerrainManager.height_at; the quad pivot is its bottom edge so
# sprites sit on the ground. When with_collision is true, a child StaticBody3D
# carries one box hitbox per instance, all sharing a single BoxShape3D resource
# instanced via the physics server. Used for both trees (with collision) and
# bushes (without).

const BILLBOARD_SHADER := preload("res://shaders/billboard.gdshader")
const BILLBOARD_OPAQUE_SHADER := preload("res://shaders/billboard_opaque.gdshader")

# Held so the shape RID added to the body via PhysicsServer3D stays alive for
# the body's lifetime. Null when built without collision.
var _collision_shape: BoxShape3D

# The world position placed for each instance, in build order — a
# renderer-independent mirror of the MultiMesh instance transforms. The MultiMesh
# transform buffer lives in the RenderingServer, which is a no-op stub under
# --headless (get_instance_transform / buffer come back empty there), so this
# array is the only way headless tests can verify placement. Populated by build().
var instance_positions: PackedVector3Array

# The per-instance scale baked into every instance transform's basis by the
# opaque mesh path (Vector3.ONE for the quad path, which bakes size into the
# quad geometry instead). Mirrors instance_positions' role: MultiMesh's
# transform buffer lives in the RenderingServer, a no-op stub under
# --headless, so get_instance_transform comes back empty there — this is the
# only way headless tests can verify the scale that was set. Populated by build().
var instance_scale: Vector3 = Vector3.ONE


func build(positions: PackedVector2Array, terrain: TerrainManager, size: Vector2,
		texture: Texture2D, collision_radius: float, collision_height: float,
		with_collision: bool, render_distance: float, render_fade: float,
		y_offset: float = 0.0, mesh: Mesh = null, opaque: bool = false) -> void:
	# Two render paths share this field:
	#  - Quad + alpha-cutout shader (mesh == null): the classic sprite billboard.
	#  - Supplied silhouette mesh + opaque shader (mesh != null and opaque): the
	#    tree cutout baked into geometry, no discard (early-Z friendly). The mesh
	#    is normalized (x in [-0.5,0.5], y in [0,1]); size is carried as per-
	#    instance scale so the opaque shader reads it from MODEL_MATRIX.
	var use_opaque := mesh != null and opaque
	var render_mesh: Mesh
	if use_opaque:
		render_mesh = mesh
	else:
		var quad := QuadMesh.new()
		quad.size = size
		# Shift the quad up by half its height so its pivot is the bottom edge.
		quad.center_offset = Vector3(0.0, size.y * 0.5, 0.0)
		render_mesh = quad

	var mat := ShaderMaterial.new()
	mat.shader = BILLBOARD_OPAQUE_SHADER if use_opaque else BILLBOARD_SHADER
	mat.set_shader_parameter("albedo", texture)
	mat.set_shader_parameter("render_distance", render_distance)
	mat.set_shader_parameter("fade_band", render_fade)
	# Bias distant foliage to cheaper mips (mobile texture-bandwidth win).
	mat.set_shader_parameter("lod_bias", Config.data.texture_lod_bias)
	# A supplied silhouette mesh can be empty (0 surfaces) if its source texture
	# had no opaque area; skip material assignment then (the field renders nothing)
	# rather than indexing a missing surface.
	if render_mesh.get_surface_count() > 0:
		render_mesh.surface_set_material(0, mat)

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = render_mesh
	mm.instance_count = positions.size()
	instance_positions = PackedVector3Array()
	instance_positions.resize(positions.size())

	# Opaque path scales the normalized mesh by size; quad path bakes size in.
	instance_scale = Vector3(size.x, size.y, 1.0) if use_opaque else Vector3.ONE
	var inst_basis := Basis.from_scale(instance_scale) if use_opaque else Basis.IDENTITY

	for i in positions.size():
		var p := positions[i]
		# y_offset sinks the sprite into the ground (negative) to hide a gap at
		# the bottom of its texture, or lifts it (positive).
		var y := terrain.height_at(p.x, p.y) + y_offset
		var pos := Vector3(p.x, y, p.y)
		instance_positions[i] = pos
		mm.set_instance_transform(i, Transform3D(inst_basis, pos))

	# One StaticBody3D holds every hitbox; all share one BoxShape3D resource instanced
	# per position (cheap: one shape, N transforms). Skipped when with_collision is false.
	if with_collision:
		_collision_shape = ObstacleBody.build(self, instance_positions, collision_radius, collision_height)

	multimesh = mm
