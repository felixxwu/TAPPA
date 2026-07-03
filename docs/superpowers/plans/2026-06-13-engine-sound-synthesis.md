# Engine Sound Synthesis Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Synthesize a real-time, RPM-driven engine sound for the car using a firing-table model so engine types (inline-4, V6, V8) are configuration, not code.

**Architecture:** A pure-DSP `EngineAudioSynth` (RefCounted) generates samples from a master crank phase, emitting a firing pulse at each cylinder's crank angle from a per-engine firing-angle table. A thin `EngineAudio` node (AudioStreamPlayer, child of Car) reads live `EngineSim` state each frame and pushes generated frames into an `AudioStreamGenerator`. Tuning lives in `GameConfig`.

**Tech Stack:** Godot 4 / GDScript, `AudioStreamGenerator` + `AudioStreamGeneratorPlayback`, GUT for headless tests.

**Note — no git:** This project is intentionally NOT under version control. Each task's final step runs the headless test suite as its checkpoint instead of a commit. Do not run git commands.

---

## File Structure

- Create `scripts/engine_audio_synth.gd` — `class_name EngineAudioSynth`, pure DSP. No node/engine refs. Single `fill(...)` entry point + internal phase/smoothing/noise state.
- Create `scripts/engine_audio.gd` — `extends AudioStreamPlayer`. Owns the `AudioStreamGenerator`, reads `get_parent().drivetrain.engine`, calls `synth.fill(...)`.
- Modify `scripts/engine.gd` — add `var throttle := 0.0`, set in `step()`.
- Modify `scripts/game_config.gd` — add engine-audio export fields + `engine_firing_phases()` helper.
- Modify `config/game_config.tres` — set the new fields' values.
- Modify `car.tscn` — add `EngineAudio` node as a child of `Car`.
- Create `tests/headless/test_engine_audio.gd` — DSP unit tests.
- Modify `tests/headless/test_smoke.gd` — assert the node mounts.

---

## Task 1: Store throttle on EngineSim

**Files:**
- Modify: `scripts/engine.gd` (add field near line 16; set in `step()` near line 129)
- Test: `tests/headless/test_engine.gd`

- [ ] **Step 1: Write the failing test**

Add to `tests/headless/test_engine.gd`:

```gdscript
func test_step_records_throttle() -> void:
	_engine.gear = 1
	_engine.step(0.016, 0.7, 0.0)
	assert_almost_eq(_engine.throttle, 0.7, 0.0001, "step() records its throttle arg")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./run_tests.sh --skip-visual`
Expected: FAIL — `Invalid get index 'throttle'` (member not declared).

- [ ] **Step 3: Add the field and assignment**

In `scripts/engine.gd`, add after line 16 (`var shift_timer ...`):

```gdscript
var throttle := 0.0  # last drive request seen by step(), for the audio synth
```

The `step()` argument is also named `throttle`, which shadows the member, so assign via `self`. Make the top of `step()` read:

```gdscript
func step(h: float, throttle: float, driveline_omega: float) -> float:
	self.throttle = throttle
	var cfg: GameConfig = Config.data
	shift_timer = maxf(shift_timer - h, 0.0)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./run_tests.sh --skip-visual`
Expected: PASS, including the new `test_step_records_throttle` and all existing engine tests.

---

## Task 2: GameConfig audio fields + firing-phase helper

**Files:**
- Modify: `scripts/game_config.gd` (Engine & Transmission group; helper near `terrain_layers()`)
- Test: `tests/headless/test_engine_audio.gd` (create)

- [ ] **Step 1: Write the failing test**

Create `tests/headless/test_engine_audio.gd`:

```gdscript
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./run_tests.sh --skip-visual`
Expected: FAIL — `Invalid set index 'engine_cylinders'` (members not declared).

- [ ] **Step 3: Add the fields**

In `scripts/game_config.gd`, inside the `@export_group("Engine & Transmission")` block (after `shift_hysteresis`, before the `drive_mode` line is fine), add:

```gdscript
# --- Engine audio ---
@export var engine_cylinders := 4  # firings per cycle = cylinders (4-stroke)
# Crank angles (degrees over the 720° four-stroke cycle) at which cylinders
# fire. Even spacing → smooth (inline-4, flat-plane V8); uneven → burble
# (cross-plane V8, V6). Empty → even spacing derived from engine_cylinders.
@export var engine_firing_angles: Array[float] = [0.0, 180.0, 360.0, 540.0]
@export var engine_volume_db := -6.0  # master level of the engine voice
@export_range(0.0, 1.0) var engine_idle_gain := 0.25  # audible floor at zero throttle
@export_range(1, 8) var engine_harmonics := 4  # firing-pulse richness
@export_range(0.0, 1.0) var engine_noise_level := 0.15
```

