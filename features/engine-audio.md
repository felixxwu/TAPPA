# Engine Audio

Procedurally synthesized engine sound — no audio samples. Driven by live engine
RPM/throttle/shift state.

## Components

- **`scripts/engine_audio.gd`** (extends `AudioStreamPlayer`) — the bridge node.
  - `MIX_RATE = 22050` Hz, `BUFFER_SECONDS = 0.15`. The fill runs in `_process` on
    the main thread, so the buffer is all that keeps audio alive across a slow
    frame — if the gap between `_process` calls exceeds it, the buffer drains and
    the engine note crackles. On the single-threaded web build a chunk-crossing
    frame can be tens of ms, so `0.1` left almost no headroom; `0.15` covers the
    worst post-optimisation frame with margin while keeping throttle→rev latency
    low. (Raise toward `0.2` if underruns persist on the weakest devices.)
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

- `fill(buffer, rpm, throttle, shift_cut, n_frames, fuel_cut, crackle_cut)`:
  (`fuel_cut` ducks the voice — limiter or damage misfire; `crackle_cut` fires the
  crackle — limiter only)
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
from the fielded car's `engine_firing_angles` (written by `EngineLibrary.apply()`
from the referenced engine's layout) — so different engine layouts (i4 vs v8,
etc.) sound distinct.

## Low octave

Some engines synthesize a note that sits too high. `EngineAudioSynth` keeps a
second crank phase (`_crank_phase_low`) advancing at half the firing frequency —
exactly one octave down — and crossfades it against the normal voice per sample:
`lerp(normal, low, mix)`. The blend amount is `engine_low_octave_mix` (0 = normal
voice only, 0.5 = a 50/50 blend, 1 = fully the low octave); at `mix == 0` the
output is byte-for-byte the original, so unaffected cars are unchanged.

It is an **engine** property: `EngineLibrary` defines `low_octave_mix` on each
catalog entry (`scripts/engine_library.gd`) and `EngineLibrary.apply()` writes
it into `GameConfig.engine_low_octave_mix` (called from `car.gd`'s
`apply_car()`) before `reconfigure()` rebuilds the synth. Most engines sit at
`0.0`; the deep V10 (`dodge_80_v10`, used by the Dodge Viper RT/10) and the
V8s/V12 (`ford_50_v8`, `mopar_440_v8`, `jaguar_53_v12`) are lifted to deepen
their synthesized note.

## Soft clipper

The combined signal (cylinder voice + noise floor + crackle, after the
envelope) is shaped by a sine-function soft clipper instead of a hard clamp:
`sin((π/2)·clamp(x·drive, -1, 1)) · post_gain`, then a final `clamp(-1, 1)`
backstop. The inner clamp keeps the argument on the first quarter-wave where
`sin` is monotonic, so peaks round toward the rails rather than hitting a hard
corner.

The signal chain is: **per-engine volume** (`engine_volume_db` → `_master_gain`,
scaling the firing voice) and the constant noise floor form the **pre-shaper**
signal → **sine shaper** (`engine_soft_clip_drive`, the pre-amp) → **global
post-amp** (`engine_soft_clip_post_gain`) → clamp → **global engine master
volume** (`engine_master_volume_db` → `_engine_master_gain`) → clamp. Per-engine
volume therefore acts before the clipper; the post gain is a single global trim.

`engine_master_volume_db` is the single project-wide lever for **all** engine
sound. Unlike `engine_volume_db` (per-car, firing voice only), it is applied to
the FINAL mixed signal after the soft clipper, so it scales every element at
once — firing voice, broadband noise, exhaust crackle, turbo whistle/air-rush,
supercharger whine, blow-off vent, and anti-lag bangs. Default `0.0` dB (no
change); negative attenuates the whole engine mix, `-80` effectively mutes it.
It is a `GameConfig` value in `game_config.tres`, not a per-car property.

