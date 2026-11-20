extends Node
# Verification aid: renders straight-on front and rear views of a car with its lamps forced fully lit,
# to check each lamp flare sits on the real lamp housing. Pure tooling; not shipped. Run windowed:
#
#   godot --path . res://tools/car_lamp_capture.tscn -- <car_id|all> [out_dir]

const OUT_DEFAULT := "/private/tmp/claude-501/-Users-felix-git-TAPPA/10909b0d-2e0f-4358-877f-3f191aa647fe/scratchpad/lamps"


func _ready() -> void:
	get_window().size = Vector2i(1000, 700)
	var args := OS.get_cmdline_user_args()
	var which: String = args[0] if args.size() > 0 else "all"
	var out: String = args[1] if args.size() > 1 else OUT_DEFAULT
	DirAccess.make_dir_recursive_absolute(out)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.45, 0.5, 0.55)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(1, 1, 1)
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-30, 0, 0)
	add_child(sun)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 3.2
	add_child(cam)
	cam.make_current()
	var cars := CarLibrary.all()
	for i in cars.size():
		var id: String = cars[i]["id"]
		if which != "all" and which != id:
			continue
		var car := (load("res://car.tscn") as PackedScene).instantiate() as VehicleBody3D
		add_child(car)
		car.apply_car(i)
		car.freeze = true
		car.global_transform = Transform3D(Basis(), Vector3(0, 1.0, 0))
		var lamps := CarLamps.new()
		add_child(lamps)
		lamps.setup(car)
		lamps.process_mode = Node.PROCESS_MODE_DISABLED
		lamps.global_transform = car.global_transform
		lamps.warm_up(car.global_position)
		lamps._head_mat.set_shader_parameter("level", 1.0)
		lamps._tail_mat.set_shader_parameter("level", 1.0)
		var box := AABB()
		var first := true
		for m in car.find_children("*", "MeshInstance3D", true, false):
			var mi := m as MeshInstance3D
			if mi.is_visible_in_tree() and mi.mesh != null:
				var b := car.global_transform.affine_inverse() * mi.global_transform * mi.mesh.get_aabb()
				box = b if first else box.merge(b)
				first = false
		print("car-lamp-capture: %s body z %.2f..%.2f y %.2f..%.2f" % [id, box.position.z, box.end.z, box.position.y, box.end.y])
		var tris := PackedVector3Array()
		for m in car.find_children("*", "MeshInstance3D", true, false):
			var mi := m as MeshInstance3D
			if mi.is_visible_in_tree() and mi.mesh != null:
				var xf := car.global_transform.affine_inverse() * mi.global_transform
				for v in mi.mesh.get_faces():
					tris.append(xf * v)
		for kind in ["head", "tail"]:
			var dz := 1.0 if kind == "head" else -1.0
			for p: Vector3 in car.lamp_locals[kind]:
				var o := Vector3(p.x, p.y, -6.0 * dz)
				var best := INF
				for t in range(0, tris.size(), 3):
					var h: Variant = Geometry3D.ray_intersects_triangle(o, Vector3(0, 0, dz), tris[t], tris[t + 1], tris[t + 2])
					if h != null:
						best = minf(best, (h as Vector3).z * dz)
				var sz := best * dz
				print("SNAP %s %s %.2f %.2f %.2f was %.2f moved %.2f" % [id, kind, p.x, p.y, sz, p.z, sz - p.z])
		var c := car.global_position + Vector3(0, 0.5, 0)
		for view in ["front", "rear", "side", "close_front", "close_rear"]:
			var dir := Vector3(0, 0, -1) if view == "front" else (Vector3(0, 0, 1) if view == "rear" else (Vector3(1, 0.15, 0) if view == "side" else (Vector3(1, 0.2, -0.6) if view == "close_front" else Vector3(1, 0.2, 0.6))))
			var look := c
			cam.size = 5.5 if view == "side" else 3.2
			if view.begins_with("close"):
				var pts: PackedVector3Array = car.lamp_locals["head" if view == "close_front" else "tail"]
				look = car.global_position + pts[pts.size() - 1]
				cam.size = 1.2
			cam.global_transform = Transform3D(Basis.looking_at(-dir, Vector3.UP), look + dir.normalized() * 20.0)
			cam.far = 100.0
			for _f in 6:
				await get_tree().process_frame
			get_viewport().get_texture().get_image().save_png("%s/%s_%s.png" % [out, id, view])
		print("car-lamp-capture: %s head=%d tail=%d" % [id, lamps._head.size(), lamps._tail.size()])
		lamps.queue_free()
		car.queue_free()
		await get_tree().process_frame
	get_tree().quit()
