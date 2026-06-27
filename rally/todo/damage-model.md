# Damage Model — implementation spec

> Status: **✅ IMPLEMENTED.** The per-car HP / attrition mechanism shipped — see
> the living doc [`features/damage.md`](../features/damage.md) (source:
> `scripts/damage_model.gd`, wired in `car.gd` / `drivetrain.gd` / `hud.gd`;
> tests in `tests/headless/test_damage_model.gd`, `test_car.gd`, `test_hud.gd`).
> The brief that drove it has been struck; only the cross-spec hooks and the
> by-design deferrals below remain.

## What shipped

Per-car HP pool (CarLibrary `max_hp`, mass-keyed) on the fielded car; impacts
above `impact_min_impulse` drain it (`hp_per_impulse`, obstacle-group filtered so
ground/road never chip), with a per-hit cap (`impact_max_loss_frac` of max HP) and a
post-hit cooldown (`impact_cooldown_s`) so one crash can't instantly wreck the car —
a car survives ~2-3 big hits (the chassis contacts an obstacle every tick while
pinned, so the cooldown groups a whole crash into one hit); power and steer-alignment degrade with the damage
fraction `d` (`damage_power_loss_max` / `damage_steer_bias_max`, bias direction
re-rolled per run); wreck at 0 HP emits `wrecked`, calls `Save.wreck_car`
(upgrades returned then instance destroyed); the immortal starter skips all of
it. In-run HUD gauge (colour-graded, low-HP warning pulse, impact flash, gated by
`hud_hp_enabled` / `hud_low_hp_warn_frac`). HP persists across events via
`Save.apply_damage`.

## Remaining / deferred (live in other specs)

- **Tuning numbers** — `max_hp` per car, the `mass`→HP curve, the impulse
  threshold, and how steeply power/steer degrade are placeholders. The mechanism
  is fixed; the values are settled by **playtest** (`gameplay.md` says so).
- **Impact / wreck SFX** — §5's `Audio.play_sfx_3d("impact_*")` / `"wreck"` hooks
  are stubbed silent; they light up with **`todo/audio.md`** (bus layout + SFX).
- **Repair kit** — the only way HP climbs back; defined in
  **`todo/upgrade-catalogue.md`**, heals `OwnedCar.hp` adjacent to this system.
- **Between-run HP readout** — the in-run gauge is done; the **HQ stats-panel HP
  bar** (shown between runs) is **`todo/menus.md`** rig 2, part of the deferred
  full menus build.
- **Visible / cosmetic damage** (dents, smoke) — out of scope; the model is
  mechanical + HUD only.
- **Extra hard caps** — whether very low HP also affects braking/grip rather than
  only power + alignment. Open; revisit via playtest if the two current effects
  read as too soft.
