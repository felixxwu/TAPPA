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

The `SpeedLabel` / `GearLabel` / `RPMLabel` trio, plus a code-built `BoostLabel`
(boost as a percentage of full boost, or `Boost N/A` on a naturally-aspirated engine —
formatted by the pure `hud.gd::boost_text`; it reads
`maxf(engine.boost, engine.sc_boost)` so a **supercharger**'s belt boost shows on the
same gauge as a turbo's, see [forced-induction.md](forced-induction.md)) and a code-built `SeedLabel` (the
current world seed, `Config.data.track_seed`, formatted by the pure
`hud.gd::seed_text` — for identifying/reproducing a run), is a **dev diagnostic**: hidden by
default and toggled with **H** (`toggle_debug_arrows`) — the same gate as the debug
force arrows, and like them honoured only in a debug build (release/web ignore the
key). Their text keeps refreshing while hidden, so it's correct the instant H
reveals it. See [debug-tools.md](debug-tools.md).
| `CountdownLabel` | `3` / `2` / `1` / `GO` | driven by `StageManager` (centered, large) |
| `ElapsedLabel` | `m:ss.cc` run timer | driven by `StageManager` (**top-left corner**) |
| Pacenote strip | current turn + upcoming queue (arrow boards) | driven by `StageManager` (top centre, code-built) |
| `StageDeltaLabel` | `n.nn ahead of/behind P1` pace popup | driven by `StageManager` (top-centre, code-built) |
| `StageCompletePanel` | finish panel: `FINISH` + time (+ cut breakdown) + `NEXT` button | driven by `StageManager` |
| `CutFlashLabel` | `CUT +n.ns` live corner-cut flash | driven by `StageManager` (top-right, code-built) |
| `NitrousBar` (+ child `NitrousLabel`) | `NITROUS` caption inside a bar whose fill is the tank fraction left | `car.drivetrain.engine` (violet; hidden when no nitrous is fitted) |
| `BoostBar` (+ child `BoostLabel`) | `BOOST` caption inside a bar whose fill is the live boost fraction | `car.drivetrain.engine` (blue; hidden on an NA car) |
| `HPBar` (+ child `HPLabel`) | `HEALTH` caption inside a bar whose fill is `hp / max_hp` | `car.damage` (colour-graded green→amber→red) |
| `ImpactFlash` | red screen flash on a hit | `car.damage` (sized to the HP lost, fades out) |
| `GripGrid` | 2x2 `FL/FR/RL/RR <n>%` — how far up its grip curve each tire is (100% = on the limit, higher = sliding) | `car.drivetrain.readouts[wheel].grip` (dev diagnostic, H gate, code-built) |

`GripGrid` is code-built and stacked below the seed label, on the same **H** gate as the
readouts above — a **2x2** grid of per-tire grip figures, one cell per corner. See
[debug-tools.md](debug-tools.md) → "Per-tire grip grid"; it is the ONE debug readout
that does **not** refresh while hidden, because its source
(`Drivetrain.readouts`) isn't published while the overlay is down.

## Damage gauge

The `HPBar`/`HPLabel`/`ImpactFlash` are driven by `_update_damage(delta)` (called
from `_process`) off the car's `DamageModel` (see [damage.md](damage.md)): the bar
tracks `hp / max_hp` and is hue-graded from green (full) to red (empty). `HPLabel`
is a **child of the bar**, centred inside it, and is a **static `HEALTH` caption** —
the fill *is* the reading, so it carries no number (an absolute HP figure was
redundant next to a bar showing the same thing). Because the caption is a child, the
grade is applied with **`self_modulate`, not `modulate`** — the latter would drag the
text's colour along with the fill and make it pulse red at low HP. Below
`hud_low_hp_warn_frac` the bar pulses a low-health warning. Any HP drop since the previous
frame bumps the red `ImpactFlash` overlay (sized to the loss), which fades back
out each frame. The gauge is hidden when `hud_hp_enabled` is off; it shows for
every car (the starter is a normal wreckable car like any other).

## Boost gauge

