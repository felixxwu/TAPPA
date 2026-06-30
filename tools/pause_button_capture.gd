extends Node
# Verification aid: show the in-run Pause button (top-right) with its new drawn
# PauseIcon glyph over a stand-in gameplay backdrop, and photograph it without booting
# the full run scene. Captures to tools/pause_button_capture.png. Pure tooling; not
# shipped. Run via:
#
#   xvfb-run -a -s "-screen 0 480x270x24" godot --path rally \
#       --rendering-driver opengl3 res://tools/pause_button_capture.tscn

const OUT := "res://tools/pause_button_capture.png"


func _ready() -> void:
	get_window().size = Vector2i(480, 270)

	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.42, 0.55, 0.68)  # sky-ish, so the black button reads
	add_child(bg)

	# The real PauseMenu — its _ready() builds the button and leaves it visible (the
	# overlay is hidden until paused).
	var pause := PauseMenu.new()
	add_child(pause)

	for _i in 8:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(OUT)
	print("pause-button-capture: saved ", OUT, " err=", err)
	get_tree().quit()
