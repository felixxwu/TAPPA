extends Node
# Verification aid: boot free roam at night and photograph the spawn cabin's lamp from 15 m, 100 m
# and 300 m down its road (todo/2026-10-30-cold-open.md, open question 1). Pure tooling; not shipped.
# Writes tools/lamp_capture_<m>m.png; `-- --lantern` adds a mock lantern post and glow, `--high` lifts
# the camera 40 m. Run:
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
	if "--lantern" in OS.get_cmdline_user_args():
		_add_lantern(cabin, streamer)
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
	get_viewport().get_texture().get_image().save_png("res://tools/lamp_capture_door%s.png" % _suffix())
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
		var eye := Vector3(p.x, h + (40.0 if "--high" in OS.get_cmdline_user_args() else 2.5), p.y)
		var cam := Camera3D.new()
		world.add_child(cam)
		cam.global_transform = Transform3D(Basis.looking_at(target - eye, Vector3.UP), eye)
		cam.fov = 60.0
		cam.far = 2000.0
		cam.make_current()
		for _i in 240:
			await get_tree().process_frame
		get_viewport().get_texture().get_image().save_png("res://tools/lamp_capture_%dm%s.png" % [int(d), _suffix()])
		print("lamp-capture: %d m (walked %.0f, cabin %.0f m away, weather %s)" % [d, walked, eye.distance_to(target), biome.weather])
		cam.queue_free()
	get_tree().quit()


func _suffix() -> String:
	return "_lantern" if "--lantern" in OS.get_cmdline_user_args() else ""


# Mock-up (pass `-- --lantern`): a lantern post at the front corner of the cabin, a glowing bulb
# that reads at distance, a billboard halo round it and a light pooling on the pad.
func _add_lantern(cabin: Node3D, streamer: TerrainStreamer) -> void:
	var door := cabin.global_transform.basis.z.normalized()
	var side := cabin.global_transform.basis.x.normalized()
	var base := cabin.global_position + door * 5.0 + side * 4.5
	base.y = streamer.height_at(base.x, base.z)
	var root := Node3D.new()
	root.name = "LanternMock"
	add_child(root)
	root.global_position = base
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.2, 0.13, 0.08)
	var post := MeshInstance3D.new()
	var pm := BoxMesh.new()
	pm.size = Vector3(0.2, 3.6, 0.2)
	pm.material = wood
	post.mesh = pm
	post.position.y = 1.8
	root.add_child(post)
	var arm := MeshInstance3D.new()
	var am := BoxMesh.new()
	am.size = Vector3(0.9, 0.12, 0.12)
	am.material = wood
	arm.mesh = am
	arm.position = Vector3(0.4, 3.5, 0.0)
	root.add_child(arm)
	var bulb := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.4, 0.5, 0.4)
	var glow := StandardMaterial3D.new()
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.albedo_color = Color(1.0, 0.75, 0.35)
	bm.material = glow
	bulb.mesh = bm
	bulb.position = Vector3(0.75, 3.15, 0.0)
	root.add_child(bulb)
	var halo := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(4.0, 4.0)
	var grad := Gradient.new()
	grad.set_color(0, Color(1.0, 0.6, 0.2, 0.9))
	grad.set_color(1, Color(1.0, 0.5, 0.1, 0.0))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	var hm := StandardMaterial3D.new()
	hm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	hm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	hm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	hm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	hm.albedo_texture = tex
	hm.disable_fog = true
	qm.material = hm
	halo.mesh = qm
	halo.position = bulb.position
	root.add_child(halo)
	# A soft glow hanging over the cabin, above the treetops, so the stop reads from down the road.
	var sky := MeshInstance3D.new()
	var sq := QuadMesh.new()
	sq.size = Vector2(18.0, 18.0)
	sq.material = hm
	sky.mesh = sq
	add_child(sky)
	sky.global_position = cabin.global_position + Vector3(0.0, 14.0, 0.0)
	var light := OmniLight3D.new()
	light.light_color = TerrainStreamer.BEACON_LIT
	light.light_energy = 2.5
	light.omni_range = 14.0
	light.position = bulb.position - Vector3(0.0, 0.4, 0.0)
	root.add_child(light)
