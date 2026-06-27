class_name CarLibrary
extends RefCounted
# A small roster of selectable cars, cycled in-game with the HUD's car button
# (see hud.gd) and applied by car.gd's apply_car(). Each entry overlays the
# neutral baseline tuning (car.tscn + game_config.tres) with one real car's
# character: body/cabin box dimensions, wheelbase and track, wheel/tyre size,
# mass, power, tyre grip, aero drag, shift_time (gearbox shift speed),
# engine_type (the engine sound preset) and the driven axle layout.
#
# Dimensions (length / width / wheelbase / track) come from manufacturer spec
# data and are used directly in metres (Godot units = metres).
#
# Dynamics values are in real SI units, matching GameConfig (mass in kg, torque
# in N·m), anchored to the Mazda MX-5:
#   * mass     — the car's real kerb mass in kg.
#   * peak_torque — the car's REAL published peak crank torque in N·m (the sim
#                models crank torque directly). redline is its real rev limit;
#                together (torque x revs) they give a realistic power character,
#                so e.g. the high-revving LFA makes its power up at 9000 rpm
#                rather than on torque alone. The engine preset still sets the
#                rpm where torque peaks and the curve shape.
#   * grip_front / grip_rear — tyre friction (wheel_friction_slip_*), a
#                dimensionless coefficient. The whole roster was raised ~20% over
#                its original road-tyre baseline (which sat the road cars near
#                0.9 front / 1.05 rear), so cars now run ~1.08 front and up. The
#                rear is kept a touch grippier than the front for a planted,
#                stable tail that resists snap power-on oversteer. Rollover from
#                the higher lateral force is held off by the low wheel_roll_influence
#                (GameConfig, 0.1) rather than by capping front grip — watch the
#                taller bodies (Mustang/Mustang-like) in hard turns if grip rises
#                much further.
#   * shift_time — seconds of clutch-open throttle cut per gear change
#                (GameConfig.shift_time): the manual roadster (MX-5) is slowest,
#                the dual-clutch / automated supercars (911 PDK, RS3 DSG,
#                Aventador ISR) snap through gears fastest.
#   * downforce_front / downforce_rear — aero downforce (N per (m/s)² at each axle,
#                GameConfig.downforce_*). apply_car() SETS these from the spec (so a
#                car with 0 has none — no hidden global baseline), and the aero_kit
#                upgrade adds on top. All cars carry a small rear value to keep the
#                tail planted under power; front defaults to 0 when omitted.
#
# engine_type indexes GameConfig.ENGINE_PRESETS: 0 i4, 1 i5, 2 i6, 3 v6,
# 4 v8, 5 v10, 6 v12. drive_mode matches Drivetrain.DriveMode: 0 RWD, 1 AWD,
# 2 FWD.
#
# low_octave_mix (GameConfig.engine_low_octave_mix) crossfades the engine voice
# toward a copy one octave lower (half the firing frequency), for cars whose
# synthesized note sits too high. 0 = normal voice only; 0.5 = a 50/50 blend of
# the normal and low-octave voices. Tuned per car to taste; e.g. the high-revving
# Lexus LFA V10 blends in the lower octave to drop its scream into a fuller register.
#
# volume_db (GameConfig.engine_volume_db) is the per-car master level of the
# engine voice, in decibels. apply_car() copies it into GameConfig before the
# synth rebuilds. All cars start at -6.0 (the GameConfig fallback default), a
# placeholder for per-car balancing — raise a car to make it louder, lower it
# to make it quieter relative to the others.
#
# noise_db is the per-car broadband-noise level, in decibels. The two inputs to
# the engine soft clipper — the cylinder voice and the white noise — are each
# controlled independently before the waveshaper: the voice by volume_db, the
# noise by noise_db. apply_car() converts noise_db to a linear amplitude
# (db_to_linear) and writes it into GameConfig.engine_noise_level before the
# synth rebuilds; engine_noise_level is the fallback default for cars that omit
# noise_db. All cars start at the same value (≈ the prior global noise floor).
#
# soft_clip_post_gain (GameConfig.engine_soft_clip_post_gain) is the per-car
# post-amp applied after the sine soft clipper, trimming each car's shaped
# output level (1.0 = transparent). apply_car() copies it into GameConfig before
# the synth rebuilds; the config value is the fallback default. The clipper's
# pre-amp (engine_soft_clip_drive) stays a single global value.

const RWD := 0
const AWD := 1
const FWD := 2

