class_name EngineLibrary
extends RefCounted
# The catalog of real engines. Each car (CarLibrary) references ONE engine by its
# stable string `id`; car.gd apply_car() resolves it and calls apply(), which is the
# ONLY writer of GameConfig's engine_* fields when a car is fielded.
#
# An engine owns everything engine-ish:
#   * layout        — key into FIRING (also fixes cylinder count = firing angle count).
#                     cylinders + firing angles are the SOUND (even spacing = smooth,
#                     uneven = burble). See features/engine-audio.md.
#   * redline_rpm / peak_torque / peak_torque_rpm — the PERFORMANCE. peak_torque is
#                     real published crank torque (N·m); peak_torque_rpm is where the
#                     preset curve peaks; redline is the real rev limit and MUST sit
#                     above peak_torque_rpm or the torque curve inverts.
#   * engine_inertia — crank+flywheel rotating inertia (kg·m²): small revs fast, large
#                     revs lazily.
#   * mass          — real dry weight (kg), independent of the chassis. Fed to the
#                     engine-swap weight model (features/engine-swap.md).
#   * gear_ratios / final_drive / shift_time — the TRANSMISSION bolted to this engine.
#                     Real published internal ratios + a game-tuned final_drive (kept
#                     higher than the real ~3-4 so each pulls against Jolt's built-in
#                     rolling resistance) + the clutch-open shift cut (manual slow, PDK
#                     fast). apply() writes them, so an ENGINE SWAP carries its whole
#                     drivetrain — gearing spacing, overall ratio, and shift feel — to
#                     the new car (features/engine-swap.md). See features/drivetrain-and-tires.md.
#   * low_octave_mix / volume_db / noise_db / soft_clip_post_gain — the VOICING
#                     (features/engine-audio.md): octave-down crossfade, master level,
#                     broadband-noise level (dB, converted to linear here), and the
#                     post-soft-clip trim.

# Standard firing tables: crank angles (degrees) over the 720° four-stroke cycle,
# shared across engines of the same layout. Even spacing sounds smooth; the uneven
# v6/v8 tables burble. cylinders = the array's length.
const FIRING := {
	"i3":  [0.0, 240.0, 480.0],
	"i4":  [0.0, 180.0, 360.0, 540.0],
	"i5":  [0.0, 144.0, 288.0, 432.0, 576.0],
	"i6":  [0.0, 120.0, 240.0, 360.0, 480.0, 600.0],
	"v6":  [0.0, 90.0, 240.0, 330.0, 480.0, 570.0],
	"v8":  [0.0, 80.0, 180.0, 260.0, 360.0, 440.0, 540.0, 620.0],
	"v10": [0.0, 72.0, 144.0, 216.0, 288.0, 360.0, 432.0, 504.0, 576.0, 648.0],
	"v12": [0.0, 60.0, 120.0, 180.0, 240.0, 300.0, 360.0, 420.0, 480.0, 540.0, 600.0, 660.0],
}