- [ ] **Step 4: Add the helper**

In `scripts/game_config.gd`, add near `terrain_layers()`:

```gdscript
# Firing angles normalized to the 0..1 crank cycle (720° four-stroke). When
# engine_firing_angles is empty, derive even spacing from engine_cylinders so
# the simple case needs no explicit table.
func engine_firing_phases() -> Array[float]:
	var out: Array[float] = []
	if engine_firing_angles.is_empty():
		var n: int = maxi(engine_cylinders, 1)
		for i in range(n):
			out.append(float(i) / float(n))
		return out
	for angle in engine_firing_angles:
		out.append(fposmod(angle / 720.0, 1.0))
	return out
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `./run_tests.sh --skip-visual`
Expected: PASS, including both new firing-phase tests.

---

## Task 3: EngineAudioSynth — produces clamped, non-empty output

**Files:**
- Create: `scripts/engine_audio_synth.gd`
- Test: `tests/headless/test_engine_audio.gd`

- [ ] **Step 1: Write the failing test**

Add to `tests/headless/test_engine_audio.gd`:

```gdscript
const MIX_RATE := 22050.0


func _make_synth() -> EngineAudioSynth:
	var cfg := GameConfig.new()
	cfg.engine_firing_angles = [0.0, 180.0, 360.0, 540.0]
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
	assert_eq(buf[0].x, 0.123, "n_frames 0 writes no samples")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./run_tests.sh --skip-visual`
Expected: FAIL — `Could not find type "EngineAudioSynth"`.

- [ ] **Step 3: Create the synth (minimal, additive firing pulses)**

Create `scripts/engine_audio_synth.gd`:

```gdscript
class_name EngineAudioSynth
extends RefCounted
# Pure DSP: turns engine state into PCM. One master crank phase advances per
# revolution; each firing phase emits a decaying multi-harmonic pulse. Owns no
# nodes — fully headless-testable. fill() is the only entry point.

const RPM_TO_REV_PER_SEC := 1.0 / 60.0
const SMOOTH_HZ := 12.0  # low-pass cutoff for rpm/throttle (per second)

var _mix_rate: float
var _firing_phases: Array[float]
var _harmonics: int
var _idle_gain: float
var _noise_level: float
var _master_gain: float  # linear, from engine_volume_db

var _crank_phase := 0.0  # 0..1 over the four-stroke cycle
var _sm_rpm := 0.0
var _sm_throttle := 0.0
var _rng := RandomNumberGenerator.new()


func _init(cfg: GameConfig, mix_rate: float) -> void:
	_mix_rate = mix_rate
	_firing_phases = cfg.engine_firing_phases()
	_harmonics = cfg.engine_harmonics
	_idle_gain = cfg.engine_idle_gain
	_noise_level = cfg.engine_noise_level
	_master_gain = db_to_linear(cfg.engine_volume_db)
	_rng.seed = 1  # deterministic for tests


func fill(buffer: PackedVector2Array, rpm: float, throttle: float, shift_cut: bool, n_frames: int) -> void:
	var dt := 1.0 / _mix_rate
	var smooth := clampf(SMOOTH_HZ * dt, 0.0, 1.0)
	var cut := 0.05 if shift_cut else 1.0
	for i in range(n_frames):
		_sm_rpm = lerpf(_sm_rpm, rpm, smooth)
		_sm_throttle = lerpf(_sm_throttle, clampf(throttle, 0.0, 1.0), smooth)
		var cycles_per_sec := _sm_rpm * RPM_TO_REV_PER_SEC * 0.5  # 720° cycle = 2 revs
		_crank_phase = fposmod(_crank_phase + cycles_per_sec * dt, 1.0)
		var sample := _voice(_crank_phase, _sm_throttle)
		sample += (_rng.randf() * 2.0 - 1.0) * _noise_level * (0.2 + 0.8 * _sm_throttle)
		var gain := _master_gain * lerpf(_idle_gain, 1.0, _sm_throttle) * cut
		sample = clampf(sample * gain, -1.0, 1.0)
		buffer[i] = Vector2(sample, sample)