The pre-amp `engine_soft_clip_drive` is a single **global** `GameConfig` value
(default `0.6`; the live `game_config.tres` is tuned higher) — higher drive
boosts low-level content and hardens the knee (more grit). The post-amp
`engine_soft_clip_post_gain` is an **engine** property (default `1.0`,
transparent; set from `EngineLibrary`'s `soft_clip_post_gain` — see *Per-engine
noise* below), trimming each engine's shaped output level. `soft_clip()` is a
public method on `EngineAudioSynth` so tests exercise the curve directly.

The clipper has exactly **two inputs**, each controlled independently *before*
the waveshaper: the cylinder voice (level set per-engine by `engine_volume_db` →
`_master_gain`) and the white noise (level set per-engine by `noise_db` →
`engine_noise_level`; see *Per-engine noise* below). The drive then decides how
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
with the default flywheel inertia. A **damage misfire** (see [damage.md](damage.md))
also stops combustion, so `engine.fuel_cut` is the limiter OR the misfire.
`engine_audio.gd` passes `engine.fuel_cut` as `fill()`'s `fuel_cut` **and**
`engine.limiting` as its separate `crackle_cut`, and the synth:

- **ducks the firing voice** toward `engine_limiter_cut_level` (combustion stops
  while the engine keeps spinning) via `_cut_gain`, on ANY `fuel_cut` — limiter or
  misfire. The duck rides its **own** fast envelope (`CUT_SMOOTH_RATE`, far above
  `engine_smoothing_rate`) so each bounce edge stays crisp no matter how slowly a
  car tracks rpm — that on/off ducking *is* the audible limiter warble (and the
  damage stumble), taken directly from the sim,
- **fires a crackle burst** on each `crackle_cut` onset (`engine_limiter_crackle`):
  a short decaying noise burst (`_crackle_env`, `CRACKLE_DECAY` ≈ 6 ms tail)
  standing in for unburnt fuel popping in the exhaust on overrun. This is
  **limiter-only** — a damage misfire ducks but does not pop, since the crackle
  fits the limiter's clean on-throttle bounce, not a damaged engine sputtering.

With `fuel_cut` false the output is byte-for-byte the pre-limiter voice, so
normal running is unaffected. The crackle and duck are deliberately *not* a
fixed-frequency gate; if a sharper per-ignition-event "braap" is ever wanted, it
belongs in the **sim** (cutting individual firing events), with the audio then
following the same way it follows the bounce now.

## Per-engine volume

The engine's master level (`engine_volume_db`, in decibels) is an **engine**
property, the same way `low_octave_mix` is: `EngineLibrary` defines `volume_db`
on each catalog entry and `EngineLibrary.apply()` writes it into
`GameConfig.engine_volume_db` (called from `car.gd`'s `apply_car()`, falling
back to the existing config value if unset) before `reconfigure()` rebuilds the
synth, which reads it into the synth's `_master_gain`. This lets each engine
sit at its own level relative to the others. `_master_gain` scales **only the
cylinder firing voice** — the broadband noise is added after it at a constant
level, so an engine's `volume_db` changes the note's loudness without altering
the noise floor. Most engines sit near the `-5.0` default; the V8s/V12/V10
voicings are boosted (`+7` to `+10`) to read louder and more aggressive.

## Per-engine noise

The white-noise input to the soft clipper is an **engine** property, authored
in decibels: `EngineLibrary` defines `noise_db` on each catalog entry and
`EngineLibrary.apply()` converts it to a linear amplitude (`db_to_linear`) and
writes it into `GameConfig.engine_noise_level` before `reconfigure()` rebuilds
the synth — so the synth itself is unchanged (it still reads the linear
`_noise_level`). This gives the clipper's two inputs — voice and noise —
independent per-engine levels (`volume_db` and `noise_db`). Every catalog entry
currently shares the same `noise_db` (`-54.0`), a placeholder for future
per-engine voicing.

The soft clipper's **post-amp** is an engine property too:
`EngineLibrary.soft_clip_post_gain` → `GameConfig.engine_soft_clip_post_gain`,
written by `EngineLibrary.apply()`. The pre-amp/`drive` stays global, so per
engine an entry controls its voice (`volume_db`), its noise (`noise_db`), and
its post-shaper output trim (`soft_clip_post_gain`); only the saturation amount
is shared.

