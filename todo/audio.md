# Audio (SFX, beeps, UI, music) — implementation spec

> Status: **PARTIALLY DONE — music shipped; the SFX SEAM has now shipped; the CUES
> are still unwired.** Landed since this spec was written: the **`Audio` autoload**
> (`scripts/audio.gd`, `class_name AudioManager`, registered as `Audio` in
> `project.godot`), the **SFX bus** (`Audio._ensure_bus()`, sending to Master), a
> procedural **`Audio.play_beep(frequency_hz, duration_sec, volume_db)`** primitive
> with the headless guard / `play()`-then-`get_stream_playback()` ordering / build-once
> player encapsulated in it, the `@export_group("SFX")` tunables in `GameConfig`, docs
> in **`features/sfx.md`**, and tests in `tests/headless/test_audio.gd`.
>
> **Still open:** every actual CALL SITE (countdown beep + GO sting, impact/wreck,
> UI move/select/back, reward reveal, podium) — each is now a one-line
> `Audio.play_beep(...)` at the trigger; `stage_manager.gd` carries an AUDIO HOOK
> comment marking the countdown one. Also open: the authored **clip** library
> (`play_sfx(id)` + `sfx_clips`), `play_sfx_3d`, the one-shot player **pool**, and the
> **SFX volume slider** in Settings. Nothing here needs a new facility — extend
> `scripts/audio.gd`.
>
> Original status note follows.
>
> Status: **PARTIALLY DONE — the music half shipped; SFX still open.** The
> **music** system landed (a `Music` autoload / `music_director.gd`,
> `music_library.gd`, `music_schedule.gd`, `music/*.ogg` beds, and a runtime-created
> **Music bus**; docs in `features/music.md`), and the Settings music-volume slider
> drives that bus. Still genuinely **not implemented**: the one-shot **SFX** side —
> impact/crash, countdown beep, UI clicks, podium/reward stingers, and an
> `Audio`/`AudioManager` with `play_sfx` / `play_sfx_3d`. The remaining spec below
> is about that SFX layer only — the bus graph is already built (see below). The
> procedural engine sound
> (`engine-audio.md`) stays as-is. Follow the config-first convention (`CLAUDE.md`)
> and add tests in the same piece of work.

## Goal

A small, central way to play one-shot sound effects and (optionally) music, on a
**named bus layout** so volumes are mixable and the Settings overlay can drive
them — covering the moments the game currently makes silently: hitting a sign or
tree, the countdown, finishing a stage, UI clicks, and the podium result.

## Why it's a gap

- The **damage model is collision-driven** (`features/damage.md` reads contact
  impulses) but **silent** — a crash that destroys a car gives no audio cue.
- The **countdown** (`stage_manager.gd`, big `3·2·1·GO` via `hud.gd::show_countdown`)
  has no beep.
- The diegetic menus (`todo/menus.md`) and the **podium / reward reveal** have no
  UI or sting audio, so "presence & atmosphere" is half-delivered.
- Only **Music** and **Engine** buses exist, so there is nowhere to route SFX and no
  SFX slider for the Settings overlay (`scripts/settings_menu.gd`) to attach to.

## Current state (measured from the code)

- **Engine audio is fully procedural** — `engine_audio.gd` (`extends
  AudioStreamPlayer`) pushes synthesized PCM into an `AudioStreamGenerator`
  (`engine_audio.gd:14-22`); the DSP is `EngineAudioSynth` (pure, no nodes).
- **Music now plays from samples** — `music_director.gd` streams `music/*.ogg`
  beds on a runtime-created **Music bus** (`features/music.md`). So the "no
  samples / no music playback" gap is closed; what remains silent is **SFX**.
- **Bus layout is partial.** `project.godot` has an `[audio]` section and a
  **Music** bus exists at runtime; there is still no dedicated **SFX** bus (SFX
  one-shots have nowhere to route yet).
- **In-code node creation is the house pattern** (`billboard_field.gd`,
  `wheel_force_debug.gd:40-52`), so creating `AudioStreamPlayer`/`-3D` nodes in
  code fits the codebase.
