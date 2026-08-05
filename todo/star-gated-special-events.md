# Star-Gated Special Events

Replace the four per-region **showdowns** with a ladder of **special events**
gated on the player's total star count, and move the game's best upgrades behind
them so each event is a door into the tech tree rather than another loot drop.

Status: **SHIPPED, with three loose ends.** The ladder, the eight specials and their
map placement, the gating seam, tier removal, the retired always-pays-out rule, the
two `max_potential_meta` flavours, nitrous (slot, sim, input, gauge, audio, mobile)
and the endgame are all implemented. Docs are in sync — see
[`features/nitrous.md`](../features/nitrous.md) plus the updated `rally-roster.md`,
`regions.md`, `reward-system.md`, `upgrade-catalogue.md`, `rally-session.md`,
`menus.md`, `save-persistence.md`, `forced-induction.md`, `engine-swap.md`,
`configuration.md` and `hud.md` / `controls.md` / `mobile-controls.md` /
`car-physics.md` / `engine-audio.md`.

**What is still outstanding — see *Still outstanding* at the bottom of this file:**

1. The nitrous **first-use hint** (needs a save flag + keyboard-vs-controller
   device detection). Not started.
2. **`GameConfig.engine_nitrous_hiss_gain`** is not wired — the synth uses a local
   `NITROUS_HISS_GAIN` constant as a placeholder.
3. The **engine-swap capability gate** is only half-wired: `engine_swaps_unlocked`
   exists and `RewardSystem` honours it, but the HQ swap station and the upgrades
   menu do not, so tokens are still spendable before the 20-star special is won.

Everything below this line is the ORIGINAL DESIGN, kept as the rationale record.
Where the implementation deliberately diverged, the divergence is called out inline
with a **SHIPPED:** note.

---

## Why

Today a showdown is the finale of its *region*: `RegionLibrary.showdown_unlocked`
opens it once every non-showdown rally in that corner is complete, and clearing
all four fires the credits (`RegionLibrary.all_showdowns_completed` →
`RallySession.showdown_won` → `podium.gd`'s "THE SHOWDOWN IS WON" line).

Two problems:

1. **The reward is the same as every other rally's** — a car draw on a top-3
   finish. Nothing about the prize says "this was the hard one".
2. **The gate is a completion sweep**, so it can't be paced. A corner either has
   everything done or it doesn't.

Star-gating fixes both. Stars already exist and are already *derived*, not
stored: `hq._stars_for(rally_id)` maps `Save.best_placement(rally_id)` (1st → 3,
2nd → 2, 3rd → 1, else 0). A star total is a running metric that rewards both
breadth (podium lots of rallies) and mastery (go back and convert a 2nd into a
1st), and it paces cleanly at a fixed interval.

## The ladder

Every **5 stars**. Each event unlocks a part into the **normal reward pool**.

**SUPERSEDED IN PART (implemented):** it originally did *not* hand the part over — the
player still had to win it at an ordinary rally. It now also **awards the part to the car
that won the special**, cascading any missing prerequisite rungs, and a special no longer
draws a car. The pool unlock still happens as described below; the award is on top. See
`features/reward-system.md` → Special-event unlock. The rest of this section describes the
pool mechanics, which are unchanged.

| Stars | Unlocks | New content? |
|---|---|---|
| 5 | Big Turbo (`turbo_large`) | no — exists |
| 10 | Drivetrain Conversion (`drivetrain_swap`, renamed) | no — exists |
| 15 | Supercharger (`supercharger`) | no — exists |
| 20 | Engine swapping (the *capability* — see below) | no — exists |
| 25 | Nitrous | **yes** — new mechanic |
| 30, 35, 40 | Nitrous upgrades — a mix of tank size (longer) and boost amount (harder) | yes — but they reuse the nitrous mechanic |

Eight rungs, ending at 40. See *The star maths* for why it stops there.

> **RESCALED: the cadence was 8 stars, now 5.** The requirements were scaled
> down in place — every rung kept its position and its unlock, only the numbers
> moved (8/16/24/32/40/48/56/64 → 5/10/15/20/25/30/35/40). **No new special
> events were added.** The accepted consequence, stated by the user: the last
> unlock now lands at 40 stars instead of 64, well short of the roster's
> star ceiling, so *"the late game will be more about completionism rather than
> late game upgrade unlocks"* — a large tail of the roster is played for
> completion rather than for new parts.

Uniform rule, one mechanism: **no new grant or inventory path at all.** Four of
the five unlocks are parts that already ship; the only genuinely new mechanic in
the whole change is nitrous itself.

**Drivetrain Conversion is a rename, not new content.** `drivetrain_swap` already
exists (`upgrade_library.gd`, slot `drivetrain`, effect `unlocks_drivetrain_swap`,
read by `UpgradeLibrary.drivetrain_swap_unlocked` / `resolve_drive_override`). It
is currently an ordinary tier-2 reward. The work is: rename to "Drivetrain
Conversion", add the star gate. It is the strongest early unlock because it
rewrites the car's `drive_mode`, which changes which rallies the car is
*eligible* for (`RallyLibrary.is_eligible` / `hq._entry_plan`) — so it visibly
opens pins on the map rather than just adding speed.

**The nitrous upgrades chain off the base part for free.** `requires_upgrade_id:
"nitrous"`, per-car, exactly as `turbo_small` → `turbo_large` → `supercharger`
does today via `UpgradeLibrary.prerequisite_met`. No new mechanism.

## The seam: `unlocked_by_rally`

Gate on **winning the event**, not on the raw star count. If 15 stars alone
unlocked the Supercharger there would be no reason to drive the event.

One new authored field on the `UpgradeDef`:

```gdscript
{
    "id": "supercharger", ..., "requires_upgrade_id": "turbo_large",
    "unlocked_by_rally": "special_15",
}
```

plus one predicate beside the existing `UpgradeLibrary.prerequisite_met`:

```gdscript
static func rally_gate_met(item_id: String, profile: Dictionary) -> bool
```

returning `true` when the field is absent, else whether that rally is recorded
complete in `profile.rallies`. Two readers:

- **`RewardSystem._parts_at_or_below`** — AND it in at the *same* call site that
  already ANDs `prerequisite_met`. This is the only place the draw pool is built,
  so the gate lands once.
- **The garage upgrades menu** (`upgrades_menu.gd`) — grey the row (see
  *Presentation* below).

No new save state: it rides entirely on existing rally-completion plumbing. And
`completed` already means **top-3**, not merely finished — `Save.complete_rally`
is documented "Record a top-3 rally finish" — so keying the gate on it genuinely
means the event was *won*.

**No save migration.** The game has no players yet, so do whatever is simplest:
existing profiles may lose access to gated parts until they win the events, and
that is fine. Do not build a grandfathering path.

**Already-fitted parts keep working**, because `UpgradeLibrary.apply` walks
`installed_upgrades` and never consults gates. That's the correct behaviour but
it is currently *accidental* — pin it with a test so nobody later "fixes" it into
a retroactive uninstall.

## Retiring the showdown gate

`showdown: true` on a `RallyLibrary` entry becomes `special: true` +
`requires_stars: N`. The reveal predicate `RallyLibrary.rally_revealed` currently
delegates showdowns to `RegionLibrary.rally_showdown_gate_open`; that branch
becomes a star-total comparison, which **removes** the region coupling rather
than adding to it.

Retire, once nothing reads them:

- `RegionLibrary.showdown_of` / `showdown_unlocked` / `rally_showdown_gate_open`
- `RegionLibrary.all_showdowns_completed` (see the endgame question below)
- `RallyLibrary.showdown_unlocked` — **note:** this is a *second, stricter*
  definition than `RegionLibrary`'s (all non-showdown rallies roster-wide, not
  per-region). Check whether anything still calls it; it looks vestigial. Worth
  confirming before the rest of the change leans on either.

