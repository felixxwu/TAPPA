# Damage Model

**Source:** `scripts/damage_model.gd` (`DamageModel`, a `RefCounted` helper owned
by `car.gd` like `Drivetrain`). Design intent in `gameplay.md` › *Damage model*.

**Tests:** `tests/headless/test_damage_model.gd`, `tests/headless/test_spectator_damage.gd`, `tests/headless/test_engine_logic.gd`

Each fielded car has a depleting **HP pool**. Impacts drain it during a run and the car's
handling and power degrade as HP falls. **Damage can never take the car out.** HP bottoms
out at 0 and the car keeps driving: at 0 HP the engine is stumbling and rev-capped, not
dead. There is no wreck, no DNF-by-damage and no 0-HP event of any kind.

**Crashing costs you SPEED, not the run and not the car.** The punishment is a slow,
gutless car for the rest of the rally — a misfiring, rev-limited engine and bent wheels —
plus a repair bill. HP climbs back two ways: the free **between-event pit repair** applied
at the start of every rally event after the first (see below), and a **paid repair** at the
tuning lift that restores full health and straightens the wheels for a flat star price
(`Save.repair_car`, see [star-economy.md](star-economy.md)).

### Wrecking is gone entirely, and it took a lot of machinery with it

0 HP used to be an **event**: `DamageModel` had a `wrecked` signal, `apply_loss` called
`_wreck()`, `car.gd` re-emitted it, `world.gd` built a **"CAR WRECKED"** orbit-camera menu
(`scripts/wreck_screen.gd`), and *Return to HQ* called `RallySession.report_wreck()` for a
DNF. All of that is **deleted** — the signal, `_wreck()`, `car.gd`'s `wrecked` signal and
`_on_wrecked()` handler, `world.gd`'s `_wreck_screen` / `_on_session_car_wrecked()`,
`Save.record_wreck()`, `RallySession.report_wreck()`, `ChallengeSession.report_wreck()` /
`_end_as_dnf()`, and the `wreck_screen.gd` file and its `WreckScreen` class. The config
knobs that only served it (`wreck_recovery_hp_fraction`, `wreck_settle_max_seconds`) went
too. `apply_loss()` is now one line: `hp = maxf(0.0, hp - amount)`.

An earlier round had already deleted the layer *beneath* that. When 0 HP meant a permanent
hulk with no way back, it needed constant scaffolding to stay survivable: `all_cars_wrecked`,
a free rescue that granted a whole new car when every owned car was a write-off,
`car_is_wrecked` exclusions in the stranded check, a price-0 car rescue, and a car park that
refused to let a wrecked car start. All of it is gone — along with `Save.wreck_car`,
`car_is_wrecked`, `all_cars_wrecked` and `ensure_wreck_safety_net`. Nothing hands out a
rescue car, because nothing needs rescuing.

Three reasons the change was worth making:

1. **One mistake could end a career**, and then merely a rally. Every rescue above existed
   to paper over that, and each one was a place the logic could be wrong. Now there is no
   failure state to rescue from, so there is no rescue code at all.
2. **It makes the map's reachability guarantee sound.** Cars are won at specific rallies
   now ([prize-rallies.md](prize-rallies.md)) and the roster is authored so exploring from
   HQ reaches everything ([map-exploration.md](map-exploration.md)). That closure is only a
   real guarantee if the player cannot LOSE the car an authored route depends on.
3. **A terminal state is a worse punishment than a slow car.** Being sent to a menu ends
   the drive; limping the last two stages on a wounded engine is a consequence the player
   keeps *playing through*, and it is legible from the driver's seat (the engine sputters,
   the limiter arrives early) rather than announced by a screen.

