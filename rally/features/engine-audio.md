# Engine Audio

Procedurally synthesized engine sound — no audio samples. Driven by live engine
RPM/throttle/shift state.

## Components

- **`scripts/engine_audio.gd`** (extends `AudioStreamPlayer`) — the bridge node.
  - `MIX_RATE = 22050` Hz, `BUFFER_SECONDS = 0.1`.
  - `_ready()` creates an `AudioStreamGenerator`, builds the synth, starts play.
  - `_process(delta)` reads engine state, asks the generator playback how many
    frames it needs, fills them via the synth, and pushes the buffer.
- **`scripts/engine_audio_synth.gd`** (`class_name EngineAudioSynth`) — pure DSP,
  no nodes.

## Synthesis model (`EngineAudioSynth`)

One master crank phase (0..1 over a 720° four-stroke cycle) plus a firing pulse
per cylinder. A second crank phase advances at **half** that rate (one octave
lower) and is crossfaded in by `engine_low_octave_mix` — see *Low octave* below.

State: `_crank_phase`, `_firing_phases` (per-cylinder firing times, 0..1),
`_harmonics`, `_idle_gain`, `_noise_level`, `_smooth_rate`.

- `fill(buffer, rpm, throttle, shift_cut, n_frames, fuel_cut)`:
  1. one-pole smooth rpm + throttle per frame (`_smooth_rate`),
  2. advance crank phase,
  3. sum firing pulses via `_voice()`,
  4. scale that cylinder voice by the master volume (`_master_gain`) **and the
     fuel-cut duck** (`_cut_gain`) — see *Rev limiter* below,
  5. add broadband noise (`_noise_level`) at a **constant** level — the volume
     does *not* scale the noise, so changing a car's `volume_db` moves only the
     engine note relative to a fixed noise floor — plus the decaying crackle
     burst (`_crackle_env`),
  6. apply the throttle/idle/shift envelope, DC-block the combined signal (see
     *Soft clipper* below), then run it through the sine soft clipper
     (`soft_clip()`), which bounds the output to [-1, 1].
- `_voice(phase, load_factor)` — each firing phase emits a decaying pulse
  (`exp(-18·d)`); harmonic content weighted by load: `0.6 + 0.4·load_factor`.

The firing phases come from `engine_firing_phases()` on `GameConfig`, derived
from the engine preset's `firing_angles` — so different engine types (i4 vs v8,
etc.) sound distinct.

## Low octave

Some engines synthesize a note that sits too high. `EngineAudioSynth` keeps a
second crank phase (`_crank_phase_low`) advancing at half the firing frequency —
exactly one octave down — and crossfades it against the normal voice per sample:
`lerp(normal, low, mix)`. The blend amount is `engine_low_octave_mix` (0 = normal
voice only, 0.5 = a 50/50 blend, 1 = fully the low octave); at `mix == 0` the
output is byte-for-byte the original, so unaffected cars are unchanged.

It is a **per-car** value: `CarLibrary` defines `low_octave_mix` on each car and
`car.gd`'s `apply_car()` copies it into `GameConfig.engine_low_octave_mix` before
`reconfigure()` rebuilds the synth. Every car is `0.0` except the high-revving
**Lexus LFA** (V10), set to `0.5` to drop its scream into a fuller register.

## Soft clipper

The combined signal (cylinder voice + noise floor + crackle, after the
envelope) is shaped by a sine-function soft clipper instead of a hard clamp:
`sin((π/2)·clamp(x·drive, -1, 1)) · post_gain`, then a final `clamp(-1, 1)`
backstop. The inner clamp keeps the argument on the first quarter-wave where
`sin` is monotonic, so peaks round toward the rails rather than hitting a hard
corner.

The signal chain is: **per-car volume** (`engine_volume_db` → `_master_gain`,
scaling the firing voice) and the constant noise floor form the **pre-shaper**
signal → **sine shaper** (`engine_soft_clip_drive`, the pre-amp) → **global
post-amp** (`engine_soft_clip_post_gain`) → clamp. Per-car volume therefore acts
before the clipper; the post gain is a single global trim.

The pre-amp `engine_soft_clip_drive` is a single **global** `GameConfig` value
(default `0.6`; the live `game_config.tres` is tuned higher) — higher drive
boosts low-level content and hardens the knee (more grit). The post-amp
`engine_soft_clip_post_gain` is **per-car** (default `1.0`, transparent; set
from `CarLibrary.soft_clip_post_gain` — see *Per-car noise* below),
trimming each car's shaped output level. `soft_clip()` is a public method on
`EngineAudioSynth` so tests exercise the curve directly.

The clipper has exactly **two inputs**, each controlled independently *before*
the waveshaper: the cylinder voice (level set per-car by `engine_volume_db` →
`_master_gain`) and the white noise (level set per-car by `noise_db` →
`engine_noise_level`; see *Per-car noise* below). The drive then decides how
hard that combined pair is pushed into saturation.

Because the clipper shapes the *combined* signal, the noise floor is no longer
perfectly volume-independent at the output — but the coupling is tiny (the noise
is still mixed at its own level pre-shaper, not scaled by `volume_db`).

