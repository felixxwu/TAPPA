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
		"id": "mazda_20_i4", "name": "2.0 Skyactiv-G i4", "layout": "i4",
		"redline_rpm": 7500.0, "peak_torque": 205.0, "peak_torque_rpm": 4500.0, "engine_inertia": 0.15,
		"low_octave_mix": 0.2, "volume_db": -5.0, "noise_db": -54.0, "soft_clip_post_gain": 0.07,
	},
	{
		"id": "renault_12_i4", "name": "1.2 16V i4", "layout": "i4",
		"redline_rpm": 6800.0, "peak_torque": 105.0, "peak_torque_rpm": 4500.0, "engine_inertia": 0.13,
		"low_octave_mix": 0.0, "volume_db": -5.0, "noise_db": -54.0, "soft_clip_post_gain": 0.07,
	},
	{
		"id": "ford_25t_i5", "name": "2.5T Duratec i5", "layout": "i5",
		"redline_rpm": 6800.0, "peak_torque": 320.0, "peak_torque_rpm": 4200.0, "engine_inertia": 0.22,
		"low_octave_mix": 0.1, "volume_db": -5.0, "noise_db": -54.0, "soft_clip_post_gain": 0.07,
	},
	{
		"id": "audi_25t_i5", "name": "2.5T TFSI i5", "layout": "i5",
		"redline_rpm": 7000.0, "peak_torque": 500.0, "peak_torque_rpm": 4200.0, "engine_inertia": 0.22,
		"low_octave_mix": 0.0, "volume_db": -5.0, "noise_db": -54.0, "soft_clip_post_gain": 0.07,
	},
	{
		"id": "ford_50_v8", "name": "5.0 Coyote V8", "layout": "v8",
		"redline_rpm": 7500.0, "peak_torque": 569.0, "peak_torque_rpm": 4200.0, "engine_inertia": 0.32,
		"low_octave_mix": 0.8, "volume_db": 7.0, "noise_db": -54.0, "soft_clip_post_gain": 0.1,
	},
	{
		"id": "mopar_440_v8", "name": "440 Magnum V8", "layout": "v8",
		"redline_rpm": 5500.0, "peak_torque": 600.0, "peak_torque_rpm": 3000.0, "engine_inertia": 0.56,
		"low_octave_mix": 0.8, "volume_db": 8.0, "noise_db": -54.0, "soft_clip_post_gain": 0.1,
	},
	{
		"id": "porsche_30_flat6", "name": "3.0 flat-6", "layout": "i6",
		"redline_rpm": 7500.0, "peak_torque": 450.0, "peak_torque_rpm": 4800.0, "engine_inertia": 0.18,
		"low_octave_mix": 0.0, "volume_db": -5.0, "noise_db": -54.0, "soft_clip_post_gain": 0.08,
	},
	{
		"id": "toyota_48_v10", "name": "4.8 V10", "layout": "v10",
		"redline_rpm": 9000.0, "peak_torque": 480.0, "peak_torque_rpm": 6000.0, "engine_inertia": 0.10,
		"low_octave_mix": 0.5, "volume_db": 7.0, "noise_db": -54.0, "soft_clip_post_gain": 0.08,
	},
	{
		"id": "lambo_65_v12", "name": "6.5 V12", "layout": "v12",
		"redline_rpm": 8350.0, "peak_torque": 690.0, "peak_torque_rpm": 5500.0, "engine_inertia": 0.26,
		"low_octave_mix": 0.5, "volume_db": 10.0, "noise_db": -54.0, "soft_clip_post_gain": 0.1,
	},
	{
		"id": "honda_066_i3", "name": "0.66 E07A i3", "layout": "i3",
		"redline_rpm": 7000.0, "peak_torque": 60.0, "peak_torque_rpm": 4500.0, "engine_inertia": 0.09,
		"low_octave_mix": 0.0, "volume_db": -5.0, "noise_db": -54.0, "soft_clip_post_gain": 0.07,
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
