extends Node
# Verification aid: boot level_view.tscn on the dev level, "drive" a stretch of road by stepping the car
# along the bake's road samples from the one nearest the level's centre (stamping the map's discovery as it goes), then photograph the map (M).
# Writes user://level_map_capture_0.png (fitted) and _1.png (zoomed on the car). Run:
#
#   godot --path . res://tools/level_map_capture.tscn
#
# CAP_STEPS (default 1500) is how many road samples to walk.

func _ready() -> void:
	get_window().size = Vector2i(1280, 720)
	Save.save_disabled = true
	var world := (load("res://level_view.tscn") as PackedScene).instantiate()
	add_child(world)
	var level: LevelView = world.get_node("Level")
	await level.loaded
	var car: VehicleBody3D = world.get_node("Car")
	var map := level.map
	map.discovery = LevelDiscovery.new(map.size_m(), Config.data.level_map_reveal_cell_m)  # start from nothing seen
	var b := level._bake
	var start := 0
	var best := INF
	for i in b.sx.size():
		var d := Vector2(b.sx[i], b.sz[i]).distance_squared_to(Vector2.ZERO)
		if d < best:
			best = d
			start = i
	var steps := int(OS.get_environment("CAP_STEPS")) if OS.get_environment("CAP_STEPS") != "" else 1500
	for i in range(start, mini(start + steps, b.sx.size())):
		car.global_position = Vector3(b.sx[i], car.global_position.y, b.sz[i])
		map.reveal_at_car()
	map.toggle()
	map.zoom = map.fit_zoom()
	map.center = Vector2.ZERO
	map.queue_redraw()
	for _i in 10:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png("user://level_map_capture_0.png")
	map.zoom = map.fit_zoom() * 3.0
	map.center = Vector2(car.global_position.x, car.global_position.z)
	map.queue_redraw()
	for _i in 10:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png("user://level_map_capture_1.png")
	get_tree().quit()
