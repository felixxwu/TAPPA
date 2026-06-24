# Damage Model — implementation spec

> Status: **planned, not yet implemented.** Implementation brief for the per-car
> HP / attrition system in `gameplay.md` › *Damage model* — the roguelike
> "every car is a depreciating asset" pull. Follow the config-first convention
> (`CLAUDE.md`): every magnitude (HP-per-impact, power-loss curve, steer-bias
> ceiling) is a `GameConfig` tunable, never hardcoded. Update the relevant
> `features/*.md` doc and add tests in the same piece of work.
>
> **Exact tuning numbers are deferred to playtesting** (`gameplay.md` says so).
> This spec fixes the *mechanism and where each value lives*, not the values.

## Goal

Give each fielded car a depleting HP pool, drain it from impacts during a run,
degrade the car's handling/power as HP falls, and **wreck** it at 0 (rally DNF +
the car destroyed, its upgrades returned to inventory). HP **persists** across
events and rallies and only ever goes down — except via a repair-kit item.

## Current state (measured from the code)

- **The car is a `VehicleBody3D`** (`car.gd:1`) — a `RigidBody3D` subclass, so
  **contact monitoring is available** (`contact_monitor` + `max_contacts_reported`,
  and `_integrate_forces(state)` exposes per-contact impulses). Today the car
  enables **none** of this; there is no collision-response code at all.
- **Impact sources already have collision.** Trees/bushes are built as a
  `StaticBody3D` by `BillboardField.build()` and the planned signs are
  `StaticBody3D` + `BoxShape3D` (`todo/roadside-signs.md` §3). So "hitting
  objects" already produces real physics contacts — the damage model just needs
  to *read* them.
- **Steering is one line to tap.** `car.gd:170` computes
  `steer_target = travel_angle * steer_travel_alignment * align_scale +
  steer_input * steer_limit`. A damage **alignment bias** is an added constant
  term here (`steer_limit` `game_config.gd:82` is the unit).
- **Engine power is one value to scale.** The driven torque is
  `var drive_torque := engine.step(h, throttle, driveline_omega())`
  (`drivetrain.gd:116`); a damage **power multiplier** scales it (or the engine's
  output) before it reaches the wheels. `apply_car` already writes
  `cfg.peak_torque` from the CarLibrary spec (`car.gd:267`), so the baseline is
  per-car.
- **No HP anywhere.** Max HP is a **CarLibrary metadata field** (the prerequisite
  in `todo/save-persistence.md`); current HP is `OwnedCar.hp` in the save. This
  spec consumes both; it does not define the storage.

## Mechanism

### 1. HP & the fielded car's damage state

- **Max HP** comes from `CarLibrary` (`max_hp`, per the metadata prerequisite),
  loosely keyed to `mass` (`gameplay.md`: heavier ≈ tougher).
- **Current HP** is `OwnedCar.hp` (save). When a car is **fielded** at the Start
  line, the run holds a working HP that starts at `OwnedCar.hp`; at each **event
  boundary** the depleted value is written back via `Save.apply_damage(...)` (the
  save spec already debounces/autosaves here).
- The car exposes a **damage fraction** `d = 1 - hp / max_hp` ∈ [0,1] that the
  handling/power effects read each physics tick.
- **The immortal starter** (`OwnedCar.immortal`) **skips all of this**: no
  depletion, no effects, never wrecked — the anti-soft-lock floor.

### 2. Impact → HP loss

- Enable `contact_monitor = true` and a small `max_contacts_reported` on the car;
  in `_integrate_forces(state)` read the contact impulse magnitude.
- Convert impulse above a **threshold** (ignore gentle scrapes/kerbs) into HP
  loss: `hp_loss = max(0, impulse - impact_min_impulse) * hp_per_impulse`. Both
  are new `GameConfig` tunables.
- **Filter to real obstacles** — only count contacts against trees/signs (a
  collision layer or group), not the ground/road, so normal driving never chips
  HP. (The terrain is the `Floor`; obstacles are the `StaticBody3D` fields.)
- HP **only depletes** in-run; no passive regen (`gameplay.md`).

### 3. Effects that scale with damage (fraction `d`)

Both fade in with `d` and are pure `GameConfig`-scaled, applied on the **fielded,
non-immortal** car:
- **Wheel-alignment pull** — add a constant steer bias at `car.gd:170`:
  `steer_target += align_bias_sign * d * cfg.damage_steer_bias_max`. The car
  drifts to one side; `damage_steer_bias_max` is in the same radians unit as
  `steer_limit` (`game_config.gd:82`). **`align_bias_sign` is re-rolled randomly
  (±1) at each run/event start** *(decided)* — not tied to the rally seed, so a
  re-entry can pull the other way; the player can't pre-learn it.
- **Engine power loss** — scale the driven torque:
  `drive_torque *= 1.0 - d * cfg.damage_power_loss_max` at `drivetrain.gd:116`
  (or inside `engine.step`). `damage_power_loss_max` is the fraction of power
  lost at 0 HP.

### 4. Wreck at 0 HP

When working HP reaches **0** on a non-immortal car:
- The current rally is an immediate **DNF** (emit a `wrecked` signal the rally
  flow / Start-line listens for — sibling to the `stage_completed` hook in
  `todo/stage-start-and-end.md`).
