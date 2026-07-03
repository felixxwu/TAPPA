# Engine sound synthesis — design

**Date:** 2026-06-13
**Status:** Approved (pending spec review)

## Goal

Synthesize (not sample) a basic but convincing engine sound for the car,
driven in real time by the simulated `EngineSim` state. The design must make
different engine types (inline-4, V6, V8, …) a matter of configuration, not
new code.

## Available signals

`EngineSim` already exposes everything the audio needs except load:

- `rpm()` — floored at `idle_rpm`, capped near `redline_rpm`, so the sound is
  always present (no separate idle layer required).
- `shift_timer` — `> 0` during a shift's clutch-open cut.
- `gear`, `idle_omega()`, `redline_omega()`.

**Change to `EngineSim`:** add `var throttle := 0.0`, set at the top of
`step()` from its `throttle` argument, so the audio can read engine load. This
is the only edit to the existing sim.

## DSP model — firing-table driven

A 4-stroke engine fires `cylinders / 2` times per crankshaft revolution. Rather
than a single oscillator at the firing frequency (which can only ever sound
"even"), the synth tracks **one master crank phase per revolution** and emits a
short firing pulse at each cylinder's crank angle, read from a per-engine
**firing-angle table**.

- Master crank phase advances by `rpm/60` revolutions per second. Driving the
  phase from a running accumulator means pitch glides smoothly with RPM — no
  clicks when the frequency changes.
- Each firing angle in the table (degrees within the 720° four-stroke cycle,
  normalized to the 0..1 crank-cycle phase) triggers a decaying firing pulse —
  a short burst of a few harmonics. Evenly spaced angles → smooth (inline-4,
  flat-plane V8); unevenly spaced angles → the characteristic burble/lope
  (cross-plane V8, V6). This single mechanism subsumes the simple case: an
  inline-4 is just four evenly spaced angles.
- **Throttle → timbre + volume:** higher throttle raises overall gain *and* the
  weight of upper harmonics (brighter/harder under load); off-throttle is
  quieter and duller.
- **Noise:** a small amount of filtered noise scaled with RPM adds grit.
- **Shift cut:** while `shift_timer > 0`, gain ducks toward near-silent.
- **Smoothing:** RPM and throttle are low-pass smoothed across frames so
  frame-rate jitter doesn't warble the pitch or volume.

Output samples are clamped to [-1, 1].

## Architecture (3 pieces)

1. **`EngineAudioSynth`** (`scripts/engine_audio_synth.gd`, `class_name`,
   `extends RefCounted`) — pure DSP. Holds the crank phase, smoothed
   RPM/throttle, and noise state. Single entry point:

   ```
   fill(buffer: PackedVector2Array, rpm: float, throttle: float,
        shift_cut: bool, n_frames: int) -> void
   ```

   It owns no nodes and no engine reference, so it is fully **headless
   testable**. Firing table, cylinder count, gains, harmonics, and noise level
   are read from `GameConfig` at construction.

2. **`engine_audio.gd`** (`scripts/engine_audio.gd`, `extends
   AudioStreamPlayer`) — a non-spatial player, child of `Car` in `car.tscn`. On
   `_ready` it sets up an `AudioStreamGenerator` (fixed `mix_rate`, short
   buffer) and plays. Each `_process` it reads `get_parent().drivetrain.engine`
   for `rpm()`, `throttle`, and `shift_timer > 0`, then fills and pushes the
   number of frames the playback reports available.

3. **`GameConfig` additions** (in the "Engine & Transmission" group):
   - `engine_cylinders: int` (default 4)
   - `engine_firing_angles: Array[float]` — crank angles in degrees over the
     720° cycle; default is the evenly spaced inline-4 `[0, 180, 360, 540]`.
     A helper `engine_firing_phases() -> Array[float]` returns them normalized
     to 0..1. When empty, the synth derives even spacing from
     `engine_cylinders` (so the simple case needs no table).
   - `engine_volume_db: float` (master level)
   - `engine_idle_gain: float` (0..1 floor so idle is audible but quiet)
   - `engine_harmonics: int` (firing-pulse richness)
   - `engine_noise_level: float`

   All live in `config/game_config.tres` per project rules; scene/script
   literals are fallback defaults.

## Data flow

```
EngineSim.step() ──sets──▶ engine.throttle
                                  │
car.tscn: Car ──child──▶ EngineAudio (_process)
                                  │ reads rpm(), throttle, shift_timer
                                  ▼
                        EngineAudioSynth.fill(...) ──▶ AudioStreamGenerator
```

## Error handling / edge cases

- `n_frames == 0` (playback buffer full) → `fill` writes nothing, no error.
- Output always clamped to [-1, 1]; no NaN even at rpm 0 or with an empty
  firing table (falls back to even spacing).
- Reset (`EngineSim.reset()`) leaves rpm at idle; the synth just tracks it, no
  special handling.

## Testing

New `tests/headless/test_engine_audio.gd` exercising `EngineAudioSynth`
directly (no audio device needed):

- Output is non-empty, all samples in [-1, 1], no NaN.
- Amplitude (RMS) rises with throttle.
- Dominant frequency (via zero-crossing / autocorrelation period count) rises
  with RPM and matches `rpm/60 × cylinders/2` for the even inline-4 table.
- An uneven firing table produces a different period structure than the even
  table at the same RPM (confirms firing-table differentiation works).
- Shift cut drops RMS amplitude toward the idle floor.

`tests/headless/test_smoke.gd` gains a check that the `EngineAudio` node mounts
under `Car` and is an `AudioStreamPlayer` with an `AudioStreamGenerator`
stream.

Final verification runs the full `./run_tests.sh` suite.

## Out of scope (YAGNI)

- Spatial/3D audio positioning (use a plain `AudioStreamPlayer`).
- Exhaust resonance / cabin filtering, turbo/blow-off, tire and wind noise.
- Per-engine sample assets.