# body / cabin are BoxMesh sizes (width, height, length) in metres; the chassis
# collision box reuses body with a little extra height. cabin_z offsets the
# greenhouse along the car's length (+ = rearward). track and wheelbase set the
# wheel positions; wheel_radius / wheel_width size the tyre cylinders.
#
# suspension_travel (m) is the spring's working length — it also doubles as the
# wheel raycast / rest length (GameConfig.suspension_travel), so a shorter travel
# also sits the car lower. suspension_stiffness is the spring rate
# (GameConfig.suspension_stiffness); the compression/rebound dampers are derived
# from it (critically damped, see GameConfig.suspension_damping_*), not specified
# per car. Soft & tall roadster/muscle (MX-5, Mustang) vs stiff & low supercars
# (911, LFA, Aventador).
const CARS: Array[Dictionary] = [
	{
		"name": "Mazda MX-5",  # ND: ~1058 kg, 181 hp, 2.0 i4, light RWD roadster
		"id": "mx5", "country": "JP", "car_type": "roadster", "max_hp": 800.0, "reward_tier": 1,
		"mass": 1058.0, "peak_torque": 205.0, "redline": 7500.0,
		"grip_front": 1.08, "grip_rear": 1.26, "shift_time": 0.30,  # manual H-pattern roadster
		"engine_type": 0, "drive_mode": RWD, "drag": 3.53, "downforce_rear": 0.5, "low_octave_mix": 0.2, "volume_db": -5.0, "noise_db": -54.0, "soft_clip_post_gain": 0.07,
		"body": Vector3(1.5, 0.50, 3.8), "cabin": Vector3(1.35, 0.45, 1.40),
		"cabin_z": 0.25, "track": 1.50, "wheelbase": 2.31,
		"wheel_radius": 0.30, "wheel_width": 0.195,
		"suspension_travel": 0.42, "suspension_stiffness": 10.0,  # compliant roadster baseline
		# Renders the authored blender/mx5.glb body (Car/Mx5Body) instead of the
		# procedural chassis+cabin boxes; see car.gd apply_car(). Wheels stay
		# procedural. Only this car carries the flag.
		"use_model": true,
	},
	{
		"name": "Audi RS3",  # 8Y: ~1575 kg, 401 hp, turbo inline-5, quattro AWD
		"id": "rs3", "country": "DE", "car_type": "hatch", "max_hp": 1000.0, "reward_tier": 2,
		"mass": 1575.0, "peak_torque": 500.0, "redline": 7000.0,
		"grip_front": 1.08, "grip_rear": 1.20, "shift_time": 0.08,  # 7-speed S-tronic dual-clutch
		"engine_type": 1, "drive_mode": AWD, "drag": 3.70, "downforce_rear": 0.06, "low_octave_mix": 0.0, "volume_db": -5.0, "noise_db": -54.0, "soft_clip_post_gain": 0.07,
		"body": Vector3(1.55, 0.60, 4), "cabin": Vector3(1.50, 0.52, 1.70),
		"cabin_z": 0.15, "track": 1.57, "wheelbase": 2.63,
		"wheel_radius": 0.335, "wheel_width": 0.235,
		"suspension_travel": 0.45, "suspension_stiffness": 13.0,  # firm AWD hot hatch
	},
	{
		"name": "Porsche 911",  # 992 Carrera: ~1505 kg, 379 hp, flat-6 (smooth six), RWD
		"id": "porsche911", "country": "DE", "car_type": "coupe", "max_hp": 950.0, "reward_tier": 3,
		"mass": 1505.0, "peak_torque": 450.0, "redline": 7500.0,
		"grip_front": 1.14, "grip_rear": 1.26, "shift_time": 0.06,  # 8-speed PDK
		"engine_type": 2, "drive_mode": RWD, "drag": 3.35, "downforce_rear": 0.06, "low_octave_mix": 0.0, "volume_db": -5.0, "noise_db": -54.0, "soft_clip_post_gain": 0.08,
		"body": Vector3(1.85, 0.52, 4.52), "cabin": Vector3(1.45, 0.48, 1.55),
		"cabin_z": 0.10, "track": 1.58, "wheelbase": 2.45,
		"wheel_radius": 0.34, "wheel_width": 0.245,
		"suspension_travel": 0.42, "suspension_stiffness": 15.0,  # taut sports car, lower ride
	},
	{
		"name": "Lexus LFA",  # ~1580 kg, 553 hp, 4.8 V10 screamer, front-mid RWD
		"id": "lfa", "country": "JP", "car_type": "coupe", "max_hp": 1000.0, "reward_tier": 3,
		"mass": 1580.0, "peak_torque": 480.0, "redline": 9000.0,
		"grip_front": 1.20, "grip_rear": 1.32, "shift_time": 0.16,  # automated single-clutch ASG
		"engine_type": 5, "drive_mode": RWD, "drag": 3.17, "downforce_rear": 0.06, "low_octave_mix": 0.5, "volume_db": 7.0, "noise_db": -54.0, "soft_clip_post_gain": 0.08,
		"body": Vector3(1.895, 0.48, 4.51), "cabin": Vector3(1.45, 0.46, 1.60),
		"cabin_z": 0.10, "track": 1.58, "wheelbase": 2.605,
		"wheel_radius": 0.34, "wheel_width": 0.255,
		"suspension_travel": 0.40, "suspension_stiffness": 16.0,  # stiff front-mid GT
	},
	{
		"name": "Ford Mustang GT",  # S550: ~1720 kg, 460 hp, 5.0 V8 muscle, RWD
		"id": "mustang", "country": "US", "car_type": "coupe", "max_hp": 1100.0, "reward_tier": 2,
		"mass": 1720.0, "peak_torque": 569.0, "redline": 7500.0,
		"grip_front": 1.08, "grip_rear": 1.08, "shift_time": 0.22,  # 6-speed manual muscle
		"engine_type": 4, "drive_mode": RWD, "drag": 3.88, "downforce_rear": 0.06, "low_octave_mix": 0.8, "volume_db": 7.0, "noise_db": -54.0, "soft_clip_post_gain": 0.1,
		"body": Vector3(1.92, 0.55, 4.78), "cabin": Vector3(1.55, 0.50, 1.75),
		"cabin_z": 0.30, "track": 1.62, "wheelbase": 2.72,
		"wheel_radius": 0.34, "wheel_width": 0.255,
		"suspension_travel": 0.55, "suspension_stiffness": 11.0,  # heavy muscle car, softer & taller
	},
	{
		"name": "Lamborghini Aventador",  # LP 700-4: ~1731 kg, 690 hp, 6.5 V12, AWD
		"id": "aventador", "country": "IT", "car_type": "coupe", "max_hp": 1100.0, "reward_tier": 4,
		"mass": 1731.0, "peak_torque": 690.0, "redline": 8350.0,
		"grip_front": 1.18, "grip_rear": 1.20, "shift_time": 0.05,  # ISR single-clutch, ~50 ms shift
		"engine_type": 6, "drive_mode": AWD, "drag": 3.35, "downforce_rear": 0.06, "low_octave_mix": 0.5, "volume_db": 10.0, "noise_db": -54.0, "soft_clip_post_gain": 0.1,
		"body": Vector3(2.03, 0.45, 4.78), "cabin": Vector3(1.55, 0.44, 1.55),
		"cabin_z": 0.05, "track": 1.72, "wheelbase": 2.70,
		"wheel_radius": 0.35, "wheel_width": 0.30,
		"suspension_travel": 0.38, "suspension_stiffness": 18.0,  # very stiff supercar, lowest ride
	},
]


