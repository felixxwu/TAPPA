class_name BillboardField
extends Node3D
# Renders scattered positions as cylindrical billboards, using a caller-supplied
# texture. Each instance is lifted onto the terrain via TerrainManager.height_at;
# the quad pivot is its bottom edge so sprites sit on the ground. When
# with_collision is true, a child StaticBody3D carries one box hitbox per instance,
# all sharing a single BoxShape3D resource instanced via the physics server. Used
# for both trees (with collision) and bushes (without).
#
# Instances are spatially BINNED into one MultiMesh per grid cell (mirrors
# TreeMeshField). A single field-wide MultiMesh submits and vertex-processes EVERY
# billboard every frame regardless of the camera — a field-wide visibility_range
# would gate them all at once, and its one big AABB is always on-screen so the
# engine never frustum-culls it. Per-bin MultiMeshInstance3Ds each have a compact
# AABB centred on the bin, so far bins are frustum-culled AND dropped past
# `visibility_range_end` — no vertex work for foliage the camera can't see, at one
# draw call per visible bin. Instance transforms are bin-local (the billboard
# shader reads each instance's world origin from MODEL_MATRIX[3], which stays
# correct = bin centre + local).

const BILLBOARD_SHADER := preload("res://shaders/billboard.gdshader")
const BILLBOARD_OPAQUE_SHADER := preload("res://shaders/billboard_opaque.gdshader")

# Held so the shape RID added to the body via PhysicsServer3D stays alive for
# the body's lifetime. Null when built without collision.
var _collision_shape: BoxShape3D

# The shared obstacle StaticBody3D (null without collision). Kept so knock_down()
# can disable one instance's box in place via the physics server.
var _collision_body: StaticBody3D

# True when this field renders the opaque tree path (silhouette card + opaque
# shader). Only that path is fellable: its shader honours the instance rotation,
# so a topple tilt shows; the legacy quad path ignores the basis. Set in build().
var _use_opaque: bool = false

# Minimum per-instance size multiplier for the opaque path: each tree is scaled by a
# deterministic random factor in [_size_jitter_min, 1.0] (hashed off its position), so
# a stand varies in height. 1.0 means no jitter (every instance at full authored size).
# Set in build(); recomputed in _upright_basis so felling restores the same size.
var _size_jitter_min: float = 1.0

# Per-instance ASPECT jitter amplitude for the opaque path: on top of the uniform size
# factor, width (x/z) and height (y) each get their own deterministic random multiplier
# in [1 - _aspect_jitter, 1 + _aspect_jitter] (independent hashes), so some trees read
# taller-and-narrower and others shorter-and-wider. 0.0 disables it (pure size jitter).
# Set in build(); recomputed in _upright_basis so felling restores the same shape.
var _aspect_jitter: float = 0.0

# Global instance index -> where that instance lives in the binned MultiMeshes, so
# a single struck tree can be found and animated. build() bins instances (reordering
# them away from build order), so this map is the bridge back. Each entry:
#   {"mmi": MultiMeshInstance3D, "mm": MultiMesh, "j": int, "base_pos": Vector3, "centre": Vector3}
# The shape index reported for a contact equals the global instance index (shapes
# are added in build order by ObstacleBody), which is the key here.
var _slot_of: Dictionary = {}

# Felling bookkeeping (see TreeMeshField for the mirror). _fallen: idx -> true
# (idempotent set). _falling: active tilts, each a duplicated _slot_of entry plus
# {"axis", "elapsed", "duration"}.
var _fallen: Dictionary = {}
var _falling: Array = []

# The shared render mesh (quad or supplied silhouette), instanced by every bin.
# Exposed so headless tests can read the mesh/material without a live MultiMesh
# buffer (which the RenderingServer stubs out under --headless).
var render_mesh: Mesh

