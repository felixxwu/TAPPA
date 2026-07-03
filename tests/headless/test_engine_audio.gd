extends GutTest
# EngineAudioSynth pure-DSP behavior and GameConfig firing-phase helper.


func test_firing_phases_default_inline4_even() -> void:
	var cfg := GameConfig.new()
	cfg.engine_cylinders = 4
	cfg.engine_firing_angles = [0.0, 180.0, 360.0, 540.0]
	var phases := cfg.engine_firing_phases()
	assert_eq(phases.size(), 4, "four firing phases")
	assert_almost_eq(phases[0], 0.0, 0.0001)
	assert_almost_eq(phases[1], 0.25, 0.0001)
	assert_almost_eq(phases[2], 0.5, 0.0001)
	assert_almost_eq(phases[3], 0.75, 0.0001)


func test_firing_phases_empty_falls_back_to_even() -> void:
	var cfg := GameConfig.new()
	cfg.engine_cylinders = 4
	cfg.engine_firing_angles = []
	var phases := cfg.engine_firing_phases()
	assert_eq(phases.size(), 4, "derives one phase per (cylinders) firing")
	assert_almost_eq(phases[1], 0.25, 0.0001, "evenly spaced over the cycle")


const MIX_RATE := 22050.0


func _make_synth() -> EngineAudioSynth:
	var cfg := GameConfig.new()
	cfg.engine_firing_angles = [0.0, 180.0, 360.0, 540.0]
	return EngineAudioSynth.new(cfg, MIX_RATE)


# A noiseless synth, for measuring pitch by zero-crossings: the noise layer adds
# random sign flips that swamp the tone's crossings, so silence it to isolate
# the firing frequency. (Noise is exercised separately by the other tests.)
func _clean_synth() -> EngineAudioSynth:
	var cfg := GameConfig.new()
	cfg.engine_firing_angles = [0.0, 180.0, 360.0, 540.0]
	cfg.engine_noise_level = 0.0
	return EngineAudioSynth.new(cfg, MIX_RATE)


func test_fill_writes_clamped_non_empty_output() -> void:
	var synth := _make_synth()
	var buf := PackedVector2Array()
	buf.resize(512)
	synth.fill(buf, 3000.0, 0.5, false, 512)
	var any_nonzero := false
	for s in buf:
		assert_false(is_nan(s.x), "no NaN samples")
		assert_true(s.x >= -1.0 and s.x <= 1.0, "sample in [-1, 1]")
		if absf(s.x) > 0.0001:
			any_nonzero = true
	assert_true(any_nonzero, "fill produces audible output")


func test_fill_zero_frames_writes_nothing() -> void:
	var synth := _make_synth()
	var buf := PackedVector2Array()
	buf.resize(8)
	for i in range(8):
		buf[i] = Vector2(0.123, 0.123)
	synth.fill(buf, 3000.0, 0.5, false, 0)
	# PackedVector2Array stores float32, so the sentinel reads back as a rounded
	# 0.123; compare with a tolerance. An actually-written sample would differ
	# far more than this, so the assertion still proves nothing was written.
	assert_almost_eq(buf[0].x, 0.123, 0.0001, "n_frames 0 writes no samples")


func _rms(buf: PackedVector2Array, n: int) -> float:
	var acc := 0.0
	for i in range(n):
		acc += buf[i].x * buf[i].x
	return sqrt(acc / float(n))


# The engine voice is a train of positive firing pulses, not a bipolar wave, so
# count the pulses (rising crossings past half the peak, with hysteresis) as a
# frequency proxy — more firings per buffer means higher pitch.
func _pulse_count(buf: PackedVector2Array, n: int) -> int:
	var peak := 0.0
	for i in range(n):
		peak = maxf(peak, buf[i].x)
	if peak <= 0.0:
		return 0
	var hi := peak * 0.5
	var lo := peak * 0.35  # hysteresis so a noisy plateau isn't counted twice
	var count := 0
	var above := false
	for i in range(n):
		if not above and buf[i].x > hi:
			count += 1
			above = true
		elif above and buf[i].x < lo:
			above = false
	return count