`BoostBar` sits **directly above** the HP bar and is built the same way: a
`ProgressBar` whose fill is the whole reading, with a static `BOOST` caption as a
centred child and the tint applied via `self_modulate`. `_update_boost_gauge(fitted,
live_boost)` (called from `_process`) sets `value` to
`maxf(engine.boost, engine.sc_boost)` — turbo and supercharger share one upgrade
slot, so at most one is ever live and one bar covers both (see
[forced-induction.md](forced-induction.md)). The bar is **hidden entirely** on a
naturally-aspirated car rather than sitting permanently at zero; the pure static
`hud.gd::has_forced_induction(cfg)` is the test (`turbo_enabled` or a non-zero
`supercharger_boost_gain`, so a stock blown engine's audio-only flag doesn't
summon an empty gauge). Its tint is a **fixed blue** at the same saturation/value
as the health bar's grade (`_BOOST_HUE` / `_BOOST_SAT` / `_BOOST_VAL`), so the two
gauges read as one family and only the hue tells them apart — fixed rather than
graded because boost has no "danger" end.

The `H` debug overlay's separate textual `Boost NN%` readout still exists alongside
it (`boost_text`, see [debug-tools.md](debug-tools.md)) for exact numbers.

## Nitrous gauge

`NitrousBar` is the boost bar's twin, stacked **directly above** it (so the bottom-left
stack reads, from the bottom edge up: health, boost, nitrous). Same construction: a
`ProgressBar` whose fill is the whole reading, a static `NITROUS` caption as a centred
child, and the tint applied via `self_modulate` so the caption keeps the plain ink colour.

Both of its answers come from the model, not the HUD: `GameConfig.has_nitrous()` says
whether a tank is fitted and live, and `EngineSim.nitrous_fraction()` reports the 0..1
tank remaining for the stage (see [nitrous.md](nitrous.md)). `hud.gd::_update_nitrous_gauge(fitted, frac)`
hides the bar **entirely** when nothing is fitted rather than parking it at zero, and
otherwise sets `value` to the fraction. `_ready()` starts it hidden.

Its tint is a **fixed violet** (`_NITROUS_HUE`) from the same `_gauge_color` family as the
health grade and the boost blue — deliberately far from the boost hue, because nitrous and
forced induction occupy separate upgrade slots, so a turbocharged car with nitrous shows
**both bars at once** and they must not read as one gauge. Like the other captions,
`NitrousLabel` opts out of the project-wide drop shadow in `_style_gauge_captions()`.

The bar write is **change-gated** on the rounded integer percent (`_last_nitrous_pct`,
`-1` = not fitted), the same pattern the boost bar uses: the drain is a continuous float,
so writing `value` every frame would queue redraws for changes nobody can see.

## Stage flow widgets

The `CountdownLabel`, `ElapsedLabel` and `StageCompletePanel` are hidden at
`_ready()` and driven by the `StageManager` (see [stage.md](stage.md)) through
these methods: `show_countdown(seconds_left)` (big centered `3·2·1·GO`;
`ceili` maps the remaining time to the digit, `0` → `GO`), `hide_countdown()`,
`show_elapsed(seconds)` (top-centre `m:ss.cc`, gated by `hud_elapsed_enabled`),
and `show_stage_complete(seconds, penalty_s)` (the finish panel — `FINISH` +
the time, plus a `+X.Xs cut` / `= total` breakdown line when `penalty_s > 0.0`).
`UITheme.format_time(ms)` is the shared `m:ss.cc` formatter (the seconds-based
call sites convert to ms first).

The **`CutFlashLabel`** is a live corner-cutting flash (see
[corner-cutting.md](corner-cutting.md)): `show_cut_flash(incident_s, total_s)`,
pulsed by `StageManager` every time `TrackProgress` bills a cut incident while
RUNNING. It shows the running event total (`CUT +total_s`), not the incident
delta, so consecutive incidents read as one growing tag rather than flickering
resets — built in code, sharing the **top-centre pace-popup spot** with
`StageDeltaLabel`, and fades the same way the pace popup does. It **takes
precedence** over the pace popup: showing a cut flash hides any live stage-delta
readout, and `show_stage_delta` no-ops while a cut flash is still on screen.
Gated by `cut_penalty_enabled`.

## Pacenote strip

The **rally pacenote strip** runs along the top-centre of the HUD: the **current
turn** (arrow board + grade number, full opacity) with the **upcoming turns queued
to its right**, progressively dimmer. It reads **left-to-right** and **slides left**
as each corner is passed. It's built in code (no scene node) by `set_pacenotes(notes)`
and advanced by `show_pacenotes(current)`.