A damaged car still races — badly. The car park warns ("Damaged — the engine is down on
power. Repair it at the lift.") but never blocks entry, and there is no health at which it
blocks entry.

**The warning is not "is this car pristine".** It fires from `Save.car_handles_badly`,
which reads health against `GameConfig.damage_misfire_health_threshold` — the SAME number
that decides when the engine starts misfiring, i.e. the point damage stops being cosmetic
and starts costing power. It used to call `Save.car_needs_repair`, which is true of ANY
car that is not pristine (and counts bent alignment too), so the red line appeared over
"HEALTH 100%" and taught the player to ignore it. Repair is still offered for any lost
health — "is this worth repairing" and "is this car hurt" are different questions, and
they are now different calls.

## State (`DamageModel`)

| Field | Meaning |
|-------|---------|
| `max_hp` | the car's HP pool — CarLibrary metadata, set per car by **durability** (real-world mechanical reliability + build quality + structural rigidity + ease of repair), not purely by mass; see the per-car rationale comments in `car_library.gd` |
| `hp` | working HP for the current run (starts at the OwnedCar's stored HP) |
| `instance_id` | OwnedCar binding; **-1 = unbound** (free-roam / dev — never touches `Save`) |
| `wheel_toe` | permanent per-wheel toe misalignment (rad), keyed by `WHEEL_NAMES` — see *Wheel misalignment* below |

`field(max_hp, hp, instance_id, wheel_toe)` configures all of the above for a run.
`car.gd` calls it (unbound, full HP, straight wheels) from `apply_car`; the
rally/Start-line layer ([rally-session.md](rally-session.md)) re-fields it from the
OwnedCar (stored HP + instance id + persisted `wheel_toe`) via `apply_owned` when a
car is taken to the line.

## Damage → HP loss (unified deceleration model)

Damage is **generalised**: HP loss is keyed to how much velocity the car sheds in a
**single physics tick** — whatever caused it. A tree, a sign, a cliff wall, a
nose-first drop into a pit, a brushed bush, a mowed crowd: they all decelerate the
body, and that deceleration *is* the damage signal. Nothing on the track "knows" it
deals damage; the car's own physics does.

`car.gd._integrate_forces` runs every physics tick. It computes:

```gdscript
dv = (_approach_velocity - state.linear_velocity).length()   # m/s shed this tick
```

`_approach_velocity` is the **pre-solve** velocity cached at the top of
`_physics_process`; `state.linear_velocity` is **post-solve**. Godot resolves
collisions (and, on a head-on hit, arrests the body) *before* `_integrate_forces`
sees the state, so a collision's full velocity loss shows up in `dv` — with **no
contact inspection**.

> **NOT skipped while the car is held.** The measurement runs unconditionally (bar the
> couple of post-teleport ticks `_suppress_impact_frames` covers) — including while the
> car is deliberately held at the line by `controls_locked` / `handbrake_locked` (see
> [stage.md](stage.md)). There was briefly an `is_held()` exemption here, because revving
> against the old velocity-cancel parking hold made the chassis jitter and creep every
> tick and `_integrate_forces` faithfully charged that as impact damage for the whole
> countdown. That was a gate over a physics bug: the hold is now a damped spring to an
> anchor point (`car.gd._apply_parking_hold`, and see
> [car-physics.md](car-physics.md) → the parking hold) so a held car is genuinely still,
> there is no spurious `dv` left to hide, and the damage rule needs no special case.
> Regression test: `test_held_car_stays_put_under_steady_disturbance` in
> `tests/headless/test_car.gd` asserts both halves at once — a held car does not creep,
> and it takes no damage while held and revving.

> **Tree plough-through feeds this for free.** The object-reaction loop runs
> *before* this measurement and, when it fells a small tree, restores some of the
> arrested forward momentum back into `state.linear_velocity` (see
> [trees.md](trees.md) → "Plough-through"). Because `dv` is read *after* that
> restore, ploughing through a small tree yields a small `dv` and therefore small
> HP loss automatically — the damage scales with tree size with no separate path.
> A full-size tree restores nothing, so `dv ≈ approach speed` as before. Gravity/engine/drag each move the velocity only ~0.1–0.3 m/s
per tick, far under threshold, so only real collisions and the soft-drag impulses
(below) produce a damaging `dv`. Using the full **vector** (not scalar speed change)
captures glancing redirects and vertical face-plants alike.

`DamageModel.register_deceleration(dv, dt, point, cfg)` turns it into HP loss:

```
# floor = impact_threshold_g · g · dt   (per-tick velocity below which nothing counts)
# above the floor, a pure square law in km/h (v = the shed velocity):
hp_loss = impact_ref_hp_loss · v² / impact_ref_speed_kmh²
```

- **Braking-proof threshold** (`impact_threshold_g`, ~2 g). Tyres/brakes cap real
  deceleration at ~1–1.5 g and suspension cushions a clean wheel-landing over several
  ticks, so those stay under the floor and cost nothing; a solid crash arrests the
  body in one tick (tens of g) and clears it easily. The small soft-drag impulses
  tip just over it for a light chip. (Trade-off: a hard flat landing or sharp kerb
  can briefly exceed 2 g and chip *minor wear* — accepted; raise `impact_threshold_g`
  if it feels twitchy.)
- **Continuity.** For a full solid arrest `dv ≈ approach speed`, so a 60 km/h head-on
  lands exactly where the old speed-keyed model did — `impact_ref_hp_loss` (390 HP in
  `game_config.tres`) and the whole square-law tuning carry over. `hp_loss_for_speed()`
  is still the pure, unit-tested static.

Two things shape survivability:
- **Per-hit cap** — each tick's loss is clamped to a flat `impact_max_loss` HP amount
  (`450` in `game_config.tres`), so no one spike can strip the whole pool. Being absolute
  rather than a fraction of max HP, a car's `max_hp` genuinely matters — a fragile car is
  flattened to 0 by fewer capped hits than a tough one, and so reaches the worst misfire
  and the lowest rev cap sooner.
- **No cooldown.** A pinned/stopped car sheds ~0 velocity/tick, so grinding against a
  wall self-limits with no timer; a genuine multi-bounce **tumble** down a tall drop
  is several real `dv` spikes and racks up several capped hits — so a long fall can
  empty the pool outright. This is intentional: drops are dangerous. What they cost is
  the rest of the rally's pace, not the rally.

A **reset/teleport** zeroes the velocity discontinuously, which would read as a huge
false `dv`; `car.gd.reset_to` sets `_suppress_impact_frames` so the next couple of
ticks skip the damage check.

A hit that costs HP emits `damaged(hp_loss, contact_point)` for the HUD/audio cue,
and **bends the wheels** (`nudge_wheels`, below).

**Object reactions stay contact-driven.** The `_integrate_forces` contact loop is
kept, but *only* to trigger reactions — trees fall (`TreeFall.should_fell`), etc. —
on their own approach-speed thresholds (they still need to know *which* object was
hit). It no longer touches HP. `OBSTACLE_GROUP` (`"obstacle"`) still tags those
collision bodies so the loop can find them.

## Wheel misalignment (`nudge_wheels`, `car.gd._apply_wheel_toe`)

A damaged car no longer pulls via a synthetic steer offset. Instead each solid
impact **permanently bends every wheel** by a random amount and direction, and the
car's pull/crab then comes from the **physics alone** — the bent wheels are rotated
on the `VehicleWheel3D` nodes themselves.

- **The nudge** (`DamageModel.nudge_wheels`, called from `register_deceleration` on a
  landed hit). For each of the four wheels: `toe += random_sign * (hp_loss/max_hp) *
  damage_wheel_toe_gain * randf(0.5,1)`, clamped to `±damage_wheel_toe_max`. The
  magnitude scales with the hit's strength (bigger crash → bigger knock); the sign
  is rolled **per wheel**, so the wheels don't all bend the same way and repeated
  hits can partly cancel — a wheel can end up near-straight again after two hits.
  `wheel_toe` is a dictionary keyed by `WHEEL_NAMES` (`WheelFL/FR/RL/RR`, the
  car.tscn node names and the stable order used to persist it).
- **Applying it physically** (`car.gd._apply_wheel_toe`). Each wheel carries its own
  `VehicleWheel3D.steering` — a physical steer angle the custom drivetrain tire model
  reads for the force direction (`drivetrain.gd`). So the toe is applied straight to
  that: **front** (steering) wheels get `steering` (the live base steer the body just
  set) **plus** their toe; **rear** wheels — which the body never steers — get only
  their toe. This runs every physics frame right after the base steer is computed, so
  it re-asserts over the body's per-frame overwrite of the front wheels. No node
  rotation and no re-parenting. Because the wheel *visual* is also rebuilt off
  `wheel.steering` (`drivetrain._update_visuals`), the bend is **visible** for free.
- **The steering servo cancels part of it, on purpose.** Since grip-servo steering
  ([car-physics.md](car-physics.md) → Steering) closes its loop on slip measured in the
  **toed** wheel's frame, the toe is inside the loop: the servo sees a bent front axle's
  lateral slip as error and corrects it — which is what a real driver does on a car with bent
  alignment, holding a correction so it tracks straight with the wheels visibly off-centre.
  Of the four contributions `nudge_wheels` creates (independent random sign each), the servo
  can only reach one:

  | Contribution | Servo authority | Outcome |
  |---|---|---|
  | Rear toe (2 wheels) | none — the front servo cannot reach it | survives fully; the car crabs and pulls |
  | Front pair bent opposite ways (~50% of cases) | ~none — it nets out of the load-weighted average | survives fully; scrub and drag |
  | Front pair bent the same way (~50%) | cancels the average | the pull goes; the **wheels sit visibly off-centre** |

  So a damaged car still crabs and scrubs, and the pull is still emergent physics with no
  synthetic steer bias — the *cue* just shifts from "the car wanders" to "the wheels are
  cocked and the rear still crabs". Do **not** try to exclude the toe from the measurement.
- **Persistence.** `wheel_toe` lives on the **OwnedCar** (a 4-float array ordered
  like `WHEEL_NAMES`), persisted at each event boundary alongside HP
  (`world.gd._on_session_event_completed` → `Save.set_wheel_toe`), so a car carries
  its bent wheels **between events**. The between-event field repair bends them back
  toward straight along with restoring some HP (`DamageModel.reset_wheel_toe` is the
  in-model equivalent of zeroing them). Older saves with no `wheel_toe` key are backfilled
  straight (`Save._sanitise`).

The solid props that arrest the car and so cost HP through the rule above are the
trees ([trees.md](trees.md)) and the **corner barriers** ([barriers.md](barriers.md)),
both tagged `OBSTACLE_GROUP` via `ObstacleBody`. Roadside signs are deliberately not
among them ([signs.md](signs.md)).

## Soft contacts — bushes & spectators (`apply_soft_drag`)

Bushes and spectators are **not** solid obstacles: a `StaticBody` would arrest the
car, the opposite of brushing through undergrowth or a crowd. So they stay
**pass-through**, but instead of a separate flat-HP path they apply a small
**speed-scaled drag impulse** to the car via `car.apply_soft_drag(strength)` —
`apply_central_impulse(-v_horiz · strength · mass)`, shedding a `strength` fraction of
horizontal speed. The resulting deceleration then feeds the **unified damage rule**
above for a light chip. Grouping is natural: a car slowed toward a stop sheds ~0 more
per tick, so ploughing a dense line doesn't wildly over-count — no soft-hit cooldown
needed.

- **Bushes** (`scripts/bush_field.gd`, `BushField`). Bushes are pure visual scatter
  (a `TreeMeshField` built `with_collision=false`), so a dedicated node does a
  per-tick **proximity query**: bush XZ positions binned into a grid (cell = hit
  radius) so only the ~handful in the car's 3×3 neighbourhood are tested. Entering a
  bush (one-shot — tracked in an "inside" set, re-arms on leave) calls
  `apply_soft_drag(bush_drag_strength)` and applies a **side-based yaw drag torque**
  via `apply_torque_impulse`: the pure `drag_torque(forward, to_bush, mag)` returns a
  torque whose sign swings the nose *toward* the bush (a snagged corner dragging back)
  and whose magnitude is `bush_drag_torque × speed × sin(angle)` (zero head-on, peaks
  side-on). The interaction radius is `bush_hit_radius_frac` (<1) of the bush's visual
  `xz_radius`, so clipping the visible edge is forgiven. Gated by `bush_min_speed_kmh`
  — a parked car in a bush isn't tugged.
- **Spectators** (`scripts/spectator_group.gd`). When a member is knocked over
  (`_knock_over`), the car takes `apply_soft_drag(spectator_drag_strength)` — a bit
  **more** than a bush. No torque.

## Effects

Both engine effects hang off **one shared ramp**, `DamageModel.damage_ramp(cfg)`: it is
`0` while health (`hp/max_hp`) is at/above `damage_misfire_health_threshold`, and ramps
linearly to `1` at 0 HP. Deriving both from the same function is deliberate — the stumble
and the lowered rev ceiling begin at the *same* moment and reach their worst *together*,
so "the car is hurt" is one readable state with two symptoms rather than two independently
tuned curves the player has to disentangle. A single knob
(`damage_misfire_health_threshold`) therefore moves the whole idea of "when damage starts
costing you", and a lightly-scuffed car runs completely clean.

Each physics tick `car.gd` feeds both derived values into the engine:

```gdscript
engine.misfire_level  = damage.misfire_level(cfg)       # ramp × damage_misfire_level_max
engine.rev_limit_scale = damage.rev_limit_fraction(cfg) # lerp 1 → damage_rev_limit_min_fraction
```

- **Engine misfire** (`DamageModel.misfire_level`) — instead of a smooth
  power derate, a damaged engine **intermittently cuts fuel**. The engine stays
  **fully healthy** while health is at/above `damage_misfire_health_threshold`; below it
  the level is `damage_ramp(cfg) × damage_misfire_level_max` — note the **cap**: it tops
  out at `damage_misfire_level_max` (0.8), *below* 1.0, on purpose. That cap is the whole
  reason a car can sit at 0 HP indefinitely: even a flattened engine keeps firing often
  enough to pull away, change gear and reach the finish, just badly. Damage weakens the
  engine **to a point and no further**.
  Inside `EngineSim.step()` a stochastic cut fires with
  probability `rate·h` per substep, where
  `rate = damage_misfire_rate_max · m · (damage_misfire_load_bias + (1-bias)·load)`
  and `load` blends throttle and rpm — so the stumble worsens with damage and under
  load, and a healthy engine (`d = 0`) never cuts. Each cut lasts a rolled
  `damage_misfire_duration_min..max`. While cut, crank torque drops to friction only
  (real power loss, fully simulated) and the same `fuel_cut` state the rev limiter
  uses ducks the synth's firing voice — so the engine audibly sputters. Unlike the
  limiter it does **not** fire the exhaust crackle (that pop is limiter-only;
  `engine_audio.gd` passes `engine.fuel_cut` to duck but only `engine.limiting` as
  the crackle trigger). The pure
  `EngineSim.misfire_rate()` is unit-testable, and a seeded per-engine RNG makes the
  cuts reproducible). This **replaces** the old `power_scale` / `damage_power_loss_max`.
  Each cut also puffs a burst of bonnet smoke — see [engine-smoke.md](engine-smoke.md).
- **Rev cap** (`DamageModel.rev_limit_fraction` → `EngineSim.rev_limit_scale`) — a damaged
  engine also **won't pull to the top end**. The fraction lerps from `1.0` (full revs) down
  to `damage_rev_limit_min_fraction` (0.6) across the same `damage_ramp`, and never reaches
  0. Every gear then runs out early, so the car is slower *everywhere*, in a way the player
  **hears** (it bounces off a lower limiter) as well as feels — a much clearer read than
  "power is down a bit" and a strictly-better cue than the old flat derate. It is a cap on
  the *limiter*, not on the engine: the torque **curve** in `EngineSim` still keys off
  `config.redline_rpm`, so the engine makes exactly the torque it always did in the rev
  range it is still allowed to use — you are just cut off earlier.

  The cap propagates through **one** accessor, `EngineSim.redline_omega()`:

  ```gdscript
  redline_omega() = maxf(config.redline_rpm * rev_limit_scale * TAU/60,
                         idle_omega() * MIN_REDLINE_IDLE_RATIO)
  ```

  Every consumer reads *that* rather than `config.redline_rpm`, so they all move down
  together: the **rev limiter** (`_update_limiter`, and so the `limiting` / `fuel_cut`
  state the audio and exhaust flames key off), the **clutch engagement** gate on the
  gearbox input's over-rev, the **crank clamp** (`omega` is clamped between `idle_omega()`
  and just above the capped redline), and the automatic gearbox's **upshift airspeeds**.
  The shift points are precomputed, not read per-tick, which is why `rev_limit_scale` is a
  **setter** (clamped to `[0.05, 1.0]`) that calls `_compute_shift_speeds()` whenever the
  value actually moves — otherwise the auto box would hold a gear the engine can no longer
  pull to and just sit bouncing off the lowered limiter. See
  [engine-and-transmission.md](engine-and-transmission.md).

  `MIN_REDLINE_IDLE_RATIO` (1.5) floors the capped redline at 1.5× idle. That floor is the
  second half of the never-strand guarantee: even with the fraction tuned to its minimum,
  the engine keeps a usable rev range above idle instead of sitting on its own idle clamp
  with nowhere to go.