func test_amplitude_rises_with_throttle() -> void:
	var n := 4096
	var low := PackedVector2Array(); low.resize(n)
	var high := PackedVector2Array(); high.resize(n)
	_make_synth().fill(low, 3000.0, 0.1, false, n)
	_make_synth().fill(high, 3000.0, 0.9, false, n)
	assert_gt(_rms(high, n), _rms(low, n), "more throttle → louder")


func test_frequency_rises_with_rpm() -> void:
	var n := 8192
	var lo := PackedVector2Array(); lo.resize(n)
	var hi := PackedVector2Array(); hi.resize(n)
	_clean_synth().fill(lo, 1500.0, 0.6, false, n)
	_clean_synth().fill(hi, 6000.0, 0.6, false, n)
	assert_gt(_pulse_count(hi, n), _pulse_count(lo, n), "higher rpm → higher pitch")


func test_shift_cut_drops_amplitude() -> void:
	var n := 4096
	var on := PackedVector2Array(); on.resize(n)
	var cut := PackedVector2Array(); cut.resize(n)
	_make_synth().fill(on, 4000.0, 0.8, false, n)
	_make_synth().fill(cut, 4000.0, 0.8, true, n)
	assert_lt(_rms(cut, n), _rms(on, n), "shift cut ducks the engine")


func test_shift_cut_stays_audible_like_a_throttle_lift() -> void:
	# A shift lifts the throttle but the engine keeps spinning, so it should
	# sound like an off-throttle blip — comparable to coasting, never silent.
	var n := 4096
	var coast := PackedVector2Array(); coast.resize(n)
	var shift := PackedVector2Array(); shift.resize(n)
	_make_synth().fill(coast, 4000.0, 0.0, false, n)  # off-throttle, no shift
	_make_synth().fill(shift, 4000.0, 0.8, true, n)    # mid-shift
	assert_gt(_rms(shift, n), 0.5 * _rms(coast, n), "shift stays audible, not muted")


# A clean synth with the low-octave voice crossfaded in by `mix`.
func _clean_synth_with_low_octave(mix: float) -> EngineAudioSynth:
	var cfg := GameConfig.new()
	cfg.engine_firing_angles = [0.0, 180.0, 360.0, 540.0]
	cfg.engine_noise_level = 0.0
	cfg.engine_low_octave_mix = mix
	return EngineAudioSynth.new(cfg, MIX_RATE)


# The low-octave voice fires at half the rate (one octave down): fully blended
# in (mix 1.0) it produces roughly half as many pulses as the normal voice at
# the same rpm.
func test_full_low_octave_halves_the_pitch() -> void:
	var n := 8192
	var normal := PackedVector2Array(); normal.resize(n)
	var low := PackedVector2Array(); low.resize(n)
	_clean_synth_with_low_octave(0.0).fill(normal, 4000.0, 0.6, false, n)
	_clean_synth_with_low_octave(1.0).fill(low, 4000.0, 0.6, false, n)
	var normal_pulses := _pulse_count(normal, n)
	var low_pulses := _pulse_count(low, n)
	assert_lt(low_pulses, normal_pulses, "full low octave fires fewer pulses (lower pitch)")
	assert_almost_eq(float(low_pulses), float(normal_pulses) * 0.5, float(normal_pulses) * 0.2,
		"full low octave is about an octave (half the firing rate) down")


# A 50/50 blend changes the waveform from the normal voice (it folds in the
# octave-lower content) without simply matching either extreme.
func test_half_low_octave_changes_the_waveform() -> void:
	var n := 4096
	var normal := PackedVector2Array(); normal.resize(n)
	var blended := PackedVector2Array(); blended.resize(n)
	_clean_synth_with_low_octave(0.0).fill(normal, 4000.0, 0.6, false, n)
	_clean_synth_with_low_octave(0.5).fill(blended, 4000.0, 0.6, false, n)
	var diff := 0.0
	for i in range(n):
		diff += absf(normal[i].x - blended[i].x)
	assert_gt(diff / float(n), 0.001, "50/50 low-octave blend changes the waveform")