New helper, one definition, mirroring `RallyLibrary._completed_count`'s "skip
showdowns" shape:

```gdscript
static func total_stars(profile: Dictionary) -> int
```

Specials themselves **do not award stars** — same exclusion `_refresh_meter` and
`_completed_count` already apply to showdowns.

### Two hard invariants

1. **Specials stay open-class.** Every showdown today authors `"restriction": {}`,
   commented "open so the low-power starter can always finish the game". Preserve
   it. Now that specials gate the parts, a restriction could otherwise deadlock the
   ladder — so state it as a rule: *no special's restriction may depend on a part
   unlocked at its own rung or higher.* Cover it with a roster test.
2. **The Drivetrain Conversion gate must not manufacture a soft-lock.** Gating the
   conversion narrows the drivetrains a player can reach, so no rally's restriction
   may be satisfiable *only* via the conversion. Note the shipped
   `test_every_shipped_rally_has_at_least_one_car_that_can_enter_it` may not catch
   this, as it tests owned cars rather than reachable modifications — this needs its
   own check.

### Naming sweep

"Showdown" is user-visible in several places and all of it moves: the
`"SHOWDOWN UNLOCKED"` reveal banner and the gold `SHOWDOWN` chip
(`hq_overlays.gd`), `hq.gd`'s `_detail_showdown` plus the reveal path's
doubled hold time for showdowns, `podium.gd`'s "THE SHOWDOWN IS WON" line, and
`RallySession.showdown_won` / `_result["showdown_won"]`.

Re-driving an already-won special must be harmless — the gate is idempotent — but
the reveal beat must not replay. `hq.gd` already reads-and-clears its reveal state
so a scene regeneration doesn't replay a popup; follow that pattern.

## Nitrous

The only new mechanic. Design agreed:

- **One bar, always full at the start of every stage.** The tank refills on stage
  start *and* on the in-stage reset-to-start — the car simply never begins a stage
  with anything less than a full tank. There is deliberately **no persistent spent
  state**, so there is no reset exploit to guard against and nothing to carry
  across events.
- **Weak to start.** Because it always refills, the base tank can be small and the
  base boost modest without feeling stingy.
- **Exactly two upgrade levers: tank size (longer) and boost amount (harder).**
  The 30/35/40 rungs mix the two, so the escalation ladder has two axes and never
  reads as "bigger number" three times.
- **Boost is a TORQUE MULTIPLIER** applied while the button is held and the tank has
  charge. It lives only in the live sim — a multiplier on the crank torque in
  `engine.gd`, alongside (not inside) the turbo/supercharger `boost_torque_factor`
  chain, and **never** written back into `effective_meta`. Tank size is a duration in
  seconds; the bar drains while held.
- **Nitrous is NOT part of the performance/eligibility calculation.** It must not
  feed `UpgradeLibrary.effective_meta`, so it never affects
  `RallyLibrary.is_eligible` p/w banding, `qualifying_detune`, or rival pace
  floors. It is a late-game mechanic that makes events *easier* — not a stat.
  This also avoids the trap where fitting your 25-star reward shoves a car over a
  `pw_max` and locks it out of rallies it could previously enter.

Needs: a `GameConfig` block (base tank size / boost amount + per-upgrade deltas),
an input action, an `EFFECTS` descriptor entry, a HUD gauge, and audio.

### A new slot, invisible in the UI

`UpgradeLibrary.SLOTS` is a fixed four — `turbo`, `aero`, `weight`, `drivetrain` —
and `Save.install_upgrade` rejects anything whose `slot_of()` is empty, while
`_enable_exclusive` enforces one enabled part per slot. So nitrous **needs a fifth
`SLOTS` entry**: joining `turbo` would make it mutually exclusive with the turbo and
supercharger, which is exactly wrong.

The 30/35/40 upgrades form a **chained ladder inside that one slot** — each rung a
strictly-better tank+boost combination replacing the last, the `turbo_small` →
`turbo_large` precedent. Not two slots for tank and boost separately: that doubles
the parts for a mixing freedom the player has no reason to want, and keeps the ladder
legible as three escalating rungs.

**The slot is deliberately absent from the upgrades menu.** There is nothing to
decide — an unwanted nitrous is simply a button you don't press, and uninstalling it
would change nothing about the car (it is excluded from `effective_meta`, so it
cannot affect eligibility). So:

- Skip the nitrous slot when `upgrades_menu.gd` builds its slot rows.
- **Install it ENABLED on award.** This is the one real trap: `rally_session.gd`
  currently installs awarded parts with `enabled := false`, because the reveal
  overlay is what enables the pick. With no UI row, a disabled nitrous would be
  permanently dead. Pass `true` for this slot (or treat the slot as always-enabled).
- No uninstall path, and nothing to show in the tuning lift.

### Activation

