class_name SignField
extends Node3D
# Builds the physical roadside signs from a SignLayout plan (todo/roadside-signs.md
# §3/§4). Each sign is a free-standing A-frame ("wet-floor" board): two thin panels
# joined at a top ridge and splayed apart at the bottom, oriented so the large
# faces point up-track / down-track and read for an approaching driver.
#
# RENDERING: signs at rest are drawn by one MultiMeshInstance3D per distinct face
# material (texture key) — two panel instances per sign — so the whole field costs
# a handful of draw calls instead of two MeshInstance3Ds per sign. A sign only
# becomes an individually-rendered node when the car knocks it over: _wake_sign
# zero-scales its MultiMesh instances and attaches real panel meshes to the body,
# which then tumbles under physics. Knocked signs are few, so the swap is cheap.
#
# Each sign is a light RigidBody3D, but it behaves like a knocked spectator rather
# than a solid prop: it never runs real collision physics against the car. It lives
# on its own collision layer (off the car's mask) and masks only the world layer
# (terrain + trees), so the car drives straight through it. On contact the car's
# waker Area flings the sign along the car's travel direction — a fake collision —
# and from there it tumbles on the terrain under physics, masked off the car (see
# SpectatorGroup, which does the same for ragdolls). This keeps the wet-floor-board
# scatter feel without the vehicle ever bogging down on the prop.
# Signs are deliberately NOT in the damage OBSTACLE_GROUP: they are cosmetic clutter
# you plough through freely, with no HP penalty (unlike the solid trees/bushes). A
# RigidBody sleeps once it settles, so the at-rest cost is negligible despite there
# being one body per sign.

const SIGN_SHADER := preload("res://shaders/ps1_models.gdshader")

# Per-kind colour used when no atlas texture is wired for a sign — keeps the
# geometry visible and testable before the art lands (todo/roadside-signs.md §3).
const FALLBACK_COLORS := {
	"sector": Color(0.95, 0.82, 0.18),  # amber sector boards
	"turn": Color(0.90, 0.35, 0.10),    # orange turn arrows
	"start": Color(0.25, 0.80, 0.35),   # green start
	"finish": Color(0.92, 0.92, 0.92),  # white finish
}

# Number of signs built — a renderer-independent count for headless tests (mirrors
# BillboardField.instance_positions; child nodes exist regardless, but this is the
# explicit contract).
var sign_count := 0

# Launch params (knock_*) snapshot from sign_render_params(), used by _wake_sign to
# fling a struck sign along the car's velocity. Stashed at build so the waker callback
# doesn't need them threaded through.
var _knock := {}
var _rng := RandomNumberGenerator.new()

# Panel geometry snapshot from build(), used by _wake_sign to attach real panel
# meshes to a knocked body.
var _panel_size: Vector2
var _thickness: float
var _splay: float
# texture_key -> shared ShaderMaterial (one MultiMesh per material, so panels of
# the same face texture batch into one draw).
var _materials := {}
# body -> {"mm": MultiMesh, "indices": PackedInt32Array, "mat": ShaderMaterial}
# — how to find (and later hide) a resting sign's MultiMesh panel instances.
var _rendered := {}


