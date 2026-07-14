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
# at its position (per-instance MultiMesh colour); the mesh's material must consume
# that instance COLOR to pick it up (the bush material's foliage dissolve shader
# multiplies by COLOR, so bushes match the ground tint everywhere).

# Held so the shape RID added to the body stays alive for the body's lifetime.
var _collision_shape: BoxShape3D

# The shared obstacle StaticBody3D (null for scenery-only fields with no collision).
# Kept so knock_down() can disable one tree's box in place via the physics server.
var _collision_body: StaticBody3D

# Global tree index -> where that instance lives in the binned MultiMeshes, so a
# single struck tree can be found and animated. build() bins instances (reordering
# them away from build order), so this map is the bridge back. Each entry:
#   {"mmi": MultiMeshInstance3D, "j": int, "base_pos": Vector3, "centre": Vector3}
# The shape index reported for a contact equals the global tree index (shapes are
# added in build order; see ObstacleBody), which is the key here.
var _slot_of: Dictionary = {}

# Set of already-felled tree indices (used as a set: idx -> true). knock_down is
# idempotent against this so a sustained crash fells a tree only once.
var _fallen: Dictionary = {}

# Active fall animations, one record per still-toppling tree; drained as each
# reaches flat so a settled forest costs nothing in _process. Each entry:
#   {"mmi", "j", "base_pos", "centre", "yaw", "axis", "elapsed", "duration"}
var _falling: Array = []

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

		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.position = centre

		for j in idxs.size():
			var pos := world_pos[idxs[j]]
			# Deterministic per-instance yaw so the cluster doesn't look cloned.
			var yaw := _yaw_for(pos)
			var xf_basis := Basis(Vector3.UP, yaw).scaled(Vector3(uscale, uscale, uscale))
			mm.set_instance_transform(j, Transform3D(xf_basis, pos - centre))
			if bake_terrain_light:
				# Tint by the terrain's baked light so ground cover matches the ground.
				mm.set_instance_color(j, terrain.light_at(pos.x, pos.z))
			# Remember where each global instance lives (and its standing yaw) so
			# knock_down() can find and animate the one struck tree without recomputing
			# it — build() bins away from build order.
			_slot_of[idxs[j]] = {
				"mmi": mmi, "j": j, "base_pos": pos, "centre": centre, "yaw": yaw}

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
		_collision_body = get_node_or_null("Collision") as StaticBody3D
	# Nothing falling at first — only tick _process once a tree is actually felled.
	set_process(false)


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


# Fell tree `idx`, toppling it in horizontal unit direction `dir` (the car's
# travel direction) over `duration` seconds. The hitbox is disabled immediately;
# because the physics server applies that next step, the car still stops against
# the tree on the impact frame, and the now-hitboxless tree tilts to the ground so
# you can drive on through where it stood. Idempotent: felling an already-felled
# tree (or an unknown/collision-less idx) is a safe no-op.
func knock_down(idx: int, dir: Vector3, duration: float) -> void:
	# No hitbox to remove (scenery-only field) or nothing to animate -> no-op.
	if _collision_body == null or _fallen.has(idx) or not _slot_of.has(idx):
		return
	# Disable in place — body_remove_shape would shift every higher shape index and
	# break the shape-index -> tree-index mapping knock_down relies on.
	PhysicsServer3D.body_set_shape_disabled(_collision_body.get_rid(), idx, true)
	_fallen[idx] = true
	# The slot already carries mmi / j / base_pos / centre / yaw from build(); copy it
	# and layer on the per-fall animation state.
	var rec: Dictionary = (_slot_of[idx] as Dictionary).duplicate()
	rec["axis"] = TreeFall.topple_axis(dir)
	rec["elapsed"] = 0.0
	rec["duration"] = maxf(duration, 0.0)
	_falling.append(rec)
	set_process(true)


# True once tree `idx` has been felled (hitbox disabled, toppling or flat).
func is_fallen(idx: int) -> bool:
	return _fallen.has(idx)


# Stand every felled tree back up: re-enable its hitbox and restore its MultiMesh
# instance to the upright pose recorded in _slot_of at build (base_pos + standing
# yaw). Used to reset the stage between the driven run and the replay so the replay
# shows an intact forest. Only touches trees in the _fallen set, so a stage with
# nothing knocked over costs nothing (the common case).
func reset_fallen() -> void:
	if _fallen.is_empty():
		return
	var s := Vector3(instance_scale, instance_scale, instance_scale)
	for idx: int in _fallen:
		if not _slot_of.has(idx):
			continue
		var slot: Dictionary = _slot_of[idx]
		if _collision_body != null:
			PhysicsServer3D.body_set_shape_disabled(_collision_body.get_rid(), idx, false)
		var upright := Basis(Vector3.UP, slot["yaw"]).scaled(s)
		var mmi: MultiMeshInstance3D = slot["mmi"]
		mmi.multimesh.set_instance_transform(
			slot["j"], Transform3D(upright, slot["base_pos"] - slot["centre"]))
	_fallen.clear()
	_falling.clear()
	# Every tree is upright again; nothing to animate.
	set_process(false)


func _process(delta: float) -> void:
	var s := Vector3(instance_scale, instance_scale, instance_scale)
	var still_active: Array = []
	for rec: Dictionary in _falling:
		rec["elapsed"] += delta
		var angle := TreeFall.fall_angle(rec["elapsed"], rec["duration"])
		# Tilt about the trunk base (the instance origin) from the standing basis.
		var tilt := Basis(rec["axis"], angle) * Basis(Vector3.UP, rec["yaw"]).scaled(s)
		var mmi: MultiMeshInstance3D = rec["mmi"]
		mmi.multimesh.set_instance_transform(
			rec["j"], Transform3D(tilt, rec["base_pos"] - rec["centre"]))
		if rec["elapsed"] < rec["duration"]:
			still_active.append(rec)
	_falling = still_active
	# A settled forest costs nothing: stop ticking once every fall has landed.
	if _falling.is_empty():
		set_process(false)


# Deterministic yaw in [0, TAU) from the world XZ position — same seeded hash the
# billboard field uses (scripts/billboard_field.gd) so both scatter schemes share one
# deterministic source.
func _yaw_for(pos: Vector3) -> float:
	return ScatterMath.hash01(int(round(pos.x)), int(round(pos.z)), 0, 7) * TAU
