class_name TeleportBeacons
extends Node3D
# Docs: features/level-editor.md — update in the same change as this file.
# The level's teleport points (yellow) and shops (purple) as things in the world: a spinning, bobbing obelisk over each, an icon on both faces.

const WIDTH := 1.5
const DEPTH := 0.15
const TELEPORT_TINT := UITheme.GOLD  # also the minimap's delivery point diamond
const BODY := 2.4
const TIP := 0.9
const HOVER := 2.2  # the tip's height over the ground, so the car passes underneath
const ICON := "res://icons/cards/rest_stop.png"
const SHOP_ICON := "res://icons/cards/shop.png"
const SHOP_TINT := Color(0.45, 0.12, 0.5)
const ICON_SIZE := 0.7

var _spots := PackedVector3Array()
var _bodies: MultiMesh
var _icons: MultiMesh
var _t := 0.0


func setup(points: Array, height_at: Callable, tint := TELEPORT_TINT, icon_path := ICON, icon_color := Color.BLACK) -> void:
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/level_prop.gdshader")
	var icon := QuadMesh.new()
	icon.size = Vector2.ONE * ICON_SIZE
	var icon_mat := StandardMaterial3D.new()
	icon_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	icon_mat.albedo_texture = load(icon_path)
	icon_mat.albedo_color = icon_color
	icon_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	icon_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	icon.material = icon_mat
	for p: Vector2 in points:
		_spots.append(Vector3(p.x, float(height_at.call(p.x, p.y)) + HOVER + TIP, p.y))
	# Every beacon in two MultiMeshes (bodies, icons) so the lot is two draw calls however many there are.
	_bodies = _field("Bodies", obelisk_mesh(tint), mat, _spots.size())
	_icons = _field("Icons", icon, null, _spots.size() * 2)
	_place()


func count() -> int:
	return _spots.size()


func _field(field_name: String, mesh: Mesh, mat: Material, n: int) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = n
	var mmi := MultiMeshInstance3D.new()
	mmi.name = field_name
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	return mm


func _process(dt: float) -> void:
	_t += dt
	_place()


func _place() -> void:
	var cfg := Config.data
	var turn := Basis(Vector3.UP, _t * cfg.teleport_beacon_spin)
	for i in _spots.size():
		var at := _spots[i]
		at.y += sin((_t * cfg.teleport_beacon_bob_hz + i * 0.37) * TAU) * cfg.teleport_beacon_bob_m
		var xf := Transform3D(turn, at)
		_bodies.set_instance_transform(i, xf)
		for k in 2:
			var side := 1.0 if k == 0 else -1.0
			# the back icon turned round so it doesn't read mirrored
			var face := Transform3D(Basis(Vector3.UP, 0.0 if k == 0 else PI), Vector3(0.0, BODY * 0.6, side * (DEPTH * 0.5 + 0.01)))
			_icons.set_instance_transform(i * 2 + k, xf * face)


# A tall box whose bottom narrows to a downward point, flat-shaded, with its origin where box meets point.
static func obelisk_mesh(tint := TELEPORT_TINT) -> ArrayMesh:
	var w := WIDTH * 0.5
	var d := DEPTH * 0.5
	var top: Array[Vector3] = [Vector3(-w, BODY, -d), Vector3(w, BODY, -d), Vector3(w, BODY, d), Vector3(-w, BODY, d)]
	var bot: Array[Vector3] = [Vector3(-w, 0, -d), Vector3(w, 0, -d), Vector3(w, 0, d), Vector3(-w, 0, d)]
	var tip := Vector3(0, -TIP, 0)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_tri(st, top[0], top[1], top[2], tint)
	_tri(st, top[0], top[2], top[3], tint)
	for i in 4:
		var j := (i + 1) % 4
		_tri(st, top[i], top[j], bot[j], tint)
		_tri(st, top[i], bot[j], bot[i], tint)
		_tri(st, bot[i], bot[j], tip, tint)
	return st.commit()


# One flat triangle, wound clockwise seen from outside (Godot's front face), shaded darker the further it faces from a fixed light.
static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, tint: Color) -> void:
	var n := (b - a).cross(c - a).normalized()
	var out := n.dot(a - Vector3(0, BODY * 0.5, 0)) > 0.0
	n = n if out else -n
	st.set_normal(n)
	st.set_color(tint.lerp(tint + Color(0.16, 0.16, 0.18), clampf(n.dot(Vector3(0.5, 0.7, 0.3).normalized()) * 0.5 + 0.5, 0.0, 1.0)))
	st.add_vertex(a)
	st.add_vertex(c if out else b)
	st.add_vertex(b if out else c)