# Build one sign per layout entry. `params` is GameConfig.sign_render_params().
func build(layout: Array, terrain: TerrainManager, params: Dictionary) -> void:
	var panel_size: Vector2 = params["panel_size_m"]
	var thickness: float = params["thickness_m"]
	var splay := deg_to_rad(float(params["splay_deg"]))
	var edge_inset: float = params["edge_inset_m"]
	var base_depth: float = params["base_depth_m"]
	var mass: float = params["mass_kg"]
	var textures: Dictionary = params.get("textures", {})
	var half_w: float = float(params["track_width"]) / 2.0
	_knock = params
	_rng.seed = 0
	_panel_size = panel_size
	_thickness = thickness
	_splay = splay
	# material -> Array of {body, xform} panel instances, collected while placing
	# bodies, then baked into one MultiMesh per material below.
	var batches := {}

	for entry in layout:
		var pos: Vector2 = entry["pos"]
		var tangent: Vector2 = entry["tangent"]
		var side: int = entry["side"]
		# Perpendicular to the road, toward the chosen edge; inset so the base sits
		# on the flat road rather than the sloped verge.
		var perp := Vector2(-tangent.y, tangent.x)
		var edge := pos + side * perp * (half_w - edge_inset)
		# Centerline surface height = the flat road height at this arc position
		# (the road band is flattened to the centerline; see TerrainManager).
		var y := terrain.height_at(pos.x, pos.y)

		# The sign IS a light RigidBody3D — panels + hitbox are its children, so it
		# tumbles as one when the car clips it. NOT in OBSTACLE_GROUP (no HP damage).
		var sign_body := RigidBody3D.new()
		sign_body.name = "Sign%d" % sign_count
		sign_body.mass = mass
		# Spawn FROZEN, resting exactly at the placed road-surface pose. The terrain
		# only has collision in a small ring streamed around the car (TerrainManager
		# RADIUS), so a live RigidBody placed on a far part of the track would have no
		# ground and free-fall into the void before the player ever reached it. Frozen,
		# it stays put; the car wakes it on contact (_wake_sign) so it still scatters.
		sign_body.freeze = true
		sign_body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
		# Live on a private layer (off the car's mask) and mask only the world layer
		# (terrain + trees) — so the car never collides with the sign. It still rolls on
		# the ground; the car just drives through it. The car shares the world layer, so
		# _wake_sign also adds an explicit exception once it has the car reference.
		sign_body.collision_layer = int(params["knock_layer"])
		sign_body.collision_mask = int(params["knock_mask"])
		# Stash the placement key on the body (cheap metadata) so tools/tests can
		# identify which arrow a built sign carries without re-running the planner.
		sign_body.set_meta("texture_key", String(entry["texture_key"]))
		# -Z runs along the road tangent; ridge (local X) crosses the road. This is
		# the resting pose; physics takes over from here once the car hits it.
		var fwd3 := Vector3(tangent.x, 0.0, tangent.y).normalized()
		sign_body.transform = Transform3D(Basis.looking_at(fwd3, Vector3.UP),
			Vector3(edge.x, y, edge.y))
		add_child(sign_body)

		# Materials are shared per texture key so panels with the same face batch
		# into one MultiMesh (and one draw call).
		var key := String(entry["texture_key"])
		if not _materials.has(key):
			_materials[key] = _material_for(String(entry["kind"]), key, textures)
		var mat: ShaderMaterial = _materials[key]
		if not batches.has(mat):
			batches[mat] = []
		for local in _panel_transforms():
			batches[mat].append({"body": sign_body, "xform": sign_body.transform * local})
		_add_collision_shape(sign_body, panel_size, base_depth)
		_add_waker(sign_body, panel_size, base_depth)
		sign_count += 1

	_build_multimeshes(batches)


# One MultiMeshInstance3D per face material, holding every resting sign's two
# panels. Records each body's instance indices so _wake_sign can hide them.
func _build_multimeshes(batches: Dictionary) -> void:
	var mesh := _panel_mesh(_panel_size, _thickness)
	for mat in batches:
		var items: Array = batches[mat]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = items.size()
		for i in items.size():
			mm.set_instance_transform(i, items[i]["xform"])
			var body: RigidBody3D = items[i]["body"]
			if not _rendered.has(body):
				# A plain Array, NOT a packed array: packed arrays are value types,
				# so appending through the dictionary would mutate a copy.
				_rendered[body] = {"mm": mm, "indices": [], "mat": mat}
			(_rendered[body]["indices"] as Array).append(i)
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = mat
		add_child(mmi)


# The two panel poses of the A-frame, local to the sign body (see _add_panels).
func _panel_transforms() -> Array[Transform3D]:
	var h := _panel_size.y
	var out: Array[Transform3D] = []
	for d in [1, -1]:
		out.append(Transform3D(
			Basis(Vector3.RIGHT, -d * _splay),
			Vector3(0.0, (h * 0.5) * cos(_splay), d * (h * 0.5) * sin(_splay))))
	return out


