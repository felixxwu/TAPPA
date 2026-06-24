class_name EngineAudioSynth
extends RefCounted
# Pure DSP: turns engine state into PCM. One master crank phase advances per
# revolution; each firing phase emits a decaying multi-harmonic pulse. Owns no
# nodes — fully headless-testable. fill() is the only entry point.

const RPM_TO_REV_PER_SEC := 1.0 / 60.0
# Rate the fuel-cut duck tracks at, independent of (and far above) the rpm/
# throttle smoothing: the limiter bounce must stay sharp even when a car uses a
# slow engine_smoothing_rate. Effective cutoff ≈ rate / 2π.
const CUT_SMOOTH_RATE := 1500.0
# Per-sample decay of the crackle burst — a short (~6 ms) exhaust-pop tail.
const CRACKLE_DECAY := 0.99
# One-pole DC-blocker pole. The firing-pulse voice is strongly positive-biased
# (each firing is a one-sided decaying bump), so the signal carries a large DC
# offset. Left in, the soft clipper pins that bias to the +1 rail under drive,
# turning the voice into inaudible DC. The DC blocker centres the signal first,
# so overdrive distorts symmetrically (a loud, square-ish tone). Cutoff ≈
# (1 - R)·mix_rate / 2π ≈ 17 Hz at 22050 Hz — well below the engine fundamental.
const DC_BLOCK_R := 0.995

var _mix_rate: float
var _firing_phases: Array[float]
var _harmonics: int
var _harmonic_weights: PackedFloat32Array  # scratch, recomputed per _voice() call
var _idle_gain: float
var _noise_level: float
var _master_gain: float  # linear, from engine_volume_db
var _smooth_rate: float  # one-pole rate for rpm/throttle; higher = snappier
var _low_octave_mix: float  # 0 = pure normal voice, 0.5 = 50/50, 1 = pure low
var _cut_level: float  # firing-voice gain while fuel is cut (1 = no duck)
var _crackle: float  # exhaust-pop burst amplitude per cut transition
var _soft_clip_drive: float  # pre-amp into the sine shaper (>0)
var _soft_clip_post_gain: float  # global post-amp after the shaper

var _crank_phase := 0.0  # 0..1 over the four-stroke cycle
var _crank_phase_low := 0.0  # second crank, half-speed = one octave lower
var _sm_rpm := 0.0
var _sm_throttle := 0.0
var _cut_gain := 1.0  # fast-tracked firing-voice gain for the limiter fuel cut
var _prev_fuel_cut := false  # edge-detect cut onsets to fire the crackle burst
var _crackle_env := 0.0  # decaying amplitude of the current crackle burst
var _dc_x_prev := 0.0  # DC-blocker state: previous input sample
var _dc_y_prev := 0.0  # DC-blocker state: previous output sample
var _rng := RandomNumberGenerator.new()


func _init(cfg: GameConfig, mix_rate: float) -> void:
	_mix_rate = mix_rate
	_firing_phases = cfg.engine_firing_phases()
	_harmonics = cfg.engine_harmonics
	_harmonic_weights.resize(_harmonics)
	_idle_gain = cfg.engine_idle_gain
	_noise_level = cfg.engine_noise_level
	_master_gain = db_to_linear(cfg.engine_volume_db)
	_smooth_rate = cfg.engine_smoothing_rate
	_low_octave_mix = clampf(cfg.engine_low_octave_mix, 0.0, 1.0)
	_cut_level = clampf(cfg.engine_limiter_cut_level, 0.0, 1.0)
	_crackle = cfg.engine_limiter_crackle
	_soft_clip_drive = maxf(cfg.engine_soft_clip_drive, 0.001)  # >0; avoid /0-ish curves
	_soft_clip_post_gain = cfg.engine_soft_clip_post_gain
	_rng.seed = 1  # deterministic for tests