## Tests

`tests/headless/test_engine_audio.gd` — firing-phase setup, `fill()` output,
clamping, silence on zero requested frames, volume scaling the cylinder voice,
the noise floor staying constant across volumes, and the rev-limiter fuel-cut
duck + crackle (ducks the voice, stays sharp under slow smoothing, crackles on
cut onset, and leaves the no-cut voice unchanged), the soft-clip curve (bounded
when overdriven, rounds peaks, drive/post-gain scaling), and the DC blocker
keeping an overdriven voice AC-dominated rather than collapsing to DC silence,
and the forced-induction layers (whistle energy rising with boost, a BOV event
adding a transient burst, a supercharger whine appearing only when enabled).
`tests/headless/test_engine_library.gd` checks `EngineLibrary.apply()` writes
volume/noise/low-octave/post-gain correctly for each catalog entry.
`tests/headless/test_car_types.gd` checks each car's referenced engine ends up
applied to the live config (volume, noise level, post-gain).

## Forced induction

On top of the base cylinder voice, the synth layers four turbo/supercharger
elements, all independently gained and all opt-in via their config gains
(zero gain = no cost, no sound — old cars are unaffected):

- **Spool whistle.** Resonant **band-pass-filtered noise** (a real turbo is air
  through the compressor, not a pure tone — a wavetable sine read as a piercing
  whine). White noise runs through a TPT/Cytomic state-variable band-pass filter
  (integrator states `_svf_ic1`/`_svf_ic2`, band output `v1` normalized by `k`
  so `Q` sets tone not level). The centre frequency sweeps
  `engine_turbo_whistle_freq_min`→`engine_turbo_whistle_freq_max` with the shaft
  speed `turbo_spin` (`= omega_turbo / turbo_omega_ref`); `engine_turbo_whistle_q`
  is the airy↔tonal resonance and `engine_turbo_air_mix` blends in a one-pole
  low-passed broadband air-rush layer (`_air_lp`, `TURBO_AIR_LP_HZ`). Amplitude
  tracks `boost` and `engine_turbo_whistle_gain` (×`TURBO_WHISTLE_LEVEL`); only
  runs while `boost > 0`. The SVF coefficients (a `tan` + a few products) are
  computed ONCE per `fill()` — boost/spin are constant across a buffer — so the
  per-sample loop is just the cheap SVF recurrence, no per-sample transcendental.
- **Blow-off valve (BOV) burst.** A transient decaying noise burst
  (`_bov_env`, instant attack + exponential decay), edge-triggered when
  `bov_event` goes true, scaled by `engine_turbo_bov_gain` **× the boost level at
  the lift** (so a full-boost lift dumps the loudest "pshhh", a partial spool a
  softer one). `bov_event` fires on a throttle lift while boosted OR at the start
  of a gear shift (the driver lifts to shift, so it vents even with the throttle
  held — see `EngineSim._step_turbo`). The decay length is
  set by `engine_turbo_bov_decay_ms` (a time in ms, converted to the per-sample
  factor `_bov_decay` via `_decay_factor` at init) — independent of the anti-lag
  bang's decay. Going back on the throttle (`throttle > 0.1` and NOT mid-shift, so
  a held throttle during a shift's own vent isn't cut) **immediately kills** any
  ringing tail — the manifold re-pressurizes and the valve shuts. An optional
  **flutter** LFO (`engine_turbo_bov_flutter_amount` depth,
  `engine_turbo_bov_flutter_hz` rate) tremolos the burst for the stuttering
  surge "brrrap"; its phase resets on each trigger. `bov_event` is **latched** by the sim (set on the
  lift-while-boosted edge, not cleared per-substep) and **consumed** by
  `engine_audio.gd._process` (read then cleared): the engine steps 8× per physics
  tick but audio samples once per rendered frame, so a single-substep pulse would
  be missed — latch-and-consume guarantees each blow-off fires exactly once.
