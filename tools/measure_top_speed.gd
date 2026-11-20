extends Node
# Drives every car flat out on the flat test track and finds the final drive that puts its top speed just below the redline in top gear.
# Run: godot --headless --path . --fixed-fps 60 res://tools/measure_top_speed.tscn [-- <car id> ...]  -> one "top_speed:" line per car

const TARGET_REDLINE_FRAC := 0.95
const MAX_SECONDS := 150.0


func _ready() -> void:
	var only := OS.get_cmdline_user_args()
	for i in CarLibrary.all().size():
		if only.is_empty() or String(CarLibrary.all()[i]["id"]) in only:
			await _tune(i)
	get_tree().quit()


func _tune(index: int) -> void:
	var id := String(CarLibrary.all()[index]["id"])
	var fd := float(EngineLibrary.by_id(String(CarLibrary.all()[index]["engine"]))["final_drive"])
	# First open the gearing until the car tops out well short of the limiter: that speed is set by drag, not gears.
	var run: Dictionary = await _run(index, fd)
	while run["rpm"] >= run["redline"] * 0.9:
		_log(id, fd, run)
		fd *= 0.8
		run = await _run(index, fd)
	_log(id, fd, run)
	# Then gear it so that speed lands at TARGET_REDLINE_FRAC of the redline, and check it.
	fd *= TARGET_REDLINE_FRAC * run["redline"] / run["rpm"]
	run = await _run(index, fd)
	_log(id, fd, run)
	print("top_speed: %s final_drive=%.2f top=%.0f km/h rpm=%.0f/%.0f" % [id, fd, run["kmh"], run["rpm"], run["redline"]])


func _log(id: String, fd: float, run: Dictionary) -> void:
	print("  %s fd=%.2f -> %.0f km/h at %.0f/%.0f rpm (gear %d)" % [id, fd, run["kmh"], run["rpm"], run["redline"], run["gear"]])


func _run(index: int, fd: float) -> Dictionary:
	Config.reset()
	var scene: Node3D = load("res://tests/fixtures/test_track.tscn").instantiate()
	add_child(scene)
	var car: VehicleBody3D = scene.get_node("Car")
	await get_tree().physics_frame
	car.apply_car(index)
	car.config.final_drive = fd
	var engine = car.drivetrain.engine
	engine._compute_shift_speeds()
	car.damage.invulnerable = true
	for f in 120:
		await get_tree().physics_frame
	car.ai_controlled = true
	car.ai_throttle = 1.0
	var last := 0.0
	var t := 0.0
	while t < MAX_SECONDS:
		for f in 300:
			await get_tree().physics_frame
		t += 5.0
		# Jolt's ground plane is only ~2 km across, so slide the car back towards the start, keeping its speed.
		var xf: Transform3D = car.global_transform
		xf.origin.z = fposmod(xf.origin.z, 400.0) - 400.0
		PhysicsServer3D.body_set_state(car.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, xf)
		var v: float = car.linear_velocity.length()
		if v - last < 0.1 and engine.gear == car.config.gear_ratios.size():
			break
		last = v
	var out := {"kmh": car.linear_velocity.length() * 3.6, "rpm": engine.rpm(), "redline": engine.redline_omega() * 60.0 / TAU, "gear": engine.gear}
	scene.free()
	return out