# An Area3D, slightly larger than the sign, that wakes the frozen body when the car
# reaches it (a frozen RigidBody never reports its own contacts, so a trigger volume
# is the reliable way to detect the hit). Sized a touch bigger than the hitbox so the
# sign goes dynamic just before the car touches it — it scatters on contact instead
# of briefly standing rigid. Static bodies (streamed terrain chunks, tree hitboxes)
# share the world layer, so they are filtered out: only the dynamic car wakes a sign.
func _add_waker(body: RigidBody3D, panel_size: Vector2, base_depth: float) -> void:
	var waker := Area3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(panel_size.x + 0.6, panel_size.y, base_depth + 0.6)
	shape.shape = box
	shape.position = Vector3(0.0, panel_size.y * 0.5, 0.0)
	waker.add_child(shape)
	waker.body_entered.connect(_wake_sign.bind(body))
	body.add_child(waker)


# Knock a frozen sign over the first time the car enters its trigger volume. The body
# never collides with the car (different layer + an explicit exception added here); a
# frozen RigidBody also never reports its own contacts, so the waker Area is the only
# hit signal. Rather than let real physics push it, we fling it along the car's travel
# direction — a fake collision — then it tumbles on the terrain on its own. The Area
# also overlaps the sign's OWN body (its parent) — ignore that, or the sign instantly
# knocks itself over. Streamed terrain and tree hitboxes are StaticBody3D, so they are
# ignored too: only a dynamic body that is not this sign (the car) knocks it over.
func _wake_sign(other: Node, body: RigidBody3D) -> void:
	if other == body or other is StaticBody3D:
		return
	if not body.freeze:
		return
	# Mask the sign off the car for good: its world-layer mask (terrain/trees) would
	# otherwise still pair it with the car, which shares that layer. The car's own mask
	# never sees the sign's private layer, so this one exception fully decouples them.
	if other is CollisionObject3D:
		body.add_collision_exception_with(other)
	body.freeze = false
	_materialize_sign(body)
	_launch_sign(body, other)


# Swap a just-knocked sign from MultiMesh rendering to real panel meshes on the
# body: zero-scale its MultiMesh instances (a MultiMesh can't remove single
# instances) and attach individual panels that tumble with the physics body.
func _materialize_sign(body: RigidBody3D) -> void:
	var entry: Dictionary = _rendered.get(body, {})
	if entry.is_empty():
		return
	_rendered.erase(body)
	var mm: MultiMesh = entry["mm"]
	for i: int in entry["indices"]:
		mm.set_instance_transform(i, Transform3D(Basis.from_scale(Vector3.ZERO), Vector3.ZERO))
	_add_panels(body, _panel_size, _thickness, entry["mat"])


# Fling a just-knocked sign along the car's velocity, with an upward bias and a random
# tumble — the same recipe SpectatorGroup uses for ragdolls. The whole impulse scales
# with the car's speed: the launch speed is `speed x factor` (clamped), the upward kick
# is a FRACTION of that launch (a fixed angle, not a constant m/s), and the spin tapers
# to zero as the car slows. So a slow nudge gives a gentle low scatter instead of
# flinging the sign into the air. Falls back to the car's forward axis when it is
# barely moving. With the car masked off, this impulse is what makes the sign scatter;
# physics then rolls it on the terrain.
func _launch_sign(body: RigidBody3D, car: Node) -> void:
	var car_vel := Vector3.ZERO
	if "linear_velocity" in car:
		car_vel = car.linear_velocity
	var speed := car_vel.length()
	var dir := car_vel.normalized()
	if speed <= 0.1 and car is Node3D:
		dir = -(car as Node3D).global_transform.basis.z
	var factor := float(_knock["knock_speed_factor"])
	var speed_max := float(_knock["knock_speed_max"])
	# Shared launch recipe with the spectator ragdoll: the whole impulse (including the
	# upward bias, a fraction of the launch rather than a constant kick) scales with car
	# speed, and the spin tapers to zero as the car slows.
	body.linear_velocity = SpectatorGroup.knock_launch_velocity(dir, speed, factor,
		float(_knock["knock_speed_min"]), speed_max, float(_knock["knock_lift_ratio"]))
	body.angular_velocity = Vector3(
		_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0)
	).normalized() * float(_knock["knock_spin"]) * SpectatorGroup.knock_spin_scale(speed, factor, speed_max)