# A zero mix must leave the voice identical to the no-feature default, so the
# cars left at 0 sound exactly as before.
func test_low_octave_mix_zero_is_unchanged() -> void:
	var n := 4096
	var default := PackedVector2Array(); default.resize(n)
	var zero := PackedVector2Array(); zero.resize(n)
	_clean_synth().fill(default, 4000.0, 0.7, false, n)
	_clean_synth_with_low_octave(0.0).fill(zero, 4000.0, 0.7, false, n)
	for i in range(n):
		assert_almost_eq(zero[i].x, default[i].x, 0.0000001, "mix 0 leaves the voice unchanged")


# A synth at a given master volume (engine_volume_db) and broadband noise level.
func _synth_with_volume(volume_db: float, noise_level: float) -> EngineAudioSynth:
	var cfg := GameConfig.new()
	cfg.engine_firing_angles = [0.0, 180.0, 360.0, 540.0]
	cfg.engine_noise_level = noise_level
	cfg.engine_volume_db = volume_db
	return EngineAudioSynth.new(cfg, MIX_RATE)


# Volume controls the cylinder firing voice: with noise silenced, a louder
# volume_db produces a louder waveform.
func test_volume_scales_the_cylinder_voice() -> void:
	var n := 4096
	var quiet := PackedVector2Array(); quiet.resize(n)
	var loud := PackedVector2Array(); loud.resize(n)
	_synth_with_volume(-18.0, 0.0).fill(quiet, 4000.0, 0.5, false, n)
	_synth_with_volume(-6.0, 0.0).fill(loud, 4000.0, 0.5, false, n)
	assert_gt(_rms(loud, n), _rms(quiet, n) * 1.5, "higher volume_db = louder cylinder voice")


# Volume scales only the cylinder voice — the noise is mixed at a constant level
# (not multiplied by _master_gain) before the soft clipper. We verify that by
# the noise contribution cancelling out of the loud-vs-quiet difference: compare
# that difference with noise off vs. on.
#
# The cancellation is near-exact but not bit-exact, because the sine soft clipper
# is a non-linear stage on the COMBINED (voice + noise) signal, so the noise
# couples weakly into the voice difference. That coupling is tiny (~1e-4); if
# volume actually scaled the noise (the old bug path) the deviation would be
# ~0.04/sample — orders of magnitude larger — so this bound still catches that
# regression.
func test_noise_is_independent_of_volume() -> void:
	var n := 4096
	# Difference between two volumes, noise OFF.
	var q0 := PackedVector2Array(); q0.resize(n)
	var l0 := PackedVector2Array(); l0.resize(n)
	_synth_with_volume(-18.0, 0.0).fill(q0, 4000.0, 0.5, false, n)
	_synth_with_volume(-6.0, 0.0).fill(l0, 4000.0, 0.5, false, n)
	# Same two volumes, noise ON (same rng seed, so the noise stream is identical).
	var qn := PackedVector2Array(); qn.resize(n)
	var ln := PackedVector2Array(); ln.resize(n)
	_synth_with_volume(-18.0, 0.2).fill(qn, 4000.0, 0.5, false, n)
	_synth_with_volume(-6.0, 0.2).fill(ln, 4000.0, 0.5, false, n)
	var max_dev := 0.0
	for i in range(n):
		var diff_off := l0[i].x - q0[i].x
		var diff_on := ln[i].x - qn[i].x
		max_dev = maxf(max_dev, absf(diff_on - diff_off))
	assert_lt(max_dev, 0.001,
		"noise is not scaled by volume: it cancels in the volume difference up to the soft clipper's weak coupling")


# A clean (noiseless) synth with explicit limiter knobs, for isolating the
# fuel-cut duck and the crackle burst from each other and from the noise floor.
func _limiter_synth(cut_level: float, crackle: float, smoothing := 200.0) -> EngineAudioSynth:
	var cfg := GameConfig.new()
	cfg.engine_firing_angles = [0.0, 180.0, 360.0, 540.0]
	cfg.engine_noise_level = 0.0
	cfg.engine_limiter_cut_level = cut_level
	cfg.engine_limiter_crackle = crackle
	cfg.engine_smoothing_rate = smoothing
	return EngineAudioSynth.new(cfg, MIX_RATE)


