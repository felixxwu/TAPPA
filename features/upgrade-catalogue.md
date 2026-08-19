# Upgrade Catalogue

`UpgradeLibrary` (`scripts/upgrade_library.gd`, `class_name UpgradeLibrary`) is
the catalogue of upgrade **items** — authored content (like `CarLibrary` /
`RallyLibrary`), not player state. The save profile holds the player side (each
`OwnedCar.installed_upgrades` / `disabled_upgrades`, keyed by the stable `id`
here, plus the generic consumable `inventory`); this library defines
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

**Tests:** `tests/headless/test_upgrade_library.gd`, `tests/headless/test_auto_build.gd`, `tests/headless/test_upgrades_grid.gd`, `tests/headless/test_car_stat_bounds.gd`

## Catalogue

`const UPGRADES: Array[Dictionary]`, each an UpgradeDef: `id`, `name`, `slot`
(`turbo` / `gearbox` / `aero` / `tires` / `weight` / `drivetrain` / `nitrous`, or `""` for
consumables — `SLOTS`' order is the garage row order, so a slot sits beside the one it is
read alongside: `gearbox` after `turbo`, `tires` after `aero`), `consumable`, an optional `free` flag (always-available,
never-drawn parts — the ballast; see below), an optional `requires_upgrade_id`
(per-car prerequisite gating — see below), an optional `unlocked_by_rally`
(garage-wide event gating — see below), an optional `weight` (pool
rarity, default 1.0 — see below), and `effect` (config-field →
delta/multiplier).

**`tier` is gone.** Upgrades used to carry a `tier` walked by
`RewardSystem._parts_at_or_below` (also gone); the event gate below replaced it
— see `reward-system.md`. (`CarLibrary`'s `reward_tier` is unrelated and still
tiers the **car** draw.)

**Pool weight (`weight`).** Optional, defaulting to 1.0.
`UpgradeLibrary.pool_weight(id)` reads it. It is the rarity knob that
replaced `tier`: tier gated on rally **difficulty** and had gone vestigial
(nearly every part sat at tier 1), whereas the event gate below handles
availability-over-time and `weight` handles rarity within whatever is
currently available — a more direct lever, expressed the way any weighted
draw already wants it (one number per item, no buckets to keep in step). With
the random per-event part draw gone there is nothing weighting items today; the
field stays as the shape a future weighted pool would read.

**Event gate (`unlocked_by_rally`).** Garage-wide availability over *time*: an
item can be withheld entirely — undiscovered, unbuyable — until a particular
special event has been **won**. `UpgradeLibrary.unlocked_by_rally(id)` reads the
field; `UpgradeLibrary.rally_gate_met(item_id, profile)` returns `true` when
the field is absent (default: ungated), else whether that rally is recorded
`completed` in `profile.rallies` — and `completed` already means a **top-3
finish**, so this genuinely reads "was the event won". Keyed on the **rally id** — never
on a star total, and stars are a spendable currency now
([star-economy.md](star-economy.md)), so a part can't be bought. The special
itself opens on the count of COMPLETED ORDINARY rallies
(`RallyLibrary.completions_required`), which is what makes the chain
"race enough events → win the special → the part becomes buyable".
This gate is about **earning** a part, never about **keeping** one:
`UpgradeLibrary.apply` walks `installed_upgrades` and never consults it, so a
part already fitted keeps working even if its gate would no longer be met.
Gated parts today: `turbo_large` → `sp_dust_trial`, `supercharger` →
`sp_archipelago_trial`, `drivetrain_swap` (now named "Drivetrain Conversion") →
`sp_lakeshore_trial`, `nitrous` → `the_showdown`, `sequential_gearbox` →
`sp_summit_trial`, `snow_tires` → `sp_woodland_trial`, and `race_tires` →
`sn_showdown`. The two tyre parts bracket the Alps: `sp_woodland_trial` is the gateway
pin into the frozen corner, `sn_showdown` sits at the far end of that chain — see
[rally-roster.md](rally-roster.md) and [snow-region.md](snow-region.md) for why.
`front_runners` gates no part: it gates the engine-swap *capability*
([engine-swap.md](engine-swap.md)), and that rally win is the WHOLE gate —
once it's won, swapping is free and unlimited, with nothing to spend.

**Prerequisite gate (`requires_upgrade_id`).** The **per-car** counterpart to
the event gate: an item that should unlock through owning ANOTHER item on
*that car*, rather than (or in addition to) the garage-wide event gate. `""`/absent
(the default) means no prerequisite. `UpgradeLibrary.requires_upgrade_id(id)`
reads the field; `UpgradeLibrary.prerequisite_met(item_id, owned_car)` checks
it against **that car's** `installed_upgrades` and is one of the checks
`Save.can_buy_part` runs, so a car cannot skip a rung until it has its
prerequisite fitted. Deliberately **per-car, not
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
enabled** with no Apply/Keep choice (`podium.gd._offer_upgrade_choice`), and its upgrades
tile offers only the three drive modes — no separate on/off. The `drivetrain` tile is
**always present**, even before the kit is won: until it's owned the car's stock drive mode
is the current pick and the other two modes are listed greyed with their reason (earn-gated
as a whole, like a part option greys until its kit is fitted) — so the tile reads like every
other slot rather than vanishing from the grid.
The **`weight` slot** holds, besides `Stock`, the **Weight Reduction** kit
(`weight_reduction`, `mass_mult` 0.80), the slot's one **earned** option — greyed until won.

