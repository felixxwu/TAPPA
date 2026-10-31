extends Node
# Verification aid: boot free roam as a first-time player (the cold open, ColdOpen), photograph the
# start, then carry the car down the road to the cabin in short hops (each one counts as driving,
# so trail coins are picked up and the cabin lights) and photograph the trail, the arrival and the
# options page. Pure tooling; not shipped. Writes tools/cold_open_capture_<n>_<what>.png. Run:
#
#   xvfb-run -a -s "-screen 0 1280x720x24" godot --rendering-driver opengl3 \
#       res://tools/cold_open_capture.tscn [-- --seed=N]


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_window().size = Vector2i(1280, 720)
	Save.save_disabled = true
	var seed := 7
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			seed = int(a.trim_prefix("--seed="))
	WorldSession.new_world(seed, ColdOpen.car_id(Config.data.free_roam))
	WorldSession.fresh = true
	WorldSession.set_cold_open_pending(true)
	var world := (load("res://free_roam.tscn") as PackedScene).instantiate()
	add_child(world)
	var co: ColdOpen = null
	for _i in 2000:
		await get_tree().process_frame
		co = world.get("cold_open") as ColdOpen
		if co != null and co.running:
			break
	if co == null or not co.running:
		push_error("cold-open-capture: the cold open never started")
		get_tree().quit()
		return
	print("cold-open-capture: seed %d, start %.0f m out, %d coins" % [seed, float(co.start_spot.get("dist", 0.0)), co._trail.size()])
	for _i in 90:
		await get_tree().process_frame
	_shot("1_start")
	Input.action_press("accelerate")
	var car: VehicleBody3D = co.car
	var path: PackedVector2Array = co.start_spot.get("path", PackedVector2Array())
	var streamer: TerrainStreamer = co.streamer
	var length := 0.0
	for k in path.size() - 1:
		length += path[k].distance_to(path[k + 1])
	var d := 0.0
	var mid_done := false
	while d < length:
		d = minf(d + 4.0, length)
		var p := ColdOpen._along(path, d)
		var ahead := ColdOpen._along(path, minf(d + 2.0, length))
		var dir := ahead - p
		if dir.length() < 0.01:
			dir = -streamer.sites.dir[0]
		car.reset_to(RoadRecovery.road_pose(streamer, p, Vector3(dir.x, 0.0, dir.y)))
		await get_tree().physics_frame
		await get_tree().physics_frame
		if not mid_done and d >= length * 0.45:
			mid_done = true
			for _i in 30:
				await get_tree().process_frame
			_shot("2_trail")
	Input.action_release("accelerate")
	print("cold-open-capture: done %s, money $%d" % [co.done, WorldSession.money()])
	for _i in 40:
		await get_tree().process_frame
	_shot("3_arrival")
	for _i in 900:
		await get_tree().process_frame
		if get_tree().paused:
			break
	for _i in 30:
		await get_tree().process_frame
	_shot("4_options")
	get_tree().quit()


func _shot(what: String) -> void:
	get_viewport().get_texture().get_image().save_png("res://tools/cold_open_capture_%s.png" % what)
	print("cold-open-capture: ", what)