# Fuel cut (rev limiter) mutes the combustion voice toward _cut_level: with the
# crackle and noise silenced, the cut buffer is quieter than the firing one.
func test_fuel_cut_ducks_the_firing_voice() -> void:
	var n := 4096
	var firing := PackedVector2Array(); firing.resize(n)
	var cut := PackedVector2Array(); cut.resize(n)
	_limiter_synth(0.18, 0.0).fill(firing, 7500.0, 1.0, false, n, false)
	_limiter_synth(0.18, 0.0).fill(cut, 7500.0, 1.0, false, n, true)
	assert_lt(_rms(cut, n), _rms(firing, n), "fuel cut ducks the firing voice")


# The duck is on its own fast envelope, not the rpm/throttle smoothing: even at a
# very slow engine_smoothing_rate the cut still bites within the buffer.
func test_fuel_cut_is_sharp_despite_slow_smoothing() -> void:
	var n := 4096
	var firing := PackedVector2Array(); firing.resize(n)
	var cut := PackedVector2Array(); cut.resize(n)
	_limiter_synth(0.18, 0.0, 10.0).fill(firing, 7500.0, 1.0, false, n, false)
	_limiter_synth(0.18, 0.0, 10.0).fill(cut, 7500.0, 1.0, false, n, true)
	assert_lt(_rms(cut, n), _rms(firing, n) * 0.8, "cut bites even with slow smoothing")


# Entering a LIMITER cut fires a crackle burst: with the duck disabled (cut_level 1)
# and noise off, the cut buffer carries extra broadband energy vs no cut. The
# crackle edge-triggers off crackle_cut (the 7th arg), which the limiter sets.
func test_fuel_cut_onset_adds_crackle() -> void:
	var n := 4096
	var quiet := PackedVector2Array(); quiet.resize(n)
	var crackly := PackedVector2Array(); crackly.resize(n)
	_limiter_synth(1.0, 0.5).fill(quiet, 7500.0, 1.0, false, n, false, false)
	_limiter_synth(1.0, 0.5).fill(crackly, 7500.0, 1.0, false, n, true, true)
	assert_gt(_rms(crackly, n), _rms(quiet, n), "limiter cut onset adds a crackle burst")


# A DAMAGE misfire ducks the voice (fuel_cut) but must NOT crackle — the pop is
# limiter-only. With the duck disabled (cut_level 1) so only the crackle could
# differ, a misfire cut (crackle_cut false) matches no-crackle; a limiter cut pops.
func test_misfire_cut_ducks_without_crackle() -> void:
	var n := 4096
	var misfire := PackedVector2Array(); misfire.resize(n)
	var limiter := PackedVector2Array(); limiter.resize(n)
	_limiter_synth(1.0, 0.5).fill(misfire, 7500.0, 1.0, false, n, true, false)
	_limiter_synth(1.0, 0.5).fill(limiter, 7500.0, 1.0, false, n, true, true)
	assert_gt(_rms(limiter, n), _rms(misfire, n), "the limiter crackles; a damage misfire does not")


# With no fuel cut the voice is identical to the pre-limiter default, so normal
# running is untouched by the feature.
func test_no_fuel_cut_leaves_voice_unchanged() -> void:
	var n := 4096
	var default := PackedVector2Array(); default.resize(n)
	var no_cut := PackedVector2Array(); no_cut.resize(n)
	_clean_synth().fill(default, 4000.0, 0.7, false, n)
	_limiter_synth(0.18, 0.5).fill(no_cut, 4000.0, 0.7, false, n, false)
	for i in range(n):
		assert_almost_eq(no_cut[i].x, default[i].x, 0.0000001, "no cut = unchanged voice")


