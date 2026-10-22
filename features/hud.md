# HUD

**Source:** `scripts/hud.gd` (extends `CanvasLayer`). Node `HUD` (layer 2) in
`free_roam.tscn` and the dev stage `main.tscn`, with `car` wired to the `Car`.

**Tests:** `tests/headless/test_hud.gd`, `tests/headless/test_hud_gauge.gd`,
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

## Gauge widget (`HudGauge` / `GaugeIcons`)

The gauges below share one widget, `HudGauge` (`scripts/hud_gauge.gd`, a `Control`): a
**vertical strip** on a black column. The bar fills from the bottom in `fill_color`, the
gauge's name (`HudGauge.NAMES` — HEALTH / BOOST / NITROUS / TEMP) runs bottom-to-top up
the bar in faint ink, an ink **needle** rides over the bar and the name at the current
level (`HudGauge.level_y`), quarter ticks sit to its right and the icon
(`scripts/gauge_icons.gd`) sits underneath. Warnings pulse the fill's alpha only, so the
needle, name and icon stay readable. The owner sets `HudGauge.value` (0..1, clamped on
draw) and `HudGauge.fill_color`; both setters change-gate their own `queue_redraw()`, so
writing an unchanged value each frame costs nothing. The name is drawn at
`UITheme.FONT_SIZE` (Jersey 10 blurs off 18 px and its multiples), so the strips are
sized tall enough for NITROUS at that size, and all strip geometry is in whole pixels.
The gauge node itself is
`mouse_filter = IGNORE` / `focus_mode = FOCUS_NONE` — it's a pure readout, never a tap
target.

The icon glyphs (`GaugeIcons.Kind.HEALTH` / `BOOST` / `NOS`) are authored on a shared
24-unit grid with a 4-unit module — every edge on a module multiple, every negative
gap exactly one module, square corners, one flat fill, no outline — so the three read
as one family: a heart (health — the standard health glyph: two round lobes and a point,
one solid silhouette with no interior gap, so it survives being shrunk to gauge size), a dial with the needle cut out as a slot swept
to the upper right (boost — the one round glyph, because every pressure instrument in
a real car is), and a pressure bottle (NOS, left as one unbroken silhouette). Two are
concave and the dial is a disc with a slot cut out of it, so `draw_colored_polygon`
can't take them directly; `GaugeIcons.triangles(kind)` triangulates each glyph once
via `Geometry2D.triangulate_polygon`/`clip_polygons` and caches the result in
`GaugeIcons._cache`, and `GaugeIcons.draw_into` just scales and blits the cached
triangles. Adding a fourth gauge means authoring its glyph to the same grid.

## Damage gauge

`HPGauge` is driven by `_update_damage(delta)` (called from `_process`) off the
car's `DamageModel` (see [damage.md](damage.md)): `value` tracks `hp / max_hp` and
`fill_color` is hue-graded from green (full) to red (empty) via `_gauge_color`.
Below `hud_low_hp_warn_frac` the low-health warning pulse rides on the fill's
**alpha** (`HudGauge.fill_color.a`) rather than on `modulate`, so the needle, name and
icon never pulse with the fill. Any HP drop since the previous frame
bumps the red `ImpactFlash` overlay (sized to the loss), which fades back out each
frame. The gauge is hidden when `hud_hp_enabled` is off; it shows for every car (the
starter takes damage like any other — no car can be wrecked, and an empty bar
means a stumbling, rev-capped engine, not a dead run).

## Temperature gauge (free roam only)

`TempGauge` is an optional `HudGauge` with the thermometer icon (`GaugeIcons.Kind.TEMP`). Only
`free_roam.tscn` has one, last in the row. Its fill is `DamageModel.temp_fraction`:
the temperature in °C over the overheat threshold, so empty at 0 °C and full at the threshold. It runs blue to red and pulses while
the engine overheats. A code-built `CoolingLabel` above the gauge row reads "RADIATOR DAMAGED" once
the cooling breaks, and "OVERHEATING — REACH A REST STOP" past the threshold. The stage scene
has no `TempGauge`, so none of this runs there (`hud.gd → _update_temp`).

## Boost gauge

`BoostGauge` is built the same way: `_update_boost_gauge(fitted, live_boost)`
(called from `_process`) sets `value` to `maxf(engine.boost, engine.sc_boost)` —
turbo and supercharger share one upgrade slot, so at most one is ever live and one
gauge covers both (see [forced-induction.md](forced-induction.md)). It's **hidden
entirely** on a naturally-aspirated car rather than sitting permanently at zero; the
pure static `hud.gd::has_forced_induction(cfg)` is the test (`turbo_enabled` or a
non-zero `supercharger_boost_gain`, so a stock blown engine's audio-only flag doesn't
summon an empty gauge). Its `fill_color` is a **fixed blue** at the same
saturation/value as the health gauge's grade (`_BOOST_HUE` / `_BOOST_SAT` /
`_BOOST_VAL`), so the two gauges read as one family and only the hue tells them
apart — fixed rather than graded because boost has no "danger" end. Its icon is
`GaugeIcons.Kind.BOOST` (the dial glyph).

