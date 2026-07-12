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

# The shared obstacle StaticBody3D (null without collision). Kept so knock_down()
# can disable one instance's box in place via the physics server.
var _collision_body: StaticBody3D

# True when this field renders the opaque cross path (trees). Only that path is
# fellable — the quad path is camera-billboarded by its shader, so tilting the
# transform basis wouldn't show. Set in build().
var _use_opaque: bool = false

# Felling bookkeeping (see TreeMeshField for the mirror). Unlike TreeMeshField this
# is ONE unbinned MultiMesh, so the instance index IS the build/shape index — no
# slot map needed. _fallen: idx -> true (idempotent set). _falling: active tilts,
# each {"idx", "base_pos", "yaw", "axis", "elapsed", "duration"}.
var _fallen: Dictionary = {}
var _falling: Array = []

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
	_use_opaque = use_opaque
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
	# The opaque mesh is a "+" cross, so its Z (the second plane) scales with the
	# horizontal size.x just like X.
	instance_scale = Vector3(size.x, size.y, size.x) if use_opaque else Vector3.ONE

	for i in positions.size():
		var p := positions[i]
		# y_offset sinks the sprite into the ground (negative) to hide a gap at
		# the bottom of its texture, or lifts it (positive).
		var y := terrain.height_at(p.x, p.y) + y_offset
		var pos := Vector3(p.x, y, p.y)
		instance_positions[i] = pos
		# The cross no longer faces the camera, so give each tree a deterministic
		# random yaw about Y (hashed off its position) — otherwise every "+" would
		# align to the same axes and the stand would look like a grid. The quad
		# path keeps its identity basis (that shader still billboards).
		var basis := Basis.IDENTITY
		if use_opaque:
			var yaw := ScatterMath.hash01(int(round(p.x)), int(round(p.y)), 0, 7) * TAU
			basis = Basis(Vector3.UP, yaw).scaled(instance_scale)
		mm.set_instance_transform(i, Transform3D(basis, pos))

	# One StaticBody3D holds every hitbox; all share one BoxShape3D resource instanced
	# per position (cheap: one shape, N transforms). Skipped when with_collision is false.
	if with_collision:
		_collision_shape = ObstacleBody.build(self, instance_positions, collision_radius, collision_height)
		_collision_body = get_node_or_null("Collision") as StaticBody3D

	multimesh = mm
	# Nothing falling at first — only tick _process once a tree is actually felled.
	set_process(false)


# The upright instance basis build() authored for the instance at world `pos`, so a
# fall animation can rebuild the transform. Mirrors the build() loop: the opaque
# cross carries a deterministic per-instance yaw + the authored size scale; the quad
# path is identity (and not fellable — see _use_opaque).
func _upright_basis(pos: Vector3) -> Basis:
	if not _use_opaque:
		return Basis.IDENTITY
	var yaw := ScatterMath.hash01(int(round(pos.x)), int(round(pos.z)), 0, 7) * TAU
	return Basis(Vector3.UP, yaw).scaled(instance_scale)


# Fell instance `idx`, toppling it in horizontal unit direction `dir` over
# `duration` seconds — the BillboardField twin of TreeMeshField.knock_down. Disables
# the hitbox in place (next step, so the car still stops now) and tilts the cross to
# the ground. Idempotent; a no-op without collision, off the opaque path, or on a
# bad index.
func knock_down(idx: int, dir: Vector3, duration: float) -> void:
	if _collision_body == null or not _use_opaque:
		return
	if _fallen.has(idx) or idx < 0 or idx >= instance_positions.size():
		return
	# Disable in place — body_remove_shape would shift every higher shape index and
	# break the shape-index -> instance-index mapping this relies on.
	PhysicsServer3D.body_set_shape_disabled(_collision_body.get_rid(), idx, true)
	_fallen[idx] = true
	_falling.append({
		"idx": idx, "base_pos": instance_positions[idx],
		"axis": TreeFall.topple_axis(dir),
		"elapsed": 0.0, "duration": maxf(duration, 0.0),
	})
	set_process(true)


# True once instance `idx` has been felled (hitbox disabled, toppling or flat).
func is_fallen(idx: int) -> bool:
	return _fallen.has(idx)


func _process(delta: float) -> void:
	var still_active: Array = []
	for rec: Dictionary in _falling:
		rec["elapsed"] += delta
		var angle := TreeFall.fall_angle(rec["elapsed"], rec["duration"])
		# Tilt about the base (the instance origin, at ground level) from upright.
		var b := Basis(rec["axis"], angle) * _upright_basis(rec["base_pos"])
		multimesh.set_instance_transform(rec["idx"], Transform3D(b, rec["base_pos"]))
		if rec["elapsed"] < rec["duration"]:
			still_active.append(rec)
	_falling = still_active
	if _falling.is_empty():
		set_process(false)