# The per-sample hot path reads a baked wavetable bank (_read_voice) instead of
# re-evaluating the firing-pulse sum (_voice). The bank must approximate the
# exact voice tightly across the full phase × load range, or the engine note
# changes character. The voice is continuous in phase, so linear interpolation
# tracks it within a small tolerance.
func test_wavetable_matches_direct_voice() -> void:
	var synth := _clean_synth()
	var max_err := 0.0
	for li in range(21):
		var load_frac := float(li) / 20.0
		for pi in range(1024):
			var phase := float(pi) / 1024.0
			max_err = maxf(max_err, absf(synth._read_voice(phase, load_frac) - synth._voice(phase, load_frac)))
	assert_lt(max_err, 0.02, "baked wavetable approximates the direct voice within tolerance")


func _synth_with_angles(angles: Array[float]) -> EngineAudioSynth:
	var cfg := GameConfig.new()
	cfg.engine_firing_angles = angles
	return EngineAudioSynth.new(cfg, MIX_RATE)


# A lopey (uneven) firing table must produce a different waveform than the
# even inline-4 at the same rpm/throttle — proves engine type is configurable.
func test_uneven_table_differs_from_even() -> void:
	var n := 4096
	var even := PackedVector2Array(); even.resize(n)
	var uneven := PackedVector2Array(); uneven.resize(n)
	_synth_with_angles([0.0, 180.0, 360.0, 540.0]).fill(even, 4000.0, 0.7, false, n)
	_synth_with_angles([0.0, 90.0, 360.0, 450.0]).fill(uneven, 4000.0, 0.7, false, n)
	var diff := 0.0
	for i in range(n):
		diff += absf(even[i].x - uneven[i].x)
	assert_gt(diff / float(n), 0.001, "uneven firing table changes the waveform")


# Soft clipper: a synth driven hard must still produce bounded, rounded output.
func _clean_synth_with(drive: float, post_gain: float) -> EngineAudioSynth:
	var cfg := GameConfig.new()
	cfg.engine_firing_angles = [0.0, 180.0, 360.0, 540.0]
	cfg.engine_noise_level = 0.0
	cfg.engine_soft_clip_drive = drive
	cfg.engine_soft_clip_post_gain = post_gain
	return EngineAudioSynth.new(cfg, MIX_RATE)


func test_soft_clip_keeps_output_bounded_when_overdriven() -> void:
	# High drive + high post gain would blow past ±1 without the shaper + clamp.
	var synth := _clean_synth_with(4.0, 4.0)
	var buf := PackedVector2Array()
	buf.resize(512)
	synth.fill(buf, 6000.0, 1.0, false, 512)
	for s in buf:
		assert_false(is_nan(s.x), "no NaN samples")
		assert_true(s.x >= -1.0 and s.x <= 1.0, "sample stays in [-1, 1]")


func test_soft_clip_curve_rounds_peaks() -> void:
	# The sine shaper applied directly: sin((π/2)·clamp(x·drive,-1,1)) · post.
	# At drive=1 a mid-level input must be boosted above the linear value
	# (low-level gain π/2 > 1), and a full-scale input must saturate to ~1.
	var synth := _clean_synth_with(1.0, 1.0)
	assert_almost_eq(synth.soft_clip(0.5), sin(PI * 0.5 * 0.5), 1e-6,
		"mid-level maps through the sine curve")
	assert_almost_eq(synth.soft_clip(1.0), 1.0, 1e-6, "full scale saturates to 1")
	assert_almost_eq(synth.soft_clip(2.0), 1.0, 1e-6, "overdrive stays clamped at 1")


func test_soft_clip_higher_drive_saturates_more() -> void:
	var low := _clean_synth_with(0.5, 1.0)
	var high := _clean_synth_with(2.0, 1.0)
	# Same sub-unity input: higher drive pushes further up the sine curve.
	assert_true(high.soft_clip(0.4) > low.soft_clip(0.4),
		"higher drive yields more output for the same input")


func test_soft_clip_post_gain_scales_output() -> void:
	var quiet := _clean_synth_with(0.5, 0.5)
	var loud := _clean_synth_with(0.5, 1.0)
	assert_almost_eq(quiet.soft_clip(0.3), loud.soft_clip(0.3) * 0.5, 1e-6,
		"post gain scales the shaped output linearly (below the clamp)")


