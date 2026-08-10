# Star Economy

Stars are the game's single currency. You **earn** them by placing well in rallies and
**spend** them on cars at the HQ present box. Design: `todo/star-economy.md`.

Before this, stars were a *score*: a number derived from the roster that gated the
special-event ladder, and cars were handed out free for every top-3 finish. Both halves
changed at once, and they had to: a guaranteed car per win made the rallies'
`restriction` bands meaningless (the garage filled itself faster than the bands could
filter), and the moment stars became spendable a gate reading the balance would have
*revoked* a special the player had already qualified for as soon as they bought a car.

## The ledger (persisted)

`Save.profile` carries two counters — `stars_earned` and `stars_spent`
(`save_manager.gd` → `_default_profile`). `Save.stars_available()` is the difference,
floored at 0; `award_stars()` credits, `spend_stars()` debits and returns `false`
(changing nothing) when the balance is short.

Two counters rather than one balance so the lifetime-earned figure survives spending.
And **persisted, not derived** — `RallyLibrary.total_stars()` / `max_total_stars()` are
gone — for two reasons the old derived total could not handle:

- Rally Challenge income has no rally record to derive from, so it was invisible.
- A derived total *shrinks* when a rally is renamed or retired, which would drop the
  balance below `stars_spent` and produce a negative balance out of a content edit.

Missing keys read 0, so adding them needed no `SCHEMA_VERSION` bump. See
[save-persistence.md](save-persistence.md).

## Earning

`RallyLibrary.stars_for_placement(placed)` is THE definition of what a placement is
worth (1st = `MAX_STARS_PER_RALLY`, descending to 0 off the podium). Every surface that
pays stars and every surface that *shows* them goes through it — `Save.complete_rally`,
the Rally Challenge payout, `hq._stars_for`'s per-pin star row and the podium's stars
beat — so a paid star and a drawn star can never disagree.

Sources:

- **Career rallies** — `Save.complete_rally(rally_id, combined_ms, placed)` credits and
  **returns the DELTA**: only the improvement over that rally's previous best. A re-win
  at an equal or worse placement pays nothing, which is what keeps the renewable-win
  loop from being farmed for currency. Turning a 2nd into a 1st is worth exactly 1,
  even though the two placements *rate* 2 and 3 stars.
- **Special events** — specials now award stars like any other rally. They used to award
  none, and that is only safe because the ladder no longer gates on the balance.
- **The Rally Challenge** — `challenge_session.gd` awards 1/2/3 by placement through the
  same `stars_for_placement` curve, via `Save.award_stars`. This is the one
  **renewable-over-real-time** star source, deliberately: it gives a stuck player
  something to grind. A mid-table finish legitimately banks 0, which is why its boxes
  are unconditional. See [rally-challenge.md](rally-challenge.md).

## Gating is on COMPLETIONS, not stars

Special events gate on the player's global count of completed **ordinary** rallies
(`requires_completions`, read through `RallyLibrary.completions_required`), not on a
star total — because a spendable balance goes *down*, and an unlock must never be
revoked by a purchase. `special_gate_open`, `stars_required`, `stars_needed` and
`engine_swap_star_requirement` are gone, replaced by `completions_required`,
`completions_needed` and `engine_swap_completion_requirement`.
`RallyLibrary.rally_revealed` no longer branches on `is_special` at all — one rule for
every rally. `_completed_count` still excludes specials, so a special never advances the
gate governing its own ladder. The map quotes the requirement as "N/M **rallies**" — an
*event* is one stage inside a rally, so "rallies" is what the gate actually counts — and
only on the **next** locked special (`RallyLibrary.next_locked_special_id`); the specials
above it stand their trophies and say nothing until it is their turn. Details in
[rally-roster.md](rally-roster.md) and [menus.md](menus.md).

Nothing in the game gates on the star balance. Upgrade parts gate on **winning a
particular special** (`UpgradeDef.unlocked_by_rally`, see
[upgrade-catalogue.md](upgrade-catalogue.md)), which is a rally id, not a currency.

## Spending: repairs and part copies

**Cars are not bought.** A car is won at the rally that advertises it — see
[prize-rallies.md](prize-rallies.md). The present box, `RewardSystem.purchase_car`,
`car_price`, `is_stranded`, the stranded-and-broke free-car rescue and
`GameConfig.star_cost_per_car` are all **deleted**. What replaced the dead-end rescue is a
CONTENT invariant proven over the map (every rally reachable, every starter able to enter
something from a fresh profile — see [map-exploration.md](map-exploration.md)), rather than
a runtime discount.

Two sinks remain, both on `Save`, both demand-driven and renewable — which is what a
currency needs if the balance is not to become dead weight:

### Repair — `Save.repair_car` / `repair_price` / `car_needs_repair`

A flat `GameConfig.star_cost_per_repair` returns a car to full health with straight
wheels. Deliberately **cheap**: repair is a ritual and a small tax, not an economic wall.
The real cost of wrecking is the lost rally result (a DNF, no podium, no progress), and
pricing the repair steeply would punish the same mistake twice. Flat rather than per-HP so
the player never has to arithmetic their way to "is it worth fixing".

`car_needs_repair` covers **both** lost HP and bent wheel toe — a car at full health with
dog-legged toe still drives badly, and charging for a repair that changes nothing is the
one thing a flat price must never do. Nothing to fix = nothing spent, and the charge
resolves before the car is touched, so a short balance leaves both untouched.

The UI is the tuning lift's hub row (`hq._repair_selected_car` /
`_refresh_repair_button`) — per-CAR, so it belongs at the station where you work on the car
in front of you rather than on the garage-wide row. It states all three cases on the button
("Repair" disabled when nothing to fix, "Repair N★" enabled, or disabled when short)
rather than vanishing: the price is information the player can act on even when they cannot
pay it yet.

