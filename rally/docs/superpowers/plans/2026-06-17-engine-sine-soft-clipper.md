# Engine Sine Soft Clipper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hard output clamp in the engine audio synth with a sine-function soft clipper driven by a global pre-amp, followed by a global post-amp and a final clamp backstop.

**Architecture:** All DSP lives in `EngineAudioSynth.fill()` (pure, headless). Two new global `GameConfig` floats (`engine_soft_clip_drive`, `engine_soft_clip_post_gain`) are read into synth fields in `_init()` and used to shape the combined `(voice + noise) * env` signal per sample. Per-car `engine_volume_db` is unchanged and already acts pre-shaper.

**Tech Stack:** Godot 4 / GDScript, GUT tests (vendored in `addons/gut/`).

## Global Constraints

- Godot binary: `/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot` (override with `$GODOT`).
- This project is **intentionally NOT under git** — do NOT run any git commands. The TDD "commit" step is replaced by running the relevant test subset.
- All tuning values live in `config/game_config.tres` (a `GameConfig` resource); `@export` defaults in `scripts/game_config.gd` are fallback defaults.
- Run tests with `./run_tests.sh`; during the task run only the affected file, save the full suite for the end. Run test commands in the background per project rules where they take a while; a single test file is fast enough to run directly here.
- Signal chain (verbatim from spec): per-car volume (`_master_gain`) pre-shaper → sine shaper (`drive`) → global `post_gain` → `clamp ±1`.
- Output samples MUST stay in [-1, 1].

---

### Task 1: Add the two global config settings

**Files:**
- Modify: `scripts/game_config.gd:183` (insert after `engine_limiter_crackle`)
- Modify: `config/game_config.tres` (add the two values to the engine section)

**Interfaces:**
- Produces: `GameConfig.engine_soft_clip_drive : float` (default `0.6`) and `GameConfig.engine_soft_clip_post_gain : float` (default `1.0`), read by Task 2.

- [ ] **Step 1: Add the `@export` properties**

In `scripts/game_config.gd`, immediately after the `engine_limiter_crackle` declaration (line 183), add:

```gdscript
## Pre-amp into the sine soft clipper that shapes the combined engine signal
## (voice + noise + crackle). Low-level gain through the curve ≈ (π/2)·drive;
## higher = more low-level boost and harder peak rounding (more grit). Must be
## > 0. 0.6 ≈ near-unity low level with gentle peak rounding.
@export_range(0.05, 4.0) var engine_soft_clip_drive := 0.6
## Global post-amp applied after the soft clipper, before the final clamp. Sets
## output level independently of the drive amount. 1.0 = transparent; > 1 is
## caught by the clamp backstop.
@export_range(0.0, 4.0) var engine_soft_clip_post_gain := 1.0
```

- [ ] **Step 2: Add the tuning values to the resource**

In `config/game_config.tres`, after the `engine_limiter_crackle = 0.015` line (line 30), add:

```
engine_soft_clip_drive = 0.6
engine_soft_clip_post_gain = 1.0
```

- [ ] **Step 3: Verify the resource loads**

Run: `$GODOT --headless --path . --quit 2>&1 | grep -i "error\|soft_clip" || echo "no load errors"`
Expected: no parse/load errors mentioning `game_config.tres` (the `|| echo` prints "no load errors" when grep matches nothing).

---

### Task 2: Apply the sine soft clipper + post gain in the synth

**Files:**
- Modify: `scripts/engine_audio_synth.gd` (add two fields near line 24, read them in `_init()` near line 46, replace the final clamp in `fill()` at line 92)
- Test: `tests/headless/test_engine_audio.gd`

**Interfaces:**
- Consumes: `GameConfig.engine_soft_clip_drive`, `GameConfig.engine_soft_clip_post_gain` (Task 1).
- Produces: per-sample output of `fill()` = `clampf(sin((PI*0.5)*clampf(x*_soft_clip_drive,-1,1)) * _soft_clip_post_gain, -1, 1)` where `x = (voice + noise) * env`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/headless/test_engine_audio.gd`:

```gdscript
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `$GODOT --headless --path . -s addons/gut/gut_cmdln.gd -gtest=res://tests/headless/test_engine_audio.gd -gexit 2>&1 | tail -30`
Expected: FAIL — `soft_clip` method does not exist on `EngineAudioSynth` / config property errors.

