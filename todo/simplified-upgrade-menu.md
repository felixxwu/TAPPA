# Simplified upgrade menu

**Goal:** someone with no car knowledge opens the upgrades page and leaves with a
build that is *competitive and legal*, without learning what a supercharger,
ballast or a detune slider is. Today's page is preserved verbatim behind an
**Advanced** button.

**Status:** spec, not implemented. Brainstormed and steered by the user; every open
question from that discussion is settled and recorded in §9 — including the
ballast/detune ordering, resolved in favour of demoting ballast out of Auto
altogether (§4).

**Depends on:** nothing unbuilt. Every solver input already ships (see
"The solver already exists"). Touches `features/upgrade-catalogue.md`,
`features/menus.md`, `features/tuning.md` and `features/drivetrain-and-tires.md`
when it lands.

---

## 1. The problem, concretely

The HQ lift → Upgrades page (`scripts/upgrades_menu.gd`, `class_name UpgradesMenu`)
for a mid-game car renders roughly:

```
Turbo          Stock  [Small]  Big (2★)  Supercharger (2★)
Aero           [Stock]  Aero Kit (2★)
Weight         +500kg  +200kg  [Stock]  -200kg (2★)
Drivetrain:    [RWD]  AWD  FWD
Nitrous        [Stock]  Nitrous (2★)
Engine: Inline-4 2.0                    [Swap Engine (1 token)]
Engine detune  0% ————————●  100%              227 HP/T
```

Every label is a **part name or a mechanism**, never an outcome. The page carries
exactly one number — `227 HP/T`, on a slider's value label
(`UpgradesMenu._detune_label_text`).

Three rows are worse than opaque — they are **trap-shaped**, because the naive
reading is the wrong one:

1. **Ballast is a free downgrade.** `ballast_large` / `ballast_small` carry
   `free: true` (`UpgradeLibrary.is_free`), so they are always selectable on every
   car at no star cost, and `_make_weight_selector` renders them as plain enabled
   options labelled `+500kg` / `+200kg`. A newcomer reads "free, therefore take
   it". Their actual purpose is the expert move of dropping power-to-weight to
   duck a rally's `pw_max`.
2. **Detune is the same trap mirrored.** It defaults to 100% and the only reason
   to ever move it is downward. A slider sitting at maximum with no explanation
   reads as a difficulty or smoothness setting.
3. **FWD/RWD/AWD is pure jargon with two separate consequences** — handling, and
   rally eligibility (`restriction.drive_mode`, e.g. the RWD-only rally in
   `RallyLibrary`). Nothing tells the player AWD is the forgiving one.

Plus: buying is an irreversible star spend (`_buy_slot_option` → `Save.buy_part`)
with **no preview**. Press, 2★ gone, and the only visible change is that one
slider label.

## 2. The solver already exists

Auto-Upgrade is a thin wrapper over shipped, tested code rather than a new pile of
heuristics:

- **`UpgradeLibrary._best_part_per_slot`** already picks the best part in each
  slot, and its own comment establishes *why that is exact rather than greedy*:
  `Save._enable_exclusive` permits one enabled part per slot, and slot effects are
  independent (turbo → torque, weight → mass, aero → downforce, drivetrain → a
  flag, nitrous → excluded from p/w entirely). Scoring each candidate alone is the
  whole answer.
- **`RallyLibrary.qualifying_detune(rally, full_meta)`** already solves "what
  detune setting makes this car legal", floored to the slider's whole-percent
  steps so the answer round-trips through the UI, and verifies itself back through
  `is_eligible`.
- **`UpgradeLibrary.max_potential_meta(owned, meta, profile)`** already computes a
  car's ceiling in two flavours — aspirational (`{}`) and reachable (a profile,
  filtering on `rally_gate_met`). The **reachable** flavour is the right one for a
  Simple-page headroom bar: it promises only what this player can actually get.
- **Pricing is flat** — `GameConfig.star_cost_per_part` (currently 2), one price
  for every part, via `Save.part_price`.

That last point has a consequence worth stating on the button. Budgeted
part-picking would normally be a knapsack, but every slot's effect on p/w is a
**multiplier** and the price is **uniform**, so "buy the *k* largest multipliers
you can afford" is **exactly optimal**, not an approximation. Auto-Upgrade can
honestly claim to produce the best build the balance allows.

## 3. The Simple page

**Simple is the page everyone gets** (settled: no per-profile preference flag, no
"first visit only" — one page for all players). It holds three things.

### 3a. A stat block in outcomes, not part names