### Part copies — `Save.buy_part` / `can_buy_part` / `part_price`

Upgrades are **car-bound**, so a part won once is fitted to one car. `star_cost_per_part`
buys a copy for any other car — per-car-per-part, so the sink is effectively bottomless.

`can_buy_part` is the single predicate the button and the purchase both read, so they
cannot diverge. It requires the part to be **discovered** (its part-unlock rally won, via
`UpgradeLibrary.rally_gate_met`) — the shop sells what the player has proven they can earn,
never a shortcut past the exploration that reveals it — and honours the **per-car**
prerequisite ladder, so buying cannot skip a rung.

The UI is the upgrades menu's existing slot rows (`upgrades_menu._make_option_selector`):
a discovered part not on this car renders as `Name N★` and buys on press. No separate
shop screen, because it is the same question the player is already asking there — "can this
car run a big turbo?" — and the answer is now "yes, for N stars" instead of a dead grey
option. Bought parts fit **disabled**, like every other award.

### What the random draw still does

`RewardSystem.draw_upgrade` is **consumables-only** now: the engine swap token and the
mystery box, plus `NO_REWARD`. Parts left the pool because a stage-by-stage drop undercut
both deliberate routes to one — why go and win a turbo, or pay for one, if it might fall
out of the next stage? Most events therefore pay nothing, which is a real outcome rather
than a bug. The mystery box keeps its own certainty curve (the first is guaranteed) instead
of being one weight among others.

## Where the player sees it

- **The podium's stars beat** — `podium.gd` `Stage.STARS`, straight after `LEADERBOARD`
  and **always** run, including on a DNF or an off-podium finish (three dim stars is
  honest, and skipping the beat would make the absence of stars feel like a bug).
  `_show_stars` / `_reveal_stars` fill three big `StarRow` stars gold one at a time to
  the rally's rating. Two different numbers are shown on purpose: the GOLD COUNT is the
  rating at the player's best-ever placement (the same figure the rally's map pin
  shows), while the CAPTION (`_stars_caption`) carries the **ledger delta** plus the
  spendable balance — otherwise a re-win would light two gold stars while the balance
  sat still. There is deliberately no "x of N" denominator anywhere: with a spendable
  balance there is no maximum to count towards. `RallySession.last_result()` supplies
  both figures as `star_rating` and `stars_gained`.
- **The HQ map meter** — bottom centre of the table HUD: a drawn star plus the digits of
  `Save.stars_available()`, the spendable balance, again with no denominator.
- **The UPGRADES page** — the heading carries the balance (`hq._refresh_lift_menu_title`),
  and every price on it — a part copy, a lightweight shell, Repair — quotes its digits with
  a star after them.

**Every star on screen is DRAWN, never the `★` character.** Syne Mono has no `★`/`☆` glyph
(see [menus.md](menus.md)), so a `★` in a label only ever rendered because the OS handed
Godot a system fallback font. The **web export has no system fonts**, so on mobile web
every price read as a tofu box. Two shapes, both from `scripts/star_row.gd`, so the
geometry has one definition:
- **A star beside a Label** → a `StarRow` node as the label's SIBLING, the label carrying
  the digits alone (`hq._refresh_lift_menu_title` + `HqOverlays.build_lift_overlay`, and the
  map meter in `build_table_overlay`).
- **A star inside a Button** → `StarRow.price_icon()` on the button's `icon` with
  `icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT`, because a Button lays out no children
  (`UpgradesMenu._option_button`, `hq._refresh_repair_button`). Button's own
  `icon_disabled_color` dims the star with the label, so an unaffordable price greys as one
  piece. `StarRow.PRICE_RADIUS` is the one size, so no price star can drift from another.

The parentheses went with the glyph — `SMALL 2★`, not `SMALL (2★)`: a star after the digits
already reads as a price, and the two characters matter on the weight row, which is the
widest slot row in the menu (see `UpgradesMenu._OPTION_BUTTON_PAD`).
- **The present box** — a procedural gift-box prop (`scripts/present_box.gd`,
  `class_name PresentBox`, `build()` / `build_openable(scale)`) standing on the world
  map as its one non-rally target, with the price/`FREE` readout above it. Tap and the
  keyboard/gamepad cursor both funnel through `hq_table.activate_present_box()`, which goes
  **straight to the box** — no confirm dialog first. The bottom button of the ordinary
  car-park chrome is the till (it quotes the price and disables when the balance is short);
  pressing it buys the car, **spawns it inside the still-closed box**, then opens the box on
  it (lid up, four walls falling on a gravity curve) and names it in the label **under the
  car** — no result modal. See [menus.md](menus.md) for the full flow, the map-target
  wiring and the nav path.

## Tests

`tests/headless/test_save_manager.gd` — the ledger (an empty fresh ledger,
`award_stars` for non-rally sources, the `complete_rally` delta, a refused overdraft,
and the whole thing surviving a save/reload).
`tests/headless/test_reward_system.gd` — `is_stranded` (including the wrecked-car
exclusion), pricing, the debit-and-grant, and the rescue firing only when stranded AND
broke. `tests/headless/test_rally_library.gd` — the star curve's shape and the
completion gate. `tests/headless/test_rally_session.gd` — `star_rating` /
`stars_gained` on the result. `tests/headless/test_menu_flow.gd` — the HQ/purchase
flow. `tests/headless/test_sim_career.gd` — the career simulator over the real
predicates.

Per `CLAUDE.md` the authored numbers are NOT test-pinned: `star_cost_per_car`,
`MAX_STARS_PER_RALLY` and the `requires_completions` rungs are all tunable content, so
tests assert the logic (a debit moves the balance by the price; the rescue needs both
conditions) and never the chosen values.
