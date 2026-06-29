class_name TreeMeshField
extends Node3D
# Renders scattered tree positions as solid low-poly 3D meshes (the opaque-mesh
# direction from todo/performance-optimisations.md item 2), replacing the old
# alpha-cutout billboards for trees. Bushes still use BillboardField.
#
# Trees are spatially BINNED into one MultiMesh per grid cell. A single
# field-wide MultiMesh can't auto-LOD or visibility-cull usefully: Godot picks a
# single mesh LOD for the whole MultiMesh (by its overall AABB) and a field-wide
# visibility_range would gate every tree at once. Per-bin MultiMeshInstance3Ds
# each have a compact AABB centred on the bin, so the engine drops far bins to
# the importer-generated mesh LODs and fades them out past
# `visibility_range_end` — auto-LOD "takes place" for further trees, at one draw
# call per visible bin.
#
# One shared StaticBody3D carries a box hitbox per tree (same scheme as
# BillboardField): one BoxShape3D resource, N transforms via the physics server.

# Held so the shape RID added to the body stays alive for the body's lifetime.
var _collision_shape: BoxShape3D

# World position placed for each instance, in build (caller) order — the
# renderer-independent mirror of the MultiMesh transforms (the MultiMesh buffer
# lives in the RenderingServer, a no-op stub under --headless), so headless tests
# can verify placement. Populated by build().
var instance_positions: PackedVector3Array

# Number of per-bin MultiMeshInstance3D children created (for tests/inspection).
var bin_count: int = 0

# Uniform scale applied to every instance so the model matches the target height
# (exposed for headless tests, where the MultiMesh transform buffer — owned by
# the RenderingServer — is a no-op stub and can't be read back).
var instance_scale: float = 1.0


func build(positions: PackedVector2Array, terrain: TerrainManager, mesh: Mesh,
		target_height: float, collision_radius: float, collision_height: float,
		render_distance: float, render_fade: float, bin_size: float,
		with_collision: bool = true) -> void:
	instance_positions = PackedVector3Array()
	instance_positions.resize(positions.size())

	# Uniform scale so the model's height matches the configured tree height
	# (keeps proportions — a 3D tree must not be stretched like a billboard quad).
	var uscale := 1.0
	var ah := mesh.get_aabb().size.y
	if ah > 0.0001:
		uscale = target_height / ah
	instance_scale = uscale

	var bin := maxf(bin_size, 1.0)
	var world_pos := PackedVector3Array()
	world_pos.resize(positions.size())
	var bins := {}  # Vector2i -> PackedInt32Array of instance indices
	for i in positions.size():
		var p := positions[i]
		var pos := Vector3(p.x, terrain.height_at(p.x, p.y), p.y)
		instance_positions[i] = pos
		world_pos[i] = pos
		var key := Vector2i(floori(p.x / bin), floori(p.y / bin))
		if not bins.has(key):
			bins[key] = PackedInt32Array()
		bins[key].append(i)

	# One MultiMesh per bin, positioned at the bin centre so visibility_range /
	# LOD distance is measured from there (instance transforms are bin-local).
	for key: Vector2i in bins:
		var idxs: PackedInt32Array = bins[key]
		var centre := Vector3((float(key.x) + 0.5) * bin, 0.0, (float(key.y) + 0.5) * bin)

		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = idxs.size()
		for j in idxs.size():
			var pos := world_pos[idxs[j]]
			# Deterministic per-tree yaw so the cluster doesn't look cloned.
			var yaw := _yaw_for(pos)
			var xf_basis := Basis(Vector3.UP, yaw).scaled(Vector3(uscale, uscale, uscale))
			mm.set_instance_transform(j, Transform3D(xf_basis, pos - centre))

		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.position = centre
		# Far cull + dither-fade, replacing the billboard shader's distance cull.
		# The importer mesh LODs handle decimation up to this range.
		mmi.visibility_range_end = render_distance
		mmi.visibility_range_end_margin = render_fade
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		add_child(mmi)
	bin_count = bins.size()

	# One StaticBody3D with a box per tree (obstacle for the car's damage model).
	# Skipped for scenery-only fields (e.g. the HQ ring).
	if with_collision and positions.size() > 0:
		var body := StaticBody3D.new()
		body.name = "Collision"
		body.add_to_group(DamageModel.OBSTACLE_GROUP)
		add_child(body)
		_collision_shape = BoxShape3D.new()
		_collision_shape.size = Vector3(collision_radius * 2.0, collision_height, collision_radius * 2.0)
		for i in positions.size():
			var pos := world_pos[i]
			# Box centred half its height above the ground so it rests on it.
			var box_xform := Transform3D(Basis.IDENTITY,
				Vector3(pos.x, pos.y + collision_height * 0.5, pos.z))
			PhysicsServer3D.body_add_shape(body.get_rid(), _collision_shape.get_rid(), box_xform)


# Deterministic yaw in [0, TAU) from the world XZ position.
func _yaw_for(pos: Vector3) -> float:
	var h := hash(Vector2i(roundi(pos.x * 13.0), roundi(pos.z * 13.0)))
	return float(h % 3600) / 3600.0 * TAU
