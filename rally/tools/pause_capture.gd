extends Node3D
# Verification aid: boot the real run scene (main.tscn) so the global UI theme is
# live, let the world build, open the in-run PAUSE menu, and photograph it over
# gameplay — the screen most directly comparable to the previous web build's pause
# menu. Captures to tools/pause_capture.png. Pure tooling; not shipped. Run via:
#
#   xvfb-run -a -s "-screen 0 960x540x24" godot --path rally \
#       --rendering-driver opengl3 res://tools/pause_capture.tscn

const OUT := "res://tools/pause_capture.png"


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS  # keep running once the tree pauses
	get_window().size = Vector2i(960, 540)
	var world := (load("res://main.tscn") as PackedScene).instantiate()
	add_child(world)

	# Let world._ready() generate terrain/track and settle a few frames.
	for _i in 150:
		await get_tree().process_frame

	var pause := world.get_node_or_null("PauseMenu")
	if pause == null:
		printerr("pause-capture: no PauseMenu node")
		get_tree().quit()
		return
	pause.open()

	for _i in 12:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(OUT)
	print("pause-capture: saved ", OUT, " err=", err)
	get_tree().quit()