# --- Stable-id lookups -------------------------------------------------------
# Ownership is persisted by the stable string `id` (not array index), so the
# save system survives the roster being reordered or extended. These resolve a
# stored id back to the current array position / entry.

# Array position of the car with this stable id, or -1 if no such car exists
# (e.g. a car removed from the roster — the save system drops orphaned entries).
static func index_of(id: String) -> int:
	for i in CARS.size():
		if CARS[i]["id"] == id:
			return i
	return -1


# The CarLibrary entry for a stable id, or an empty Dictionary if unknown.
static func by_id(id: String) -> Dictionary:
	var i := index_of(id)
	return CARS[i] if i >= 0 else {}


# A rough power-to-weight figure (kW per kg) derived from the published torque,
# redline and mass — NOT stored, recomputed on demand for reward-tier defaults
# and the stats panel. Peak power ~ torque x angular speed at redline; the exact
# constant is a tuning detail, this is only a relative ranking heuristic.
static func power_to_weight(entry: Dictionary) -> float:
	var torque: float = entry.get("peak_torque", 0.0)
	var redline: float = entry.get("redline", 0.0)
	var mass: float = entry.get("mass", 1.0)
	if mass <= 0.0:
		return 0.0
	var peak_power_kw := torque * redline * (TAU / 60.0) / 1000.0
	return peak_power_kw / mass