- **Wheel misalignment** — the car's pull/crab is NOT a damage-fraction effect: it
  comes from the accumulated per-wheel `wheel_toe` applied to the physical wheels
  (see *Wheel misalignment* above). It persists between events and is eased back only
  by the between-event field repair, independent of HP.

## 0 HP is a STATE, not an event

`apply_loss()` is the whole of it:

```gdscript
func apply_loss(amount: float) -> void:
	if not enabled:
		return
	hp = maxf(0.0, hp - amount)
```

Nothing is signalled. There is no `wrecked` signal on `DamageModel`, none on `car.gd`,
nothing listening in `world.gd`, and no code path anywhere that reacts to the moment HP
touches zero. A car at 0 HP is simply a car whose `damage_ramp` has saturated: worst
misfire (capped at `damage_misfire_level_max`), lowest rev cap
(`damage_rev_limit_min_fraction`, floored by `MIN_REDLINE_IDLE_RATIO`), whatever wheel toe
it has accumulated — and it drives. It stays in the garage with its upgrades fitted (parts
are consumed on fit, so they were never returned in the first place), it can be raced again
immediately, and the free between-event repair lifts it back off the floor without the
player spending anything.

That "state, not event" framing is what let the whole wreck layer be deleted rather than
merely made survivable. An event needs a handler, and every handler needed a policy: what
does a fielded car do, what does an unbound free-roam car do, what does the menu show, what
does the session report. A state needs none of that — the existing per-tick read of
`misfire_level` / `rev_limit_fraction` already covers 0 HP, because 0 HP is just the end of
a ramp it was already sampling.