**Ballast is retired.** The slot used to also carry two `free: true` options that ADDED
mass (`ballast_large` 1.5x, `ballast_small` 1.2x), so a player could deliberately get
heavier to shed power-to-weight and drop into a lower rally class. Entry is **categorical**
now, so there is nothing to duck under by getting slower, and an option whose whole effect
is "make your car worse" is a row every player scrolls past.

A profile still carrying one needs no migration: `Save._prune_unknown_upgrades` drops any
installed id the catalogue no longer has, on load. The `free` and `mass_mult > 1.0`
**branches survive** — `UpgradeLibrary.is_free` still installs without a purchase, and Auto
still refuses to fit anything that adds mass — so `fx_ballast` remains in
`tests/headless/upgrade_fixtures.gd` as the synthetic input for them, the same pattern
`fx_consumable` follows for the retired consumables.
The weight slot's option list is **ordered and labelled bespokely** by `UpgradeOptions`
rather than following the generic part-option shape — see below.
The **`gearbox` slot** holds the **Sequential Gearbox** (`sequential_gearbox`),
whose `shift_time_set` effect **replaces** `shift_time` with its own absolute figure (the
`"set"` op) rather than scaling the car's. The kit IS a specific piece of hardware, so it
shifts at its own rate whatever it replaces, and one authored number is what a designer tunes.

**It is therefore not a guaranteed improvement, deliberately.** `shift_time` is a
**per-engine** field (`EngineLibrary`, so an engine swap carries its gearbox — see
[engine-and-transmission.md](engine-and-transmission.md)), and an engine whose own gearbox is
already quicker than the kit gets **slower** by fitting it. On the shipped roster that is the
7-speed S tronic alone (0.08 s); every other transmission sits at 0.22–0.35 s and gains.
Fitting is the player's choice and nothing auto-fits it, so a car that would lose out just
stays on Stock. If that ever needs to be impossible, the fix is a "take the better of the
two" op — never a per-engine exception table.
It has its own `gearbox` tile on the upgrades grid, and fitting it moves the page's
`PERFORMANCE` line not at all — the rating reads power-to-weight, which a shift time cannot
touch — the same position nitrous is in.
The **`tires` slot** holds the tyre compounds, **Snow Tires** (`snow_tires`) and **Race Tires**
(`race_tires`), whose `tire_grip_mult` effect multiplies the car's tyre μ. Race Tires is a
flat gain everywhere, won at `sn_showdown` deep in the Alps chain; Snow Tires is won at
`sp_woodland_trial`, the gateway pin into the Alps, so the player arrives in the frozen
region with winter rubber rather than earning it afterwards. **The slot is a per-rally
trade-off, not a ladder.** Snow Tires is not simply the smaller multiplier: alongside its
flat (gravel-neutral) term it carries `tire_snow_grip_mult` and `tire_tarmac_grip_mult`, a
large bonus on snow ground bought with a tarmac penalty steep enough that on asphalt the
part is **net worse than the car's own stock rubber** — see
[drivetrain-and-tires.md](drivetrain-and-tires.md) → *Surface-specialised compounds* for
the rule and where it is applied. So one enabled part per slot makes them genuine
alternatives the player re-picks by stage, instead of a choice that goes dead the moment
both are owned. (It was a strictly-weaker rung once, and that is exactly the problem this
fixed.) Those two effects are ordinary `EFFECTS` rows (`mult`, `feeds_pw: false`,
`feeds_grip: true`, meta and cfg sharing the field name); they deliberately do **not** move
the upgrades page's GRIP row, which reads `tire_compound` alone — a single headline number
cannot honestly state a figure that changes with the surface. Its **own slot rather than sharing `aero`**: grip from
rubber and grip from downforce are not alternatives — a car wants both — and one enabled
part per slot would have made them mutually exclusive. Like the aero kit they are
deliberately **not** power-to-weight inputs, so they can never move a car's rally
eligibility; their grip contribution is folded in by `grip_meta` below.
Current set: three **forced-induction kits** (turbo slot — `turbo_small` ungated,
`turbo_large` prerequisite-gated on the same car having `turbo_small` plus its own
event gate, and `supercharger` prerequisite-gated on `turbo_large` plus its own
event gate, see above; the blower's belt physics are in [forced-induction.md](forced-induction.md)),
an aero kit, the tyre compounds (snow and race), the sequential gearbox, the three **weight** parts above, the
drivetrain conversion kit, and the `nitrous` slot's part (see below).

**Nothing in the catalogue is a consumable any more.** Every entry sits in a real slot and
is fitted to a car. The consumables that used to live here have all been retired in turn —
the repair kit (repair is automatic between events now — `Save.field_repair`; see
[damage.md](damage.md)), the engine swap token
(swapping is free and unlimited once `front_runners` is won — see
[engine-swap.md](engine-swap.md)) and the mystery box (parts are bought with stars whenever
the player wants one, so a random box onto a part had nothing left to offer).

**The `consumable` capability survives with no current occupants.** The flag is still
authored on every entry (`false` throughout) and the code paths that respect it are still
live and still tested: `Save.install_upgrade` refuses to slot a consumable, and
`UpgradeReveal` routes one to the inventory instead of onto the car. The generic
`inventory` save key survives with it, along with `Save.add_item` / `consume_item` — it was
never token-specific, so a future consumable needs no save migration to land in it. Keeping
the branches costs nothing and is what makes re-introducing one a catalogue edit rather
than a code change.

### The `nitrous` slot

The last `SLOTS` entry, and an ordinary tile on the upgrades grid like any other — the
mechanic, gauge, input and audio are documented in full in
[nitrous.md](nitrous.md); this file only covers its place in the catalogue.
It is a SINGLE part with an ordinary garage row — it was a four-rung ladder
(`nitrous` → `nitrous_tank` → `nitrous_shot` → `nitrous_race`) in a hidden slot,
collapsed to one entry carrying the top rung's numbers.
`UpgradeLibrary.HIDDEN_SLOTS` is empty as a result. The `install_nitrous` effect uses the `"write_fields"` op with
`feeds_pw: false` in the `EFFECTS` table below, so nitrous can never move
`effective_meta`'s power-to-weight or a car's rally eligibility.
The concrete part
list and exact numbers are a balance pass (deferred); these are single-purpose
defaults. The aero kit also **reveals the car's spoiler/splitter mesh** while enabled — see [aero-parts.md](aero-parts.md).

The upgrades menu is a **reusable `UpgradesGrid` component** (`scripts/upgrades_grid.gd`,
mirroring `TuningPanel`) — **one view, no pages**: a heading row, a `PERFORMANCE` line, and a
3-column grid of slot tiles, each tile opening a popup listing that slot's options (see
[menus.md](menus.md) → "The upgrades page: a grid of slots"):
the HQ lift mounts it as its Upgrades page, the car-park
**detune-to-enter prompt** mounts a second instance in its Change-Upgrades popup so a
too-powerful car can shed power by stripping parts instead of detuning (see
[menus.md](menus.md) → CARPARK), and the podium **reward reveal**
(`scripts/upgrade_reveal.gd`, `_on_upgrades_pressed`/`_build_upgrades_overlay`) mounts a
third instance behind an **Upgrades** button on its post-spin action row, so a player can
slot a just-won part immediately instead of waiting for the next HQ visit.
It owns its `Save` persistence
and reports edits via an
`on_change` callback so the host re-fields the car. (A fourth instance is the start line's
pre-stage **Upgrades** overlay, `start_line.gd._build_upgrades_overlay`.)

