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
# Combined steer-assist + spin-protection yaw torque, drawn as one arrow above
# the car pointing left/right (see car.steer_assist_readout).
const ASSIST_COLOR := Color(1.0, 0.9, 0.2)
const COLLISION_BOX_COLOR := Color(1.0, 1.0, 1.0, 0.18)

var car: VehicleBody3D
var _mesh := ImmediateMesh.new()
var _wheels: Array = []
# Transparent overlay of the chassis collision hull (a chamfered octagon), shown
# with the arrows. Lives under the CollisionShape3D so it inherits its exact
# transform; its mesh is rebuilt from the hull points whenever they change (cars
# swap the hull at runtime via apply_car).
var _collision_box: MeshInstance3D = null
var _hull_points := PackedVector3Array()


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
	# If the overlay starts visible (config), hide the body to match the H-toggle behaviour.
	if visible and car.has_method("set_body_hidden"):
		car.set_body_hidden(true)


func _build_collision_box() -> void:
	var shape_node := car.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if shape_node == null:
		return
	_collision_box = MeshInstance3D.new()
	_collision_box.mesh = ArrayMesh.new()
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = COLLISION_BOX_COLOR
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED  # see the hull from inside too
	_collision_box.material_override = mat
	_collision_box.visible = visible
	shape_node.add_child(_collision_box)


# Rebuild the transparent overlay mesh as the octagonal prism described by the
# hull's 16 points ([top, bottom] per corner, 8 corners walked clockwise — the
# ordering car.gd._chassis_hull_points documents). Eight side quads + two caps.
func _rebuild_collision_mesh(points: PackedVector3Array) -> void:
	var arr_mesh := _collision_box.mesh as ArrayMesh
	arr_mesh.clear_surfaces()
	@warning_ignore("integer_division")
	var n := points.size() / 2  # corners (two points — top + bottom — each)
	if n < 3:
		return
	var verts := PackedVector3Array()
	for i in n:
		var j := (i + 1) % n
		var top_i := points[2 * i]
		var bot_i := points[2 * i + 1]
		var top_j := points[2 * j]
		var bot_j := points[2 * j + 1]
		# Side quad (double-sided material, so winding is cosmetic).
		verts.append_array([top_i, top_j, bot_j, top_i, bot_j, bot_i])
	# Fan the two octagon caps from corner 0.
	for i in range(1, n - 1):
		verts.append_array([points[0], points[2 * i], points[2 * (i + 1)]])          # top
		verts.append_array([points[1], points[2 * (i + 1) + 1], points[2 * i + 1]])  # bottom
	var surface := []
	surface.resize(Mesh.ARRAY_MAX)
	surface[Mesh.ARRAY_VERTEX] = verts
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface)


func _physics_process(delta: float) -> void:
	var __t := Time.get_ticks_usec()
	_timed_physics_process(delta)
	PerfLog.track(&"wheel_force_debug", Time.get_ticks_usec() - __t)


func _timed_physics_process(_delta: float) -> void:
	# The H-key toggle is a dev-only affordance: only honour it in a debug build
	# (editor / debug export). Release exports (e.g. the web build) never show the
	# arrows via the key. A config that starts them visible still works either way.
	if OS.is_debug_build() and Input.is_action_just_pressed("toggle_debug_arrows"):
		visible = not visible
		# Hide the car body while the overlay is up so the (now slightly smaller)
		# hitbox hull isn't obscured; restore it when the overlay is dismissed.
		if car.has_method("set_body_hidden"):
			car.set_body_hidden(visible)
	if _collision_box != null:
		_collision_box.visible = visible
		if visible:
			var shape := (_collision_box.get_parent() as CollisionShape3D).shape as ConvexPolygonShape3D
			if shape != null and shape.points != _hull_points:
				_hull_points = shape.points
				_rebuild_collision_mesh(_hull_points)
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
	# One combined steer-assist arrow above the roof: length scales with the
	# total yaw-assist torque, direction points left/right (the way the aids are
	# rotating the car). Positive readout = torque about the car's up axis =
	# turning the nose left, so the arrow points along the car's -X (left).
	var assist_scale_m_per_nm: float = Config.data.debug_assist_arrow_scale
	var origin: Vector3 = car.global_position + car.global_transform.basis.y * 1.5
	var left: Vector3 = -car.global_transform.basis.x
	segments.append([origin, origin + left * car.steer_assist_readout * assist_scale_m_per_nm, ASSIST_COLOR])
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
