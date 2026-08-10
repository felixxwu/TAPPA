# Upgrade Catalogue

`UpgradeLibrary` (`scripts/upgrade_library.gd`, `class_name UpgradeLibrary`) is
the catalogue of upgrade **items** — authored content (like `CarLibrary` /
`RallyLibrary`), not player state. The save profile holds the player side (each
`OwnedCar.installed_upgrades` / `disabled_upgrades`, keyed by the stable `id`
here, plus the consumable `inventory` — engine swap tokens and mystery boxes); this library defines
what those ids mean and what each does to a fielded car.

**Upgrades are car-bound.** An upgrade belongs to the car it was fitted to and
**never moves** to another car or into a shared pool. A part is acquired by
**buying a copy for that car with stars** (`Save.buy_part`, from the slot row
itself — see "Acquisition" below); it fits **disabled**. A fitted part can be **toggled
on/off** in the upgrades menu (`OwnedCar.disabled_upgrades`); only **enabled**
parts contribute effects, and a car keeps at most one enabled part per slot. A
car can never hold the same upgrade twice (**per-car dedup**), and the part stays
on the car for good (not on swap, and not when the car is wrecked). Tuning
(`features/tuning.md`, the lift) is free, reversible per-car config nudges. This
is the upgrades half.

## Catalogue

`const UPGRADES: Array[Dictionary]`, each an UpgradeDef: `id`, `name`, `slot`
(`turbo` / `aero` / `weight` / `drivetrain` / `nitrous`, or `""` for
consumables), `consumable`, an optional `free` flag (always-available,
never-drawn parts — the ballast; see below), an optional `requires_upgrade_id`
(per-car prerequisite gating — see below), an optional `unlocked_by_rally`
(garage-wide event gating — see below), an optional `weight` (reward-pool
rarity, default 1.0 — see below), and `effect` (config-field →
delta/multiplier).

**`tier` is gone.** Upgrades used to carry a `tier` walked by
`RewardSystem._parts_at_or_below` (also gone); the event gate below replaced it
— see `reward-system.md`. The draw pool is now a **flat** filter with no tier
concept at all. (`CarLibrary`'s `reward_tier` is unrelated and still tiers the
**car** draw.)

