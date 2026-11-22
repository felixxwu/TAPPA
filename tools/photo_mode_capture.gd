extends Node
# Verification aid: boot free roam with the touch controls forced on, open Photo Mode from the pause
# menu and photograph its on-screen touch overlay. Pure tooling; not shipped. Writes
# user://photo_mode_capture_<n>.png. CAP_TAP=1 opens Photo Mode with a real touch tap on its card
# (the phone path) instead of calling the menu directly; CAP_SIZE=WxH sets the window. Run:
#
#   xvfb-run -a -s "-screen 0 1280x720x24" godot --rendering-driver opengl3 res://tools/photo_mode_capture.tscn


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var w := OS.get_environment("CAP_SIZE")
	get_window().size = Vector2i(int(w.split("x")[0]), int(w.split("x")[1])) if w != "" else Vector2i(1280, 720)
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
	if OS.get_environment("CAP_TAP") != "":
		# The phone path: tap the Photo Mode card twice (select, then confirm) with real touch events.
		var cards: CardCarousel = menu._cards
		var i := CardUI.index_of(cards, "Photo Mode")
		cards.select(i, false)
		for _f in 30:
			await get_tree().process_frame
		for _t in 1:
			var rect := cards.get_card(i).root.get_global_rect()
			_tap(get_viewport().get_final_transform() * rect.get_center())
			for _f in 40:
				await get_tree().process_frame
	else:
		menu._on_photo_mode_pressed()
	for _i in 20:
		await get_tree().process_frame
	var controls := world.get_node_or_null("PhotoModeControls")
	print("photo-mode-capture: controls=", controls, " visible=", controls.visible if controls else null,
		" camera=", get_viewport().get_camera_3d())
	_shot("2_photo")
	get_tree().quit()


func _tap(pos: Vector2) -> void:
	for pressed in [true, false]:
		var t := InputEventScreenTouch.new()
		t.index = 0
		t.position = pos
		t.pressed = pressed
		Input.parse_input_event(t)
		await get_tree().process_frame


func _shot(what: String) -> void:
	get_viewport().get_texture().get_image().save_png("user://photo_mode_capture_%s.png" % what)
	print("photo-mode-capture: ", what)
