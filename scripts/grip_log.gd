class_name GripLog
extends RefCounted
# TEMPORARY DIAGNOSTIC LOGGING — delete this file and its call sites once the
# "snow tyres swapped to stock on the start line still grip like snow tyres" bug is
# understood. It exists to tell one story on stdout: WHICH menu / screen the player is
# in, WHAT upgrade edit was made, WHICH fielding path re-derived the config, and WHAT
# grip the car is actually getting while driving.
#
# Debug-build only (running the project from the Godot binary counts), so an export
# build is silent. Set GRIP_LOG=0 in the environment to mute it.

static var _enabled := -1  # -1 = not resolved yet, 0 = off, 1 = on


static func enabled() -> bool:
	if _enabled < 0:
		var muted := OS.get_environment("GRIP_LOG") == "0"
		_enabled = 1 if (OS.is_debug_build() and not muted) else 0
	return _enabled == 1


# A plain narrative line: where the player is, what they just did.
static func say(msg: String) -> void:
	if enabled():
		print("[grip] %7.2fs  %s" % [Time.get_ticks_msec() / 1000.0, msg])


# The tyre + surface state of a config, as one line. `tag` says who wrote it.
static func tyres(tag: String, cfg: GameConfig) -> void:
	if not enabled() or cfg == null:
		return
	say("%-26s muF=%.3f muR=%.3f snow_mult=%.2f tarmac_mult=%.2f | surface grass=%.2f gravel=%.2f tarmac=%.2f | snowy=%s snow_depth=%.2f snow_drag=%.1f ice=%.2f weather=%s"
		% [tag, cfg.wheel_friction_slip_front, cfg.wheel_friction_slip_rear,
			cfg.tire_snow_grip_mult, cfg.tire_tarmac_grip_mult,
			cfg.grass_grip, cfg.gravel_grip, cfg.tarmac_grip,
			cfg.ground_is_snow(), cfg.deep_snow_depth_m, cfg.deep_snow_drag,
			cfg.frozen_water_grip, cfg.weather])
	# The rest of the car, so a route comparison catches a divergence that ISN'T the tyres
	# (power, mass, aero, brakes all change how planted a car feels).
	say("%-26s mass=%.0f torque=%.0f redline=%.0f boost=%.2f down_f=%.2f down_r=%.2f widths=%.2f/%.2f brake=%.0f bias=%.2f"
		% [" ... same write", cfg.mass, cfg.peak_torque, cfg.redline_rpm,
			cfg.turbo_boost_gain, cfg.downforce_front, cfg.downforce_rear,
			cfg.wheel_width_front, cfg.wheel_width_rear, cfg.brake_torque, cfg.brake_bias])


# What the car is ACTUALLY getting under its wheels right now: the per-contact surface
# multiplier the tyre model resolved, the effective mu it produces, and how hard the
# tyres are working. Called on a timer from car.gd while driving.
static func live(cfg: GameConfig, drivetrain: Drivetrain, speed_kmh: float, pos: Vector3) -> void:
	if not enabled() or cfg == null or drivetrain == null:
		return
	var params: Dictionary = drivetrain.surface_tire_params(cfg, pos)
	var mu_mult := float(params.get("mu_mult", 1.0))
	say("DRIVING  %5.1f km/h  surface_mult=%.3f (road_w=%.2f slip_peak=%.3f slide=%.2f) -> effective muF=%.3f muR=%.3f | usage %s | terrain=%s snowy=%s"
		% [speed_kmh, mu_mult, float(params.get("road_weight", 1.0)),
			float(params.get("slip_peak", 0.0)), float(params.get("slide_ratio", 0.0)),
			cfg.wheel_friction_slip_front * mu_mult, cfg.wheel_friction_slip_rear * mu_mult,
			_usage(drivetrain), "yes" if drivetrain.terrain != null else "NONE (no surface blend!)",
			cfg.ground_is_snow()])


# The car's own accelerometer: lateral / longitudinal g in the BODY frame, plus the peaks
# since the last launch. This is the number that decides how the car feels — how hard it
# can actually turn and brake — so it is what two runs should be compared on.
static func gforce(tag: String, speed_kmh: float, lat_g: float, long_g: float,
		peak_lat: float, peak_long: float, peak_lat_kmh: float, mu_eff: float) -> void:
	say("G-FORCE %-9s %5.1f km/h  lat=%+.2fg long=%+.2fg  |  PEAK lat=%.2fg (at %.0f km/h) long=%.2fg  |  effective mu=%.3f"
		% [tag, speed_kmh, lat_g, long_g, peak_lat, peak_lat_kmh, peak_long, mu_eff])