# The firing voice is heavily positive-biased; without the DC blocker, hard
# overdrive pinned it to the +1 rail — pure DC, which is inaudible. The pre-clip
# DC blocker centres the signal so overdrive produces a loud, symmetric
# (square-ish) tone: the output is dominated by AC content (not a DC offset).
func test_dc_blocker_keeps_overdriven_voice_audible() -> void:
	var cfg := GameConfig.new()
	cfg.engine_firing_angles = [0.0, 180.0, 360.0, 540.0]
	cfg.engine_noise_level = 0.0  # isolate the voice
	cfg.engine_volume_db = 12.0   # loud
	cfg.engine_soft_clip_drive = 50.0  # hard overdrive
	cfg.engine_soft_clip_post_gain = 1.0
	var synth := EngineAudioSynth.new(cfg, MIX_RATE)
	var n := 8192
	var buf := PackedVector2Array(); buf.resize(n)
	synth.fill(buf, 4000.0, 1.0, false, n)
	# Measure the steady-state second half (skip the rpm ramp + filter settle).
	var start := n / 2
	var count := n - start
	var mean := 0.0
	for i in range(start, n):
		mean += buf[i].x
	mean /= count
	var ac := 0.0
	for i in range(start, n):
		ac += (buf[i].x - mean) * (buf[i].x - mean)
	ac = sqrt(ac / count)
	assert_gt(ac, 0.2, "overdriven voice stays loud (AC content), not collapsed to DC silence")
	assert_gt(ac, absf(mean), "output is AC-dominated, not pinned to a DC rail")


func _turbo_synth() -> EngineAudioSynth:
	var cfg := GameConfig.new()
	cfg.engine_firing_angles = [0.0, 180.0, 360.0, 540.0]
	cfg.engine_noise_level = 0.0  # isolate the tonal turbo/supercharger layers
	cfg.turbo_enabled = true
	cfg.turbo_omega_ref = 12000.0
	cfg.engine_turbo_whistle_gain = 0.5
	cfg.engine_turbo_bov_gain = 0.5
	cfg.engine_turbo_antilag_bang_gain = 0.5
	return EngineAudioSynth.new(cfg, MIX_RATE)


func _energy(buf: PackedVector2Array) -> float:
	var e := 0.0
	for s in buf:
		e += s.x * s.x
	return e


func _zero_crossings(buf: PackedVector2Array) -> int:
	var z := 0
	for i in range(1, buf.size()):
		if (buf[i].x >= 0.0) != (buf[i - 1].x >= 0.0):
			z += 1
	return z


func test_whistle_adds_energy_with_boost() -> void:
	var synth := _turbo_synth()
	var quiet := PackedVector2Array(); quiet.resize(1024)
	var loud := PackedVector2Array(); loud.resize(1024)
	# Same rpm/throttle; only boost + shaft speed differ.
	synth.fill(quiet, 3000.0, 1.0, false, 1024, false, false, 0.0, 0.0)
	synth.fill(loud, 3000.0, 1.0, false, 1024, false, false, 0.9, 0.9)
	assert_gt(_energy(loud), _energy(quiet), "spool whistle adds energy as boost rises")


func test_whistle_pitch_rises_with_shaft_speed() -> void:
	# The spool is band-pass-filtered noise whose centre frequency sweeps UP with
	# shaft speed, so faster spin => higher spectral content => more zero-crossings.
	# Mute the firing voice so the whistle dominates the buffer, isolating the cue.
	var mk := func() -> EngineAudioSynth:
		var cfg := GameConfig.new()
		cfg.engine_firing_angles = [0.0, 180.0, 360.0, 540.0]
		cfg.engine_noise_level = 0.0
		cfg.engine_volume_db = -80.0  # mute the firing voice; isolate the whistle
		cfg.turbo_enabled = true
		cfg.turbo_omega_ref = 12000.0
		cfg.engine_turbo_whistle_gain = 0.9
		cfg.engine_turbo_air_mix = 0.0  # pure resonant band = sharpest pitch cue
		cfg.engine_turbo_whistle_freq_min = 600.0
		cfg.engine_turbo_whistle_freq_max = 6000.0
		return EngineAudioSynth.new(cfg, MIX_RATE)
	var slow := PackedVector2Array(); slow.resize(4096)
	var fast := PackedVector2Array(); fast.resize(4096)
	# Fresh synths (same seed) so only the shaft speed differs between the two.
	mk.call().fill(slow, 3000.0, 1.0, false, 4096, false, false, 1.0, 0.1)
	mk.call().fill(fast, 3000.0, 1.0, false, 4096, false, false, 1.0, 1.0)
	assert_gt(_zero_crossings(fast), _zero_crossings(slow),
		"spool centre frequency (zero-crossing rate) rises with shaft speed")


