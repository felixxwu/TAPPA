extends Node
# Verification aid: boot the Hafren level, open Photo Mode and fly the camera well away from the car
# and road, then photograph what streamed in round it (trees, ground cover). Pure tooling; not shipped.
# Writes user://level_photo_capture_<n>.png. Run:
#
#   xvfb-run -a -s "-screen 0 1280x720x24" godot --rendering-driver opengl3 res://tools/level_photo_capture.tscn


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_window().size = Vector2i(1280, 720)
	Save.save_disabled = true
	var world := (load("res://level_view.tscn") as PackedScene).instantiate()
	add_child(world)
	var level: LevelView = world.get_node("Level")
	await level.loaded
	for _i in 60:
		await get_tree().process_frame
	var menu := world.get_node("PauseMenu") as PauseMenu
	menu.open()
	await get_tree().process_frame
	menu._on_photo_mode_pressed()
	var cam := world.get_node("PhotoModeCamera") as PhotoModeCamera
	var dist := float(OS.get_environment("CAP_DIST")) if OS.get_environment("CAP_DIST") != "" else 600.0
	var start := cam.global_position
	var steps := 60
	for i in steps:  # fly out over a second or so, as a player would
		cam.global_position = start + Vector3(dist, 0.0, 0.0) * float(i + 1) / steps
		cam.global_position.y = level.height_at(cam.global_position.x, cam.global_position.z) + 4.0
		await get_tree().process_frame
	for _i in 240:
		await get_tree().process_frame
	_shot("far")
	get_tree().quit()


func _shot(what: String) -> void:
	get_viewport().get_texture().get_image().save_png("user://level_photo_capture_%s.png" % what)
	print("level-photo-capture: ", what)
