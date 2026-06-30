extends Node3D
# Verification aid: boot the HQ (the meta-game hub) so the global UI theme is
# live, then drive its camera/overlay through each menu "station" and photograph
# them — to eyeball the design system across the real menus. Captures to
# tools/menu_<view>.png. Pure tooling; not shipped. Run via:
#
#   xvfb-run -a -s "-screen 0 960x540x24" godot --path rally \
#       --rendering-driver opengl3 res://tools/menu_capture.tscn

var _hq: Node3D


func _ready() -> void:
	get_window().size = Vector2i(960, 540)
	_hq = (load("res://hq.tscn") as PackedScene).instantiate()
	add_child(_hq)
	# HQ shows a LoadingScreen then builds behind it; wait for the build to land.
	for _i in 180:
		await get_tree().process_frame

	var first_rally := String(RallyLibrary.RALLIES[0]["id"])

	await _shot("exterior", func() -> void: _hq._go_to(_hq.View.EXTERIOR, true))
	await _shot("garage", func() -> void: _hq._go_to(_hq.View.GARAGE, true))
	await _shot("worldmap", func() -> void: _hq._enter_table())
	await _shot("rally_detail", func() -> void:
		_hq._selected_rally_id = first_rally
		_hq._show_detail())
	await _shot("tuning_lift", func() -> void: _hq._enter_lift())
	await _shot("car_select", func() -> void:
		_hq._selected_rally_id = first_rally
		_hq._enter_car_screen())
	await _shot("settings", func() -> void: _hq._open_settings(false))

	get_tree().quit()


# Run `setup`, let the camera tween + overlay settle, then save a PNG.
func _shot(name: String, setup: Callable) -> void:
	setup.call()
	for _i in 80:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png("res://tools/menu_%s.png" % name)
	print("menu-capture: %s err=%d" % [name, err])