func test_bov_event_produces_a_burst() -> void:
	var synth := _turbo_synth()
	var none := PackedVector2Array(); none.resize(1024)
	var vent := PackedVector2Array(); vent.resize(1024)
	synth.fill(none, 3000.0, 0.0, false, 1024, false, false, 0.5, 0.5, false)
	synth.fill(vent, 3000.0, 0.0, false, 1024, false, false, 0.5, 0.5, true)
	assert_gt(_energy(vent), _energy(none), "a blow-off event adds a transient burst")


func test_bov_burst_scales_with_boost() -> void:
	# The burst amplitude tracks the boost being run at the lift: a full-boost lift
	# is louder than a partial-spool lift (same gain, same decay, same trigger).
	var full := _turbo_synth()
	var part := _turbo_synth()
	var loud := PackedVector2Array(); loud.resize(1024)
	var soft := PackedVector2Array(); soft.resize(1024)
	full.fill(loud, 3000.0, 0.0, false, 1024, false, false, 1.0, 1.0, true)
	part.fill(soft, 3000.0, 0.0, false, 1024, false, false, 0.4, 0.4, true)
	assert_gt(_energy(loud), _energy(soft), "the blow-off is loudest at full boost")


func _long_bov_synth() -> EngineAudioSynth:
	# Isolate the BOV tail: muted voice, no whistle/noise, a long decay so a tail
	# survives across buffers unless something kills it.
	var cfg := GameConfig.new()
	cfg.engine_firing_angles = [0.0, 180.0, 360.0, 540.0]
	cfg.engine_noise_level = 0.0
	cfg.engine_volume_db = -80.0
	cfg.turbo_enabled = true
	cfg.engine_turbo_bov_gain = 0.6
	cfg.engine_turbo_whistle_gain = 0.0
	cfg.engine_turbo_bov_decay_ms = 200.0
	return EngineAudioSynth.new(cfg, MIX_RATE)


func test_throttle_application_kills_bov_tail() -> void:
	var synth := _long_bov_synth()
	var ring := PackedVector2Array(); ring.resize(1024)
	var killed := PackedVector2Array(); killed.resize(1024)
	synth.fill(ring, 3000.0, 0.0, false, 1024, false, false, 0.8, 0.8, true)  # fire, ring off-throttle
	# Back on throttle (not shifting): the ringing tail must be cut immediately.
	synth.fill(killed, 3000.0, 1.0, false, 1024, false, false, 0.8, 0.8, false)
	assert_gt(_energy(ring), 0.0, "precondition: the burst is ringing")
	assert_lt(_energy(killed), _energy(ring) * 0.05, "throttle application kills the BOV tail")


func test_bov_tail_survives_throttle_held_during_shift() -> void:
	# During a shift the throttle is cut regardless of input, so a held throttle
	# must NOT silence the shift's blow-off (only a genuine post-shift re-application does).
	var held := _long_bov_synth()
	var released := _long_bov_synth()
	var during_shift := PackedVector2Array(); during_shift.resize(1024)
	var on_throttle := PackedVector2Array(); on_throttle.resize(1024)
	held.fill(during_shift, 3000.0, 0.0, false, 1024, false, false, 0.8, 0.8, true)  # fire
	released.fill(on_throttle, 3000.0, 0.0, false, 1024, false, false, 0.8, 0.8, true)  # fire (same)
	# Next buffer: throttle held, but one is mid-shift (shift_cut) and one is not.
	held.fill(during_shift, 3000.0, 1.0, true, 1024, false, false, 0.8, 0.8, false)
	released.fill(on_throttle, 3000.0, 1.0, false, 1024, false, false, 0.8, 0.8, false)
	assert_gt(_energy(during_shift), _energy(on_throttle),
		"a held throttle mid-shift keeps the blow-off; back on throttle (no shift) kills it")


