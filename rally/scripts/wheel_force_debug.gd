class_name WheelForceDebug
extends MeshInstance3D
# Debug overlay drawing per-wheel force arrows, rebuilt every physics tick.
# Green = suspension force, red = tire friction force applied by the
# Drivetrain tire model. Blue = aero downforce applied at the axle midpoints.
# Values are read directly from drivetrain.readouts and car.downforce_readouts —
# exact, not estimates.

const SUSPENSION_COLOR := Color(0.2, 1.0, 0.2)
const FRICTION_COLOR := Color(1.0, 0.2, 0.2)
const DOWNFORCE_COLOR := Color(0.3, 0.6, 1.0)
const COLLISION_BOX_COLOR := Color(1.0, 1.0, 1.0, 0.18)

var car: VehicleBody3D
var _mesh := ImmediateMesh.new()
var _wheels: Array = []
# Transparent overlay of the chassis collision box, shown with the arrows. Lives
# under the CollisionShape3D so it inherits its exact transform; only its mesh
# size is synced (cars can swap the box at runtime).
var _collision_box: MeshInstance3D = null


func _init(p_car: VehicleBody3D) -> void:
	car = p_car
	mesh = _mesh
	top_level = true  # draw in world space, ignore the car's transform
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.no_depth_test = true
	material_override = mat


func _ready() -> void:
	global_transform = Transform3D.IDENTITY
	_wheels = car.find_children("*", "VehicleWheel3D", false)
	_build_collision_box()


func _build_collision_box() -> void:
	var shape_node := car.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if shape_node == null:
		return
	_collision_box = MeshInstance3D.new()
	_collision_box.mesh = BoxMesh.new()
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = COLLISION_BOX_COLOR
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED  # see the box from inside too
	_collision_box.material_override = mat
	_collision_box.visible = visible
	shape_node.add_child(_collision_box)


func _physics_process(_delta: float) -> void:
	if Input.is_action_just_pressed("toggle_debug_arrows"):
		visible = not visible
	if _collision_box != null:
		_collision_box.visible = visible
		if visible:
			var shape := (_collision_box.get_parent() as CollisionShape3D).shape as BoxShape3D
			if shape != null:
				(_collision_box.mesh as BoxMesh).size = shape.size
	if not visible:
		_mesh.clear_surfaces()
		return
	var scale_m_per_n: float = Config.data.debug_force_arrow_scale
	var segments: Array = []  # [from, to, color] triples
	for wheel in _wheels:
		var readout: Dictionary = car.drivetrain.readouts.get(wheel, {})
		if readout.is_empty():
			continue
		var cp: Vector3 = wheel.get_contact_point()
		var n: Vector3 = wheel.get_contact_normal()
		segments.append([cp, cp + n * readout.normal * scale_m_per_n, SUSPENSION_COLOR])
		segments.append([cp, cp + readout.applied * scale_m_per_n, FRICTION_COLOR])
	for entry in car.downforce_readouts:
		var p: Vector3 = entry[0]
		var f: Vector3 = entry[1]
		segments.append([p, p + f * scale_m_per_n, DOWNFORCE_COLOR])
	var verts: Array = []  # [position, color] pairs, two per line segment
	for seg in segments:
		_add_arrow(verts, seg[0], seg[1], seg[2])
	_mesh.clear_surfaces()
	if verts.is_empty():
		return
	_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for v in verts:
		_mesh.surface_set_color(v[1])
		_mesh.surface_add_vertex(v[0])
	_mesh.surface_end()


func _add_arrow(verts: Array, from: Vector3, to: Vector3, color: Color) -> void:
	var dir := to - from
	if dir.length() < 0.01:
		return
	verts.append([from, color])
	verts.append([to, color])
	# Arrow head: two short barbs in the plane of the shaft.
	var head := dir.normalized() * minf(0.15, dir.length() * 0.3)
	var perp := dir.cross(Vector3.UP)
	if perp.length() < 0.01:
		perp = dir.cross(Vector3.RIGHT)
	perp = perp.normalized() * head.length() * 0.5
	for barb in [perp, -perp]:
		verts.append([to, color])
		verts.append([to - head + barb, color])
