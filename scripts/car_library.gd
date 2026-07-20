class_name CarLibrary
extends RefCounted
# A small roster of selectable cars, cycled in-game with the HUD's car button
# (see hud.gd) and applied by car.gd's apply_car(). Each entry overlays the
# neutral baseline tuning (car.tscn + game_config.tres) with one real car's
# character: body/cabin box dimensions, wheelbase and track, wheel/tyre size,
# mass, tyre grip, aero drag, the driven axle layout, and an "engine" id naming
# its powerplant in EngineLibrary (scripts/engine_library.gd) — the single source
# of truth for ALL engine data (cylinders/firing, torque, redline, inertia, the
# voicing fields low_octave_mix/volume_db/noise_db/soft_clip_post_gain, AND the
# TRANSMISSION bolted to it: gear_ratios / final_drive / shift_time). See
# EngineLibrary.apply(), which car.gd's apply_car() calls with the resolved engine.
# Because the gearbox lives on the engine, an ENGINE SWAP (features/engine-swap.md)
# carries the whole drivetrain to the new car — the car entry no longer authors any
# gearbox field.
#
# Dimensions (length / width / wheelbase / track) come from manufacturer spec
# data and are used directly in metres (Godot units = metres).
#
# Dynamics values are in real SI units, matching GameConfig (mass in kg),
# anchored to the Mazda MX-5:
#   * mass     — the car's real kerb mass in kg.
#   * (gearbox) — gear_ratios / final_drive / shift_time NO LONGER live here; they
#                moved onto the ENGINE (EngineLibrary), so a swapped engine brings its
#                own transmission. See EngineLibrary's header for the tuning rationale
#                (real internal ratios; game-tuned final_drive against Jolt's baseline
#                rolling resistance; manual-slow vs PDK-fast shift_time).
#   * drag     — quadratic aero drag coefficient (GameConfig.drag_coefficient):
#                the force is drag x speed². NOTE these are deliberately SMALL: the
#                physics engine (Jolt VehicleBody3D) already applies a large
#                baseline rolling resistance of its own (~0.2 g, mass-proportional;
#                see features/drivetrain-and-tires.md), which on its own already
#                lands the cars near their real top speeds. drag is therefore sized
#                only to TOP UP that baseline to the realistic total — NOT to be the
#                whole aero force — and was tuned per car by measuring top speed in
#                the sim. Draggy bodies (Charger) still need a real coefficient;
#                slippery coupes (Viper, XJS) sit near zero because the engine's
#                baseline alone already meets (or slightly exceeds) the resistance
#                for their real top speed.
#   * tire_compound — ONE dimensionless rubber-grip coefficient per car (same
#                compound both axles), ~0.85 for hard economy/commercial tyres up to
#                ~1.30 for track semi-slicks. This is only the RUBBER; effective μ is
#                tire_compound × the load-sensitivity factor (GameConfig.tire_load_factor,
#                keyed off wheel_width_front/rear + the load each axle carries). So a
#                car's front/rear grip BALANCE emerges physically from its widths and
#                weight_front — no per-axle grip knob. apply_car() seeds BOTH
#                wheel_friction_slip_front/rear from this; the grip_balance tuning slider
#                then trims them. Rollover from high lateral force is held off by the low
#                wheel_roll_influence (GameConfig, 0.1) — watch the taller bodies
#                (Charger-like) in hard turns if compounds climb much further.
#   * downforce_front / downforce_rear — aero downforce (N per (m/s)² at each axle,
#                GameConfig.downforce_*). apply_car() SETS these from the spec (so a
#                car with 0 has none — no hidden global baseline), and the aero_kit
#                upgrade adds on top. All cars carry a small rear value to keep the
#                tail planted under power; front defaults to 0 when omitted.
#   * steer_assist_torque — per-car yaw torque (N·m) of the understeer steering aid
#                (GameConfig.steer_assist_torque). apply_car() SETS this from the spec
#                (default 0 → no assist; no hidden global baseline), so the aid is a
#                per-car character knob, not a global. Only the Focus authors a value.
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
# brake_bias (0..1) is the car's default front share of foot-brake torque, copied
# onto cfg.brake_bias in car.gd apply_car(). It's the baseline the brakes-kit
# tuning slider re-centres on (TuningLibrary.apply, ±tuning_brake_authority);
# without the kit the car simply keeps this default. Omit to fall back to the
# GameConfig.brake_bias default. Higher = more front braking. See features/tuning.md.
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
# wheel positions; wheel_radius sizes the tyre cylinders and wheel_width_front /
# wheel_width_rear set each axle's tyre width (visual AND grip via load sensitivity).
#
# suspension_travel (m) is the spring's working length — it also doubles as the
# wheel raycast / rest length (GameConfig.suspension_travel), so a shorter travel
# also sits the car lower. suspension_stiffness is the spring rate
# (GameConfig.suspension_stiffness); the compression/rebound dampers are derived
# from it (critically damped, see GameConfig.suspension_damping_*), not specified
# per car. Soft & tall roadster/muscle (MX-5, Charger) vs stiff & low supercars
# (911, Viper, XJS).
const CARS: Array[Dictionary] = [
	{
		"name": "MX-5",  # ND: ~1058 kg, 181 hp, 2.0 i4, light RWD roadster
		"id": "mx5", "country": "JP", "car_type": "roadster", "max_hp": 800.0, "reward_tier": 1,
		"mass": 1058.0, "engine": "mazda_20_i4", "weight_front": 0.50, "engine_pos": 0.85,  # ND: famous 50/50
		"tire_compound": 0.93,  # sport touring tyres (transmission lives on the engine — EngineLibrary)
		"brake_bias": 0.25,  # front share of foot-brake torque (50/50 RWD roadster)
		"drive_mode": RWD, "drag": 0, "downforce_rear": 0, "steer_assist_torque": 1000,
		"bonnet_cam_offset": Vector3(0, 0, 0),  # local-space nudge for the hood cam; tweak per body
		"body": Vector3(1.5, 0.50, 3.8), "cabin": Vector3(1.35, 0.45, 1.40),
		"cabin_z": 0.25, "track": 1.4, "wheelbase": 2.45,
		"wheel_radius": 0.30, "wheel_width_front": 0.195, "wheel_width_rear": 0.195,  # 195/50R16 square
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
		"name": "Focus",  # 2009 (US Mk2.5): ~1190 kg, 140 hp, 2.0 NA Duratec i4, FWD compact
		"id": "focus", "country": "US", "car_type": "hatch", "max_hp": 950.0, "reward_tier": 1,
		"mass": 1190.0, "engine": "ford_20_i4", "weight_front": 0.62, "engine_pos": 0.85,  # transverse NA I4, nose-heavy FWD
		"tire_compound": 0.88,  # economy / touring all-season tyres
		"brake_bias": 0.25,  # front share of foot-brake torque (nose-heavy FWD)
		"drive_mode": FWD, "drag": 0, "downforce_rear": 0, "steer_assist_torque": 10000,
		"bonnet_cam_offset": Vector3(0.0, 0.2, 0),  # local-space nudge for the hood cam; tweak per body
		# Hitbox from blender/focus/focus.glb: L 4.30 m, W 1.84 m (real width; the glb's
		# 1.89 includes the mirrors, excluded from collision as for the MX-5).
		"body": Vector3(1.84, 0.52, 4.30), "cabin": Vector3(1.55, 0.50, 1.60),
		"cabin_z": 0.10, "track": 1.6, "wheelbase": 2.7,
		"wheel_radius": 0.31, "wheel_width_front": 0.205, "wheel_width_rear": 0.205,  # 205/55R16 square, FWD
		"suspension_travel": 0.45, "suspension_stiffness": 9.0,  # compliant compact hatch
		# Renders blender/focus/focus.glb (Car/FocusBody) with its baked texture; see
		# car.gd apply_car(). Wheels use the Focus's own wheel.png.
		"use_model": true,
		"model_node": "FocusBody",
		"model_texture": "res://blender/focus/focus_texture.png",
		"wheel_texture": "res://blender/focus/wheel.png",
	},
	{
		"name": "Twingo",  # Mk1 (C06) 1.2 16V: ~950 kg, 75 PS, light FWD city car
		"id": "twingo", "country": "FR", "car_type": "hatch", "max_hp": 700.0, "reward_tier": 1,
		"mass": 950.0, "engine": "renault_12_i4", "weight_front": 0.62, "engine_pos": 0.85,  # transverse FWD city car, nose-heavy
		"tire_compound": 0.85,  # hard economy tyres, skinny
		"brake_bias": 0.25,  # front share of foot-brake torque (nose-heavy FWD)
		"drive_mode": FWD, "drag": 0, "downforce_rear": 0, "steer_assist_torque": 0,
		"bonnet_cam_offset": Vector3(0, 0, -0.1),  # local-space nudge for the hood cam; tweak per body
		# Hitbox from blender/twingo/twingo.glb: L 3.38 m, W 1.63 m (real body width).
		"body": Vector3(1.63, 0.50, 3.38), "cabin": Vector3(1.45, 0.55, 1.50),
		"cabin_z": 0.10, "track": 1.5, "wheelbase": 2.345,
		"wheel_radius": 0.28, "wheel_width_front": 0.165, "wheel_width_rear": 0.165,  # 165/65R14 skinny
		"suspension_travel": 0.4, "suspension_stiffness": 9.0,  # soft, tall city car
		# Renders blender/twingo/twingo.glb (Car/TwingoBody) with its baked texture; see
		# car.gd apply_car(). Wheels use the Twingo's own wheel.png.
		"use_model": true,
		"model_node": "TwingoBody",
		"model_texture": "res://blender/twingo/twingo_texture.png",
		"wheel_texture": "res://blender/twingo/wheel.png",
	},
	{
		"name": "Honda Acty",  # HA4 kei truck: ~780 kg, 656cc mid-engine triple
		"id": "acty", "country": "JP", "car_type": "kei", "max_hp": 650.0, "reward_tier": 1,
		"mass": 780.0, "engine": "honda_066_i3", "weight_front": 0.45, "engine_pos": 0.35,  # mid-engine cab-over kei, tail-heavy
		"tire_compound": 0.8,  # hard commercial tyres, skinny
		"brake_bias": 0.2,  # front share of foot-brake torque (mid-engine, tail-heavy)
		"drive_mode": AWD, "drag": 0, "downforce_rear": 0, "steer_assist_torque": 0,
		"bonnet_cam_offset": Vector3.ZERO,  # local-space nudge for the hood cam; tweak per body
		# Hitbox from blender/acty/acty.glb: L 3.35 m, W 1.42 m (real body width; the real
		# HA4 is 3.40 m x 1.48 m). Tall cab-over body, so a taller collision box.
		"body": Vector3(1.42, 0.70, 3.35), "cabin": Vector3(1.35, 0.75, 1.10),
		"cabin_z": -0.95, "track": 1.21, "wheelbase": 1.90,
		"wheel_radius": 0.27, "wheel_width_front": 0.145, "wheel_width_rear": 0.145,  # 145R12 kei, very skinny
		"suspension_travel": 0.40, "suspension_stiffness": 9.0,  # soft, tall little truck
		# Renders blender/acty/acty.glb (Car/ActyBody) with the texture extracted from
		# the glb's embedded image; see car.gd apply_car(). Wheels use its own wheel.png.
		"use_model": true,
		"model_node": "ActyBody",
		"model_texture": "res://blender/acty/acty_texture.png",
		"wheel_texture": "res://blender/acty/wheel.png",
	},
	{
		"name": "Charger R/T",  # '69 Dodge Charger R/T: ~1670 kg, 440 Magnum V8, RWD muscle
		"id": "charger", "country": "US", "car_type": "muscle", "max_hp": 1100.0, "reward_tier": 1,
		"mass": 1670.0, "engine": "mopar_440_v8", "weight_front": 0.56, "engine_pos": 0.85,  # big-block V8 up front, nose-heavy
		"tire_compound": 0.95,  # touring tyres
		"brake_bias": 0.25,  # front share of foot-brake torque (nose-heavy RWD muscle)
		"drive_mode": RWD, "drag": 0.05, "downforce_rear": 0, "steer_assist_torque": 0,
		"bonnet_cam_offset": Vector3.ZERO,  # local-space nudge for the hood cam; tweak per body
		# Hitbox from blender/charger/charger.glb: L 5.28 m, W 1.88 m (real '69 R/T is
		# 5.28 m x 1.95 m). Long, low, heavy coupe.
		"body": Vector3(1.90, 0.55, 5.28), "cabin": Vector3(1.55, 0.50, 1.80),
		"cabin_z": 0.35, "track": 1.6, "wheelbase": 3,
		"wheel_radius": 0.36, "wheel_width_front": 0.235, "wheel_width_rear": 0.255,  # mild muscle stagger
		"suspension_travel": 0.42, "suspension_stiffness": 10.0,  # soft, heavy muscle car
		# Renders blender/charger/charger.glb (Car/ChargerBody) with the texture extracted
		# from the glb's embedded image; see car.gd apply_car(). Wheels use its own wheel.png.
		"use_model": true,
		"model_node": "ChargerBody",
		"model_texture": "res://blender/charger/charger_texture.png",
		"wheel_texture": "res://blender/charger/wheel.png",
	},
	{
		"name": "911 Turbo",  # 1975 930 Turbo 3.0: ~1140 kg, 260 PS, turbo flat-6, RWD, 4-speed
		"id": "porsche911", "country": "DE", "car_type": "coupe", "max_hp": 950.0, "reward_tier": 2,
		"mass": 1140.0, "engine": "porsche_30_flat6", "weight_front": 0.41, "engine_pos": 0.10,  # rear-engine flat-6, tail-heavy ~41/59
		"tire_compound": 0.92,
		"brake_bias": 0.2,  # front share of foot-brake torque (rear-engine, tail-heavy)
		"drive_mode": RWD, "drag": 0, "downforce_rear": 0, "steer_assist_torque": 5000,
		"bonnet_cam_offset": Vector3.ZERO,  # local-space nudge for the hood cam; tweak per body
		"body": Vector3(1.75, 0.52, 4.29), "cabin": Vector3(1.40, 0.48, 1.50),
		"cabin_z": 0.10, "track": 1.6, "wheelbase": 2.35,
		"wheel_radius": 0.32, "wheel_width_front": 0.185, "wheel_width_rear": 0.215,  # 185/215 the "wide" 930 stagger
		"suspension_travel": 0.35, "suspension_stiffness": 15.0,  # taut sports car, lower ride
		# Renders blender/911/911.glb (Car/Porsche911Body) with its baked texture; see
		# car.gd apply_car(). Wheels use its own wheel.png.
		"use_model": true,
		"model_node": "Porsche911Body",
		"model_texture": "res://blender/911/texture.png",
		"wheel_texture": "res://blender/911/wheel.png",
	},
	{
		"name": "Dodge Viper RT/10",  # 1st-gen RT/10: ~1520 kg, 400 hp, 8.0 V10, front-mid RWD roadster
		"id": "viper", "country": "US", "car_type": "roadster", "max_hp": 1000.0, "reward_tier": 2,
		"mass": 1520.0, "engine": "dodge_80_v10", "weight_front": 0.49, "engine_pos": 0.60,  # front-mid V10, ~49/51
		"tire_compound": 1.15,  # sticky performance tyres (period bias-belted rubber)
		"brake_bias": 0.25,  # front share of foot-brake torque (~49/51 front-mid RWD)
		"drive_mode": RWD, "drag": 0, "downforce_rear": 0, "steer_assist_torque": 0,
		"bonnet_cam_offset": Vector3.ZERO,  # local-space nudge for the hood cam; tweak per body
		"body": Vector3(1.92, 0.44, 4.45), "cabin": Vector3(1.40, 0.42, 1.45),  # low open roadster
		"cabin_z": 0.10, "track": 1.60, "wheelbase": 2.44,
		"wheel_radius": 0.34, "wheel_width_front": 0.275, "wheel_width_rear": 0.335,  # 275/335 stagger
		"suspension_travel": 0.40, "suspension_stiffness": 15.0,  # firm but a touch softer than the later GTS
	},
	{
		"name": "Jaguar XJS",  # 5.3 V12 HE: ~1755 kg, ~295 hp, front V12, RWD GT
		"id": "xjs", "country": "GB", "car_type": "coupe", "max_hp": 1100.0, "reward_tier": 2,
		"mass": 1755.0, "engine": "jaguar_53_v12", "weight_front": 0.53, "engine_pos": 0.75,  # front V12, nose-heavy ~53/47
		"tire_compound": 0.95,  # period touring / GT tyres
		"brake_bias": 0.2,  # front share of foot-brake torque (nose-heavy RWD GT)
		"drive_mode": RWD, "drag": 0, "downforce_rear": 0, "steer_assist_torque": 4000,
		"bonnet_cam_offset": Vector3.ZERO,  # local-space nudge for the hood cam; tweak per body
		"body": Vector3(1.59, 0.50, 4.87), "cabin": Vector3(1.45, 0.48, 1.70),
		"cabin_z": 0.30, "track": 1.60, "wheelbase": 2.68,
		"wheel_radius": 0.33, "wheel_width_front": 0.215, "wheel_width_rear": 0.235,  # 215/235 mild stagger
		"suspension_travel": 0.35, "suspension_stiffness": 10.0,  # soft long-legged GT
		# Renders blender/xjs/xjs.glb (Car/XjsBody) with its baked texture; see
		# car.gd apply_car(). Wheels use its own wheel.png.
		"use_model": true,
		"model_node": "XjsBody",
		"model_texture": "res://blender/xjs/texture.png",
		"wheel_texture": "res://blender/xjs/wheel.png",
	},
	{
		"name": "The Beast",  # 1972 John Dodd: ~5.9 m one-off, 27 L Rolls-Royce Merlin V12, RWD
		"id": "beast", "country": "GB", "car_type": "muscle", "max_hp": 1200.0, "reward_tier": 2,
		"mass": 1900.0, "engine": "merlin_v27_v12", "weight_front": 0.55, "engine_pos": 0.85,  # vast V12 slung out front, nose-heavy
		"tire_compound": 1.2,  # period touring tyres
		"brake_bias": 0.1,  # front share of foot-brake torque (nose-heavy RWD)
		"drive_mode": RWD, "drag": 0.06, "downforce_rear": 0, "steer_assist_torque": 2000,  # long, brick-like body → real aero drag
		"bonnet_cam_offset": Vector3.ZERO,  # local-space nudge for the hood cam; tweak per body
		# ~19 ft (5.9 m) long one-off; box sized to the real length. Verify fit in-game.
		"body": Vector3(1.90, 0.55, 5.90), "cabin": Vector3(1.45, 0.48, 1.60),
		"cabin_z": 1.40, "track": 1.7, "wheelbase": 3.45,
		"wheel_radius": 0.37, "wheel_width_front": 0.235, "wheel_width_rear": 0.275,  # mild stagger
		"suspension_travel": 0.45, "suspension_stiffness": 11.0,  # heavy long GT, softer ride
		# Renders blender/thebeast/mrbeast.glb (Car/TheBeastBody); see car.gd apply_car().
		"use_model": true,
		"model_node": "TheBeastBody",
		"model_texture": "res://blender/thebeast/mrbeast_texture.png",
		"wheel_texture": "res://blender/thebeast/wheel.png",
	},
]


