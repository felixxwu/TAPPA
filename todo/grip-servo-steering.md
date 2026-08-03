# Grip-Servo Steering

Replace the whole front-wheel steering system with one closed loop on **measured
front-tire grip usage**. Steering input stops meaning "point the wheels here" and starts
meaning "work the front tires this hard".

Status: **IMPLEMENTED**, two driving passes done. Three things surfaced from driving that
the design had wrong or missing — see [At rest the null is undefined](#at-rest-the-null-is-undefined),
[Throttle gives way too](#throttle-gives-way-too-on-a-driven-steered-axle), and the
`steer_speed` note in [Config surface](#config-surface). Not yet balance-checked against
`LapTimeModel`.

## Dependency

Requires the per-tire grip readout (`Drivetrain.grip_fraction`, `WheelContact.slip_use`,
`readouts[wheel].grip`, and the HUD's `GripGrid`). That work is complete but **may still be
uncommitted** — check `git log` for it before starting, and see
[`features/debug-tools.md`](../features/debug-tools.md) → "Per-tire grip grid".

The readout's metric choice is load-bearing here, not incidental. `grip_fraction` measures
**slip over `slip_peak`**, which rises monotonically through the limit. A force-based
metric (`|f| / μN`) peaks at 1.0 and then *falls* toward `sliding_grip_ratio`, so a servo
tracking it would read "only 87%, push harder", get less, push harder again, and drive
itself into a permanent slide chasing a number moving away from it. **Do not change the
readout to a force basis without redesigning this controller.**

## Why: the current system leaves grip unused

The symptom is front tires sitting at ~80% usage during a turn that wants 100% — understeer
with grip still in reserve. Three causes, all in `car.gd` → `_update_steering` and its
helpers:

1. **`steer_travel_alignment` ships at `0.8`** (`game_config.gd`; not overridden in
   `config/game_config.tres`). The front wheels follow only 80% of the travel direction, so
   in any slide they sit off the ideal angle by 20% of the chassis slip angle —
   permanently, and proportional to how sideways the car is.
2. **It uses the chassis slip angle, not each front wheel's.** `_update_steering` takes
   `atan2(-local_vel.x, -local_vel.z)` at the centre of mass. The front axle's velocity
   direction differs from that by the yaw-rate term, so mid-corner the reference is
   systematically wrong in a way no coefficient can correct.
3. **`optimum_steer_limit` is open-loop.** It predicts the limit from `cfg.steer_limit` and
   a nominal surface `slip_peak`, then caps the wheel angle there. It never checks what the
   tires actually did, so load transfer, `tire_load_factor`, and the two fronts being on
   different surfaces are all invisible to it. It can land *near* the limit; it cannot land
   *on* it.

`steer_lock_blend_end_speed` (40 km/h) then exists purely to blend back to mechanical lock
at low speed, because the slip-based cap is speed-independent above `tire_norm_floor`
(2.5 m/s) and would otherwise pin low-speed steering at ~8.6° on tarmac. It is a workaround
for using the chassis reference instead of the wheels' own.

## Design

### The mental model

Today's input sets a **wheel angle**. The new input sets a **grip target**. The wheel angle
becomes an output the controller works.

The right analogue is **steering force feedback**: you command effort, and the wheel finds
its own angle against the tires' self-aligning torque, self-centring to the travel
direction when released. This system is that, with the treacherous part removed — real
aligning torque peaks *before* peak lateral grip and then collapses (the "wheel went light
and I was a passenger" understeer runaway), whereas slip usage rises monotonically, so full
input means exactly 100% and stays stable there.

Two things follow from taking the force-feedback model seriously, and both matter later:

- **`steer_speed` is the model of a hand** — how fast a wheel can physically be turned.
  It is not a numerical smoothing parameter, and it is the only rate in the system.
- **The servo stands in for the driver's arms.** Where a real driver would hold a
  correction, the servo holds it. This is what makes the damage behaviour in
  [Damage toe](#damage-toe-is-intended-behaviour-not-a-conflict) correct rather than broken.

### Sign conventions (derive before coding; these are easy to get backwards)

- `VehicleWheel3D.steering` is **positive to the left**, matching `car.gd`'s `ai_steer`
  comment and `_axis_input("steer_right", "steer_left", ai_steer)` (positive = left).
- `Drivetrain.wheel_side(wheel)` = `wheel_forward(wheel).cross(contact_normal)`, which for
  forward ≈ −Z and normal ≈ +Y gives ≈ **+X, i.e. right**.
- `WheelContact.s_lat = -side.dot(vel)`, so **`s_lat > 0` means the contact patch is
  travelling to the LEFT** relative to the wheel.
- Therefore the wheel's own slip angle, left-positive and consistent with `steering`, is
  `atan2(s_lat * sign(v_long), abs(v_long))` — **not** the plain `atan2(s_lat, v_long)` an
  earlier revision used. Lateral slip is zero whenever the velocity is *parallel* to the
  wheel, which is true both running forward along it and backward along it; the plain form
  only ever finds the forward solution, so reversing it reported ~±PI and the servo tried to
  spin the wheel half a turn into the steering stop, in a direction set by the sign of a
  near-zero lateral term. Folding in `sign(v_long)` picks the **nearer** of the two solutions:
  unchanged forwards, correct backwards, and bounded to a quarter turn either way. `signf(0.0)`
  is `0.0`, so a purely sideways-sliding patch reports "no correction", which is the honest
  answer since no wheel angle can zero its lateral slip.
- The **null angle** (wheel pointing along its own travel, zero lateral slip) is
  `steering + slip_angle` — turning further *left* than the null makes `slip_angle` negative
  and generates leftward force, the correct physical sense.

The `steering = null - slip_angle` relation makes the controller **stateless**: the current
offset from the null is just `|slip_angle|`, re-measured every tick, so there is no
integrator variable to store, reset, or wind up. The wheel angle *is* the integrator.

### Input demand: share the friction circle

Keyboard and touch give every input as **0% or 100%**, so the player cannot express the
compromise a progressive pedal allows — and the servo measures what longitudinal slip has
already spent, so a pinned pedal leaves nothing for cornering and the car simply refuses to
turn in. Rather than pick a pedal ceiling by hand, scale the **longitudinal** demand so it and
the steering demand fit one circle:

```
long_demand = brake_input + (drive if front_axle_driven else 0.0)
scale       = Car.longitudinal_demand_scale(long_demand, steer_demand)
brake_input *= scale
drive       *= scale        # only when the steered axle is also driven
```

where the scale is `1.0` inside the circle and `1.0 / |(long, steer)|` outside it. A pedal
alone is untouched; a pedal pinned with full steering scales to **0.71** — not an invented
compromise but the optimum on a friction circle, and what a driver with progressive pedals
does. **No config knob.** Trail braking and power-out both emerge: as steering winds on the
pedal bleeds off, and as it unwinds the pedal returns.

**Only the longitudinal side is scaled.** The lateral side is already limited by the servo's
own `lat_available` (what the ellipse has left after the *measured* longitudinal spend), so
scaling the steering demand too would **double-count** — at 0.71 longitudinal the tires have
0.71 of lateral budget, and a player asking for everything should get all of it, not
`0.71 x 0.71 = 0.5`. An earlier revision made exactly this mistake and quietly under-steered
every braking corner by a factor of 0.71.

**This is demand arbitration, not ABS or traction control.** Pedal torque is untouched when
the player is not steering, so wheels still lock up under braking and still spin up under
power — both remain skill elements. A full longitudinal servo (pedal = target longitudinal
usage) would give ABS and perfect threshold braking, but it deletes those and is a much
larger change: **explicitly out of scope**, noted as a possible follow-up.

The **handbrake** is excluded either way — it wants the rears to break away while the fronts
keep full bite.

#### Throttle gives way too, on a driven steered axle

The first revision scaled only the brake, reasoning that power understeer was wanted emergent
behaviour the player could resolve by lifting off. **Driving disproved that**: under hard FWD
acceleration the wheels barely turned at all, because the drive had spent the entire front
budget and the servo correctly found no cornering grip left. That is not power understeer, it
is a dead steering wheel — and it is the same binary-input problem the brake had.

So the throttle is scaled too, but **only when the steered axle is also driven**
(`Drivetrain.front_axle_driven()`: true on FWD/AWD, false on RWD). The asymmetry is physical
rather than arbitrary: braking always acts on the steered axle, so the brake always competes;
the throttle only competes when the front wheels are the driven ones. On RWD the throttle
keeps full authority and power-oversteer behaviour is untouched.

One accepted simplification: on AWD, scaling `drive` for the front axle's benefit also robs
the rear, since one throttle figure feeds the whole driveline.

### The control law

Replaces `_update_steering` entirely. Runs in `_timed_physics_process` **after**
`drivetrain.step()` — already the existing order, `car.gd` calls `step()` then
`_update_steering` — so it reads this tick's own measurement with no added lag.

```
front = drivetrain.front_axle_state()      # load-weighted; see below

# What is left of the friction circle for cornering, MEASURED not modelled:
long_used     = absf(front.s_long * cfg.traction_ellipse_ratio) / front.slip_peak
lat_available = sqrt(max(0.0, 1.0 - long_used * long_used))

setpoint = steer_demand * lat_available    # 0..1 of peak grip
measured = absf(front.s_lat) / front.slip_peak
error    = setpoint - measured

step = error * front.slip_peak             # usage error -> radians; see derivation
null = steering + front.slip_angle         # zero lateral slip

if steer_demand <= cfg.steer_deadzone:
    # * travel: at rest the null is undefined and degenerates to a fixed point,
    #   so fade it toward straight ahead. See "At rest the null is undefined".
    travel = clamp(absf(front.v_long) / cfg.tire_norm_floor, 0.0, 1.0)
    target = null * travel
else:
    target = null + signf(steer_input) * (absf(front.slip_angle) + step)

steering = clampf(move_toward(steering, target, cfg.steer_speed * delta),
                  -cfg.steer_limit, cfg.steer_limit)
```

#### Why the setpoint is the lateral budget, not total usage

The steer angle only moves the **lateral** component, so comparing the player's request
against *combined* usage charges them for the longitudinal spend. Under threshold braking
at `traction_ellipse_ratio = 1.0` (the shipped value — a strict circle), front longitudinal
slip alone reaches `slip_peak`, so combined usage reads ~100% with the wheels dead straight.
A request of 60% would then produce `error = -0.40`, driving the offset to zero: **the car
would refuse to turn in under braking at all.** Measuring against the *remaining lateral*
share is what makes trail braking work.

The two mechanisms agree numerically, which is the check that this is coherent: demand
normalisation sets brake to 0.71, so `long_used ≈ 0.71`, so
`lat_available = sqrt(1 - 0.5) ≈ 0.71`, so `setpoint = 1.0 × 0.71 = 0.71`. Both halves land
on the same 71% share of the circle.

Note `long_used` is measured per front wheel, so `brake_bias` sending different torque to
the front axle is accounted for automatically — no need to model the split.

#### Why `step = error * slip_peak`, with no gain knob

An earlier draft exposed a `steer_full_rate_error` gain. Deriving its stability bound
removes it. One tick's movement must not exceed the remaining angular error:

```
(error / E) * steer_speed * delta   <=   error * slip_peak
                              E    >=   steer_speed * delta / slip_peak
```

At `steer_speed = 5.0`, 60 Hz, tarmac `slip_peak = 0.15` that is `E >= 0.56`. Substituting
the boundary value back in collapses the term entirely:

```
step = (error / (steer_speed*delta/slip_peak)) * steer_speed * delta
     =  error * slip_peak
```

So the step is simply the usage error converted into radians — a Newton step with a gain of
exactly 1. **There is no gain to expose or mis-set.** It self-scales with the surface
(gravel's larger `slip_peak` gives proportionally larger steps) and with the frame rate.

The small-angle approximation behind it (`slip ≈ sin θ ≈ θ`) errs in the safe direction: at
a 30° slip angle in a deep slide the step **under**-corrects by ~13%, converging slightly
slower rather than overshooting. Do not "fix" this with a `1/cos` term without a reason —
under-correction is the safe failure mode.

`cfg.steer_speed` therefore appears **exactly once**, as the rate limit, doing only the job
of modelling the hand.

#### Zero input takes the null directly

Not "servo usage toward zero". *Minimising usage* is genuinely ambiguous: on a FWD/AWD car
under power the front tires carry longitudinal force, so combined usage never reaches zero
and the objective has no unique solution. The null is defined by **lateral** slip alone,
which can reach zero at any throttle setting. This resolves that open question, and it also
makes releasing the wheel catch a slide — so `steer_travel_alignment` needs no replacement.

The `steer_deadzone` comparison (not `== 0.0`) matters because analogue sticks and the
touch slider never return exactly zero.

### Reverse needs NO special case

An earlier revision of this design called for gating the servo on forward motion and falling
back to `input * steer_limit` when reversing — described then as "the single blemish on one
generalised system". That turned out to be unnecessary: the blemish was a **bug in the
slip-angle formula**, not an irreducible case. With the reverse-safe form in Sign conventions
the null angle is correct going backwards, so there is no reverse branch anywhere and the
system really is one rule.

It shipped broken once, which is worth recording: with the plain `atan2(s_lat, v_long)`,
backing up in a straight line swung the wheels to **full lock**, in a direction set by the
sign of a near-zero lateral term (so it could flip). Nothing caught it because the test this
document asked for — "reversing steers from input directly and does not invert" — was never
written.

The steering *response* does invert in reverse — holding "left" while backing up swings the
nose left, so the car backs to the right — but that needs no code: it is what the physics does
once the front tires are asked for a leftward force, and what a real car does too.

Guarded now by `test_reversing_straight_reports_no_slip_angle`,
`test_reversing_while_sliding_corrects_the_nearer_way`,
`test_the_slip_angle_never_asks_for_more_than_a_quarter_turn`,
`test_a_purely_sideways_patch_asks_for_no_correction` and
`test_reversing_does_not_swing_the_wheels_to_lock`.

### At rest the null is undefined

Found by driving, not by reasoning: **released wheels stayed cocked wherever the player left
them.** At a true standstill `s_lat` and `v_long` are both exactly 0, so `atan2(0, 0)` returns
0, so `null == steering` — the zero-input target is a fixed point and the wheels never come
back to centre.

The fix is to recognise that "point along the direction of travel" has no answer when there is
no travel: as the reference speed vanishes the travel direction degenerates to the car's own
forward axis. So the null fades toward straight ahead, weighted by the axle's forward contact
speed over **`tire_norm_floor`** — the same speed at which the tire model itself stops treating
slip as meaningful (`Drivetrain._tire_force`). It is the existing physical floor applied
consistently, not a new steering exception, and it costs no knob.

It also disposes of a separate worry: below that floor the raw `atan2` is dominated by
suspension jitter, and the weight multiplies that away.

**Confine it to the zero-input branch.** The demand branch needs no travel reference to push
further from where it already is, and pinning its null would make the offset converge on one
`slip_peak` of angle instead of integrating out to the mechanical stop — i.e. it would silently
break full lock at a standstill. `test_centring_does_not_stop_standstill_input_reaching_lock`
guards the pair together for exactly that reason.

### What each case does

| Case | Behaviour | Mechanism |
|---|---|---|
| Standstill, **no** input | wheels return to centre | the null fades toward straight ahead below `tire_norm_floor` — see above |
| Standstill, full input | walks out to mechanical lock | nothing moves ⇒ `measured` is 0 ⇒ permanently under setpoint ⇒ integrates into the `steer_limit` clamp. Replaces `steer_lock_blend_end_speed` |
| Creep (~0.1 m/s), full input | still reaches lock | the velocity is *coherent*, so `atan2` correctly reports the scrub and the null lands near straight — but `v_ref` is floored at `tire_norm_floor`, so `measured` reads only ~13% and the offset keeps growing |
| Steady cornering | converges to the commanded usage | stable fixed point at `measured == setpoint` |
| Half input | settles at ~50% of available | proportional setpoint |
| Release mid-slide | lateral slip → 0, slide catches | target *is* the null |
| Braking + steering | trail braking | demand normalisation frees longitudinal budget; `lat_available` reflects what is left |
| FWD/AWD, zero input, full power | resolves cleanly | null is lateral-only; wheelspin is irrelevant to it |
| FWD/AWD under power, turning | authority shrinks, but never to nothing | `long_used` is measured, so `lat_available` falls — **power understeer becomes emergent**, not scripted — while the throttle scaling keeps a real angle available. See "Throttle gives way too" |
| RWD under power, turning | full steering authority | the front tires never drive, so the throttle is not scaled and takes no cornering grip |
| Past the limit | pulls itself back | `setpoint ≤ 1` ⇒ commanded slip never exceeds peak; no over-limit clause needed |
| One front airborne | handled implicitly | its `n_force` is 0, so the load weighting drops it |
| Both fronts airborne | fall back to `steer_demand * steer_limit` | no measurement to servo on; holding the angle looks frozen mid-jump, which players read as a bug |

### Combining the two front wheels

**Load-weighted average**, weighted by `WheelContact.n_force`, for `s_long`, `s_lat`,
`slip_angle` and `slip_peak`. The loaded outer tire dominates — correct, since it generates
most of the cornering force — and a nearly-airborne inner wheel stops skewing the reading.
Degrades to a plain average on an evenly loaded axle.

A plain average would let the unloaded inner wheel drag the reading down (outer 95% at
4000 N, inner 60% at 800 N ⇒ 77%), so the servo would turn in further and saturate the
outer tire past peak. `max()` would be safe but deliberately under-uses the loaded tire,
the opposite of this work's goal.

### What the drivetrain must expose

`WheelContact` already carries `v_long`, `s_lat`, `n_force`, `slip_peak` and `slip_use`.
Add:

- `WheelContact.slip_angle` — `atan2(s_lat, v_long)`, and `WheelContact.s_long_norm` — the
  normalised longitudinal slip `_tire_force` already computes. Both stored unconditionally
  alongside `slip_use` (same reasoning: cheaper than the branch).
- `Drivetrain.front_axle_state() -> Dictionary` — walks `_contacts` for non-traction
  wheels, load-weighting the fields above, returning a **reused scratch dict** (same
  pattern as `_surf_scratch` / `_steer_scratch`) so the per-tick path allocates nothing.
  Must report whether *any* front wheel was in contact, for the airborne fallback.

**It must not read the `readouts` dictionary.** That dict is gated on `publish_readouts`,
which the car ties to the debug overlay's visibility — steering needs this every tick in
every build. Both consumers read the same `WheelContact` fields, so the debug grid and the
controller cannot disagree.

**Stale `_contacts`.** `front_axle_state()` reads state populated by `step()`. During the
countdown hold, the finish lock, and replay playback, `step()` may not run. Define this
explicitly: if `step()` did not run this tick, take the airborne fallback (direct input
mapping) rather than servoing on last tick's numbers. See `test_countdown_hold.gd`.

### No low-speed exception

Earlier drafts assumed the null angle would be numerically unstable near standstill and
would need a blend. It does not, and this is the point of the whole redesign:

- At **true standstill** `s_lat` and `v_long` are both exactly `0` and `atan2(0, 0)`
  returns `0`, so the null equals the current angle and the offset grows unopposed.
- At **creep** the velocities are small but *coherent* — they come from
  `Drivetrain.velocity_at(cp)`, a rigid-body velocity, not a sensor. There is no noise
  source to jitter.

Because `steer_speed` is a physical hand-speed limit, every low-speed behaviour is bounded
by physical plausibility rather than by a numerical guard. **`steer_lock_blend_end_speed` is
deleted outright, not replaced.**

One residual worth knowing (a note, not a special case): if the car is barely moving but
travelling *mostly sideways* — settling on its springs, or sliding on a slope at ~0.2 m/s —
the null can swing toward ±90° and the wheels will rotate to follow their travel direction.
The rate limit bounds how fast, and at that speed it is harmless and arguably correct.

### Damage toe is intended behaviour, not a conflict

`_apply_wheel_toe` writes `wheel.steering = steering + toe` for the fronts and
`wheel.steering = toe` for the rears, and the drivetrain measures in that toed frame — so
the toe is **inside** the loop by construction. `DamageModel.nudge_wheels` bends **all four
wheels with an independent random sign each**, so of four contributions the servo can only
touch one:

| Contribution | Servo authority | Outcome |
|---|---|---|
| Rear toe (2 wheels) | **none** — the front servo cannot reach it | survives fully; the car crabs and pulls |
| Front pair, opposite signs (~50% of cases) | ~none — the load-weighted average nets out | survives fully; scrub and drag |
| Front pair, same sign (~50%) | cancels the average | the pull goes, and the **wheels sit visibly off-centre** |

That third row is faithful, not broken. A real car with bent front alignment does not
wander — the *driver holds a correction* and it tracks straight with the wheel off-centre.
The servo stands in for the driver's arms, so reproducing that is correct. The damage cue
moves from "the car drifts sideways" to "the wheels are cocked and the rear still crabs",
which is arguably a better read.

Do **not** try to exclude the toe from the measurement. `features/damage.md` states the
pull emerges from the physics with no synthetic bias, and that remains true.

### The stiction hold reads the pre-scale brake

The demand arbitration scales `brake_input` down when the player also steers — and
`_apply_parking_hold` was reading that scaled value, so a car pedal-braked to a standstill
**while steering** silently lost its anchor and could creep down a slope. (The synthesized
parking brake was never affected: `brake_hold` exempts it from scaling entirely.)

`_resolve_drive_inputs` now decides `pinned` from the driver's demand **before** scaling and
reports it. The split is the point: the stiction hold asks "should a stationary car be
anchored", while the arbitration only frees **cornering** grip on a **moving** car — it has
nothing to say about that question, so it must not be allowed to answer it by side effect.

Note this is a *result* the caller needs, not a flag for it to re-derive a decision with —
which is why exporting it through `_inputs_scratch` is fine where the earlier `brake_hold`
flag was not (that one existed only so the caller could redo a decision the function had
already made, and it was folded back in).

Guarded by `test_braking_to_a_stop_while_steering_still_anchors_the_car`.

## Deletions

| Removed | Reason |
|---|---|
| `car.gd` `_steer` + its `assist_rate` smoothing (and its reset, `car.gd` ~line 1201) | `steer_speed` rate-limiting *is* the smoothing; two easing stages in series was double-smoothing |
| `GameConfig.steer_travel_alignment` | the null angle replaces it at an implicit coefficient of 1.0 — **this is the 80% fix** |
| `Car.optimum_steer_limit`, `GameConfig.steer_lock_blend_end_speed`, `Car.STEER_LOCK_BLEND_END_SPEED` | the servo measures the limit instead of predicting it; no low-speed blend needed |
| `Car.steer_authority` | existed only to taper the understeer assist |
| `Car.optimum_slip_angle` | only caller is `_apply_steer_assist` |
| `Car._apply_steer_assist` + `GameConfig.steer_assist_torque` | **already inert in the shipped game**: the config default is `0.0`, `game_config.tres` does not override it, and all 9 entries in `CarLibrary.CARS` author `"steer_assist_torque": 0`. It fires only in `tests/fixtures/test_config.tres` (`2000.0`). Also remove the field from all 9 `CARS` entries and its doc block in `car_library.gd` |
| `GameConfig.steer_assist_min_speed` | both users (the alignment fade and the assist fade) are going |
| `Drivetrain.steering_axle_slip_peak` | only caller is `optimum_steer_limit`'s call site |
| `tests/headless/test_speed_steer_limit.gd` | tests only deleted functions (8 tests) |

Kept: `steer_limit`, `steer_speed`, `_apply_wheel_toe`, `_apply_level_assist`, and
`_apply_spin_protection`.

**Spin protection stays** and needs re-gating: it currently shares the deleted
`steer_assist_min_speed` fade via `assist_scale`. Re-gate it on the 2 m/s forward-motion
floor that the slip-angle calculation already carries. It solves a problem the servo does
not — the player holding steering *into* a slide until the car rotates past recovery. It is
live and strong (`spin_assist_torque` defaults to `10000.0` in `game_config.gd`, not
overridden in the `.tres`; `config/game_config.tres` sets `spin_assist_angle = 0.6`), so
deleting it would be a large, separate handling change.

## Config surface

Removed: `steer_travel_alignment`, `steer_lock_blend_end_speed`, `steer_assist_torque`,
`steer_assist_min_speed`. Added: `steer_deadzone` only (and only if no existing input
deadzone can be reused — check `mobile_controls.gd`'s `tilt_deadzone` and any shared input
helper first).

Net **−4 knobs, with no gain or blend added.** Steering tunes on `steer_limit` and
`steer_speed`.

**`steer_speed` retuned from `5.0` to `2.0`** in `config/game_config.tres` — the prediction that
it would feel too sharp was confirmed on the first drive. Reaching peak grip now takes only
~8.6° of wheel movement instead of most of full lock, so at `5.0` rad/s the wheel crossed that
in about two ticks (33 ms), which read as twitchy even though it is physically honest. `2.0`
gives ~75 ms to the grip limit and ~400 ms to full lock for parking. It is the dominant feel
parameter now, so expect further tuning — and tune it in the `.tres`, never in the script
default.

## Consequences to accept deliberately

**Understeer from over-steering becomes impossible.** Sawing at the wheel can no longer
overdrive the front tires. Understeer now comes only from carrying too much speed for the
radius (tires at 100% and it is not enough), from throttle eating the friction budget on a
FWD/AWD car, or from a surface change. This is the intended effect of "always use as much
as the steering wheels have to offer", but it removes a mistake the player used to be able
to make.

**`grip_balance` changes character.** The tuning slider trims front/rear **μ** — force at a
given slip — not `slip_peak`, where that slip sits. Because the servo targets *slip*, front
grip tuning no longer changes how much the car can turn, only how much force it gets for
turning. The slider still shifts the balance, but it will *feel* different, and
[`features/tuning.md`](../features/tuning.md) describes it in the old terms.

**Rival difficulty shifts.** Rivals are not driven — they are simulated abstractly by
`LapTimeModel` (a QSS point-mass sweep whose cornering ceiling is
`v_cap = sqrt(mu*g / kappa)`), which already assumes *perfect* grip usage. Raising the
player from ~80% to 100% therefore closes real time to every rival. Expect a rebalance pass
on `LapTimeModel` inputs or the roster's target times; do not treat "the player is suddenly
beating the field" as a bug in this work.

## Testing

Behaviour and logic only — no pinned tunable values, nothing a designer retuning
`steer_speed` or `slip_peak` would break.

New tests (`tests/headless/test_car.gd`, or a new `test_grip_servo_steering.gd`):

- **Full input drives measured front usage to ≈100%** — the regression test for the 80%
  problem, and the most important assertion in this work.
- Half input settles measurably **below** full input (ordering, not either number).
- Zero input in a slide drives front lateral slip toward zero (auto-countersteer).
- Standstill + full input reaches `steer_limit`.
- **Full brake + full steer still turns the car** — the regression test for the
  can't-steer-under-braking hole. Assert non-zero yaw, and that braking is reduced versus
  brake-alone.
- Full brake with **no** steering input gives the same brake torque as before
  normalisation (the arbitration must not tax straight-line braking).
- A FWD car at full throttle has **less** steering authority than the same car coasting
  (ordering; emergent from the ellipse).
- `steering` never exceeds `steer_limit` under any input.
- Both fronts airborne falls back to direct input mapping rather than freezing.
- `front_axle_state()` load-weights — an unloaded inner wheel must not dominate. Build a
  synthetic contact set; do not drive a real car for this.
- The step never overshoots: from a large error the usage approaches the setpoint
  monotonically, without oscillating around it.
- W+A still turns the car left; reset still returns it to the start (existing invariants).
- Reversing does not swing the wheels to lock, and the slip angle never asks for more than a
  quarter turn (the regression that shipped once — see "Reverse needs NO special case").
- Braking with no steering reaches the drivetrain unscaled; a synthesized hold (parking brake,
  finish stop) is never bled off by steering, and still reports the axle as pinned.

Existing tests that **must** change — the user explicitly asked for the behaviour they
assert to change, so say so in the summary rather than silently weakening them:

- `test_car.gd::test_travel_alignment_zero_disables_castering`,
  `::test_travel_alignment_scales_down_at_low_speed` — the knob is gone.
- `test_car.gd::test_steer_assist_suppressed_below_min_speed`,
  `::test_steer_assist_tapers_with_slip_angle` — the assist is gone.
- `test_car.gd::test_spin_assist_*` (3 tests) — behaviour kept, gate changed.
- `tests/fixtures/test_config.tres` — drop `steer_assist_torque = 2000.0`.
- `tests/headless/test_speed_steer_limit.gd` — delete.

Blast radius to re-run: `test_car`, `test_drivetrain`, `test_speed_steer_limit`,
`test_damage_model` (wheel toe layers on the new angle), `test_replay_playback` and
`test_replay_recorder`, `test_countdown_hold` (frozen-car path), `test_benchmark_mode` (the
autopilot feeds `ai_steer`), `test_mobile_controls` (same input actions), `test_debug_arrows`,
`test_hud`, plus the `sim_test.gd` users. Given the breadth this is one of the cases that
justifies a **full** `./run_tests.sh`.

## Unaffected

- **Replay.** `replay_recorder.gd` records and interpolates `wheel_steer` per frame and
  `car.gd::_step_replay` writes the recorded angles straight onto the wheels, so playback
  never runs the controller. Existing replays stay valid.
- **Input plumbing.** `mobile_controls.gd` (touch slider / buttons / tilt) drives the same
  `steer_left` / `steer_right` actions, so no touch-side change is needed. Its own local
  `_steer` variable is unrelated to `car.gd`'s.
- **`ai_steer`.** Its only real writer is `benchmark_runner.gd`'s pure-pursuit autopilot
  (`start_line.gd` merely zeroes it). `1.0` now means "use all the grip" rather than "full
  lock", which is probably better autopilot behaviour, but the benchmark's driven line will
  change — expect to re-baseline benchmark numbers. This is **not** a rival-car concern;
  rivals never use this path.

## Docs to update in the same piece of work

[`features/car-physics.md`](../features/car-physics.md) (the steering section and both
assists), [`features/drivetrain-and-tires.md`](../features/drivetrain-and-tires.md)
(`front_axle_state`, `slip_angle`, `s_long_norm`),
[`features/configuration.md`](../features/configuration.md) (the four removed knobs),
[`features/controls.md`](../features/controls.md) (steering input now means grip demand;
brake and steer share the circle),
[`features/debug-tools.md`](../features/debug-tools.md) (the grip readout is now
load-bearing for steering, not just diagnostic),
[`features/tuning.md`](../features/tuning.md) (`grip_balance`'s changed character), and
[`features/damage.md`](../features/damage.md) (the toe interaction table above).

## Open risks

1. **`steer_speed` feel.** Retuned to `2.0` after the first drive; still the dominant feel
   parameter and likely to want more. Needs driving, not reasoning — as the at-rest null bug
   showed, this system's remaining unknowns surface behind the wheel rather than on paper.
2. **Split-surface fronts** (one on tarmac, one on grass) have different `slip_peak`
   values, so their usages are normalised against different scales before being averaged.
   Believed correct — each is a fraction of *its own* limit — but worth driving
   deliberately.
3. **Demand normalisation vs. the handbrake.** `handbrake` is a separate input that adds
   rear brake torque and opens the centre diff. It is not part of the normalised pair, so a
   handbrake turn keeps full steering authority — believed right (that manoeuvre wants the
   rears to break away while the fronts bite), but unverified.