**Fielded vs. free-roam is no longer a distinction here.** A bound car (`instance_id >= 0`)
persists its HP back at each event boundary via `Save.apply_damage`, which now also clamps
at 0 (`hp = maxf(0.0, hp - amount)`) — no write-off, no wreck record, nothing a repair
can't undo. An unbound car simply never touches the save. Neither branch does anything
*else* at 0 HP; the old free-roam special case, where `car.gd._on_wrecked` healed the car
to full and teleported it back to the spawn, is gone with the signal that drove it. Free
roam now behaves like everywhere else: you keep driving the car you damaged.

Every car — including the starter — takes damage the same way, and none of them can be
lost. **There is no anti-soft-lock machinery, because nothing can strand a player**: a car
at 0 HP is still a drivable car, and HP climbs back via the free between-event field repair
and the paid repair at the lift. `Save.wreck_car`, `car_is_wrecked`, `all_cars_wrecked`,
`ensure_wreck_safety_net` and the free rescue car that existed to dig the player out are
all retired — see [reward-system.md](reward-system.md).

### Nothing DNFs the player any more

`RallySession.report_wreck()` and `ChallengeSession.report_wreck()` / `_end_as_dnf()` are
gone, so **the player cannot DNF a rally or a challenge through damage** — see
[rally-session.md](rally-session.md) and [rally-challenge.md](rally-challenge.md). The
`_dnf` flag survives in both: **rivals** still DNF an event, the standings/result contract
still carries a `dnf` field, and a persisted challenge run still reads one back. Only the
player's own route to it was removed. The `"WRECKED"` labels the UI shows (rally detail,
the overworld picker) key off `hp == 0` or a rival's `dnf` flag and still render correctly
for both.