# The two splayed panels. Each is a thin, double-sided quad tilted about the ridge
# (local X) so their top edges meet at the apex and their bottoms separate into a
# stable footprint. The quad maps the FULL face texture (UV 0..1) onto each side —
# a BoxMesh instead unwraps its six faces into an atlas, so each face would only
# show a zoomed-in slice of the arrow. Both panels share the face material (same
# texture both ways — the arrow-correct-on-approach refinement is deferred, §4).
func _add_panels(sign_root: Node3D, panel_size: Vector2, thickness: float,
		mat: ShaderMaterial) -> void:
	var mesh := _panel_mesh(panel_size, thickness)
	# Panel centred at its midpoint, rotated about X by -d*splay: bottom swings
	# out to (0,0,d*h*sin) while the top meets the apex at (0,h*cos,0).
	for local in _panel_transforms():
		var panel := MeshInstance3D.new()
		panel.mesh = mesh
		panel.material_override = mat
		panel.transform = local
		sign_root.add_child(panel)


# A thin, double-sided board quad centred at the origin in the local XY plane: a
# front face (+Z) and a back face (-Z), each carrying the full face texture (UV
# 0..1, image top = panel top). The thin open edges are imperceptible at the sign's
# thickness, and the unshaded shader ignores normals (winding drives the two-sided
# visibility). One mesh is shared by both panels of a sign.
func _panel_mesh(panel_size: Vector2, thickness: float) -> ArrayMesh:
	var w := panel_size.x * 0.5
	var h := panel_size.y * 0.5
	var t := thickness * 0.5
	var verts := PackedVector3Array([
		# Front (+Z): BL, BR, TR, TL
		Vector3(-w, -h, t), Vector3(w, -h, t), Vector3(w, h, t), Vector3(-w, h, t),
		# Back (-Z): BL, TL, TR, BR
		Vector3(-w, -h, -t), Vector3(-w, h, -t), Vector3(w, h, -t), Vector3(w, -h, -t),
	])
	var uvs := PackedVector2Array([
		Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0),
		Vector2(0, 1), Vector2(0, 0), Vector2(1, 0), Vector2(1, 1),
	])
	var normals := PackedVector3Array([
		Vector3.BACK, Vector3.BACK, Vector3.BACK, Vector3.BACK,
		Vector3.FORWARD, Vector3.FORWARD, Vector3.FORWARD, Vector3.FORWARD,
	])
	# Front wound CCW from +Z, back wound CCW from -Z, so each side faces outward.
	var indices := PackedInt32Array([0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# A single box hitbox covering the A-frame footprint, a direct child of the
# RigidBody so it moves with the sign. Centred half its height above the body
# origin so the box bottom rests on the ground; this offset also puts the centre
# of mass above the base, so a low hit tips the sign over rather than sliding it.
func _add_collision_shape(body: RigidBody3D, panel_size: Vector2, base_depth: float) -> void:
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(panel_size.x, panel_size.y, base_depth)
	shape.shape = box
	# Centre half its height above the ground so it rests on the surface.
	shape.position = Vector3(0.0, panel_size.y * 0.5, 0.0)
	body.add_child(shape)


# A PS1-look material: the atlas face texture if one is wired for this key,
# otherwise a flat per-kind colour so the sign is still visible pre-art.
func _material_for(kind: String, texture_key: String, textures: Dictionary) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = SIGN_SHADER
	mat.set_shader_parameter("blend_road", false)
	var path := String(textures.get(texture_key, ""))
	if not path.is_empty() and ResourceLoader.exists(path):
		mat.set_shader_parameter("albedo_texture", load(path) as Texture2D)
		mat.set_shader_parameter("albedo_color", Color.WHITE)
	else:
		# No texture: hint_default_white samples white, so albedo_color shows solid.
		mat.set_shader_parameter("albedo_color", FALLBACK_COLORS.get(kind, Color.WHITE))
	return mat
