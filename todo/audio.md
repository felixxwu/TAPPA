# Audio (SFX, beeps, UI, music) — implementation spec

> Status: **planned, not yet implemented.** Implementation brief for game audio
> **beyond the engine** — the impact/crash, countdown, UI and stinger sounds the
> `gameplay.md` › *Presence & atmosphere* and damage/flow loops imply but no spec
> currently owns. The existing procedural engine sound (`engine-audio.md`) stays
> as-is; this spec adds everything else and the **bus layout** the Settings
> overlay (`todo/settings.md`) controls. Follow the config-first convention
> (`CLAUDE.md`). Update `features/engine-audio.md` (or a new `features/audio.md`)
> and add tests in the same piece of work.

## Goal

A small, central way to play one-shot sound effects and (optionally) music, on a
**named bus layout** so volumes are mixable and the Settings overlay can drive
them — covering the moments the game currently makes silently: hitting a sign or
tree, the countdown, finishing a stage, UI clicks, and the podium result.

## Why it's a gap

- The **damage model is collision-driven** (`features/damage.md` reads contact
  impulses) but **silent** — a crash that destroys a car gives no audio cue.
- The **countdown** (`todo/stage-start-and-end.md` § 3, big `3·2·1·GO`) has no
  beep.
- The diegetic menus (`todo/menus.md`) and the **podium / reward reveal** have no
  UI or sting audio, so "presence & atmosphere" is half-delivered.
- There is **no bus structure**, so the Settings overlay (`todo/settings.md`) has
  nothing to attach volume sliders to.

## Current state (measured from the code)

- **Engine audio is fully procedural** — `engine_audio.gd` (`extends
  AudioStreamPlayer`) pushes synthesized PCM into an `AudioStreamGenerator`
  (`engine_audio.gd:14-22`); the DSP is `EngineAudioSynth` (pure, no nodes).
  **No audio *samples* are used anywhere** and there is no SFX/music playback.
- **No bus layout.** `project.godot` defines **no `[audio]` / bus config**, so
  everything (just the engine today) plays on the default **Master** bus. There
  is no `default_bus_layout.tres`.
- **In-code node creation is the house pattern** (`billboard_field.gd`,
  `wheel_force_debug.gd:40-52`), so creating `AudioStreamPlayer`/`-3D` nodes in
  code fits the codebase.
- **`main.tscn` has no audio nodes** beyond the engine player on the `Car`.

## Bus layout (the foundation Settings needs)

Add a `default_bus_layout.tres` (or build it in code at boot) with:

```
Master
├─ Engine   (the existing procedural engine player routes here)
├─ SFX       (impacts, countdown, UI, stingers)
└─ Music     (optional beds; deferred content, bus exists now)
```

- Re-point `engine_audio.gd`'s player to the **Engine** bus (one line:
  `bus = "Engine"`), so engine volume is independently mixable.
- Settings sliders (`todo/settings.md`) set `AudioServer.set_bus_volume_db` per
  bus (Master / SFX / Music / Engine), persisted to `settings.cfg`.

## An `Audio` autoload (one-shot SFX)

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
  `sign_textures` in `todo/roadside-signs.md`), empty = silent fallback so the
  game runs before audio assets are authored.

## Sound set (the moments to cover)

| id | Trigger | Bus | Source spec |
|---|---|---|---|
| `impact_soft` / `impact_hard` | contact impulse over threshold; hard above a bigger one | SFX (3D) | `features/damage.md` § 2 |
| `wreck` | HP→0 wreck | SFX | `features/damage.md` § 4 |
| `countdown_beep` / `countdown_go` | each `3·2·1` tick / `GO` | SFX | `todo/stage-start-and-end.md` § 3 |
| `ui_move` / `ui_select` / `ui_back` | menu navigation | SFX | `todo/menus.md` nav |
| `reward_reveal` | lootbox/reward reveal settles | SFX | `todo/menus.md` rig 5 |
| `podium` | podium result shown | SFX | `todo/menus.md` Podium |
| `music_menu` / `music_run` | HQ / run beds (optional) | Music | deferred |

The **damage model** and **stage** specs call `Audio.play_sfx*` at their existing
trigger points — those hooks already exist in this spec set, audio just rides
them. Impact intensity (`impact_soft` vs `impact_hard`) keys off the same impulse
the damage model already computes, so no new physics read.

## Hooking in (touch points, all thin)

- `features/damage.md` § 2: when an impact passes the threshold, also
  `Audio.play_sfx_3d("impact_*", contact_point)`; on wreck, `play_sfx("wreck")`.
- `todo/stage-start-and-end.md` § 3: in `show_countdown`, fire `countdown_beep`
  per integer tick and `countdown_go` at `GO`.
- `todo/menus.md`: navigation actions and the reward reveal call `play_sfx`.

## New `GameConfig` tunables

| Field | Type | Default | Purpose |
|---|---|---|---|
| `sfx_clips` | Dictionary | `{}` | Map clip id → `res://audio/*.ogg`. Empty = silent fallback. |
| `music_clips` | Dictionary | `{}` | Map music id → file. Empty = no music. |
| `sfx_pool_size` | int | `8` | One-shot `AudioStreamPlayer` pool size. |
| `impact_hard_impulse` | float | — | Impulse above which a crash uses `impact_hard`. Shares the damage-model impulse scale. |

Default **bus volumes** are owned by `todo/settings.md` (persisted to
`settings.cfg`), not `GameConfig` — `GameConfig` holds the authored clip wiring,
the player profile holds chosen volumes.

## Dependencies

- **Settings** (`todo/settings.md`) — owns the volume sliders that drive the bus
  layout this spec defines. Build the bus layout here; Settings reads/writes it.
- **Damage model** (`features/damage.md`) — the impact/wreck triggers.
- **Stage start/end** (`todo/stage-start-and-end.md`) — the countdown triggers.
- **Menus** (`todo/menus.md`) — UI / reward / podium triggers.
- **Engine audio** (`features/engine-audio.md`) — re-bussed to `Engine`;
  otherwise unchanged.
- **Asset work (action item):** author the clip set above (PS1-era / lo-fi to
  match the look). Owner: Felix. Geometry/logic works with the silent fallback
  until clips land.

## Testing

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
  visually, `todo/roadside-signs.md`).
