# Upgrade Catalogue

`UpgradeLibrary` (`scripts/upgrade_library.gd`, `class_name UpgradeLibrary`) is
the catalogue of upgrade **items** — authored content (like `CarLibrary` /
`RallyLibrary`), not player state. The save profile holds the player side (each
`OwnedCar.installed_upgrades` / `disabled_upgrades`, keyed by the stable `id`
here, plus the consumable `inventory` — repair kits + engine swap tokens); this library defines
what those ids mean and what each does to a fielded car.

**Upgrades are car-bound.** An upgrade belongs to the car it was won for and
**never moves** to another car or into a shared pool. When a part is won it is
fitted straight onto the driven car (`rally_session` installs it **disabled**;
the podium's Apply enables the player's pick). A fitted part can be **toggled
on/off** in the upgrades menu (`OwnedCar.disabled_upgrades`); only **enabled**
parts contribute effects, and a car keeps at most one enabled part per slot. A
car can never hold the same upgrade twice (**per-car dedup**), and the part stays
on the car for good (not on swap, and not when the car is wrecked). Tuning
(`features/tuning.md`, the lift) is free, reversible per-car config nudges. This
is the upgrades half.

## Catalogue

`const UPGRADES: Array[Dictionary]`, each an UpgradeDef: `id`, `name`, `slot`
(`turbo` / `aero` / `weight` / `brakes` / `drivetrain`, or `""` for consumables),
`tier` (reward-tier gating), `consumable`, an optional `free` flag (always-available,
never-drawn parts — the ballast; see below), and `effect` (config-field → delta/multiplier).

The **`drivetrain` slot** holds the **Drivetrain Swap** kit, whose `effect` is a single
`unlocks_drivetrain_swap` flag (skipped by `apply`, like the other `unlocks_*` gates).
It gates the garage FWD/RWD/AWD selector and, via `resolve_drive_override`, lets
`effective_meta` report the player's chosen `drive_mode` — so a swap changes handling
AND rally eligibility (`resolve_drive_override`, and the per-car
`OwnedCar.drivetrain_override`; see `features/drivetrain-and-tires.md`).

**The drivetrain kit is the one slot with NO enable/disable.** Unlike every other
fitted part, `drivetrain_swap_unlocked` checks **installed** (not enabled): owning the
kit IS the unlock, and the selector's stock choice plays the "off" role (disabling would
just re-select the original drive mode). So its podium reveal **always installs it
enabled** with no Apply/Keep choice (`podium.gd._offer_upgrade_choice`), and its upgrades-menu
row shows only the selector — no toggle (`UpgradesMenu._make_slot_row`). The FWD/RWD/AWD selector
is **always shown**, even before the kit is won: until it's owned only the car's stock drive
mode is selected + enabled and the other two modes are greyed (earn-gated as a whole, like a
part option greys until its kit is fitted) — so the row reads like every other slot rather
than a bare "— empty —" line.
The **`weight` slot** is a **power-to-weight lever**, not an ordinary earn-gated part
row. It holds three parts plus `Stock`: two **BALLAST** options that ADD weight —
**Heavy Ballast** (`ballast_large`, `mass_mult` 1.5) and **Light Ballast**
(`ballast_small`, `mass_mult` 1.2) — and one **Weight Reduction** kit
(`weight_reduction`, `mass_mult` 0.80) that SHEDS weight. Both ballast parts carry a
**`free: true`** flag: they are **always selectable on every car** (no earning
required) and are **never drawn as a reward** (`reward_system._parts_at_or_below`
skips `free` parts alongside consumables — see `UpgradeLibrary.is_free`). The ballast
lets a player deliberately add mass to drop power-to-weight and qualify for a lower
rally class (a p/w lever alongside engine detune). Weight Reduction is the slot's one
**earned** reward-pool option — the "lightweight" performance drop, greyed until won.
The weight slot uses a **bespoke selector** in `UpgradesMenu` rather than the generic
earn-gated option row — see below.
Current set: two **turbo kits** (turbo slot — `turbo_small` tier 1, `turbo_large`
tier 2), an aero kit, the three **weight** parts above,
a big brake kit, and the two consumables — the **repair kit** and the **engine
swap token** (both `slot: ""`, held in the shared `inventory`; the token is spent
by `Save.swap_engines`, see [engine-swap.md](engine-swap.md)). The concrete part
list and exact numbers are a balance pass (deferred); these are single-purpose
defaults. The aero kit also **reveals the car's spoiler/splitter mesh** while enabled — see [aero-parts.md](aero-parts.md).

