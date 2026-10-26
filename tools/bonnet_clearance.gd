extends SceneTree
# BONNET CAMERA CLEARANCE — for every car with a body model, where the bonnet camera sits
# relative to that body, so a car's `bonnet_cam_offset` (CarLibrary) can be set by numbers
# rather than by eye.
#
# RUN IT (no scene, no tests, a few seconds):
#
#   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . -s tools/bonnet_clearance.gd
#
# The camera is placed the way the game places it (CameraManager.refresh_bonnet_offset):
# GameConfig.bonnet_offset + the car's bonnet_cam_offset, in the car's own space (forward is -z).
# Heights are measured by dropping rays onto the body mesh as car.tscn seats it. Per car:
#   below    the body surface straight under the camera, and the gap to it (negative = the
#            camera is inside the body)
#   ahead    the highest body point in front of the camera; above the camera means it is in view
#   bonnet   where the windscreen ends and the bonnet's flat begins, and the camera's height over it
#   set y    the bonnet_cam_offset.y that leaves CLEARANCE_M between the camera and the body
#
# `-s` compiles this before the autoloads exist, so CarLibrary and the config are reached through
# untyped load() after one frame.

const CELL := 0.1
const CLEARANCE_M := 0.1


func _initialize() -> void:
	await process_frame
	var cfg = load("res://config/game_config.tres")
	var lib = load("res://scripts/car_library.gd")
	var car: Node3D = (load("res://car.tscn") as PackedScene).instantiate()
	for spec: Dictionary in lib.CARS:
		var body := car.get_node_or_null(NodePath(String(spec.get("model_node", "")))) as Node3D
		if not bool(spec.get("use_model", false)) or body == null:
			continue
		var cam: Vector3 = cfg.bonnet_offset + spec.get("bonnet_cam_offset", Vector3.ZERO)
		_report(String(spec["id"]), cam, cfg.bonnet_offset, Surface.new(car, body))
	car.free()
	quit()


func _report(id: String, cam: Vector3, base: Vector3, s: Surface) -> void:
	var below := s.top(cam.x, cam.z)
	var ahead := -INF
	var ahead_at := Vector2.ZERO
	for zi in range(1, 21):
		for xi in range(-6, 7, 2):
			var p := Vector2(cam.x + xi * 0.1, cam.z - zi * 0.05)
			var h := s.top(p.x, p.y)
			if h > ahead:
				ahead = h
				ahead_at = p
	# Walk forward from the camera until the surface stops falling steeply: that is the bonnet.
	var bonnet_z := INF
	var bonnet_h := -INF
	var prev := below
	var z := cam.z - 0.05
	while z > s.front_z:
		var h := s.top(cam.x, z)
		if is_finite(prev) and is_finite(h) and (prev - h) / 0.05 < 0.2:
			bonnet_z = z
			bonnet_h = h
			break
		prev = h
		z -= 0.05
	print("%-12s camera (%.2f, %.2f, %.2f)" % [id, cam.x, cam.y, cam.z])
	print("    below   body at %.2f m -> gap %+.2f m%s" % [below, cam.y - below, "  INSIDE THE BODY" if cam.y < below else ""])
	print("    ahead   highest %.2f m at (%.2f, %.2f)%s" % [ahead, ahead_at.x, ahead_at.y, "  ABOVE THE CAMERA" if ahead > cam.y else ""])
	if is_finite(bonnet_z):
		print("    bonnet  starts %.2f m ahead at %.2f m -> camera %.2f m above it" % [cam.z - bonnet_z, bonnet_h, cam.y - bonnet_h])
	else:
		print("    bonnet  not found ahead of the camera")
	print("    set y   bonnet_cam_offset.y = %.2f for %.2f m clearance" % [maxf(below, ahead) + CLEARANCE_M - base.y, CLEARANCE_M])


# A body mesh's triangles in the car's space, bucketed by xz cell so a downward ray only tests
# the triangles that could cover it.
class Surface:
	var tris := PackedVector3Array()
	var cells := {}  # Vector2i -> PackedInt32Array of first-vertex indices
	var front_z := INF

	func _init(car: Node3D, body: Node3D) -> void:
		var stack: Array[Node] = [body]
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			stack.append_array(n.get_children())
			if not (n is MeshInstance3D) or (n as MeshInstance3D).mesh == null:
				continue
			var xf := Transform3D.IDENTITY
			var p: Node = n
			while p != car:
				xf = (p as Node3D).transform * xf
				p = p.get_parent()
			for v in (n as MeshInstance3D).mesh.get_faces():
				tris.append(xf * v)
		for i in range(0, tris.size(), 3):
			var a := tris[i]
			var b := tris[i + 1]
			var c := tris[i + 2]
			front_z = minf(front_z, minf(a.z, minf(b.z, c.z)))
			for cx in range(floori(minf(a.x, minf(b.x, c.x)) / CELL), floori(maxf(a.x, maxf(b.x, c.x)) / CELL) + 1):
				for cz in range(floori(minf(a.z, minf(b.z, c.z)) / CELL), floori(maxf(a.z, maxf(b.z, c.z)) / CELL) + 1):
					var key := Vector2i(cx, cz)
					var list: PackedInt32Array = cells.get(key, PackedInt32Array())
					list.append(i)
					cells[key] = list

	# The highest body surface over (x, z), or -INF where the body doesn't reach.
	func top(x: float, z: float) -> float:
		var best := -INF
		for i in cells.get(Vector2i(floori(x / CELL), floori(z / CELL)), PackedInt32Array()):
			var hit = Geometry3D.ray_intersects_triangle(Vector3(x, 100.0, z), Vector3.DOWN, tris[i], tris[i + 1], tris[i + 2])
			if hit != null:
				best = maxf(best, (hit as Vector3).y)
		return best