# --- Stable-id lookups -------------------------------------------------------
# Ownership is persisted by the stable string `id` (not array index), so the
# save system survives the roster being reordered or extended. These resolve a
# stored id back to the current array position / entry.

# Test seam + stable-id lookups via the shared Registry helper (scripts/registry.gd).
# An empty override means "use the shipped CARS"; tests call override_for_test() to
# run against a synthetic roster and reset() in teardown. Inert in production.
static var _seam := Registry.Seam.new(CARS)

static func all() -> Array[Dictionary]:
	return _seam.all()

static func override_for_test(cars: Array[Dictionary]) -> void:
	_seam.override_for_test(cars)

static func reset() -> void:
	_seam.reset()


# Array position of the car with this stable id, or -1 if no such car exists
# (e.g. a car removed from the roster — the save system drops orphaned entries).
static func index_of(id: String) -> int:
	return Registry.index_of(all(), id)


# The CarLibrary entry for a stable id, or an empty Dictionary if unknown.
static func by_id(id: String) -> Dictionary:
	return Registry.by_id(all(), id)


# A real engine's torque has already fallen off by redline, so its true peak power
# sits well below torque × redline speed. This single global factor calibrates
# that falloff: with it, every stock car's derived figure lands within ~±8% of its
# real published power (e.g. Viper 401 hp vs 400, Charger 362 vs 375, boosted 930
# 251 vs 260, MX-5 168 vs 181). One constant for the whole roster — power is
# DERIVED from torque, never authored separately, so retuning an engine's torque
# moves its displayed power with it.
const TORQUE_POWER_FALLOFF := 0.78