| Row | Source | Notes |
|---|---|---|
| **Speed** | `CarLibrary.power_to_weight_hp_tonne(effective_meta)` | Already *the* figure eligibility is judged on (`RallyLibrary.ineligibility_reason`, `UpgradesMenu.over_pw_limit`) — no new maths, and it cannot disagree with the gate |
| **Grip** | `CarLibrary.max_lateral_g(meta, cfg)`, extended for aero — see §5 | Already exists and is already shown on car-select (`features/drivetrain-and-tires.md`) |
| **Condition** | `hp / max_hp` | Already computed in `hq._car_stats_text` |
| **Stability** | `drive_mode` + `weight_front` | Deliberately a **word**, not a bar — "Forgiving / Balanced / Twitchy". It has no single honest scalar, and a bar would imply a precision that isn't there |

**Bars are normalised against the car's own reachable ceiling** —
`max_potential_meta(owned, entry, Save.profile)` — with the filled segment as
"now" and a ghosted segment as "headroom you can still buy". That reads as "how
much of this car have you unlocked", needs no rally context, and reuses shipped
code.

**When the host passed a `pw_limit`, overlay the rally's legal band on the Speed
bar** (`restriction.pw_min`..`pw_max`). The plumbing already exists as
`UpgradesMenu._pw_limit`, set by the start line (`start_line.gd:984`), the
car-park over-power popup and the reward reveal (`upgrade_reveal.gd:274`). This is
the single most useful thing on the page in those three contexts, because it turns
"227 HP/T" into "inside the band / over the line".

### 3b. `Auto-Upgrade (6★)` — price on the button, two presses to commit

**Second press required** (settled). First press previews: before/after bars, the
parts it will buy by name, the resulting hp/t, and the total cost. Second press
commits. It spends stars irreversibly, so it never fires on one press.

It must **not** spend the whole balance by default — it buys only parts that
improve the objective below, so a car already at its reachable ceiling costs 0★
and the button says so rather than inventing something to sell.

### 3c. `Advanced ▸`

Opens today's `UpgradesMenu`, unchanged.

## 4. Auto-Upgrade's objective

The objective changes by host, and this is the load-bearing part of the design.

### Unconstrained (HQ lift, no `pw_limit`)