- **`main.tscn` has no audio nodes** beyond the engine player on the `Car`.

## Bus layout — DONE

The **SFX** bus now exists too, created by `Audio._ensure_bus()` at boot (sending to
Master), alongside the Music and Engine buses. What remains here is only the **Settings
SFX slider** persisted to the profile via `AudioServer.set_bus_volume_db` — the bus it
would drive is in place. Original note follows.

### Original note

`music_director.gd` already creates the bus graph at boot — a **Music** bus (which the
Settings music slider drives) and an **Engine** bus (which `engine_audio.gd` routes to and
which the loading screen mutes wholesale) — and applies `master_volume` to Master. So the
only thing left here is **adding an `SFX` bus** for the one-shots below, plus its Settings
slider persisted to `settings.cfg` via `AudioServer.set_bus_volume_db`.

## An `Audio` autoload (one-shot SFX) — SHIPPED (procedural half)

**What exists now** (`scripts/audio.gd`, docs `features/sfx.md`):

```gdscript
const BUS := &"SFX"
func play_beep(frequency_hz := 0.0, duration_sec := 0.0, volume_db := 0.0) -> bool
func beep_spec(frequency_hz := 0.0, duration_sec := 0.0, volume_db := 0.0) -> Dictionary
func is_available() -> bool
static func render_beep(frames, frequency_hz, mix_rate, amplitude, decay) -> PackedVector2Array
```

A procedural beep rather than a clip library, because this project ships no audio
samples yet. The sections below describe the CLIP half, which is still to do — build
it on this same node and bus.

### Original spec (clip library — still open)

`scripts/audio.gd`, `class_name AudioManager extends Node`, registered as an
autoload alongside `Config` (and `Save`, `RallySession`). A tiny one-shot player
pool so overlapping sounds (e.g. rapid impacts) don't cut each other off:

```gdscript
# Library of authored clips, keyed by a stable id (config-first: paths in GameConfig/a resource)
func play_sfx(id: String, volume_db := 0.0) -> void   # 2D UI/cue sound on the SFX bus
func play_sfx_3d(id: String, pos: Vector3) -> void      # positioned world sound (impacts)
func play_music(id: String) -> void / stop_music()      # optional; Music bus
```

- `play_sfx` grabs a free `AudioStreamPlayer` from a small pool (create N up
  front), assigns the clip, plays. `play_sfx_3d` uses `AudioStreamPlayer3D` at a
  world position for impacts (so a crash sounds where it happened).
- **Headless-safe:** like `engine_audio.gd:32` (`if _playback == null: return`),
  guard every play call so tests with no audio device are no-ops.
- Clip ids → file paths live in config (a `Dictionary` knob, mirroring
  `sign_textures` in `features/signs.md`), empty = silent fallback so the
  game runs before audio assets are authored.

## Sound set (the moments to cover)

| id | Trigger | Bus | Source spec |
|---|---|---|---|
| `impact_soft` / `impact_hard` | contact impulse over threshold; hard above a bigger one | SFX (3D) | `features/damage.md` § 2 |
| `wreck` | HP→0 wreck | SFX | `features/damage.md` § 4 |
| `countdown_beep` / `countdown_go` | each `3·2·1` tick / `GO` | SFX | `features/stage.md` (`stage_manager.gd`) |
| `ui_move` / `ui_select` / `ui_back` | menu navigation | SFX | `todo/menus.md` nav |
| `reward_reveal` | lootbox/reward reveal settles | SFX | `todo/menus.md` rig 5 |
| `podium` | podium result shown | SFX | `todo/menus.md` Podium |
| `music_menu` / `music_run` | HQ / run beds (optional) | Music | deferred |

The **damage model** and **stage** code call `Audio.play_sfx*` at their existing
trigger points — those hooks already exist in this spec set, audio just rides
them. Impact intensity (`impact_soft` vs `impact_hard`) keys off the same impulse
the damage model already computes, so no new physics read.