- **Desktop / keyboard: Shift.** A new `nitrous` input action in `project.godot`.
  **The action name must not read as gear-shifting** — call it `nitrous`, never
  `shift`, since `shift_up` / `shift_down` are E / Q.

  Why Shift, given everything else taken (W/A/S/D + arrows, Space handbrake, E/Q
  gears, T gearbox, C/R camera, F skip, H/P debug, Enter/Esc menus):

  - **Both driving postures are bound.** `accelerate` is W *and* Up, `steer_left` is
    A *and* Left — so some players drive on WASD (right hand free) and others on the
    arrows (left hand free). Shift is the one key comfortable in both: pinky-adjacent
    to A for WASD, free-hand for arrow drivers (whose right Shift also sits beside
    their arrow cluster). Left-hand keys like Z/X or right-hand keys like B/N/M each
    only suit one posture.
  - **Web-safe.** This ships to browser, where Tab steals focus and Ctrl/Alt/Cmd
    collide with browser shortcuts. Shift alone triggers nothing.
  - **Comfortable to hold**, which matters because nitrous drains while held.

  **Decided: LEFT Shift only.** Bind `physical_keycode` 4194325 (`KEY_SHIFT`) with
  `"location": 1` (`KEY_LOCATION_LEFT`). This is the one binding in the project that
  deliberately sets `location` — every existing action leaves it 0 ("any") — so it
  needs a comment saying why, or someone will "normalise" it back.

  Why left-only: on Windows, holding *right* Shift ~8s opens the Filter Keys prompt
  (and 5 Shift presses can trigger Sticky Keys). Nitrous is a held key, so that's a
  real hazard. Arrow-key drivers lose the nearer right Shift, but their left hand is
  free anyway, so the cost is small.
- **Controller: X (joypad button 2).** The thumb-position boost button, comfortable
  to hold. Everything else is taken — 0/1 A+B (handbrake, cancel), 3 Y (camera),
  6 START (pause), 9/10 shoulders (gears), 11–14 d-pad (menus), and the triggers are
  axes 4/5 — leaving only BACK, the system-reserved GUIDE, and the two stick-clicks,
  all poor for a held input.

  Button 2 is currently `toggle_gearbox`, so **freeing it is a prerequisite** — see
  *Cleanup: the gearbox toggle's controller binding* below.
- **Mobile: a small button immediately left of the GAS pedal.** In
  `mobile_controls.gd` this is a new `"nitrous"` region: `_REGION_LABEL` entry,
  a `_rects["nitrous"]` in `_compute_rects` sited at the gas pedal's `y` and
  `bx - hgap - nos_w`, and an entry in the hit-test region list.

**The mobile placement needs a per-scheme rule, not one rect.** There are six
control schemes and "left of the gas pedal" isn't always meaningful:

- Schemes 2/3/4 are **auto-gas** — `_has_gas_button()` is false, so there is no gas
  pedal to sit left of. Anchor to the BRAKE pedal instead.
- Scheme 4 (`SIMPLE_LR_AUTO`) splits the whole lower screen into steering halves, so
  a nitrous button there **steals steering input**. The hit-test loop already tests
  pedals before the simple halves, so ordering saves it *provided* `"nitrous"` is
  added to that list ahead of `simple_left`/`simple_right` — get this wrong and the
  button silently does nothing, or worse, steers.

The button must only exist when nitrous is **fitted** to the driven car, so
`_build` / `_compute_rects` need that check, and the overlay must rebuild when the
car changes — not just when the scheme changes.

### Audio — a sixth synth layer, no new assets

There is no `Audio` autoload yet (`todo/audio.md`), and the engine's forced-induction
sounds are all **procedurally synthesised** in `engine_audio_synth.gd`. Nitrous should
follow suit rather than introduce sample assets — the machinery it needs already
exists there:

- a **baked white-noise table** with an independent rolling read index per layer
  (`_ni_noise`, `_ni_whistle`, `_ni_bov` — nitrous adds `_ni_nitrous`),
- **resonant band-pass filtered noise** (the turbo whistle),
- a **decaying burst with a flutter LFO** (the blow-off valve, `_bov_decay`),
- a **broadband air-rush layer** blended under the supercharger whine.

So the design is a recombination of parts already written:

1. **Trigger transient** — a short solenoid *crack* on activation: a BOV-style noise
   burst reusing the `_bov_decay` envelope shape, but with a softer attack and no
   flutter. This is what sells the button press.
2. **Sustain** — broadband **hiss** while held: low-pass (or gently band-passed) noise
   at a fixed level, sitting *under* the engine note. Nitrous is mostly hiss; it
   doesn't need a tonal component, which also keeps it clearly distinct from the
   turbo whistle and the supercharger whine on a car carrying all three.
3. **Let the engine do the power** — because nitrous is a torque multiplier, the
   existing synth's rpm tracking already makes the car *sound* faster. Do not
   synthesise a fake "power" layer on top; it would double-count.
4. **Cutoff cue** — a short descending hiss tail on release **and** on tank-empty, so
   the player hears that it stopped without looking at the gauge. The empty case
   matters most: that's the one the player didn't choose.
5. **Level** — a `GameConfig` gain field alongside `engine_supercharger_whine_gain`,
   and pick a level in the same spirit as the existing constants
   (`TURBO_WHISTLE_LEVEL` 0.5 for filtered noise vs `TURBO_TONE_LEVEL` 0.12 for the
   tonal whine — filtered noise has lower RMS, so it carries a higher number). It must
   layer under the engine, not mask it, and must respect the existing audio volume
   sliders.

> **SHIPPED, except the gain field.** All four beats exist in
> `engine_audio_synth.gd` (`NITROUS_CRACK_*` solenoid crack, `NITROUS_HISS_*`
> sustain on its own `_ni_nitrous` noise-table index, and a descending cutoff cue
> that sweeps the low-pass from `NITROUS_HISS_LP_HZ` down to
> `NITROUS_TAIL_LP_HZ` on both release and dry-tank, the dry case armed at full
> strength). The preview trap below is handled: `engine_audio.gd` passes the
> DELIVERY state (`nitrous_on`), never "fitted", and `car_preview_audio.gd` passes
> the nitrous args hard-false.
> **`GameConfig.engine_nitrous_hiss_gain` was NOT added** — the level is the local
> constant `NITROUS_HISS_GAIN`, flagged as a placeholder in the code comment. See
> *Still outstanding* below.

**One trap:** `car_preview_audio.gd` applies the car's fitted upgrades before revving
in the garage, so a nitrous-equipped car will build the nitrous layer there too. It
must stay silent in the preview — there is no throttle-and-button input, so gate it
on the activation state rather than on the part being fitted.

### Cleanup: the gearbox toggle's controller binding

Nitrous needs joypad button 2, which `toggle_gearbox` holds. **Remove that action's
joypad binding** (`project.godot`) and update the controller column in
`features/controls.md`.

**Do NOT delete the action wholesale without adding a replacement first.** It looks
like a leftover debug tool but isn't:

- The debug actions are `toggle_debug_arrows` (H), `toggle_perf_overlay` (P) and
  `skip_to_finish` (F). `toggle_gearbox` is documented in `features/controls.md` as a
  *player* control and appears in `input_remap.gd`'s user-rebindable list.
- It is the **only runtime path to automatic transmission**. `auto_gearbox` is a
  `GameConfig` field (`game_config.gd`, default `false` = manual) whose comment even
  says "toggle in-game with T", and there is no settings-menu option for it.
- **Mobile has no shift buttons in any control scheme**, so touch players have no way
  to change gear and no way to reach automatic if the toggle disappears.

> **SHIPPED — the fuller option was taken.** The `toggle_gearbox` action was
> removed from `project.godot` **entirely**, not just its joypad binding, and the
> replacement demanded above was built in the same pass: a gearbox auto/manual
> option in the settings menu (`settings_menu.gd`, `gearbox_auto()`, defaulting to
> `GameConfig.auto_gearbox`), which `car.gd` mirrors. So automatic is still
> reachable at runtime and touch players are not stranded.

So: dropping the *joypad* binding is safe and sufficient for nitrous. If the action
is to be removed entirely (`car.gd`'s `_driver_input_live()` branch,
`input_remap.gd`, `features/car-physics.md`, `features/controls.md`), **add a
gearbox auto/manual option to the settings menu in the same change** — otherwise
automatic becomes unreachable at runtime and mobile is stranded in manual.

### The first-use hint

Show a hint at stage start naming the button, **until the player presses it once,
then never again**.

- **This does need new save state** — a single profile flag (the "no new save
  state" note earlier in this spec is about the *unlock gates*, which genuinely
  need none). Persist it so the hint doesn't return next session; it is a
  once-per-profile beat, not once-per-stage.
- **It needs the right glyph for the actual device**, and `Platform` currently has
  no keyboard-vs-controller distinction — only `is_touch()`, `is_web()`,
  `is_mobile_or_web()`, `is_headless()`. So this needs last-input-device tracking
  (a controller can be plugged into a desktop mid-session), or at minimum
  "controller if any joypad is connected, else keyboard".
- Suppress it entirely when nitrous isn't fitted, and don't let it fire on the
  stage where the part is first won mid-rally if the car doesn't yet have it.

> **NOT IMPLEMENTED.** Nothing in `scripts/` references a nitrous hint or a
> first-use flag. Still wanted, unchanged — see *Still outstanding* below.

### The gauge

A **blue bar in the same family as the health and boost bars** — the pattern to
copy is `hud.gd`'s boost bar (`_update_boost_gauge`, `_gauge_color`,
`_style_gauge_captions`): a change-gated `ProgressBar` with its caption *inside* the
bar, `self_modulate` tinted, no drop shadow on the caption, visible only when the
relevant part is fitted. Unlike boost, nitrous **drains** rather than tracking a
live reading.

**Hue: violet, ~0.70.** The boost bar is *already* blue — `hud.gd`'s
`_BOOST_HUE := 0.58` — and a turbocharged car with nitrous fitted shows **both bars
at once**, stacked; two identical blues would be unreadable at a glance mid-stage.
Violet sits far enough from 0.58 to separate cleanly while still reading as the same
family, and it reads as the "special" gauge. Keep the shared `_GAUGE_SAT` /
`_GAUGE_VAL` so it stays a sibling of the other two, and add `_NITROUS_HUE` beside
`_BOOST_HUE`.

Stacking order: nitrous above boost above health, so the newest/most situational
gauge is furthest from the bottom edge (matching how BoostBar was added above
HPBar).

## Engine swaps: capability, not currency

**The engine-swap token cannot leave the reward pool.**
`reward_system.gd` appends it to *every* pool unconditionally — that is what
guarantees a payout when a car already has every eligible part fitted. And
`MYSTERY_BOX_TOKEN_THRESHOLD = 3` means the mystery-box branch only fires when
the player is *holding* tokens, so choking supply would quietly stop boxes
firing too.

So separate the capability from the currency:

- Tokens keep dropping exactly as they do now.
- The 20-star event unlocks **swapping** — the swap station becomes usable and
  tokens become spendable. Until then tokens are banked but inert.
- Two readers need the locked state, both of which already read
  `Save.engine_swap_tokens_owned()`: `hq.gd` (the `CarparkMode.SWAP` station) and
  `upgrades_menu.gd`.

> **SHIPPED (partial).** `RallyLibrary.engine_swaps_unlocked(profile)` and
> `RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY := "sp_archipelago_trial"` exist, and the
> reward side honours them: `RewardSystem._box_gate_open` skips the
> `MYSTERY_BOX_TOKEN_THRESHOLD` requirement while swapping is locked, since tokens
> are meant to be inert then. **But neither UI reader was wired.** `hq.gd`'s swap
> station (`_on_swap_confirmed` / the swap-confirm popup) and
> `upgrades_menu.gd`'s engine-swap row still gate purely on
> `Save.engine_swap_tokens_owned() > 0`, so in the shipped build a swap is
> spendable as soon as a token is held, and the "banked but inert / locked teaser"
> framing does not exist anywhere in the UI. See *Still outstanding* below.

This is the strongest incentive on the whole ladder: a visible stack of tokens
you *can't spend yet* pulls harder toward the event than any prize description.

**Risk:** pre-unlock tokens read as a junk reward unless the UI frames them as a
teaser (`3 TOKENS — LOCKED · Win the 20-star event`) rather than an item. Get the
label wrong and early draws feel like a whiff. Mitigating factor: tokens aren't
fully dead pre-unlock, since the mystery-box branch still consumes them.

## Remove upgrade tier gating

The star gate makes `UpgradeDef.tier` redundant, and the data shows it was
already vestigial:

- **Read in exactly one place** — the tier loop in
  `RewardSystem._parts_at_or_below`. Every other tier reference in the codebase
  is `reward_tier` on **cars**, a separate field.
