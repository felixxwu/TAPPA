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
#                     Displayed power / power-to-weight are DERIVED from these
#                     (CarLibrary.power_to_weight: torque × redline speed × a global
#                     falloff factor) — there is deliberately no separately-authored
#                     power figure, so retuning torque moves the stats with it.
#   * engine_inertia — crank+flywheel rotating inertia (kg·m²): small revs fast, large
#                     revs lazily.
#   * engine_friction_base — always-on crank friction (N·m, FMEP constant term) subtracted
#                     on every path (see engine.gd). Per-engine, authored to scale vaguely
#                     with cylinder count / displacement so a big-block drags far more than
#                     a kei triple. Optional: apply() falls back to the GameConfig default
#                     when a (synthetic) engine dict omits it. The rpm-dependent slope
#                     (engine_friction_slope) is still global.
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
#   * turbo_* / supercharger_enabled / engine_turbo_*_gain / engine_supercharger_whine_gain
#                     — FORCED INDUCTION (features/forced-induction.md), all optional:
#                     an NA engine omits them and apply() defaults to OFF/zero, so the
#                     turbo sim is skipped and no boost/whine audio plays.

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
		"engine_friction_base": 20.0,  # i4 2.0L
		"low_octave_mix": 0.2, "volume_db": -5.0, "noise_db": -54.0, "soft_clip_post_gain": 0.07,
		"gear_ratios": [5.087, 2.991, 2.035, 1.594, 1.286, 1.000], "final_drive": 5, "shift_time": 0.30,  # ND 6-speed manual
	},
	{
		"id": "renault_12_i4", "name": "1.2 16V i4", "layout": "i4", "mass": 95.0,
		"redline_rpm": 6800.0, "peak_torque": 105.0, "peak_torque_rpm": 4500.0, "engine_inertia": 0.13,
		"engine_friction_base": 0.0,  # i4 1.2L (small displacement, low friction)
		"low_octave_mix": 0.0, "volume_db": -5.0, "noise_db": -54.0, "soft_clip_post_gain": 0.07,
		"gear_ratios": [3.364, 1.864, 1.321, 0.967, 0.756], "final_drive": 8, "shift_time": 0.35,  # JB1 5-speed manual
	},
	{
		"id": "ford_25t_i5", "name": "2.5T Duratec i5", "layout": "i5", "mass": 150.0,
		"redline_rpm": 6800.0, "peak_torque": 320.0, "peak_torque_rpm": 4200.0, "engine_inertia": 0.22,
		"engine_friction_base": 25.0,  # i5 2.5L
		"low_octave_mix": 0.1, "volume_db": -5.0, "noise_db": -54.0, "soft_clip_post_gain": 0.07,
		"gear_ratios": [3.385, 2.050, 1.433, 1.088, 0.868, 0.700], "final_drive": 9, "shift_time": 0.30,  # Getrag M66 6-speed
	},
	{
		"id": "audi_25t_i5", "name": "2.5T TFSI i5", "layout": "i5", "mass": 165.0,
		"redline_rpm": 7000.0, "peak_torque": 500.0, "peak_torque_rpm": 4200.0, "engine_inertia": 0.22,
		"engine_friction_base": 25.0,  # i5 2.5L
		"low_octave_mix": 0.0, "volume_db": -5.0, "noise_db": -54.0, "soft_clip_post_gain": 0.07,
		"gear_ratios": [3.563, 2.526, 1.679, 1.022, 0.788, 0.761, 0.635], "final_drive": 12, "shift_time": 0.08,  # 7-speed S tronic
	},
	{
		"id": "ford_50_v8", "name": "5.0 Coyote V8", "layout": "v8", "mass": 200.0,
		"redline_rpm": 7500.0, "peak_torque": 569.0, "peak_torque_rpm": 4200.0, "engine_inertia": 0.32,
		"engine_friction_base": 40.0,  # V8 5.0L
		"low_octave_mix": 0.8, "volume_db": 7.0, "noise_db": -54.0, "soft_clip_post_gain": 0.1,
		"gear_ratios": [3.66, 2.43, 1.69, 1.32, 1.00, 0.65], "final_drive": 7, "shift_time": 0.22,  # Getrag MT82 6-speed manual
	},
	{
		"id": "mopar_440_v8", "name": "440 Magnum V8", "layout": "v8", "mass": 290.0,
		"redline_rpm": 5500.0, "peak_torque": 600.0, "peak_torque_rpm": 3000.0, "engine_inertia": 0.56,
		"engine_friction_base": 60.0,  # V8 7.2L (big-block, more than the 5.0)
		"low_octave_mix": 0.8, "volume_db": 8.0, "noise_db": -54.0, "soft_clip_post_gain": 0.1,
		"gear_ratios": [2.45, 1.45, 1.00], "final_drive": 4.5, "shift_time": 0.30,  # TorqueFlite A727 3-speed auto
	},
	{
		"id": "porsche_30_flat6", "name": "3.0 turbo flat-6", "layout": "i6", "mass": 180.0,
		"redline_rpm": 6800.0, "peak_torque": 225.0, "peak_torque_rpm": 4000.0, "engine_inertia": 0.18,  # 930 Turbo 3.0: 260 PS @ 5500, 343 Nm @ 4000
		"engine_friction_base": 30.0,  # flat-6 3.0L
		"low_octave_mix": 0.0, "volume_db": -5.0, "noise_db": -54.0, "soft_clip_post_gain": 0.08,
		"gear_ratios": [3.18, 1.83, 1.26, 0.93], "final_drive": 4.22, "shift_time": 0.25,  # 4-speed manual (930/30)
		# Stock forced induction (features/forced-induction.md): the 930's single
		# large turbo, famous for its lag. Balance placeholders.
		"turbo_enabled": true, "turbo_boost_gain": 0.5, "turbo_inertia": 1.0e-2, "turbo_omega_ref": 11000.0,
		"turbo_parasitic_friction": 16.0,
		"engine_turbo_whistle_gain": 0.015, "engine_turbo_bov_gain": 0.005,
	},
	{
		# Dodge Viper RT/10 (1st gen, 1992) 8.0 L (488 cu in) OHV V10: 400 bhp @ 4600, 610 N·m (450 lb-ft) @ 3600.
		# Big pushrod truck-derived V10 — deep, low-revving, lazy heavy crank (high inertia).
		"id": "dodge_80_v10", "name": "8.0 V10", "layout": "v10", "mass": 230.0,
		"redline_rpm": 6000.0, "peak_torque": 610.0, "peak_torque_rpm": 3600.0, "engine_inertia": 0.35,
		"engine_friction_base": 52.0,  # V10 8.0L
		"low_octave_mix": 0.7, "volume_db": 9.0, "noise_db": -54.0, "soft_clip_post_gain": 0.08,
		"gear_ratios": [2.66, 1.78, 1.30, 1.00, 0.74, 0.50], "final_drive": 6, "shift_time": 0.30,  # Tremec T-56 6-speed manual
	},
	{
		# Jaguar XJS 5.3 L V12 HE: 295 PS @ 5500, 432 N·m (318 lb-ft) @ 3000; tach redlined 6500.
		# Smooth SOHC luxury V12 — refined, deep, quieter than the exotics.
		"id": "jaguar_53_v12", "name": "5.3 V12", "layout": "v12", "mass": 235.0,
		"redline_rpm": 6500.0, "peak_torque": 432.0, "peak_torque_rpm": 3000.0, "engine_inertia": 0.30,
		"engine_friction_base": 58.0,  # V12 5.3L
		"low_octave_mix": 0.8, "volume_db": 6.0, "noise_db": -54.0, "soft_clip_post_gain": 0.1,
		"gear_ratios": [2.48, 1.48, 1.00], "final_drive": 6, "shift_time": 0.30,  # GM TH400 3-speed auto
	},
	{
		# Rolls-Royce Merlin: 27 L (1,650 cu in) aero/tank V12, as in John Dodd's "The Beast".
		# Aero engines rev LOW (~3,000 rpm limit) but make colossal torque; in road tune here
		# ~1,900 N·m @ ~2,000 rpm derives to ~665 bhp — the conservative end of the CLAIMED 750-950 bhp.
		# Huge crank/flywheel → very lazy revs (big engine_inertia). Loudest, deepest voice in the roster.
		"id": "merlin_v27_v12", "name": "27L Merlin V12", "layout": "v12", "mass": 745.0,
		"redline_rpm": 3200.0, "peak_torque": 1900.0, "peak_torque_rpm": 2000.0, "engine_inertia": 1.5,
		"engine_friction_base": 100.0,  # V12 27L aero monster — far more than the 5.3 despite equal cylinders
		"low_octave_mix": 0.8, "volume_db": 11.0, "noise_db": -54.0, "soft_clip_post_gain": 0.1,
		"gear_ratios": [2.48, 1.48, 1.00], "final_drive": 3, "shift_time": 0.30,  # GM TH400 3-speed auto
	},
	{
		"id": "honda_066_i3", "name": "0.66 E07A i3", "layout": "i3", "mass": 70.0,
		"redline_rpm": 7000.0, "peak_torque": 60.0, "peak_torque_rpm": 4500.0, "engine_inertia": 0.09,
		"engine_friction_base": 0.0,  # i3 0.66L kei (tiny — with only 60 Nm on tap, 40 stalled it)
		"low_octave_mix": 0.0, "volume_db": -5.0, "noise_db": -54.0, "soft_clip_post_gain": 0.07,
		"gear_ratios": [4.083, 2.500, 1.680, 1.064, 0.861], "final_drive": 9, "shift_time": 0.35,  # Acty HA4 5-speed manual
	},
]


