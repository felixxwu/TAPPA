# Engine Swap & Detune

**Sources:** the mid-run swap — `scripts/run_session.gd` (`RunSession.
_pool_engine_swap_ids`, `_current_engine_id`, `_with_engine_swap_display`,
`choose_engine_swap`, `engine_swap_id`), `scripts/boost_library.gd`
(`BoostLibrary.resolve_id`'s `"engine_swap:"` id branch) and
`scripts/world.gd` (`_owned_with_run_effects` writing `owned["swapped_engine"]`)
— through the pre-existing `scripts/engine_swap.gd` (`EngineSwap`, pure
math/lookup module) and the `_apply_engine_swap` fielding step in
`scripts/car.gd`, which this feature REUSES rather than reimplements; plus the
legacy owned-car read path, which still resolves cars in existing saves that
carry a `swapped_engine`.

**The Engine Swap is a genuine, deterministic MID-RUN engine swap.** It is
offered in the SAME between-stage pick as the other boosts and the AWD
drivetrain conversion, run-scoped (dies with the run, never touches `Save`'s
persisted car), but it is NOT a `BoostLibrary` catalogue entry and carries no
purchasable level: `RunSession._pool_engine_swap_ids()` offers exactly **the
next most powerful `EngineLibrary` engine relative to the car's current one**
(ranked by `CarLibrary.peak_power_kw`) that gains at least `MIN_SWAP_HP_GAIN`
(30hp) over the current engine — a smaller increment is skipped in favour of
the next rung that clears the bar — never a random pick, and `[]` once no
remaining engine clears that bar (including once the car already runs the
catalogue's most powerful engine) — see
[region-runs.md](region-runs.md) → "The engine swap" for the full pick-pool
mechanics. This supersedes an earlier flat `engine_power_mult` multiplier on
`cfg.peak_torque` — the `BoostLibrary.CATALOGUE["engine_swap"]` entry and its
magnitude field `GameConfig.run_boost_engine_power_mult` are both deleted,
since nothing else read either — which itself had superseded the original
decision-17 one-time meta unlock (`Save.buy_engine_swap_unlock`,
`KEY_ENGINE_SWAP_UNLOCKED`, both long deleted). The old garage "move any engine
into any other car" mutators (`Save.swap_engines` / `set_engine_detune`) are
deleted with the HQ lift that hosted them; their per-car keys survive as READ
paths for old saves only.

**Engine detune** is a per-car value (0-100%) that scales the fitted engine's
torque, and remains the only DELIBERATE power-to-weight *reduction* lever for a
challenge's rating ceiling (the weight slot's free ballast parts are retired --
see [upgrade-catalogue.md](upgrade-catalogue.md) -> the `weight` slot). With the
detune slider's host gone it is read-path-only too.

**Tests:** `tests/headless/test_engine_swap.gd` (the pure module),
`tests/headless/test_region_run.gd` (the "between-stage pick: an engine swap"
section — `_pool_engine_swap_ids`' next-most-powerful selection, `choose_engine_swap`,
no-reach-Save, wipe-on-finish, resume), `tests/headless/test_run_pick_panel.gd` (the
`"engine_swap:"` pick-entry card render/report)

Both of the old gate's consumers — `UpgradeOptions.engine_swap_blocked_reason`
and `hq._show_swap_confirm` — were deleted with the parts model and the
diegetic hub (`hq.gd`); the gate itself followed them.

Distinguish from [upgrade-catalogue.md](upgrade-catalogue.md): slottable
upgrades permanently change a car's baseline. The engine swap changes nothing
permanently either — it dies with the run, exactly like every other
between-stage pick, and changes only which engine this run's car currently
runs, gone the moment the run ends (win or lose). Detune is ordinary
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
- **`display_name(entry, owned) -> String`** — the car's name, prefixed with
  the swapped-in engine's layout when non-stock (e.g. `"V8 Rondel Twist"`); the plain
  name otherwise. Used everywhere an owned car's name is shown — today the hub CAR
  page's cards and the run summary.
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
- **`can_swap(car_a, car_b) -> bool`** — structural validity only: true when
  both cars exist (neither dict is empty). Health is not a factor.

## `Save` mutators

- **`Save.swap_engines(id_a, id_b) -> bool`** — exchanges the CURRENT engines
  (via `EngineSwap.current_engine_id`, so swapping a car that's already
  running a third car's engine still works correctly) of two owned cars.
  Refuses (returns `false`, no change) if the ids match, `EngineSwap.can_swap`
  fails, or **the two cars already run the same current engine** (a no-op swap).
  It consumes nothing — those structural guards are the whole of its contract.
  Each car's
  `swapped_engine` is set to the OTHER's current engine, then cleared back to
  `""` when the result equals that car's OWN stock engine — so "stock" is always
  canonical and a car's display name reverts the moment it's running its own
  engine again, even via a chain of swaps.
- **`Save.set_engine_detune(instance_id, frac)`** — clamps `frac` to `[0, 1]`
  and stores it at `tuning.engine_detune`. `1.0` (full power) is the default
  everywhere a car doesn't have this key yet.

## Fielding pipeline (`car.gd`)

### Three fielding paths — pick the right one

There are **three** ways to put an engine on a car, and choosing wrong fails
*silently*: the car simply runs the wrong engine, with no error. That is exactly how
start-line rivals ended up on their cars' stock engines
(see [region-stage-library.md](region-stage-library.md) → rival builds).

| Call | Applies | Use for |
|---|---|---|
| `apply_car(index, rebuild_audio := true)` | the CarLibrary entry's **stock** engine, nothing else | a generic **catalogue model** — free-roam previews, flavour props, the dev car-cycle. Stock is the *correct* answer here. |
| `apply_owned(owned)` | stock baseline → **engine swap** → upgrades → tuning → damage, then one terminal voice rebuild | a **saved `OwnedCar`** — fielding the player's own car (run fielding, hub previews). |
| `fit_engine(engine_id)` | **only** the engine swap (+ suspension re-sync + voice rebuild) | a **catalogue model running a non-stock engine** — i.e. a rival with an engine swap, where there is no `OwnedCar` to hand. Call after `apply_car(index, false)`. |

`fit_engine` deliberately does **not** do what `apply_owned` does: no upgrades, no
tuning, no live-baseline snapshot, no damage/HP-to-instance binding. A prop wants
none of those.

**Prop callers go through `CarProp.spawn`**, whose opts express the choice:
`"owned"` → `apply_owned`; `"engine_id"` (non-empty) → `apply_car(index, false)` +
`fit_engine`; otherwise the bare `"index"` → stock. Before `engine_id` existed the
`index` branch was the *only* way to name a car by id, which is why every caller
holding just a `car_id` was forced onto the stock engine.

**The deferred-audio footgun.** `apply_car(index, false)` skips the engine-voice
build so a caller can rebuild once after all its config mutation. Forgetting the
follow-up leaves the car **mute** — the config carries the engine either way, so
nothing else complains. `apply_car` therefore arms `_audio_build_pending`, and the
first live `_physics_process` tick `push_warning`s if it is still set. Both current
deferrers (`apply_owned`, `fit_engine`) clear it via `_reconfigure_engine_audio`, so
it never fires today; it exists to catch the third caller.

### `apply_owned`

`apply_owned` is the pipeline that turns a saved `OwnedCar` into a live,
physically simulated car (see the deleted career rally session):

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
3b. Because step 1 re-points `meta["engine"]` at the fitted engine, every
   **engine-derived rally restriction** follows the swap too:
   `RallyLibrary.ineligibility_reason` resolves `engine_min_l`/`engine_max_l`
   (from the engine's `displacement_l`) and `cylinders_min`/`cylinders_max`
   (from `EngineLibrary.cylinders`, derived from `layout`) through that id. So
   dropping a V8 into a small car can both qualify it for a big-bore class and
   disqualify it from a small-displacement one. The car's own `doors` is a body
   property and is unaffected by a swap, by design.
4. **Applies `engine_detune` last**, scaling the resulting `peak_torque` by
   the clamped `[0, 1]` fraction from `owned_car.tuning.engine_detune` (default
   `1.0`) — so a detuned car's reduced torque feeds `power_to_weight` and can
   push it over (or back under) a rally's `pw_max` ceiling, same as an
   engine swap or upgrade would.

`TuningLibrary.apply` applies the matching effect to the LIVE `cfg` at
fielding time (step 3, after upgrades): `cfg.peak_torque *= clampf(detune, 0, 1)`,
run last so it scales whatever torque the swapped engine + upgrade kits
produced. See [tuning.md](tuning.md) for the full axis table.

## The UI is gone; here is what a rebuild owes

Nothing in the flat shell swaps an engine. The shop sells the *unlock*
([hub-shell.md](hub-shell.md)); no screen spends it. These are the rules the deleted UI
enforced, kept because a rebuild has to re-establish them and they are not obvious:

- **A swap needs a partner car**, so the screen that lists engines cannot perform the
  swap on its own — the old `engine` tile called back to its host for exactly that reason.
  List every OTHER owned car (no self-swap); filter none of them on health.
- **Show both sides.** A swap EXCHANGES engines, so the preview showed a row for the
  player's car AND for the donor, each with its resulting hp/tonne delta. The pure math is
  still there: `EngineSwap.pw_after_swap(owned, entry, donor_engine_id)` returns kW/kg;
  scale by `CarLibrary.KW_KG_TO_HP_TONNE` to display.
- **Re-check the gate from the screen**, not from a stored flag on the car:
  `RallyLibrary.engine_swaps_unlocked(Save.profile)`. `Save.swap_engines` is deliberately a
  pure mutator that does NOT check it, so the entry point owns that.
- **Locked means locked, not priced.** Every unavailable row in the old UI read `Locked`
  rather than quoting a cost, so "the cursor skips this" and "here is what it costs" stayed
  visually distinct.

### Navigation, when it is rebuilt

CLAUDE.md requires every menu to be keyboard + gamepad navigable and to ship with a nav
test in the same change. The old swap flow got that for free by reusing the car park's own
input handlers with a mode flag — it added no new input surface. A flat rebuild gets it the
same way, from `MenuNav.attach` on a `MenuPage` of ordinary focusable rows; see
[menu-navigation.md](menu-navigation.md) and `HubShell`'s pages for the pattern.

## Tests

`tests/headless/test_engine_swap.gd` — `current_engine_id` prefers the swap
over stock; `layout_label_from` uppercases and strips the qualifier suffix on
supplied layout strings, and every key in `EngineLibrary.FIRING` yields a
non-empty label with no underscore and no lowercase; `layout_label` equals the
formatter applied to each roster entry's own `layout`; `display_name` prefixes
the layout only when swapped; `recompute_mass` swaps the engine component;
`recompute_weight_front` moves the CoG by the injected engine position (with
injected numbers, not authored values — see the project's testing rules);
`can_swap` accepts two real cars regardless of health and rejects an empty one.
`test_save_manager.gd` covers `swap_engines` succeeding between damaged cars (HP
untouched), `set_engine_detune` persistence, and the stock-reversion clearing
behaviour. `test_car.gd` covers `_apply_engine_swap`'s mass/CoM/
drivetrain rebuild. `test_upgrade_library.gd` covers `effective_meta` resolving
the swapped engine and detune scaling power-to-weight. `test_tuning_library.gd`
covers `TuningLibrary.apply`'s `engine_detune` torque scaling.

**The mid-run swap** — `test_region_run.gd`'s "between-stage pick: an engine swap"
section: `_pool_engine_swap_ids()` offers the next strictly-more-powerful catalogue
engine and no engine sits strictly between it and the current one; the pool empties
once the car already runs the most powerful engine; the pool competes in the SAME
draw as the boosts and AWD without changing the pick's total size;
`choose_engine_swap` records the id, resolves the pick, and takes no repair; a later
swap replaces rather than stacks; the swap never reaches `Save`'s persisted car; it
is wiped on run end (win or lose) and survives a pause/resume. `test_run_pick_panel.gd`
covers an `"engine_swap:"` pick entry rendering its card and reporting its id, and
that no card is drawn when the pick carries none.

**The UI tests are gone with the UI** (`test_upgrades_grid.gd` for the two tiles,
the deleted `test_menu_flow.gd` for car-park swap mode and its confirm). There is no detune-to-enter
gate left to test either: entry to a region run is ungated, and a Rally Challenge's rating
ceiling is judged by `ChallengeRunMode.classify_cars`, which
`tests/headless/test_challenge_session.gd` covers.