Its **heading row carries the player's star balance** (`UpgradesGrid.build_title_row`: the
page title, then the digits of `Save.stars_available()` beside a drawn `StarRow` price
star). It belongs to the COMPONENT, so all four hosts show it and every `rebuild()` — which
buying a part triggers — re-reads it. The balance is on the page because the **popups quote
prices**: a star figure the player has to remember from another screen turns every purchase
into arithmetic. See [star-economy.md](star-economy.md).

Under the heading sits the page's **single PERFORMANCE line**: the current build's
`CarPerformance.rating`, and under a host ceiling the target beside it (`512 / 480`, red
when over). It is a plain `Label` — nothing focusable, so it adds no keyboard/gamepad nav.
It is built from `CarPerformance.merged_meta(owned, entry)`, **not** `effective_meta`, or
fitting tyres or an aero kit would move no number on the page. It is the ONLY aggregate
readout: everything else on the page is a part and its current setting.

**Engine swap and engine detune are tiles, not special rows.** They are pseudo-slots
(`UpgradeOptions.SLOT_ENGINE` / `SLOT_TUNE`) sitting in the grid alongside the seven real
`UpgradeLibrary.SLOTS`, so the player finds them by looking at the grid rather than by
scrolling past the parts. The `engine` tile is **lift-only** in effect (only the HQ lift
passes `on_swap`; other hosts leave it unset, since the swap flow would change the HQ view,
and its options come back unselectable there). The `tune` tile shows the live detune
percentage and is the ONE tile that opens a slider rather than a list — detune is
continuous, and quantising it into list rows would throw away the fine control the player
uses it for.
The `engine` tile is the whole of the swap UI: a swap costs nothing and can be
repeated as often as the player likes once `front_runners` is won, so there is no balance
or stock to show — `UpgradeOptions.engine_swap_blocked_reason` returns only `"Locked"` or
`""`, and `Save.swap_engines` consumes nothing. See [engine-swap.md](engine-swap.md).

When a host passes a **performance ceiling** (`rating_limit >= 0`, in `CarPerformance`
rating units — every host reads it from `DrivingContext.rating_limit()` /
`rating_limit_for_car()`, which answers for whichever session is fielding the car), the
overlay's **close button is gated** (`UpgradesGrid.bind_close_button` + `request_close()` /
`can_close()` / `over_rating_limit()`): it reads **Done**, and while the current build
exceeds the ceiling it turns **red**, its text becomes **"Over limit — reduce to N
performance"**, and it **blocks closing** — both the button press and Esc /
controller-back are refused (hosts hand `request_close` to `MenuNav` as `on_back`) until
the build is back under. Over the ceiling the car is simply **ineligible** (there is no
detune escape any more), so letting the player walk out would only defer the refusal to
the start line.

**Only Rally Challenge sets a ceiling.** Career rally entry is purely categorical, so the
start line, the car-park popup and the reward reveal all pass `NO_LIMIT` for a career run
and the button stays a plain **Back** — as it always has on the HQ garage lift.

**The option model is pure data: `UpgradeOptions`** (`scripts/upgrade_options.gd`). It is
the single place the buy rules, rally gates and prerequisite ladders are turned into
something a menu can draw, and the UI never re-derives any of them:

- `grid_slots()` — the tile order: the seven `UpgradeLibrary.SLOTS` plus the two
  pseudo-slots `SLOT_ENGINE` (engine swap) and `SLOT_TUNE` (detune).
- `options_for(owned_car, slot)` — the ladder for one slot as
  `{id, label, current, selectable, price, locked_reason}` entries, `Stock` first. `Stock`
  is always selectable (the "off" state — the car's un-upgraded factory config, hence the
  label rather than `None`). Each `label` comes from `_option_label`, which is the part's
  `menu_label` / `name` for every slot except `weight` — that one reads as a signed mass
  delta rounded to the nearest 100, see "The `weight` slot" below.
