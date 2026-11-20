extends Node
# Stops every car from speed at full foot brake on the flat test track and reports how much of its tyres' peak braking grip it actually uses.
# Run: godot --headless --path . --fixed-fps 60 res://tools/measure_braking.tscn [-- [solve] <car id> ...]  -> one "braking:" line per car
# With "solve" it instead finds the brake_torque and brake_bias that put both axles at TARGET_USE of their peak.

const START_KMH := 100.0
const STOP_KMH := 10.0
const TARGET_USE := 0.75


func _ready() -> void:
	var only := OS.get_cmdline_user_args()
	var solve := "solve" in only
	only.erase("solve")
	print("braking: car abs | decel g | stop m | used/peak force front rear | slip/peak front rear | locked% front rear")
	for i in CarLibrary.all().size():
		if only.is_empty() or String(CarLibrary.all()[i]["id"]) in only:
			if solve:
				await _solve(i)
			else:
				await _measure(i)
	get_tree().quit()


# Solves on slip, not force: below the peak the two are proportional, but a locked tyre still slides at most of its
# peak force, so a force target can settle on a locked axle. Front torque is per front wheel and rear torque per rear
# axle (see drivetrain.gd); each pass rescales each axle towards the target and re-measures.
func _solve(index: int) -> void:
	var spec: Dictionary = CarLibrary.all()[index]
	var torque := float(spec["brake_torque"])
	var bias := float(spec["brake_bias"])
	for pass_i in 5:
		var use: Array = await _measure(index, torque, bias)
		var front := 2.0 * torque * bias * TARGET_USE / maxf(use[0], 0.01)
		var rear := 2.0 * torque * (1.0 - bias) * TARGET_USE / maxf(use[1], 0.01)
		torque = (front + rear) / 2.0
		bias = front / (front + rear)
	await _measure(index, torque, bias)
	print("solved: %s brake_torque=%.0f brake_bias=%.2f" % [spec["id"], torque, bias])


func _measure(index: int, torque := -1.0, bias := -1.0) -> Array:
	Config.reset()
	var id := String(CarLibrary.all()[index]["id"])
	var scene: Node3D = load("res://tests/fixtures/test_track.tscn").instantiate()
	add_child(scene)
	var car: VehicleBody3D = scene.get_node("Car")
	await get_tree().physics_frame
	car.apply_car(index)
	if torque > 0.0:
		car.config.brake_torque = torque
		car.config.brake_bias = bias
	car.damage.invulnerable = true
	for f in 120:
		await get_tree().physics_frame
	car.ai_controlled = true
	car.ai_throttle = 1.0
	var t := 0.0
	while car.linear_velocity.length() * 3.6 < START_KMH and t < 90.0:
		await get_tree().physics_frame
		t += 1.0 / 60.0
		# Jolt's ground plane is only ~2 km across, so slide the car back towards the start, keeping its speed.
		if car.global_position.z < -600.0:
			var xf: Transform3D = car.global_transform
			xf.origin.z += 400.0
			PhysicsServer3D.body_set_state(car.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, xf)
	var dt: Drivetrain = car.drivetrain
	var er: float = car.config.traction_ellipse_ratio
	var v0: float = car.linear_velocity.length()
	var p0: Vector3 = car.global_position
	# Per axle [front, rear]: summed brake force, summed peak brake force, summed slip usage, samples, locked samples.
	var used := [0.0, 0.0]
	var peak := [0.0, 0.0]
	var slip := [0.0, 0.0]
	var n := [0, 0]
	var locked := [0, 0]
	var time := 0.0
	car.ai_throttle = -1.0
	while car.linear_velocity.length() * 3.6 > STOP_KMH and time < 30.0:
		await get_tree().physics_frame
		time += 1.0 / 60.0
		for c in dt._contacts:
			var a := 0 if c.wheel in dt.front_wheels else 1
			used[a] += maxf(-c.impulse_long * 60.0, 0.0)
			peak[a] += c.mu * c.n_force / er
			var u: float = dt.wheel_long_grip_usage(c.wheel)
			slip[a] += u
			n[a] += 1
			if u > 1.0:
				locked[a] += 1
	var v1: float = car.linear_velocity.length()
	var decel_g := (v0 - v1) / time / 9.81
	var dist := car.global_position.distance_to(p0)
	print("braking: %-10s %-5s | %.2f g | %5.1f m | %3.0f%% %3.0f%% | %.2f %.2f | %3.0f%% %3.0f%%" % [
		id, str(car.config.abs_enabled), decel_g, dist,
		100.0 * used[0] / maxf(peak[0], 1.0), 100.0 * used[1] / maxf(peak[1], 1.0),
		slip[0] / maxi(n[0], 1), slip[1] / maxi(n[1], 1),
		100.0 * locked[0] / maxi(n[0], 1), 100.0 * locked[1] / maxi(n[1], 1)])
	scene.free()
	return [slip[0] / maxi(n[0], 1), slip[1] / maxi(n[1], 1)]