- The car is **destroyed**: `Save.wreck_car(instance_id)` removes the instance
  **after returning its `installed_upgrades` to inventory** (only the chassis is
  lost — `gameplay.md`; the save spec's `wreck_car` already specifies this).
- Player DNF happens **only** this way — there is no time-cut fail-out
  (`gameplay.md`).

### 5. In-run HP HUD + impact feedback (decided)

Because a wreck **destroys** the car, the player must be able to read damage in
the moment to make the "back off or push?" call (`gameplay.md` › *Damage*). Add a
live readout to the in-car HUD (`scripts/hud.gd`, `main.tscn` `HUD` CanvasLayer,
`features/hud.md`):
- **HP gauge** — a bar (and/or number) showing working HP / `max_hp`, updated
  each frame from the fielded car's HP like the existing speed/gear/RPM labels
  (`hud.gd._process`). Colour-graded (green → amber → red) as `d` rises.
- **Low-HP warning** — below a `GameConfig` threshold (`hud_low_hp_warn_frac`)
  the gauge flashes / pulses so the danger is unmissable.
- **Impact cue** — a brief screen flash (and the `impact_*` SFX, `todo/audio.md`)
  on each HP-losing hit, sized to the impulse, so a chip vs a big hit reads
  differently.
- **Immortal starter** — hide the gauge (or show `∞`); it never takes damage.
- Gate behind a `hud_hp_enabled` flag (mirrors `hud_enabled`). This is the
  in-run counterpart to the **HQ stats-panel HP bar** (`todo/menus.md` rig 2),
  which shows HP *between* runs.

Audio hooks (all thin, defined in `todo/audio.md`): an above-threshold impact
fires `Audio.play_sfx_3d("impact_soft"/"impact_hard", contact_point)`; a wreck
fires `Audio.play_sfx("wreck")`.

## New `GameConfig` tunables (magnitudes only — values via playtest)

| Field | Meaning |
|---|---|
| `impact_min_impulse` | contact impulse below which no HP is lost (scrape filter) |
| `hp_per_impulse` | HP lost per unit impulse above the threshold |
| `damage_power_loss_max` | fraction of engine power lost at 0 HP (caps effect) |
| `damage_steer_bias_max` | max alignment steer bias (rad) at 0 HP |
| `hud_hp_enabled` | bool — show the in-run HP gauge (mirrors `hud_enabled`) |
| `hud_low_hp_warn_frac` | HP fraction below which the gauge flashes a warning |

Per-car **`max_hp`** lives in `CarLibrary` (metadata prerequisite), with a
`mass`-keyed default; it is **not** a `GameConfig` field.

## Dependencies

- **CarLibrary metadata** (`todo/save-persistence.md` › *Prerequisite*) —
  `max_hp` per car. Do first.
- **Save / persistence** — `OwnedCar.hp`, `Save.apply_damage`, `Save.wreck_car`
  (return-upgrades-then-remove). This spec is the main caller of those.
- **Upgrade catalogue** (`todo/upgrade-catalogue.md`) — the **repair kit** is the
  only way HP goes back up; defined there, consumed here-adjacent (heals
  `OwnedCar.hp`).
- **Impact sources** — `todo/roadside-signs.md` (signs are `StaticBody3D`) and the
  existing tree/bush `StaticBody3D`. Land at least one obstacle field's collision
  layer/group so the filter has something to match.
- **Relates to** `todo/stage-start-and-end.md` — the `wrecked` DNF parallels its
  `stage_completed` end-of-event hook; HP is written back at event boundaries.
- **Audio** (`todo/audio.md`) — the impact/wreck SFX hooks (§5) call `Audio`;
  thin, optional (silent fallback) until audio lands.
- **HUD** (`features/hud.md`) — the in-run HP gauge (§5) extends the existing HUD
  alongside speed/gear/RPM.

## Testing

Headless GUT tests (`tests/headless/`):
- **Impulse→HP:** a contact below `impact_min_impulse` costs 0 HP; above it costs
  `(impulse - threshold) * hp_per_impulse`; ground/road contacts cost nothing.
- **Effect scaling:** at `d=0` steer bias and power loss are 0; at `d=1` they hit
  `damage_steer_bias_max` / `damage_power_loss_max`; monotonic between.
- **Wreck:** HP→0 emits `wrecked`, calls `Save.wreck_car`, and the instance's
  upgrades land back in inventory before removal.
- **Immortal starter:** takes impacts without losing HP and never wrecks.
- **Persistence handoff:** working HP at event end is written via
  `Save.apply_damage` and reloads unchanged (round-trip with the save tests).
- **HUD readout:** the HP gauge reflects working HP / `max_hp`; crosses into the
  warning state below `hud_low_hp_warn_frac`; is hidden for the immortal starter.

## Out of scope / open questions

- **Tuning numbers** — `max_hp` per car, the `mass`→HP curve (formula default vs
  hand-set per car, `gameplay.md` open q), impulse threshold, and how steeply
  power/steer degrade. Settle via playtest.
- **Steering-pull direction** — **decided: random (±1) per run/event start**, not
  seed-tied (see *Effects* §3). Re-rolls on each run / re-entry.
- **Visible damage** — dents/smoke on the car mesh are not specced here; the model
  is mechanical + HUD only for now. *(The in-run HP gauge / warning / impact flash
  is now in scope — see §5.)*
- **Cosmetic vs hard caps** — whether very low HP also affects braking/grip, or
  only power+alignment as above. Start with the two `gameplay.md` names them.