# Test seam + stable-id lookups via the shared Registry helper (scripts/registry.gd).
# See CarLibrary for the rationale. No production code reads ENGINES directly; every
# reader goes through by_id/index_of/apply, so routing these is enough. FIRING stays
# const (keyed by layout, not by authored entry).
static var _seam := Registry.Seam.new(ENGINES)

static func all() -> Array[Dictionary]:
	return _seam.all()

static func override_for_test(engines: Array[Dictionary]) -> void:
	_seam.override_for_test(engines)

static func reset() -> void:
	_seam.reset()


static func index_of(id: String) -> int:
	return Registry.index_of(all(), id)


static func by_id(id: String) -> Dictionary:
	return Registry.by_id(all(), id)


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
	# Always-on crank friction (FMEP constant term) is per-engine now: authored to scale
	# vaguely with cylinder count / displacement, so a big-block carries far more parasitic
	# drag than a kei triple (a single global term either bogged the small engines or
	# under-braked the big ones). Falls back to the config default for a synthetic engine
	# dict that omits it. The rpm-dependent slope (engine_friction_slope) stays global.
	cfg.engine_friction_base = engine.get("engine_friction_base", cfg.engine_friction_base)
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
	# Forced induction (features/forced-induction.md). Optional keys — NA engines omit
	# them and fall back to OFF/zero, so the turbo sim is skipped and no whine plays.
	cfg.turbo_enabled = engine.get("turbo_enabled", false)
	cfg.turbo_inertia = engine.get("turbo_inertia", cfg.turbo_inertia)
	cfg.turbo_omega_ref = engine.get("turbo_omega_ref", cfg.turbo_omega_ref)
	cfg.turbo_boost_gain = engine.get("turbo_boost_gain", 0.0)
	cfg.turbo_parasitic_friction = engine.get("turbo_parasitic_friction", 0.0)
	cfg.turbo_drive_gain = engine.get("turbo_drive_gain", cfg.turbo_drive_gain)
	cfg.turbo_drag_coef = engine.get("turbo_drag_coef", cfg.turbo_drag_coef)
	cfg.turbo_antilag = engine.get("turbo_antilag", false)
	cfg.turbo_antilag_drive = engine.get("turbo_antilag_drive", 0.0)
	cfg.supercharger_enabled = engine.get("supercharger_enabled", false)
	cfg.engine_turbo_whistle_gain = engine.get("engine_turbo_whistle_gain", 0.0)
	cfg.engine_turbo_bov_gain = engine.get("engine_turbo_bov_gain", 0.0)
	cfg.engine_turbo_antilag_bang_gain = engine.get("engine_turbo_antilag_bang_gain", 0.0)
	cfg.engine_supercharger_whine_gain = engine.get("engine_supercharger_whine_gain", 0.0)