# Sum each firing pulse: a short harmonic burst windowed near its crank phase.
func _voice(phase: float, load: float) -> float:
	var out := 0.0
	for fp in _firing_phases:
		var d := fposmod(phase - fp, 1.0)  # 0..1 since this firing fired
		var window := exp(-d * 18.0)  # decaying pulse envelope
		var local := d * TAU
		var pulse := 0.0
		for h in range(1, _harmonics + 1):
			var weight := pow(0.6 + 0.4 * load, float(h)) / float(h)
			pulse += sin(local * float(h)) * weight
		out += pulse * window
	return out / float(maxi(_firing_phases.size(), 1))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./run_tests.sh --skip-visual`
Expected: PASS — clamped output, non-empty, and zero-frames writes nothing.

---

## Task 4: Synth responds to throttle and RPM

**Files:**
- Test: `tests/headless/test_engine_audio.gd`
- (No implementation expected — these verify Task 3's model. If a test fails, fix `engine_audio_synth.gd`.)

- [ ] **Step 1: Write the tests**

Add to `tests/headless/test_engine_audio.gd`:

```gdscript
func _rms(buf: PackedVector2Array, n: int) -> float:
	var acc := 0.0
	for i in range(n):
		acc += buf[i].x * buf[i].x
	return sqrt(acc / float(n))


# Count signal periods via rising zero-crossings → a frequency proxy.
func _zero_crossings(buf: PackedVector2Array, n: int) -> int:
	var count := 0
	for i in range(1, n):
		if buf[i - 1].x <= 0.0 and buf[i].x > 0.0:
			count += 1
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
	_make_synth().fill(lo, 1500.0, 0.6, false, n)
	_make_synth().fill(hi, 6000.0, 0.6, false, n)
	assert_gt(_zero_crossings(hi, n), _zero_crossings(lo, n), "higher rpm → higher pitch")


func test_shift_cut_drops_amplitude() -> void:
	var n := 4096
	var on := PackedVector2Array(); on.resize(n)
	var cut := PackedVector2Array(); cut.resize(n)
	_make_synth().fill(on, 4000.0, 0.8, false, n)
	_make_synth().fill(cut, 4000.0, 0.8, true, n)
	assert_lt(_rms(cut, n), _rms(on, n), "shift cut ducks the engine")
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `./run_tests.sh --skip-visual`
Expected: PASS — amplitude rises with throttle, frequency rises with RPM, shift cut ducks. If any fails, adjust `engine_audio_synth.gd` (e.g. smoothing/gain) until the model holds.

---

## Task 5: Firing table differentiates engine character

**Files:**
- Test: `tests/headless/test_engine_audio.gd`

- [ ] **Step 1: Write the test**

Add to `tests/headless/test_engine_audio.gd`:

```gdscript
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
```

- [ ] **Step 2: Run test to verify it passes**

Run: `./run_tests.sh --skip-visual`
Expected: PASS — the two firing tables yield measurably different waveforms.

---

## Task 6: EngineAudio node + scene wiring

**Files:**
- Create: `scripts/engine_audio.gd`
- Modify: `car.tscn` (add child node under `Car`)
- Modify: `tests/headless/test_smoke.gd`

- [ ] **Step 1: Write the failing smoke test**

Add to `tests/headless/test_smoke.gd`:

```gdscript
func test_car_has_engine_audio_player() -> void:
	var car := _scene.get_node("Car") as VehicleBody3D
	var audio := car.get_node_or_null("EngineAudio") as AudioStreamPlayer
	assert_not_null(audio, "Car has an EngineAudio AudioStreamPlayer child")
	assert_true(audio.stream is AudioStreamGenerator, "stream is an AudioStreamGenerator")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./run_tests.sh --skip-visual`
Expected: FAIL — `EngineAudio` node not found (null).

- [ ] **Step 3: Create the node script**

Create `scripts/engine_audio.gd`:

