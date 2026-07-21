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


# Distance attenuation for the non-positional engine voice: returns a volume_db
# (<= 0) for a car `dist_sq` (m², squared to avoid a sqrt) from the active
# camera. Inside `ref_dist` the result is 0 dB (full volume); beyond it the level
# follows the physical 1/d sound-pressure law — because volume_db is applied as a
# linear amplitude gain 10^(db/20), 10·log10(ref²/d²) resolves to amplitude ref/d,
# i.e. -6 dB per doubling of distance. Clamped at `floor_db` so a far car goes to
# a finite floor, not -inf. 4.342945 = 10/ln(10), so 4.342945·log(x) == 10·log10(x)
# (GDScript log() is natural log). Pure/static — headless-testable, no nodes.
static func attenuation_db(dist_sq: float, ref_dist: float, floor_db: float) -> float:
	var ref_sq := ref_dist * ref_dist
	if dist_sq <= ref_sq:
		return 0.0
	return maxf(4.342945 * log(ref_sq / dist_sq), floor_db)
# Voice wavetable bank. The firing-pulse voice is a periodic function of crank
# phase, parameterised only by load (throttle). Re-evaluating its
# firing_phases × harmonics sin/exp sum EVERY sample is the synth's dominant
# cost. Instead we bake the voice over one crank cycle into a small bank of
# tables — one per load level — ONCE at init, then read it back per sample with
# linear interpolation in phase and load (_read_voice). Pitch (rpm) falls out for
# free: the crank phase still advances at the rpm-derived rate, we just sample
# the table at that phase. This trades ~harmonics×firings transcendentals per
# sample for a handful of array reads. The bank build is a one-time cost (well
# under a second of the old per-sample work) paid at car load. The voice is
# continuous in phase (at a firing the window is 1 but the harmonic sum is 0), so
# linear interpolation tracks it tightly. See todo/performance-optimisations.md
# item 6.
const VOICE_TABLE_SIZE := 2048  # phase resolution of one crank cycle
const VOICE_LOAD_TABLES := 8    # load (throttle) steps the bank is baked at

const WHISTLE_TABLE_SIZE := 1024
# Internal headroom scales for the turbo/supercharger layers, so a gain of 1.0 sits
# subordinate to the engine note rather than dwarfing it. The whistle is now
# band-pass-filtered noise (lower RMS than a raw sine), so it gets a higher level
# than the tonal supercharger whine.
const TURBO_WHISTLE_LEVEL := 0.5  # filtered-noise spool whistle
const TURBO_TONE_LEVEL := 0.12    # tonal supercharger whine (wavetable)
# Cutoff (Hz) of the broadband air-rush layer blended under the resonant whine.
const TURBO_AIR_LP_HZ := 1800.0
const SUPERCHARGER_BELT_HZ_PER_RPM := 0.12  # whine pitch = rpm * this (belt ratio)
const ANTILAG_BANG_INTERVAL := 0.08  # seconds between anti-lag bangs while coasting