- `current_label(owned_car, slot)` — what the tile itself reads under its icon
  (`turbo: Small`, `tune: 80%`, `weight: +200`). It just reports the current option's
  label, so the weight slot's delta labelling reaches the tile for free.
- `build_with(owned_car, slot, option_id)` — a pure COPY of the owned-car dict with that
  slot switched to that option, and nothing written to the save. It parks the WHOLE slot
  first and only then switches the pick on, which is what makes one-part-per-slot and the
  `""` = `Stock` case fall out of the same few lines instead of needing a branch each. The
  end state is the same one the matching `UpgradesGrid._apply_option` branch would leave
  behind, minus the persisting — so a hypothetical build and a real one cannot disagree.
- `rating_with(owned_car, slot, option_id)` — the `CarPerformance.rating` of
  `CarPerformance.merged_meta` over that hypothetical build: "what would this car rate if I
  took this option". This is what lets the slot popup quote a figure per row (see
  [menus.md](menus.md) → "The slot popup"). It is deliberately NOT stamped inside
  `options_for`: a rating is a simulated benchmark lap, and `options_for` sits on the grid's
  hot path (every tile asks it for a caption on every rebuild via `current_label` /
  `has_choice`). `UpgradesGrid._rated_options` stamps it on the way INTO the popup instead,
  so only a picker the player actually opened pays for it — a handful of sims, memoised by
  `CarPerformance` from then on.

### Drivetrain conversion: global unlock, per-car bill

The drivetrain slot is the one that lists **drive modes** (RWD / AWD / FWD) rather than
parts, and it splits its gating in two:

- **The capability is GLOBAL.** `UpgradeLibrary.drivetrain_swap_unlocked(profile)` reads the
  profile's rally record — won once, available to every car in the garage from then on,
  like the engine-swap capability.
- **Each conversion is BOUGHT per car**, at `GameConfig.star_cost_per_drive_mode`. The mode
  is recorded on the car (`drivetrain_modes_bought`), so it is paid for **once**: switching
  back to a layout the car has already bought is free thereafter, exactly as toggling a
  bought part between Stock and fitted is free. **Returning to the car's own authored
  layout is always free and never recorded** — otherwise a player out of stars could be
  stranded in a layout they could not leave.

This replaced a **per-car** unlock that was unreachable in practice. The kit was a part in
the `drivetrain` slot, granted by `_grant_rally_prizes` to the single car *selected* when
its special was won — but because `options_for` routes `"drivetrain"` to
`_drivetrain_options` (modes, not parts), the kit never appeared as a purchase row
anywhere. No other car in the garage could acquire it by stars or by any other means, and
the slot simply read "Locked" forever with no way to learn why.

The car park does **not** compensate for the price. It used to auto-switch a
wrong-drivetrain car at the Start button — free, silent, and reverted after the rally —
which under per-car pricing would have handed the player exactly what the garage charges
for, and (once `resolve_drive_override` began ignoring unpaid overrides) would have sent
the car out still ineligible while the game believed it qualified. That switch is removed:
an ineligible car is parked, marked with its reason, and left for the player to convert
([menus.md](menus.md) → the car park).

Two details worth keeping:

- The gate is found by its **effect flag** (`drivetrain_swap_part_id` scans for
  `unlocks_drivetrain_swap`), never by a hard-coded id. `rally_gate_met` treats an *unknown*
  item as ungated, so an id literal fails **open** — renaming the part, or running against
  the synthetic test catalogue, would have handed every car free conversion. A catalogue
  with no conversion part reads as locked, not as ungated.
- `resolve_drive_override` gates on the mode being **paid for**, not merely stored, so
  anything writing `drivetrain_override` directly cannot bypass the price. Profiles from
  before the change are **grandfathered** in `Save._grandfather_drive_mode`: a car already
  carrying an override has that mode added to its bought list on load, so an earned
  conversion is never silently revoked. Done in the tolerant sanitise pass rather than as a
  schema migration, for the same reason the retired-consumable cleanup is — a
  `SCHEMA_VERSION` bump makes older builds refuse the profile outright.

**Unavailable rows say `Locked`, never a price.** `_lock_reason` returns `"Locked"` for
anything the player cannot take right now — not yet unlocked, prerequisite missing, or
simply unaffordable — and `_drivetrain_options` matches it. A greyed row quoting
`2 STARS` reads as a price tag on something buyable, because that is the same figure the
*affordable* rows carry beside the star icon; one word for every unavailable option keeps
"the cursor skips this" and "here is what it costs" visually distinct.