## Between-event pit repairs (`Save.field_repair`)

A rally is a campaign of `EVENTS_PER_RALLY` events run back-to-back on one fielded
car (see [rally-session.md](rally-session.md)). At the **start of every event after
the first**, the engineers patch the car up a bit — a free, automatic partial
repair, and the ONLY way HP is ever restored:

- **Health:** restore `field_repair_hp_fraction` (default `0.2`) of the HP **lost so
  far** — a car at 50% comes back to 60% (20% of the missing 50%), one at 90% to 92%.
  Never exceeds `max_hp`.
- **Wheel alignment:** bend every wheel `field_repair_toe_fraction` (default `0.5`)
  back toward straight — a wheel bent 4° comes back to 2°. Deliberately more generous
  than the HP patch so alignment recovers faster across a rally. Each wheel keeps its
  sign; a fully-bent car straightens out over the events.

`RallySession._enter_event()` calls `Save.field_repair(instance_id, hp_fraction,
toe_fraction)` for `_event_index >= 1` **before the per-event scene reload**, so the
freshly-loaded run scene fields the already-repaired car. `field_repair` returns a
summary (`{repaired, hp_before, hp_after, max_hp, hp_gained}`) stashed on the session
and read once via `take_pending_repair()`. It reports `repaired: false` — and writes
nothing — for a pristine car (full HP, straight wheels), the only case where there is
nothing to do. A car at **0 HP** is repaired like any other, and in fact gains the most:
`lost` is the full pool, so it comes back off the floor and out of the worst of the
misfire/rev cap without the player spending a star. The summary drives a **`RepairReveal`** popup (`scripts/
repair_reveal.gd`): a dismissable modal ("Pit Repairs Complete", health **+N HP**,
Continue) that `world.gd._show_repair_popup()` shows once the
loading overlay is gone (staged runs keep it up until the start-line queue is laid
out, so the popup is shown AFTER `_build_start_line()` / `loading.finish()`, sitting
over the ready start-line reveal rather than a frozen loading screen). The popup only
appears when the repair moved health by **at least `RepairReveal.MIN_SHOW_GAIN_PCT`
percentage points** (2, via `RepairReveal.worth_showing`) — a smaller touch-up (e.g.
wheels-only on a near-full car) still applies to the save but doesn't interrupt the
player. The card and the gate read the **same** number — `health_gain_pct`, percentage
points of `max_hp` — so the figure on screen is the one that decided whether to show the
popup at all. Proportional is the right unit: a repair's worth is how much of the car it
fixed, and 20 HP means very different things on a fragile car and a heavy one; the rest of
the UI already talks in health percent. (`health_gain_hp` still exists as a pure helper and
is tested, but nothing displays it.) Headless runs drain the summary without building the
popup.