# Number of per-bin MultiMeshInstance3D children created (for tests/inspection).
var bin_count: int = 0

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
		y_offset: float = 0.0, mesh: Mesh = null, opaque: bool = false,
		size_jitter_min: float = 1.0, aspect_jitter: float = 0.0) -> void:
	# Two render paths share this field:
	#  - Quad + alpha-cutout shader (mesh == null): the classic sprite billboard.
	#  - Supplied silhouette mesh + opaque shader (mesh != null and opaque): the
	#    tree cutout baked into geometry, no discard (early-Z friendly). The mesh
	#    is normalized (x in [-0.5,0.5], y in [0,1]); size is carried as per-
	#    instance scale so the opaque shader reads it from MODEL_MATRIX.
	var use_opaque := mesh != null and opaque
	_use_opaque = use_opaque
	_size_jitter_min = clampf(size_jitter_min, 0.0, 1.0)
	# Clamp below 1.0 so 1 - _aspect_jitter stays positive (no zero/negative scale).
	_aspect_jitter = clampf(aspect_jitter, 0.0, 0.9)
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
	# The opaque tree cutout dissolves near the camera (same dither as the 3D canopy)
	# so a tree the camera pushes inside stops blocking the view — the quad path uses
	# its own alpha-cutout distance fade and has no such uniforms.
	if use_opaque:
		mat.set_shader_parameter("near_fade_start", Config.data.tree_near_fade_start_m)
		mat.set_shader_parameter("near_fade_end", Config.data.tree_near_fade_end_m)
	# A supplied silhouette mesh can be empty (0 surfaces) if its source texture
	# had no opaque area; skip material assignment then (the field renders nothing)
	# rather than indexing a missing surface.
	if render_mesh.get_surface_count() > 0:
		render_mesh.surface_set_material(0, mat)

	instance_positions = PackedVector3Array()
	instance_positions.resize(positions.size())

	# Opaque path scales the normalized mesh by size; quad path bakes size in.
	# The opaque mesh is a "+" cross, so its Z (the second plane) scales with the
	# horizontal size.x just like X.
	instance_scale = Vector3(size.x, size.y, size.x) if use_opaque else Vector3.ONE

	# World positions in build (caller) order — the collision shapes are added in
	# this order too, so a contact's shape index == the global instance index.
	for i in positions.size():
		var p := positions[i]
		# y_offset sinks the sprite into the ground (negative) to hide a gap at
		# the bottom of its texture, or lifts it (positive).
		var y := terrain.height_at(p.x, p.y) + y_offset
		instance_positions[i] = Vector3(p.x, y, p.y)

	# Bin instances into one MultiMesh per grid cell (Vector2i -> global indices).
	var bin := maxf(Config.data.tree_bin_size_m, 1.0)
	var bins := SpatialGrid.of_indices(positions, bin)
	for key: Vector2i in bins:
		var idxs: PackedInt32Array = bins[key]
		# Bin centre; instance transforms are bin-local so the compact per-bin AABB
		# lets the engine frustum-cull / visibility-cull each bin on its own.
		var centre := Vector3((float(key.x) + 0.5) * bin, 0.0, (float(key.y) + 0.5) * bin)

		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		# The opaque tree path carries a per-instance FELLED flag in custom data
		# (INSTANCE_CUSTOM.x): 0 while standing (shader billboards a single card), 1
		# once knocked over (shader locks the full "+" cross and topples it). The quad
		# path doesn't read custom data, so only enable it for the opaque path.
		mm.use_custom_data = use_opaque
		mm.mesh = render_mesh
		mm.instance_count = idxs.size()

		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.position = centre

		for j in idxs.size():
			var gi := idxs[j]
			var pos := instance_positions[gi]
			# Trees billboard toward the camera in the shader, so the instance basis
			# carries only the authored size scale (rotation stays identity) — no
			# per-instance yaw, which would pre-rotate the card off the camera. A felled
			# tree's topple tilt is applied on top of this identity basis later.
			var xform_basis := Basis.IDENTITY
			if use_opaque:
				xform_basis = Basis.IDENTITY.scaled(_instance_scale(pos))
			mm.set_instance_transform(j, Transform3D(xform_basis, pos - centre))
			if use_opaque:
				mm.set_instance_custom_data(j, Color(0.0, 0.0, 0.0, 0.0))
			# Bridge the global index (== shape index) back to its binned slot so
			# knock_down / reset_fallen can find and animate the one struck tree.
			_slot_of[gi] = {"mmi": mmi, "mm": mm, "j": j, "base_pos": pos, "centre": centre}

		# Far cull + dither-fade: far bins stop drawing (and their instances stop
		# being vertex-processed) past this range. Shared with the foliage/props
		# render distance.
		mmi.visibility_range_end = render_distance
		mmi.visibility_range_end_margin = render_fade
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		add_child(mmi)
	bin_count = bins.size()

	# One StaticBody3D holds every hitbox; all share one BoxShape3D resource instanced
	# per position (cheap: one shape, N transforms). Skipped when with_collision is false.
	if with_collision:
		_collision_shape = ObstacleBody.build(self, instance_positions, collision_radius, collision_height)
		_collision_body = get_node_or_null("Collision") as StaticBody3D

	# Nothing falling at first — only tick _process once a tree is actually felled.
	set_process(false)


# The deterministic per-instance size multiplier in [_size_jitter_min, 1.0], hashed
# off the instance's world XZ so the same position always yields the same size (build
# and felling-restore agree). Returns 1.0 when jitter is disabled (_size_jitter_min ==
# 1.0). Only the opaque tree path calls this.
func _size_factor(pos: Vector3) -> float:
	if _size_jitter_min >= 1.0:
		return 1.0
	var r := ScatterMath.hash01(int(round(pos.x)), int(round(pos.z)), 0, 11)
	return lerpf(_size_jitter_min, 1.0, r)


# The full per-instance scale (x, y, z) build() bakes into the instance basis for the
# opaque path: the authored size (instance_scale) times the uniform size factor, times
# an independent ASPECT stretch on width (x/z) and height (y). Deterministic per world
# XZ (distinct hash salts 13/17) so build and felling-restore agree. The cross's Z
# (second plane) tracks width just like X.
func _instance_scale(pos: Vector3) -> Vector3:
	var scale := instance_scale * _size_factor(pos)
	if _aspect_jitter <= 0.0:
		return scale
	# Each axis: 1 + (rand in [-1, 1]) * amplitude -> [1 - k, 1 + k], independent x/y.
	var ax := 1.0 + (ScatterMath.hash01(int(round(pos.x)), int(round(pos.z)), 0, 13) * 2.0 - 1.0) * _aspect_jitter
	var ay := 1.0 + (ScatterMath.hash01(int(round(pos.x)), int(round(pos.z)), 0, 17) * 2.0 - 1.0) * _aspect_jitter
	return Vector3(scale.x * ax, scale.y * ay, scale.z * ax)


