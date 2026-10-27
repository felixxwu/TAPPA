# Engine Swap & Detune

**Sources:** `scripts/free_roam/loot_rules.gd` (`LootRules` — an engine is a found part with id
`"engine_swap:<EngineLibrary id>"`; `fielded` writes it as the car's `swapped_engine`),
`scripts/engine_swap.gd` (`EngineSwap`, pure math/lookup module) and the
`_apply_engine_swap` fielding step in `scripts/car.gd`.

**Tests:** `tests/headless/test_engine_swap.gd`, `tests/headless/test_loot.gd`, `tests/headless/test_car.gd`

**In free roam an engine is loot.** Each `EngineLibrary` entry names the biome `ring` it is
found in ([loot.md](loot.md)); fitting one at a rest stop's Garage puts it in the car's
`parts`, and `LootRules.fielded(owned)` turns it into `swapped_engine` on the duplicate that
fields the car. A car holds one engine part at a time (`LootRules` swaps the old one out).
The persisted car never carries `swapped_engine` itself.

**Engine detune** is a per-car value (0-100%) in the `tuning` bag that scales the fitted
engine's torque. No screen sets it today; it is read-path-only (see [tuning.md](tuning.md)).

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
- The car dict `apply_owned` reads carries two engine fields (see
  [save-persistence.md](save-persistence.md)):
  - **`swapped_engine`** (string, default `""`) — the id of a non-stock engine
    currently fitted, or absent/empty when running the car's own stock engine. Written
    onto the fielding duplicate by `LootRules.fielded`, never persisted.
  - **`tuning.engine_detune`** (float, default `1.0`) — the 0–1 torque scale,
    stored in the existing per-car `tuning` bag alongside `grip_balance` /
    `brake_bias` / `aero_balance`.

## `EngineSwap` (pure module)

`scripts/engine_swap.gd` holds all the swap math/lookups as static functions —
no scene or Save coupling; `car.gd` applies the result.

- **`current_engine_id(owned, stock_id) -> String`** — the engine a car is
  actually running: `owned.swapped_engine` if set, else the `stock_id`
  (`CarLibrary` entry's `engine`) passed in.
- **`layout_label_from(layout) -> String`** — formats a layout STRING for
  display: uppercased, with any qualifier suffix after the first `_` dropped
  (`"v8"` → `"V8"`, `"v12_uneven"` → `"V12"`). Layout keys index
  `EngineLibrary.FIRING`, where a qualified key like `v12_uneven` is a separate
  firing table for the same physical layout (a lopier voice for the Merlin), so
  only the leading token is the layout name — without the strip a swapped-in
  Merlin displayed as `"V12_UNEVEN Rondel Twist"`. The rule is derived from the
  string, so a future qualified table needs no change here.
  Note: an engine may deliberately borrow another layout's firing table for its
  sound (the flat-six Porsche uses `i6`, so it displays "I6") — that's a known
  simplification of the audio model, not something the label tries to correct.
- **`layout_label(engine_id) -> String`** — the engine's `EngineLibrary`
  `layout` run through `layout_label_from`; `""` if unknown.
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

## Fielding pipeline (`car.gd`)

### Two fielding paths — pick the right one

There are **two** ways to put an engine on a car, and choosing wrong fails
*silently*: the car simply runs the wrong engine, with no error.

| Call | Applies | Use for |
|---|---|---|
| `apply_car(index, rebuild_audio := true)` | the CarLibrary entry's **stock** engine, nothing else | a generic **catalogue model** — free-roam previews, flavour props, the dev car-cycle. Stock is the *correct* answer here. |
| `apply_owned(owned)` | stock baseline → **engine swap** → upgrades → tuning → damage, then one terminal voice rebuild | a **saved `OwnedCar`** — fielding the player's own car (run fielding, hub previews). |

**Prop callers go through `CarProp.spawn`**, whose opts express the choice:
`"owned"` → `apply_owned`; otherwise the bare `"index"` → stock.

**The deferred-audio footgun.** `apply_car(index, false)` skips the engine-voice
build so a caller can rebuild once after all its config mutation. Forgetting the
follow-up leaves the car **mute** — the config carries the engine either way, so
nothing else complains. `apply_car` therefore arms `_audio_build_pending`, and the
first live `_physics_process` tick `push_warning`s if it is still set. The one current
deferrer (`apply_owned`) clears it via `_reconfigure_engine_audio`, so it never fires
today; it exists to catch the next caller.

### `apply_owned`

`apply_owned` is the pipeline that turns a saved `OwnedCar` into a live,
physically simulated car:

```
1. CarLibrary baseline    apply_car(index)            -> Config.data
1b. Engine swap           _apply_engine_swap(owned)      (THIS — rewrites engine + mass/CoM)
2. Installed upgrades     UpgradeLibrary.apply()          (changes the baseline)
3. Per-car tuning         TuningLibrary.apply()           (re-balances it, incl. detune)
4. Damage multipliers     power/steer degraded by HP
```

`_apply_engine_swap(owned)` runs immediately after the `CarLibrary` baseline
and **before** upgrades, so a weight-reduction kit's `mass_mult_floor` scales the
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
   drivetrain (Drivetrain Conversion kit — `UpgradeLibrary`'s `drivetrain_swap`
   item, renamed from "Drivetrain Swap") still wins after an engine swap. See
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

## Detune

`TuningLibrary.apply` applies `engine_detune` to the LIVE `cfg` at fielding time (after
upgrades): `cfg.peak_torque *= clampf(detune, 0, 1)`, run last so it scales whatever torque
the swapped engine + upgrade kits produced. See [tuning.md](tuning.md) for the full axis table.

## Tests

`tests/headless/test_engine_swap.gd` — `current_engine_id` prefers the swap
over stock; `layout_label_from` uppercases and strips the qualifier suffix on
supplied layout strings, and every key in `EngineLibrary.FIRING` yields a
non-empty label with no underscore and no lowercase; `layout_label` equals the
formatter applied to each roster entry's own `layout`; `recompute_mass` swaps the engine component;
`recompute_weight_front` moves the CoG by the injected engine position (with
injected numbers, not authored values — see the project's testing rules);
`test_car.gd` covers `_apply_engine_swap`'s mass/CoM/
drivetrain rebuild. `test_tuning_library.gd`
covers `TuningLibrary.apply`'s `engine_detune` torque scaling.

`test_loot.gd` covers an engine part fielding as `swapped_engine` and a second engine replacing
the first.
