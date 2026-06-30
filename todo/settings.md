# Settings — implementation spec

> Status: **planned, not yet implemented.** Implementation brief for the
> player-facing **Settings / options** surface and its persistence — the gap
> `gameplay.md`'s shippable (itch.io) build implies but no spec owned.
> `todo/save-persistence.md` deliberately **excludes** settings ("audio/graphics/
> control settings are *not* covered here … likely [their] own `settings.cfg` —
> different lifecycle") and flags it as an open question; this spec resolves it.
> Follow the config-first convention (`CLAUDE.md`). Update the relevant
> `features/*.md` doc and add tests in the same piece of work.
>
> **Scope decided (with the user): minimal now** — volume sliders + a quality
> toggle, reachable from Pause and Title. Richer graphics/control options are
> noted in *Out of scope*.

## Goal

A small settings store, separate from the progression profile, that loads at
boot, applies its values to the live engine (audio buses, a quality flag), and
is edited through one flat overlay reachable from Pause and Title.

## Why a separate store from the save profile

Settings have a **different lifecycle** from progression: they're device-local
preferences, should survive a "New game" (which wipes the profile,
`todo/save-persistence.md` › *reset_new_game*), and shouldn't bloat or version
with `profile.json`. So: a **separate `user://settings.cfg`** via Godot's
`ConfigFile` (flat key/value is a perfect fit), loaded once at boot — distinct
from the `Save` autoload that owns `profile.json`.

## Current state (measured from the code)

- **No settings of any kind.** The only autoload is `Config`
  (`project.godot:18-20`), holding the working `GameConfig`; there is no options
  UI and nothing reads/writes preferences.
- **No audio bus layout** exists (`project.godot` has no `[audio]` section), so
  volume control has nothing to attach to until `todo/audio.md` adds the bus
  layout. **This spec depends on that.**
- **`hud_enabled` is the existing pattern** for a runtime toggle
  (`game_config.gd`, read in `hud.gd._ready()`) — but that's an *authored
  default*, not a *player preference*. Settings are the player-mutable layer.
- **No `get_tree().paused` usage / Pause overlay yet** — the Pause overlay is
  `todo/menus.md` overlay 8; Settings opens from it.

## What persists (`settings.cfg`)

```
[audio]
master_volume = 1.0      # 0..1, mapped to dB on the Master bus
sfx_volume    = 1.0      # SFX bus
music_volume  = 0.8      # Music bus
engine_volume = 1.0      # Engine bus (the procedural engine, re-bussed in audio.md)

[video]
quality = "default"      # single low-effort toggle for now (see Quality below)

[schema]
version = 1
```

Volumes are stored linear `0..1` (slider-friendly) and converted to dB on apply
via `linear_to_db` → `AudioServer.set_bus_volume_db(bus_idx, db)`, with `0.0`
mapping to muted (`-80 dB` or `set_bus_mute`). The bus names match
`todo/audio.md`'s layout (Master / SFX / Music / Engine).

## A `Settings` autoload

`scripts/settings.gd`, `class_name SettingsManager extends Node`, registered in
`project.godot [autoload]` alongside `Config` / `Save` / `Audio`:

```gdscript
Settings.values            # parsed ConfigFile values (defaults if absent)
Settings.load_or_default()  # boot: read settings.cfg or seed defaults
Settings.set_value(section, key, v)  # mutate + apply live + autosave (debounced)
Settings.apply()            # push all values to the engine (audio buses, quality)
Settings.save()             # write user://settings.cfg
```

- `apply()` runs **once at boot** (after the audio bus layout exists) and again
  on any change, so a slider tweak is audible immediately.
- **Degrade gracefully:** if `settings.cfg` can't be written (private browsing /
  blocked storage on web — same constraint `todo/save-persistence.md` notes),
  keep values in memory; settings simply won't persist. Never crash.

## The Settings overlay (UI)

A flat `CanvasLayer` overlay (pragmatic-hybrid: dense controls, readability wins
— same rationale as `todo/menus.md`'s Pause/Standings overlays), added to
`todo/menus.md` as **overlay 11**:
- **Volume sliders:** Master / SFX / Music / Engine, each `0..1`, live-applied.
- **Quality toggle** (see below).
- **Back** returns to wherever it was opened from (Pause or Title).
- Reachable from **Pause** (overlay 8 gains a *Settings* button) and **Title**
  (`todo/menus.md` nav flow). Opening from Pause does **not** unpause.

## Quality toggle (minimal)

The project is "inherently lean" — most specs explicitly avoid quality-tier
branching. So keep this **one low-effort switch**, not a full graphics menu:
- Candidates, pick one to wire first: a **render-scale / resolution** factor, or
  toggling the **post-process** pass (`PostProcess` in `main.tscn`), or the
  existing perf-overlay/foliage density from `todo/performance-optimisations.md`.
- Store as an opaque `quality` string so the option set can grow without a schema
  bump. Default `"default"` changes nothing from today.

If wiring a real quality lever proves more than trivial, ship **volumes only**
first and leave `quality` stored-but-inert — the overlay still works.

## Dependencies

- **Audio** (`todo/audio.md`) — **hard dependency**: provides the Master/SFX/
  Music/Engine bus layout the volume sliders drive. Build that first (or at least
  its bus layout).
- **Menus** (`todo/menus.md`) — hosts the overlay (new overlay 11) and the Pause/
  Title entry points.
- **Save / persistence** (`todo/save-persistence.md`) — *not* a dependency for
  storage (separate `settings.cfg`), but this spec **closes** that spec's
  "Settings vs progress" open question (answer: separate file).

## Testing

Headless GUT tests (`tests/headless/`, `user://` redirected to a temp dir):
- **Round-trip:** set values via the API, `save()`, reload, assert equality;
  missing file → defaults.
- **Apply maps to dB:** `master_volume = 0.0` mutes the Master bus; `1.0` ≈ 0 dB;
  monotonic in between (assert via `AudioServer.get_bus_volume_db`).
- **New game preserves settings:** `Save.reset_new_game()` wipes the profile but
  `settings.cfg` is untouched (cross-check with the save tests).
- **Headless-safe:** with no audio device, `apply()` does not error.
- **Smoke:** the `Settings` autoload registers (`tests/headless/test_smoke.gd`).

## Out of scope / open questions

- **Control rebinding** — remapping the driving inputs (and the menu-nav inputs
  from `todo/menus.md`); a bigger input-map pass, deferred. Mobile has its own
  on-screen controls (`mobile-controls.md`).
- **Richer video options** — resolution list, vsync, FOV, fullscreen; the lean
  design argues against a big menu. Add individually only if needed.
- **Accessibility** — colourblind-safe HUD/standings palette, text scale; worth a
  later pass, not specced now.
- **Where Title lives** — the Title screen itself is a `todo/menus.md` decision
  (diegetic HQ-exterior beat); Settings just hangs off it.