var _mix_rate: float
var _firing_phases: Array[float]
var _harmonics: int
var _harmonic_weights: PackedFloat32Array  # scratch, recomputed per _voice() call
var _idle_gain: float
var _noise_level: float
var _master_gain: float  # linear, from engine_volume_db (per-car; firing voice only)
var _engine_master_gain: float  # linear, from engine_master_volume_db (global; whole mix)
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
var _prev_crackle_cut := false  # edge-detect limiter-cut onsets to fire the crackle burst
var _crackle_env := 0.0  # decaying amplitude of the current crackle burst
var _dc_x_prev := 0.0  # DC-blocker state: previous input sample
var _dc_y_prev := 0.0  # DC-blocker state: previous output sample
var _rng := RandomNumberGenerator.new()
var _voice_bank: Array[PackedFloat32Array] = []  # [VOICE_LOAD_TABLES] of [VOICE_TABLE_SIZE]
var _turbo_whistle_gain := 0.0
# Turbo whistle = resonant band-pass-filtered noise. Sweep range + resonance + the
# broadband air-rush blend, cached from config; the band-pass is a TPT/Cytomic
# state-variable filter (unconditionally stable to any centre freq), its
# coefficients recomputed once per fill() and its two integrator states below.
var _turbo_whistle_freq_min := 700.0
var _turbo_whistle_freq_max := 5000.0
var _turbo_whistle_q := 3.5
var _turbo_air_mix := 0.45
var _svf_ic1 := 0.0  # SVF integrator state 1
var _svf_ic2 := 0.0  # SVF integrator state 2
var _air_lp := 0.0  # air-rush one-pole low-pass state
var _air_lp_coeff := 0.0  # air-rush LP coefficient (fixed cutoff, set at init)
var _turbo_bov_gain := 0.0
var _bov_decay := 0.0  # per-sample decay factor for the blow-off burst (from decay_ms)
var _bov_flutter_amount := 0.0  # LFO depth over the burst (0 = smooth, 1 = full-depth stutter)
var _bov_flutter_hz := 20.0  # flutter LFO frequency
var _bov_flutter_phase := 0.0  # LFO phase, reset on each burst trigger
var _turbo_antilag_bang_gain := 0.0
var _antilag_decay := 0.0  # per-sample decay factor for the anti-lag bang (from decay_ms)
var _supercharger := false
var _supercharger_whine_gain := 0.0
var _whistle_table := PackedFloat32Array()  # single-cycle whine tone (supercharger), baked once
var _whine_phase := 0.0
var _bov_env := 0.0  # decaying blow-off burst amplitude
var _antilag_env := 0.0  # decaying anti-lag bang amplitude
var _antilag_timer := 0.0  # spacing between anti-lag bangs while coasting on boost
var _prev_bov := false  # edge-detect the blow-off event


func _init(cfg: GameConfig, mix_rate: float) -> void:
	_mix_rate = mix_rate
	_firing_phases = cfg.engine_firing_phases()
	_harmonics = cfg.engine_harmonics
	_harmonic_weights.resize(_harmonics)
	_idle_gain = cfg.engine_idle_gain
	_noise_level = cfg.engine_noise_level
	_master_gain = db_to_linear(cfg.engine_volume_db)
	_engine_master_gain = db_to_linear(cfg.engine_master_volume_db)
	_smooth_rate = cfg.engine_smoothing_rate
	_low_octave_mix = clampf(cfg.engine_low_octave_mix, 0.0, 1.0)
	_cut_level = clampf(cfg.engine_limiter_cut_level, 0.0, 1.0)
	_crackle = cfg.engine_limiter_crackle
	_soft_clip_drive = maxf(cfg.engine_soft_clip_drive, 0.001)  # >0; avoid /0-ish curves
	_soft_clip_post_gain = cfg.engine_soft_clip_post_gain
	_turbo_whistle_gain = cfg.engine_turbo_whistle_gain
	_turbo_whistle_freq_min = cfg.engine_turbo_whistle_freq_min
	_turbo_whistle_freq_max = cfg.engine_turbo_whistle_freq_max
	_turbo_whistle_q = maxf(cfg.engine_turbo_whistle_q, 0.5)
	_turbo_air_mix = clampf(cfg.engine_turbo_air_mix, 0.0, 1.0)
	_air_lp_coeff = 1.0 - exp(-TAU * TURBO_AIR_LP_HZ / _mix_rate)
	_turbo_bov_gain = cfg.engine_turbo_bov_gain
	_bov_decay = _decay_factor(cfg.engine_turbo_bov_decay_ms)
	_bov_flutter_amount = clampf(cfg.engine_turbo_bov_flutter_amount, 0.0, 1.0)
	_bov_flutter_hz = cfg.engine_turbo_bov_flutter_hz
	_turbo_antilag_bang_gain = cfg.engine_turbo_antilag_bang_gain
	_antilag_decay = _decay_factor(cfg.engine_turbo_antilag_decay_ms)
	_supercharger = cfg.supercharger_enabled
	_supercharger_whine_gain = cfg.engine_supercharger_whine_gain
	_build_whistle_table()
	_rng.seed = 1  # deterministic for tests
	_build_voice_bank()