**Reward-pool weight (`weight`).** Optional, defaulting to 1.0.
`UpgradeLibrary.pool_weight(id)` reads it. This is the rarity knob that
replaced `tier`: tier gated on rally **difficulty** and had gone vestigial
(nearly every part sat at tier 1), whereas the event gate below now handles
availability-over-time and `weight` handles rarity within whatever is
currently available — a more direct lever, and the reward pool already spoke
in weights (that's how the engine swap token gets its low drop rate).

**Event gate (`unlocked_by_rally`).** Garage-wide availability over *time*: an
item can be withheld from the reward pool entirely until a particular special
event has been **won**. `UpgradeLibrary.unlocked_by_rally(id)` reads the
field; `UpgradeLibrary.rally_gate_met(item_id, profile)` returns `true` when
the field is absent (default: ungated), else whether that rally is recorded
`completed` in `profile.rallies` — and `completed` already means a **top-3
finish**, so this genuinely reads "was the event won". Keyed on the **rally id** — never
on a star total, and stars are a spendable currency now
([star-economy.md](star-economy.md)), so a part can't be bought. The special
itself opens on the count of COMPLETED ORDINARY rallies
(`RallyLibrary.completions_required`), which is what makes the chain
"race enough events → win the special → the part enters the pool".
This gate is about **earning** a part, never about **keeping** one:
`UpgradeLibrary.apply` walks `installed_upgrades` and never consults it, so a
part already fitted keeps working even if its gate would no longer be met.
Gated parts today: `turbo_large` → `sp_woodland_trial`, `drivetrain_swap`
(now named "Drivetrain Conversion") → `sp_dust_trial`, `supercharger` →
`sp_lakeshore_trial`, and `nitrous` → `the_showdown`. See `reward-system.md` for how
`RewardSystem` reads this gate into the draw pool.

**Prerequisite gate (`requires_upgrade_id`).** The **per-car** counterpart to
the event gate: an item that should unlock through owning ANOTHER item on
*that car*, rather than (or in addition to) the garage-wide event gate. `""`/absent
(the default) means no prerequisite. `UpgradeLibrary.requires_upgrade_id(id)`
reads the field; `UpgradeLibrary.prerequisite_met(item_id, owned_car)` checks
it against **that car's** `installed_upgrades` and is one of the checks
`RewardSystem._eligible_parts` runs to keep a gated item out of the draw pool
until the driven car has its prerequisite fitted. Deliberately **per-car, not
garage-wide** — upgrades are car-bound, so every car has to climb its own
ladder; a sibling car owning Small Turbo does not unlock Big Turbo elsewhere.
The **forced-induction ladder** uses this: **Big Turbo (`turbo_large`)**
requires `turbo_small` (plus its own event gate above), and the **Supercharger
(`supercharger`)** requires `turbo_large` (plus its own event gate) — so a car
climbs the chain *and* the ladder has to have been unlocked garage-wide.

**The chain can also be satisfied by CASCADE.** When a special event awards the part it
gates (`RewardSystem.grant_special_unlock` — see
[reward-system.md](reward-system.md) → Special-event unlock), the missing rungs beneath it
are granted to that car too, so the award is usable rather than a part the car cannot run.
Only the awarded part is ENABLED; the cascaded rungs are fitted but parked, because a ladder
shares one `slot` and its rungs are mutually exclusive alternatives.

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
required) and are **never drawn as a reward** (`RewardSystem._eligible_parts`
skips `free` parts alongside consumables — see `UpgradeLibrary.is_free`). The ballast
lets a player deliberately add mass to drop power-to-weight and qualify for a lower
rally class (a p/w lever alongside engine detune). Weight Reduction is the slot's one
**earned** reward-pool option — the "lightweight" performance drop, greyed until won.
The weight slot uses a **bespoke selector** in `UpgradesMenu` rather than the generic
earn-gated option row — see below.
Current set: three **forced-induction kits** (turbo slot — `turbo_small` ungated,
`turbo_large` prerequisite-gated on the same car having `turbo_small` plus its own
event gate, and `supercharger` prerequisite-gated on `turbo_large` plus its own
event gate, see above; the blower's belt physics are in [forced-induction.md](forced-induction.md)),
an aero kit, the three **weight** parts above, the drivetrain conversion kit, a
**fifth `nitrous` slot** (see below), and two consumables — the **engine
swap token** and the **mystery box** (`MYSTERY_BOX_ID`, `"mystery_box"`; both
`slot: ""`, held in the shared `inventory`). (A third, the repair kit, was retired —
damage is one-way now; see [damage.md](damage.md).) The token is spent
by `Save.swap_engines`, see [engine-swap.md](engine-swap.md); the swap
**capability** itself is unlocked by winning the engine-swap special
(`RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY` / `RallyLibrary.engine_swaps_unlocked`;
`engine_swap_completion_requirement()` reports how many ordinary rallies that
special needs), but tokens drop and accumulate from
the start regardless (see `reward-system.md`). The mystery box
is drawn instead of a normal upgrade once a car has nothing left to gain (and,
once swapping is unlocked, the player is token-rich too — see
`reward-system.md`), and is also handed out by the online Rally Challenge
(`ChallengeSession._COMPLETION_REWARD`). Opened from the **HQ garage row**, it
fits a random upgrade to any owned car with an empty slot — the currently
selected one included — see [reward-system.md](reward-system.md)

### The `nitrous` slot

A fifth `SLOTS` entry, deliberately absent from the upgrades menu — the
mechanic, gauge, input and audio are documented in full in
[nitrous.md](nitrous.md); this file only covers its place in the catalogue.
It is a SINGLE part with an ordinary garage row — it was a four-rung ladder
(`nitrous` → `nitrous_tank` → `nitrous_shot` → `nitrous_race`) in a hidden slot,
collapsed to one entry carrying the top rung's numbers.
`UpgradeLibrary.HIDDEN_SLOTS` is empty as a result. The `install_nitrous` effect uses the `"write_fields"` op with
`feeds_pw: false` in the `EFFECTS` table below, so nitrous can never move
`effective_meta`'s power-to-weight or a car's rally eligibility.
→ "Mystery box" for the trigger, resolver, and reveal. The concrete part
list and exact numbers are a balance pass (deferred); these are single-purpose
defaults. The aero kit also **reveals the car's spoiler/splitter mesh** while enabled — see [aero-parts.md](aero-parts.md).

The upgrades menu is a **reusable `UpgradesSimple` component** (`scripts/upgrades_simple.gd`,
mirroring `TuningPanel`), which wraps the older `UpgradesMenu` (`scripts/upgrades_menu.gd`)
as its **Advanced** page — every host below mounts `UpgradesSimple`, never `UpgradesMenu`
directly (see [menus.md](menus.md) → "The upgrades page: Simple over Advanced"):
the HQ lift mounts it as its Upgrades page, the car-park
**detune-to-enter prompt** mounts a second instance in its Change-Upgrades popup so a
too-powerful car can shed power by stripping parts instead of detuning (see
[menus.md](menus.md) → CARPARK), and the standings/podium **reward reveal**
(`scripts/upgrade_reveal.gd`, `_on_upgrades_pressed`/`_build_upgrades_overlay`) mounts a
third instance behind an **Upgrades** button on its post-spin action row, so a player can
slot the just-won part immediately instead of waiting for the next stage/HQ visit — see
[menus.md](menus.md) → "Collect reward on the standings". It owns its `Save` persistence
and reports edits via an
`on_change` callback so the host re-fields the car. There is **no stats line** at the top;
the live power-to-weight readout instead lives on the **engine-detune slider's value label**
(e.g. `80% - 200 hp/tonne`, recomputed from `effective_meta` on every rebuild), and that
slider now sits at the **bottom** of the menu — below the part-slot selectors and the
lift-only engine-swap row — as the final power adjustment. Lateral G is no longer shown here.
The engine-swap row is **lift-only** (the host passes `on_swap`); the popup
leaves it unset and drops the row, since the swap flow would change the HQ view.

**The Advanced page is not always shown whole.** `UpgradesSimple`'s stat rows each carry a
wrench that opens it **filtered to one category** via
`UpgradesMenu.set_filter(slots, show_detune, show_swap)` — Speed shows the `turbo`/`nitrous`
rows plus the detune slider and the swap row, Grip shows `aero`, Lightness `weight`,
Stability `drivetrain` — so any single row/slider described here may legitimately be absent
from a given visit to the page. `rebuild()` applies the filter, `is_filtered()` reports it,
and an empty slot list restores the full page (what the **Advanced** button opens). See
[menus.md](menus.md) → "The stat block is a CATEGORY INDEX" for the mapping and its
rationale.
There is no mystery-box row on this page any more — a box is a garage-WIDE
reward, so it lives on the HQ garage action row instead. See
[reward-system.md](reward-system.md) → "Mystery box" and
[engine-swap.md](engine-swap.md).

When a host passes a power-to-weight limit (`pw_limit >= 0` — the start-line pre-race
overlay, the car-park over-powered Change-Upgrades popup, and the reward reveal's
Upgrades overlay, which reads it off `RallyLibrary.by_id(RallySession.rally_id())
.restriction.pw_max` — the same source the start line uses), the overlay's **close button
is gated** (`UpgradesMenu.bind_close_button` + `request_close()` / `can_close()`): it reads
**Done**, and while the current build exceeds the cap it turns **red**, its text becomes
**"Over limit — reduce to N hp/tonne"**, and it **blocks closing** — both the button press
and Esc / controller-back are refused (hosts hand `request_close` to `MenuNav` as `on_back`)
until the player drags the detune slider back under the cap. With no limit set (the HQ garage
lift), the button stays a plain **Back** and closes freely.

**Every part slot is an earn-gated option selector** (`UpgradesMenu._make_option_selector`), built
to read like the drivetrain picker: the slot name on the left (**no trailing colon** — this
page's own detune row has none, and neither does any Tuning row), then `Stock` + one button per
catalogue part in that slot on the right. `Stock` is always selectable (the "off" state —
the car's un-upgraded factory config, hence the label rather than `None`); each part option
is **greyed until that kit is fitted** to this car, and the active one is
bracketed **and painted the house accent green** so the current pick stands out.

**A slot row NEVER wraps.** `UpgradesMenu._option_row()` is the shared builder — a flat
`HBoxContainer` holding the label and every option button as siblings — used by both
`_make_option_selector` and `_make_drivetrain_selector` (the weight row builds its own
equivalent for the same reason). It used to be an `HFlowContainer`, and a row with more
options than fit spilled onto a second line: that read as a layout bug rather than a
feature — the **aero** row, with one part beside `Stock`, was landing its only real option
on a line of its own — and it made a row's own reported height depend on how many options it
happened to have. It is also **not** an HBox wrapping a nested container: nesting a
container inside a fixed-line one made each slot row's height unreliable mid-layout, which
threw off the `VBoxContainer` stacking the rows and cost them their vertical stacking. A
single flat box sizes itself in one pass. Options that no longer fit are **squeezed** by
`_tighten_option_padding` (see `_OPTION_BUTTON_PAD`) rather than moved to another line.
Guarded by `test_upgrades_menu.gd::test_a_slot_row_never_wraps`, which asserts no wrap at
two widths (it replaced an older test that measured `get_line_count()` — a measurement the
flat row can no longer even report).

**Locked options are not shown at all** (`UpgradesMenu._slot_parts`) — not
greyed, absent. A greyed row the player cannot act on only raises "when do I get
this?", which the garage cannot answer; the MAP is the surface that advertises
what a special unlocks. So the turbo row reads `Stock | Small` for a new player and
grows to `Stock | Small | Big | Supercharger` as the turbo and supercharger
specials are won. A slot whose every option is still locked gets **no row at all, label
included** (`_make_slot_row` returns null) — for a new player that is the whole
drivetrain row. The engine-swap row is hidden on the same rule while the capability
is still locked. Two exceptions keep the display honest: a part already FITTED shows
regardless of its gate (the gate governs earning, never keeping), and a part that
is unlocked but merely unfitted stays visible-and-disabled, since winning it is
something the player can actually act on.

The turbo slot has three parts — `Stock` / `Small` / `Big` / `Supercharger` (`turbo_small` /
`turbo_large` / `supercharger`, shown by their `menu_label`); the single-part slots read `Stock` /
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
`peak_torque_mult` stage kits are gone. The **`supercharger`** part is the same
shape under a sibling key, `install_supercharger`, and both keys run the SAME
`install_induction` op — the flag each one enables, the rival state each one **clears**
(symmetrically: a turbo cancels the blower's gain too) and the sub-key that feeds
power-to-weight are all descriptor DATA, not branches. `apply` sets
`supercharger_enabled = true`, clears `turbo_enabled` (a blown car has no
turbo — they share the slot) and copies the belt fields
(`supercharger_boost_gain` / `supercharger_rpm_ref` /
`supercharger_parasitic_coef` and the whine gain) onto `cfg`. A *stock* blown
engine still carries no physics — it leaves the gain at 0 and the flag is
audio-only (`features/forced-induction.md`).

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
`.tres`. `*_mult` keys multiply the baseline (`mass`); additive
keys add (`downforce_front` / `downforce_rear`); `install_turbo` writes the turbo
fields (see above); `install_nitrous` (`"write_fields"` op) straight-splats its
fields onto `cfg` with no enable flag and no slot rival to clear — `has_nitrous()`
in the live sim reads the values themselves, so a zero gain/tank already reads
as "not fitted" (see [nitrous.md](nitrous.md)).
`unlocks_*` keys are **flags**, skipped by `apply` — they gate tuning sliders, not
config. `aero_tuning_unlocked(car)` reads that flag so the tuning lift only exposes
the aero slider when the kit is fitted. Brake bias is **not** gated — it's a free
tuning axis on every car (see [tuning.md](tuning.md)).

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
`hq_carpark.gd._build_eligible_lineup`) pass `effective_meta` into `RallyLibrary.is_eligible`,
so an upgrade can push a car over — or back under — a rally's `pw_max` ceiling.
The rival pool and reward-grant queries keep using the raw `CARS` entries (those
are unmodified roster cars, not the player's upgraded ones).

### `aero_meta` — the same copy, plus downforce

`aero_meta(owned_car, meta)` is `effective_meta` with the enabled parts' **`add`
effects** (the aero kit's `downforce_front` / `downforce_rear`) folded in on top. It
exists as a separate call rather than as a widening of `effective_meta` because the two
answer different questions: `effective_meta` mirrors only the **power-to-weight-feeding**
effects, since p/w is what eligibility is judged on and **downforce doesn't move a car's
class**. But a grip readout has to show what the wing bought, and
`CarLibrary.max_lateral_g` reads its downforce off the meta it's handed — so the Simple
upgrades page's Grip row passes `aero_meta`, while every eligibility path keeps passing
`effective_meta`. Keeping them apart is what stops an aero part quietly changing which
rallies a car can enter.

### `CarStatBounds` — the roster-wide scale the stat bars are drawn against

`scripts/car_stat_bounds.gd` (`CarStatBounds`) caches the **min/max each comparable stat
reaches across the whole car roster** — `pw` (hp/tonne), `grip` (max lateral G) and `mass`
— as `{key: [lo, hi]}` from `all()`, with `fraction(key, value)` mapping a car's figure to
the 0..1 the Simple upgrades page's `StatBar` fills (see [menus.md](menus.md) →
`UpgradesSimple`). Grip is speed-dependent, so bounds are rated at `GRIP_REFERENCE_KMH`,
the same reference speed `UpgradesSimple` rates its Grip row at, so bounds can't be
computed at one speed and the figure displayed at another. The speed itself is never shown on the row — it's the same
for every car, so the comparison holds either way and the label's width goes to the blocks.

The scale spans the roster **as the cars ship** — each car's `effective_meta({}, entry)`,
i.e. stock. Stretching the top to the best car at its fully-upgraded ceiling was tried and
is worse: the shipped ceiling is roughly **2.5x** the best stock car, so every early-game
car collapsed into a single lit block and the page couldn't tell a hot hatch from a kei
van — losing all resolution exactly where most of the game is played. A heavily-upgraded
car just pegs its bar at full, which is both true and cheap to lose. The **floor is padded
`FLOOR_PAD` (10%) of the span below the worst car** so the slowest car still lights one
block (an entirely empty bar reads as broken, not as slow); the **top sits exactly on the
best car**, so a full bar keeps meaning "nothing ships faster than this". A degenerate
range (one car, or a synthetic roster of identical cars) returns `1.0` rather than dividing
by zero.

It's cached because the sweep walks every car through `effective_meta`. **Both catalogue
seams invalidate it** — `CarLibrary.override_for_test()`/`reset()` and
`UpgradeLibrary.override_for_test()`/`reset()` both call `CarStatBounds.invalidate()`,
since the bounds derive from both rosters; a test that installs synthetic cars while
holding stale bounds would draw bars against a scale from a different game. Covered by
`tests/headless/test_car_stat_bounds.gd`.

## Auto-Upgrade: `auto_build_plan`

`UpgradeLibrary.auto_build_plan(owned_car, meta, profile, stars, restriction := {},
free_only := false)` answers "give me the best build this car can have right now" as a
**pure function** — it returns a PLAN and never mutates anything:

```
{buy: [id], enable: [id], strip: [id], detune: float,
 drivetrain: int, cost: int, blocked: String, changed: bool}
```

`enable` / `strip` are toggles on parts the car already owns, `buy` is a purchase (fitted
enabled), `detune` is the **absolute** slider setting to write, `drivetrain` is a
drive-mode override or `-1` for "leave alone", and `blocked` is a non-empty reason when no
build can get this car in (wrong car type, wrong country) — something the solver must NAME
rather than hand back a plan that silently doesn't work. `changed` is the "does this do
anything" predicate, and it is deliberately a **plan difference**, not a p/w comparison
(`_finish`): swapping the player's ballast for an equivalent detune lands identical
power-to-weight with measurably more grip, and a p/w test would call that a no-op.

Three callers share this one rule instead of keeping three copies of it: the
**Auto-Upgrade button** (`AutoUpgradeRow`, see [menus.md](menus.md)), the **free restore at
the Start gate** (`Save.restore_free_build`), and the tests.

**The objective.** Only slots that feed power-to-weight take part in the search
(`_slot_feeds_pw` reads the same `EFFECTS` table `apply()`/`effective_meta` use, so a new
effect can't leave a slot unsearched); the rest — aero, drivetrain kit, nitrous — can't be
scored against the objective, so Auto never BUYS them and only switches on ones the car
already owns and left parked (an already-enabled part beats a parked sibling, since Auto
has no way to rank two effects that don't reach p/w and must not overturn the player's
pick). Over the p/w slots it is **exhaustive** (`_slot_combinations` — the cartesian
product, a handful of parts over two slots today) rather than greedy, because the
constrained objective isn't something a per-slot greedy pass can express. Each
combination is scored by `_combo_pw` (at full tune; detune trims afterwards) and ranked by
`_combo_better`:

- **Unconstrained** — the highest power-to-weight the budget affords, cheapest on a tie.
- **Under a cap** — it *inverts* to the **smallest p/w that still clears `pw_max`**, so the
  detune has the least work left to do and the car keeps as much of itself as possible.
  Comparison happens in the **rounded hp/tonne the eligibility gate itself uses**, so a
  build the search calls a fit really does pass `is_eligible`. If nothing clears the cap it
  falls back to plain maximisation — every build is legal then anyway.
- **Detune is the final trim, never the first lever** — the winning build is already the
  smallest one that clears the cap, so only the leftover is trimmed, via
  `RallyLibrary.qualifying_detune` on `_car_with_plan`'s projected car.

**Auto never fits ballast, but always strips it.** Ballast is a p/w lever that also
destroys grip: mass raises the load through each contact patch, which lowers μ through
`GameConfig.tire_load_factor` (see
[drivetrain-and-tires.md](drivetrain-and-tires.md)). Detune buys the *same* p/w reduction
for free, so any part whose `mass_mult` exceeds 1.0 is excluded from the candidate lists in
every mode — and, being in a p/w slot, an already-fitted one falls out of the winning
combination and lands in `strip`.

**`restriction` is a rally-restriction dict** (the `RallyLibrary` shape), not the bare
`pw_max` float it might have been. A host that only has a ceiling passes
`{"pw_max": limit}` in one line; a host that has the real rally passes the real thing —
and that is exactly what lets `blocked` distinguish **"wrong build"** (fixable: buy,
strip, detune) from **"wrong car"** (nothing to be done). The one non-power field Auto may
touch is the drive mode (`_drivetrain_fix`), and only when the swap kit is actually fitted;
everything else in a restriction is car identity.

**`free_only` is a flag, not a `stars = 0` call.** `star_cost_per_part` is an exported
range a designer could set to 0, which would silently turn a free-only restore into a
shopping spree. The flag also forbids the plan from moving power **down**: an over-limit
car is the "Too powerful" prompt's business, a deliberate decision point the restore must
not quietly bypass.

## The car's ceiling: `max_potential_meta` — two flavours

`UpgradeLibrary.max_potential_meta(owned_car, meta, profile := {}) -> Dictionary`
returns the car's `effective_meta` at its **maximum achievable** power-to-weight:
tuning forced to full (no detune), mass-adding ballast dropped (it's `free` and
always removable), and the best available part installed in every slot via
`_best_part_per_slot`. Per-slot maximisation is **exact**, not a heuristic —
`Save._enable_exclusive` allows only one enabled part per slot and the slots'
effects are independent (turbo → torque, weight → mass, aero → downforce,
drivetrain → a flag, nitrous → excluded from p/w entirely), so scoring each
candidate on its own is the whole answer. `_best_part_per_slot` skips
consumables and any part whose `mass_mult` is greater than 1.0 (mass-adding
ballast).

**The `profile` argument selects which ceiling, and the two mean different
things:**

- **`{}` (default) — the ASPIRATIONAL ceiling.** Every catalogue part is a
  candidate regardless of ownership *and* event gates are ignored: "could this
  car ever do it?" Used for entry eligibility and the displayed ceiling, so a
  player is never locked out of a rally for lacking a part they will obviously
  grow into.
- **a non-empty profile — the REACHABLE ceiling.** `_best_part_per_slot` also
  filters candidates through `rally_gate_met(item_id, profile)`: "can this
  player get there *now*?" Used by `RewardSystem._unlock_candidates`'s
  soft-lock rescue check — judging that check against the aspirational
  ceiling would conclude nobody is ever stuck (every car could in principle be
  turbo'd), silently disabling the rescue for a player whose turbo is locked
  behind an event they can't yet reach.

Only the `pw_min` floor is ever judged against either ceiling
(`RallyLibrary.ineligibility_reason`'s `floor_meta`); `pw_max` still uses the
car's **real current stats**, so the ceiling only ever makes a car *more*
eligible, never less — a player can't sandbag into a class they'd dominate.
**Accepted consequence:** with the best parts locked behind special events, the `pw_min` floor
is now very permissive (almost any car could eventually be turbo'd and
lightened), so its remaining job is soft-lock prevention, not class balance —
`pw_max` is where balance actually lives. See `reward-system.md` for the
soft-lock rescue that consumes the reachable flavour.

## Install (in `Save`)

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
- **There is no repair action.** HP climbs back only via the free between-event
  `Save.field_repair`, and a wrecked car is never revived — see [damage.md](damage.md).

## Acquisition — bought with stars, not dropped

**Parts are BOUGHT, not won at random.** `RewardSystem.draw_upgrade` is
**consumables-only** now — the engine swap token and the mystery box, plus
`NO_REWARD` — because a stage-by-stage part drop undercut both deliberate routes
to a part (why go and win a turbo, or pay for one, if it might fall out of the
next stage?). Most events therefore pay no item at all; the rally itself pays
STARS ([star-economy.md](star-economy.md) → "What the random draw still does").

The buy path is `Save.can_buy_part` / `part_price` / `buy_part`, priced at a flat
`GameConfig.star_cost_per_part` **per car per part** — upgrades are car-bound, so
every car meets the same question separately, which is what makes the sink
effectively bottomless. `can_buy_part` is the single predicate both the button and
the purchase read, and it requires the part to be **discovered**
(`rally_gate_met` — its part-unlock rally won, so the shop only ever sells what
the player has proven they can earn) and honours the **per-car**
`requires_upgrade_id` ladder, so a purchase cannot skip a rung. Bought parts fit
**disabled**, like every other award.

The UI is the slot rows themselves, not a separate shop screen
(`UpgradesMenu._make_option_selector` / `_make_weight_selector`): a discovered part
not on this car renders as `Name (N★)` and buys on press — the same question the
player is already asking on that row, answered with a price instead of a dead grey
option.

This library still supplies the gate helpers the shop and the mystery box read —
`requires_upgrade_id` / `prerequisite_met`, `unlocked_by_rally` /
`rally_gate_met`, `is_free` and `pool_weight`. `RewardSystem._eligible_parts` is
**not** retired: the **mystery box** still opens onto a part and uses it (with
`pool_weight` for rarity), and `_car_is_maxed` reads it to decide when a box is
granted instead of a normal draw — see [reward-system.md](reward-system.md). The
`free` ballast is excluded there for the same reason as ever (always available, so
never a reward). The **standings reveal** (`scripts/upgrade_reveal.gd`, not the
podium) is what confirms whatever the draw did hand out, with a single "Next" step.

## Tests

`tests/headless/test_auto_build.gd` — the `auto_build_plan` solver (max p/w
unconstrained; smallest-clearing build then detune under a cap; ballast stripped and
never fitted; `free_only` spends nothing and never trims power down; `blocked` named
when no build can enter) plus the save side (`Save.apply_build_plan`,
`Save.restore_free_build`), all on synthetic fixtures per CLAUDE.md.
`tests/headless/test_upgrades_simple.gd` covers the Simple page (stat block, the
Auto row's two presses — now press → `ConfirmPopup` → confirm, Simple↔Advanced, the
delegated `can_close` gate).

`tests/headless/test_upgrade_library.gd` — catalogue validity (unique ids, known
slots, consumables have no slot), lookups, effect application (multiplies/adds on a
baseline incl. `mass_mult`; empty list is a no-op), `effective_meta`
(lightens/empowers a meta copy without mutating the source), the aero
tuning gate, `rally_gate_met` (true when `unlocked_by_rally` is absent, false/true
tracking `profile.rallies[id].completed` otherwise, using synthetic fixtures per
CLAUDE.md), and `max_potential_meta`'s two flavours (aspirational includes
unowned/event-gated parts; a reachable profile excludes still-gated ones, and
a fitted-but-gate-closed part keeps applying). `test_rally_library.gd` covers an installed upgrade
qualifying / disqualifying a car for a rally's pw band; `test_car_library.gd`
covers `apply_owned` re-syncing the RigidBody mass after a weight-reduction kit.
Disabled parts being inert everywhere (config, effective stats, tuning gates) is
covered there too. Same-slot exclusivity (applying/enabling a part disables the
incumbent instead of scrapping it), the `enabled=false` disabled fit, per-car
duplicate-fit rejection, the same part fitting two different cars independently,
the `set_upgrade_enabled` toggle, consumable/unknown rejection, field-repair
heal+clamp, wreck (parts stay on the car), and the v1→v2 migration stripping the
old unbound pool are in `test_save_manager.gd` (they need the Save profile). The
garage upgrades menu having no apply-from-pool rows, the earn-gated option selectors
(turbo `Stock`/`Small`/`Big` and the single-part `Stock`/`<Kit>` slots — greyed until won,
picking enables, `Stock` parks), and the option-selector focus-retention regression are in
`test_menu_flow.gd`. The reward reveal's confirmation (a single "Next" step) and the
consumable / drivetrain-kit skip are in `test_upgrade_reveal.gd`; the standings
Collect-reward flow that hosts it is in `test_menu_flow.gd`.
`test_rally_session.gd` covers per-event won parts binding to the driven car with no
slottable part won twice per rally (the dedup'd draw). Mystery-box tests — the
draw trigger, `pick_mystery_box_grant`, `Save.open_mystery_box`'s atomic
install/fallback, and the garage button's nav/gating — are covered in
`test_reward_system.gd` / `test_save_manager.gd` / `test_menu_flow.gd`; see
`features/reward-system.md` → "Mystery box" for the full breakdown.
