extends Node
# Verification aid: boot free roam and photograph a road in the deep-snow ring from beside the
# car, with the snow lift on and then off, to check the raised ground (ps1_terrain_snow.gdshader,
# TerrainStreamer._material_for) and that the props stay buried. Pure tooling; not shipped.
# Writes tools/snow_capture_<n>_<on|off>.png. Run:
#
#   xvfb-run -a -s "-screen 0 1280x720x24" godot --rendering-driver opengl3 \
#       res://tools/snow_capture.tscn

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
	var shots: Array[Array] = []
	# a road point in a deep-snow ring, if the network reaches one
	for ei in net.edges.size():
		var pl := net.polyline(ei)
		for i in pl.size() - 1:
			var ring := streamer.terrain.ring_index(pl[i].x, pl[i].y)
			if TerrainStreamer.snow_depth_of(BiomeDirector.region_of(streamer.settings, ring)) > 0.0:
				shots.append([pl[i], (pl[i + 1] - pl[i]).normalized()])
				break
		if not shots.is_empty():
			break
	# and open ground in one: walk out from spawn until the ring is snowy and the ground is dry
	for ang in [0.3, 2.0, 4.2, 5.5]:
		var dir := Vector2(cos(ang), sin(ang))
		for r in range(0, int(streamer.settings.island_radius_m), 10):
			var p := dir * float(r)
			var ring := streamer.terrain.ring_index(p.x, p.y)
			if TerrainStreamer.snow_depth_of(BiomeDirector.region_of(streamer.settings, ring)) > 0.0 \
					and streamer.terrain.height(p.x, p.y, PackedInt32Array(), false) > 2.0:
				shots.append([p + dir * 40.0, Vector2(-dir.y, dir.x)])
				break
		if shots.size() >= 2:
			break
	print("snow-capture: %d snow road spots" % shots.size())
	for shot in shots.size():
		var p: Vector2 = shots[shot][0]
		var dir: Vector2 = shots[shot][1]
		streamer.prefill_at(p)
		var h := streamer.height_at(p.x, p.y)
		car.reset_to(Transform3D(Basis.looking_at(Vector3(dir.x, 0.0, dir.y), Vector3.UP), Vector3(p.x, h + 1.0, p.y)))
		for _i in 60:
			await get_tree().process_frame
		car.freeze = true
		for n in world.find_children("*", "CameraManager", true, false):
			n.process_mode = Node.PROCESS_MODE_DISABLED
		for n in world.find_children("*", "BiomeDirector", true, false):
			n.process_mode = Node.PROCESS_MODE_DISABLED
		var side := Vector2(-dir.y, dir.x)
		var cp := Vector2(car.global_position.x, car.global_position.z)
		var eye2 := cp + side * 7.0 - dir * 3.0
		var eye := Vector3(eye2.x, car.global_position.y + 0.8, eye2.y)
		var cam := Camera3D.new()
		world.add_child(cam)
		cam.global_transform = Transform3D(Basis.looking_at(car.global_position - eye, Vector3.UP), eye)
		cam.fov = 60.0
		cam.make_current()
		for state in ["on", "off"]:
			if state == "off":
				for m in streamer.ring_materials():
					m.set_shader_parameter("snow_depth", 0.0)
					m.set_shader_parameter("snow_depth_b", 0.0)
			for _i in 30:
				await get_tree().process_frame
			get_viewport().get_texture().get_image().save_png("res://tools/snow_capture_%d_%s.png" % [shot, state])
			print("snow-capture: shot ", shot, " ", state)
		for m in streamer.ring_materials():
			if m.shader == TerrainStreamer.SNOW_SHADER:
				m.set_shader_parameter("snow_depth", Config.data.snow_visual_depth_m)
		cam.queue_free()
	get_tree().quit()
