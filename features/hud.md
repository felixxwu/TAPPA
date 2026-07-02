# HUD

**Source:** `scripts/hud.gd` (extends `CanvasLayer`). Node `HUD` (layer 2) in
`main.tscn`, with `car` wired to the `Car`.

On-screen readout plus two interactive mode buttons.

## Elements

| Node | Shows | Source |
|------|-------|--------|
| `SpeedLabel` | `"<n> km/h"` | `car.linear_velocity.length() * 3.6` |
| `GearLabel` | `R` / `N` / `1`–`5` | `engine.gear` via `_gear_text()` |
| `RPMLabel` | `"<n> rpm"` | `engine.rpm()` |

The `SpeedLabel` / `GearLabel` / `RPMLabel` trio is a **dev diagnostic**: hidden by
default and toggled with **H** (`toggle_debug_arrows`) — the same gate as the debug
force arrows, and like them honoured only in a debug build (release/web ignore the
key). Their text keeps refreshing while hidden, so it's correct the instant H
reveals it. See [debug-tools.md](debug-tools.md).
| `CountdownLabel` | `3` / `2` / `1` / `GO` | driven by `StageManager` (centered, large) |
| `ElapsedLabel` | `m:ss.cc` run timer | driven by `StageManager` (top centre) |
| `StageDeltaLabel` | `P1 ±n.ns` pace popup | driven by `StageManager` (top-centre, code-built) |
| `StageCompletePanel` | placeholder result panel | driven by `StageManager` |
| `HPBar` (+ `HPLabel`) | `Health NN%` over a bar | `car.damage` (colour-graded green→amber→red) |
| `ImpactFlash` | red screen flash on a hit | `car.damage` (sized to the HP lost, fades out) |

## Damage gauge

The `HPBar`/`HPLabel`/`ImpactFlash` are driven by `_update_damage(delta)` (called
from `_process`) off the car's `DamageModel` (see [damage.md](damage.md)): the bar
tracks `hp / max_hp` and is hue-graded from green (full) to red (empty), under a
**`Health NN%`** label (a percentage, not a raw HP number — "HP" reads as
horsepower); below `hud_low_hp_warn_frac` it pulses a low-health warning. Any HP drop since the previous
frame bumps the red `ImpactFlash` overlay (sized to the loss), which fades back
out each frame. The gauge is hidden when `hud_hp_enabled` is off; it shows for
every car (the starter is a normal wreckable car like any other).

## Stage flow widgets

The `CountdownLabel`, `ElapsedLabel` and `StageCompletePanel` are hidden at
`_ready()` and driven by the `StageManager` (see [stage.md](stage.md)) through
these methods: `show_countdown(seconds_left)` (big centered `3·2·1·GO`;
`ceili` maps the remaining time to the digit, `0` → `GO`), `hide_countdown()`,
`show_elapsed(seconds)` (top-centre `m:ss.cc`, gated by `hud_elapsed_enabled`),
and `show_stage_complete(seconds)` (the placeholder result panel). `_format_time`
is the shared `m:ss.cc` formatter.

The **`StageDeltaLabel`** is the in-run *"vs P1" pace popup*: a fifth method,
`show_stage_delta(delta_ms)`, the `StageManager` pulses **every few turns** with the
player's time delta to the leading rival at that point. It's built in code (not the
scene) by `_build_stage_delta_label()`, anchored top-centre just below the run
timer. The sign is explicit and colour-coded
— **negative = ahead** (green, shown as `P1 -1.3s`), **positive = behind** (red, shown
as `P1 +2.1s`) — matching the design-system palette (`UITheme.GREEN`/`RED`). Gated by
`hud_stage_delta_enabled`; it auto-hides after `stage_delta_show_seconds` (a countdown
in `_process`). How the delta itself is computed lives in [stage.md](stage.md).

## Behavior

- `_ready()` — sets visibility from `cfg.hud_enabled`.
- `_process(delta)` — refreshes labels each frame.
- `_gear_text(gear)` — formats -1→`R`, 0→`N`, else the number.

## Layout

Labels are direct children of the `HUD` CanvasLayer, positioned via
`offset_*` with explicit `font_size` overrides. All sizes are deliberately
small (font 14 for labels) — the HUD is rendered at 1/2 scale.

The `ElapsedLabel` run timer is anchored to the **top centre**
(`anchor_left/right = 0.5`, `grow_horizontal = 2`, `horizontal_alignment = 1`) so
it sits in the middle of the screen regardless of viewport width, with the
`StageDeltaLabel` pace popup tucked just below it. The **top-right corner is left
clear for the Pause button**, which lives on the separate `PauseMenu` CanvasLayer
(see [menus.md](menus.md)), not the HUD. The `HPBar`/`HPLabel` health gauge is
anchored to the **bottom centre** of the viewport (`anchor_top/bottom = 1.0`,
`anchor_left/right = 0.5`, `grow_horizontal = 2`).

## Build version

The build version is shown on the **title screen only** (the HQ exterior title
overlay, `scripts/hq.gd` → `_build_title_overlay()`, bottom-right corner) — not on
the in-run HUD. It is derived automatically as `0.<git commit count>` with the
short SHA appended (e.g. `v0.61 (b154d5c)`). `build_web.sh` computes this from git
and stamps it into `application/config/version` in `project.godot` for the
duration of the export (reverting the file afterwards), so it is baked into the
web `.pck`. Editor and test runs fall back to the committed default
`config/version="0.0-dev"`.

## Related config

`hud_enabled`, `hud_elapsed_enabled`, `hud_hp_enabled`, `hud_low_hp_warn_frac`,
`hud_stage_delta_enabled`, `stage_delta_interval_turns`, `stage_delta_show_seconds`.
See [configuration.md](configuration.md) and [damage.md](damage.md).