Without a stage AFTER it, the final event of a rally would never get this courtesy
repair — `_enter_event()` only ever runs again for a NEXT event, and there is no
next event after the last one, so damage taken on the final stage would otherwise
carry forward untouched into whatever the player drives next (the next rally, free
roam, etc.). `RallySession._resolve_results()` closes that gap: it also calls the
same repair (`RallySession._apply_field_repair()`, the shared helper both call sites
now use) for the just-finished car, with the identical `field_repair_hp_fraction`/
`field_repair_toe_fraction` fractions. Unlike the between-event repair, this one is
applied **silently** — the summary is discarded rather than stashed for
`take_pending_repair()`, so it never fights with the podium flow's own
UI for the player's attention.

## HP is NOT a damage oracle — ask `RallySession.took_damage_this_rally()`

**Never derive "did the player take damage this rally" from the car's HP.** It is
wrong in *both* directions:

- **A crashed car can read pristine.** The between-event repair above runs at every
  stage boundary, and `_resolve_results()` runs one more on its **first lines**,
  before a single line of reward logic. By the time anything at resolve time reads
  `hp`, this rally's damage has already been partly healed.
- **A clean run can read damaged.** Cars routinely *start* a rally below `max_hp`,
  because repairing at HQ costs stars (see [star-economy.md](star-economy.md) →
  *Repairs*). `hp < max_hp` at the finish may be damage the player brought with
  them; `hp >= max_hp` is simply unreachable for such a car however flawlessly they
  drove.

