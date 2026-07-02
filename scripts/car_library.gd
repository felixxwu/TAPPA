class_name CarLibrary
extends RefCounted
# A small roster of selectable cars, cycled in-game with the HUD's car button
# (see hud.gd) and applied by car.gd's apply_car(). Each entry overlays the
# neutral baseline tuning (car.tscn + game_config.tres) with one real car's
# character: body/cabin box dimensions, wheelbase and track, wheel/tyre size,
# mass, tyre grip, aero drag, shift_time (gearbox shift speed), the driven
# axle layout, and an "engine" id naming its powerplant in EngineLibrary
# (scripts/engine_library.gd) — the single source of truth for ALL engine
# data (cylinders/firing, torque, redline, inertia, and the voicing fields
# low_octave_mix/volume_db/noise_db/soft_clip_post_gain). See
# EngineLibrary.apply(), which car.gd's apply_car() calls with the resolved
# engine.
#
# Dimensions (length / width / wheelbase / track) come from manufacturer spec
# data and are used directly in metres (Godot units = metres).
#
# Dynamics values are in real SI units, matching GameConfig (mass in kg),
# anchored to the Mazda MX-5:
#   * mass     — the car's real kerb mass in kg.
#   * gear_ratios / final_drive — the gearbox (GameConfig.gear_ratios /
#                final_drive). apply_car copies them in AFTER EngineLibrary.apply
#                (which only sets torque / redline / firing), and EngineSim handles
#                any number of forward gears. Each car now carries its OWN real
#                published transmission ratios (per-car; see each entry's comment for
#                the box modelled), so gearing character differs across the roster —
#                a 3-speed TorqueFlite Charger vs an 8-speed PDK 911. Only the
#                final_drive is a game value, kept deliberately higher than the real
#                ~3-4 (tuned per car) so each pulls cleanly against Jolt's built-in
#                rolling resistance (see the drag note below); the internal ratios are real.
#   * drag     — quadratic aero drag coefficient (GameConfig.drag_coefficient):
#                the force is drag x speed². NOTE these are deliberately SMALL: the
#                physics engine (Jolt VehicleBody3D) already applies a large
#                baseline rolling resistance of its own (~0.2 g, mass-proportional;
#                see features/drivetrain-and-tires.md), which on its own already
#                lands the cars near their real top speeds. drag is therefore sized
#                only to TOP UP that baseline to the realistic total — NOT to be the
#                whole aero force — and was tuned per car by measuring top speed in
#                the sim. Draggy bodies (Mustang) still need a real coefficient;
#                slippery coupes (LFA, Aventador) sit near zero because the engine's
#                baseline alone already meets (or slightly exceeds) the resistance
#                for their real top speed.
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
#   * weight_front — the car's real static front-axle weight fraction (0..1):
#                0.50 = 50/50, >0.5 = nose-heavy (front-engine FWD), <0.5 = tail-heavy
#                (mid/rear-engine). apply_car() turns this into the RigidBody's custom
#                center_of_mass along the wheelbase (z = wheelbase x (rear_frac - 0.5),
#                +Z = rearward), so the suspension settles the real static load split
#                onto each axle — which feeds tyre grip via Drivetrain.wheel_normal_force
#                and shifts the car's understeer/oversteer balance. Defaults to 0.50
#                (auto/centred) when omitted. Only the front/rear split is authored; CoG
#                height stays at the body origin (published height data is scarce and the
#                low wheel_roll_influence damps its effect anyway). See features/car-physics.md.
#
# drive_mode matches Drivetrain.DriveMode: 0 RWD, 1 AWD, 2 FWD.
#
# bonnet_cam_offset (Vector3, metres, car-local) nudges the bonnet/hood camera on
# top of the shared GameConfig.bonnet_offset so each body can sit its hood cam at
# the right spot. Defaults to Vector3.ZERO; read via car.gd bonnet_cam_offset()
# and applied in CameraManager.retarget(). See features/camera.md.

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
		"name": "MX-5",  # ND: ~1058 kg, 181 hp, 2.0 i4, light RWD roadster
		"id": "mx5", "country": "JP", "car_type": "roadster", "max_hp": 800.0, "reward_tier": 1,
		"mass": 1058.0, "engine": "mazda_20_i4", "weight_front": 0.50,  # ND: famous 50/50
		# Real ND 6-speed manual ratios: 5.087/2.991/2.035/1.594/1.286/1.000.
		# final_drive is game-tuned to 3.5, NOT the real 2.866: the MX-5's real ~150 hp
		# (in-sim) can't pull the tall real final drive against the Jolt VehicleBody3D's
		# built-in ~0.2 g rolling resistance (it stalls/crawls, stuck below the auto
		# box's upshift point in 3rd). 3.5 is the shortest drive that still drives
		# cleanly — gears 5/6 sit above its ~95 km/h power-limited top, so they go
		# unused, but 1st-4th carry the real spacing that calms the mid-gear punch and
		# stops the 4th-gear wheelspin. This box drives well, so the whole roster now
		# shares it (see the gear_ratios header note). See features/drivetrain-and-tires.md.
		"gear_ratios": [5.087, 2.991, 2.035, 1.594, 1.286, 1.000], "final_drive": 7,
		"grip_front": 1, "grip_rear": 1, "shift_time": 0.30,  # manual H-pattern roadster
		"drive_mode": RWD, "drag": 0, "downforce_rear": 0,
		"bonnet_cam_offset": Vector3(0, 0, 0),  # local-space nudge for the hood cam; tweak per body
		"body": Vector3(1.5, 0.50, 3.8), "cabin": Vector3(1.35, 0.45, 1.40),
		"cabin_z": 0.25, "track": 1.4, "wheelbase": 2.45,
		"wheel_radius": 0.30, "wheel_width": 0.195,
		"suspension_travel": 0.42, "suspension_stiffness": 10.0,  # compliant roadster baseline
		# Renders the authored blender/mx5/mx5.glb body (Car/Mx5Body) instead of the
		# procedural chassis+cabin boxes; see car.gd apply_car(). Wheels stay
		# procedural. Only this car carries the flag.
		"use_model": true,
		"model_node": "Mx5Body",
		"model_texture": "res://blender/mx5/mx5_texture.png",
		"wheel_texture": "res://blender/mx5/wheel.png",
	},
	{
		"name": "Focus ST",  # Mk2 2009: ~1467 kg, 225 PS, 2.5 turbo i5, FWD hot hatch
		"id": "focus", "country": "US", "car_type": "hatch", "max_hp": 950.0, "reward_tier": 1,
		"mass": 1467.0, "engine": "ford_25t_i5", "weight_front": 0.62,  # transverse turbo I5, nose-heavy FWD
		# Real Getrag M66 6-speed ratios (Focus ST Mk2 2.5T).
		"gear_ratios": [3.385, 2.050, 1.433, 1.088, 0.868, 0.700], "final_drive": 10,
		"grip_front": 1, "grip_rear": 0.85, "shift_time": 0.30,  # 6-speed manual, FWD
		"drive_mode": FWD, "drag": 0, "downforce_rear": 0,
		"bonnet_cam_offset": Vector3(0.0, 0.2, 0),  # local-space nudge for the hood cam; tweak per body
		# Hitbox from blender/focus/focus.glb: L 4.30 m, W 1.84 m (real width; the glb's
		# 1.89 includes the mirrors, excluded from collision as for the MX-5).
		"body": Vector3(1.84, 0.52, 4.30), "cabin": Vector3(1.55, 0.50, 1.60),
		"cabin_z": 0.10, "track": 1.6, "wheelbase": 2.7,
		"wheel_radius": 0.35, "wheel_width": 0.235,
		"suspension_travel": 0.45, "suspension_stiffness": 10.0,  # firm hot hatch
		# Renders blender/focus/focus.glb (Car/FocusBody) with its baked texture; see
		# car.gd apply_car(). Wheels use the Focus's own wheel.png.
		"use_model": true,
		"model_node": "FocusBody",
		"model_texture": "res://blender/focus/focus_texture.png",
		"wheel_texture": "res://blender/focus/wheel.png",
	},
	{
		"name": "Twingo",  # Mk1 (C06) 1.2 16V: ~890 kg, 75 PS, light FWD city car
		"id": "twingo", "country": "FR", "car_type": "hatch", "max_hp": 700.0, "reward_tier": 1,
		"mass": 890.0, "engine": "renault_12_i4", "weight_front": 0.62,  # transverse FWD city car, nose-heavy
		# Real Renault JB1 5-speed ratios (Twingo Mk1 1.2 16V).
		"gear_ratios": [3.364, 1.864, 1.321, 0.967, 0.756], "final_drive": 9,
		"grip_front": 0.5, "grip_rear": 0.6, "shift_time": 0.35,  # 5-speed manual, skinny tyres, FWD
		"drive_mode": FWD, "drag": 0, "downforce_rear": 0,
		"bonnet_cam_offset": Vector3(0, 0, -0.1),  # local-space nudge for the hood cam; tweak per body
		# Hitbox from blender/twingo/twingo.glb: L 3.38 m, W 1.63 m (real body width).
		"body": Vector3(1.63, 0.50, 3.38), "cabin": Vector3(1.45, 0.55, 1.50),
		"cabin_z": 0.10, "track": 1.5, "wheelbase": 2.345,
		"wheel_radius": 0.28, "wheel_width": 0.165,
		"suspension_travel": 0.4, "suspension_stiffness": 9.0,  # soft, tall city car
		# Renders blender/twingo/twingo.glb (Car/TwingoBody) with its baked texture; see
		# car.gd apply_car(). Wheels use the Twingo's own wheel.png.
		"use_model": true,
		"model_node": "TwingoBody",
		"model_texture": "res://blender/twingo/twingo_texture.png",
		"wheel_texture": "res://blender/twingo/wheel.png",
	},
	# {
	# 	"name": "Audi RS3",  # 8Y: ~1575 kg, 401 hp, turbo inline-5, quattro AWD
	# 	"id": "rs3", "country": "DE", "car_type": "hatch", "max_hp": 1000.0, "reward_tier": 1,
	# 	"mass": 1575.0, "engine": "audi_25t_i5", "weight_front": 0.59,  # transverse turbo I5 quattro, nose-heavy
	# 	# Real 7-speed S tronic (DQ500-class) ratios (Audi RS3 8Y).
	# 	"gear_ratios": [3.563, 2.526, 1.679, 1.022, 0.788, 0.761, 0.635], "final_drive": 12,
	# 	"grip_front": 1, "grip_rear": 0.8, "shift_time": 0.08,  # 7-speed S-tronic dual-clutch
	# 	"drive_mode": AWD, "drag": 0, "downforce_rear": 0,
	# 	"bonnet_cam_offset": Vector3.ZERO,  # local-space nudge for the hood cam; tweak per body
	# 	"body": Vector3(1.55, 0.60, 4), "cabin": Vector3(1.50, 0.52, 1.70),
	# 	"cabin_z": 0.15, "track": 1.57, "wheelbase": 2.63,
	# 	"wheel_radius": 0.335, "wheel_width": 0.235,
	# 	"suspension_travel": 0.45, "suspension_stiffness": 13.0,  # firm AWD hot hatch
	# },
	{
		"name": "Honda Acty",  # HA4 kei truck: ~740 kg, 656cc mid-engine triple, RWD
		"id": "acty", "country": "JP", "car_type": "kei", "max_hp": 650.0, "reward_tier": 1,
		"mass": 740.0, "engine": "honda_066_i3", "weight_front": 0.45,  # mid-engine cab-over kei, tail-heavy
		# Real Honda Acty HA4 5-speed ratios; kept on the high final_drive so its ~44 hp
		# still pulls (see the gear_ratios header note).
		"gear_ratios": [4.083, 2.500, 1.680, 1.064, 0.861], "final_drive": 9,
		"grip_front": 0.45, "grip_rear": 0.45, "shift_time": 0.35,  # 5-speed manual, skinny tyres, mid-engine RWD
		"drive_mode": AWD, "drag": 0, "downforce_rear": 0,
		"bonnet_cam_offset": Vector3.ZERO,  # local-space nudge for the hood cam; tweak per body
		# Hitbox from blender/acty/acty.glb: L 3.35 m, W 1.42 m (real body width; the real
		# HA4 is 3.40 m x 1.48 m). Tall cab-over body, so a taller collision box.
		"body": Vector3(1.42, 0.70, 3.35), "cabin": Vector3(1.35, 0.75, 1.10),
		"cabin_z": -0.95, "track": 1.21, "wheelbase": 1.90,
		"wheel_radius": 0.27, "wheel_width": 0.145,
		"suspension_travel": 0.40, "suspension_stiffness": 9.0,  # soft, tall little truck
		# Renders blender/acty/acty.glb (Car/ActyBody) with the texture extracted from
		# the glb's embedded image; see car.gd apply_car(). Wheels use its own wheel.png.
		"use_model": true,
		"model_node": "ActyBody",
		"model_texture": "res://blender/acty/acty_texture.png",
		"wheel_texture": "res://blender/acty/wheel.png",
	},
	{
		"name": "Charger R/T",  # '69 Dodge Charger R/T: ~1750 kg, 440 Magnum V8, RWD muscle
		"id": "charger", "country": "US", "car_type": "muscle", "max_hp": 1100.0, "reward_tier": 2,
		"mass": 1750.0, "engine": "mopar_440_v8", "weight_front": 0.56,  # big-block V8 up front, nose-heavy
		# Real 3-speed TorqueFlite A727 automatic ratios ('69 Charger R/T 440).
		"gear_ratios": [2.45, 1.45, 1.00], "final_drive": 4,
		"grip_front": 1, "grip_rear": 0.9, "shift_time": 0.30,  # 3-speed TorqueFlite auto, RWD
		"drive_mode": RWD, "drag": 0.05, "downforce_rear": 0,
		"bonnet_cam_offset": Vector3.ZERO,  # local-space nudge for the hood cam; tweak per body
		# Hitbox from blender/charger/charger.glb: L 5.28 m, W 1.88 m (real '69 R/T is
		# 5.28 m x 1.95 m). Long, low, heavy coupe.
		"body": Vector3(1.90, 0.55, 5.28), "cabin": Vector3(1.55, 0.50, 1.80),
		"cabin_z": 0.35, "track": 1.6, "wheelbase": 3,
		"wheel_radius": 0.36, "wheel_width": 0.225,
		"suspension_travel": 0.42, "suspension_stiffness": 10.0,  # soft, heavy muscle car
		# Renders blender/charger/charger.glb (Car/ChargerBody) with the texture extracted
		# from the glb's embedded image; see car.gd apply_car(). Wheels use its own wheel.png.
		"use_model": true,
		"model_node": "ChargerBody",
		"model_texture": "res://blender/charger/charger_texture.png",
		"wheel_texture": "res://blender/charger/wheel.png",
	},
	{
		"name": "Ford Mustang GT",  # S550: ~1720 kg, 460 hp, 5.0 V8 muscle, RWD
		"id": "mustang", "country": "US", "car_type": "muscle", "max_hp": 1100.0, "reward_tier": 1,
		"mass": 1720.0, "engine": "ford_50_v8", "weight_front": 0.53,  # front V8, mild nose bias
		# Real Getrag MT82 6-speed ratios (Mustang GT S550, 2015-17).
		"gear_ratios": [3.66, 2.43, 1.69, 1.32, 1.00, 0.65], "final_drive": 7,
		"grip_front": 1.1, "grip_rear": 0.9, "shift_time": 0.22,  # 6-speed manual muscle
		"drive_mode": RWD, "drag": 0, "downforce_rear": 0,
		"bonnet_cam_offset": Vector3.ZERO,  # local-space nudge for the hood cam; tweak per body
		"body": Vector3(1.92, 0.55, 4.78), "cabin": Vector3(1.55, 0.50, 1.75),
		"cabin_z": 0.30, "track": 1.62, "wheelbase": 2.72,
		"wheel_radius": 0.34, "wheel_width": 0.255,
		"suspension_travel": 0.55, "suspension_stiffness": 11.0,  # heavy muscle car, softer & taller
	},
	{
		"name": "Porsche 911",  # 992 Carrera: ~1505 kg, 379 hp, flat-6 (smooth six), RWD
		"id": "porsche911", "country": "DE", "car_type": "coupe", "max_hp": 950.0, "reward_tier": 2,
		"mass": 1505.0, "engine": "porsche_30_flat6", "weight_front": 0.39,  # rear-engine flat-6, tail-heavy ~39/61
		# Real 8-speed PDK ratios (Porsche 911 992 Carrera).
		"gear_ratios": [4.89, 3.17, 2.15, 1.56, 1.18, 0.94, 0.76, 0.61], "final_drive": 7,
		"grip_front": 1.1, "grip_rear": 0.9, "shift_time": 0.06,  # 8-speed PDK
		"drive_mode": RWD, "drag": 0, "downforce_rear": 0,
		"bonnet_cam_offset": Vector3.ZERO,  # local-space nudge for the hood cam; tweak per body
		"body": Vector3(1.85, 0.52, 4.52), "cabin": Vector3(1.45, 0.48, 1.55),
		"cabin_z": 0.10, "track": 1.58, "wheelbase": 2.45,
		"wheel_radius": 0.34, "wheel_width": 0.245,
		"suspension_travel": 0.42, "suspension_stiffness": 15.0,  # taut sports car, lower ride
	},
	{
		"name": "Lexus LFA",  # ~1580 kg, 553 hp, 4.8 V10 screamer, front-mid RWD
		"id": "lfa", "country": "JP", "car_type": "coupe", "max_hp": 1000.0, "reward_tier": 3,
		"mass": 1580.0, "engine": "toyota_48_v10", "weight_front": 0.48,  # front-mid V10 + rear transaxle, 48/52
		# Real 6-speed ASG ratios (Lexus LFA).
		"gear_ratios": [3.231, 2.188, 1.609, 1.233, 0.970, 0.795], "final_drive": 7,
		"grip_front": 1.20, "grip_rear": 1, "shift_time": 0.16,  # automated single-clutch ASG
		"drive_mode": RWD, "drag": 0, "downforce_rear": 0,
		"bonnet_cam_offset": Vector3.ZERO,  # local-space nudge for the hood cam; tweak per body
		"body": Vector3(1.895, 0.48, 4.51), "cabin": Vector3(1.45, 0.46, 1.60),
		"cabin_z": 0.10, "track": 1.58, "wheelbase": 2.605,
		"wheel_radius": 0.34, "wheel_width": 0.255,
		"suspension_travel": 0.40, "suspension_stiffness": 16.0,  # stiff front-mid GT
	},
	{
		"name": "Lamborghini Aventador",  # LP 700-4: ~1731 kg, 690 hp, 6.5 V12, AWD
		"id": "aventador", "country": "IT", "car_type": "coupe", "max_hp": 1100.0, "reward_tier": 3,
		"mass": 1731.0, "engine": "lambo_65_v12", "weight_front": 0.43,  # mid V12, tail-heavy ~43/57
		# Real 7-speed ISR ratios (Lamborghini Aventador LP 700-4).
		"gear_ratios": [3.909, 2.438, 1.810, 1.458, 1.185, 0.967, 0.844], "final_drive": 7,
		"grip_front": 1.1, "grip_rear": 0.9, "shift_time": 0.05,  # ISR single-clutch, ~50 ms shift
		"drive_mode": AWD, "drag": 0, "downforce_rear": 0,
		"bonnet_cam_offset": Vector3.ZERO,  # local-space nudge for the hood cam; tweak per body
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
#
# torque/redline resolve from the referenced engine (EngineLibrary) UNLESS the
# entry carries its own "peak_torque"/"redline" — which is how upgrade-adjusted
# stats flow through: UpgradeLibrary.effective_meta() seeds those keys from the
# engine and multiplies them by the installed engine kits, so an upgraded meta
# ranks above the base car. A raw CarLibrary entry has neither key and falls back
# to its engine's published figures.
static func power_to_weight(entry: Dictionary) -> float:
	var eng := EngineLibrary.by_id(entry.get("engine", ""))
	var torque: float = float(entry.get("peak_torque", eng.get("peak_torque", 0.0)))
	var redline: float = float(entry.get("redline", eng.get("redline_rpm", 0.0)))
	var mass: float = entry.get("mass", 1.0)
	if mass <= 0.0:
		return 0.0
	var peak_power_kw := torque * redline * (TAU / 60.0) / 1000.0
	return peak_power_kw / mass
