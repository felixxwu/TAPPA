extends Node3D
# Verification aid: build the pre-event start-line REVEAL overlay (TIMES TO BEAT)
# over a stand-in "world" background, so the house-style panels and the clear centre
# band (where the orbiting car shows through) can be photographed without booting a
# full session run. Captures to tools/start_line_capture.png. Pure tooling; not
# shipped. Run via:
#
#   xvfb-run -a -s "-screen 0 960x540x24" godot --path rally \
#       --rendering-driver opengl3 res://tools/start_line_capture.tscn

const OUT := "res://tools/start_line_capture.png"


func _ready() -> void:
	get_window().size = Vector2i(960, 540)

	# Stand-in for the orbiting scene: a sky/grass split with a chunky block in the
	# centre band so it's obvious the panels leave the car's space clear.
	var bg := CanvasLayer.new()
	bg.layer = 0
	add_child(bg)
	var sky := ColorRect.new()
	sky.set_anchors_preset(Control.PRESET_FULL_RECT)
	sky.color = Color(0.45, 0.62, 0.78)
	bg.add_child(sky)
	var grass := ColorRect.new()
	grass.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	grass.offset_top = -180
	grass.color = Color(0.30, 0.42, 0.22)
	bg.add_child(grass)
	var car := ColorRect.new()
	car.set_anchors_preset(Control.PRESET_CENTER)
	car.custom_minimum_size = Vector2(260, 120)
	car.size = Vector2(260, 120)
	car.position = Vector2(480 - 130, 270 - 60)
	car.color = Color(0.85, 0.18, 0.16)
	bg.add_child(car)

	var sl := StartLine.new()
	add_child(sl)
	var rally := RallyLibrary.by_id("rwd_masters")
	var leaders := [
		{"name": "Rival 3", "car_name": "Porsche 911", "time_ms": 75430},
		{"name": "Rival 1", "car_name": "Dodge Viper RT/10", "time_ms": 78120},
		{"name": "Rival 7", "car_name": "Focus ST", "time_ms": 80050},
	]
	sl._build_overlay(rally, 1, leaders)

	for _i in 12:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(OUT)
	print("start-line-capture: saved ", OUT, " err=", err)
	get_tree().quit()