- `slot_description(slot)` — one line saying what the slot **does**, in plain language for
  a player who knows nothing about cars ("which wheels get the power", "the rubber you
  drive on"). Drawn at the top of that slot's picker by `UpgradeSlotPopup`, above the
  options; `""` for a slot with no entry, and the popup then draws no row at all rather
  than an empty gap.

  This is **not** a title, and the picker still has none: a heading repeating "TURBO" over
  a list of turbos is a line of nothing, whereas this is the only thing telling a novice
  why they would open the slot at all. Two constraints shaped the copy — every label in the
  game renders UPPERCASE (`UITheme.enforce`), which is tiring over long sentences, and the
  panel is ~300 px wide — so each entry is at most two short sentences (what it is, then
  what it does for you) and avoids jargon rather than explaining it. The tests assert that
  every openable slot HAS one and that it reaches the popup, never the wording, which is
  authored copy.

Keeping this as data rather than as widget-construction code is what lets the tile, the
popup and the tests all agree about what a slot currently offers; a rule re-implemented in
a button builder is a rule that drifts the first time the layout changes.

### One definition of what a pick MEANS

`UpgradeOptions.option_edit(owned_car, slot, option_id)` is the single description of the
edit a pick stands for, returning a `kind`: `"none"` (the engine slot's host-owned flow and
the tune slider — not slot edits at all), `"clear_slot"`, `"enable_part"`, `"fit_part"` or
`"drive_mode"`.

**Both** the hypothetical build (`build_with`, which the picker rates) and the real apply
(`UpgradesGrid._apply_option`) branch on it. They still *perform* the edit differently —
the hypothetical mutates a copy, the real one goes through `Save`'s mutators so
exclusivity, the purchase re-checks and the reward flow are untouched — but the DECISION is
made once.

They used to be two independent `match slot` ladders held together by a comment asserting
they agreed, and they did not. The drivetrain arm of one marked the layout paid for while
the other did not, so the picker quoted every drive-mode row at the *unconverted* car's
rating. Two further traps came from the same fork: `""` (the universal Stock sentinel) meant
`int("") == 0 == RWD` on the drivetrain branch, silently converting any non-RWD car; and
the engine/tune slots had no arm at all, so an engine id or a percentage would have been
appended to `installed_upgrades` as if it were a part. All three are structural now.

`test_upgrades_grid.gd::test_build_with_agrees_with_a_real_apply_for_every_slot_and_option`
holds the two paths to it — for every slot and every selectable option, the rated
hypothetical and the committed car must have the same merged meta.

### Gates fail CLOSED on an unknown id

`rally_gate_met` and `prerequisite_met` both used to answer **yes** for an id absent from
the catalogue: the lookup returned `{}`, the missing field defaulted to `""`, and `""` means
"no gate authored". That is how a capability keyed on a hard-coded id was handed to
everyone the moment the id was absent — which is exactly what happened when the drivetrain
gate was keyed on the literal `"drivetrain_swap"` and that id was missing from the
synthetic test catalogue. Both now deny an unknown id up front. The genuine "no gate
authored" case is unaffected.

### The conversion kit is a marker, not a part

`drivetrain_swap` carries **no slot** (`"slot": ""`). It is a capability marker: what it
grants is the garage-wide right to convert, read off its rally gate. It sat in slot
`"drivetrain"` for a long time, which was a lie with teeth — a part claiming a slot whose
picker lists drive *modes* and could therefore never offer it, so no second car could
acquire it by stars or by anything else. `""` is the established "not in any slot" value
(the solver and the pickers both skip it).

`test_upgrades_grid.gd::test_every_catalogue_part_is_reachable_from_its_slots_picker`
enforces the general rule: every non-consumable part in a garage slot must appear in that
slot's picker. It is the test that would have caught the original bug directly.

**Locked options are LISTED, GREYED — this reverses the old rule.** The menu used to omit
every gated part outright, on the reasoning that a row the player cannot act on only raises
"when do I get this?", which the garage cannot answer. The grid takes the opposite view,
because a tile hides its ladder behind a press: a turbo tile whose popup shows only
`Stock | Small` looks like the whole of the turbo slot, and the player has no way to learn
that a bigger one exists. So every rung is listed with its `locked_reason` as its caption —
`"Locked"`, `"Needs Big"`, `"3 stars"` — and the slot shows its full ladder from the first
visit. What keeps it from being a wall of dead controls is the FOCUS rule: unselectable rows
are `FOCUS_NONE`, so keyboard and gamepad nav **skips straight over them** and the cursor
only ever lands on something that does something. The old exceptions still hold and are now
just ordinary cases of the same rule: a part already FITTED is selectable regardless of its
gate (the gate governs earning, never keeping), and an unlocked-but-unfitted part is
selectable as a purchase, priced.

The turbo slot's menu labels run `Stock` / `Small` / `Big` / `Supercharger` (`turbo_small` /
`turbo_large` / `supercharger`, shown by their `menu_label`), and the tyre slot reads
`Stock` alongside a label per compound — `Snow` / `Race` (`snow_tires` / `race_tires`,
likewise by `menu_label`); the
single-part slots read `Stock` /
`<Kit>` (e.g. the aero tile's `Stock` / `Aero Kit`, using the part's full `name`). Under the
hood it's the ordinary per-slot enable/disable machinery (`Save.set_upgrade_enabled`):
picking a part enables it (same-slot exclusivity switches any sibling off), picking `Stock`
disables every part in the slot (the underlying id is still `""`). Kits are won and fitted
disabled, then enabled from the slot's popup (either at the HQ lift or after an event's
standings reveal confirms the won part).
Drivetrain remains one odd one out (its options are a `drive_mode` override, not a part
enable, and it uses a single unlock rather than per-option earn-gating — see above).

**The `weight` slot is the other exception: its rows are labelled by a signed mass
delta, not by part name.** `UpgradeOptions._option_label` returns the part's
`menu_label` / `name` for every slot — except `weight`, where it returns a bare signed
integer rounded to the nearest hundred (`+200`, `-200`) and nothing else. The parts are authored as "Heavy Ballast" /
"Light Ballast" / "Weight Reduction", which is three words for a slot that is really one
number, on a grid tile that has to fit three across a phone. What the player is choosing
between here is **how much mass to add or shed**, so the row states exactly that; the
catalogue order (heaviest first, down through the lightweight kit) then reads as a
physical ordering, so "heavier" and "lighter" are directions on the list rather than
facts to be decoded from names. `Stock` still reads `Stock` — it is the slot's off state,
same as everywhere else — and it is the first row, same as everywhere else.

