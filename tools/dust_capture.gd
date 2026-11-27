extends Node
# Verification aid: boot the Hafren level, hold the throttle from the spawn, and photograph the
# dust puffs (DustPuffs, features/dust-puffs.md) from behind and from the side. Pure tooling;
# not shipped. Writes tools/dust_capture_<n>.png; DUST_CAPTURE_OFF=1 turns the puffs off. Run:
#
#   xvfb-run -a -s "-screen 0 1280x720x24" godot --rendering-driver opengl3 \
#       res://tools/dust_capture.tscn

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_window().size = Vector2i(1280, 720)
	Save.save_disabled = true
	var world := (load("res://level_view.tscn") as PackedScene).instantiate()
	add_child(world)
	await (world.get_node("Level") as LevelView).loaded
	for _i in 120:
		await get_tree().process_frame
	var car: VehicleBody3D = world.get_node("Car")
	if OS.get_environment("DUST_CAPTURE_OFF") == "1":
		Config.data.dust_puffs_enabled = false
	Input.action_press("accelerate")
	# Frame-time log, to spot a first-use hitch when the first puffs appear.
	var last := Time.get_ticks_usec()
	var worst := 0
	var worst_at := 0
	for i in 150:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		if now - last > worst:
			worst = now - last
			worst_at = i
		if now - last > 50000:
			print("dust-capture: frame %d took %d ms (puffs live %d)" % [i, (now - last) / 1000, world.find_children("*", "DustPuffs", true, false)[0].live_count()])
		last = now
	print("dust-capture: worst frame %d ms at %d" % [worst / 1000, worst_at])
	var cam := Camera3D.new()
	world.add_child(cam)
	var back := car.global_position + car.global_basis.z * 6.0 + Vector3.UP * 2.0
	cam.global_transform = Transform3D(Basis.looking_at(car.global_position - car.global_basis.z * 4.0 - back, Vector3.UP), back)
	cam.fov = 70.0
	cam.make_current()
	await get_tree().process_frame
	await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png("res://tools/dust_capture_0.png")
	print("dust-capture: chase")
	cam = Camera3D.new()
	world.add_child(cam)
	var side := car.global_basis.x
	var eye := car.global_position + side * 7.0 + car.global_basis.z * 4.0 + Vector3.UP * 1.5
	cam.global_transform = Transform3D(Basis.looking_at(car.global_position + car.global_basis.z * 4.0 - eye, Vector3.UP), eye)
	cam.fov = 60.0
	cam.make_current()
	await get_tree().process_frame
	await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png("res://tools/dust_capture_1.png")
	print("dust-capture: side")
	get_tree().quit()