So `RallySession` **latches the fact instead**, in `_took_damage_this_rally`:

- set the moment any event reports `hp_lost > 0` (`report_event_result`) — now the ONLY
  place it is latched, since `report_wreck` (the one path that bypassed
  `report_event_result`) no longer exists;
- latched off whether damage *happened*, not whether it could be persisted — an
  unbound car with no save slot still took the hit;
- cleared only in `start_rally`, so it survives every repair to resolve time and is
  still readable during the finish beat;
- read via **`RallySession.took_damage_this_rally()`**, and carried on the
  `rally_finished` result as **`took_damage`**.

That flag is the clean-run signal any reward should use.

## In-run HUD (see [hud.md](hud.md))

`hud.gd` reads `car.damage` each frame: a colour-graded **health gauge** (`HPGauge`,
a `HudGauge` radial ring, green → amber → red) whose fill fraction is `hp / max_hp`,
with a cross **icon** (`GaugeIcons.Kind.HEALTH`) sitting in the ring's hole rather
than a text caption — no absolute HP number, which was redundant beside a gauge
showing the same thing; a low-health **warning pulse** below `hud_low_hp_warn_frac`,
riding on the fill's alpha; and a red **impact flash** (`ImpactFlash`) sized to each
HP-losing hit. Because the icon is drawn separately from the fill, the pulse never
tints it. The gauge is hidden when `hud_hp_enabled` is off. Because there is no
longer a number to round, the old "reserve `0` for a genuine wreck" rounding rule is
gone with it — and there is no wreck to reserve it for anyway: an empty ring is a
legitimate, drivable, permanent reading. A **boost gauge**
sits to its left and a **nitrous gauge** to its right, built the same way — see
[hud.md](hud.md).

## Config knobs (`GameConfig`, *Damage* group)