- **Data source.** `world.gd._setup_pacenotes` builds the note list once per stage
  from the generated track's `pieces` via `Pacenotes.build` (`scripts/pacenotes.gd`) —
  one note per non-`Straight` corner, at the corner-entry arc offset (the same offset
  `SignLayout.plan` plants a board at). Each note is `{corner, flip, offset_m}`. The
  strip covers **every** corner including gentle 5s/6s (unlike the roadside signs,
  which skip them).
- **Art (reused).** Each board is a `TextureRect` of the roadside-sign arrow art
  (`textures/signs/arrow_*.png`, keyed through `GameConfig.sign_textures`). The key
  comes from `Pacenotes.arrow_key(corner, flip)`, which uses the **same** direction
  mapping as `SignLayout._arrow_key` (a left-hand corner, `flip=true`, takes the
  `"right"`-keyed art). The chase camera looks along the track's forward axis, which
  flips the 2D track's left/right on screen — the same inversion the roadside boards
  bake in — so the HUD reads correctly with the signs' convention, not the opposite of
  it. The `arrow_5`/`arrow_6` boards are baked by
  `tools/bake_sign_arrows.gd` (see [signs.md](signs.md)).
  `hud.gd::_pace_texture` looks lazy (`load()` on a cache miss), but it is **not** a
  mid-drive cost: `set_pacenotes` — called from `world.gd::_setup_pacenotes` during track
  generation, behind the loading screen — resolves a texture for *every* note in the
  list, so all distinct arrow textures are already loaded and cached before the drive
  starts. Nothing to pre-warm here.
- **Advance.** `world.gd` also hands the per-corner progress **fractions**
  (`Pacenotes.notes_to_fracs`, same start-line span as the pace splits) to
  `StageManager.setup_pacenotes`. Each RUNNING tick `_maybe_advance_pacenotes` counts
  how many corner entries the car's `progress_percent()` has passed and, when that
  count changes, pulses `hud.show_pacenotes(current)`. It needs **no P1 rival** — the
  strip shows on every run, session or dev boot.
- **Motion / look.** `hud.gd._tick_pacenotes` eases an animated `_pace_scroll` toward
  the current index (fps-independent exponential smoothing) so a one-step advance
  reads as a smooth left-slide; `_layout_pacenotes` positions/fades each board from
  its distance to the current slot (`_PACE_*` consts: slot width, upcoming count,
  dim step/floor). Gated by `hud_pacenotes_enabled` — off builds no boards.
  The top-centre pace/cut popups (`StageDeltaLabel` / `CutFlashLabel`) sit directly
  below the strip: their top edge is `_POPUP_TOP = _PACE_TOP + _PACE_ICON + _POPUP_GAP`,
  so bumping the pacenote icon size pushes the popups down with it rather than
  overlapping.

The `StageCompletePanel` holds a `Box` (VBoxContainer) with the label and a
code-built **`NextButton`**. Pressing NEXT emits the HUD's **`finish_next_pressed`**
signal, which `world.gd` connects to `StageManager.proceed_to_results` — that's what
starts the leaderboard/podium flow ([stage.md](stage.md)). The button is
keyboard/gamepad navigable via `MenuNav.attach` (attached in `_ready`, so it's
`FOCUS_ALL` and re-grabs focus whenever the panel is shown — `ui_accept` triggers
it); see [menus.md](menus.md).

The **`StageDeltaLabel`** is the in-run *"vs P1" pace popup*: a fifth method,
`show_stage_delta(delta_ms)`, the `StageManager` pulses **every few turns** with the
player's time delta to the leading rival at that point. It's built in code (not the
scene) by `_build_stage_delta_label()`, anchored top-centre just below the run
timer. The relation is spelled out and colour-coded
— **negative = ahead** (green, shown as `1.34 ahead of P1`), **positive = behind** (red,
shown as `2.10 behind P1`) — matching the design-system palette (`UITheme.GREEN`/`RED`). Gated by
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
(see [menus.md](menus.md)), not the HUD. The `HPBar` health gauge and the
`BoostBar` stacked just above it are anchored to the **bottom centre** of the
viewport (`anchor_top/bottom = 1.0`, `anchor_left/right = 0.5`,
`grow_horizontal = 2`); each one's caption fills its parent bar
(`anchors_preset = 15`, centred both ways), so the pair grows and shrinks as one
unit.

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