const ENGINES: Array[Dictionary] = [
	{
		"id": "mazda_20_i4", "name": "2.0 Skyactiv-G i4", "layout": "i4", "mass": 110.0,
		"redline_rpm": 7500.0, "peak_torque": 205.0, "peak_torque_rpm": 4500.0, "engine_inertia": 0.15,
		"low_octave_mix": 0.2, "volume_db": -5.0, "noise_db": -54.0, "soft_clip_post_gain": 0.07,
		"gear_ratios": [5.087, 2.991, 2.035, 1.594, 1.286, 1.000], "final_drive": 5, "shift_time": 0.30,  # ND 6-speed manual
	},
	{
		"id": "renault_12_i4", "name": "1.2 16V i4", "layout": "i4", "mass": 95.0,
		"redline_rpm": 6800.0, "peak_torque": 105.0, "peak_torque_rpm": 4500.0, "engine_inertia": 0.13,
		"low_octave_mix": 0.0, "volume_db": -5.0, "noise_db": -54.0, "soft_clip_post_gain": 0.07,
		"gear_ratios": [3.364, 1.864, 1.321, 0.967, 0.756], "final_drive": 8, "shift_time": 0.35,  # JB1 5-speed manual
	},
	{
		"id": "ford_25t_i5", "name": "2.5T Duratec i5", "layout": "i5", "mass": 150.0,
		"redline_rpm": 6800.0, "peak_torque": 320.0, "peak_torque_rpm": 4200.0, "engine_inertia": 0.22,
		"low_octave_mix": 0.1, "volume_db": -5.0, "noise_db": -54.0, "soft_clip_post_gain": 0.07,
		"gear_ratios": [3.385, 2.050, 1.433, 1.088, 0.868, 0.700], "final_drive": 9, "shift_time": 0.30,  # Getrag M66 6-speed
	},
	{
		"id": "audi_25t_i5", "name": "2.5T TFSI i5", "layout": "i5", "mass": 165.0,
		"redline_rpm": 7000.0, "peak_torque": 500.0, "peak_torque_rpm": 4200.0, "engine_inertia": 0.22,
		"low_octave_mix": 0.0, "volume_db": -5.0, "noise_db": -54.0, "soft_clip_post_gain": 0.07,
		"gear_ratios": [3.563, 2.526, 1.679, 1.022, 0.788, 0.761, 0.635], "final_drive": 12, "shift_time": 0.08,  # 7-speed S tronic
	},
	{
		"id": "ford_50_v8", "name": "5.0 Coyote V8", "layout": "v8", "mass": 200.0,
		"redline_rpm": 7500.0, "peak_torque": 569.0, "peak_torque_rpm": 4200.0, "engine_inertia": 0.32,
		"low_octave_mix": 0.8, "volume_db": 7.0, "noise_db": -54.0, "soft_clip_post_gain": 0.1,
		"gear_ratios": [3.66, 2.43, 1.69, 1.32, 1.00, 0.65], "final_drive": 7, "shift_time": 0.22,  # Getrag MT82 6-speed manual
	},
	{
		"id": "mopar_440_v8", "name": "440 Magnum V8", "layout": "v8", "mass": 290.0,
		"redline_rpm": 5500.0, "peak_torque": 600.0, "peak_torque_rpm": 3000.0, "engine_inertia": 0.56,
		"low_octave_mix": 0.8, "volume_db": 8.0, "noise_db": -54.0, "soft_clip_post_gain": 0.1,
		"gear_ratios": [2.45, 1.45, 1.00], "final_drive": 4.5, "shift_time": 0.30,  # TorqueFlite A727 3-speed auto
	},
	{
		"id": "porsche_30_flat6", "name": "3.0 flat-6", "layout": "i6", "mass": 180.0,
		"redline_rpm": 7500.0, "peak_torque": 450.0, "peak_torque_rpm": 4800.0, "engine_inertia": 0.18,
		"low_octave_mix": 0.0, "volume_db": -5.0, "noise_db": -54.0, "soft_clip_post_gain": 0.08,
		"gear_ratios": [4.89, 3.17, 2.15, 1.56, 1.18, 0.94, 0.76, 0.61], "final_drive": 7, "shift_time": 0.06,  # 8-speed PDK
	},
	{
		"id": "toyota_48_v10", "name": "4.8 V10", "layout": "v10", "mass": 220.0,
		"redline_rpm": 9000.0, "peak_torque": 480.0, "peak_torque_rpm": 6000.0, "engine_inertia": 0.10,
		"low_octave_mix": 0.5, "volume_db": 7.0, "noise_db": -54.0, "soft_clip_post_gain": 0.08,
		"gear_ratios": [3.231, 2.188, 1.609, 1.233, 0.970, 0.795], "final_drive": 7, "shift_time": 0.16,  # 6-speed ASG
	},
	{
		"id": "lambo_65_v12", "name": "6.5 V12", "layout": "v12", "mass": 235.0,
		"redline_rpm": 8350.0, "peak_torque": 690.0, "peak_torque_rpm": 5500.0, "engine_inertia": 0.26,
		"low_octave_mix": 0.5, "volume_db": 10.0, "noise_db": -54.0, "soft_clip_post_gain": 0.1,
		"gear_ratios": [3.909, 2.438, 1.810, 1.458, 1.185, 0.967, 0.844], "final_drive": 7, "shift_time": 0.05,  # 7-speed ISR single-clutch
	},
	{
		# Rolls-Royce Merlin: 27 L (1,650 cu in) aero/tank V12, as in John Dodd's "The Beast".
		# Aero engines rev LOW (~3,000 rpm limit) but make colossal torque; in road tune here
		# ~1,900 N·m @ ~2,000 rpm gives ~850 bhp by the power_to_weight heuristic (torque × redline).
		# Huge crank/flywheel → very lazy revs (big engine_inertia). Loudest, deepest voice in the roster.
		"id": "merlin_v27_v12", "name": "27L Merlin V12", "layout": "v12", "mass": 745.0,
		"redline_rpm": 3200.0, "peak_torque": 1900.0, "peak_torque_rpm": 2000.0, "engine_inertia": 1.5,
		"low_octave_mix": 0.8, "volume_db": 11.0, "noise_db": -54.0, "soft_clip_post_gain": 0.1,
		"gear_ratios": [2.48, 1.48, 1.00], "final_drive": 3, "shift_time": 0.30,  # GM TH400 3-speed auto
	},
	{
		"id": "honda_066_i3", "name": "0.66 E07A i3", "layout": "i3", "mass": 70.0,
		"redline_rpm": 7000.0, "peak_torque": 60.0, "peak_torque_rpm": 4500.0, "engine_inertia": 0.09,
		"low_octave_mix": 0.0, "volume_db": -5.0, "noise_db": -54.0, "soft_clip_post_gain": 0.07,
		"gear_ratios": [4.083, 2.500, 1.680, 1.064, 0.861], "final_drive": 9, "shift_time": 0.35,  # Acty HA4 5-speed manual
	},
]