- **Anti-lag bang burst.** Its OWN independent decaying noise burst
  (`_antilag_env`, `engine_turbo_antilag_bang_gain`, with its own decay length
  `engine_turbo_antilag_decay_ms` → `_antilag_decay`) — separate from the BOV
  burst — retriggered every `ANTILAG_BANG_INTERVAL` seconds while
  `antilag_active` stays true (coasting on boost with anti-lag engaged), via
  `_antilag_timer`.
- **Supercharger whine.** A wavetable tone (`_build_whistle_table` /
  `_read_whistle`, ×`TURBO_TONE_LEVEL`) — a supercharger genuinely IS a
  mechanical belt-driven tone, so the tonal wavetable is right here. Pitch tracks
  engine rpm directly (belt-driven: `rpm * SUPERCHARGER_BELT_HZ_PER_RPM`) and it
  is always on (not gated on boost) while `supercharger_enabled` is true, scaled
  by `engine_supercharger_whine_gain`.

The whistle and whine are summed onto the `voice` signal (after its own
`_master_gain` is applied, so they carry their own independent gains rather
than the engine-voice master level); the BOV and anti-lag bursts ride on the
noise bus (like the crackle). All four then DC-block and soft-clip together
with the rest of the engine signal.

`fill()` gained four new trailing params — `boost`, `turbo_spin`,
`bov_event`, `antilag_active` — all defaulted (`0.0`/`0.0`/`false`/`false`),
so every pre-existing call site and test keeps working unchanged.
`scripts/engine_audio.gd._process` computes `turbo_spin` from
`engine.omega_turbo / Config.data.turbo_omega_ref` (guarded against a zero
`turbo_omega_ref`) and passes `engine.boost`, `engine.bov_event`, and
`engine.antilag_active` straight through from `EngineSim`. See
[forced-induction.md](forced-induction.md) for the underlying turbo/supercharger
simulation these signals come from.

## Related config

`engine_volume_db` (engine property via `EngineLibrary.volume_db`),
`engine_idle_gain`, `engine_harmonics`, `engine_noise_level`,
`engine_smoothing_rate`, `engine_low_octave_mix` (engine property via
`EngineLibrary.low_octave_mix`), `engine_limiter_cut_level`,
`engine_limiter_crackle`, `engine_soft_clip_drive` (global),
`engine_soft_clip_post_gain` (engine property via
`EngineLibrary.soft_clip_post_gain`), `turbo_enabled`, `turbo_omega_ref`,
`supercharger_enabled`, `engine_turbo_whistle_gain`, `engine_turbo_bov_gain`,
`engine_turbo_antilag_bang_gain`, `engine_supercharger_whine_gain`. See
[configuration.md](configuration.md) and `scripts/engine_library.gd`.

## Performance note

The per-sample synthesis loop is the project's heaviest pure-CPU cost (run on the
main thread at the mix rate — several times heavier under single-threaded web
WASM than on desktop). Optimisations in place, all behaviour-preserving:
- **Voice wavetable (the big one).** The firing-pulse voice is a periodic
  function of crank phase, parameterised only by load (throttle), so instead of
  re-evaluating its `firing_phases × harmonics` `sin`/`exp` sum every sample, the
  synth bakes the voice over one crank cycle into a small bank of tables — one per
  load level (`VOICE_LOAD_TABLES`) — **once at init** (`_build_voice_bank`), then
  reads it back per sample with bilinear interpolation in phase and load
  (`_read_voice`). Pitch (rpm) falls out for free: the crank phase still advances
  at the rpm-derived rate, the table is just sampled at that phase. This trades
  the per-sample transcendentals for a handful of array reads — measured **3.4×
  (i4) to 8.1× (v12)** faster on the voice, with the cost now *constant* in
  cylinder count (so big engines benefit most) and a worst-case approximation
  error of ~`8e-5` (inaudible; guarded by `test_wavetable_matches_direct_voice`).
  The voice is continuous in phase (at a firing the window is 1 but the harmonic
  sum is 0), so linear interpolation tracks it tightly. `_voice()` is retained
  unchanged as the offline table builder, so the baked sound is the original
  design — and it still computes its per-harmonic weights (`pow(0.6 + 0.4·load,
  h)/h`) once per call rather than per firing phase.
