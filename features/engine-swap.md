# Engine Swap & Detune

**Sources:** `scripts/engine_swap.gd` (`EngineSwap`, pure math/lookup module),
the `swap_engines` / `set_engine_detune` mutators in `scripts/save_manager.gd`,
the `_apply_engine_swap` fielding step in `scripts/car.gd`, the
`effective_meta` feed-through in `scripts/upgrade_library.gd`, the
`engine_detune` scaling read by `TuningLibrary.apply` in
`scripts/tuning_library.gd` (detune is stored in the per-car `tuning` bag but is
**not** a `TuningLibrary.AXES` entry), the `engine` and `tune` tiles on the upgrades grid
(`scripts/upgrades_grid.gd` / `scripts/upgrade_options.gd` / `scripts/upgrade_slot_popup.gd`),
and the car-park swap-mode UI in
`scripts/hq.gd`.

**Engine swap** lets the player move any owned car's engine into any other
owned car. Each swap costs one **engine swap token** — a consumable earned as a
low-weight reward-pool drop, held in the shared inventory.
**Health is irrelevant**: a damaged car swaps fine and keeps its current HP
through the exchange (no repair coupling). Every swap spends a token, including
reverting a car to its own stock engine. **Engine detune** is a per-car tuning
slider (0–100%) that directly scales the fitted engine's torque, letting a car
be deliberately hobbled (e.g. to fit a rally's power-to-weight band) without
touching its parts. Detune is not the only power-to-weight lever: the weight
slot's **free ballast** parts (`ballast_large` / `ballast_small` — see
[upgrade-catalogue.md](upgrade-catalogue.md)) add mass to drop p/w the other way,
so a car can qualify for a lower class by adding weight as well as by cutting
power.

**Capability gate.** Tokens drop and bank from the very start, but cannot be
SPENT until the engine-swap special is won
(`RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY := "front_runners"`, "Upgrade: Engine Swap" — the
difficulty-1 pin right beside HQ, revealed from the very first map view, so swapping is
the first thing the ladder opens and a player can go and win the garage's most
interesting mechanic immediately; predicate
`RallyLibrary.engine_swaps_unlocked(profile)`). Separating the capability from
the currency is deliberate: a visible stack of tokens you cannot use yet is a
stronger pull toward the event than any prize description, so the locked UI names
the banked tokens rather than hiding them.

The gate used to hang on `sp_woodland_trial` (now the Snow Tires special). A career that
already won it keeps the capability outright through `Save.KEY_LEGACY_ENGINE_SWAP`, set
by the **5 → 6** save migration and checked FIRST by `engine_swaps_unlocked` — the same
shape as `KEY_LEGACY_PART_UNLOCKS` for the 4 → 5 part moves, and deliberately not done by
marking the new rally completed, which would light its map circle and pay stars nobody
earned. See [save-persistence.md](save-persistence.md).

Three consumers:

- `RewardSystem._box_gate_open` — waives the mystery-box token threshold while
  swapping is locked, so tokens don't also gate boxes before they're spendable.