func fill(buffer: PackedVector2Array, rpm: float, throttle: float, shift_cut: bool, n_frames: int, fuel_cut := false, crackle_cut := false, boost := 0.0, turbo_spin := 0.0, bov_event := false, antilag_active := false) -> void:
	var dt := 1.0 / _mix_rate
	var smooth := clampf(_smooth_rate * dt, 0.0, 1.0)
	# A shift opens the clutch and cuts throttle, but the engine keeps spinning:
	# it sounds like lifting off, not silence. Drive throttle to zero (so the
	# voice dulls and quietens toward idle through the normal gain path) and
	# apply only a slight extra dip for the torque interruption.
	var target_throttle := 0.0 if shift_cut else clampf(throttle, 0.0, 1.0)
	var cut := 0.8 if shift_cut else 1.0
	# A fuel cut stops combustion, so the firing voice ducks to _cut_level while the
	# engine keeps spinning. `fuel_cut` covers BOTH the rev limiter and a damage
	# misfire — both duck the voice. The crackle burst (unburnt fuel popping in the
	# exhaust on overrun), however, only fits the limiter's clean on-throttle bounce,
	# not a damaged engine stumbling — so it edge-triggers off `crackle_cut` (the
	# limiter alone), passed separately by engine_audio.gd. A fast envelope
	# (CUT_SMOOTH_RATE) keeps each bounce edge crisp.
	var cut_target := _cut_level if fuel_cut else 1.0
	var cut_smooth := clampf(CUT_SMOOTH_RATE * dt, 0.0, 1.0)
	if crackle_cut and not _prev_crackle_cut:
		_crackle_env = _crackle
	_prev_crackle_cut = crackle_cut
	# Going back on the throttle re-pressurizes the manifold and shuts the dump
	# valve, so kill any ringing BOV tail immediately. But NOT mid-shift: during a
	# shift the throttle is cut regardless of the driver's input (shift_cut), so a
	# held throttle there must not silence the shift's own blow-off.
	if throttle > 0.1 and not shift_cut:
		_bov_env = 0.0
	# Scale the burst by how much boost was being run: a full-boost lift dumps the
	# loudest "pshhh", a partial-spool lift a softer one.
	if bov_event and not _prev_bov:
		_bov_env = _turbo_bov_gain * clampf(boost, 0.0, 1.0)
		_bov_flutter_phase = 0.0  # start each burst's flutter from the same point
	_prev_bov = bov_event
	# Turbo whistle band-pass coefficients — computed ONCE per buffer (boost/turbo_spin
	# are constant across a fill()), so the per-sample loop is just the cheap SVF
	# recurrence with no transcendental. TPT/Cytomic SVF: unconditionally stable at any
	# centre frequency. Centre freq sweeps freq_min→freq_max with shaft speed.
	var whistle_active := _turbo_whistle_gain != 0.0 and boost > 0.0
	var svf_a1 := 0.0
	var svf_a2 := 0.0
	var svf_a3 := 0.0
	var svf_k := 0.0
	if whistle_active:
		var fc := lerpf(_turbo_whistle_freq_min, _turbo_whistle_freq_max, clampf(turbo_spin, 0.0, 1.0))
		var g := tan(PI * fc / _mix_rate)
		svf_k = 1.0 / _turbo_whistle_q
		svf_a1 = 1.0 / (1.0 + g * (g + svf_k))
		svf_a2 = g * svf_a1
		svf_a3 = g * svf_a2
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
		var sample := _read_voice(_crank_phase, _sm_throttle)
		if _low_octave_mix > 0.0:
			var low := _read_voice(_crank_phase_low, _sm_throttle)
			sample = lerpf(sample, low, _low_octave_mix)
		# Volume (_master_gain) scales only the cylinder firing voice. The
		# broadband noise is added afterwards at a constant level so a car's
		# volume_db changes the engine note's loudness without altering the
		# noise floor.
		var voice := sample * _master_gain * _cut_gain
		var noise := (_rng.randf() * 2.0 - 1.0) * _noise_level * (0.2 + 0.8 * _sm_throttle)
		# Exhaust crackle rides on top of the steady noise floor as a decaying burst.
		noise += (_rng.randf() * 2.0 - 1.0) * _crackle_env
		# Turbo spool: resonant band-pass-filtered NOISE (centre freq tracks shaft
		# speed) blended with a broadband air-rush layer — reads as airflow, not a
		# pure tone. White noise → TPT SVF band-pass (v1), normalized by k so Q sets
		# tone not level; air rush is the same noise one-pole low-passed.
		if whistle_active:
			var wn := _rng.randf() * 2.0 - 1.0
			var v3 := wn - _svf_ic2
			var v1 := svf_a1 * _svf_ic1 + svf_a2 * v3
			var v2 := _svf_ic2 + svf_a2 * _svf_ic1 + svf_a3 * v3
			_svf_ic1 = 2.0 * v1 - _svf_ic1
			_svf_ic2 = 2.0 * v2 - _svf_ic2
			_air_lp += _air_lp_coeff * (wn - _air_lp)
			var spool := lerpf(v1 * svf_k, _air_lp, _turbo_air_mix)
			voice += spool * boost * _turbo_whistle_gain * TURBO_WHISTLE_LEVEL
		# Supercharger whine: pitch tracks engine rpm (belt-driven), always on.
		if _supercharger and _supercharger_whine_gain != 0.0:
			var whine_hz := _sm_rpm * SUPERCHARGER_BELT_HZ_PER_RPM
			_whine_phase = fposmod(_whine_phase + whine_hz * dt, 1.0)
			voice += _read_whistle(_whine_phase) * (0.3 + 0.7 * _sm_throttle) * _supercharger_whine_gain * TURBO_TONE_LEVEL
		# Blow-off vent burst (decaying filtered noise), optionally fluttered by an
		# LFO tremolo (the stuttering surge "brrrap"): the LFO scales the burst
		# amplitude between (1 - amount) and 1 at _bov_flutter_hz.
		_bov_env *= _bov_decay
		var bov_lfo := 1.0
		if _bov_flutter_amount > 0.0 and _bov_env > 0.0:
			_bov_flutter_phase = fposmod(_bov_flutter_phase + _bov_flutter_hz * dt, 1.0)
			bov_lfo = 1.0 - _bov_flutter_amount * (0.5 + 0.5 * sin(TAU * _bov_flutter_phase))
		noise += (_rng.randf() * 2.0 - 1.0) * _bov_env * bov_lfo
		# Anti-lag bangs: retrigger a short burst at intervals while coasting on boost.
		if antilag_active:
			_antilag_timer -= dt
			if _antilag_timer <= 0.0:
				_antilag_env = _turbo_antilag_bang_gain
				_antilag_timer = ANTILAG_BANG_INTERVAL
		_antilag_env *= _antilag_decay
		noise += (_rng.randf() * 2.0 - 1.0) * _antilag_env
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
		# Global engine master volume: a single project-wide lever applied to the
		# FINAL mixed signal (voice + noise + crackle + turbo + supercharger + BOV +
		# anti-lag), after the soft clipper. Clamp again so a >0 dB setting can't
		# push the summed peaks past the rails.
		sample = clampf(soft_clip(blocked) * _engine_master_gain, -1.0, 1.0)
		buffer[i] = Vector2(sample, sample)


