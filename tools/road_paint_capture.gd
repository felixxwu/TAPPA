extends Node
# Verification aid: boot free roam and photograph the road from just above the car on a gravel
# road, a tarmac road and at a junction, to check the per-pixel road paint and lane markings
# (TerrainStreamer._arrays, ps1_models.gdshader paint_road_per_pixel). Pure tooling; not shipped.
# Writes tools/road_paint_capture_<n>.png. Run:
#
#   xvfb-run -a -s "-screen 0 1280x720x24" godot --rendering-driver opengl3 \
#       res://tools/road_paint_capture.tscn

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
	var degree := {}
	for e in net.edges:
		degree[e.x] = degree.get(e.x, 0) + 1
		degree[e.y] = degree.get(e.y, 0) + 1
	var shots: Array[Transform3D] = []
	# a gravel and a tarmac stretch, well away from either end of their road
	for want_tarmac in [false, true]:
		for ei in net.edges.size():
			var pl := net.polyline(ei)
			if pl.size() < 8:
				continue
			var p := pl[pl.size() / 2]
			var q := pl[pl.size() / 2 + 1]
			var t := streamer.terrain.tarmac_weight(p.x, p.y)
			if (t > 0.9) != want_tarmac:
				continue
			shots.append(_view(streamer, p, (q - p).normalized(), 3.0))
			break
	# a junction, looking into it along one of its roads
	for ei in net.edges.size():
		var e := net.edges[ei]
		if degree[e.x] >= 3:
			var pl := net.polyline(ei)
			var a := pl[0]
			var dir := (pl[1] - a).normalized()
			shots.append(_view(streamer, a + dir * 14.0, -dir, 8.0))
			break
	for shot in shots.size():
		var xf := shots[shot]
		var foot := Vector2(xf.origin.x, xf.origin.z)
		streamer.prefill_at(foot)
		car.reset_to(Transform3D(xf.basis, Vector3(foot.x, streamer.height_at(foot.x, foot.y) + 1.0, foot.y)))
		for _i in 30:
			await get_tree().process_frame
		var cam := Camera3D.new()
		world.add_child(cam)
		cam.global_transform = xf
		cam.fov = 70.0
		cam.make_current()
		for _i in 60:
			await get_tree().process_frame
		get_viewport().get_texture().get_image().save_png("res://tools/road_paint_capture_%d.png" % shot)
		print("road-paint-capture: shot ", shot)
		cam.queue_free()
	get_tree().quit()


# A camera a few metres up over road point `p`, looking down the road along `dir`.
func _view(streamer: TerrainStreamer, p: Vector2, dir: Vector2, up: float) -> Transform3D:
	var from := p - dir * 6.0
	var eye := Vector3(from.x, streamer.terrain.height(from.x, from.y, PackedInt32Array(), false) + up, from.y)
	var at := Vector3(p.x + dir.x * 10.0, eye.y - up - 0.5, p.y + dir.y * 10.0)
	return Transform3D(Basis.looking_at(at - eye, Vector3.UP), eye)
