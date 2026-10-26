extends Node
# Verification aid: boot free roam and photograph the car's lamps (features/car-lamps.md) —
# by day under the brake, and at night with the headlights on, running and braking.
# Pure tooling; not shipped. Writes lamp_<shot>.png into the directory given after `--`:
#
#   godot res://tools/lamp_capture.tscn -- /some/output/dir

var _out := "res://tools"


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		_out = args[0]
	get_window().size = Vector2i(1280, 720)
	Save.save_disabled = true
	WorldSession.new_world(7, TitleScreen.starter_choices()[0])
	var world := (load("res://free_roam.tscn") as PackedScene).instantiate()
	add_child(world)
	await _frames(120)
	for page: RestStopPage in world.find_children("*", "RestStopPage", true, false):
		if page.is_open():
			page.close()
	var car: VehicleBody3D = world.find_children("*", "VehicleBody3D", true, false)[0]
	var camera := get_viewport().get_camera_3d()
	camera.set_process(false)
	camera.set_physics_process(false)
	# Hold the car still and drive its brake lamp by hand, so each shot shows one state.
	car.freeze = true
	car.set_physics_process(false)
	var director: BiomeDirector = world.find_children("*", "BiomeDirector", true, false)[0]

	await _shot("day_braking_rear", car, camera, Vector3(-1.4, 1.0, 4.5), 1.0)
	await _shot("day_front", car, camera, Vector3(1.4, 1.0, -4.5), 0.0)

	_force_weather(director, StageFields.WEATHER_NIGHT)
	await _frames(240)
	await _shot("night_front", car, camera, Vector3(1.4, 1.0, -4.5), 0.0)
	await _shot("night_front_close", car, camera, Vector3(1.2, 0.9, -4.0), 0.0)
	await _shot("night_rear_running", car, camera, Vector3(-1.4, 1.0, 4.5), 0.0)
	await _shot("night_rear_braking", car, camera, Vector3(-1.4, 1.0, 4.5), 1.0)
	await _shot("night_side", car, camera, Vector3(6.0, 1.2, 0.0), 1.0)
	get_tree().quit()


# Switch the free-roam weather and keep the director from switching it back.
func _force_weather(director: BiomeDirector, weather: String) -> void:
	director.weather = weather
	director._apply_weather(Config.data)
	director._start_fade(BiomeDirector.target_look(Config.data,
		BiomeDirector.region_of(director.streamer.settings, director.ring), weather, director._base_env))
	director._check_t = 1e9


func _shot(name: String, car: Node3D, camera: Camera3D, local_eye: Vector3, brake: float) -> void:
	car.brake_lamp = brake
	var target := car.global_transform * Vector3(0.0, 0.4, 0.0)
	camera.global_position = car.global_transform * local_eye
	camera.look_at(target, Vector3.UP)
	await _frames(20)
	var path := _out.path_join("lamp_%s.png" % name)
	get_viewport().get_texture().get_image().save_png(path)
	print("lamp-capture: ", path)


func _frames(n: int) -> void:
	for _i in n:
		await get_tree().process_frame
