# Car performance rating (the benchmark lap)

**Sources:** `scripts/car_performance.gd` (`CarPerformance` — `rating`,
`benchmark_ms`, `merged_meta`, `reset`, `REFERENCE_CAR`, `RATING_SCALE`,
`BENCHMARK_SURFACE_GRIP`), `scripts/benchmark_track.gd` (`BenchmarkTrack` —
`build`, `build_from`, `ARC_STEPS_PER_QUARTER`), `scripts/lap_time_model.gd`
(`optimum_profile`'s `mu_override`, `_load_factor`, `_geared_top_speed_sq`,
`_grip_long`, `_traction_factor`, `V_CAP_MAX_MS`), `scripts/game_config.gd` (the `benchmark_*`,
`traction_factor_*` and `tire_load_*` exports), `tests/headless/test_car_performance.gd`,
`tests/headless/test_lap_time_model.gd`.

> **No screen shows the rating today.** Its consumers (the rival field, the challenge ceiling,
> the upgrades grid's `PERFORMANCE` readout) are deleted; the model below is intact.

**Tests:** `tests/headless/test_car_performance.gd`, `tests/headless/test_lap_time_model.gd`

## What the rating is

One number saying how fast a given build is — higher is faster, the way Forza's
PI works. `CarPerformance.rating(meta)` is **not a weighted formula over stats**:
the car is simulated around a fixed test track (`BenchmarkTrack`) with
`LapTimeModel`, and the rating is derived from the resulting **total lap time**.

```
rating = round(RATING_SCALE * (reference_ms / benchmark_ms) ^ rating_spread)
```

Reciprocal time, so the number is proportional to *average speed*. Raw time
compresses badly at the fast end — half a second between two quick cars means far
more than between two slow ones — and the reciprocal spreads the roster evenly.
`CarPerformance.benchmark_ms(meta)` exposes the raw time for tooling and
calibration.

### `rating_spread` — widening the field

Lap time is a **compressive** measure of a car. A hypercar is many times the machine a kei
van is, but only about 1.5× faster round a lap, so the physically honest ratings bunch: the
shipped roster spanned just 342–526, with the six quickest cars inside 55 points of each
other. The roster read flatter than it drives.

`GameConfig.rating_spread` is an exponent on the speed ratio, stretching the field about
the `RATING_SCALE` anchor. `1.0` is the raw proportional number and `pow()` is skipped
entirely. The shipped value is **3.0**, which takes the roster to roughly 161–583.

An **exponent**, not a linear `500 + (raw - 500) * gain`: it is multiplicative, so it can
never drive a slow car to zero or negative (a linear gain of 3 puts the slowest shipped car
at 26), and "twice the ratio" means the same thing everywhere on the scale. The reference
car rates exactly `RATING_SCALE` at every setting — the stretch has one fixed point, so it
widens the field rather than sliding it.

**What it cannot do:** differences are amplified *proportionally*, so two cars the
benchmark finds within 1% of each other stay within `spread`% of each other. It widens the
whole field, mostly by pulling the slow cars down; it does not pull the fast cars apart.
Separating cars that are genuinely near-identical on the benchmark is a **geometry**
question — `benchmark_straight_m` and friends, above — not a scaling one.

It is folded into `_config_key`, so retuning it invalidates every memoised rating: it
changes the number without changing the lap, and a cache keyed only on the benchmark
geometry would serve stale figures for the rest of the session.

**Knock-on:** any rating-space value (a future ceiling or matching window) is measured
against this wider field, so revisit it alongside a change here.

Because the score comes out of the solver, it can never drift out of agreement
with a hand-written weighting: whatever `LapTimeModel` models, the rating
accounts for. Whatever it doesn't model is invisible to the rating — see
[What it measures](#what-it-measures-and-what-it-does-not), which is the section
to read before you assume anything about this number.

## The benchmark track

`BenchmarkTrack.build()` reads the `GameConfig` knobs;
`BenchmarkTrack.build_from(straight_m, hairpin_radius_m, sweeper_radius_m,
sweeper_count)` is the explicit form, so calibration tooling can sweep the knobs
without writing to the live config. Both return the
`{"centerline": Curve2D, "pieces": []}` dict `LapTimeModel` consumes.

Layout, in order:

1. **A straight** — acceleration and top speed. Since the geared top-speed cap
   landed this section genuinely measures top speed rather than just
   acceleration: a short-geared car now runs out of gears on it.
2. **A hairpin** (a PI arc) — low-speed cornering and corner exit.
3. **N sweepers** (PI/2 arcs) — high-speed cornering, where downforce shows up.

**Sections are not timed individually.** There is one score: the total time.
Their only job is to make a single lap exercise all three regimes, which is what
turns the lengths and radii into balance levers.

### Why this isn't `TrackFixtures`

`tests/headless/track_fixtures.gd` already has `straight`, `arc`, `handled_arc`,
`straight_then_arc` — but each returns an **independently originated** curve, so
chaining them butts two curves together at an arbitrary angle.
`LapTimeModel._curvature_profile` measures heading change per sample, so a kink
reads as an **enormous κ**, and the nonlinear `mu_g / κ` cornering cap turns that
into an arbitrary hard slowdown that would dominate the benchmark.

`BenchmarkTrack` therefore joins every segment with continuous **position and
tangent**: `_push` merges a coincident point so a junction is *one* curve point
carrying both the incoming and the outgoing handle, never two stacked points, and
`_add_arc` starts from the running position/tangent so the join is smooth by
construction. Segments carry real Bézier handles the way `TrackGenerator` builds
real track. `ARC_STEPS_PER_QUARTER` (8, ~11° a segment) is set by how flat κ needs
to be, not by how close the path is: the `(4/3)·tan(dθ/4)·r` handle approximation
ripples in *curvature* between points even where position error is negligible.
`test_benchmark_track_has_no_curvature_spikes_at_joins` guards this.

It lives in `scripts/`, not in a test fixture, because shipped code cannot depend
on test code.

**Handedness is cosmetic.** `_curvature_profile` takes `absf(...)`, so a right
hairpin and a left sweeper are indistinguishable to the solver. The `_LEFT` /
`_RIGHT` signs exist for readability and **nothing asserts on them**. If
handedness ever needs to matter (an asymmetric car), that is a change to the
curvature profile, not to this file.

## Tuning knobs

All in `config/game_config.tres` (see `scripts/game_config.gd` for the authored
defaults and ranges). **Changing any of them re-scores every car** — safe,
because nothing is persisted and the scale is anchored (below), but read this
file first.

| Knob | What it rebalances |
|---|---|
| `benchmark_straight_m` | **The primary lever.** Power against cornering. Shorten it if the rating is found to favour straight-line speed. |
| `benchmark_sweeper_radius_m` | Low-speed grip against high-speed aero — downforce only asserts itself above a certain speed, so a wider, faster sweeper weights aero more. |
| `benchmark_hairpin_radius_m` | Low-speed cornering weight. Configurable, but not expected to be a primary lever. |
| `benchmark_sweeper_count` | How much of the lap is high-speed cornering at all. |

`test_the_straight_knob_shifts_the_power_corner_balance` pins the straight
lever's *direction* (a longer straight widens the power car's lead over the grip
car) and never its value.

## Scale anchoring, and frozen conditions

Two separate mechanisms stop the number drifting under the roster.

**Normalisation against a reference car.** `REFERENCE_CAR` is a **synthetic**
spec — deliberately not a catalogue entry, so retuning or deleting a shipped car
cannot shift the scale under every other car. Ratings are expressed relative to
its benchmark time, so the reference car rates exactly `RATING_SCALE` by
construction (`test_the_reference_car_anchors_the_scale`), and moving the
geometry knobs moves the anchor with it
(`test_the_scale_survives_a_geometry_change`). This is what would let an authored
rating value — e.g. a future Rally Challenge ceiling — keep its meaning across a
knob change. `RATING_SCALE` is presentation only: it sets the range the roster
lands in, not the ordering.

**Frozen benchmark conditions.** `LapTimeModel._surface_grip` normally reads
`gravel_grip`, `tarmac_grip` and the weather table out of `Config.data`, so an
ordinary grip or weather retune would silently re-score the whole roster. The
rating must be a property of the *car*, so the conditions are nailed down as the
`BENCHMARK_SURFACE_GRIP` constant and pushed through `optimum_profile`'s
**`mu_override`** seam, which replaces the surface/weather lookup entirely when
`>= 0`. The car's own `tire_compound` is *not* bypassed — `_simulate` folds it
into the override, because it is a property of the car, not the conditions.
`mu_override < 0` (the default) is an exact no-op for every other caller.
`test_the_scale_survives_a_surface_grip_retune` guards it.

**The same reasoning now carries a second term through the bypass: tire load
sensitivity.** `optimum_profile` multiplies `mu` by `LapTimeModel._load_factor`
**after** `mu` has been resolved, on **both** branches — the `_surface_grip` path
and the `mu_override` path. That placement is load-bearing, not stylistic:
`_simulate` always passes `mu_override`, so a load term living inside
`_surface_grip` would have been invisible to the rating, which is precisely the
one place it most needed to be seen. Like `tire_compound`, it is a property of
the *car* (its mass and its tyre widths), not of the conditions, so the frozen
conditions must not freeze it out.

## What it measures, and what it does NOT

**It measures:** power (`peak_torque` / `redline` via
`CarLibrary.power_to_weight`), mass, drag, tyre grip (`tire_compound`), tyre
**width** (`wheel_width_front` / `wheel_width_rear`, through load sensitivity —
see below), downforce (`downforce_front` + `downforce_rear`), drive mode, and the
car's **geared top speed** (`LapTimeModel._geared_top_speed_sq` — see
[The geared top-speed cap](#the-geared-top-speed-cap) below).

### Mass is no longer only power-to-weight

Worth stating explicitly, because this file used to say the opposite. Before the
load-sensitivity term, mass reached the solver in exactly ONE place: `a_engine =
P/(v·m)`. Cornering (`mu·g/κ`), braking and corner-exit traction were all exactly
mass-invariant. Two bad consequences followed. Fitting weight reduction barely
moved a car's rating, while being transformative to drive — the number and the
car disagreed about the single most-felt modification in the game. And the only
channel by which shedding mass bought *cornering* speed at all was the aero term
(`aero_a = μ·D/m`), so the model rewarded a diet only on cars that already had
downforce, and gave nothing at all to the light, aero-free classics where a diet
matters most.

The live physics has always modelled this (`Drivetrain.step` →
`GameConfig.tire_load_factor`, `tire_load_sensitivity`): a less-loaded tyre has a
higher coefficient, and a wider tyre spreads the same load over more rubber. So
`LapTimeModel._load_factor(car_meta, mass)` calls **the same
`GameConfig.tire_load_factor`** the wheels do, with a point-mass simplification —
normal force is `mass·G/4` (four equally-loaded corners) and width is the mean of
`wheel_width_front` / `wheel_width_rear`. That is deliberately coarser than
`Drivetrain.step`, which resolves the factor per wheel per tick against the live
suspension normal force and therefore picks up weight transfer; the point mass
has no axles to transfer between. Coarse but the *same curve* is the point: the
rating now moves in the direction the car does, which matters well beyond the
number on the upgrades page, because the AI field is paced off this same solve
([region-stage-library.md](region-stage-library.md)).

**It does not measure — at all:**

- **Braking.** There is no per-car brake data in this game: `brake_torque` is a
  single global in `GameConfig`, cars author only `brake_bias`, and no upgrade
  touches brakes. `brake_bias` alone cannot move a point-mass deceleration
  ceiling. So "two cars with different brakes time identically" is true only
  because there are no different brakes.
- **The SHIFTS themselves.** Keep this distinction sharp, because the gearbox is
  now half-modelled: the ratios DO reach the solver, but only through the top
  gear, as a speed ceiling. Nothing models the time lost to an upshift, so a
  close-ratio box that keeps an engine in its band is not credited for it, and
  `shift_time` (per-engine, and upgradeable — see
  [engine-and-transmission.md](engine-and-transmission.md)) is invisible to the
  rating. Intermediate ratios are invisible for the same reason: only the
  smallest one is read.
- **The torque CURVE's shape.** Peak power is assumed available at every speed
  below the cap, so a peaky engine and a flat one with the same peak rate alike.
  Turbo lag follows from that (a boosted engine is rated at full boost — only the
  *resulting* torque figure reaches the solver).
- Suspension, weight distribution (`weight_front` — the point mass loads all four
  corners equally, so front/rear balance is invisible even though the widths are
  not).

**Consequence, stated plainly because the next person will assume otherwise: the
hairpin measures low-speed cornering and corner exit, NOT braking.** Do not
describe the rating to the player as though it reflects stopping power, and do
not tune the hairpin radius expecting it to reward brakes.
`test_the_rating_ignores_fields_the_benchmark_cannot_measure` pins this — if it
ever fails, the rating gained a term and this section needs updating with it.

Adding a braking term means authoring roster-wide per-car brake data; it is
deferred follow-up (the spec's D7).

## Caching

`benchmark_ms` is memoised in a static dictionary. The key (`_cache_key`) is
**only the fields the solver actually reads** — mass, peak torque, redline, tyre
compound, **both tyre widths**, drag, both downforce terms, drive mode,
**`wheel_radius` and the engine id** — so names, model paths and ownership
bookkeeping don't fragment the cache. The last two are the geared top-speed
inputs: the radius comes off the car, and the engine id stands in for the ratios
and final drive that hang off the engine. The id earns its place on its own
account — two metas identical in every other field but wearing different
gearboxes now genuinely lap differently, so an engine **swap** has to re-solve
rather than serve the pre-swap time. It is concatenated
with `_config_key()`, a fingerprint of the four `benchmark_*` knobs, the three
`traction_factor_*` values and `tire_load_sensitivity` / `tire_ref_pressure`,
because a designer edit mid-session must not leave
stale numbers on screen. The built track and the reference time are cached
alongside and invalidated by the same fingerprint.

**Ratings are never persisted to a save.** They are derived on demand, so a
retune can't leave stale numbers baked into a profile. `CarPerformance.reset()`
drops everything — call it when the catalogue is swapped wholesale (tests,
`CarFixtures`); the config fingerprint already handles config edits.

## `merged_meta` — why it needs both meta builders

`UpgradeLibrary` keeps power and grip in **two different metas**:

- `effective_meta` mirrors only the `EFFECTS` entries flagged `feeds_pw`, and so
  **excludes `tire_compound` and `downforce_*`**;
- `grip_meta` is `effective_meta` plus the `feeds_grip` fields.

That split exists because power-to-weight was the *eligibility* currency and
tyres were not allowed to widen it. The rating has no such constraint, and a
rating blind to aero and tyres would defeat the entire point of the sweeper
section — **a rating built on `effective_meta` alone would not move when an aero
kit is fitted.** `CarPerformance.merged_meta(owned_car, base_meta)` therefore
takes `effective_meta` and copies `tire_compound`, `downforce_front` and
`downforce_rear` over from `grip_meta`. Pass its output to `rating`, never a raw
`effective_meta`. `test_merged_meta_carries_both_power_and_grip_terms` and
`test_an_aero_kit_rates_higher` cover it.

## The solver enrichment that makes the benchmark mean anything

Before this work `LapTimeModel` read only mass, drag, power-to-weight,
`tire_compound` and the event's surface/weather — so a benchmark on it would have
been a restatement of power-to-weight and the corner sections would have been
decorative. Two terms were added. Both are also fixes: the model
previously ignored whether a car was AWD or carried an aero kit.

### Downforce — a speed-dependent friction circle, in ALL THREE passes

Aero load passes **through μ**, exactly like the car's weight does, so the
envelope is `μ(g + D·v²/m) = mu_g + aero_a·v²` where `aero_a = μ·D/m` and `D` is
the sum of `downforce_front` and `downforce_rear` (the point mass has no axles).

Cornering ceiling: `κ·v² = mu_g + aero_a·v²`, which is **linear in v², not
quadratic**, giving `v² = mu_g / (κ − aero_a)`.

Crucially the same envelope is used in **all three passes**, via `_grip_long(mu_g,
aero_a, v2, a_lat)`. If only the pass-1 ceiling knew about aero, a car sitting at
its aero-boosted cap would have `a_lat > mu_g`, `grip_long` would collapse to
**zero**, and the car could neither accelerate nor brake at a speed the ceiling
had just declared legal — the three passes would stop describing one friction
envelope. `test_all_passes_share_one_envelope_at_the_aero_boosted_cap` guards
this. With `aero_a = 0` the expression is exactly
the old `sqrt(mu_g² − a_lat²)`.

**The singularity.** `v² = mu_g / (κ − aero_a)` blows up as `aero_a → κ`, i.e.
"aero alone holds the car at any speed", and this is reachable in practice — the
`aero_kit` upgrade adds real downforce and a sweeper's κ is small by design. So
the denominator is floored at `KAPPA_DENOM_MIN` and the cap is clamped to
`V_CAP_MAX_MS` (150 m/s = 540 km/h — far above anything drivable, so it never
binds on a real car and exists purely to keep a degenerate combination finite).
`test_extreme_downforce_stays_finite` covers it.

### Drive mode — the traction factor, forward pass only

The forward pass is `a = min(traction_factor(drive_mode) · grip_long, a_engine)`.
`_traction_factor` selects `traction_factor_rwd` / `_awd` / `_fwd` from
`GameConfig` by the car's `drive_mode`, defaulting to RWD for a meta without the
field. It gates how much of the available envelope can be **put down as drive**;
braking is untouched, because braking is not a drivetrain function. The
justification from the real sim: `Drivetrain.step` couples the driveline, so AWD
spreads drive torque over four contact patches — less slip per patch, less
wheelspin.

Note this applies along the **whole** track including the straight, so it also
affects the launch. That is deliberate (a FWD car does launch worse) but it means
the traction knobs interact with `benchmark_straight_m`.

### The geared top-speed cap

`a_engine = P/(v·m)` accelerates **forever**. Before this term the model had no
gearbox and no rev limiter, so it scored every car as though it were driving an
ideal CVT that never runs out of gears — a short-geared torque car was credited
with speeds it is physically pinned below. `LapTimeModel._geared_top_speed_sq`
gives the solver the top end the car actually has:

```
v_max = omega_redline * wheel_radius / (top_ratio * final_drive)
```

which is the **same chain `Drivetrain` gears the crank through to the axle**, so
the two cannot describe different cars. Note it reads from *two* places:
`wheel_radius` off the CAR (`CarLibrary`) while the ratios and `final_drive` come
off the ENGINE (`EngineLibrary`, resolved from `car_meta["engine"]`) — which is
exactly why an engine swap correctly moves a car's top speed, and why the engine
id is in the cache key. **Top gear is the SMALLEST ratio, not the last entry**:
the shipped boxes happen to be authored descending, nothing enforces that, and a
mis-ordered list would otherwise hand a car a first-gear top speed.

**Returning `0.0` means "no cap", and that zero is load-bearing rather than
defensive padding.** A meta with no engine id, an unknown engine, or no wheel
radius does not describe a gearbox at all — and most callers hand this model
exactly that: a synthetic point-mass meta from a physics test or a rally fixture.
Inventing a plausible gearbox for them would silently re-time every one of those
solves. So the absence of a drivetrain is treated as an absence of information,
not as a car with a very short top gear.

**Where it is applied matters more than the formula.** It goes into `cap2`, the
cornering-ceiling array — including on the straight sections — not into
`a_engine`. That placement means **both** the forward acceleration pass and the
backward braking pass respect it, which is the point: a car must not arrive at a
corner carrying a speed it could never have reached. Capping `a_engine` alone
would have left the braking pass free to back-solve from an impossible entry
speed.

Observed effect when this landed, and stated as a snapshot of the currently
authored roster rather than a target: only **two** cars moved — `beast`
526 → 508 and `xjs` 478 → 473 — and every other shipped car was unchanged,
because on the benchmark track they never reach their geared top speed anyway.
That is the useful shape of this term: it bites exactly the short-geared cars and
is inert for the rest. Re-gear a car or swap its engine and the set of cars it
touches changes; don't treat those two ids as fixed.

`test_lap_time_model.gd` covers it in relations only, on the synthetic
`CarFixtures` roster and never a shipped engine:
`test_a_meta_with_no_gearbox_is_left_uncapped` (the zero case above),
`test_a_taller_geared_car_reaches_a_higher_top_speed`,
`test_the_cap_actually_binds_on_a_long_straight`, and
`test_the_cap_holds_the_braking_pass_too` (the `cap2`-not-`a_engine` placement —
if that one fails, someone has moved the cap onto the engine term).

## Invariance: the enrichment shipped inert

`traction_factor_*` all default to `1.0` and **no shipped car has any
downforce**, so the downforce and drive-mode terms are exact no-ops on current
content and every existing time is byte-identical to before they existed.
`test_defaults_are_an_exact_no_op` in `test_lap_time_model.gd` pins that
property for those two terms — the **geared top-speed cap is the one enrichment
that did not ship inert**, by design: it is a correction, not an opt-in, so it
moved the times of the cars it binds on (see above). Its own no-op guarantee is
narrower and is the zero case: a meta that doesn't describe a gearbox is left
exactly as it was, which is what keeps every point-mass caller unchanged. Keep
`test_defaults_are_an_exact_no_op` green — keep it green, because it is the only thing standing between a solver
tweak and a silent, game-wide shift in every rating.

## Calibration tooling

One committed offline tool, a report rather than a pass/fail gate. It is not part of the
test suite — it generates real tracks and takes minutes.

**C1 — benchmark fidelity: `./calibrate_benchmark.sh`**
(`tools/calibrate_benchmark.gd` + `.tscn`). Asks the only question that matters
about the benchmark: does it *rank* cars the way real stages do? For every
catalogue car, stock and at `UpgradeLibrary.max_potential_meta` (to span the
power range), it computes the benchmark time and the mean `optimum_ms` over a
sample of **live-generated** stages, and reports the **Spearman rank
correlation** between them — absolute agreement is meaningless when a 40 s
benchmark stands in for a multi-minute stage. It also names the worst
**over-rated** and **under-rated** builds (largest rank deltas each way), since
a lone correlation number tells you nothing about what term is missing.

The stage sample spans archetypes (`ARCHETYPES` in the script: `straightness`,
`turn_count`, `forestiness`, `surface_mix`, gravel through tarmac) and each
archetype's own correlation is printed, so a benchmark that ranks open stages
well and twisty ones backwards cannot hide behind the pooled figure. Stages are
synthetic seeds put through `TrackGenerator.generate` — never an authored stage list.

Knob sweeping goes through `BenchmarkTrack.build_from`, never the live config:
`-- --straight=350,500,750 --sweeper=70,90,120` sweeps the cartesian product and
flags the best-correlating setting. Other args: `--stages=N` (generation is the
entire cost), `--seed=N` (`--stock-only` is accepted and ignored — there is one build
per car now that parts are gone). Anything it recommends is a
`GameConfig` value — apply it in `config/game_config.tres`.

## Testing

`tests/headless/test_car_performance.gd` (bare logic, no scene — the cheap tier)
and the enrichment half of `tests/headless/test_lap_time_model.gd`. Per project
rules, **no test asserts a particular rating, a particular benchmark time, or
where a catalogue car lands**; every rating test is built from a synthetic meta
and asserts a direction or an invariance (more power rates higher, more mass
rates lower, an aero kit rates higher, AWD ≥ RWD when its ceiling is higher,
unmodelled fields move nothing, the anchor survives a geometry or grip retune,
the straight lever's direction). A designer retuning the knobs must not break
that file.

The load-sensitivity term is covered the same way, in relations only:
`test_car_performance.gd` → `test_wider_tires_rate_higher_at_the_same_mass` and
`test_shedding_mass_helps_a_car_that_cannot_use_more_power` (the second is the
interesting one — it isolates the effect from `a_engine = P/(v·m)` by using a car
that is not power-limited, so the gain can only have come through μ);
`test_lap_time_model.gd` →
`test_a_lighter_car_corners_faster_not_just_accelerates_faster`,
`test_wider_tires_recover_grip_at_the_same_mass`, and
`test_the_load_term_applies_through_the_frozen_benchmark_override_too`, which
pins the `mu_override` placement described above — if that one fails, someone has
moved the term back inside `_surface_grip` and the rating has gone blind to mass
again.

## Related

- [region-stage-library.md](region-stage-library.md) — `LapTimeModel`'s other job: the dev
  stage's PAR times.
- [upgrade-catalogue.md](upgrade-catalogue.md) — the `feeds_pw` / `feeds_grip`
  split behind `merged_meta`.
- [configuration.md](configuration.md) — where the knobs live.