The kilos are **derived, not authored**. These parts carry a mass MULTIPLIER
(`mass_mult`), so the same ballast is a different number of kilos on a light car than on a
heavy one, and quoting the multiplier would just make the player do the arithmetic.
The baseline is `UpgradeOptions._stock_mass` — the car's mass with the weight slot
**empty** (`build_with(owned_car, SLOT_WEIGHT, "")` then `UpgradeLibrary.effective_meta`,
so an engine swap's mass is already folded in). Measuring against the empty slot rather
than the car's *current* mass is what makes the numbers stable: swapping one ballast for
another reports what the NEW part weighs, instead of the difference between the two, so a
given part never quotes different kilos depending on what it happened to replace.

That derived figure is then **rounded to the nearest 100**, and floored at a magnitude of
100. Deriving from a multiplier lands on values like 243 or 187 — precision the player has
no use for and cannot act on, where a round number reads as a decision; the floor stops a
real part on a light enough car rounding down to `+0`, which would state that the option
does nothing. Rounding is presentation only: the mass the physics uses is always the exact
multiplier, never the displayed figure. A weight
part with no `mass_mult`, or a car with no mass to measure against, falls back to the
authored name rather than printing `+0`. Because the tile caption comes from
`UpgradeOptions.current_label` (which just reads the current option's label), the grid tile
now reads `weight: +240` too.

The two ballast options are
**always selectable** (they're `free`); the lightweight (earned) one is greyed until won;
the active pick carries `UITheme.mark_selected` like every other slot. Selecting a `free`
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
`.tres`. `*_mult` keys multiply the baseline (`mass` / tyre μ); additive
keys add (`downforce_front` / `downforce_rear`); `*_set` keys **replace** it outright with an
absolute figure (`shift_time`); `install_turbo` writes the turbo
fields (see above); `install_nitrous` (`"write_fields"` op) straight-splats its
fields onto `cfg` with no enable flag and no slot rival to clear — `has_nitrous()`
in the live sim reads the values themselves, so a zero gain/tank already reads
as "not fitted" (see [nitrous.md](nitrous.md)).
`unlocks_*` keys are **flags**, skipped by `apply` — they gate tuning sliders, not
config. `aero_tuning_unlocked(car)` reads that flag so the tuning lift only exposes
the aero slider when the kit is fitted. Brake bias is **not** gated — it's a free
tuning axis on every car (see [tuning.md](tuning.md)).

**A `mult`/`add` row may target more than one config field, under a different name.** A
descriptor's `field` is the **meta** spelling; the optional `cfg_fields` list is the
**live-config** spelling, and `_cfg_fields(desc)` falls back to `[field]` when the two
coincide (as they do for `mass` and the downforce pair). `tire_grip_mult` is the row that
needs it: a car's rubber is one `tire_compound` on its meta but a per-axle
`wheel_friction_slip_front` / `_rear` pair on the config. Keeping that mapping as table
DATA is what stops `apply` growing a branch per part. Multiplying both axles in step 2 —
before tuning runs — scales the player's `grip_balance` split rather than overwriting it.

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
`hq_carpark.gd._build_eligible_lineup`) pass `effective_meta` into `RallyLibrary.is_eligible`.
Entry itself is categorical now, so an upgrade no longer moves a car in or out of a career
rally; what `effective_meta` still feeds is every displayed power figure, and — through
`CarPerformance.merged_meta` — the performance rating a Rally Challenge ceiling judges.
The rival pool and reward-grant queries keep using the raw `CARS` entries (those
are unmodified roster cars, not the player's upgraded ones).

### `grip_meta` — the same copy, plus the grip-feeding fields

`grip_meta(owned_car, meta)` is `effective_meta` with every enabled part's
**`feeds_grip`** effect folded in on top: the aero kit's `downforce_front` /
`downforce_rear` (the `add` arm) and the race tyres' `tire_compound` multiplier (the `mult`
arm). It exists as a separate call rather than as a widening of `effective_meta` because
the two answer different questions: `effective_meta` mirrors only the
**power-to-weight-feeding** effects, since p/w is what eligibility is judged on and
**grip doesn't move a car's class**. But a grip readout has to show what the wing and the
rubber bought, and `CarLibrary.max_lateral_g` reads both downforce and `tire_compound` off
the meta it's handed — so any grip READOUT passes `grip_meta`, while
every eligibility path keeps passing `effective_meta`. Keeping them apart is what stops a
wing or a set of tyres quietly changing which rallies a car can enter.

`feeds_grip` is a second flag on the `EFFECTS` rows rather than a re-use of `feeds_pw`, for
exactly that reason — the two sets must not merge. (This was `aero_meta` while downforce
was the only thing it folded in.)

### `CarStatBounds` — the roster-wide scale for comparing cars

`scripts/car_stat_bounds.gd` (`CarStatBounds`) caches the **min/max each comparable stat
reaches across the whole car roster** — `rating` (CarPerformance), `pw` (hp/tonne),
`grip` (max lateral G) and `mass` — as `{key: [lo, hi]}` from `all()`, with
`fraction(key, value)` mapping a car's figure onto 0..1 for any surface that wants to show
one car against the whole roster (`StatBar`, `scripts/stat_bar.gd`, is the segmented-bar
widget built for that). Grip is speed-dependent, so bounds are rated at
`GameConfig.grip_reference_kmh` — a single config field, so a bound can't be computed at
one speed and a figure displayed at another.

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

## The auto-build solver: `auto_build_plan`

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

**The solver currently has no menu surface.** The upgrades grid asks the player to choose a
part per slot, so there is no one-press "build me the best car" control on it; the solver
is exercised by the tests and stays available for any future host that wants to offer it.
Nothing applies a build automatically either — see "No auto-apply" below.

**The objective.** Only slots that feed power-to-weight take part in the search
(`_slot_feeds_pw` reads the same `EFFECTS` table `apply()`/`effective_meta` use, so a new
effect can't leave a slot unsearched); the rest — aero, drivetrain kit, nitrous — can't be
scored against the objective, so Auto never BUYS them and only switches on ones the car
already owns and left parked (an already-enabled part beats a parked sibling, since Auto
has no way to rank two effects that don't reach p/w and must not overturn the player's
pick). Over the p/w slots it is **exhaustive** (`_slot_combinations` — the cartesian
product, a handful of parts over two slots today) rather than greedy, because the
constrained objective isn't something a per-slot greedy pass can express. Each
combination is scored by `_combo_rating` — **`CarPerformance.rating` of the whole projected
build** (at full tune), via `merged_meta`, so tyres and downforce the car already owns count
— and ranked by the ONE shared scorer `_combo_better`: **the highest rating the budget
affords, cheapest on a tie**. Every caller goes through it, so nothing can disagree about
what "best" means.

**No auto-apply.** A build plan is only ever committed by a press the player made. There
is no start-gate restore and nothing switches parts on behind the loading screen: a car
races exactly the build it was left on. (`Save.restore_free_build` did this and was
removed — an automatic, permanent edit the player could neither see happen nor decline is
worse than the forgotten-detune problem it solved, especially now that entry is
categorical and a detune can only ever be a deliberate choice.)

**There is no ceiling term in the solver.** A Rally Challenge ceiling is an *eligibility
line*, not an objective — over it the car cannot enter at all — so the ceiling stays with
the host, which is expected to compute a finished plan's rating and **withhold** a plan
that would breach it rather than offering a star spend that makes the car ineligible.
Detune is not a lever the solver reaches for any more; it is carried through untouched as
a handling knob the player sets deliberately.

**Auto never fits ballast, but always strips it.** Ballast is a p/w lever that also
destroys grip: mass raises the load through each contact patch, which lowers μ through
`GameConfig.tire_load_factor` (see
[drivetrain-and-tires.md](drivetrain-and-tires.md)) — so it is a straight rating loss. Any
part whose `mass_mult` exceeds 1.0 is excluded from the candidate lists in
every mode — and, being in a p/w slot, an already-fitted one falls out of the winning
combination and lands in `strip`.

**`restriction` is a rally-restriction dict** (the `RallyLibrary` shape) and is entirely
**categorical** — car type, country, drive mode. It carries no performance ceiling, and a
numeric key must never be smuggled into it. Passing the real restriction is what lets
`blocked` distinguish **"wrong build"** (fixable) from **"wrong car"** (nothing to be
done). The one field Auto may touch is the drive mode (`_drivetrain_fix`), and only when
the swap kit is actually fitted; everything else in a restriction is car identity.

**`free_only` is a flag, not a `stars = 0` call.** `star_cost_per_part` is an exported
range a designer could set to 0, which would silently turn a free-only restore into a
shopping spree. The flag also forbids the plan from moving the rating **down**: a free
restore only ever moves the car forward, or sideways.

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
  player get there *now*?" **This flavour has no caller left**: its only consumer
  was `RewardSystem`'s soft-lock rescue, deleted with the move to purely
  categorical entry requirements. Kept for now pending a decision on whether the
  parameter goes too.

**Neither flavour feeds eligibility any more.** Rally entry became purely categorical with
the car-performance rating rework, so nothing about a car's power can admit or exclude it
and `ineligibility_reason` lost its `floor_meta` argument. What remains is the
calibration/reporting question "what could this car become?" —
`tools/calibrate_benchmark.gd` is the one caller left in the repo.

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

**Parts are BOUGHT or WON OUTRIGHT, never dropped at random.** There is no per-event
upgrade draw at all — a stage-by-stage part drop undercut both deliberate routes to a part
(why go and win a turbo, or pay for one, if it might fall out of the next stage?), and once
the consumables were retired the draw could only ever pay nothing anyway. So a part arrives
by exactly two routes the player chose: **winning the special that advertises it**
(`unlocked_by_rally` → `RewardSystem.grant_special_unlock`, see
[prize-rallies.md](prize-rallies.md)) or **buying it with stars**. An ordinary event pays
stars, not equipment ([star-economy.md](star-economy.md)). The CAR draw is untouched —
a top-3 finish still grants a car (`RewardSystem.draw_car`), revealed by the present box.

The buy path is `Save.can_buy_part` / `part_price` / `buy_part`, priced at a flat
`GameConfig.star_cost_per_part` **per car per part** — upgrades are car-bound, so
every car meets the same question separately, which is what makes the sink
effectively bottomless. `can_buy_part` is the single predicate both the button and
the purchase read, and it requires the part to be **discovered**
(`rally_gate_met` — its part-unlock rally won, so the shop only ever sells what
the player has proven they can earn) and honours the **per-car**
`requires_upgrade_id` ladder, so a purchase cannot skip a rung. `buy_part` itself fits the
part **parked**, like every other award — but see below: the slot picker enables it
immediately afterwards, so parked is what the *grant* paths leave behind, not what the
player sees when they buy one themselves.

The UI is the slot popups themselves, not a separate shop screen
(`UpgradeOptions.options_for` fills in a `price`, and `UpgradeSlotPopup` hangs a drawn
`StarRow.price_icon()` on the row): a discovered part not on this car is an ordinary
selectable option carrying its price, and pressing it buys, fits AND enables it — the same
question the player is already asking in that slot, answered with a price instead of a dead
grey option.

**Buying from the picker also FITS the part** (`UpgradesGrid._apply_option` follows a
successful `Save.buy_part` with `Save.set_upgrade_enabled(instance_id, id, true)`).
`buy_part` leaving it parked is right for the paths that hand the player something they did
not ask for — a special event's unlock and its cascaded ladder rungs — because those must
never silently change how the car drives. Picking an option in the slot popup is the exact opposite: the player opened
that slot, chose that rung and spent stars on it, so leaving it parked meant the menu took
the payment and visibly did nothing. The enable is exclusive, so it parks the slot's
outgoing part for free. `Save.apply_build_plan` already used the same buy-then-enable pair.

This library supplies the gate helpers the shop and the special-event grant read —
`requires_upgrade_id` / `prerequisite_met`, `unlocked_by_rally` / `rally_gate_met` and
`is_free`. `RewardSystem._eligible_parts` is gone with the draw it filtered; nothing
enumerates a pool of parts any more, because both remaining routes name the part directly.
`UpgradeReveal` (`scripts/upgrade_reveal.gd`) still confirms a granted part with a single
"Next" step — it just no longer has a random draw to announce.

## Tests

`tests/headless/test_auto_build.gd` — the `auto_build_plan` solver (max p/w
unconstrained; smallest-clearing build then detune under a cap; ballast stripped and
never fitted; `free_only` spends nothing and never trims power down; `blocked` named
when no build can enter) plus the save side (`Save.apply_build_plan`), all on synthetic
fixtures per CLAUDE.md.
`tests/headless/test_upgrades_grid.gd` covers the grid page (a tile per
`UpgradeOptions.grid_slots()` entry, tile labels tracking the current pick, tile → popup →
apply, the `tune` tile's slider popup, the `can_close` gate, and focus surviving a
rebuild), and the option model itself (locked options present-but-unselectable with a
reason, prices on buyable ones). Its weight-label tests
(`test_weight_options_read_as_a_signed_mass_delta`,
`test_a_weight_delta_is_measured_against_the_empty_slot`,
`test_other_slots_keep_their_part_names`) assert the SIGN and the FORMAT plus the
empty-slot baseline — never a particular number of kilos, which is authored tuning.

`tests/headless/test_upgrade_library.gd` — catalogue validity (unique ids, known
slots, consumables have no slot), lookups, effect application (multiplies/adds on a
baseline incl. `mass_mult`; `tire_grip_mult` reaching BOTH axle μ fields via `cfg_fields`;
`shift_time_set` replacing two different baselines with the same absolute figure, which is
what separates a `set` from a `mult`; empty list is a no-op), `effective_meta`
(lightens/empowers a meta copy without mutating the source), `grip_meta` folding tyres and
downforce in **while `effective_meta` leaves power-to-weight untouched** — the safeguard
that keeps a grip part out of eligibility — the aero
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
the `set_upgrade_enabled` toggle, consumable/unknown rejection (against the synthetic
`fx_consumable` entry — see below), field-repair
heal+clamp, wreck (parts stay on the car), and the v1→v2 migration stripping the
old unbound pool are in `test_save_manager.gd` (they need the Save profile). The
garage upgrades menu having no apply-from-pool rows, the earn-gated option selectors
(turbo `Stock`/`Small`/`Big` and the single-part `Stock`/`<Kit>` slots — greyed until won,
picking enables, `Stock` parks), and the option-selector focus-retention regression are in
`test_menu_flow.gd`. The reward reveal's confirmation (a single "Next" step) and the
consumable / drivetrain-kit skip are in `test_upgrade_reveal.gd`.

**Consumable handling is tested against a synthetic entry, not a shipped one.** No
catalogue item is a consumable any more, so `tests/headless/upgrade_fixtures.gd` authors
**`fx_consumable`** — a `slot: ""`, `consumable: true` stand-in — and the tests that
exercise the surviving branches (`Save.install_upgrade` refusing to slot one,
`UpgradeReveal` routing one to the inventory) install the fixture roster and use it. That
replaced re-exporting the real token's id, which was the fixture file's way of pointing at
a shipped consumable; a synthetic entry is the right shape anyway, since a capability with
no occupants can only be tested by supplying one.


## Re-sited unlocks and the legacy grant

`unlocked_by_rally` can be re-pointed when the roster changes — two parts moved into the
Alps (Race Tires → `sn_showdown`, Sequential Gearbox → `sp_summit_trial`) to give that
corner something worth working toward.

`rally_gate_met` therefore checks `Save.KEY_LEGACY_PART_UNLOCKS` **before** the rally: a
player who won the part where it used to live keeps it. That set is written only by the
save migration (v4 → v5, from `Save.MOVED_PART_UNLOCKS`) and is empty for every career
started after the move. See [snow-region.md](snow-region.md) and
[save-persistence.md](save-persistence.md).

The engine-swap **capability** was re-sited the same way (`sp_woodland_trial` →
`front_runners`, freeing the old rally to carry Snow Tires), and follows the same shape
one level up: `RallyLibrary.engine_swaps_unlocked` checks `Save.KEY_LEGACY_ENGINE_SWAP`
before the rally, written by the v5 → v6 migration. See
[engine-swap.md](engine-swap.md).
