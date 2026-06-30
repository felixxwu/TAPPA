extends Node3D
# Verification aid: build a few HQ map-table pins (RallyFlag + the new design-system
# black readout box with the rally name and proper five-pointed StarRow stars) over a
# stand-in map plane and photograph them at roughly the table-view angle, without
# booting the whole HQ. Captures to tools/map_pin_capture.png. Pure tooling; not
# shipped. Run via:
#
#   xvfb-run -a -s "-screen 0 960x540x24" godot --path rally \
#       --rendering-driver opengl3 res://tools/map_pin_capture.tscn

const OUT := "res://tools/map_pin_capture.png"
const PIN_LABEL_PX := Vector2i(320, 120)
const PIN_LABEL_PIXEL_SIZE := 0.00255
const MAX_STARS := 3


func _ready() -> void:
	get_window().size = Vector2i(960, 540)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.20, 0.22, 0.26)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.8, 0.8, 0.8)
	e.ambient_light_energy = 1.0
	env.environment = e
	add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -40, 0)
	add_child(sun)

	# Stand-in map plane (satellite-ish green/tan), pins standing on it.
	var plane := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(3.0, 2.0)
	plane.mesh = pm
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.34, 0.40, 0.30)
	plane.material_override = gmat
	add_child(plane)

	# Three pins to show the range: gold (3 stars), bronze (1 star), locked.
	_pin("Rising Sun Rally", false, 3, Vector3(-0.7, 0, 0.25))
	_pin("RWD Masters", false, 1, Vector3(0.0, 0, -0.1))
	_pin("The Showdown", true, 0, Vector3(0.7, 0, 0.25))

	var cam := Camera3D.new()
	cam.fov = 50.0
	add_child(cam)
	cam.look_at_from_position(Vector3(0.0, 1.7, 2.3), Vector3(0.0, 0.5, 0.0), Vector3.UP)
	cam.current = true

	for _i in 16:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(OUT)
	print("map-pin-capture: saved ", OUT, " err=", err)
	get_tree().quit()


func _pin(rally_name: String, locked: bool, earned: int, pos: Vector3) -> void:
	var pin := Node3D.new()
	pin.position = pos
	add_child(pin)
	pin.add_child(RallyFlag.build(locked, earned))
	var label := _build_pin_label(rally_name, earned)
	label.position = Vector3(0.0, RallyFlag.POLE_HEIGHT + 0.16, 0.0)
	pin.add_child(label)


func _build_pin_label(rally_name: String, earned: int) -> Sprite3D:
	var vp := SubViewport.new()
	vp.size = PIN_LABEL_PX
	vp.transparent_bg = true
	vp.gui_disable_input = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	vp.add_child(center)
	var panel := UITheme.panel(1.0, 14)
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", UITheme.GAP)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_child(box)
	box.add_child(UITheme.title(rally_name))
	var stars := StarRow.new()
	stars.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.add_child(stars)
	stars.setup(earned, MAX_STARS)
	UITheme.enforce(panel)
	var sprite := Sprite3D.new()
	sprite.add_child(vp)
	sprite.texture = vp.get_texture()
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sprite.shaded = false
	sprite.pixel_size = PIN_LABEL_PIXEL_SIZE
	sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	return sprite