The `H` debug overlay's separate textual `Boost NN%` readout still exists alongside
it (`boost_text`, see [debug-tools.md](debug-tools.md)) for exact numbers.

## Nitrous gauge

`NitrousGauge` is the boost gauge's twin, using `GaugeIcons.Kind.NOS` (the pressure
bottle) as its icon. Both of its answers come from the model, not the HUD:
`GameConfig.has_nitrous()` says whether a tank is fitted and live, and
`EngineSim.nitrous_fraction()` reports the 0..1 tank remaining for the stage (see
[nitrous.md](nitrous.md)). `hud.gd::_update_nitrous_gauge(fitted, frac)` hides the
gauge **entirely** when nothing is fitted rather than parking it at zero, and
otherwise sets `value` to the fraction. `_ready()` starts it hidden.

Its `fill_color` is a **fixed violet** (`_NITROUS_HUE`) from the same
`_gauge_color` family as the health grade and the boost blue — deliberately far
from the boost hue, because nitrous and forced induction occupy separate upgrade
slots, so a turbocharged car with nitrous shows **both gauges at once** and they
must not read as one.

The gauge write is **change-gated** on the rounded integer percent
(`_last_nitrous_pct`, `-1` = not fitted), the same pattern the boost gauge uses: the
drain is a continuous float, so writing `value` every frame would queue redraws for
changes nobody can see.

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
resets — built in code, anchored top-centre at `_POPUP_TOP`, and fading out after
`hud_popup_show_seconds` (a countdown ticked in `_process`). Gated by
`cut_penalty_enabled`. (`_POPUP_TOP` is still derived from the deleted pacenote strip's
`_PACE_TOP` + `_PACE_ICON` constants in `hud.gd`.)

## Off-track warning

The **`OffRoadLabel`** mirrors `TrackProgress`'s off-road clock (see
[progress.md](progress.md)): a red `OFF TRACK  n.n` counting down the seconds left
before the car is snapped back onto the road. Built in code, anchored at the
**viewport centre** and hung `_OFF_ROAD_TOP` below it so it clears the centred
3·2·1·GO countdown and stays out of the eye-line of the road ahead.

Unlike the popups above it is **not a fading pulse** — it mirrors a live state, so it
has no `_tick_fade` timer: `show_off_road(seconds_left)` puts it up and it stays up
until `hide_off_road()`. `StageManager._update_off_road_warning` owns both calls,
polling `TrackProgress.off_road_time()` / `off_road_seconds_left()` each RUNNING
frame and holding the label back until `off_road_warning_after_s` has elapsed.
`show_off_road` change-gates on the displayed **tenth**, so a per-frame call only
re-formats the string ten times a second. `Hud.off_road_text(seconds_left)` is the
pure formatter (clamps a negative countdown to `0.0`).

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
`CutFlashLabel` popup stacked below it on the same centred column, from `_POPUP_TOP`. The **top-right corner is left
clear for the Pause button**, which lives on the separate `PauseMenu` CanvasLayer
(see [menus.md](menus.md)), not the HUD. The gauges are anchored to the
**bottom centre** of the viewport as one row, in the order health, boost, nitrous,
temperature. `hud.gd → _layout_gauges` places the **visible** ones edge to edge, centred,
so their black columns read as one panel and a part that isn't fitted closes up rather
than leaving a hole. It re-lays the row only when the set of visible gauges changes. Each
strip's size comes from its node in the scene (`free_roam.tscn` / `main.tscn`); the scene
offsets are only the starting positions.

## Build version

The build version is shown on the **title screen only** (`title_screen.gd`, via
`UpdateCheck.display_version`) — not on the in-run HUD. It is derived automatically as `0.<git commit count>` with the
short SHA appended (e.g. `v0.61 (b154d5c)`). `build_web.sh` computes this from git
and stamps it into `application/config/version` in `project.godot` for the
duration of the export (reverting the file afterwards), so it is baked into the
web `.pck`. Editor and test runs fall back to the committed default
`config/version="0.0-dev"`.

## Related config

`hud_enabled`, `hud_elapsed_enabled`, `hud_hp_enabled`, `hud_low_hp_warn_frac`,
`hud_popup_show_seconds`.
See [configuration.md](configuration.md) and [damage.md](damage.md).
