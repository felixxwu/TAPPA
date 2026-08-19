# SFX — one-shot sound effects (`Audio` autoload)

**Source:** `scripts/audio.gd` (`class_name AudioManager`, autoload `Audio`)
**Tests:** `tests/headless/test_audio.gd`

**If you want to play a sound when something happens, this is the whole page you
need.** The answer is one line at the call site:

```gdscript
Audio.play_beep()                  # the standard cue, tuned in GameConfig
Audio.play_beep(1200.0)            # a higher-pitched variant (e.g. "GO" over a tick)
Audio.play_beep(1200.0, 0.25, 3.0) # pitch, length (s), +dB offset on the configured level
```

Do **not** create an `AudioStreamPlayer`, an `AudioStreamGenerator` or a PCM loop at
the call site. Everything that makes that hard is already solved once, in
`scripts/audio.gd` — see "What the seam owns" below for the four specific ways
hand-rolling it goes wrong here.

## Files

| Thing | Where |
|---|---|
| The autoload | `scripts/audio.gd` (`class_name AudioManager`), registered as `Audio` in `project.godot` |
| Tunables | `config/game_config.tres` / `scripts/game_config.gd` → `@export_group("SFX")` |
| Tests | `tests/headless/test_audio.gd` |
| Planned cue set / clip library | `todo/audio.md` |
| The other audio systems | `features/engine-audio.md` (procedural engine note), `features/music.md` (music beds) |

## Public API

```gdscript
func play_beep(frequency_hz := 0.0, duration_sec := 0.0, volume_db := 0.0) -> bool
func is_available() -> bool
func beep_spec(frequency_hz := 0.0, duration_sec := 0.0, volume_db := 0.0) -> Dictionary
static func render_beep(frames: int, frequency_hz: float, mix_rate: float,
        amplitude: float, decay: float) -> PackedVector2Array
const BUS := AudioBuses.SFX
```

`AudioBuses` (`scripts/audio_buses.gd`) is the single definition of every mix bus name
(`MASTER`, `MUSIC`, `ENGINE`, `SFX`) — audio.gd's `BUS` and music_director.gd's bus
lookups all reference it, so a bus rename touches one file. See `features/music.md`.

- `frequency_hz` / `duration_sec`: `<= 0` means "use the configured default"
  (`sfx_beep_frequency_hz` / `sfx_beep_duration_sec`). Pass a value only when the cue
  is deliberately different from the standard blip.
- `volume_db` is an **offset** on top of `sfx_beep_volume_db`, so a call site can make
  one cue louder without restating (or drifting from) the authored base level.
- Returns `true` only if audio was actually pushed. It returns `false` — never errors,
  never blocks — when headless, when `sfx_enabled` is off, or when the generator
  buffer is momentarily full. Callers do not need to guard.
- `beep_spec` resolves a request against config (enabled gate + defaults for any
  argument left at 0) and returns `{}` when nothing should sound. `play_beep` is a thin
  wrapper over it; the split exists so the *decision* is testable headless, where no
  real playback can exist.
- `render_beep` is the pure DSP (one exponentially-decaying sine, stereo frames), split
  out static so the waveform is testable with no audio device.

## Why a *beep* is the primitive

This project ships **no audio samples**. The engine note is synthesized
(`EngineAudioSynth`) and the only files on disk are the music beds. So the SFX layer
starts procedural: a short decaying sine is the cue vocabulary until authored clips
exist. When clips land, add a `play_sfx(id)` to this same node and bus (the clip map
belongs in `GameConfig`) rather than starting a second facility — `todo/audio.md` has
the planned id set.

## What the seam owns (and why you must not re-do it)

1. **`push_buffer` vs `push_frame`.** `AudioStreamGeneratorPlayback.push_buffer()`
   takes a `PackedVector2Array`; `push_frame()` takes a single `Vector2`. Mixing them
   up is a static type error that breaks the whole file at compile time.
2. **`play()` before `get_stream_playback()`.** `get_stream_playback()` returns `null`
   on a *stopped* player. Fetch it first and the customary
   `if playback == null: return` guard swallows the mistake — you ship silence with no
   error anywhere. `engine_audio.gd::_ready` shows the same order.
3. **The headless guard.** Any node that calls `play()` must first check
   `Platform.is_headless()` — see the invariant in `features/testing.md` and
   `features/engine-audio.md`. Skipping it produces an *intermittent* teardown
   segfault, i.e. a flake somebody else pays for.
4. **Build once, at boot.** The player and generator are created in `_ready()` and
   reused. Rebuilding them per call (worse, from a `_process` path) reassigns `stream`
   and invalidates the playback just fetched.

## Bus layout

`Audio._ensure_bus()` creates a dedicated **SFX** bus at boot, sending to Master —
matching how `music_director.gd` creates the **Music** and **Engine** buses
(`_ensure_music_bus` / `_ensure_engine_bus`). A named bus per source is the house
convention: it's what lets a settings slider or a wholesale mute act on one lever.
Never route a sound to Master directly.

The bus is created **headless too** (the bus graph is safe under the dummy driver;
only *playback* is not), so the bus-layout contract holds in tests.

## Tunables (`@export_group("SFX")`)

| Field | Purpose |
|---|---|
| `sfx_enabled` | Master switch; false makes every call a silent no-op |
| `sfx_beep_frequency_hz` | Default cue pitch |
| `sfx_beep_duration_sec` | Default cue length |
| `sfx_beep_volume_db` | Default cue level (per-call `volume_db` offsets this) |
| `sfx_beep_decay` | Exponential tail decay rate; higher = more percussive |
| `sfx_mix_rate` | Synthesis/mix rate for procedural SFX |

These are tunables — tests must not pin their values (see `CLAUDE.md` → Testing).

## Not yet wired

The countdown beep, impact/wreck sounds, UI clicks and the podium sting are all
**still unwired**; the seam exists, the call sites don't. `scripts/stage_manager.gd`
carries an explicit AUDIO HOOK comment at the GO transition. `todo/audio.md` tracks
the full set.
