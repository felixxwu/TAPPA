extends Node
# Verification aid: photograph the free-roam menus (title MAIN / STARTER, the pause menu,
# the rest-stop page and its sub-pages, the stats page) so a layout change can be eyeballed
# without a playthrough. Pure tooling; not shipped. Writes tools/menu_capture_<name>.png. Run:
#
#   xvfb-run -a -s "-screen 0 1280x720x24" godot --rendering-driver opengl3 \
#       res://tools/menu_capture.tscn

const OUT := "res://tools/menu_capture_%s.png"


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_window().size = Vector2i(1280, 720)
	Save.save_disabled = true
	if not WorldSession.has_world():
		WorldSession.new_world(7, TitleScreen.starter_choices()[0])
	var title := TitleScreen.new()
	title.enter_world = func() -> void: pass
	var layer := CanvasLayer.new()
	add_child(layer)
	layer.add_child(title)
	await _settle()
	await _shot("title")
	title._show(TitleScreen.View.STARTER)
	await _settle()
	await _shot("starter")
	layer.queue_free()
	var world := (load("res://free_roam.tscn") as PackedScene).instantiate()
	add_child(world)
	for _i in 240:
		await get_tree().process_frame
	var page: RestStopPage = world.find_children("*", "RestStopPage", true, false)[0]
	if page.is_open():
		page.close()
	var pause: PauseMenu = world.find_children("*", "PauseMenu", true, false)[0]
	pause.set_input_enabled(true)
	pause.open()
	await _settle()
	await _shot("pause")
	pause.resume()
	var stash := WorldSession.list("stash")
	if stash.is_empty():
		for item: Dictionary in LootRules.ring_tables(4)[1]:
			if String(item["kind"]) == "part" and stash.size() < 6:
				stash.append(item)
		WorldSession.set_list("stash", stash)
	page.open(0)
	await _settle()
	await _shot("rest_main")
	page._show(RestStopPage.View.PARTS)
	await _settle()
	await _shot("rest_parts")
	page._show(RestStopPage.View.GARAGE)
	await _settle()
	await _shot("rest_garage")
	page._show(RestStopPage.View.JOURNAL)
	await _settle()
	await _shot("rest_journal")
	page._show(RestStopPage.View.TUNE)
	await _settle()
	await _shot("rest_tune")
	page.close()
	var pages: WorldPages = world.find_children("*", "WorldPages", true, false)[0]
	pages.show_stats(func() -> void: pass)
	await _settle()
	await _shot("stats")
	get_tree().quit()


func _settle() -> void:
	for _i in 120:
		await get_tree().process_frame


func _shot(name: String) -> void:
	var img := get_viewport().get_texture().get_image()
	img.save_png(OUT % name)
	print("menu-capture: ", name)