Maximise p/w within the star balance: buy and enable the best affordable part per
slot, strip any ballast the player left on (it's `free`, always removable), return
detune to 100%.

### Constrained (`pw_limit` set — start line, car-park popup, reward reveal)

Maximise p/w **subject to ≤ pw_max**, reducing power via a fixed lever ladder
(settled by the user; ballast **demoted** behind detune — see below):

1. **Remove power upgrades first** — but only the *minimum* needed. Never strip a
   part whose removal drops p/w **below** pw_max, because detune cannot trim
   upward and the headroom would be lost for nothing. Formally: choose the part
   set with the **smallest p/w that is still ≥ pw_max**, so step 2 has the least
   work to do and the car keeps as much of itself as possible.
2. **Then detune, as the final fine trim** — `qualifying_detune` to land exactly
   on the requirement, not as the sole lever dragged down to hit it.
3. ~~Then add ballast~~ — **unreachable, and deliberately so.** See below.

Stripping before detuning is right for two reasons beyond the user's preference:
a stripped part is free, reversible and **visible** on its row, whereas a car left
at 62% detune forever is an invisible permanent handicap — precisely the
confusion this redesign exists to remove — and a supercharger bought for 2★ then
detuned to 60% is money spent for nothing.

### Auto never fits ballast

Ballast sat between stripping and detuning in the first draft and has been
**demoted behind detune**. The reason is physical rather than stylistic:
`GameConfig.tire_load_factor` is load-**sensitive** — `(tire_ref_pressure /
(normal_force / width)) ^ tire_load_sensitivity` — so μ *falls* as mass rises.
Ballast buys its p/w reduction by also destroying cornering grip, while detune
buys the same reduction for free. Worked on a ~1058 kg car at today's tunables:

| Lever to reach the same p/w | Lateral grip |
|---|---|
| Detune only | 0.91 G (unchanged) |
| `+200kg` ballast | 0.89 G (−2%) |
| `+500kg` ballast | 0.87 G (−4.5%) |

And the displayed penalty **understates** the real one: mass also costs braking
distance, rotational inertia and jump landings, none of which `max_lateral_g`
models. Since final p/w is pinned to pw_max either way, ballast-before-detune was
strictly slower on stage for no gain.

**Demoting it removes it entirely, and that is the intended outcome.** Steps 1+2
can *always* satisfy a pw_max on their own — detune scales torque linearly toward
zero, so `qualifying_detune` only ever returns -1.0 for a failure detune can't fix
(a non-power restriction field), never for a pw_max. So nothing ever falls through
to step 3, and the constrained ladder is effectively two rungs. **Auto therefore
never fits ballast on any car, in either mode.**

This lines the solver up with `UpgradeLibrary._best_part_per_slot`, which already
skips every candidate whose `mass_mult > 1.0` on the same reasoning — ballast is
`free` and always removable, so it can never be part of a ceiling.

**Auto does still REMOVE ballast the player left on**, in every mode: it is almost
always either a mistake (it reads as a free upgrade — §1) or a stale leftover from
a lower class, and stripping it is free and reversible. Ballast stays fully
available by hand on the Advanced page, which is where a deliberate p/w lever
belongs.

Stripping raises p/w, so it can break a `pw_max` that the ballast was satisfying.
That is not a reason to keep it: **strip the ballast and let step 2 detune back
under the cap instead.** Same final p/w, strictly more grip, per the table above.

The one thing that could revive step 3 is a **detune floor** — a rule that Auto
won't cut torque below, say, 50%, on the grounds that a car needing a deeper cut
than that is undriveable and ballast at least preserves throttle response. **Not
specified, and not recommended:** at that extreme the honest message is the one
below — wrong car for this class — not a quietly worse build.

### Free-only restore — the Start gate

A third mode of the same solver, for the case where a player enters a rally
**without using the upgrades they already own** — the motivating example being a
detune left down from a previous rally that they forgot to bring back up.

**Permitted actions (all free, no star spend):**

- enable an owned-but-disabled part (`Save.set_upgrade_enabled`)
- raise detune back toward 100%
- strip ballast, compensating with detune if that breaks the cap (see above)

**Forbidden:** buying anything. This must be an explicit `free_only` flag on the
solver, **not** a `stars = 0` call — `GameConfig.star_cost_per_part` is
`@export_range(0, 30)`, so a designer setting it to 0 would silently turn a
"free-only" restore into a shopping spree.

**It only ever moves power UP** (or sideways, trading ballast for detune at equal
p/w), never down, and never above the rally's `pw_max`. Making an *over*-limit car
legal stays the existing "Too powerful" prompt's job — that gate is a deliberate
decision point, and this one must not quietly bypass it. Under-utilisation and
over-power are separate problems with separate gates.

**Predicate: the free plan differs from the current build.** Not a p/w comparison
— that would miss the ballast-for-detune swap, which lands identical p/w with
measurably more grip (§4's table). "The plan is a no-op" is the simpler and
strictly more complete test.

**It fires automatically, and this has precedent.** `hq._on_start_pressed` already
auto-applies a free qualifying fix on Start — the `_drivetrain_needed` switch,
applied before the detune math and before the over-limit check. The free restore
slots in as a sibling rung, running first so the over-limit check judges the final
build.

**But it must be announced.** The drivetrain switch can be silent because it is
temporary; this one is **permanent**, so the player is told in one line, in outcome
words ("Restored full power — 227 HP/T"). No extra press: the two-press rule in §3b
exists to guard an irreversible *star spend*, and this spends nothing.

Permanent rather than reverted, unlike the drivetrain switch, because the two are
undoing different things. A drivetrain override is a deliberate identity choice
that belongs to the car, so a rally-specific switch is reverted to leave it intact
(`RallySession.register_drivetrain_revert` → `_reset_to_idle`). A detune left down
from a previous event is *stale state*: reverting it would leave the tuning lift
showing a permanently detuned car while races quietly ran at full power, which is a
worse confusion than the one being fixed.

> If you'd rather it were temporary, the machinery is already built and tested but
> dormant: `RallySession.register_detune_revert` has no caller today (documented as
> such in `features/engine-swap.md`, exercised by `test_rally_session.gd`). Wiring
> it would be a few lines.

### What Auto must not pretend to fix

Of the non-power restriction fields (`drive_mode`, `country`, `car_type`,
`doors_min`/`doors_max`, `cylinders_*`, `engine_*_l` — see
`RallyLibrary.ineligibility_reason`), Auto can fix exactly **one**: `drive_mode`,
via the drivetrain kit's override (`Save.set_drivetrain_override`). The rest are
car identity. For those, Auto reports "wrong car for this class", never "wrong
build" — a solver that silently fails to fix an unfixable thing is worse than one
that names it.

## 5. Aero's grip contribution — the reference speed

Settled: show an estimate of the grip aero adds, at a stated average speed.

`CarLibrary.max_lateral_g` today is a **static-load** figure — it deliberately
ignores downforce and the `grip_balance` slider, so fitting the aero kit currently
moves nothing on a Grip bar. Extend it with an optional speed:

```
max_lateral_g(entry, cfg, speed_kmh := 0.0)
```

At `0.0` it returns exactly today's figure (no behaviour change for the existing
car-select caller). Above 0 it adds each axle's downforce to that axle's normal
load before taking `tire_load_factor`, then reports
`Σ(μ_axle · load_axle) / (mass · g)` in G. Downforce is authored in **N per
(m/s)²** per axle (`CarLibrary`'s field comment), applied in
`car.gd::_apply_aero` as `v² · downforce_front` / `_rear`; the aero kit adds
`+3` to each (`upgrade_library.gd` → `aero` effect).

**Reference speed: 50 km/h.** Justification, and why it needs stating on screen:
`GameConfig.speed_lines_full_kmh` is 78 with the authored note that *"~80 km/h is
realistically flat out in this game"*, so 50 km/h is about two-thirds of top
speed — a fast corner rather than a straight, which is where lateral grip actually
decides a stage, and a fair read of "average". It is also the **conservative**
choice, because the effect grows with v²:

| Speed | Aero-kit grip gain (~1058 kg car, today's tunables) |
|---|---|
| 50 km/h | 0.91 G → 1.00 G (**+10%**) |
| 80 km/h | 0.91 G → 1.14 G (+25%) |

So the Grip row should read something like
`Grip  0.91 G  →  1.00 G with aero (at 50 km/h)`, with the speed always shown —
quoting a speed-dependent figure without its speed is the kind of number that
reads as a promise.

Every figure in this section is worked from **current tunables**
(`tire_load_sensitivity` 0.12, `tire_ref_pressure` 14000, aero `+3`) and is
illustrative only. Per `CLAUDE.md` none of it gets pinned in a test.

## 6. Implementation seam

`UpgradesMenu` is mounted by **four** hosts, all through the same small interface:
`setup(owned, on_change, on_swap, pw_limit)`, `bind_close_button(button,
on_close)`, `first_control()`, `request_close` / `can_close`.

- HQ lift — `hq_overlays.gd:351`, `hq.gd:2708`
- Start line — `start_line.gd:984-986`
- Reward reveal — `upgrade_reveal.gd:274-279`
- Car-park over-power popup — `hq.gd`, `_upgrades_popup_done`

So: **leave `UpgradesMenu` completely untouched** and add the Simple page as a
sibling component (`UpgradesSimple`) exposing that **same interface**. Hosts then
change by one word (the class they instantiate), the gated-close machinery
(`bind_close_button` / `over_pw_limit`) is reused rather than reimplemented, and
Advanced is free — `UpgradesSimple` instantiates an `UpgradesMenu` internally as
its sub-page, forwarding `pw_limit` so the red over-limit gate still works in
there.

`UpgradesSimple.can_close()` must delegate to the same p/w check, or a player
could escape the start-line cap through the Simple page.

### The Start-gate hook (free restore)

The free restore needs a rung in **three** start paths:

- `hq._on_start_pressed` — the career path, inserted **before** the
  `_detune_needed` over-limit check, next to the existing `_drivetrain_needed`
  auto-switch it mirrors
- the same function's `CarparkMode.CHALLENGE` branch, which has its own
  over-limit gate (the Rally Challenge's synthetic `pw_max` comes from
  `world.gd::_build_start_line`)
- `start_line.gd`'s Start button (`_start_button`, `_pw_limit()`)

`todo/backlog.md` already flags the detune-to-enter flow as duplicated across
`hq.gd` and `start_line.gd`, deliberately un-consolidated because the two flows
differ materially. **Do not widen that duplication:** the predicate and the plan
both live in the pure solver, so each host contributes only a call plus its own
notice. Three call sites of one function is fine; three copies of the rule is not.

The same plan should also surface on the Simple page as a `Restore (0★)`
affordance, for a player who visits the lift before racing.

## 7. Sequencing

Front-loads the value, so a slip still ships something useful:

1. **Pure solver in `UpgradeLibrary`** — `auto_build_plan(owned_car, meta,
   profile, stars, pw_limit, free_only := false) -> {buy, enable, strip, detune,
   cost}`. No scene, no UI, pure over its inputs like `max_potential_meta`
   already is. Cheap headless tests.
2. **The free restore at the Start gate** (§4 → "Free-only restore"). Same
   solver with `free_only = true`, three call sites, no new UI beyond a one-line
   notice. Independently valuable — it fixes the forgot-to-restore-the-detune
   trap on its own, for players who never open the upgrades page at all.
3. **Wire the solver to a single Auto-Upgrade button on the existing page.**
   Shippable alone — most of the newcomer benefit for a fraction of the UI work.
4. **Then** the Simple stat block, the aero-aware `max_lateral_g`, and the
   Advanced toggle.

Steps 1–2 are worth doing first regardless of whether the Simple page ever lands:
they need no new UI surface and they close the specific trap that prompted this
addition.

## 8. Tests

Per `CLAUDE.md`: logic only, no pinned tunables, synthetic fixtures over
`CarFixtures.install()` / `upgrade_fixtures.gd` rather than real catalogue entries.

Solver (`tests/headless/`, bare logic, no scene):

- a plan never includes an undiscovered part (`rally_gate_met` false)
- a plan never breaks the prerequisite ladder (`requires_upgrade_id` unmet)
- a plan never costs more than the passed balance
- with a `pw_limit`, the resulting build is **never over** it
- with a `pw_limit`, the plan does **not** strip a part whose removal would drop
  p/w below the limit (the no-needless-undershoot rule, §4 step 1)
- detune is only ever the final trim — a plan that reached the limit by stripping
  alone leaves detune at 1.0
- **a plan never fits ballast** — no `is_free` mass-adding part ever appears in
  `buy`/`enable`, at any `pw_limit`, including one so low that only a deep detune
  can reach it (§4 → "Auto never fits ballast")
- **a plan strips ballast the player left on**, in both the constrained and
  unconstrained modes
- a car already at its reachable ceiling yields an empty plan costing 0
- an unfixable restriction (`car_type` mismatch) yields "wrong car", not a plan
- `max_lateral_g(entry, cfg, 0.0)` equals the pre-change value (regression guard
  for the existing car-select caller); a positive speed returns a *higher* figure
  when downforce is non-zero, and an unchanged one when it is zero

Free-only mode (§4 → "Free-only restore"):

- `free_only` buys **nothing**, and specifically buys nothing when
  `star_cost_per_part` is 0 (the flag is not a budget check)
- a detune left below 1.0 is raised back — to 1.0 with no limit, or to
  `qualifying_detune` under one, never above the cap
- an owned-but-disabled part gets enabled when doing so stays legal
- it **never reduces** p/w below the player's current setting: an over-limit car
  yields a no-op plan, leaving the existing "Too powerful" prompt to handle it
- the predicate is plan-difference, not p/w difference — a car whose only
  available improvement is swapping ballast for detune (identical p/w, more grip)
  is still reported as improvable
- a fully-utilised car yields a no-op plan, so the gate stays quiet

Menu (`test_menu_flow.gd`): Simple page mounts in all four hosts; **Advanced round
trips** back to Simple; `can_close()` is still refused while over a `pw_limit`;
Auto-Upgrade needs **two** presses to spend (one press changes no balance).

Start gate (`test_menu_flow.gd`, and `test_rally_session.gd` for the persistence
half): pressing Start on a car with a stale detune **restores it and launches** in
one press; the restore **persists** after the rally ends (it is not registered for
revert, unlike the drivetrain switch); Start on a fully-utilised car launches with
no notice and no edit; Start on an over-limit car still reaches the "Too powerful"
prompt rather than being silently detuned into legality.

**Nav (mandatory, `CLAUDE.md`):** the Simple page is keyboard + gamepad navigable
via `MenuNav.attach`, with a nav test. This should be *easier* than today's page —
the current rows are wrapping `HFlowContainer`s with 4+ buttons, and
`_tighten_option_padding` documents them already fighting for width at 4:3, versus
2–3 focusables on Simple.

## 9. Settled decisions

- **Simple is for everyone** — no preference flag, no first-visit-only behaviour.
- **Auto detunes**, but only as the final fine trim: strip power parts (the
  minimum needed, never undershooting) → detune to hit the requirement exactly.
- **Ballast is demoted behind detune, which removes it from Auto entirely** —
  steps 1+2 always suffice, so nothing reaches it. Auto never *fits* ballast but
  does *strip* it; it stays available by hand on Advanced. Rationale and the grip
  numbers in §4 → "Auto never fits ballast".
- **Auto requires a second press** to spend stars.
- **A free-only restore runs automatically at the Start gate** when the player is
  not using upgrades they already own (the forgotten detune). Announced, one press,
  permanent, never spends stars, never moves power down, never above `pw_max` —
  §4 → "Free-only restore".
- **Grip shows aero's contribution** at a stated 50 km/h.
- **The Tuning page is left alone** — neutral is already a safe default, so it is
  not a trap in the way ballast and detune are.
