class_name MeshScatterField
extends MultiMeshInstance3D
# Renders scattered positions as instances of a real MESH in a single MultiMesh
# (one draw call) — the mesh counterpart of BillboardField. Each instance is
# lifted onto the terrain via TerrainManager.height_at, given a random yaw and a
# slightly jittered uniform scale so the repeated mesh does not read as a tiled
# pattern, and tinted by the terrain's baked light at that point (per-instance
# MultiMesh colour, multiplied in foliage_mesh.gdshader) so it matches the
# ground. Used for the ground-cover bushes; carries no collision.

# The world position placed for each instance, in build order — a
# renderer-independent mirror of the MultiMesh instance transforms. The MultiMesh
# transform buffer lives in the RenderingServer, a no-op stub under --headless,
# so this array is the only way headless tests can verify placement. Populated by
# build(), mirroring BillboardField.instance_positions.
var instance_positions: PackedVector3Array


func build(positions: PackedVector2Array, terrain: TerrainManager, mesh: Mesh,
		y_offset: float, base_scale: float, scale_jitter: float,
		seed_value: int) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = positions.size()

	instance_positions = PackedVector3Array()
	instance_positions.resize(positions.size())

	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	for i in positions.size():
		var p := positions[i]
		# y_offset (negative) sinks the patch slightly so its base meets the ground.
		var y := terrain.height_at(p.x, p.y) + y_offset
		var pos := Vector3(p.x, y, p.y)
		instance_positions[i] = pos
		var yaw := rng.randf() * TAU
		var s := base_scale * (1.0 + rng.randf_range(-scale_jitter, scale_jitter))
		var inst_basis := Basis(Vector3.UP, yaw).scaled(Vector3(s, s, s))
		mm.set_instance_transform(i, Transform3D(inst_basis, pos))
		# Bake the terrain's light at this point so foliage matches the ground tint.
		mm.set_instance_color(i, terrain.light_at(p.x, p.y))

	multimesh = mm