# Sine-function soft clipper applied to the combined engine signal. The inner
# clamp keeps the argument on the first quarter-wave [-π/2, π/2] where sin is
# monotonic, so the shaper rounds peaks toward ±1 without folding back. The
# global post gain sets output level; the outer clamp is a backstop for
# post_gain > 1.
func soft_clip(x: float) -> float:
	var shaped := sin((PI * 0.5) * clampf(x * _soft_clip_drive, -1.0, 1.0))
	return clampf(shaped * _soft_clip_post_gain, -1.0, 1.0)


# Bake the firing-pulse voice over one crank cycle into a bank of load-indexed
# tables. Called once at init; the per-sample path reads this bank via
# _read_voice() instead of re-evaluating _voice(). Cost is VOICE_LOAD_TABLES ×
# VOICE_TABLE_SIZE voice evaluations, one time.
func _build_voice_bank() -> void:
	_voice_bank.clear()
	for k in range(VOICE_LOAD_TABLES):
		var load_level := float(k) / float(VOICE_LOAD_TABLES - 1)
		var table := PackedFloat32Array()
		table.resize(VOICE_TABLE_SIZE)
		for i in range(VOICE_TABLE_SIZE):
			table[i] = _voice(float(i) / float(VOICE_TABLE_SIZE), load_level)
		_voice_bank.append(table)


