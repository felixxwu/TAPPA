class_name SignField
extends Node3D
# Builds the physical roadside signs from a SignLayout plan (todo/roadside-signs.md
# §3/§4). Each sign is a free-standing A-frame ("wet-floor" board): two thin panels
# joined at a top ridge and splayed apart at the bottom, oriented so the large
# faces point up-track / down-track and read for an approaching driver. Signs are
# few (tens per stage), so each is an individual node — no MultiMesh/culling
# (unlike the foliage in todo/performance-optimisations.md); the engine frustum-
# culls the MeshInstance3Ds and each sign carries its own face texture anyway.
#
# Each sign is a light RigidBody3D so the car scatters it on contact (the
# wet-floor-board feel). Signs are deliberately NOT in the damage OBSTACLE_GROUP:
# they are cosmetic clutter you plough through freely, with no HP penalty (unlike
# the solid trees/bushes). A RigidBody sleeps once it settles, so the at-rest cost
# is negligible despite there being one body per sign.

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
		# Stash the placement key on the body (cheap metadata) so tools/tests can
		# identify which arrow a built sign carries without re-running the planner.
		sign_body.set_meta("texture_key", String(entry["texture_key"]))
		# -Z runs along the road tangent; ridge (local X) crosses the road. This is
		# the resting pose; physics takes over from here once the car hits it.
		var fwd3 := Vector3(tangent.x, 0.0, tangent.y).normalized()
		sign_body.transform = Transform3D(Basis.looking_at(fwd3, Vector3.UP),
			Vector3(edge.x, y, edge.y))
		add_child(sign_body)

		var mat := _material_for(String(entry["kind"]), String(entry["texture_key"]), textures)
		_add_panels(sign_body, panel_size, thickness, splay, mat)
		_add_collision_shape(sign_body, panel_size, base_depth)
		_add_waker(sign_body, panel_size, base_depth)
		sign_count += 1


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


# Wake a frozen sign the first time the car enters its trigger volume, so it tumbles
# away under physics instead of standing rigid. The Area also overlaps the sign's OWN
# body (its parent) — ignore that, or the sign instantly wakes itself and falls.
# Streamed terrain and tree hitboxes are StaticBody3D, so they are ignored too: only
# a dynamic body that is not this sign (the car) unfreezes it.
func _wake_sign(other: Node, body: RigidBody3D) -> void:
	if other == body or other is StaticBody3D:
		return
	if body.freeze:
		body.freeze = false


# The two splayed panels. Each is a thin, double-sided quad tilted about the ridge
# (local X) so their top edges meet at the apex and their bottoms separate into a
# stable footprint. The quad maps the FULL face texture (UV 0..1) onto each side —
# a BoxMesh instead unwraps its six faces into an atlas, so each face would only
# show a zoomed-in slice of the arrow. Both panels share the face material (same
# texture both ways — the arrow-correct-on-approach refinement is deferred, §4).
func _add_panels(sign_root: Node3D, panel_size: Vector2, thickness: float,
		splay: float, mat: ShaderMaterial) -> void:
	var h := panel_size.y
	var mesh := _panel_mesh(panel_size, thickness)
	for d in [1, -1]:
		var panel := MeshInstance3D.new()
		panel.mesh = mesh
		panel.material_override = mat
		# Panel centred at its midpoint, rotated about X by -d*splay: bottom swings
		# out to (0,0,d*h*sin) while the top meets the apex at (0,h*cos,0).
		panel.transform = Transform3D(
			Basis(Vector3.RIGHT, -d * splay),
			Vector3(0.0, (h * 0.5) * cos(splay), d * (h * 0.5) * sin(splay)))
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