**DC blocker.** The firing-pulse voice is strongly positive-biased — each firing
is a one-sided decaying bump (`exp(-18·d)` kills the oscillation before it swings
negative), so a train of them has a large positive mean (`mean/peak ≈ +0.8`).
Fed straight into the clipper, that bias pins the signal to the `+1` rail under
drive, collapsing the voice into inaudible DC (you'd hear only the bipolar
crackle). So a one-pole DC blocker (`DC_BLOCK_R`, high-pass ≈ 17 Hz — well below
the engine fundamental) centres the combined signal *before* the clipper:
`y = x - x_prev + R·y_prev`. Centred, the clipper swings both rails and overdrive
produces a loud, square-ish tone. Clipping the asymmetric pulse still leaves a
small residual DC in the output; that offset is inaudible and a post-clip blocker
would overshoot the rails, so it is left as-is.

## Rev limiter

The audio honestly reflects the sim's **soft bounce limiter** rather than faking
a synthetic stutter. `engine.gd`'s `_update_limiter()` latches a fuel cut at
redline and releases it a `rev_limiter_band` below (engine braking drags the revs
back down), so `engine.limiting` toggles on/off at the limit — a couple of Hz
with the default flywheel inertia. `engine_audio.gd` passes that flag straight in
as `fill()`'s `fuel_cut`, and the synth:

- **ducks the firing voice** toward `engine_limiter_cut_level` (combustion stops
  while the engine keeps spinning) via `_cut_gain`. The duck rides its **own**
  fast envelope (`CUT_SMOOTH_RATE`, far above `engine_smoothing_rate`) so each
  bounce edge stays crisp no matter how slowly a car tracks rpm — that on/off
  ducking *is* the audible limiter warble, taken directly from the sim,
- **fires a crackle burst** on each cut onset (`engine_limiter_crackle`): a short
  decaying noise burst (`_crackle_env`, `CRACKLE_DECAY` ≈ 6 ms tail) standing in
  for unburnt fuel popping in the exhaust on overrun.

With `fuel_cut` false the output is byte-for-byte the pre-limiter voice, so
normal running is unaffected. The crackle and duck are deliberately *not* a
fixed-frequency gate; if a sharper per-ignition-event "braap" is ever wanted, it
belongs in the **sim** (cutting individual firing events), with the audio then
following the same way it follows the bounce now.

## Per-car volume

The engine's master level (`engine_volume_db`, in decibels) is **per-car**, the
same way `low_octave_mix` is: `CarLibrary` defines `volume_db` on each car and
`car.gd`'s `apply_car()` copies it into `GameConfig.engine_volume_db` (falling
back to the existing config value if a car omits the key) before `reconfigure()`
rebuilds the synth, which reads it into the synth's `_master_gain`. This lets
each car's engine sit at its own level relative to the others. `_master_gain`
scales **only the cylinder firing voice** — the broadband noise is added after
it at a constant level, so a car's `volume_db` changes the engine note's
loudness without altering the noise floor. Cars start at the `-6.0` default
placeholder for per-car balancing (the MX-5 is dropped to `-8.0`).

## Per-car noise

The white-noise input to the soft clipper is **per-car**, authored in decibels:
`CarLibrary` defines `noise_db` on each car and `car.gd`'s `apply_car()`
converts it to a linear amplitude (`db_to_linear`) and writes it into
`GameConfig.engine_noise_level` before `reconfigure()` rebuilds the synth — so
the synth itself is unchanged (it still reads the linear `_noise_level`). Cars
that omit `noise_db` keep the config's `engine_noise_level` (the fallback
default). This gives the clipper's two inputs — voice and noise — independent
per-car levels (`volume_db` and `noise_db`). All cars start at the same
`noise_db` (≈ the prior global noise floor), a placeholder for per-car voicing.

The soft clipper's **post-amp** is per-car too: `CarLibrary.soft_clip_post_gain`
→ `GameConfig.engine_soft_clip_post_gain`, copied in `apply_car()` (config value
is the fallback). The pre-amp/`drive` stays global, so per-car a car controls
its voice (`volume_db`), its noise (`noise_db`), and its post-shaper output trim
(`soft_clip_post_gain`); only the saturation amount is shared.

## Tests

`tests/headless/test_engine_audio.gd` — firing-phase setup, `fill()` output,
clamping, silence on zero requested frames, volume scaling the cylinder voice,
the noise floor staying constant across volumes, and the rev-limiter fuel-cut
duck + crackle (ducks the voice, stays sharp under slow smoothing, crackles on
cut onset, and leaves the no-cut voice unchanged), the soft-clip curve (bounded
when overdriven, rounds peaks, drive/post-gain scaling), and the DC blocker
keeping an overdriven voice AC-dominated rather than collapsing to DC silence.
`tests/headless/test_car_types.gd` — `test_every_car_applies_its_own_engine_volume`
checks each car overlays its `volume_db` onto the live config, and
`test_every_car_applies_its_own_noise_level` checks each car overlays its
`noise_db` (converted to a linear `engine_noise_level`), and
`test_every_car_applies_its_own_soft_clip_post_gain` checks each car overlays
its `soft_clip_post_gain`.

## Related config

`engine_volume_db` (per-car from `CarLibrary.volume_db`), `engine_idle_gain`,
`engine_harmonics`, `engine_noise_level`, `engine_smoothing_rate`,
`engine_low_octave_mix` (per-car from `CarLibrary.low_octave_mix`),
`engine_limiter_cut_level`, `engine_limiter_crackle`, `engine_soft_clip_drive`
(global), `engine_soft_clip_post_gain` (per-car from
`CarLibrary.soft_clip_post_gain`), plus `engine_type`
(firing pattern). See [configuration.md](configuration.md).
