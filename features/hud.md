# HUD

**Source:** `scripts/hud.gd` (extends `CanvasLayer`). Node `HUD` (layer 2) in
`main.tscn`, with `car` wired to the `Car`.

**Tests:** `tests/headless/test_hud.gd`, `tests/headless/test_hud_gauge.gd`,
`tests/headless/test_live_standings.gd`

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

The three readouts below share one widget, `HudGauge` (`scripts/hud_gauge.gd`, a
`Control`): a radial fill clipped to a **square**, drawn as a **ring** with an icon
(`scripts/gauge_icons.gd`) sitting in the hole rather than as a solid pie. It sweeps
clockwise from 12 o'clock like a pie chart, but every point on the sweep is projected
onto the perimeter of a square (`HudGauge._perimeter`), so the fill hugs the box and
turns hard corners instead of describing a circle — keeping it in the same
orthogonal, no-rounded-corners language as the rest of the design system
(see [ui-design-system.md](ui-design-system.md)) while still reading as a dial. The
projection is exact, not tessellated: the perimeter is a straight line between two
square corners, so `_draw_ring` emits one convex quad per corner-to-corner span
(`draw_colored_polygon` only renders convex polygons correctly).

It's a ring, not a solid pie, on purpose: on a solid pie the wedge sweeps *under* the
icon, so the icon's contrast against its background changes continuously with the
value while driving. Putting the icon in the hole means it always sits on the
(constant) track colour and always reads the same. The owner sets `HudGauge.value`
(0..1, clamped on draw) and `HudGauge.fill_color`; both setters change-gate their own
`queue_redraw()`, so writing an unchanged value each frame costs nothing. The gauge
node itself is `mouse_filter = IGNORE` / `focus_mode = FOCUS_NONE` — it's a pure
readout, never a tap target.

The icon glyphs (`GaugeIcons.Kind.HEALTH` / `BOOST` / `NOS`) are authored on a shared
24-unit grid with a 4-unit module — every edge on a module multiple, every negative
gap exactly one module, square corners, one flat fill, no outline — so the three read
as one family: a cross (health, the one glyph with no interior gap, chosen so it
survives being shrunk to gauge size), a dial with the needle cut out as a slot swept
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
**alpha** (`HudGauge.fill_color.a`) rather than on `self_modulate`/`modulate` the way
the old text-captioned bar worked — the icon is drawn separately in ink by
`GaugeIcons`, so it never pulses with the fill. Any HP drop since the previous frame
bumps the red `ImpactFlash` overlay (sized to the loss), which fades back out each
frame. The gauge is hidden when `hud_hp_enabled` is off; it shows for every car (the
starter takes damage like any other — no car can be wrecked, and an empty bar
means a stumbling, rev-capped engine, not a dead run).

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
`GaugeIcons.Kind.BOOST` (the dial).

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
resets — built in code, anchored top-centre just below the pacenote strip
(`_POPUP_TOP`), and fading out after `hud_popup_show_seconds` (a countdown ticked
in `_process`). It **shares that row with the permanent standings readout and takes it
over while it is up**: `show_cut_flash` drops `PositionLabel` / `PositionGapLabel`, and
`show_position` keeps them down while `_cut_flash_left > 0.0`. Deliberate reuse rather
than a second location — a freshly billed penalty is the most urgent thing the HUD has to
say, and it gets said in the spot the player is already reading. Nothing restores the
readout by hand: the flash fades on its own clock and the next `show_position` frame (the
stage drives one every frame) puts it straight back, already carrying the current
position. Gated by `cut_penalty_enabled`.

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
  The standings readout and the cut flash share the row directly
  below the strip: their top edge is `_POPUP_TOP = _PACE_TOP + _PACE_ICON + _POPUP_GAP`,
  so bumping the pacenote icon size pushes both down with it rather than
  overlapping.

The `StageCompletePanel` holds a `Box` (VBoxContainer) with the label and a
code-built **`NextButton`**. Pressing NEXT emits the HUD's **`finish_next_pressed`**
signal, which `world.gd` connects to `StageManager.proceed_to_results` — that's what
starts the leaderboard/podium flow ([stage.md](stage.md)). The button is
keyboard/gamepad navigable via `MenuNav.attach` (attached in `_ready`, so it's
`FOCUS_ALL` and re-grabs focus whenever the panel is shown — `ui_accept` triggers
it); see [menus.md](menus.md).

## Live standings readout

The **`PositionLabel`** / **`PositionGapLabel`** pair is the *permanent* in-run
standings readout: where the player currently sits in the rival field (`P3/12`) and
the gap that matters underneath it (`1.42 behind P2`, or `1.42 ahead of P2` in green while
leading). It **replaced** the old every-few-turns *"vs P1" pace popup*
(`StageDeltaLabel` / `show_stage_delta`), and the swap was the point: a delta that
flashed up for three seconds every fifth turn told you nothing between pulses, and
"how far off P1" is not the question a driver mid-stage is actually asking — the
question is *what place am I in, and what do I have to find to gain one*. So the
readout is always on and always current instead of being a pulse you might miss.

Both labels are built in code by `_build_position_readout()` and centred on the
**top-centre popup row, directly under the pacenote strip**: `_POS_TOP` is the position
line's resting row (`= _POPUP_TOP`, so it follows the strip's size rather than a hand-copied
number), `_POS_HEIGHT` / `_GAP_HEIGHT` are its two row heights, and the gap line is seated
directly below the position line. Centre screen is deliberate — this is the readout the
player checks most often mid-stage, so it belongs in the eye-line with the pacenotes rather
than parked in a corner. It shares that row with `CutFlashLabel`, which borrows it for a
moment whenever a cut is billed (above).