- `UpgradeOptions._engine_options` — the `engine` tile's options are always LISTED, and
  every engine other than the fitted one carries a `locked_reason` of `"Locked"` while the
  capability is unwon, or `"Needs token"` once it is unlocked but the player holds none.
  This is the grid-wide rule (see [upgrade-catalogue.md](upgrade-catalogue.md) → "Locked
  options are LISTED, GREYED"): a tile hides its contents behind a press, so an omitted
  option is an option the player can never learn exists. Naming the reason is also what
  turns a banked-but-unspendable token stack into a pull toward the gating event.
- `hq._show_swap_confirm` — the car-park station's confirm popup, which is
  reachable independently of the garage grid, so it re-checks rather
  than trusting the caller, and is where the locked explanation still lives. Its OK button is disabled on `_pending_swap.is_empty()`, which is
  set on exactly the one path where a swap can proceed — so a locked (or
  tokenless) popup can't present a live button that silently no-ops.

`Save.swap_engines` itself does not check the gate; both entry points do, and it
stays a pure mutator.

Distinguish from [upgrade-catalogue.md](upgrade-catalogue.md): slottable
upgrades permanently change a car's baseline. The engine swap token is a
consumable (spent per swap), but the swap itself is not permanent — it just
changes which `EngineLibrary` entry the car currently runs, and can be undone by
swapping back (which costs another token). Detune is ordinary
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
- **`can_swap(car_a, car_b) -> bool`** — structural validity only: true when
  both cars exist (neither dict is empty). Health is no longer a factor — the
  token cost is enforced in `Save.swap_engines`, not here.

## `Save` mutators

- **`Save.swap_engines(id_a, id_b) -> bool`** — exchanges the CURRENT engines
  (via `EngineSwap.current_engine_id`, so swapping a car that's already
  running a third car's engine still works correctly) of two owned cars.
  Refuses (returns `false`, no change) if the ids match, `EngineSwap.can_swap`
  fails, **the two cars already run the same current engine** (a no-op swap —
  the token check runs AFTER this guard, so a no-op never spends a token), **or
  no engine swap token is held**. On success it spends one token
  (`consume_item(UpgradeLibrary.ENGINE_SWAP_TOKEN_ID, 1)`). Each car's
  `swapped_engine` is set to the OTHER's current engine, then cleared back to
  `""` when the result equals that car's OWN stock engine — so "stock" is always
  canonical and a car's display name reverts the moment it's running its own
  engine again, even via a chain of swaps.
- **`Save.engine_swap_tokens_owned() -> int`** — the token count held in the
  shared inventory (0 when the key is absent). The HQ swap button reads it to
  label/disable itself.
- **`Save.set_engine_detune(instance_id, frac)`** — clamps `frac` to `[0, 1]`
  and stores it at `tuning.engine_detune`. `1.0` (full power) is the default
  everywhere a car doesn't have this key yet.

## Fielding pipeline (`car.gd`)

### Three fielding paths — pick the right one

There are **three** ways to put an engine on a car, and choosing wrong fails
*silently*: the car simply runs the wrong engine, with no error. That is exactly how
start-line rivals ended up on their cars' stock engines
(see [rally-roster.md](rally-roster.md) → rival builds).

| Call | Applies | Use for |
|---|---|---|
| `apply_car(index, rebuild_audio := true)` | the CarLibrary entry's **stock** engine, nothing else | a generic **catalogue model** — free-roam previews, flavour props, the dev car-cycle. Stock is the *correct* answer here. |
| `apply_owned(owned)` | stock baseline → **engine swap** → upgrades → tuning → damage, then one terminal voice rebuild | a **saved `OwnedCar`**: the player's car, HQ car-park and tuning-lift props. |
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

## UI

- **Upgrades grid, the `engine` tile** (`UpgradeOptions.SLOT_ENGINE`, drawn by
  `scripts/upgrades_grid.gd` like any other slot) — the tile reads the car's current
  engine name (`EngineSwap.current_engine_id` → `EngineLibrary`), and its popup lists
  **every roster engine**, the fitted one marked. Engines other than the fitted one are
  greyed with their reason — `"Locked"` before the capability special is won, `"Needs
  token"` at 0 tokens (`Save.engine_swap_tokens_owned()`). Health never affects it.
  Picking an engine does not perform the swap: the tile calls the host's `on_swap`
  callback (`UpgradesGrid._apply_option`) and the HOST runs the flow, because a swap needs
  a partner car to be picked out in the car park. So the tile is effectively **lift-only** —
  only `hq.gd` passes `on_swap`. For the same reason the tile does **not** grey itself for
  "no other car to swap with": whether a partner exists is a fact about the swap flow, not
  about this car's engine, and `hq.gd._enter_engine_swap` is the one place that knows.
- **Mystery box — NOT on this page.** It used to be a lift-only upgrades-page row: a box is a garage-WIDE
  reward, not a property of the car on the lift, so it moved to the **garage
  action row** as a "Mystery Box (N)" button (`hq.gd._refresh_garage_row` ->
  `_on_open_mystery_box`). Omitted entirely at 0 boxes held; disabled with the
  tooltip "Every car in the garage is fully upgraded" when
  `RewardSystem.any_car_has_room(Save.profile)` is false. See
  [reward-system.md](reward-system.md) → "Mystery box" for the trigger, resolver,
  and full opening sequence (including why the modal check must precede the spend).
- **Car-park swap mode** (`hq._enter_engine_swap` / `_carpark_swap_mode`) —
  pressing Swap Engine opens the car park listing **every** OTHER owned car (the
  current car itself is excluded — no self-swap); no car is filtered out on
  health. It reuses the car park's normal cycle-and-frame flow; the Start button
  reads **"Swap Engine"**. Swap mode shows no repair/kit warning label (Start
  stays enabled, warning hidden). Confirming (`hq._select_swap_target`) always
  pops `_show_swap_confirm` — OK **"Swap"**, disabled when no token is held —
  and OK (`_on_swap_confirmed` → `_commit_engine_swap`) calls `Save.swap_engines`
  (which spends the token). It forces the lift prop to respawn with the new
  engine, and returns to the lift's Upgrades page. **Back**
  (`_car_back`) returns to the lift with no change (each car-park mode's Back returns
  to its own origin — the starter picker to the exterior, the challenge picker to the
  garage).
  While picking a partner, `hq_carpark.gd._refresh_swap_preview()` (called from
  `_focus_changed`) shows a two-way hp/tonne preview in a `RichTextLabel`
  (`hq._swap_preview_label`) below the stats panel: since a swap EXCHANGES
  engines, both the lift car (receiving the focused partner's engine) and the
  focused partner (receiving the lift car's engine) get a row, each with a
  coloured ↑/↓/— arrow for the resulting delta. The pure math is
  `EngineSwap.pw_after_swap(owned, entry, donor_engine_id)` (returns kW/kg;
  scaled by `CarLibrary.KW_KG_TO_HP_TONNE` for display). Hidden outside swap
  mode.
- **Upgrades grid, the `tune` tile** (`UpgradeOptions.SLOT_TUNE`) — the detune, sitting in
  the grid beside the parts. It is NOT a
  `TuningLibrary.AXES` row and no longer lives on the tuning page — detune is a
  power / power-to-weight knob, so it belongs with upgrades. Always **available**
  (no upgrade gate). The tile reads the live percentage, and it is the ONE tile whose
  press opens a **slider** rather than a list (`UpgradeSlotPopup.open_slider`, `0%`–`100%`
  step 5, built from the shared `SliderRow`): detune is continuous, and quantising it into
  21 list rows would be a slider drawn badly. The slider writes live —
  `frac = value / 100.0` through `Save.set_engine_detune` at `tuning.engine_detune`, with
  no rebuild, since rebuilding mid-drag would free the popup out from under the grab — and
  its value label reads the resulting live power-to-weight (`200 HP/T`,
  `UpgradesGrid._detune_label_text`); the label does not flag the limit. A `rating_limit` ceiling is instead enforced by the
  overlay's **gated Done button** (red, blocks closing and Esc while over — the
  start-line Upgrades overlay, the reward reveal and the car-park Change-Upgrades popup
  all source one from `DrivingContext`, and only a Rally Challenge has one; the HQ lift
  omits it, keeping a plain Back for free tuning).
  The tuning panel's **Reset to neutral** (now a button in the Tuning page's bottom
  action row, see [tuning.md](tuning.md)) no longer touches detune — it clears
  only the handling axes and **preserves** `tuning.engine_detune`.
- **Car-park detune-to-enter prompt** — an owned car OVER a rally's `pw_max`
  cap still parks in the rally car-select lineup and LOOKS eligible there (no
  warning label, plain Start — saves overlay space); pressing Start pops a
  **"Too powerful" confirm** whose only route through is **Change Upgrades**
  (the other button is Cancel). It opens the gated `UpgradesGrid` popup where the
  player sheds power for themselves — the `tune` tile's detune slider, the weight
  slot's ballast, or stripping parts — and the popup's gated **Done** button
  refuses to close until the build is under the cap. That fix is an **ordinary
  garage edit and permanent** (it persists after the rally); there is **no**
  temporary, auto-reverted per-rally detune here any more. Once under the cap the
  player closes the popup and re-presses Start to launch (close → re-press, no
  auto-launch). The old one-press **Detune to N% & Start** agreement and its
  `RallySession.register_detune_revert` revert flow have been removed. Rallies
  have no hard power floor, so an underpowered car can still enter a higher
  class — it just gets a non-blocking "Underpowered" warning at car selection in
  the HQ car park.
  (The `RallySession.register_detune_revert` API itself still exists and is
  unit-tested; it is just no longer driven by this flow.) See
  [menus.md](menus.md) → CARPARK.

### Navigation

The `engine` tile is an ordinary `Control.FOCUS_ALL`
button in the upgrades grid, and the engine rows in its popup are ordinary focusable rows
(native-focus regime — see [menus.md](menus.md) → "Menu navigation"), so the swap is
reachable by keyboard/gamepad exactly like every other tile, with no extra
wiring. Once pressed, the car park it opens is the SAME diegetic 3D station
used by the wheel view and the starter picker — it reuses that station's existing
`menu_left`/`menu_right` (cycle the focused car), `menu_select` (confirm via
`_on_start_pressed` → `_select_swap_target`), and `menu_back` (`_car_back`,
which returns to the lift when `_carpark_swap_mode` is set) handlers in
`hq.gd._unhandled_input`, so swap mode is fully keyboard/gamepad navigable by
construction — it adds no new input surface, only a new car-park **mode flag**
that changes what `_on_start_pressed`/`_car_back` do at the existing
confirm/back actions. The detune slider lives in the `tune`
tile's popup (`UpgradeSlotPopup.open_slider`, wherever `UpgradesGrid` is hosted), which
opens with the slider focused and uses the same left/right-nudges-the-focused-slider
handling as every other slider in the game (see [menus.md](menus.md) → "Menu
navigation"). The
mystery-box row's **Open** button is likewise an ordinary `Control.FOCUS_ALL`
button (`set_meta("upgrade_focus_key", "open_box")` keeps the cursor on it
across a rebuild, same trick the other rows use), so it needs no extra nav
wiring either.

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
`test_save_manager.gd` covers `swap_engines` spending a token, blocking without
one, succeeding between damaged cars (HP untouched), `engine_swap_tokens_owned`,
`set_engine_detune` persistence, and the stock-reversion clearing behaviour.
`test_reward_system.gd` covers the token being a drawable pool member. `test_car.gd` covers `_apply_engine_swap`'s mass/CoM/
drivetrain rebuild. `test_upgrade_library.gd` covers `effective_meta` resolving
the swapped engine and detune scaling power-to-weight. `test_tuning_library.gd`
covers `TuningLibrary.apply`'s `engine_detune` torque scaling. `test_upgrades_grid.gd` covers the
`engine` and `tune` tiles (their options, locked reasons and the slider popup);
`test_menu_flow.gd` covers car-park swap mode and
the car-park detune-to-enter prompt (over-cap car parks looking eligible; Start
pops the "Too powerful" confirm; Change Upgrades opens the gated upgrades popup).
`test_rally_library.gd`
covers `RallyLibrary.qualifying_detune` itself. The mystery-box row (Lift-only,
disabled states, opening installs onto another car) is covered in
`test_menu_flow.gd`; the box's draw/resolve logic is covered in
`test_reward_system.gd` / `test_save_manager.gd` — see
`features/reward-system.md` → "Mystery box".
