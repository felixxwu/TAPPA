# Engine sine-function soft clipper — design

## Goal

Add a sine-function soft clipper to the combined engine audio signal (cylinder
firing voice + broadband noise + crackle burst) in `EngineAudioSynth`, replacing
the current hard clamp with a smoothly saturating curve that rounds peaks for a
warmer, less harsh output.

## Background

`scripts/engine_audio_synth.gd` synthesizes the engine sound per sample. The
final combined value is built in `fill()` (currently ~line 87–92):

```gdscript
var voice := sample * _master_gain * _cut_gain
var noise := (_rng.randf() * 2.0 - 1.0) * _noise_level * (0.2 + 0.8 * _sm_throttle)
noise += (_rng.randf() * 2.0 - 1.0) * _crackle_env
var env := lerpf(_idle_gain, 1.0, _sm_throttle) * cut
sample = clampf((voice + noise) * env, -1.0, 1.0)
```

That `(voice + noise) * env` is the combined engine + noise signal, currently
passed through a **hard** clipper (`clampf` to [-1, 1]). The soft clipper
replaces this single line.

## Signal chain

```
per-car volume (_master_gain) ─┐
                               ├─→ (voice + noise) * env ─→ sine shaper ─→ × post_gain ─→ clamp ±1
constant noise floor ──────────┘       [pre-shaper]          [drive]       [global]      [backstop]
```

- **Per-car `engine_volume_db`** (`_master_gain`) scales the cylinder firing
  voice *into* the combined signal — it is therefore applied **before** the
  waveshaper. The constant noise floor and the envelope (`env`) likewise form
  part of the pre-shaper signal. (This already matches the current code; the
  spec just makes the ordering explicit.)
- The **sine waveshaper** (`_soft_clip_drive`, pre-amp) saturates the combined
  pre-shaper signal.
- A single **global `engine_soft_clip_post_gain`** (post-amp) sets output level
  after shaping, followed by a final hard clamp backstop.

## The curve

A sine waveshaper applied to the combined signal, then global post gain:

```gdscript
# Sine soft clipper: round the peaks into the rails instead of a hard corner.
# clamp keeps us on the first quarter-wave so the shaper stays monotonic.
var x := (voice + noise) * env
var shaped := sin((PI * 0.5) * clampf(x * _soft_clip_drive, -1.0, 1.0))
# Global post-amp sets output level after shaping; final clamp is the backstop
# (only bites if post_gain is pushed > 1 hard enough to exceed the rails).
sample = clampf(shaped * _soft_clip_post_gain, -1.0, 1.0)
```

Properties:

- `sin((π/2)·y)` saturates at ±1 when `|y| ≥ 1`; the inner
  `clampf(x · drive, -1, 1)` keeps the argument on the first quarter-wave
  (`[-π/2, π/2]`), where `sin` is monotonic — so the shaper never folds back.
- Low-level gain through the shaper is `(π/2)·drive`; as `drive` rises,
  low-level content is boosted and peaks round off more (more grit). The global
  post gain then scales the whole shaped result uniformly.

## Configuration

Both new settings are **global**, not per-car. Add to `GameConfig` and
`config/game_config.tres`, and read into float fields in
`EngineAudioSynth._init()`, following the same pattern as `_noise_level`,
`_master_gain`, etc.

- **`engine_soft_clip_drive`** (pre-amp into the shaper), default **`0.6`**
  ("lightly applied"): low-level gain `≈ π/2·0.6 ≈ 0.94` with gentle peak
  rounding — a touch warmer/smoother than the current hard clip. Pushing toward
  1 and above progressively boosts low-level content and hardens the knee.
  Must be `> 0`; clamp defensively to a small positive minimum in `_init()`.
- **`engine_soft_clip_post_gain`** (global post-amp after the shaper), default
  **`1.0`** (transparent). Lets output level be set independently of the drive
  amount; a value `> 1` is allowed and caught by the final clamp backstop.

Note: per-car level remains `engine_volume_db` (`_master_gain`), unchanged and
applied pre-shaper. The post gain is deliberately a single global trim, not
per-car.

## Scope of effect

The soft clipper applies to the **whole combined bus** — engine firing voice +
constant noise floor + crackle burst — so the noise is shaped along with the
voice. This matches the "combined signal" intent.

## Tests (`tests/headless/test_engine_audio.gd`)

- Output stays bounded to [-1, 1], including a deliberately overdriven input
  that would otherwise hard-clip.
- The curve actually softens vs. a hard clamp: a peak that hard-clip would
  flatten comes out rounded, with slope still positive approaching the rail.
- A higher `drive` saturates a given input more than a lower `drive`.
- `engine_soft_clip_post_gain` scales the shaped output: a post gain `< 1`
  lowers output level, `> 1` raises it and is held to ±1 by the final clamp;
  per-car `engine_volume_db` still acts pre-shaper (voice level into the
  shaper), independent of the post gain.

## Docs

- Update `features/engine-audio.md`: amend synthesis-model step 6 (the clamp
  step) and add a short "Soft clipper" section describing the curve, the signal
  chain (per-car volume pre-shaper → drive → global post gain → clamp), the
  `engine_soft_clip_drive` / `engine_soft_clip_post_gain` config, and defaults.
- Add `engine_soft_clip_drive` and `engine_soft_clip_post_gain` to the "Related
  config" list and `features/configuration.md`.

## Out of scope

- Per-car soft-clip drive (could be added later via `CarLibrary`, same as
  `volume_db` / `low_octave_mix`).
- Any oversampling / anti-aliasing of the shaper (the existing synth runs at a
  fixed `MIX_RATE` with no oversampling; the soft clipper follows suit).