**The projection is a gap-carry, not an extrapolation.** The maths lives in
`scripts/live_standings.gd` (`LiveStandings`, pure static, no nodes and no `Config`
reads — see [stage.md](stage.md) for how `StageManager` feeds it):

- `time_frac_at(frac, turn_progress, turn_time_frac)` reads the leader's fraction of
  stage *time* completed at the player's track progress off the same per-turn pace
  table the old popup used, linearly interpolated between turn boundaries. It returns
  `-1.0` when there is no usable table, because "no projection" is a real state (a
  plain dev boot has no rival field at all), not an error.
- `project_total_ms(...)` turns that into the player's projected finishing time as
  **the leader's total plus the player's live delta to the leader at this instant** —
  i.e. "if the rest of the stage goes like the leader's did". The obvious alternative,
  extrapolating the player's own average pace (`elapsed / frac`), was rejected: it
  reads wildly optimistic or pessimistic off a single slow opening sector and swings on
  every corner, which makes the position number flicker between places for no reason
  the player can see. The gap-carry only moves when the player actually gains or loses
  time, which is exactly when the readout *should* move.
- `standing(projected_ms, rival_times_ms)` slots that projection into the field and
  returns `{position, field, gap_ms, leading}` — a 1-based place counting the player,
  the classified field size including the player, an always-positive gap (the time to
  find on the car ahead, or the cushion back to P2 when leading), and which of those
  two the gap is. A tie goes to the player, which is why a run reads `P1` off the
  start line: at zero progress the projection *is* the leader's time.

`Hud.position_text(position, field)` and `Hud.gap_text(gap_ms, leading, position)` are
the **pure static formatters**, split out so the strings are testable without the HUD
scene. The gap is **worded rather than signed** (`behind` / `ahead of`) — a bare `±` in
the middle of the screen at speed reads as ambiguous, and this line has to answer "which
way" instantly. Leading colours it `UITheme.GREEN`, otherwise `INK_DIM`.

**The gap number is eased, not written raw.** The projection behind it moves every frame
and jitters with the player's own speed, so the raw figure chatters in the hundredths and
reads as noise rather than information. `show_position` only sets `_gap_target_ms`;
`_tick_gap_smoothing(delta)` chases it with `_gap_shown_ms` on the same
`1 - exp(-delta * _GAP_SMOOTH_SPEED)` curve the pacenote strip slides on (fps-independent,
and a little slower than the strip — this is a number being read, so it wants to settle),
and `_write_gap_text()` is the only thing that writes the line, change-gated on the
displayed centisecond. Three cases **snap** instead of easing, because in each the gap is
suddenly measured against a *different car* and gliding across the old value would quote
seconds that were true of neither: the first update after the readout appears (a stage
opening with the number counting up from zero would be a lie, not a smoothing), a position
change, and the leading flag turning over. `_gap_leading` is latched *before* any write for
that reason — writing first would spell the opening frame of a lead as a deficit. The tick
runs whether or not the labels are visible, so a readout hidden behind a cut flash comes
back current instead of gliding up from a stale figure, and it bails out once the number
has arrived so the settled frame does no work at all.

`show_position(position, field, gap_ms, leading)` drives the pair and is gated by
`hud_position_enabled`. Because `StageManager` polls it **every RUNNING frame** while
the underlying projection moves continuously, both label writes are **change-gated on
the displayed value** — position, field, and the gap rounded to the shown centisecond —
so the common frame builds no strings at all. `moved` is in the gap line's gate too:
that line *names* the position above (`behind P4`), so it must be rebuilt when the position
turns over even if the seconds round the same. A frame driven while a cut flash owns the row
updates that state as usual but leaves the labels hidden, so a place lost behind the flash is
caught rather than missed — and isn't replayed as a fresh overtake when the row comes back. A field of one classified car hides the
gap line outright — a gap to nobody. `hide_position()` takes the readout down at the
finish or on a re-arm and forgets the shown values, so the next stage's first position
is an appearance rather than an overtake.

A position **change** plays a subtle animation, ticked by `_tick_position_anim`: a
gained place slides the position label up into its resting row and flashes
`UITheme.GREEN`, a lost place slides down and flashes `UITheme.RED`, both easing back
to `INK` over `_POS_ANIM_SECONDS` from a `_POS_SLIDE` offset. It is eased (`u * u`) so
most of the travel and nearly all of the colour happen in the first instants — that's
what makes it read as a flick rather than a drift — and it costs nothing once the timer
lapses. The animation only fires once a position has already been shown, since the
first frame of a stage is the readout appearing, not an overtake.

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
permanent standings readout (`PositionLabel` + `PositionGapLabel`) and the
`CutFlashLabel` popup stacked below it on the same centred column, under the pacenote
strip from `_POS_TOP` / `_POPUP_TOP` — the readout and the flash take turns on that one
row rather than occupying two places. The **top-right corner is left
clear for the Pause button**, which lives on the separate `PauseMenu` CanvasLayer
(see [menus.md](menus.md)), not the HUD. The three gauges are anchored to the
**bottom centre** of the viewport (`anchor_top/bottom = 1.0`, `anchor_left/right =
0.5`, `grow_horizontal = 2`) as a row rather than the old vertical stack: `HPGauge`
sits in the **centre** at 48x48, with `BoostGauge` to its **left** and
`NitrousGauge` to its **right**, both 38x38. Health-in-the-middle is deliberate —
either flanker is hidden outright when its part isn't fitted, and hiding a flanker
leaves health exactly where the eye expects it, rather than shuffling the row.

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
`hud_position_enabled`, `hud_popup_show_seconds`.
See [configuration.md](configuration.md) and [damage.md](damage.md).