static func index_of(id: String) -> int:
	for i in ENGINES.size():
		if ENGINES[i]["id"] == id:
			return i
	return -1


static func by_id(id: String) -> Dictionary:
	var i := index_of(id)
	return ENGINES[i] if i >= 0 else {}


# Write the engine's whole profile into GameConfig. The synth (engine_audio_synth.gd)
# and physics (engine.gd) read these live fields; this is the only place a fielded
# car's engine data lands.
static func apply(engine: Dictionary, cfg: GameConfig) -> void:
	var firing_src: Array = FIRING[engine["layout"]]
	var firing: Array[float] = []
	for angle in firing_src:
		firing.append(float(angle))
	cfg.engine_firing_angles = firing
	cfg.engine_cylinders = firing.size()
	cfg.redline_rpm = engine["redline_rpm"]
	cfg.peak_torque = engine["peak_torque"]
	cfg.peak_torque_rpm = engine["peak_torque_rpm"]
	cfg.engine_inertia = engine["engine_inertia"]
	cfg.engine_low_octave_mix = engine["low_octave_mix"]
	cfg.engine_volume_db = engine["volume_db"]
	cfg.engine_noise_level = db_to_linear(engine["noise_db"])
	cfg.engine_soft_clip_post_gain = engine["soft_clip_post_gain"]
	# The transmission bolted to this engine — so an engine swap carries its gearbox
	# to the new car (features/engine-swap.md). Build a typed Array[float] (the dict
	# literal is untyped). EngineSim recomputes its shift speeds when the drivetrain
	# is rebuilt after apply() (car.gd apply_car / _apply_engine_swap).
	if engine.has("gear_ratios"):
		var ratios: Array[float] = []
		for gr in engine["gear_ratios"]:
			ratios.append(float(gr))
		cfg.gear_ratios = ratios
	cfg.final_drive = engine.get("final_drive", cfg.final_drive)
	cfg.shift_time = engine.get("shift_time", cfg.shift_time)