func fill(buffer: PackedVector2Array, rpm: float, throttle: float, shift_cut: bool, n_frames: int, fuel_cut := false) -> void:
	var dt := 1.0 / _mix_rate
	var smooth := clampf(_smooth_rate * dt, 0.0, 1.0)
	# A shift opens the clutch and cuts throttle, but the engine keeps spinning:
	# it sounds like lifting off, not silence. Drive throttle to zero (so the
	# voice dulls and quietens toward idle through the normal gain path) and
	# apply only a slight extra dip for the torque interruption.
	var target_throttle := 0.0 if shift_cut else clampf(throttle, 0.0, 1.0)
	var cut := 0.8 if shift_cut else 1.0
	# The rev limiter cuts fuel: combustion stops, so the firing voice ducks to
	# _cut_level while the engine keeps spinning. The sim bounces fuel_cut on/off
	# at the limit, so ducking honestly tracks that — no synthetic frequency. A
	# fast envelope (CUT_SMOOTH_RATE) keeps each bounce edge crisp; the cut onset
	# fires a crackle burst (unburnt fuel popping in the exhaust on overrun).
	var cut_target := _cut_level if fuel_cut else 1.0
	var cut_smooth := clampf(CUT_SMOOTH_RATE * dt, 0.0, 1.0)
	if fuel_cut and not _prev_fuel_cut:
		_crackle_env = _crackle
	_prev_fuel_cut = fuel_cut
	for i in range(n_frames):
		_sm_rpm = lerpf(_sm_rpm, rpm, smooth)
		_sm_throttle = lerpf(_sm_throttle, target_throttle, smooth)
		_cut_gain = lerpf(_cut_gain, cut_target, cut_smooth)
		_crackle_env *= CRACKLE_DECAY
		var cycles_per_sec := _sm_rpm * RPM_TO_REV_PER_SEC * 0.5  # 720° cycle = 2 revs
		_crank_phase = fposmod(_crank_phase + cycles_per_sec * dt, 1.0)
		# Second voice advancing at half the rate = one octave lower. Crossfade it
		# in by _low_octave_mix so a car can sound deeper without changing pitch.
		_crank_phase_low = fposmod(_crank_phase_low + cycles_per_sec * 0.5 * dt, 1.0)
		var sample := _voice(_crank_phase, _sm_throttle)
		if _low_octave_mix > 0.0:
			var low := _voice(_crank_phase_low, _sm_throttle)
			sample = lerpf(sample, low, _low_octave_mix)
		# Volume (_master_gain) scales only the cylinder firing voice. The
		# broadband noise is added afterwards at a constant level so a car's
		# volume_db changes the engine note's loudness without altering the
		# noise floor.
		var voice := sample * _master_gain * _cut_gain
		var noise := (_rng.randf() * 2.0 - 1.0) * _noise_level * (0.2 + 0.8 * _sm_throttle)
		# Exhaust crackle rides on top of the steady noise floor as a decaying burst.
		noise += (_rng.randf() * 2.0 - 1.0) * _crackle_env
		var env := lerpf(_idle_gain, 1.0, _sm_throttle) * cut
		# DC-block the combined signal BEFORE the soft clipper (see DC_BLOCK_R) so
		# the positive-biased voice is centred and overdrive swings both rails
		# (loud, square-ish) instead of pinning to +1: y = x - xp + R·yp. Clipping
		# the asymmetric pulse still leaves a small residual DC in the output; that
		# offset is inaudible and a post-clip blocker would overshoot the rails, so
		# it is left alone.
		var combined := (voice + noise) * env
		var blocked := combined - _dc_x_prev + DC_BLOCK_R * _dc_y_prev
		_dc_x_prev = combined
		_dc_y_prev = blocked
		sample = soft_clip(blocked)
		buffer[i] = Vector2(sample, sample)


# Sine-function soft clipper applied to the combined engine signal. The inner
# clamp keeps the argument on the first quarter-wave [-π/2, π/2] where sin is
# monotonic, so the shaper rounds peaks toward ±1 without folding back. The
# global post gain sets output level; the outer clamp is a backstop for
# post_gain > 1.
func soft_clip(x: float) -> float:
	var shaped := sin((PI * 0.5) * clampf(x * _soft_clip_drive, -1.0, 1.0))
	return clampf(shaped * _soft_clip_post_gain, -1.0, 1.0)


# Sum each firing pulse: a short harmonic burst windowed near its crank phase.
func _voice(phase: float, load_factor: float) -> float:
	# The per-harmonic weight depends only on the harmonic index and load_factor,
	# not the firing phase — so compute it ONCE here and reuse across every firing
	# phase below, instead of recomputing the same pow() inside the inner loop for
	# each phase. Algebraically identical (load_factor is fixed within a call);
	# removes a firing_phases-fold of pow() calls per sample.
	var base := 0.6 + 0.4 * load_factor
	for h in range(1, _harmonics + 1):
		_harmonic_weights[h - 1] = pow(base, float(h)) / float(h)
	var out := 0.0
	for fp in _firing_phases:
		var d := fposmod(phase - fp, 1.0)  # 0..1 since this firing fired
		var window := exp(-d * 18.0)  # decaying pulse envelope
		var local := d * TAU
		var pulse := 0.0
		for h in range(1, _harmonics + 1):
			pulse += sin(local * float(h)) * _harmonic_weights[h - 1]
		out += pulse * window
	return out / float(maxi(_firing_phases.size(), 1))