The upgrades menu is a **reusable `UpgradesMenu` component** (`scripts/upgrades_menu.gd`,
mirroring `TuningPanel`): the HQ lift mounts it as its Upgrades page, and the car-park
**detune-to-enter prompt** mounts a second instance in its Change-Upgrades popup so a
too-powerful car can shed power by stripping parts instead of detuning (see
[menus.md](menus.md) → CARPARK). It owns its `Save` persistence and reports edits via an
`on_change` callback so the host re-fields the car. There is **no stats line** at the top;
the live power-to-weight readout instead lives on the **engine-detune slider's value label**
(e.g. `80% - 200 hp/tonne`, recomputed from `effective_meta` on every rebuild), and that
slider now sits at the **bottom** of the menu — below the part-slot selectors and the
lift-only engine-swap row — as the final power adjustment. Lateral G is no longer shown here.
The engine-swap row is **lift-only** (the host passes `on_swap`); the popup
leaves it unset and drops the row, since the swap flow would change the HQ view.

When a host passes a power-to-weight limit (`pw_limit >= 0` — the start-line pre-race
overlay and the car-park over-powered Change-Upgrades popup), the overlay's **close button
is gated** (`UpgradesMenu.bind_close_button` + `request_close()` / `can_close()`): it reads
**Done**, and while the current build exceeds the cap it turns **red**, its text becomes
**"Over limit — reduce to N hp/tonne"**, and it **blocks closing** — both the button press
and Esc / controller-back are refused (hosts hand `request_close` to `MenuNav` as `on_back`)
until the player drags the detune slider back under the cap. With no limit set (the HQ garage
lift), the button stays a plain **Back** and closes freely.