# The car's power-to-weight figure (kW per kg) — NOT stored, recomputed on demand
# for reward-tier defaults, the stats panel, and rally pw-band eligibility:
# peak power ≈ peak_torque × redline angular speed × TORQUE_POWER_FALLOFF.
#
# torque/redline resolve from the referenced engine (EngineLibrary) UNLESS the
# entry carries its own "peak_torque"/"redline" — which is how upgrade-adjusted
# stats flow through: UpgradeLibrary.effective_meta() seeds those keys from the
# engine (rating a turbo's torque at peak boost, so the boosted figure is the
# displayed one) and multiplies them by the installed engine kits / detune, so an
# upgraded meta ranks above the base car. A raw CarLibrary entry has neither key
# and derives from its engine's published torque/redline.
# Convert a power-to-weight figure from power_to_weight()'s kW/kg to the hp/tonne
# the HUD / detail panel / detune slider display (1 kW = 1.34102 hp, 1 tonne = 1000 kg).
# Single source of truth — hq.gd and RallyLibrary both multiply by this.
const KW_KG_TO_HP_TONNE := 1341.02
static func power_to_weight(entry: Dictionary) -> float:
	var eng := EngineLibrary.by_id(entry.get("engine", ""))
	var torque: float = float(entry.get("peak_torque", eng.get("peak_torque", 0.0)))
	var redline: float = float(entry.get("redline", eng.get("redline_rpm", 0.0)))
	var mass: float = entry.get("mass", 1.0)
	if mass <= 0.0:
		return 0.0
	var peak_power_kw := torque * redline * (TAU / 60.0) / 1000.0 * TORQUE_POWER_FALLOFF
	return peak_power_kw / mass


