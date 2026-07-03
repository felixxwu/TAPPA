class_name TreeMeshField
extends Node3D
# Renders scattered foliage positions as solid low-poly 3D meshes (the opaque-mesh
# direction from todo/performance-optimisations.md item 2), replacing the old
# alpha-cutout billboards. Used for BOTH trees (with collision) and the
# ground-cover bushes (without) — see the build() flags.
#
# Instances are spatially BINNED into one MultiMesh per grid cell. A single
# field-wide MultiMesh can't auto-LOD or visibility-cull usefully: Godot picks a
# single mesh LOD for the whole MultiMesh (by its overall AABB) and a field-wide
# visibility_range would gate every instance at once. Per-bin MultiMeshInstance3Ds
# each have a compact AABB centred on the bin, so the engine drops far bins to
# the importer-generated mesh LODs and fades them out past
# `visibility_range_end` — auto-LOD "takes place" for further foliage, at one draw
# call per visible bin.
#
# When with_collision is true a shared StaticBody3D carries a box hitbox per
# instance: one BoxShape3D resource, N transforms via the physics server. When
# bake_terrain_light is true each instance is tinted by the terrain's baked light
# at its position (per-instance MultiMesh colour); the mesh's material must enable
# vertex_color_use_as_albedo to pick it up (the bushes do, so they match the
# ground tint everywhere, as the old foliage shader did).

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
		with_collision: bool = true, bake_terrain_light: bool = false) -> void:
	instance_positions = PackedVector3Array()
	instance_positions.resize(positions.size())

	# Uniform scale so the model's height matches the configured height (keeps
	# proportions — a 3D mesh must not be stretched like a billboard quad).
	var uscale := uniform_scale_for(mesh, target_height)
	instance_scale = uscale

	var bin := maxf(bin_size, 1.0)
	var world_pos := PackedVector3Array()
	world_pos.resize(positions.size())
	for i in positions.size():
		var p := positions[i]
		var pos := Vector3(p.x, terrain.height_at(p.x, p.y), p.y)
		instance_positions[i] = pos
		world_pos[i] = pos
	# Vector2i -> PackedInt32Array of instance indices, one MultiMesh per bin.
	var bins := SpatialGrid.of_indices(positions, bin)

	# One MultiMesh per bin, positioned at the bin centre so visibility_range /
	# LOD distance is measured from there (instance transforms are bin-local).
	for key: Vector2i in bins:
		var idxs: PackedInt32Array = bins[key]
		var centre := Vector3((float(key.x) + 0.5) * bin, 0.0, (float(key.y) + 0.5) * bin)

		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = bake_terrain_light  # must be set before instance_count
		mm.mesh = mesh
		mm.instance_count = idxs.size()
		for j in idxs.size():
			var pos := world_pos[idxs[j]]
			# Deterministic per-instance yaw so the cluster doesn't look cloned.
			var yaw := _yaw_for(pos)
			var xf_basis := Basis(Vector3.UP, yaw).scaled(Vector3(uscale, uscale, uscale))
			mm.set_instance_transform(j, Transform3D(xf_basis, pos - centre))
			if bake_terrain_light:
				# Tint by the terrain's baked light so ground cover matches the ground.
				mm.set_instance_color(j, terrain.light_at(pos.x, pos.z))

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

	# One StaticBody3D with a box per instance (obstacle for the car's damage
	# model). Skipped for scenery-only fields: the HQ tree ring and the
	# non-colliding ground-cover bushes.
	if with_collision and positions.size() > 0:
		_collision_shape = ObstacleBody.build(self, world_pos, collision_radius, collision_height)


# Uniform scale that makes `mesh` stand `target_height` tall (the same scale
# build() applies). 1.0 if the mesh has no height.
static func uniform_scale_for(mesh: Mesh, target_height: float) -> float:
	var ah := mesh.get_aabb().size.y
	return target_height / ah if ah > 0.0001 else 1.0


# World-space XZ radius of one instance once scaled to `target_height` — half the
# larger horizontal AABB extent. Used by callers to keep a wide mesh (e.g. the
# ground-cover bush) clear of the road at any yaw.
static func xz_radius(mesh: Mesh, target_height: float) -> float:
	var a := mesh.get_aabb()
	return maxf(a.size.x, a.size.z) * 0.5 * uniform_scale_for(mesh, target_height)


# Deterministic yaw in [0, TAU) from the world XZ position.
func _yaw_for(pos: Vector3) -> float:
	var h := hash(Vector2i(roundi(pos.x * 13.0), roundi(pos.z * 13.0)))
	return float(h % 3600) / 3600.0 * TAU