- `engine_audio.gd` sizes its scratch buffer to exactly the frames available and
  pushes it directly, dropping the per-frame `slice()` allocation.
- The shipped `engine_harmonics` is **3** (`config/game_config.tres`; code default
  is 4). With the wavetable this no longer affects the per-sample cost (only the
  one-time bake), but it still shapes the baked timbre. Config value, not a code
  change; the synth reads it unchanged.

Note: a GDScript `sin`-lookup table or a harmonic-recurrence rewrite were both
measured to be *slower* than direct `sin` here — in interpreted GDScript a builtin
`sin` is a cheap dispatch into compiled engine math, so replacing one `sin` with
several interpreted ops loses. The wavetable wins because it replaces the *entire*
`firing_phases × harmonics` sum (≈16 transcendentals) with ~5 array ops, not one
`sin` with several. See `todo/performance-optimisations.md` item 6.

These are guarded by the existing `test_engine_audio*` tests (which build the
synth from `GameConfig.new()`, i.e. the code defaults, so they are unaffected by
the shipped `engine_harmonics` override). Because the fill is frame-coupled, a slow
main-thread frame (e.g. a terrain chunk-crossing build on web) can underrun the
generator buffer — hence the `BUFFER_SECONDS` headroom above and the terrain work
to keep crossing frames short (see [terrain.md](terrain.md)).

## HQ car-lineup rev preview

`scripts/car_preview_audio.gd` (`class_name CarPreviewAudio`, an `AudioStreamPlayer`)
plays a short engine rev for whichever car is highlighted in the HQ lineup, so the
player hears each car as they flick through the car-park. `hq.gd` lazily creates one
and calls `_preview_rev(engine_id)` from `_focus_changed()` — the single choke-point
every selection change (arrows, swipe-flick, tap, and the initial lineup show) passes
through, so the rev fires on every flick *and* on the first car shown. It reads the
car's *current* engine via `EngineSwap.current_engine_id(...)`, so a swapped-in engine
previews correctly.

Unlike the in-car `engine_audio.gd`, the preview owns everything itself — its own
`AudioStreamGenerator`, an isolated `GameConfig` copy (`Config.data.duplicate(true)` +
`EngineLibrary.apply`), an `EngineSim`, and an `EngineAudioSynth` — so it needs no live
physics car. `rev(engine_id)` rebuilds all of these from idle and flushes the generator
(`stop()`/`play()`), so starting a new rev instantly cancels the one in flight. The
`EngineSim` is stepped in **neutral** (`gear = 0`), i.e. free-revving against crank
torque + engine friction with no wheels/load: the throttle is held full for
`GameConfig.preview_rev_hold_seconds` (default 0.5) so the flywheel climbs, then released
so engine braking pulls it back to idle naturally, at which point the preview ends. Sim
stepping (`_advance`) is separated from buffer filling (`_fill_audio`) so it runs and is
testable headless with no audio device — see `tests/headless/test_car_preview_audio.gd`,
which asserts the *envelope behaviour* (throttle held then released, revs climb then fall
to idle, a new rev cancels the old) without pinning the hold seconds or any RPM number.

On web this stacks with a second, engine-level buffer: because the export is
single-threaded (`thread_support=false`), Godot mixes **all** audio (this synth
plus every sample bus) on the main thread and pushes it to the browser's WebAudio
ring buffer. With the 30 fps thermal cap on mobile/web (`target_fps_mobile`, see
`world.gd`), the main thread sleeps ~33 ms between frames, so the default 15 ms
output buffer drains before the next refill and the *whole mix* crackles — not
just the engine note. `project.godot` therefore sets
`audio/driver/output_latency.web=120` (desktop keeps the tight 15 ms default) so
the WebAudio buffer has enough slack to survive the inter-frame gap. This is read
at driver init (engine boot), so it lives in project settings, not runtime code.