# Peak lateral cornering grip, expressed in G. Effective μ = tyre compound × the
# load-sensitivity factor (see GameConfig.tire_load_factor): a real tyre's μ falls as
# the load pressed through its contact patch rises, and a wider tyre spreads that load
# over more rubber. So the figure depends on BOTH width and mass — heavier drops it,
# wider recovers it — unlike the textbook a = μ·g where mass would cancel.
#
# We take each axle's STATIC per-wheel load (mass · g · weight split / 2) through the
# same factor the physics uses, with that axle's width, then average the two axles.
# Using the SHARED GameConfig helper keeps the panel honest about what the car does.
# The grip_balance tuning slider is deliberately ignored — this is a nominal spec-sheet
# figure for car selection, not the currently-tuned car.
static func max_lateral_g(entry: Dictionary, cfg: GameConfig) -> float:
	var g := Platform.gravity()
	var mass: float = float(entry.get("mass", 1.0))
	var wf: float = clampf(float(entry.get("weight_front", 0.5)), 0.0, 1.0)
	var compound := float(entry.get("tire_compound", 1.0))
	var front_load := mass * g * wf * 0.5
	var rear_load := mass * g * (1.0 - wf) * 0.5
	var mu_front := compound * cfg.tire_load_factor(front_load, float(entry.get("wheel_width_front", 0.225)))
	var mu_rear := compound * cfg.tire_load_factor(rear_load, float(entry.get("wheel_width_rear", 0.225)))
	return (mu_front + mu_rear) * 0.5