# Public: the per-instance size multiplier for collision shape / instance `idx`
# (shape index == global instance index; instance_positions stays in build order
# even though rendering is binned). Mirrors the size the opaque tree path bakes into
# the instance basis. Returns 1.0 for a bad index or when jitter is disabled. Used
# by car.gd to scale felling + plough-through.
func size_factor(idx: int) -> float:
	if idx < 0 or idx >= instance_positions.size():
		return 1.0
	return _size_factor(instance_positions[idx])


# The upright instance basis build() authored for the instance at world `pos`, so a
# fall animation can rebuild the transform. Mirrors the build() loop: the opaque
# tree path is identity rotation + authored size scale (the shader billboards it);
# the legacy quad path is identity (and not fellable — see _use_opaque).
func _upright_basis(pos: Vector3) -> Basis:
	if not _use_opaque:
		return Basis.IDENTITY
	# Identity rotation + authored size scale (times the per-instance jitter factor);
	# the shader yaws the card to the camera, so there is no authored yaw to restore.
	# A topple tilt is composed on top of this in _process / knock_down.
	return Basis.IDENTITY.scaled(_instance_scale(pos))


# Fell instance `idx`, toppling it in horizontal unit direction `dir` over
# `duration` seconds — the BillboardField twin of TreeMeshField.knock_down. Disables
# the hitbox in place (next step, so the car still stops now) and tilts the cross to
# the ground. Idempotent; a no-op without collision, off the opaque path, or on a
# bad index.
func knock_down(idx: int, dir: Vector3, duration: float) -> void:
	if _collision_body == null or not _use_opaque:
		return
	if _fallen.has(idx) or not _slot_of.has(idx):
		return
	# Disable in place — body_remove_shape would shift every higher shape index and
	# break the shape-index -> instance-index mapping this relies on.
	PhysicsServer3D.body_set_shape_disabled(_collision_body.get_rid(), idx, true)
	var slot: Dictionary = _slot_of[idx]
	# Flip the FELLED flag so the shader locks this instance into the "+" cross and
	# stops billboarding it — the topple below then tilts the fixed cross.
	(slot["mm"] as MultiMesh).set_instance_custom_data(slot["j"], Color(1.0, 0.0, 0.0, 0.0))
	_fallen[idx] = true
	# Copy the slot (mm / j / base_pos / centre) and layer on the per-fall animation.
	var rec: Dictionary = slot.duplicate()
	rec["axis"] = TreeFall.topple_axis(dir)
	rec["elapsed"] = 0.0
	rec["duration"] = maxf(duration, 0.0)
	_falling.append(rec)
	set_process(true)


# True once instance `idx` has been felled (hitbox disabled, toppling or flat).
func is_fallen(idx: int) -> bool:
	return _fallen.has(idx)


# Stand every felled instance back up: re-enable its hitbox and restore its MultiMesh
# transform to the upright pose build() authored. The BillboardField twin of
# TreeMeshField.reset_fallen — used to reset the stage before the replay. Only touches
# felled instances, so a stand with nothing knocked over costs nothing.
func reset_fallen() -> void:
	if _fallen.is_empty():
		return
	for idx: int in _fallen:
		if not _slot_of.has(idx):
			continue
		if _collision_body != null:
			PhysicsServer3D.body_set_shape_disabled(_collision_body.get_rid(), idx, false)
		var slot: Dictionary = _slot_of[idx]
		var pos: Vector3 = slot["base_pos"]
		var mm: MultiMesh = slot["mm"]
		mm.set_instance_transform(slot["j"], Transform3D(_upright_basis(pos), pos - (slot["centre"] as Vector3)))
		# Back to standing: clear the FELLED flag so the shader billboards it again.
		mm.set_instance_custom_data(slot["j"], Color(0.0, 0.0, 0.0, 0.0))
	_fallen.clear()
	_falling.clear()
	set_process(false)


func _process(delta: float) -> void:
	var still_active: Array = []
	for rec: Dictionary in _falling:
		rec["elapsed"] += delta
		var angle := TreeFall.fall_angle(rec["elapsed"], rec["duration"])
		# Tilt about the base (the instance origin, at ground level) from upright.
		var b := Basis(rec["axis"], angle) * _upright_basis(rec["base_pos"])
		var mm: MultiMesh = rec["mm"]
		mm.set_instance_transform(rec["j"], Transform3D(b, (rec["base_pos"] as Vector3) - (rec["centre"] as Vector3)))
		if rec["elapsed"] < rec["duration"]:
			still_active.append(rec)
	_falling = still_active
	if _falling.is_empty():
		set_process(false)
