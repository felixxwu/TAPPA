extends Node
# Verification aid: boot free roam, open the rest-stop Garage page with two owned cars (one with a
# couple of parts unlocked, one switched off) and photograph it, to check each car card's
# "x / y upgrades" line. Pure tooling; not shipped. Writes tools/garage_page_capture.png. Run:
#
#   xvfb-run -a -s "-screen 0 1280x720x24" godot --rendering-driver opengl3 \
#       res://tools/garage_page_capture.tscn

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
	Save.set_car_parts(int(WorldSession.active_car()["instance_id"]), [
		{"kind": "part", "id": "grip", "level": 0, "on": true},
		{"kind": "part", "id": "turbo", "level": 0, "on": false}])
	Save.grant_car(String(TitleScreen.starter_choices()[1 % TitleScreen.starter_choices().size()]))
	page.owned = WorldSession.active_car()
	page.open(0)
	page._show(RestStopPage.View.GARAGE)
	for _i in 90:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png("res://tools/garage_page_capture.png")
	print("garage-page-capture: saved")
	get_tree().quit()
