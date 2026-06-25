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

# Held so the shape RID added to the body via PhysicsServer3D stays alive for
# the body's lifetime. Null when built without collision.
var _collision_shape: BoxShape3D

# The world position placed for each instance, in build order — a
# renderer-independent mirror of the MultiMesh instance transforms. The MultiMesh
# transform buffer lives in the RenderingServer, which is a no-op stub under
# --headless (get_instance_transform / buffer come back empty there), so this
# array is the only way headless tests can verify placement. Populated by build().
var instance_positions: PackedVector3Array


func build(positions: PackedVector2Array, terrain: TerrainManager, size: Vector2,
		texture: Texture2D, collision_radius: float, collision_height: float,
		with_collision: bool, render_distance: float, render_fade: float,
		y_offset: float = 0.0) -> void:
	var quad := QuadMesh.new()
	quad.size = size
	# Shift the quad up by half its height so its pivot is the bottom edge.
	quad.center_offset = Vector3(0.0, size.y * 0.5, 0.0)

	var mat := ShaderMaterial.new()
	mat.shader = BILLBOARD_SHADER
	mat.set_shader_parameter("albedo", texture)
	mat.set_shader_parameter("render_distance", render_distance)
	mat.set_shader_parameter("fade_band", render_fade)
	# Bias distant foliage to cheaper mips (mobile texture-bandwidth win).
	mat.set_shader_parameter("lod_bias", Config.data.texture_lod_bias)
	quad.surface_set_material(0, mat)

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = quad
	mm.instance_count = positions.size()
	instance_positions = PackedVector3Array()
	instance_positions.resize(positions.size())

	# One StaticBody3D holds every hitbox; all share one BoxShape3D resource
	# instanced per position with its own transform (cheap: one shape, N
	# transforms). Skipped entirely when with_collision is false.
	var body: StaticBody3D = null
	if with_collision:
		body = StaticBody3D.new()
		body.name = "Collision"
		add_child(body)
		_collision_shape = BoxShape3D.new()
		_collision_shape.size = Vector3(collision_radius * 2.0, collision_height, collision_radius * 2.0)

	for i in positions.size():
		var p := positions[i]
		# y_offset sinks the sprite into the ground (negative) to hide a gap at
		# the bottom of its texture, or lifts it (positive).
		var y := terrain.height_at(p.x, p.y) + y_offset
		var pos := Vector3(p.x, y, p.y)
		instance_positions[i] = pos
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, pos))
		if with_collision:
			# Box centred half its height above the ground so it rests on it.
			var box_xform := Transform3D(Basis.IDENTITY, Vector3(p.x, y + collision_height * 0.5, p.y))
			PhysicsServer3D.body_add_shape(body.get_rid(), _collision_shape.get_rid(), box_xform)

	multimesh = mm