# Bake one cycle of the turbine tone (fundamental + a quieter octave) so the
# per-sample whistle path is a couple of array reads, mirroring the voice bank.
func _build_whistle_table() -> void:
	_whistle_table.resize(WHISTLE_TABLE_SIZE)
	for i in range(WHISTLE_TABLE_SIZE):
		var ph := TAU * float(i) / float(WHISTLE_TABLE_SIZE)
		_whistle_table[i] = 0.8 * sin(ph) + 0.2 * sin(2.0 * ph)


# Read the whistle table at a normalized phase [0,1) with linear interpolation.
func _read_whistle(phase: float) -> float:
	var p := phase * float(WHISTLE_TABLE_SIZE)
	var i0 := int(p) % WHISTLE_TABLE_SIZE
	var i1 := (i0 + 1) % WHISTLE_TABLE_SIZE
	return lerpf(_whistle_table[i0], _whistle_table[i1], p - floorf(p))


# Convert a burst envelope decay TIME (ms) into the per-sample multiplicative decay
# factor. decay_ms is the exponential time constant (time to fall to 1/e): after
# that many ms the envelope has decayed by e. Guards a >=1-sample denominator.
func _decay_factor(decay_ms: float) -> float:
	var tau_samples := maxf(decay_ms / 1000.0 * _mix_rate, 1.0)
	return exp(-1.0 / tau_samples)


# Read the baked voice at (phase, load) with bilinear interpolation: linear in
# crank phase (wrapping the cycle) and linear across the two bracketing load
# tables. This is the per-sample hot path — it replaces the firing_phases ×
# harmonics sin/exp sum in _voice() with a handful of array reads.
func _read_voice(phase: float, load_level: float) -> float:
	var lf := clampf(load_level, 0.0, 1.0) * float(VOICE_LOAD_TABLES - 1)
	var k0 := int(lf)
	var k1 := mini(k0 + 1, VOICE_LOAD_TABLES - 1)
	var kfrac := lf - float(k0)
	var p := phase * float(VOICE_TABLE_SIZE)
	var i0 := mini(int(p), VOICE_TABLE_SIZE - 1)  # fposmod gives [0,1); guard the float edge
	var i1 := (i0 + 1) % VOICE_TABLE_SIZE         # wrap the last cell back to phase 0
	var pfrac := p - float(i0)
	var t0 := _voice_bank[k0]
	var t1 := _voice_bank[k1]
	var v0 := lerpf(t0[i0], t0[i1], pfrac)
	var v1 := lerpf(t1[i0], t1[i1], pfrac)
	return lerpf(v0, v1, kfrac)


# Sum each firing pulse: a short harmonic burst windowed near its crank phase.
# Now the OFFLINE table builder for _build_voice_bank() rather than a per-sample
# call — _read_voice() serves the hot loop. Kept exact (no approximation) so the
# baked tables carry the original sound design.
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