**Every part slot is an earn-gated option selector** (`UpgradesMenu._make_option_selector`), built
to read like the drivetrain picker: `SLOT:` on the left, then `Stock` + one button per
catalogue part in that slot on the right. `Stock` is always selectable (the "off" state —
the car's un-upgraded factory config, hence the label rather than `None`); each part option
is **greyed until that kit is fitted** to this car, and the active one is
bracketed **and painted the house accent green** so the current pick stands out. The turbo slot has two parts — `Stock` / `Small` / `Big` (`turbo_small` /
`turbo_large`, shown by their short `menu_label`); the single-part slots read `Stock` /
`<Kit>` (e.g. `Aero: Stock / Aero Kit`, using the part's full `name`). Under the hood it's
the ordinary per-slot enable/disable machinery (`Save.set_upgrade_enabled` via
`UpgradesMenu._set_slot_option`): picking a part enables it (same-slot exclusivity switches any
sibling off), picking `Stock` disables every part in the slot (the underlying id is still
`""`). Kits are won and fitted disabled, then enabled via the selector in the upgrades menu
(either at the HQ lift or after an event's standings reveal confirms the won part); the selector
is the menu presentation replacing the old Enable/Disable toggle rows.
Drivetrain remains one odd one out (its selector is a `drive_mode` override, not a part
enable, and it uses a single unlock rather than per-option earn-gating — see above).

**The `weight` slot is the other exception** — it has a bespoke selector
(`UpgradesMenu._make_weight_selector`), NOT the generic earn-gated option row. Its
options are ordered **heaviest → lightest** with `Stock` (no change, the default)
sitting **between** the ballast (`mass_mult` > 1) and the lightweight (`mass_mult` < 1),
so for a ~1000 kg car the row reads **+500kg  +200kg  [Stock]  -200kg**. Each button is
labelled by its mass delta off the car's **base** mass (the current effective mass ÷ the
currently-active weight multiplier), rounded to the nearest 100 kg and signed with a
`kg` suffix (`+500kg`, `-200kg`); `Stock` reads `Stock`. The two ballast buttons are
**always enabled** (they're `free`); the lightweight (earned) button **greys until won**;
the active pick is bracketed + accent-green like every other slot. Selecting a `free`
ballast the car doesn't own yet **installs it on the spot** then enables it exclusively
(one weight part enabled at a time); `Stock` disables all weight parts.

The turbo slot installs a **turbocharger** rather than a flat power bump: each
turbo kit's `effect` is a single `install_turbo` key whose value is a dict of turbo
parameters (`turbo_boost_gain`, `turbo_inertia`, `turbo_omega_ref`,
`turbo_drive_gain`, `turbo_drag_coef`, and the whistle/BOV audio gains). `apply`
sets `turbo_enabled = true` and copies those onto `cfg`, so fitting a turbo (or a
bigger one over a stock turbo) reshapes the delivered torque curve dynamically —
the full model lives in `features/forced-induction.md`. The old flat
`peak_torque_mult` stage kits are gone. **Superchargers are never upgrades** — they
are an intrinsic engine property (`features/forced-induction.md`).

## Effect-application pipeline

A fielded car's live `Config.data` is built in a fixed order so effects compose
predictably:

1. **CarLibrary baseline** — `apply_car` copies the model's spec into `Config.data`.
2. **Enabled upgrades** — `UpgradeLibrary.apply(owned_car, cfg)` walks
   `enabled_upgrades(owned_car)` (installed minus the menu-disabled ones) and
   applies each `effect` on top; a disabled part stays fitted but is inert.
3. **Per-car tuning** — the player's tuning deltas (`features/tuning.md`).
4. **Damage multipliers** — power/steer degraded by HP fraction (`features/damage.md`).

`apply` is pure: it mutates only the passed-in live `cfg`, never the authored
`.tres`. `*_mult` keys multiply the baseline (`brake_torque`, `mass`); additive
keys add (`downforce_front` / `downforce_rear`); `install_turbo` writes the turbo
fields (see above).
`unlocks_*` keys are **flags**, skipped by `apply` — they gate tuning sliders, not
config. `aero_tuning_unlocked(car)` / `brake_bias_unlocked(car)` read those flags
so the tuning lift only exposes aero / brake-bias sliders when the matching kit
is fitted.

> **Mass re-sync:** `car.gd.apply_car` copies the baseline `mass` onto the
> RigidBody, but upgrades run *after* it (step 2), so `apply_owned` re-assigns
> `mass = Config.data.mass` after `apply` — otherwise a weight-reduction kit would
> lighten the config but leave the physics body at its baseline weight.

## Effective stats (display + eligibility)

`effective_meta(owned_car, meta)` returns a copy of a car's CarLibrary entry with
the power-to-weight inputs (`peak_torque`, `mass`) adjusted by its installed
upgrades. It's pure (never touches the authored `CARS` entry) and is what makes a
fitted turbo or weight reduction **change the displayed hp/tonne AND a car's
rally eligibility**: a turbo is **rated at peak boost** — `effective_meta`
multiplies `peak_torque` by `(1 + turbo_boost_gain)` (the stock engine's gain, or
an installed turbo kit's, whichever applies) so a turbocharged car reads as more
powerful and is gated accordingly. the HQ stats panel calls
`CarLibrary.power_to_weight(UpgradeLibrary.effective_meta(owned, entry))`, and the
two player-car eligibility checks (`hq._has_eligible_car`,
`hq._build_eligible_lineup`) pass `effective_meta` into `RallyLibrary.is_eligible`,
so an upgrade can push a car over — or back under — a rally's `pw_max` ceiling.
The rival pool and reward-grant queries keep using the raw `CARS` entries (those
are unmodified roster cars, not the player's upgraded ones).

## Install / repair (in `Save`)

The slot policy and HP healing live in `Save` (it owns inventory + HP):

- **`Save.install_upgrade(instance_id, item_id, enabled := true)`** — fits a won
  part to a car. Upgrades are **car-bound**, so this takes no inventory (there is
  no shared pool for slottable parts) — it just records the fit on the OwnedCar.
  `enabled` controls the freshly-fitted state: `true` enables it (switching off
  any same-slot incumbent, which stays fitted, just disabled); `false` parks it
  disabled. The reward loop fits every won part with `enabled = false`; the
  standings reveal confirms the part with a single "Next" step, and the player
  enables it later in the upgrades menu. Applied parts **accumulate** on the
  car; at most one is **enabled** per slot. Fitting a part the car already carries
  is rejected (**per-car dedup**). Consumables and unknown ids can't be slotted
  (rejected). There is **no uninstall** and no move — a fitted part can only be
  toggled off, never moved to another car, and a **wrecked car keeps its parts
  fitted** (the car isn't destroyed — see
  [save-persistence.md](save-persistence.md)). The HQ upgrades menu only toggles
  parts already on the car (no apply-from-pool); see `features/reward-system.md`
  for the standings reveal flow.
- **`Save.set_upgrade_enabled(instance_id, item_id, enabled)`** — the upgrades-menu
  toggle for an applied part. Free, instant and reversible; enabling a part
  disables its same-slot siblings (`OwnedCar.disabled_upgrades` holds the
  toggled-off ids). `UpgradeLibrary.enabled_upgrades(car)` /
  `is_enabled(car, id)` are the read side every effect/gate consumer uses.
- **`Save.use_repair_kit(instance_id)`** — spends one repair kit to **fully
  restore** the car to its CarLibrary `max_hp`. The only way HP goes back up, and
  what revives a wrecked (0 HP) car. Offered at the tuning lift and at the
  car-select screen when a chosen car is too damaged to enter.

## Reward integration

Upgrades are the **per-event** reward: one is drawn at each non-final event
boundary (events 1 & 2 of a 3-event rally); the car is the per-rally reward. The
reward draw picks an `UpgradeDef` by `tier`, clamped by progress, excluding parts
already on the driven car — and never `free` parts (the ballast is always
available, so it's not a reward) — that policy is reward-system logic
(`reward-system.md`); this library just provides the tier-keyed pool. The flow
controller fits each won part straight onto the driven car via
`Save.install_upgrade(..., enabled=false)` (repair kits, being consumable, go to
`Save.add_item` instead), and the **standings reveal** (`scripts/upgrade_reveal.gd`,
not the podium) confirms the part with a single "Next" step — see `features/reward-system.md`.

## Tests

`tests/headless/test_upgrade_library.gd` — catalogue validity (unique ids, known
slots, consumables have no slot), lookups, effect application (multiplies/adds on a
baseline incl. `mass_mult`; empty list is a no-op), `effective_meta`
(lightens/empowers a meta copy without mutating the source), and the aero /
brake-bias tuning gates. `test_rally_library.gd` covers an installed upgrade
qualifying / disqualifying a car for a rally's pw band; `test_car_library.gd`
covers `apply_owned` re-syncing the RigidBody mass after a weight-reduction kit.
Disabled parts being inert everywhere (config, effective stats, tuning gates) is
covered there too. Same-slot exclusivity (applying/enabling a part disables the
incumbent instead of scrapping it), the `enabled=false` disabled fit, per-car
duplicate-fit rejection, the same part fitting two different cars independently,
the `set_upgrade_enabled` toggle, consumable/unknown rejection, repair-kit
heal+clamp, wreck (parts stay on the car), and the v1→v2 migration stripping the
old unbound pool are in `test_save_manager.gd` (they need the Save profile). The
garage upgrades menu having no apply-from-pool rows, the earn-gated option selectors
(turbo `Stock`/`Small`/`Big` and the single-part `Stock`/`<Kit>` slots — greyed until won,
picking enables, `Stock` parks), and the option-selector focus-retention regression are in
`test_menu_flow.gd`. The reward reveal's confirmation (a single "Next" step) and the
consumable / drivetrain-kit skip are in `test_upgrade_reveal.gd`; the standings
Collect-reward flow that hosts it is in `test_menu_flow.gd`.
`test_rally_session.gd` covers per-event won parts binding to the driven car with no
slottable part won twice per rally (the dedup'd draw).