`impact_threshold_g` (the braking-proof deceleration gate — the single sensitivity
knob), `impact_ref_speed_kmh`, `impact_ref_hp_loss`,
`impact_max_loss`, `damage_misfire_health_threshold` (where BOTH engine effects start —
the shared `damage_ramp`), `damage_misfire_level_max` (worst misfire intensity at 0 HP —
the "certain point" past which damage stops weakening the engine),
`damage_rev_limit_min_fraction` (fraction of redline still usable at 0 HP),
`damage_misfire_rate_max`,
`damage_misfire_load_bias`, `damage_misfire_duration_min`, `damage_misfire_duration_max`,
`damage_wheel_toe_gain`, `damage_wheel_toe_max`, the between-event pit repair
(`field_repair_hp_fraction`, `field_repair_toe_fraction`), soft contacts
(`bush_drag_strength`, `bush_drag_torque`, `bush_min_speed_kmh`, `bush_hit_radius_frac`,
`spectator_drag_strength`), `hud_hp_enabled`, `hud_low_hp_warn_frac`.
`wreck_recovery_hp_fraction` and `wreck_settle_max_seconds` were **removed** with the
wreck flow. `config/game_config.tres` overrides neither of the two new knobs, so their
`game_config.gd` defaults (0.8 and 0.6) are what ships. Per-car `max_hp` is CarLibrary
metadata, **not** a `GameConfig` field. The between-event pit repair is the only heal there is, tuned by
the two `field_repair_*` fractions.
Tuning numbers are placeholders pending playtest (the mechanism is fixed, the
values are not).

## Tests

`tests/headless/test_damage_model.gd` (the square-law `hp_loss_for_speed`, **unified
deceleration damage** — below-threshold braking costs nothing, above-threshold costs
HP & emits, a full arrest matches the capped square law, the per-hit cap can't empty the
pool in one go, a stopped car self-limits without a cooldown, repeated spikes accumulate
down to 0 HP, a soft-drag-magnitude deceleration deals a small chip — the
**damage fraction** tracking HP, **wheel toe** (a hit bends every wheel within the
clamp, a zero-strength hit is a no-op, toe stays clamped over many hits, `field`
loads persisted toe, repair straightens), **HP floors at 0 without signalling anything**
for a bound and an unbound model alike (the car keeps its upgrades and its save row),
persistence round-trip, the shared **`damage_ramp`** — 0 above the health threshold,
ramping to 1 at 0 HP — and the two effects derived from it: **`misfire_level`** capped at
`damage_misfire_level_max` (strictly < 1 at 0 HP, which is what keeps the car drivable)
and **`rev_limit_fraction`** falling from 1.0 to `damage_rev_limit_min_fraction` and never
to 0), `test_engine_logic.gd` (**misfire**:
the pure `misfire_rate` is 0 when healthy / positive & load-rising under damage, a
healthy engine never cuts over many steps, a damaged one cuts intermittently, and a
forced cut kills crank torque; **rev cap**: `rev_limit_scale` scales `redline_omega()`,
the `MIN_REDLINE_IDLE_RATIO` floor holds at the lowest scale, and setting it recomputes
the auto box's upshift speeds), `test_save_manager.gd` (`wheel_toe`
round-trips through save/reload, a full-fraction field repair straightens the wheels,
old saves backfill straight, **`field_repair`** restores the given fraction of lost HP, bends
each wheel the given fraction back toward straight, and skips a pristine car;
**`apply_damage` clamps at 0** rather than writing the car off), `test_rally_session.gd` (the **between-event pit repair**
fires entering every event after the first, never the first, and its summary is
consumed once), `test_car.gd` (bent front wheels **veer the car through the
physics alone**, `engine.misfire_level` tracks the damage fraction), `test_bush_field.gd` (side-based `drag_torque` sign +
scaling, enter/leave one-shot **soft drag**, min-speed gate), `test_spectator_damage.gd` (a
knockdown applies **soft drag** to the car), `test_car.gd` (contact monitor
wiring, plus a **head-on collision costs HP** regression that drives the car into
an obstacle to guard the approach-speed keying above), `test_hud.gd` (health gauge).

There is no wreck-screen test because there is no wreck screen; `test_wreck_site_gate.gd`
is about the **roadside opponent wreck** prop ([opponent-wrecks.md](opponent-wrecks.md)),
an unrelated feature that is untouched by any of the above.