# The three inputs to wheel_normal_force (car.mass x (k x compression - damping x vel)),
# so a load difference can be attributed to body MASS, spring RATE or COMPRESSION rather
# than guessed at. Recomputes compression exactly as Drivetrain.wheel_normal_force does.
static func suspension(tag: String, car: VehicleBody3D, drivetrain: Drivetrain) -> void:
	if not enabled():
		return
	var parts: PackedStringArray = []
	for wheel in drivetrain.all_wheels:
		if not wheel.is_in_contact():
			parts.append("%s: airborne" % wheel.name)
			continue
		var cp: Vector3 = wheel.get_contact_point()
		var down := -car.global_transform.basis.y
		var hardpoint: Vector3 = car.global_transform * drivetrain.hardpoints[wheel]
		var length: float = (cp - hardpoint).dot(down) - wheel.wheel_radius
		var compression: float = wheel.wheel_rest_length - length
		parts.append("%s: k=%.1f rest=%.3f travel=%.3f maxF=%.0f comp=%.4f N=%.0f" % [
			wheel.name, wheel.suspension_stiffness, wheel.wheel_rest_length,
			wheel.suspension_travel, wheel.suspension_max_force, compression,
			drivetrain.wheel_normal_force(wheel)])
	say("%-26s body_mass=%.1f cfg_mass=%.1f ride_y=%.3f | %s"
		% [tag, car.mass, car.config.mass, car.global_position.y, " | ".join(parts)])


# A high-rate burst through the launch itself: per-wheel normal force, longitudinal slip
# and the force actually applied, plus the driveline speeds. This is the level at which "it
# hooks up" versus "it spins" is decided, and it is bounded (a couple of seconds per launch).
static func burst(tick: int, speed_kmh: float, rpm: float, gear: int, rear_omega: float,
		front_omega_avg: float, throttle: float, per_wheel: String) -> void:
	say("BURST %3d  %6.2f km/h rpm=%.0f g=%d thr=%.2f | rear_omega=%.1f front_omega=%.1f | %s"
		% [tick, speed_kmh, rpm, gear, throttle, rear_omega, front_omega_avg, per_wheel])


# WHICH wheels are driven, and how the load sits across them. A car driving all four uses
# the whole vehicle weight for traction; one driving a single axle uses only that axle's
# share — which changes achievable longitudinal g without changing mu at all.
static func driveline(tag: String, cfg: GameConfig, drivetrain: Drivetrain) -> void:
	var mode := ["RWD", "AWD", "FWD"]
	var driven := 0
	var loads: PackedStringArray = []
	for wheel in drivetrain.all_wheels:
		if drivetrain.is_wheel_driven(wheel):
			driven += 1
		loads.append("%.0f" % drivetrain.wheel_normal_force(wheel))
	say("%-26s drive_mode=%s (cfg=%s) driven_wheels=%d/%d | weight_front=%.2f | normal_force=[%s] N"
		% [tag, mode[int(drivetrain.drive_mode)] if int(drivetrain.drive_mode) < 3 else "?",
			mode[int(cfg.drive_mode)] if int(cfg.drive_mode) < 3 else "?",
			driven, drivetrain.all_wheels.size(), cfg.weight_front, ", ".join(loads)])


# The car's CONDITION: HP, the misfire the damage model is cutting torque with, and the
# bent-toe alignment. All three persist in the SAVE across stages and sessions, so two
# launches that look identical on paper can differ entirely here.
static func condition(tag: String, hp: float, max_hp: float, misfire: float, toe: Array) -> void:
	var bent := 0.0
	for v in toe:
		bent = maxf(bent, absf(float(v)))
	say("%-26s hp=%.0f/%.0f (%.0f%%) misfire=%.3f worst_toe=%.4f rad toe=%s"
		% [tag, hp, max_hp, 100.0 * hp / maxf(max_hp, 1.0), misfire, bent, toe])


# The DRIVE side of the story: what the driver asked for, what gear/revs the car is in, and
# how much the driven wheels are actually spinning. A launch that bogs and a launch that
# hooks up can share the same mu and differ entirely here.
static func drive(speed_kmh: float, throttle: float, brake: float, handbrake: bool,
		gear: int, rpm: float, auto: bool, wheelspin_excess: float, long_g: float,
		locks: String) -> void:
	say("DRIVE    %5.1f km/h  throttle=%.2f brake=%.2f handbrake=%s | gear=%d rpm=%.0f %s | wheelspin_excess=%.2f long=%+.2fg | %s"
		% [speed_kmh, throttle, brake, "yes" if handbrake else "no ", gear, rpm,
			"AUTO" if auto else "MANUAL", wheelspin_excess, long_g, locks])


# How hard each tyre is working right now (1.0 = on the limit), so the log shows whether
# the car is actually AT its grip ceiling or nowhere near it.
static func _usage(drivetrain: Drivetrain) -> String:
	var parts: PackedStringArray = []
	for wheel in drivetrain.all_wheels:
		parts.append("%.2f" % drivetrain.wheel_grip_usage(wheel))
	return "/".join(parts)
