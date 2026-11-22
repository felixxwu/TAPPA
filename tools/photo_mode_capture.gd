extends Node
# Verification aid: boot free roam with the touch controls forced on, open Photo Mode from the pause
# menu and photograph its on-screen touch overlay. Pure tooling; not shipped. Writes
# user://photo_mode_capture_<n>.png. Run:
#
#   xvfb-run -a -s "-screen 0 1280x720x24" godot --rendering-driver opengl3 res://tools/photo_mode_capture.tscn


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_window().size = Vector2i(1280, 720)
	Save.save_disabled = true
	Config.data.mobile_controls_force = true
	ColdOpen.new_world(7, Config.data.free_roam)
	var world := (load("res://free_roam.tscn") as PackedScene).instantiate()
	add_child(world)
	for _i in 2000:
		await get_tree().process_frame
		var co := world.get("cold_open") as ColdOpen
		if co != null and co.running:
			break
	for _i in 90:
		await get_tree().process_frame
	_shot("0_driving")
	var menu := world.get_node("PauseMenu") as PauseMenu
	menu.open()
	for _i in 10:
		await get_tree().process_frame
	_shot("1_paused")
	menu._on_photo_mode_pressed()
	for _i in 20:
		await get_tree().process_frame
	_shot("2_photo")
	get_tree().quit()


func _shot(what: String) -> void:
	get_viewport().get_texture().get_image().save_png("user://photo_mode_capture_%s.png" % what)
	print("photo-mode-capture: ", what)
