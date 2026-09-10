# Car stats — the spec sheet, plain and compared

**Source:** `scripts/car_stats.gd` (`CarStats` — the sheet as data: `ROWS`, `values`,
`preview`, `row`/`label_for`/`format`/`direction`/`change`), `scripts/car_stats_panel.gd`
(`CarStatsPanel` — the plain/comparison 2-column read-out), `scripts/skill_progress_panel.gd`
(`SkillProgressPanel` — the between-stage skill-gate read-out, a sibling widget built the
same way), `scripts/lifetime_stats.gd` (`LifetimeStats.progress_text` — the clamped
`"150/800"` fraction `SkillProgressPanel` shows per locked skill), `scripts/hub_shell.gd`
(`_show_car_stats` — the CAR page's "Show stats" popup), `scripts/world.gd` (the
between-stage `_confirm_pick` → `_show_skill_progress` → `_apply_pick` sequence).

**Tests:** `tests/headless/test_car_stats_sheet.gd` (the `CarStats` module — NOT
`test_car_stats.gd`, which is `CarLibrary`'s own derived-stat coverage; the two files
cover different classes despite the similar name), `tests/headless/test_car_stats_panel.gd`,
`tests/headless/test_skill_progress_panel.gd`, `tests/headless/test_lifetime_stats.gd`
(`progress_text`), `tests/headless/test_hub_shell.gd` (the CAR page's "Show stats" action).

## Why this exists, and why it isn't `StatBar`

`StatBar` (`scripts/stat_bar.gd`, `features/car-performance.md`'s neighbour) draws a
20-block bar scaled against `CarStatBounds` — the whole roster's min/max. It answers "how
does this car compare with every other car in the game", and that roster-relative scale is
exactly wrong for the question this module answers instead: "what are THIS car's numbers,
right now, and what would this pick do to them". A boost that moves grip from 1.02G to
1.05G is a real gain a player should see, but on a roster-wide bar it can vanish inside one
block. `CarStats`/`CarStatsPanel` show absolute before/after figures instead, with no
roster context at all.

## `CarStats.ROWS` — the sheet, as one ordered list

Each row is `{id, label, unit, decimals, direction}`. `direction` — `BETTER` (1), `WORSE`
(-1), or `NEUTRAL` (0) — is the single source of truth for "which way is an improvement",
because that answer is NOT guessable from the number alone: bigger power is good, bigger
mass is bad, and a UI that assumes "bigger = better" gets half the sheet's colours backwards.
`mass` is the one `WORSE` row; `drive` (the drivetrain) is `NEUTRAL` — AWD is not an upgrade
over RWD, just a different car, so it never carries a colour even when it changes.

Order is deliberate, not alphabetical: power and weight lead (what a player actually
chooses between), power-to-weight follows as the figure that combines them, and the
categorical drivetrain sits last since it's the one row with no better/worse sense.

## `values()` reads `grip_meta`, not `effective_meta` — on purpose

Every other "what does this car currently look like" caller in the codebase uses
`UpgradeLibrary.effective_meta`, and it was the obvious first call to reach for here too —
it's wrong for this sheet specifically. `effective_meta` only folds in the effects that
feed power-to-weight (its own header says so); the GRIP-feeding pair —
`tire_compound` and the two `downforce_*` fields, which `CarLibrary.max_lateral_g` reads —
is folded in by `grip_meta`, which is `effective_meta`'s output plus those two fields.
Reading the sheet off `effective_meta` would leave the Grip row flat for exactly the two
boosts a player expects to move it (Sticky Tyres, the Aero kit) while every other row stayed
correct — a silent, plausible-looking wrong answer, and the reason
`test_car_stats_sheet.gd -> test_values_a_grip_feeding_boost_moves_the_grip_row` exists as a
named regression test. `grip_meta` is a strict superset of `effective_meta`, so one call
serves the whole sheet with nothing left out.

The Grip row's own label carries the reference speed it was rated at
(`label_for("grip")`, live off `Config.data.grip_reference_kmh`) — grip grows with v², so a
bare number with no speed attached reads as a promise the car only keeps at one velocity.

## `preview()` deep-duplicates before probing

`preview(owned_car, meta, pick)` answers "what would the sheet look like if `pick` were
taken" — the confirmation popup's "after" column, for a pick not yet committed. The `owned`
dict `Save.get_car` hands back is the LIVE profile reference, so appending a candidate boost
to it directly would fit the boost for real and persist a merely-previewed pick into the
save. `preview` guards this by deep-duplicating (`owned_car.duplicate(true)`) before
appending anything, then reads `values()` off the copy — the same trap and the same fix
`world.gd::_field_car` documents at length for the run's own boost merge. Confirmed by
`test_preview_does_not_mutate_the_passed_in_owned_dict`.

`pick` is either a boost entry (`{"id":…, "effect":…}`, `BoostLibrary.boost_for`'s own
shape) or a drivetrain conversion (`{"drivetrain": <DriveMode int>}`). An empty or
unrecognised pick returns the unmodified sheet, so a caller with nothing to preview renders
a plain single-figure panel rather than an empty one.

## `change()` compares FORMATTED figures, not raw floats

`change(id, before, after)` answers "did this move make the stat better, worse, or neither"
— `+1`/`-1`/`0`, `0` for both a `NEUTRAL` stat and an unchanged one. The comparison runs on
`format(id, before) == format(id, after)`, not the raw numbers: a change too small to survive
rounding is invisible to the player, and colouring an apparently-identical pair red or green
would read as a display bug. This is why Grip carries 2 decimals against every other row's
0 — a small but real grip gain must still clear the rounding bar that decides whether to
show a colour at all.

## `CarStatsPanel` — plain vs. comparison off one builder

`CarStatsPanel.build(before, after := {})` — a 2-column `GridContainer` of `CarStats.ROWS`
order. Empty `after` is PLAIN mode (one figure per row, the car-page popup's use). A non-empty
`after` is COMPARISON mode (`"400 → 500"`, the upgrade confirmation's use) — and the mode is
chosen purely by whether `after` was passed, so there's no separate flag to get out of sync
with the data.

**An unchanged stat collapses to one figure, not `"400 → 400"` in grey.** Most of the sheet
doesn't move on a real upgrade, and a column of identical before/after pairs joined by
arrows would bury the one or two rows that actually changed — which is the entire question
the panel exists to answer. `CarStats.change` owns which side is coloured (this file only
paints what it's told: the better figure green via `UITheme.GREEN`, the worse one red via
`UITheme.RED`); a `NEUTRAL` stat that genuinely moved (a drivetrain conversion) still draws
both sides, just uncoloured. A stat absent from `before` draws no row at all — a synthetic
fixture car with a partial sheet is not "this car has 0 grip".

Not a scene, not a page: `build` returns a plain `Control` the caller mounts into a popup or
`MenuPage` body — that's what lets both `HubShell._show_car_stats` and `world.gd`'s
between-stage confirm share the same widget, and what keeps this file's tests free of a
world scene.

## `SkillProgressPanel` — the sheet's sibling, for skill gates

`SkillProgressPanel.build(profile)` is a separate widget with the same shape (2-column
`GridContainer`, one `Control` returned for the caller to mount) answering a different
question: "how much closer did that stage just get me to my NEXT skill". One row per
`SkillLibrary.all()` entry — locked shows `LifetimeStats.progress_text(current, threshold)`
against the gating stat's name (`"Damage taken: 150/800"`), gate-met-but-unbought shows
"Unlocked — buy in the shop" (green), owned shows "Owned" (green). See
[skills.md](skills.md) for the gate mechanics `is_unlocked`/`unlock_of` this reads.

`LifetimeStats.progress_text(current, threshold)` CLAMPS `current` into `[0, threshold]` for
display only — a lifetime counter keeps growing after its gate is met, and `"1240/800"`
reads as a broken progress bar. The gate itself is still decided by `SkillLibrary.is_unlocked`
off the real, unclamped value; only the printed fraction is capped.

## Where this shows up

- **`HubShell`'s CAR page** — "Show stats" is a page action (`_action`, beside Back), not a
  per-card icon: a card's own confirm already means "start a run" / "buy this", and
  `CardCarousel` gives a card one confirm, not two, so a second per-card affordance would
  either need a pointer (breaking CLAUDE.md's keyboard+gamepad rule) or steal the confirm
  that buys the car. As an action it reads the carousel's live selection and sits in the
  same focusable row as Back, so it works identically on a pad. Plain mode only (no "after"
  — there's no pick to compare against on this page). An unowned catalogue car passes an
  EMPTY owned dict, so the sheet reads the showroom car with no upgrades/tuning/engine-swap
  resolved onto it — exactly what a car you haven't bought is.
- **`world.gd`'s between-stage sequence** — see [region-runs.md](region-runs.md) → *Between-
  stage pick* for the pick mechanics; this doc covers only the two screens the pick now
  routes through before applying: `_confirm_pick` (`CarStatsPanel` comparison, before → after,
  Apply/Cancel) then `_show_skill_progress` (`SkillProgressPanel`, Continue). Not tested at
  this layer — instantiating `main.tscn` costs ~15s per test (`features/testing.md`'s cost
  model) for what is a thin relay calling two already-tested panel builders in sequence;
  compile-time checking is what covers `world.gd` itself.
