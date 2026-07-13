# Engine Swap & Detune

**Sources:** `scripts/engine_swap.gd` (`EngineSwap`, pure math/lookup module),
the `swap_engines` / `set_engine_detune` mutators in `scripts/save_manager.gd`,
the `_apply_engine_swap` fielding step in `scripts/car.gd`, the
`effective_meta` feed-through in `scripts/upgrade_library.gd`, the
`engine_detune` axis in `scripts/tuning_library.gd`, and the swap-row / car-park
swap-mode UI in `scripts/hq.gd`.

**Engine swap** lets the player move any owned car's engine into any other
owned car — unlimited and reversible. Both cars must be at **100% HP** for the
exchange itself, but a car below full health no longer blocks the swap: it's
restored with a **Repair Kit** as part of the swap (one kit per damaged car,
spent on confirm). A swap between two already-full cars is still free. **Engine
detune** is a per-car tuning slider (0–100%) that directly
scales the fitted engine's torque, letting a car be deliberately hobbled (e.g.
to fit a rally's power-to-weight band) without touching its parts.

Distinguish from [upgrade-catalogue.md](upgrade-catalogue.md): upgrades are
consumable items that permanently change a car's baseline. A swap is not
consumed and not permanent — it just changes which `EngineLibrary` entry the
car currently runs, and can be undone by swapping back. Detune is ordinary
[tuning.md](tuning.md): free, reversible, stored per-car, never written to the
authored `.tres`.

## Data model

- `EngineLibrary` entries (`scripts/engine_library.gd`) now carry a **`mass`**
  (kg) field alongside `layout`/`peak_torque`/`redline_rpm`/etc — e.g.
  `{"id": "ford_50_v8", ..., "mass": 200.0}`. This is what makes an engine a
  physical object with weight, not just a torque curve.
- `CarLibrary` entries (`scripts/car_library.gd`) carry an **`engine_pos`** —
  the front-axle weight fraction of the ENGINE itself (not the whole car),
  used to place it along the wheelbase when computing weight distribution.
  Front-engined cars set it high (`0.85`), a rear-engined car low (`0.10`), a
  mid-engined car in between (`0.35`–`0.55`). When an entry omits it, it
  **defaults to the car's own `weight_front`** (an engine assumed to sit at the
  car's own balance point), so a swap on such a car degrades to a mass-only
  change.
- `OwnedCar` (in `Save.profile.cars`) gained two fields, both defaulted so no
  `SCHEMA_VERSION` bump was needed (see [save-persistence.md](save-persistence.md)):
  - **`swapped_engine`** (string, default `""`) — the id of a non-stock engine
    currently fitted, or absent/empty when running the car's own stock engine.
  - **`tuning.engine_detune`** (float, default `1.0`) — the 0–1 torque scale,
    stored in the existing per-car `tuning` bag alongside `grip_balance` /
    `brake_bias` / `aero_balance`.

## `EngineSwap` (pure module)

`scripts/engine_swap.gd` holds all the swap math/lookups as static functions —
no scene or Save coupling; `Save` owns the mutations and `car.gd` applies the
result.

- **`current_engine_id(owned, stock_id) -> String`** — the engine a car is
  actually running: `owned.swapped_engine` if set, else the `stock_id`
  (`CarLibrary` entry's `engine`) passed in.
- **`layout_label(engine_id) -> String`** — the engine's `EngineLibrary`
  `layout` uppercased (`"v8"` → `"V8"`); `""` if unknown.
- **`display_name(entry, owned) -> String`** — the car's name, prefixed with
  the swapped-in engine's layout when non-stock (e.g. `"V8 Twingo"`); the plain
  name otherwise. Used everywhere an owned car's name is shown (lift, car
  park, HQ stats).
- **`recompute_mass(m_total, m_stock_engine, m_new_engine) -> float`** — total
  mass with the engine component swapped out:

  ```
  M' = M - m0 + m1
  ```

- **`recompute_weight_front(m_total, wf, m_stock_engine, m_new_engine, engine_pos) -> float`**
  — the static front-axle weight fraction after the swap, treating the engine
  as a point mass at `engine_pos` (the fraction of the ENGINE's weight on the
  front axle):

  ```
  WF' = ((WF·M - m0·EF) + m1·EF) / (M - m0 + m1)
  ```

  When `EF == WF` this reduces to `WF` unchanged (a pure mass-only swap, no
  distribution shift). Returns the untouched `wf` if the new total mass would
  be non-positive (defensive; never hit with authored data).