- **The authored table is already flat.** Every upgrade is tier 1 except
  `drivetrain_swap` at tier 2 — nothing at 3 or 4, with `MAX_TIER = 4`. So the
  tier walk *and* its step-down fallback ("stepping down to the nearest lower
  tier that has an eligible part") exist to serve a single tier-2 entry — which
  is precisely the entry this change star-gates instead.

Remove:

- `tier` from every `UPGRADES` entry.
- The tier loop in `_parts_at_or_below`, which becomes a flat filter: unlocked +
  `prerequisite_met` + `rally_gate_met` + not already fitted + not `free`.
- The `MAX_TIER`-not-`target_tier` subtlety in `_car_has_nothing_left` — the
  fiddliest reasoning in that file. **Note the question it answered comes back in
  a new form:** it existed so a car wouldn't read as "maxed" merely because
  progress hadn't raised the tier ceiling yet, and a star gate reintroduces exactly
  that. Decision: `_car_has_nothing_left` uses the **gated** pool, i.e. a car with
  every *currently unlocked* part fitted counts as maxed. Consequence: cars read as
  maxed much earlier, so the box branch is reached far more often — which is exactly
  why the always-pays-out rule is retired in the same change (see *Retire "every
  event always awards something"*). The two decisions must land together.
- `rally_difficulty` from `draw_upgrade`'s signature, plus its callers.

**Keep:** `MAX_TIER`, `tier_ceiling()`, `target_tier()`. The **car** draw still
uses them, and `challenge_session.gd` calls `tier_ceiling()` directly to derive
challenge difficulty.

**Accepted loss:** the difficulty → part-quality correlation. A harder rally
stops yielding a better part. Fine — it barely existed with everything at tier 1,
and the correlation still lives on the car draw, which is the more visible prize.

**Do in the same pass:** author an optional per-entry `weight` (default 1.0) on
`UPGRADES`. Removing tier leaves the pool flat with no rarity knob; pool entries
are already `{"id":..., "weight":...}` dicts (that's how the token gets its
`0.2`), so weight is a drop-in and a more direct knob than tier ever was. Cheap
now, awkward to retrofit.

## Retire "every event always awards something"

Star-gating makes cars read as maxed far earlier (see `_car_has_nothing_left`
above), and the current draw *always* pays out — so without this change the late
draw degenerates into a mystery-box firehose. This section is the mitigation, and
the two decisions have to land together.

**The new rule, in order:**

1. **While the car still has an unlocked part to win, award it.** Unchanged — the
   "every non-final event awards an upgrade" promise holds for as long as there is
   something real to give. This is the common case and must not regress.
2. **Once the car is maxed** (every *currently unlocked*, prerequisite-met part
   fitted) **and** — *only if engine swapping is unlocked* — the player holds at
   least 3 swap tokens, roll for a **mystery box** with probability
   `1 / (boxes_owned + 1)`.
3. **On a failed roll, award nothing at all.** No consolation token, no reveal — the
   flow goes straight to the next menu.

**The `+1` is load-bearing.** Literal `1 / boxes_owned` is undefined at zero boxes
and equals 1.0 at one box, so the first two would both be certain. `1 / (owned + 1)`
gives: 0 boxes → guaranteed, 1 → 1/2, 2 → 1/3, 3 → 1/4. First box certain, then a
self-throttling tail. Author the shape in `GameConfig` rather than hard-coding it.

**The token stops being the guaranteed fallback.** `reward_system.gd` currently
appends the swap token to *every* pool unconditionally, and `features/reward-system.md`
states this is "what keeps the draw always paying out". That invariant is now
**retired** — both the code comment and the doc say so explicitly today, so both must
change or the next reader will treat the new behaviour as a bug. Keep the token as a
low-weight *entry* in the normal pool (it's still a legitimate drop); just stop
relying on it as the always-there floor.

**Keep `_other_car_has_room`.** A box with nowhere to land is still useless, and now
that "nothing" is a legal outcome, that check failing simply means nothing is
awarded — cleaner than the contortions it needed before.

### The "nothing" return path

`draw_upgrade` returns `String`; **`""` becomes the "no reward" sentinel.** That's
already the meaning `RallySession._event_upgrade` carries for the final event, so no
new type is needed — but two call sites must stop assuming a non-empty id:

- **`rally_session.gd` `report_event_result`** — today `awarded` (an *event-boundary*
  test, `_event_index < EVENTS_PER_RALLY`) gates the draw, the install, the
  `_upgrades_won` append, the `Save.save()` *and* the `upgrade_revealed.emit`. Split
  it: the boundary decides whether to *draw*, the drawn id decides whether to
  *install / append / reveal*. On `""`, skip the install and **do not emit
  `upgrade_revealed`** — the standings interstitial is emitted separately right after,
  so suppressing the reveal already produces "straight to the next menu" with no
  extra flow work.
- **`challenge_session.gd:350`** — the same draw, same treatment. Easy to miss.

Guard `Save.install_upgrade` / `Save.add_item` against `""` regardless, so a missed
call site fails loudly rather than writing an empty item into a car.

**Savescum: no change needed.** `Save.save()` stays gated on `if damaged or awarded`.
A failed roll writes nothing, which is fine: `_event_index` and `_event_times_ms` are
**pure session state, never persisted**, so there is no mid-rally resume to reload
into. Re-rolling a failed box means replaying the rally from event 1 with the damage
already banked — the savescum protection comes from the absence of a mid-rally save,
not from the `Save.save()` call. (Worth a comment where the outcome is decided, since
`features/reward-system.md` credits the save call for that property.)

### Interaction with locked engine swaps

Before the 20-star rung, swapping is locked and tokens are inert. The 3-token
condition is therefore **skipped** while locked (per the rule above), so a maxed car
pre-20-stars yields either a box or nothing. Tokens keep accruing unspendably in the
meantime — which is the intended teaser (see *Engine swaps* above), but it does mean
the pre-20-star maxed-car case pays out less often than the post-unlock one. That's
acceptable; note it so it isn't mistaken for a bug.

## Eligibility judges the car's TRUE ceiling

With the best parts gated, a car's *currently fitted* hardware is a bad measure of
what it can become — most of the time the good parts are still locked. So the
`pw_min` floor must be judged against what the car **could be maxed to from the
whole catalogue**, not just its installed parts maxed out.

**The mechanism already exists and is already wired.**
`RallyLibrary.ineligibility_reason` takes `floor_meta` and applies it to the
`pw_min` floor *only* (`pw_max` keeps using the car's real current stats, so a
player can't sandbag into a class they'd dominate). All four call sites already
pass `UpgradeLibrary.max_potential_meta(car, entry)`: `hq.gd` (`_entry_plan`),
`reward_system.gd` (the soft-lock rescue check), `start_line.gd`, and
`RallyLibrary.incomplete_rallies_enterable_by`.

The change is to **`max_potential_meta` alone**: today it only maxes parts the car
*already has* (re-enables `disabled_upgrades`, sets `engine_detune` to 1.0, drops
mass-adding ballast). Extend it to include every part the car could ever fit —
ignoring both ownership and star gates.

**Consequence to accept knowingly:** the `pw_min` floor becomes very permissive.
Judged as though it could eventually be turbo'd, supercharged and lightened,
nearly every car clears nearly every floor — so a weak car can enter a high-tier
rally and be uncompetitive. That is the intended direction (nobody is locked out
for lacking a gated part, which also strengthens the anti-soft-lock guarantee),
but it does mean the floor's remaining job is soft-lock prevention rather than
balance. `pw_max` is where class balance actually lives.

This also settles the old "advertised car ceiling" question: the ceiling **does**
count locked parts, consistently with eligibility.

## What a special pays out

**Exactly what an ordinary rally pays**: the per-event upgrade draws at the
non-final event boundaries, plus the car draw on a top-3 finish. The unlock is
*additional*, not a replacement.

Keeping the car draw matters for soft-lock safety — an event that paid only a door
could leave a player with no car able to progress. (Today only the *final*
showdown swaps its car draw for the credits beat, `rally_session.gd`; see the
endgame question below.)

## Presentation

The two surfaces pull in OPPOSITE directions, deliberately.

- **The map ADVERTISES** what is coming: a locked special's pin names its rung and
  what it unlocks, because the map is where you go to ask "what should I aim at?".
- **The garage HIDES** what you can't have: a star-locked upgrade is absent
  entirely, because the garage is where you go to ask "what can I do right now?",
  and a permanently-disabled row is a dead end that only invites "when do I get
  this?".

### The upgrades menu — locked options are HIDDEN

**SHIPPED, and this REVERSES the original decision** (which was "greyed out but
fully legible, carrying the requirement as a tooltip"). Rationale for the change:
a row of greyed options the player cannot act on reads as a nag, and it raises
exactly the question the garage has no way to answer. Availability and information
are both withheld here; the *map* is the surface that answers "where do I earn X?".

The rule, in `upgrades_menu.gd._slot_parts` (the one seam every selector goes
through, so it covers the turbo/aero option rows, the bespoke weight selector and
the drivetrain picker at once):

- A part whose **star gate is shut** is omitted from its slot's options entirely.
  A new player's turbo row therefore reads `Stock | Small` and nothing more,
  growing as specials are won.
- A part that is **unlocked but not yet fitted to this car** stays
  visible-and-disabled — that one the player can act on, by winning it.
- A part **already fitted** stays visible whatever its gate says: the gate governs
  EARNING a part, never keeping one, so a car must never display less than it is
  actually running.
- A slot whose **every** real option is still locked gets **no row at all** — not
  even the label (`_make_slot_row` returns null). For a new player that means the
  drivetrain row is simply absent.
- The **engine-swap row** is likewise absent while the capability is star-locked,
  rather than showing a disabled `Swap Engine — locked`.

Trade-off accepted: the "banked tokens you can't spend yet" teaser no longer
appears in the garage, so a player holding swap tokens before the 20-star special
has no in-garage explanation of what they are for. The car-park confirm popup still
explains it if reached, and the map pin still advertises the unlock.

### The map

A special's pin names its unlock **in both states**, so the map answers "where do
I get X?" at a glance:

```
                        X/24 stars              ── locked
                    unlocks Supercharger

                       SPECIAL EVENT            ── unlocked
                    unlocks Supercharger
```

**The locked case changes an existing invariant.** `hq._make_pin` is explicit that
the readout box is all-or-nothing — a locked or no-eligible-car rally gets *no*
box, only a grey flag, because "a menu is either live and at full opacity, or
absent". A locked special needs a box, so `_make_pin` gains a third case:
locked-special → **box at full opacity, but non-pickable**. That keeps the stated
rule intact (the box is live-looking, it just isn't a target) — the grey *flag* below
it already carries the "not yet" signal, so the box doesn't need to repeat it. No
dimming, so no exception to document.

`_refresh_meter` should switch from `Progress: N / M rallies completed` to the
star total, so the table HUD and the pins agree on one metric.

**Menu navigation:** the map table is the diegetic `hq.gd._unhandled_input`
left/right cursor pattern, and locked pins are skipped by the cursor walk. Confirm
a locked special is skipped too (it is non-pickable) and that the cursor can't
strand on one. See `features/menus.md` → Menu navigation.

---

## The eight specials — authored

Specials keep the **3-event** structure; the events are simply **longer**, and the
length ramps with the rung.

**Rung ↔ corner assignment.** Each corner gets exactly two specials — one early, one
late — so the ladder **tours the map twice** rather than clustering. The four existing
showdowns are all `difficulty` 4 with long events, which is far too much for a player
three wins in, so they take the four *upper* rungs and the four new (gentler) specials
take the lower ones.

| Stars | Id | Name | Region | Diff | Turn counts | Status |
|---|---|---|---|---|---|---|
| 5 | `sp_woodland_trial` | The Woodland Trial | `home` | 2 | 28 / 30 / 28 | authored |
| 10 | `sp_dust_trial` | The Dust Trial | `greece` | 2 | 32 / 35 / 32 | authored |
| 15 | `sp_lakeshore_trial` | The Lakeshore Trial | `home_coast` | 3 | 37 / 39 / 37 | authored |
| 20 | `sp_archipelago_trial` | The Archipelago Trial | `greece_coast` | 3 | 41 / 44 / 41 | authored |
| 25 | `the_showdown` | The Showdown | `home` | 4 | 46 / 46 / 46 | authored |
| 30 | `hc_showdown` | The Lakeland Crown | `home_coast` | 4 | 48 / 51 / 48 | authored |
| 35 | `gr_showdown` | The Aegean Crown | `greece` | 4 | 51 / 53 / 51 | authored |
| 40 | `gc_showdown` | The Island Crown | `greece_coast` | 4 | 53 / 55 / 53 | authored |

**Turn counts above are as currently authored** (`scripts/rally_library.gd`) — they moved
twice since this table was first written: once to lengthen the three showdowns that used
to trail `gr_thermopylae` (below), and again when every rally-library event was scaled
~15% longer across the board. Re-read the source before trusting a number quoted here;
do not treat this table as a contract (CLAUDE.md — never pin tunable values). The ramp is
monotonic with the star rung, every rung clearly longer than an ordinary rally's turn
count. `gr_showdown` (51/53/51) is comfortably longer than `gr_thermopylae` (32/35/32),
the ordinary rally in the same corner — the original lengthening this table proposed is
long since done; the numbers here are historical only in *shape*, not in the exact
figures.

Naming reads as a two-tier family: the new lower rungs are **Trials**, the capstones
stay **Showdown / Crown**.

All eight keep `"restriction": {}` (the open-class invariant), and all eight are
`special: true` with `requires_stars` set to their rung.

### Placement — authored from the map, not derived

The four existing showdowns all sit at their corner's **outer extremity** (x = 0.130,
0.941, 0.140, 0.978). That's an existing authored convention worth extending: a
special sits on the outer edge of its corner, so the map reads "the big one is out
past everything else". New pins, each ≥ 0.08 from every neighbour:

| Id | `map_pos` | Sited as |
|---|---|---|
| `sp_woodland_trial` | `Vector2(0.318, 0.128)` | `home`'s north edge, right of Grand Tour (0.220, 0.160) |
| `sp_dust_trial` | `Vector2(0.062, 0.884)` | `greece`'s far SW, below the Aegean Crown (0.140, 0.790) |
| `sp_lakeshore_trial` | `Vector2(0.772, 0.528)` | `home_coast`'s north edge, between Lakeside (0.702, 0.571) and Headland (0.831, 0.593) |
| `sp_archipelago_trial` | `Vector2(0.812, 0.962)` | `greece_coast`'s south edge, east of the Island GP (0.677, 0.938) |

**`sp_lakeshore_trial` is the one to watch:** at y = 0.528 it is the northernmost
`home_coast` pin, and the **NE corner (x > 0.5, y < 0.5) is reserved for the snow
region** (`todo/one-map-four-corners.md`). It must not creep above ~0.52.

### Per-event authoring rules these must obey

Copied from the shipped data, not invented — get these wrong and stages flood or a
test fails:

- **`water_level` follows the region**, authored per event, never derived from
  `map_pos`: `home` −12, `greece` −10 to −11, `home_coast` −7 to −4,
  `greece_coast` −7 to −4.
- **Any event at a coastal waterline must pair `terrain_layer1_amplitude` ≥ 16.0**
  (a high sea over low relief floods the track). The coastal corners ship 16–21.
- **Weather is region-restricted.** `sandstorm` is authored **only** on `greece`
  events — `test_rally_library.gd::test_sandstorm_only_authored_on_greece_events`
  enforces it. `storm` sits on the two coastal corners; `fog` on the two temperate
  ones (`home` / `home_coast`); `rain` anywhere.
- **Terrain idiom per corner:** `home` forestiness 0.7–0.85 / surface_mix 0.3–0.5 /
  amplitude 34–36; `greece` forestiness 0.65–0.85 / surface_mix 0.1–0.25 / amplitude
  12–26; `home_coast` forestiness 0.55–0.8 / surface_mix 0.4–0.9 / amplitude 19–21;
  `greece_coast` forestiness 0.45–0.7 / surface_mix 0.3–0.7 / amplitude 16.
- **Cliffiness climbs across the three events** (…0.85 → 0.95 → 1.0) in every
  shipped showdown — keep that escalation.
- **Seeds:** the `8xxxx` block is entirely unused. Allot `81001-3`, `82001-3`,
  `83001-3`, `84001-3` to the four new specials.

## The star maths — the ladder stops at 40

The roster is **32 entries, 8 of them specials**. Specials award no stars
(`RallyLibrary.total_stars` skips them), so there are **24 star-earning rallies →
72 max stars**.

**The ladder stops at 40**, giving eight rungs: 5, 10, 15, 20, 25, 30, 35, 40.
Everything above 40 (41–72) is deliberately unallocated.

That cap does real work:

- **The win condition isn't a perfect run.** A 72-star rung would have demanded 3
  stars in all 24 rallies with no slips; 40 leaves a wide margin of slack, so the
  game can be finished without flawlessness.
- **Four new specials to author, not five.** Four exist already. This is still the
  bulk of the work — stages, `map_pos` pins, weather — but it's a fifth less of it.
- **Three nitrous-upgrade rungs (30, 35, 40)**, which the two levers (tank size /
  boost amount) fill comfortably without padding.

**After the rescale from 8s to 5s, the slack above the top rung is large by
design** — roughly the last 32 of 72 stars sit past the final unlock. The user
accepted this explicitly: the tail of the roster is completionism, not new parts.

## The endgame

Credits fire on **winning the 40-star special** — the top rung — replacing
`RegionLibrary.all_showdowns_completed()`. `RallySession.showdown_won` and the
`podium.gd` beat stay intact; only the predicate changes.

Because the ladder caps at 40 rather than 72, this is a reachable finish rather
than a star-perfect one. Note that today the *final* showdown swaps its car draw
for the credits beat (`rally_session.gd`); keep that behaviour on the 40-star
event, and only that one — every other special pays out normally (see *What a
special pays out*).

> **SHIPPED, with a deliberate change of predicate.** The credits do **not** key
> on the 40-star rung specifically. `rally_session.gd` fires the renamed
> `game_won` signal when `RallyLibrary.is_special(_rally)` **and**
> `RallyLibrary.all_specials_completed(Save.profile)` — i.e. when the just-won
> special was the last one outstanding. Normally that IS the top rung (the rungs
> open in star order), but the rule is set-completion, so a player who somehow
> leaves an earlier rung unwon finishes the game on that one instead. This is
> strictly more robust than naming a rung, and it survives a designer re-authoring
> the ladder. `top_rung_stars()` exists for display but does not gate the endgame.
> `RegionLibrary.all_showdowns_completed` is deleted; the result-dict key is
> `game_won`, and `podium.gd` prints "EVERY SPECIAL EVENT IS WON — you've
> completed the game!".

## Map placement — the per-region invariant is retired

**Decided: "at most one showdown per region, and exactly one wherever there are
rallies to gate" is retired.** Specials are gated by the global star total, so
they have no relationship to a region's contents — a corner may hold any number of
them, including none.

That freedom is the point: with nine specials across four corners, placement
becomes pure map-composition (spacing, `map_pos` spread, which corner's look suits
a given stage) rather than something the gating rules constrain. Specials still sit
at a normalised `map_pos` inside a corner and still inherit that corner's look and
`water_level` like any other rally — the region tag keeps doing its rendering job,
it just stops doing a gating job.

To update:

- The `RegionLibrary.REGIONS` header comment stating the invariant, and the
  `RallyLibrary.RALLIES` header comment that repeats it ("exactly one entry with
  `showdown = true`").
- `test_region_library.gd` — the invariant's coverage, plus anything asserting
  `showdown_of` returns a single entry per region.
- `features/regions.md` and `features/rally-roster.md`.

Take care with the **snow corner**: `todo/one-map-four-corners.md` records that the
NE corner ships pin-less pending art, and the retired invariant was written partly
to permit that ("a region authored with NO rallies simply has none"). Retiring it
doesn't disturb the snow corner — it makes the empty case ordinary rather than
special-cased — but the two specs should stay consistent, and siting new specials
should not quietly claim the reserved NE corner.

---

## Tests

Per `CLAUDE.md`: **do not pin the ladder's numbers.** `5`, `10`, `15`, which part
sits at which rung, and nitrous magnitudes are all authored/tunable — a designer
retuning them must not break the suite. Test the logic that must hold for any
values:

- `total_stars` sums `best_placement` correctly and excludes specials.
- A part with `unlocked_by_rally` is absent from the draw pool while that rally
  is incomplete and present once complete — using **synthetic** fixtures
  (`UpgradeFixtures` / `RallyFixtures`), never a real catalogue entry.
- `rally_gate_met` returns `true` when the field is absent (the default path).
- A car with an unlocked part still to win **always** gets it — the "nothing"
  outcome never pre-empts a real reward.
- `draw_upgrade` returns `""` only in the maxed-car case, and a `""` draw installs
  nothing, appends nothing to `_upgrades_won`, and emits no `upgrade_revealed` —
  while the standings interstitial still fires.
- Box probability falls as boxes accumulate, and the first box at zero held is
  certain (the `+1`). Test the *shape* — monotonically decreasing, certain at zero —
  never the specific fractions.
- The mystery-box branch fires with swapping locked *without* requiring 3 tokens, and
  requires them once unlocked.
- `_other_car_has_room` failing yields nothing rather than a box.
- Nitrous starts full at every stage start *and* after an in-stage reset (there is
  no spent state to preserve).
- Nitrous does **not** move `effective_meta`'s power-to-weight, so fitting it never
  changes a car's eligibility or `qualifying_detune`.
- The nitrous gauge is hidden unless the part is fitted, and its caption carries no
  drop shadow (the gauge-caption exception — see `features/ui-design-system.md`).
- Nitrous is installed **enabled** on award, so it works with no menu interaction.
- The nitrous slot is absent from the upgrades menu's slot rows, and its absence
  doesn't strand the menu's keyboard walk.
- Holding the nitrous action multiplies drive torque and drains the bar; releasing it
  stops both; an empty bar applies no multiplier.
- The nitrous hue differs from `_BOOST_HUE`, so a car with both fitted shows two
  distinguishable bars.
- The mobile nitrous region exists in every scheme that can show it, sits left of
  the gas pedal (or the brake in auto-gas schemes), and is hit-tested **before** the
  simple left/right steering halves.
- The first-use hint shows once, is suppressed after the first press, and stays
  suppressed across a save/load round-trip.
- A part already in `installed_upgrades` keeps applying even while its
  `unlocked_by_rally` gate is closed (no retroactive uninstall).
- Extended `max_potential_meta` includes catalogue parts the car does not own, and
  the `pw_min` floor is judged against it while `pw_max` is judged on real stats.
- A special still runs the ordinary upgrade + car draws.
- No special's restriction depends on a part its own rung or higher unlocks; no
  rally is enterable *only* via the Drivetrain Conversion.
- A region may hold zero, one, or several specials (the retired per-region
  invariant), and a region holding none still resolves its look/waterline normally.
- Every special authors exactly 3 events, `"restriction": {}`, and a `requires_stars`
  matching its rung. Sanity guards only — do **not** pin turn counts, difficulties or
  `map_pos` values, which are all authored/tunable.
- `sandstorm` appears only on `greece` events (the existing test already covers this —
  make sure the new specials don't break it).
- Every coastal-waterline event authors `terrain_layer1_amplitude` >= 16.0.
- No two pins sit closer than the authored minimum spacing, and no pin lands in the
  reserved NE snow corner.
- A locked special's pin is non-pickable and the cursor walk skips it, but it
  still builds a readout box (the locked-pin exception) naming its unlock.
- A star-gated upgrade row is present-but-disabled in the upgrades menu rather
  than absent, and the keyboard walk skips it without stranding.
- Roster invariant: every authored `unlocked_by_rally` names a real rally id, and
  every special's `requires_stars` is reachable given the roster's max stars.

## Docs to update in the same pass

**DONE.** `features/nitrous.md` was created and indexed in `features/README.md`,
and the following were brought in line with the code: `rally-roster.md`,
`regions.md`, `reward-system.md`, `upgrade-catalogue.md`, `rally-session.md`,
`menus.md`, `save-persistence.md`, `forced-induction.md`, `engine-swap.md`,
`configuration.md`, `rally-challenge.md`, `README.md`, plus `hud.md`,
`ui-design-system.md`, `controls.md`, `mobile-controls.md`, `car-physics.md` and
`engine-audio.md`.

Two doc-adjacent loose ends:

- **`gameplay.md`** (the progression/endgame vision doc) was not revisited — worth
  a pass to make sure the north-star document describes the star ladder rather than
  per-region showdowns.
- **A stale CODE comment**: the `RALLIES` header comment in
  `scripts/rally_library.gd` (immediately above `const RALLIES`) still talks about
  "non-showdown rally", "`showdown = true`", "the showdown's events are longer" and
  the retired at-most-one-per-region invariant. The `REGIONS` header in
  `region_library.gd` was updated; this one was missed.

---

## Still outstanding

Everything else has shipped. These three are the remainder:

1. **The nitrous first-use hint.** Not started — nothing in `scripts/` references
   a hint or a first-use flag. The design is in *The first-use hint* above and is
   unchanged. It needs (a) a persisted once-per-profile flag in the save schema,
   and (b) a keyboard-vs-controller distinction, which `Platform` still lacks (it
   knows only `is_touch` / `is_web` / `is_mobile_or_web` / `is_headless`) — so
   either last-input-device tracking or, at minimum, "controller if any joypad is
   connected, else keyboard".

2. **`GameConfig.engine_nitrous_hiss_gain`.** The nitrous mix level is currently
   the local constant `NITROUS_HISS_GAIN` in `engine_audio_synth.gd`, which its own
   comment flags as standing in for a `GameConfig` field alongside
   `engine_supercharger_whine_gain`. Wiring it means adding the export, authoring it
   in `config/game_config.tres`, and caching it in the synth the way the other
   induction gains are cached.

3. **The engine-swap capability gate's UI half.** `RallyLibrary.engine_swaps_unlocked`
   is honoured by `RewardSystem._box_gate_open` only. To deliver the design in
   *Engine swaps: capability, not currency*, `hq.gd`'s swap station and
   `upgrades_menu.gd`'s engine-swap row must also consult it and frame banked tokens
   as a locked teaser (`3 TOKENS — LOCKED · Win the 20-star event`) rather than as a
   usable item. Until then the 20-star special's advertised unlock ("unlocks engine
   swaps", which `hq._special_unlock_line` already prints on its pin) is not real —
   which is a player-visible inconsistency, so this is the most urgent of the three.
