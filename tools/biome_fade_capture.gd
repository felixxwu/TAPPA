extends Node
# Verification aid: build the free-roam terrain on its own and photograph biome borders from
# above, out in the open and where a road crosses one, to check the ground fade
# (ps1_models.gdshader fade_rings, TerrainStreamer._pair_material). Pure tooling; not shipped.
# Writes tools/biome_fade_capture_<n>.png. Run: godot res://tools/biome_fade_capture.tscn

func _ready() -> void:
	get_window().size = Vector2i(1280, 720)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/ps1_models.gdshader")
	mat.set_shader_parameter("albedo_texture", load("res://textures/grass.jpg"))
	mat.set_shader_parameter("road_texture", load("res://textures/gravel.jpg"))
	mat.set_shader_parameter("blend_road", true)
	var streamer := TerrainStreamer.new()
	streamer.settings = FreeRoamSettings.new()
	streamer.material = mat
	var focus := Node3D.new()
	add_child(focus)
	streamer.focus = focus
	add_child(streamer)
	var sun := WorldEnvironment.new()
	sun.environment = Environment.new()
	sun.environment.background_mode = Environment.BG_COLOR
	sun.environment.background_color = Color(0.5, 0.6, 0.7)
	add_child(sun)
	var terrain := streamer.terrain
	var shots: Array[Vector2] = []
	# open ground: walk out from spawn until the ring coordinate crosses each border
	for k in range(1, streamer.settings.ring_count):
		for ang in [0.3, 2.0, 4.2]:
			var dir := Vector2(cos(ang), sin(ang))
			var r := 0.0
			while r < streamer.settings.island_radius_m and terrain.ring_coord(dir.x * r, dir.y * r) < k:
				r += 2.0
			var p := dir * r
			if terrain.height(p.x, p.y, PackedInt32Array(), false) > 0.0:
				shots.append(p)
				break
	# a road crossing a border
	var net := streamer.network
	for ei in net.edges.size():
		var pl := net.polyline(ei)
		var found := false
		for i in pl.size() - 1:
			if terrain.ring_index(pl[i].x, pl[i].y) != terrain.ring_index(pl[i + 1].x, pl[i + 1].y):
				shots.append((pl[i] + pl[i + 1]) * 0.5)
				found = true
				break
		if found:
			break
	var cam := Camera3D.new()
	add_child(cam)
	cam.fov = 70.0
	cam.far = 2000.0
	cam.make_current()
	for shot in shots.size():
		var foot := shots[shot]
		focus.position = Vector3(foot.x, 0.0, foot.y)
		streamer.prefill_at(foot)
		var g := streamer.height_at(foot.x, foot.y)
		var eye := Vector3(foot.x, g + 30.0, foot.y + 20.0)
		cam.global_transform = Transform3D(Basis.looking_at(Vector3(foot.x, g, foot.y) - eye, Vector3.UP), eye)
		for _i in 20:
			await get_tree().process_frame
		get_viewport().get_texture().get_image().save_png("res://tools/biome_fade_capture_%d.png" % shot)
		print("biome-fade-capture: shot ", shot, " at ", foot, " ring ", terrain.ring_coord(foot.x, foot.y))
	get_tree().quit()