- **`can_swap(car_a, car_b) -> bool`** — true only when both cars exist,
  neither is empty, and both sit at their `CarLibrary` `max_hp` (100% health).
  A repair kit clears the gate the same way it clears any other "car isn't
  full HP" restriction.

## `Save` mutators

- **`Save.swap_engines(id_a, id_b) -> bool`** — exchanges the CURRENT engines
  (via `EngineSwap.current_engine_id`, so swapping a car that's already
  running a third car's engine still works correctly) of two owned cars.
  Refuses (returns `false`, no change) if the ids match or `EngineSwap.can_swap`
  fails. Each car's `swapped_engine` is set to the OTHER's current engine, then
  cleared back to `""` when the result equals that car's OWN stock engine — so
  "stock" is always canonical and a car's display name reverts the moment it's
  running its own engine again, even via a chain of swaps.
- **`Save.set_engine_detune(instance_id, frac)`** — clamps `frac` to `[0, 1]`
  and stores it at `tuning.engine_detune`. `1.0` (full power) is the default
  everywhere a car doesn't have this key yet.

## Fielding pipeline (`car.gd`)

`apply_owned` is the pipeline that turns a saved `OwnedCar` into a live,
physically simulated car (see [rally-session.md](rally-session.md)):

```
1. CarLibrary baseline    apply_car(index)            -> Config.data
1b. Engine swap           _apply_engine_swap(owned)      (THIS — rewrites engine + mass/CoM)
2. Installed upgrades     UpgradeLibrary.apply()          (changes the baseline)
3. Per-car tuning         TuningLibrary.apply()           (re-balances it, incl. detune)
4. Damage multipliers     power/steer degraded by HP
```

`_apply_engine_swap(owned)` runs immediately after the `CarLibrary` baseline
and **before** upgrades, so a weight-reduction kit's `mass_mult` scales the
post-swap total, and before the end-of-function suspension re-sync, so the
spring split re-derives from the post-swap `weight_front`. It is a no-op for a
car running its own stock engine (`EngineSwap.current_engine_id(owned, stock) == stock`).
When non-stock:

1. Looks up the swapped-in engine in `EngineLibrary` and calls
   `EngineLibrary.apply(new_eng, cfg)` — this overwrites the config's whole
   engine profile: torque curve, redline, cylinder count, firing angles,
   voicing, **and the transmission bolted to that engine** (`gear_ratios`,
   `final_drive`, `shift_time`), see
   [engine-and-transmission.md](engine-and-transmission.md).
2. **Rebuilds the drivetrain** (`Drivetrain.new(self)`, re-resolving terrain
   and drive mode) so the new redline/shift-speed table takes effect, and
   <br>(The rebuild uses the spec's stock `drive_mode`, but `apply_owned` sets
   `_owned_drive_override` from `UpgradeLibrary.resolve_drive_override` *before*
   this step, and `_rebuild_drivetrain` honours it — so a player's chosen
   drivetrain (Drivetrain Swap kit) still wins after an engine swap. See
   [drivetrain-and-tires.md](drivetrain-and-tires.md).)
   reconfigures the engine audio voice (`EngineAudio.reconfigure`) so the
   sound matches the new cylinder count/firing order
   ([engine-audio.md](engine-audio.md)).
3. **Recomputes mass and weight distribution** from the two engines' `mass`
   and the car's `engine_pos`:
   ```gdscript
   cfg.mass = EngineSwap.recompute_mass(spec_mass, m0, m1)
   cfg.weight_front = EngineSwap.recompute_weight_front(spec_mass, spec_wf, m0, m1, ef)
   mass = cfg.mass
   center_of_mass = Vector3(0.0, 0.0, spec["wheelbase"] * (0.5 - cfg.weight_front))
   ```
   (`m0`/`m1` are the stock/new engine masses, `spec_mass`/`spec_wf` the car's
   authored baseline mass/`weight_front`, `ef` the car's `engine_pos`, falling
   back to `spec_wf` when the CarLibrary entry omits it.) This is the same
   `center_of_mass.z = wheelbase × (0.5 − weight_front)` formula
   `apply_car` uses for the baseline case (see [car-physics.md](car-physics.md)
   → Weight distribution), just re-derived from the post-swap `weight_front`.

**The transmission swaps with the engine.** `gear_ratios`, `final_drive`, and
`shift_time` live on the `EngineLibrary` entry (not the car), so
`EngineLibrary.apply` — called in step 1 — brings the swapped engine's whole
drivetrain: gearing spacing, overall ratio, and shift feel. Swapping a PDK V8
into a kei car gives it the V8's gearbox and fast shifts, not the kei's
5-speed. The drivetrain rebuild in step 2 recomputes shift speeds for the new
ratios. (Design decision: engine + gearbox are one swappable unit.)

## Eligibility feed-through (`effective_meta`)

`UpgradeLibrary.effective_meta(owned_car, meta)` is the single place that
derives a car's power-to-weight figure for display and for
`RallyLibrary.is_eligible` (see [upgrade-catalogue.md](upgrade-catalogue.md)).
It resolves the CURRENT engine the same way `car.gd` does:

1. Resolves `current_id := EngineSwap.current_engine_id(owned_car, stock_id)`,
   points the meta's `engine` at it, and seeds `peak_torque`/`redline` from
   that engine (only filling values the `meta` doesn't already carry, so
   synthetic test fixtures with explicit values are untouched).
2. If swapped (`current_id != stock_id`), recomputes `mass` via
   `EngineSwap.recompute_mass` using the stock and swapped-in engine masses —
   so a swap changes the displayed/eligibility mass exactly like it changes
   the live physics mass.
3. Applies enabled upgrade multipliers (engine kits, weight reduction) on top
   of the swapped baseline.
4. **Applies `engine_detune` last**, scaling the resulting `peak_torque` by
   the clamped `[0, 1]` fraction from `owned_car.tuning.engine_detune` (default
   `1.0`) — so a detuned car's reduced torque feeds `power_to_weight` and can
   push it out of (or into) a rally's `pw_min`/`pw_max` band, same as an
   engine swap or upgrade would.

`TuningLibrary.apply` applies the matching effect to the LIVE `cfg` at
fielding time (step 3, after upgrades): `cfg.peak_torque *= clampf(detune, 0, 1)`,
run last so it scales whatever torque the swapped engine + upgrade kits
produced. See [tuning.md](tuning.md) for the full axis table.

## UI

- **Upgrades page, engine-swap row** (`hq._make_engine_swap_row`) — shown on
  the tuning-lift's Upgrades page above the slot rows: a label with the
  car's current engine name (`EngineLibrary.by_id(current).name`) and a **Swap
  Engine** button. The button is **never disabled on health or kit state** — a
  damaged car is repaired as part of the swap, so it's only disabled when there's
  literally no other owned car to swap with. When this car is below 100% HP the
  tooltip notes a Repair Kit will be spent.
- **Car-park swap mode** (`hq._enter_engine_swap` / `_carpark_swap_mode`) —
  pressing Swap Engine opens the car park listing **every** OTHER owned car (the
  current car itself is excluded — no self-swap); no car is filtered out on
  health. It reuses the car park's normal cycle-and-frame flow; the Start button
  reads **"Swap Engine"**. While picking a partner,
  `hq._refresh_swap_repair_warning` shows how many Repair Kits the swap will cost
  (one per car below 100% HP) — or, if the player is short, says so — without
  disabling anything. Confirming (`hq._select_swap_target`): with no kit needed it
  calls `Save.swap_engines` directly; when a car is damaged it pops
  `_show_swap_repair_confirm` (OK **"Repair & Swap"**, disabled when the player
  lacks the kits), and OK (`_on_swap_repair_confirmed` → `_commit_engine_swap`)
  spends one `Save.use_repair_kit` per damaged car before the exchange. Either way
  it forces the lift prop to respawn with the new engine, and returns to the
  lift's Upgrades page. **Back**
  (`_car_back`) returns to the lift with no change, same as change-car and
  starter-pick modes.
  While picking a partner, `hq._refresh_swap_preview()` (called from
  `_focus_changed`) shows a two-way hp/tonne preview in a `RichTextLabel`
  (`hq._swap_preview_label`) below the stats panel: since a swap EXCHANGES
  engines, both the lift car (receiving the focused partner's engine) and the
  focused partner (receiving the lift car's engine) get a row, each with a
  coloured ↑/↓/— arrow for the resulting delta. The pure math is
  `EngineSwap.pw_after_swap(owned, entry, donor_engine_id)` (returns kW/kg;
  scaled by `CarLibrary.KW_KG_TO_HP_TONNE` for display). Hidden outside swap
  mode.
- **Tuning page, detune slider** — a normal `TuningLibrary.AXES` row
  ("Engine detune", `0%`–`100%`), always **unlocked** (no upgrade gate,
  unlike brake-bias/aero). The slider stores `frac = value / 100.0` via
  `Save.set_engine_detune`; **Reset to neutral** returns it to `1.0` (100%,
  full power) like every other axis returns to its own neutral.
- **Car-park detune-to-enter prompt** — an owned car OVER a rally's `pw_max`
  cap still parks in the rally car-select lineup and LOOKS eligible there (no
  warning label, plain Start — saves overlay space); pressing Start pops a
  **confirm dialog** that explains it doesn't qualify as-is and the tune that
  would fix it, with OK as the explicit agreement (**Detune to N% & Start**)
  that applies the tune via `Save.set_engine_detune` before fielding
  (`hq._show_detune_confirm` / `_on_detune_confirmed`; the math is
  `RallyLibrary.qualifying_detune`). The agreement is **temporary, for that
  rally only** — unlike a garage-lift detune, which is permanent: the confirm
  registers the car's prior tune with the session
  (`RallySession.register_detune_revert`), and when the rally ENDS (finish,
  wreck or abandon — all via `_reset_to_idle`, never mid-rally, so the tune
  can't creep back up between events) the prior tune is restored (the
  garage-set value, or the 1.0 default if never tuned). See
  [menus.md](menus.md) → CARPARK.

### Navigation

The swap row's **Swap Engine** button is an ordinary `Control.FOCUS_ALL`
button on the Upgrades page (native-focus regime — see
[menus.md](menus.md) → "Menu navigation"), so it's reachable by
keyboard/gamepad exactly like every other upgrades-menu button, with no extra
wiring. Once pressed, the car park it opens is the SAME diegetic 3D station
used by change-car and the starter picker — it reuses that station's existing
`menu_left`/`menu_right` (cycle the focused car), `menu_select` (confirm via
`_on_start_pressed` → `_select_swap_target`), and `menu_back` (`_car_back`,
which returns to the lift when `_carpark_swap_mode` is set) handlers in
`hq.gd._unhandled_input`, so swap mode is fully keyboard/gamepad navigable by
construction — it adds no new input surface, only a new car-park **mode flag**
that changes what `_on_start_pressed`/`_car_back` do at the existing
confirm/back actions. The detune slider is a row on the Tune page, using the
same left/right-nudges-the-focused-slider handling as `grip_balance` (see
[menus.md](menus.md) → "Menu navigation" → the tuning-lift Tune page).

## Tests

`tests/headless/test_engine_swap.gd` — `current_engine_id` prefers the swap
over stock; `layout_label` uppercases a known layout; `display_name` prefixes
the layout only when swapped; `recompute_mass` swaps the engine component;
`recompute_weight_front` moves the CoG by the injected engine position (with
injected numbers, not authored values — see the project's testing rules);
`can_swap` requires both cars at full health. `test_save_manager.gd` covers
`swap_engines`/`set_engine_detune` persistence and the stock-reversion
clearing behaviour. `test_car.gd` covers `_apply_engine_swap`'s mass/CoM/
drivetrain rebuild. `test_upgrade_library.gd` covers `effective_meta` resolving
the swapped engine and detune scaling power-to-weight. `test_tuning_library.gd`
covers the `engine_detune` axis application. `test_menu_flow.gd` covers the
swap row, car-park swap mode, the detune slider's navigation/persistence, and
the car-park detune-to-enter prompt (over-cap car parks looking eligible; Start
pops the confirm; agreeing applies the tune and launches). `test_rally_library.gd`
covers `RallyLibrary.qualifying_detune` itself.
