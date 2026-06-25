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
		# -Z runs along the road tangent; ridge (local X) crosses the road. This is
		# the resting pose; physics takes over from here once the car hits it.
		var fwd3 := Vector3(tangent.x, 0.0, tangent.y).normalized()
		sign_body.transform = Transform3D(Basis.looking_at(fwd3, Vector3.UP),
			Vector3(edge.x, y, edge.y))
		add_child(sign_body)

		var mat := _material_for(String(entry["kind"]), String(entry["texture_key"]), textures)
		_add_panels(sign_body, panel_size, thickness, splay, mat)
		_add_collision_shape(sign_body, panel_size, base_depth)
		sign_count += 1


# The two splayed panels. Each is a thin box tilted about the ridge (local X) so
# their top edges meet at the apex and their bottoms separate into a stable
# footprint. Both panels share the face material (same texture both ways — the
# arrow-correct-on-approach refinement is deferred, §4).
func _add_panels(sign_root: Node3D, panel_size: Vector2, thickness: float,
		splay: float, mat: ShaderMaterial) -> void:
	var h := panel_size.y
	var box := BoxMesh.new()
	box.size = Vector3(panel_size.x, h, thickness)
	for d in [1, -1]:
		var panel := MeshInstance3D.new()
		panel.mesh = box
		panel.material_override = mat
		# Bottom at (0,0,d*h*sin) leaning in to meet the apex at (0,h*cos,0); the
		# box centre is the panel midpoint, rotated about X by -d*splay.
		panel.transform = Transform3D(
			Basis(Vector3.RIGHT, -d * splay),
			Vector3(0.0, (h * 0.5) * cos(splay), d * (h * 0.5) * sin(splay)))
		sign_root.add_child(panel)


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