## Hooking in (touch points, all thin)

- `features/damage.md` § 2: when an impact passes the threshold, also
  `Audio.play_sfx_3d("impact_*", contact_point)`; on wreck, `play_sfx("wreck")`.
- `features/stage.md`: in `hud.gd::show_countdown` / `stage_manager.gd`'s countdown, fire
  `countdown_beep` per integer tick and `countdown_go` at `GO` (`GO_FLASH_SECONDS`).
- `todo/menus.md`: navigation actions and the reward reveal call `play_sfx`.

## New `GameConfig` tunables

**Already added** (`@export_group("SFX")`, authored in `config/game_config.tres`):
`sfx_enabled`, `sfx_beep_frequency_hz`, `sfx_beep_duration_sec`, `sfx_beep_volume_db`,
`sfx_beep_decay`, `sfx_mix_rate`. Still to add, with the clip library:

| Field | Type | Default | Purpose |
|---|---|---|---|
| `sfx_clips` | Dictionary | `{}` | Map clip id → `res://audio/*.ogg`. Empty = silent fallback. |
| `music_clips` | Dictionary | `{}` | Map music id → file. Empty = no music. |
| `sfx_pool_size` | int | `8` | One-shot `AudioStreamPlayer` pool size. |
| `impact_hard_impulse` | float | — | Impulse above which a crash uses `impact_hard`. Shares the damage-model impulse scale. |

Default **bus volumes** are owned by `scripts/settings_menu.gd` (persisted to
`settings.cfg`), not `GameConfig` — `GameConfig` holds the authored clip wiring,
the player profile holds chosen volumes.

## Dependencies

- **Settings** (`scripts/settings_menu.gd`) — owns the volume sliders that drive the bus
  layout this spec defines. Build the bus layout here; Settings reads/writes it.
- **Damage model** (`features/damage.md`) — the impact/wreck triggers.
- **Stage start/end** (`features/stage.md`, `scripts/stage_manager.gd`) — the countdown
  triggers.
- **Menus** (`todo/menus.md`) — UI / reward / podium triggers.
- **Engine audio** (`features/engine-audio.md`) — re-bussed to `Engine`;
  otherwise unchanged.
- **Asset work (action item):** author the clip set above (PS1-era / lo-fi to
  match the look). Owner: Felix. Geometry/logic works with the silent fallback
  until clips land.

## Testing

`tests/headless/test_audio.gd` already covers: the `Audio` autoload is registered, the
**SFX bus** exists and sends to Master, `play_beep` is a safe repeatable no-op headless
(and never creates playback), the `sfx_enabled` gate silences it, and the pure
`render_beep` DSP decays / stays finite / rejects degenerate input. Remaining:

Headless GUT tests (`tests/headless/`):
- **Bus layout:** the `Engine` / `SFX` / `Music` buses exist after boot and the
  engine player routes to `Engine`.
- **Headless no-op:** `Audio.play_sfx*` with no audio device / empty `sfx_clips`
  does not error and plays nothing (mirrors `engine_audio.gd:32`).
- **Pool reuse:** N+1 rapid `play_sfx` calls reuse the pool without crashing
  (oldest is recycled).
- **Trigger wiring (with the damage/stage tests):** an above-threshold impact and
  a countdown tick each invoke `Audio` (assert via a stubbed `AudioManager`),
  without requiring real playback.

## Out of scope / open questions

- **Music** — beds are scaffolded (bus + `play_music`) but the actual tracks and
  when they cross-fade are deferred content.
- **3D vs 2D for impacts** — `play_sfx_3d` proposed for positional crashes;
  could be flat 2D if positioning adds little. Decide at build.
- **Surface/terrain audio** (gravel vs tarmac roll, skids) — a richer driving-
  audio pass, not covered here; the road is uniform today.
- **Spoken pace notes / co-driver calls** — a rally staple, but big content;
  explicitly out of scope for now (the roadside signs cover turn warning
  visually — see `features/signs.md`).
