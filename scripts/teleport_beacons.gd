class_name TeleportBeacons
extends Node3D
# Docs: features/level-editor.md — update in the same change as this file.
# The level's teleport points as things in the world: a spinning, bobbing black obelisk over each, an icon on both faces.

const WIDTH := 1.0
const DEPTH := 0.3
const BODY := 2.4
const TIP := 0.9
const HOVER := 2.2  # the tip's height over the ground, so the car passes underneath
const ICON := "res://icons/cards/rest_stop.png"
const ICON_SIZE := 0.7

var _bases: PackedFloat32Array = []
var _t := 0.0


func setup(points: Array, height_at: Callable) -> void:
	var body := MeshInstance3D.new()
	body.mesh = obelisk_mesh()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED  # like the level's buildings: shading baked per face
	mat.vertex_color_use_as_albedo = true
	body.material_override = mat
	var icon := QuadMesh.new()
	icon.size = Vector2.ONE * ICON_SIZE
	var icon_mat := StandardMaterial3D.new()
	icon_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	icon_mat.albedo_texture = load(ICON)
	icon_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	icon_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	icon.material = icon_mat
	for p: Vector2 in points:
		var beacon := Node3D.new()
		beacon.position = Vector3(p.x, float(height_at.call(p.x, p.y)) + HOVER + TIP, p.y)
		_bases.append(beacon.position.y)
		beacon.add_child(body.duplicate())
		for side in [1.0, -1.0]:
			var face := MeshInstance3D.new()
			face.mesh = icon
			face.position = Vector3(0.0, BODY * 0.6, side * (DEPTH * 0.5 + 0.01))
			face.rotation.y = 0.0 if side > 0.0 else PI  # the back icon turned round so it doesn't read mirrored
			beacon.add_child(face)
		add_child(beacon)
	body.free()


func _process(dt: float) -> void:
	_t += dt
	var cfg := Config.data
	for i in get_child_count():
		var b := get_child(i) as Node3D
		b.rotation.y = _t * cfg.teleport_beacon_spin
		b.position.y = _bases[i] + sin((_t * cfg.teleport_beacon_bob_hz + i * 0.37) * TAU) * cfg.teleport_beacon_bob_m


# A tall box whose bottom narrows to a downward point, flat-shaded, with its origin where box meets point.
static func obelisk_mesh() -> ArrayMesh:
	var w := WIDTH * 0.5
	var d := DEPTH * 0.5
	var top: Array[Vector3] = [Vector3(-w, BODY, -d), Vector3(w, BODY, -d), Vector3(w, BODY, d), Vector3(-w, BODY, d)]
	var bot: Array[Vector3] = [Vector3(-w, 0, -d), Vector3(w, 0, -d), Vector3(w, 0, d), Vector3(-w, 0, d)]
	var tip := Vector3(0, -TIP, 0)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_tri(st, top[0], top[1], top[2])
	_tri(st, top[0], top[2], top[3])
	for i in 4:
		var j := (i + 1) % 4
		_tri(st, top[i], top[j], bot[j])
		_tri(st, top[i], bot[j], bot[i])
		_tri(st, bot[i], bot[j], tip)
	return st.commit()


# One flat triangle, wound clockwise seen from outside (Godot's front face), shaded darker the further it faces from a fixed light.
static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	var n := (b - a).cross(c - a).normalized()
	var out := n.dot(a - Vector3(0, BODY * 0.5, 0)) > 0.0
	n = n if out else -n
	st.set_normal(n)
	st.set_color(Color.BLACK.lerp(Color(0.16, 0.16, 0.18), clampf(n.dot(Vector3(0.5, 0.7, 0.3).normalized()) * 0.5 + 0.5, 0.0, 1.0)))
	st.add_vertex(a)
	st.add_vertex(c if out else b)
	st.add_vertex(b if out else c)