```gdscript
extends AudioStreamPlayer
# Bridges the simulated engine to audio: reads EngineSim state each frame and
# pushes synthesized PCM into an AudioStreamGenerator. The DSP lives in
# EngineAudioSynth; this node only owns the generator and the per-frame pull.

const MIX_RATE := 22050.0
const BUFFER_SECONDS := 0.1

var _synth: EngineAudioSynth
var _playback: AudioStreamGeneratorPlayback
var _scratch := PackedVector2Array()


func _ready() -> void:
	var cfg: GameConfig = Config.data
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = MIX_RATE
	gen.buffer_length = BUFFER_SECONDS
	stream = gen
	_synth = EngineAudioSynth.new(cfg, MIX_RATE)
	play()
	_playback = get_stream_playback() as AudioStreamGeneratorPlayback


func _process(_delta: float) -> void:
	if _playback == null:
		return  # headless / no audio device
	var engine: EngineSim = get_parent().drivetrain.engine
	var n := _playback.get_frames_available()
	if n <= 0:
		return
	if _scratch.size() < n:
		_scratch.resize(n)
	_synth.fill(_scratch, engine.rpm(), engine.throttle, engine.shift_timer > 0.0, n)
	_playback.push_buffer(_scratch.slice(0, n))
```

- [ ] **Step 4: Add the node to `car.tscn`**

In `car.tscn`, add the script as an `ext_resource` near the top (after the existing `car.gd` ext_resource at line 4):

```
[ext_resource type="Script" path="res://scripts/engine_audio.gd" id="3_engaud"]
```

Then add the node as a child of the root `Car` node (e.g. after the `[node name="Chassis" ...]` block):

```
[node name="EngineAudio" type="AudioStreamPlayer" parent="."]
script = ExtResource("3_engaud")
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `./run_tests.sh --skip-visual`
Expected: PASS — the smoke test finds the node with an `AudioStreamGenerator` stream, and all prior tests stay green.

---

## Task 7: Populate config values + full verification

**Files:**
- Modify: `config/game_config.tres`

- [ ] **Step 1: Add the audio values to the resource**

In `config/game_config.tres`, under `[resource]`, add (keep the inline-4 default; tune later):

```
engine_cylinders = 4
engine_firing_angles = Array[float]([0.0, 180.0, 360.0, 540.0])
engine_volume_db = -6.0
engine_idle_gain = 0.25
engine_harmonics = 4
engine_noise_level = 0.15
```

- [ ] **Step 2: Run the config-applied test + headless suite**

Run: `./run_tests.sh --skip-visual`
Expected: PASS — `test_config_applied.gd` and all engine-audio/smoke tests green.

- [ ] **Step 3: Final full verification (headless + visual)**

Run: `./run_tests.sh`
Expected: ALL tests pass. The visual pass opens a window briefly — expected and OK. Audio has no golden image, so no `--regen-goldens` is needed.

- [ ] **Step 4: Summary**

Report: files created/modified, that the full suite passes, and that switching engine type is now a `engine_firing_angles` / `engine_cylinders` edit in `config/game_config.tres` (e.g. a cross-plane V8 table for a lopey idle).
```
```

---

## Self-Review

**Spec coverage:**
- Store throttle on EngineSim → Task 1. ✓
- Firing-table DSP model (crank phase, per-cylinder pulses, throttle timbre/volume, noise, shift cut, smoothing) → Task 3 (model) + Task 4 (throttle/rpm/shift behavior). ✓
- `EngineAudioSynth` pure/headless-testable with the exact `fill(...)` signature → Task 3. ✓
- `engine_audio.gd` node reading `get_parent().drivetrain.engine`, AudioStreamGenerator, null-playback guard → Task 6. ✓
- GameConfig fields + `engine_firing_phases()` helper (empty → even spacing) → Task 2. ✓
- `config/game_config.tres` values → Task 7. ✓
- `car.tscn` wiring → Task 6. ✓
- Tests: non-empty/clamped/no-NaN (T3), amplitude-vs-throttle (T4), freq-vs-rpm (T4), firing-table differentiation (T5), shift-cut ducking (T4), smoke mount (T6) → all present. ✓
- Out-of-scope items (spatial audio, resonance, samples) → excluded. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code. Task 1 Step 3 explicitly resolves the arg/member shadowing with `self.throttle = throttle`. ✓

**Type consistency:** `fill(buffer, rpm, throttle, shift_cut, n_frames)` signature identical in Task 3 impl, Task 3/4/5 tests, and Task 6 node. `EngineAudioSynth.new(cfg, mix_rate)` consistent. `engine_firing_phases()` named identically in helper, tests, and synth. `engine.throttle` / `engine.shift_timer` / `engine.rpm()` match `EngineSim`. ✓