- [ ] **Step 3: Add the synth fields**

In `scripts/engine_audio_synth.gd`, after the `_crackle` field declaration (line 24), add:

```gdscript
var _soft_clip_drive: float  # pre-amp into the sine shaper (>0)
var _soft_clip_post_gain: float  # global post-amp after the shaper
```

- [ ] **Step 4: Read the config in `_init()`**

In `_init()`, after the `_crackle = cfg.engine_limiter_crackle` line (line 46), add:

```gdscript
	_soft_clip_drive = maxf(cfg.engine_soft_clip_drive, 0.001)  # >0; avoid /0-ish curves
	_soft_clip_post_gain = cfg.engine_soft_clip_post_gain
```

- [ ] **Step 5: Add the `soft_clip` helper and use it in `fill()`**

In `scripts/engine_audio_synth.gd`, replace the final clamp line in `fill()`:

```gdscript
			sample = clampf((voice + noise) * env, -1.0, 1.0)
```

with:

```gdscript
			sample = soft_clip((voice + noise) * env)
```

Then add this method (e.g. directly above `_voice`):

```gdscript
# Sine-function soft clipper applied to the combined engine signal. The inner
# clamp keeps the argument on the first quarter-wave [-π/2, π/2] where sin is
# monotonic, so the shaper rounds peaks toward ±1 without folding back. The
# global post gain sets output level; the outer clamp is a backstop for
# post_gain > 1.
func soft_clip(x: float) -> float:
	var shaped := sin((PI * 0.5) * clampf(x * _soft_clip_drive, -1.0, 1.0))
	return clampf(shaped * _soft_clip_post_gain, -1.0, 1.0)
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `$GODOT --headless --path . -s addons/gut/gut_cmdln.gd -gtest=res://tests/headless/test_engine_audio.gd -gexit 2>&1 | tail -30`
Expected: PASS — all `test_soft_clip_*` tests green, and the pre-existing engine audio tests still pass.

---

### Task 3: Update feature docs

**Files:**
- Modify: `features/engine-audio.md` (synthesis-model step 6, new "Soft clipper" section, "Related config" list)
- Modify: `features/configuration.md` (engine config list)

**Interfaces:**
- Consumes: behavior implemented in Tasks 1–2. No code.

- [ ] **Step 1: Amend synthesis-model step 6**

In `features/engine-audio.md`, in the `fill()` numbered list, change step 6 from:

```
  6. apply the throttle/idle/shift envelope, clamp to [-1, 1].
```

to:

```
  6. apply the throttle/idle/shift envelope, then run the combined signal
     through the sine soft clipper (`soft_clip()`) — see *Soft clipper* below —
     which bounds the output to [-1, 1].
```

- [ ] **Step 2: Add the "Soft clipper" section**

In `features/engine-audio.md`, after the "Low octave" section, add:

```markdown
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
post-amp** (`engine_soft_clip_post_gain`) → clamp. Per-car volume therefore
acts before the clipper; the post gain is a single global trim.

Both settings are global. `engine_soft_clip_drive` defaults to `0.6` (low-level
gain ≈ π/2·0.6 ≈ 0.94 with gentle peak rounding — a touch warmer than the old
hard clip, applied to every car). `engine_soft_clip_post_gain` defaults to `1.0`
(transparent). Higher drive boosts low-level content and hardens the knee;
`soft_clip()` is a public method on `EngineAudioSynth` so tests exercise the
curve directly.
```

- [ ] **Step 3: Update the "Related config" list**

In `features/engine-audio.md`, in the "Related config" paragraph, add `engine_soft_clip_drive` and `engine_soft_clip_post_gain` to the list of engine settings.

- [ ] **Step 4: Update `features/configuration.md`**

In `features/configuration.md`, add `engine_soft_clip_drive` and `engine_soft_clip_post_gain` to the engine-audio config listing, matching the format of neighboring entries (e.g. `engine_noise_level`, `engine_limiter_crackle`).

- [ ] **Step 5: Run the full test suite (final verification)**

Run: `./run_tests.sh` (in the background per project rules; wait for the completion notification).
Expected: ALL tests pass.
