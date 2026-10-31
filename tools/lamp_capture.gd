extends Node
# Verification aid: boot free roam at night and photograph the spawn cabin's lamp from 15 m, 100 m
# and 300 m down its road (todo/2026-10-30-cold-open.md, open question 1). Pure tooling; not shipped.
# Writes tools/lamp_capture_<m>m.png. Run:
#
#   xvfb-run -a -s "-screen 0 1280x720x24" godot --rendering-driver opengl3 \
#       res://tools/lamp_capture.tscn

const DISTANCES := [15.0, 100.0, 300.0]


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
	var biome: BiomeDirector = world.find_children("*", "BiomeDirector", true, false)[0]
	biome.forced_weather = "night"
	biome.update_now()
	var cabin := streamer.find_child("Site0", true, false) as Node3D
	if cabin == null:
		push_error("lamp-capture: no Site0 cabin")
		get_tree().quit()
		return
	var target := cabin.global_position + Vector3(0.0, 1.8, 0.0)
	# Walk the road away from spawn, along the way the spawn pose faces.
	var net := streamer.network
	var a := streamer.sites.anchor[0]
	var out := streamer.sites.dir[0]
	net.nearest(a.x, a.y, 200.0)
	var pl := net.polyline(net.hit_edge)
	var best := 0
	for i in pl.size():
		if pl[i].distance_to(a) < pl[best].distance_to(a):
			best = i
	var step := 1
	if best + 1 >= pl.size() or (best > 0 and (pl[best - 1] - pl[best]).dot(out) > (pl[best + 1] - pl[best]).dot(out)):
		step = -1
	for hud in world.find_children("*", "CanvasLayer", true, false):
		(hud as CanvasLayer).visible = false
	# Straight in at the doorway first (the model's door is on its +z side), lamp state printed.
	var door := cabin.global_transform.basis.z.normalized()
	var deye := cabin.global_position + door * 10.0 + Vector3(0.0, 2.0, 0.0)
	var dcam := Camera3D.new()
	world.add_child(dcam)
	dcam.global_transform = Transform3D(Basis.looking_at(target - deye, Vector3.UP), deye)
	dcam.make_current()
	for _i in 240:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png("res://tools/lamp_capture_door.png")
	print("lamp-capture: door, lamp node %s" % [cabin.get_node_or_null("Lamp") != null])
	dcam.queue_free()
	for d: float in DISTANCES:
		var walked := 0.0
		var i := best
		var p := pl[best]
		while walked < d and i + step >= 0 and i + step < pl.size():
			var seg := pl[i + step].distance_to(pl[i])
			if walked + seg >= d:
				p = pl[i].lerp(pl[i + step], (d - walked) / seg)
				walked = d
				break
			walked += seg
			i += step
			p = pl[i]
		streamer.prefill_at(p)
		var h := streamer.height_at(p.x, p.y)
		car.reset_to(Transform3D(Basis(), Vector3(p.x, h + 1.0, p.y)))
		car.freeze = true
		for n in world.find_children("*", "CameraManager", true, false):
			n.process_mode = Node.PROCESS_MODE_DISABLED
		var eye := Vector3(p.x, h + 2.5, p.y)
		var cam := Camera3D.new()
		world.add_child(cam)
		cam.global_transform = Transform3D(Basis.looking_at(target - eye, Vector3.UP), eye)
		cam.fov = 60.0
		cam.far = 2000.0
		cam.make_current()
		for _i in 240:
			await get_tree().process_frame
		get_viewport().get_texture().get_image().save_png("res://tools/lamp_capture_%dm.png" % int(d))
		print("lamp-capture: %d m (walked %.0f, cabin %.0f m away, weather %s)" % [d, walked, eye.distance_to(target), biome.weather])
		cam.queue_free()
	get_tree().quit()