func test_bov_flutter_modulates_the_burst() -> void:
	# The flutter LFO scales the burst between (1 - amount) and 1, so its mean
	# amplitude — and thus total energy over the tail — drops when flutter is on.
	var mk := func(amount: float) -> EngineAudioSynth:
		var cfg := GameConfig.new()
		cfg.engine_firing_angles = [0.0, 180.0, 360.0, 540.0]
		cfg.engine_noise_level = 0.0
		cfg.engine_volume_db = -80.0
		cfg.turbo_enabled = true
		cfg.engine_turbo_bov_gain = 0.6
		cfg.engine_turbo_whistle_gain = 0.0
		cfg.engine_turbo_bov_decay_ms = 200.0
		cfg.engine_turbo_bov_flutter_amount = amount
		cfg.engine_turbo_bov_flutter_hz = 30.0
		return EngineAudioSynth.new(cfg, MIX_RATE)
	var smooth := PackedVector2Array(); smooth.resize(2048)
	var fluttered := PackedVector2Array(); fluttered.resize(2048)
	mk.call(0.0).fill(smooth, 3000.0, 0.0, false, 2048, false, false, 0.9, 0.9, true)
	mk.call(0.9).fill(fluttered, 3000.0, 0.0, false, 2048, false, false, 0.9, 0.9, true)
	assert_gt(_energy(smooth), 0.0, "precondition: the burst is audible")
	assert_lt(_energy(fluttered), _energy(smooth),
		"flutter chops the burst amplitude, lowering its mean energy")


func test_bov_decay_ms_shapes_the_tail() -> void:
	# A longer decay time rings out longer, so the burst carries more total energy
	# over the buffer than a short decay (same gain, same trigger).
	var mk := func(decay_ms: float) -> EngineAudioSynth:
		var cfg := GameConfig.new()
		cfg.engine_firing_angles = [0.0, 180.0, 360.0, 540.0]
		cfg.engine_noise_level = 0.0
		cfg.engine_volume_db = -80.0  # mute the voice; isolate the burst
		cfg.turbo_enabled = true
		cfg.engine_turbo_bov_gain = 0.6
		cfg.engine_turbo_bov_decay_ms = decay_ms
		return EngineAudioSynth.new(cfg, MIX_RATE)
	var short_tail := PackedVector2Array(); short_tail.resize(4096)
	var long_tail := PackedVector2Array(); long_tail.resize(4096)
	mk.call(5.0).fill(short_tail, 3000.0, 0.0, false, 4096, false, false, 0.5, 0.5, true)
	mk.call(120.0).fill(long_tail, 3000.0, 0.0, false, 4096, false, false, 0.5, 0.5, true)
	assert_gt(_energy(long_tail), _energy(short_tail),
		"a longer bov_decay_ms rings the burst out longer (more energy)")


func test_supercharger_whine_only_when_enabled() -> void:
	var mk := func(blown: bool) -> EngineAudioSynth:
		var cfg := GameConfig.new()
		cfg.engine_firing_angles = [0.0, 180.0, 360.0, 540.0]
		cfg.engine_noise_level = 0.0
		cfg.supercharger_enabled = blown
		cfg.engine_supercharger_whine_gain = 0.6
		return EngineAudioSynth.new(cfg, MIX_RATE)
	var plain := PackedVector2Array(); plain.resize(1024)
	var blown := PackedVector2Array(); blown.resize(1024)
	mk.call(false).fill(plain, 4000.0, 0.8, false, 1024)
	mk.call(true).fill(blown, 4000.0, 0.8, false, 1024)
	assert_gt(_energy(blown), _energy(plain), "a supercharged engine adds a whine layer")
