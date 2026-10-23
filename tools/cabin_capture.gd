extends Node
# Verification aid: boot free roam, park the car on the road beside a few rest stops and
# photograph each one's log cabin (TerrainStreamer._site_marker). Pure tooling; not shipped.
# Writes tools/cabin_capture_<n>.png. Run:
#
#   xvfb-run -a -s "-screen 0 1280x720x24" godot --rendering-driver opengl3 \
#       res://tools/cabin_capture.tscn

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
	var rests := streamer.sites.of_kind(RoadSites.Kind.REST)
	for shot in 3:
		var site: int = rests[shot + 1]
		var c := streamer.sites.pos[site]
		var a := streamer.sites.anchor[site]
		# Back along the road from the pad's anchor, looking across at the cabin.
		var side := (c - a).normalized()
		var along := Vector2(-side.y, side.x)
		var from := a - along * 25.0
		streamer.prefill_at(from)
		var y := streamer.height_at(from.x, from.y) + 1.0
		var look := (c - from).normalized()
		car.reset_to(Transform3D(Basis.looking_at(Vector3(look.x, 0.0, look.y), Vector3.UP), Vector3(from.x, y, from.y)))
		for _i in 240:
			await get_tree().process_frame
		get_viewport().get_texture().get_image().save_png("res://tools/cabin_capture_%d.png" % shot)
		var found := streamer.find_children("Site%d" % site, "", true, false)
		print("cabin-capture: shot ", shot, " site ", site, " cabin ", "found" if found.size() > 0 else "MISSING")
	get_tree().quit()
