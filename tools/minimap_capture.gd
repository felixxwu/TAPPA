extends Node
# Verification aid: drive free roam a little with the AutoDriver and photograph the minimap
# (features/minimap.md), then the full map it opens, and print what a road redraw and a frame of
# the minimap cost. Pure tooling; not shipped. Run:
#
#   xvfb-run -a -s "-screen 0 1280x720x24" godot --rendering-driver opengl3 \
#       res://tools/minimap_capture.tscn -- --out=/some/dir [--size=2400x1080] [--frames=1500]

var _out := "user://"


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var size := Vector2i(1280, 720)
	var frames := 1500
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--size="):
			var p := a.substr(7).split("x")
			size = Vector2i(int(p[0]), int(p[1]))
		elif a.begins_with("--frames="):
			frames = int(a.substr(9))
	get_window().size = size
	Save.save_disabled = true
	WorldSession.new_world(1, TitleScreen.starter_choices()[0])
	var world := (load("res://free_roam.tscn") as PackedScene).instantiate()
	add_child(world)
	for _i in 30:
		await get_tree().process_frame
	var page: RestStopPage = world.find_children("*", "RestStopPage", true, false)[0]
	world.start_auto_drive()
	var tag := "%dx%d" % [size.x, size.y]
	for i in frames:
		await get_tree().process_frame
		if page.is_open():
			page.close()
		if i == int(frames / 2.0):
			await _shot("drive_mid_" + tag)
	await _shot("drive_" + tag)
	var mm: MiniMap = world.find_child("MiniMap", true, false)
	print("minimap: %d redraws, last gather %d us, rect %s" % [mm.redraws, mm.last_redraw_us, mm.get_rect()])
	var t0 := Time.get_ticks_usec()
	for _i in 50:
		mm.gather_roads(mm.draw_radius())
	print("minimap: gather_roads avg %.1f us" % ((Time.get_ticks_usec() - t0) / 50.0))
	t0 = Time.get_ticks_usec()
	for _i in 200:
		mm._process(0.0)
	print("minimap: _process (no redraw) avg %.1f us" % ((Time.get_ticks_usec() - t0) / 200.0))
	t0 = Time.get_ticks_usec()
	for _i in 50:
		mm._markers = MiniMap.site_markers(mm.streamer.sites, mm.rest_stops.lit_sites, mm.car_xz, mm.view_m)
	print("minimap: site_markers avg %.1f us, %d shown, %d seen" % [(Time.get_ticks_usec() - t0) / 50.0, mm._markers.size(), WorldSession.seen_sites().size()])
	world.open_full_map()
	for _i in 30:
		await get_tree().process_frame
	await _shot("full_map_" + tag)
	get_tree().quit()


func _shot(label: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(_out.path_join("minimap_%s.png" % label))
	print("minimap-capture: ", label)
