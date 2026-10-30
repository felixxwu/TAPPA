extends Node
# Verification aid: boot free roam, put the car on a straight-ish gravel road, hold the
# throttle, and photograph the dust puffs (DustPuffs, features/dust-puffs.md) from the
# game's own chase camera and from the side. Pure tooling; not shipped.
# Writes tools/dust_capture_<n>.png (tools/dust_capture_tarmac_<n>.png with
# DUST_CAPTURE_TARMAC=1). Run:
#
#   xvfb-run -a -s "-screen 0 1280x720x24" godot --rendering-driver opengl3 \
#       res://tools/dust_capture.tscn

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_window().size = Vector2i(1280, 720)
	Save.save_disabled = true
	WorldSession.new_world(7, TitleScreen.starter_choices()[0])
	var world := (load("res://free_roam.tscn") as PackedScene).instantiate()
	add_child(world)
	for _i in 120:
		await get_tree().process_frame
	var page: RestStopPage = world.find_children("*", "RestStopPage", true, false)[0]
	if page.is_open():
		page.close()
	var car: VehicleBody3D = world.find_children("*", "VehicleBody3D", true, false)[0]
	var streamer: TerrainStreamer = world.find_children("*", "TerrainStreamer", true, false)[0]
	var net := streamer.network
	# the longest gravel road (or tarmac road with DUST_CAPTURE_TARMAC=1)
	var tarmac := OS.get_environment("DUST_CAPTURE_TARMAC") == "1"
	var tag := "tarmac_" if tarmac else ""
	var best := PackedVector2Array()
	for ei in net.edges.size():
		var pl := net.polyline(ei)
		if pl.size() < 12 or pl.size() <= best.size():
			continue
		var mid := pl[pl.size() / 2]
		if (streamer.terrain.tarmac_weight(mid.x, mid.y) > 0.5) != tarmac:
			continue
		best = pl
	var p := best[best.size() / 4]
	var q := best[best.size() / 4 + 2]
	var dir := (q - p).normalized()
	streamer.prefill_at(p)
	var fwd := Vector3(dir.x, 0, dir.y)
	var basis := Basis.looking_at(fwd, Vector3.UP)
	car.reset_to(Transform3D(basis, Vector3(p.x, streamer.height_at(p.x, p.y) + 1.0, p.y)))
	for _i in 30:
		await get_tree().process_frame
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
	get_viewport().get_texture().get_image().save_png("res://tools/dust_capture_%s0.png" % tag)
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
	get_viewport().get_texture().get_image().save_png("res://tools/dust_capture_%s1.png" % tag)
	print("dust-capture: side")
	get_tree().quit()
