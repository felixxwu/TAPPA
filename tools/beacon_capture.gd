extends Node
# Verification aid: boot free roam, park the car short of a piece of loot and photograph the view
# (the beams over rest stops and loot, the floating "New upgrade" labels). Pure tooling; not
# shipped. Writes tools/beacon_capture_<n>.png. Run:
#
#   xvfb-run -a -s "-screen 0 1280x720x24" godot --rendering-driver opengl3 \
#       res://tools/beacon_capture.tscn

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_window().size = Vector2i(1280, 720)
	Save.save_disabled = true
	WorldSession.new_world(7, TitleScreen.starter_choices()[0])
	var world := (load("res://free_roam.tscn") as PackedScene).instantiate()
	add_child(world)
	for _i in 120:
		await get_tree().process_frame
	var loot: LootDirector = world.find_children("*", "LootDirector", true, false)[0]
	var page: RestStopPage = world.find_children("*", "RestStopPage", true, false)[0]
	if page.is_open():
		page.close()
	print("beacon-capture: loot ", loot.pacing_report())
	var car: VehicleBody3D = world.find_children("*", "VehicleBody3D", true, false)[0]
	var streamer: TerrainStreamer = world.find_children("*", "TerrainStreamer", true, false)[0]
	var shots := 0
	for site: int in loot.placement:
		if shots >= 2:
			break
		var target := streamer.sites.pos[site]
		# 80 m back along the direction from spawn, facing the site.
		var dir := (target - Vector2.ZERO).normalized() if target.length() > 1.0 else Vector2(1, 0)
		var from := target - dir * 80.0
		var y := streamer.height_at(from.x, from.y) + 1.0
		var basis := Basis.looking_at(Vector3(dir.x, 0.0, dir.y), Vector3.UP)
		car.reset_to(Transform3D(basis, Vector3(from.x, y, from.y)))
		for _i in 180:
			await get_tree().process_frame
		get_viewport().get_texture().get_image().save_png("res://tools/beacon_capture_%d.png" % shots)
		print("beacon-capture: shot ", shots, " site ", site, " ", loot.placement[site])
		shots += 1
	get_tree().quit()
