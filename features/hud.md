# HUD

**Source:** `scripts/hud.gd` (extends `CanvasLayer`). Node `HUD` (layer 2) in
`level_view.tscn` and the dev stage `main.tscn`, with `car` wired to the `Car`.

**Tests:** `tests/headless/test_hud.gd`,
`tests/headless/test_hud_docs.gd` (a mechanical guard: parses `HUD.DEBUG_READOUT_NODES`
straight from `scripts/hud.gd` and fails if this doc — or `features/debug-tools.md` —
claims a documented label is/isn't H-gated in a way that disagrees with it)

On-screen readout plus two interactive mode buttons.

## Pause behaviour

The HUD is `PROCESS_MODE_ALWAYS` and, while `get_tree().paused`, sets every direct Control
child's `modulate.a` to 0 (restored on resume) and skips its refresh. Alpha rather than `visible`
so `hud_enabled`, world.gd's photo-mode chrome and the gauges' fitted logic keep owning `visible`.

## Elements

| Node | Shows | Source |
|------|-------|--------|
| `SpeedLabel` | `"<n> km/h"` | `car.linear_velocity.length() * 3.6` |
| `GearLabel` | `R` / `N` / `1`–`5` | `engine.gear` via `_gear_text()` |
| `RPMLabel` | `"<n> rpm"` | `engine.rpm()` |

Beyond the table there is a code-built `BoostLabel`
(boost as a percentage of full boost, or `Boost N/A` on a naturally-aspirated engine —
formatted by the pure `hud.gd::boost_text`; it reads
`maxf(engine.boost, engine.sc_boost)` so a **supercharger**'s belt boost shows on the
same gauge as a turbo's, see [forced-induction.md](forced-induction.md)) and a code-built `SeedLabel` (the
current world seed, `Config.data.track_seed`, formatted by the pure
`hud.gd::seed_text` — for identifying/reproducing a run).

**Visibility is per-label data, not a fixed set.** Every label named in `hud.gd` →
`DEBUG_READOUT_NODES` is a **dev diagnostic**: hidden by default and toggled with **H**
(`toggle_debug_arrows`) — the same gate as the debug force arrows, and like them honoured
only in a debug build (release/web ignore the key). Every label NOT named there is always
visible. Gated labels keep refreshing while hidden, so they're correct the instant H
reveals them. See [debug-tools.md](debug-tools.md).

**Membership is data, in one place.** `hud.gd` → `DEBUG_READOUT_NODES` is the single
source of truth for which elements the H key gates. **Read the current membership
from that constant — this doc deliberately does not list it**, because a second copy
of a list is a second thing to rot, and it did: this section named `GearLabel` as a
member for a full round after it stopped being one. `tests/headless/test_hud.gd`
binds to the same constant (it iterates it rather than naming labels) and adds a
per-element contract named after each element, so **moving an element in or out of
the overlay is a one-line edit to `DEBUG_READOUT_NODES`** and the per-element test
that names it will report the change. Update this section's prose and
`features/debug-tools.md` in the same change.

`GripGrid` is code-built and stacked below the seed label, on the same **H** gate as the
readouts above — a **2x2** grid of per-tire grip figures, one cell per corner. See
[debug-tools.md](debug-tools.md) → "Per-tire grip grid"; it is the ONE debug readout
that does **not** refresh while hidden, because its source
(`Drivetrain.readouts`) isn't published while the overlay is down.

## Gauge cluster (`HudDial`)

Every player-facing gauge lives on one rev-counter dial, `HudDial` (`scripts/hud_dial.gd`, a
`Control`), built in code by `hud.gd → _build_dial` as the `Dial` node and placed each frame
in the **bottom-right** corner (`HudDial.home_rect`). When touch controls are showing it lifts
clear of them together with the level view's minimap, as one band, so the two always stay
level (`MobileControls.bottom_band_lift`). It is a pure readout
(`mouse_filter = IGNORE`, `focus_mode = NONE`). `hud.gd` writes plain fields on it each
frame and calls `queue_redraw()`; a **negative** reading means "not shown".

| Reading | Drawn as | Source in `hud.gd` |
|---------|----------|--------------------|
| `rpm`, `scale_rpm`, `redline_rpm` | 270° scale, needle, red zone | `engine.rpm()`; `HudDial.scale_for(cfg.redline_rpm)` (next whole thousand ≥ 1000 rpm past the redline); `engine.redline_omega()`, so a damage-capped engine's red zone creeps down |
| `gear_text` | big digit in the centre | `_gear_text(engine.gear)` |
| `hp`, `hp_color` | the segmented **rim**; segments go dark as HP drops | `_update_damage`: `hp / max_hp`, hue-graded green → red via `_gauge_color`, alpha-pulsed below `hud_low_hp_warn_frac`. `-1` when `hud_hp_enabled` is off |
| `temp`, `overheating` | the **face** glows red from the rim inward above half temperature; "x1000" becomes a blinking **HOT** while overheating | `_update_temp`: `DamageModel.temp_fraction` / `is_overheating`. `-1` when the damage model has no `thermal` |
| `boost` | arc in the empty bottom quarter, labelled BOOST | `maxf` of turbo/blower via `engine.boost_reading()`; `-1` unless `GameConfig.has_forced_induction()` |
| `nitrous`, `nitrous_on` | ring of 10 violet pips round the gear; lit pips grow while firing | `engine.nitrous_fraction()`, `engine.nitrous_delivering`; `-1` unless `GameConfig.has_nitrous()` |

Boost and nitrous colours are fixed hues from the same `_gauge_color` family as the health
grade (`_BOOST_HUE`, `_NITROUS_HUE`), kept far apart because both can show at once. All text
is Jersey 10 at 18 / 54 px on whole pixels with the house hard shadow.

The code-built `CoolingLabel` (a child of the dial) sits right-aligned just above it and reads
"RADIATOR DAMAGED" once the cooling breaks, or "OVERHEATING — REACH A CHECKPOINT" past the
threshold.

The `H` debug overlay's separate textual `Boost NN%` readout still exists alongside the dial
(`boost_text`, see [debug-tools.md](debug-tools.md)) for exact numbers.

## Impact flash

Any HP drop since the previous frame bumps the red `ImpactFlash` overlay (sized to the loss),
which fades back out each frame (`_update_damage`).

## Money counter (free roam only)

Not part of `hud.gd`: `LootDirector.money_label` draws "$n" (`WorldSession.money`) in the top-left
corner on a black box (so it reads against a bright sky), added to the HUD layer (so the pause fade above hides it too) ([loot.md](loot.md)).

## Behavior

- `_ready()` — sets visibility from `cfg.hud_enabled`.
- `_process(delta)` — refreshes labels each frame.
- `_gear_text(gear)` — formats -1→`R`, 0→`N`, else the number.

## Layout

Labels are direct children of the `HUD` CanvasLayer, positioned via
`offset_*` with explicit `font_size` overrides. All sizes are deliberately
small (font 14 for labels) — the HUD is rendered at 1/2 scale.

The **top-right corner is left
clear for the Pause button**, which lives on the separate `PauseMenu` CanvasLayer
(see [menus.md](menus.md)), not the HUD. The gauge cluster dial sits in the
**bottom-right** corner (see above). On touch screens it shares that corner with the
gas pedal of [mobile-controls.md](mobile-controls.md).

## Build version

The build version is shown on the **title screen only** (`title_screen.gd`, via
`UpdateCheck.display_version`) — not on the in-run HUD. It is derived automatically as `0.<git commit count>` with the
short SHA appended (e.g. `v0.61 (b154d5c)`). `build_web.sh` computes this from git
and stamps it into `application/config/version` in `project.godot` for the
duration of the export (reverting the file afterwards), so it is baked into the
web `.pck`. Editor and test runs fall back to the committed default
`config/version="0.0-dev"`.

## Related config

`hud_enabled`, `hud_hp_enabled`, `hud_low_hp_warn_frac`.
See [configuration.md](configuration.md) and [damage.md](damage.md).
