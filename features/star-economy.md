# Star Economy

Stars are the game's single currency. You **earn** them by placing well in rallies and
**spend** them on car repairs and on upgrade parts, from the upgrades menu's own slot
rows. Cars are **not** bought — they are won at the rally that advertises them (see
[prize-rallies.md](prize-rallies.md)). Design: `todo/star-economy.md`.

**Tests:** `tests/headless/test_save_manager.gd`, `tests/headless/test_rally_library.gd`

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
worth. Every surface that pays stars and every surface that *shows* them goes through it —
`Save.complete_rally`, the Rally Challenge payout, `hq._stars_for`'s per-pin star row and
the podium's stars beat — so a paid star and a drawn star can never disagree.

**Three tiers:** **1st** pays `STARS_FOR_WIN` (3), the **rest of the podium**
(2nd–`PODIUM_PLACES`) pays `STARS_FOR_PODIUM` (2), **any other finish** pays
`STARS_FOR_FINISH` (1), and not finishing (`placed <= 0`) pays nothing. Winning outright
pays strictly more than scraping the podium — the win is what the player is chasing, and
the rally's car/part prize alone did not make that legible in the currency itself. Below
the win the curve is FLAT: 2nd and 3rd pay alike, and so does every finish behind them, so
a rally the player cannot podium is still worth driving. This briefly ran as two flat tiers
(podium = 2, any other finish = 1) with no win bonus; the 1st-place tier is back.

`PODIUM_PLACES` and `MAX_STARS_PER_RALLY` are **separate constants**. They used to be one
number doing both jobs (a 1st→3 / 2nd→2 / 3rd→1 ramp made them necessarily equal); kept
apart, widening the podium cannot silently change what a win pays. `MAX_STARS_PER_RALLY`
(= `STARS_FOR_WIN`) is the denominator the star rows draw against.

Sources:

- **Career rallies — RE-WINNABLE.** `Save.complete_rally(rally_id, combined_ms, placed)`
  credits what **this** finish placed, every time, and returns it. Replaying a rally is a
  legitimate way to earn stars. It used to credit only the improvement over that rally's
  previous best (so a replay at an equal or worse placement paid nothing) as an anti-grind
  guard; that guard is deliberately gone. **Consequence for price tuning:** star income is
  now bounded only by the player's patience, so repair and part costs are the only thing
  holding the economy up.
  The payout reads `placed`, never the stored `best_placed` — the record only ever improves,
  so paying off it would silently reinstate the old rule. `best_placed` is still tracked,
  because it drives the map's star rating; it just no longer gates what gets paid.
  The **car** prize is still one-time (see [reward-system.md](reward-system.md)): an easy
  rally refilling the garage forever would make the rallies' `restriction` bands meaningless,
  which is the half of the original grind guard that still matters.
- **Special events** — specials now award stars like any other rally. They used to award
  none, and that is only safe because the ladder no longer gates on the balance.
- **The Rally Challenge** — `challenge_session.gd` awards by placement through the same
  `stars_for_placement` curve, via `Save.award_stars`. It is renewable **over real time** (a
  new challenge each day), where career rallies are renewable **on demand**. Sharing the one
  curve means a mid-table challenge finish now banks `STARS_FOR_FINISH` rather than 0.
  **Completing a challenge also pays a flat star amount of its own**
  (`ChallengeSession._COMPLETION_REWARD`, authored per kind — Daily smallest, Monthly
  largest — granted through `Save.award_stars` alongside the placement credit). That
  table used to pay mystery boxes; with the box retired, the reward became the currency
  the boxes were always a detour around. See [rally-challenge.md](rally-challenge.md).

### Adding a NEW star payout at the end of a career rally

`RallySession._resolve_results()` has **two named reward seams**, and which one you put a
new payout in decides its gate — see [reward-system.md](reward-system.md) → *Where a NEW
end-of-rally reward goes*:

- `_award_podium_rewards(...)` — pays only on a podium (or the opening rally's first
  attempt). This is where the existing `Save.complete_rally` placement payout lives.
- `_award_any_finish_rewards(...)` — pays on **any** non-DNF finish. Empty today. A bonus
  that should not be podium-gated (e.g. one keyed on finishing without damage) belongs
  here, and pays via `Save.award_stars`.

A bonus keyed on the run being **clean** must ask `RallySession.took_damage_this_rally()`
(or the finish result's `took_damage`), never the car's HP — HQ repairs cost stars, so cars
enter rallies already damaged, and field repairs run before resolve. See
[damage.md](damage.md) → *HP is NOT a damage oracle*.

## Gating is GEOMETRIC, not stars and not completions

Special events gate exactly like every ordinary rally: `RallyLibrary.rally_revealed`
compares a rally's `map_pos` against the lit circles of every completed rally on the
roster (`lit_sources`), with no `is_special` branch at all — see
[map-exploration.md](map-exploration.md). This replaced an earlier completion-count
ladder (`requires_completions` / `completions_required` / `completions_needed`), which
itself replaced gating on the roster-wide STAR TOTAL; both were retired because their
unlocks had no visible relationship to the rally just won, whereas a pin's position
does — and a spendable star balance goes *down*, so a gate reading it would have closed
behind a player who had already passed it. `special_gate_open`, `stars_required`,
`stars_needed`, `engine_swap_star_requirement`, `completions_required`,
`completions_needed` and `engine_swap_completion_requirement` are all gone. The
engine-swap *capability* gate is now a per-rally hook, `RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY`
(`front_runners`), checked via `RallyLibrary.engine_swaps_unlocked(profile)` — see
`features/save-persistence.md` (`scripts/save_manager.gd`) and
[map-exploration.md](map-exploration.md). The map's locked-special teaser now names the
event and what it unlocks rather than quoting a progress fraction, and only on the
**nearest** locked special (`RallyLibrary.nearest_locked_special_id`); the specials
beyond it stand their trophies and say nothing until the frontier reaches them. Details
in [rally-roster.md](rally-roster.md) and [menus.md](menus.md).

Nothing in the game gates on the star balance. Upgrade parts gate on **winning a
particular special** (`UpgradeDef.unlocked_by_rally`, see
[upgrade-catalogue.md](upgrade-catalogue.md)), which is a rally id, not a currency.

## Spending: repairs and part copies

**Cars are not bought.** A car is won at the rally that advertises it — see
[prize-rallies.md](prize-rallies.md). `RewardSystem.purchase_car`, `car_price`, the
stranded-and-broke price-0 rescue and `GameConfig.star_cost_per_car` are all **deleted**.
So is the anti-soft-lock rally unlock that `is_stranded` / `_unlock_candidates` armed:
entry is purely categorical now, so nothing can be too slow to enter anything. One thing
outlived the purchase flow: the present-box PROP, re-purposed as the free prize-car reveal (see "Where the player sees it"
below). What replaced the dead-end rescue is a
CONTENT invariant proven over the map (every rally reachable, every starter able to enter
something from a fresh profile — see [map-exploration.md](map-exploration.md)), rather than
a runtime discount.

Two sinks remain, both on `Save`, both demand-driven and renewable — which is what a
currency needs if the balance is not to become dead weight:

### Repair — `Save.repair_car` / `repair_price` / `car_needs_repair`

A flat `GameConfig.star_cost_per_repair` returns a car to full health with straight
wheels. Deliberately **cheap**: repair is a ritual and a small tax, not an economic wall.
Damage never writes a car off or ends a run, so the real cost of crashing is paid on the
road: a misfiring, rev-capped engine and bent wheels for the rest of the rally (see
[damage.md](damage.md)) — a slower result, on top of this bill. Pricing the repair steeply
would punish the same mistake a third time. Flat rather than per-HP so
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

The UI is the upgrades grid's slot popups (`UpgradeOptions.options_for` fills in a
`price`; `UpgradeSlotPopup` hangs a drawn `StarRow.price_icon()` on the row): a discovered
part not on this car is an ordinary selectable option carrying its price, and buys on
press. No separate
shop screen, because it is the same question the player is already asking there — "can this
car run a big turbo?" — and the answer is now "yes, for N stars" instead of a dead grey
option. `Save.buy_part` itself fits the part **parked**, like every other award, but the
picker path immediately enables it (`UpgradesGrid._apply_option`): the player chose this rung
and paid for it, so it would be a poor trade to take the stars and leave the car driving
exactly as before. Parked-on-arrival stays the rule for the paths that hand out a part
nobody asked for — see [upgrade-catalogue.md](upgrade-catalogue.md) → "Acquisition".
Each row also quotes the performance rating that option would give the car, drawn in
parentheses BEFORE the price so the two figures cannot be confused (the price keeps its
drawn star icon) — see [menus.md](menus.md) → "The slot popup".

### The random draw is gone entirely

`RewardSystem.draw_upgrade` no longer exists. Parts left its pool first, because a
stage-by-stage drop undercut both deliberate routes to one — why go and win a turbo, or
pay for one, if it might fall out of the next stage? That left it paying only the two
consumables, and once those were deleted too (the mystery box and the engine swap token
— see [reward-system.md](reward-system.md)) a draw that could only ever pay nothing had
no reason to fire. **Stars are now the only thing a stage pays**, and buying is the only
route to a part the player didn't win outright at a special.

This makes the two sinks above load-bearing rather than optional: with no free parts
falling out of the rally loop, the balance is what a player spends to make a car faster,
and the prices are the whole difficulty curve of the economy.

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
- **The upgrades grid's slot popups** — a price beside any discovered part not yet on this
  car, greyed when the balance is short (the price is information the player can act on
  even when they cannot pay it). The page's own HEADING ROW carries the balance
  (`UpgradesGrid.build_title_row`: the page title, then digits + a drawn star),
  because this is where stars are spent — and because the prices sit one press away inside
  a popup, so a balance remembered from another screen would turn every purchase into
  arithmetic. It lives in the COMPONENT rather than in each
  host's heading so all FOUR hosts show it — the HQ lift, the car-park detune
  popup, the start line's Upgrades overlay and the upgrade reveal's — and so every
  `rebuild()` (which a purchase triggers) re-reads it. It used to be spliced into the HQ
  lift's page title, which is why the other three showed no balance at all. See "Part
  copies" above.
- **The tuning lift's hub row** — the per-car Repair button, stating its price. See
  "Repair" above.

**Every star on screen is DRAWN, never the `★` character.** Syne Mono has no `★`/`☆` glyph
(see [menus.md](menus.md)), so a `★` in a label only ever rendered because the OS handed
Godot a system fallback font. The **web export has no system fonts**, so on mobile web
every price read as a tofu box. Two shapes, both from `scripts/star_row.gd`, so the
geometry has one definition:
- **A star beside a Label** → a `StarRow` node as the label's SIBLING, the label carrying
  the digits alone (`UpgradesGrid.build_title_row`, and the map meter in
  `HqOverlays.build_table_overlay`).
- **A star inside a Button** → `StarRow.price_icon()` on the button's `icon` with
  `icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT`, because a Button lays out no children
  (`UpgradeSlotPopup`'s priced option rows, `hq._refresh_repair_button`). Button's own
  `icon_disabled_color` dims the star with the label, so an unaffordable price greys as one
  piece. `StarRow.PRICE_RADIUS` is the one size, so no price star can drift from another.

The polygon RASTERISER behind both shapes lives in `PolygonIcon` (`scripts/polygon_icon.gd`),
not in `StarRow` any more: `StarRow.texture` delegates to `PolygonIcon.texture`, which the
`WrenchIcon` shares (the grid's slot pictures are authored SVGs — `UpgradeIcons` — with
the drawn wrench as the fallback for a slot no artwork exists for yet). Same tofu reasoning, applied once — the star just
happened to be the first drawn icon that needed it.

The parentheses went with the glyph — `SMALL 2★`, not `SMALL (2★)`: a star after the digits
already reads as a price, and the two characters matter in an option row, where the price
shares its line with the option's name.

**Not a star sink: the present box.** `scripts/present_box.gd` (`class_name PresentBox`,
`build()` / `build_openable(...)`) survives, but purely as the **prize-car reveal** for a
car the player has ALREADY won — `hq._enter_present_box(instance_id)`, armed off
`RallySession.pending_car_reveal_instance_id`. Its bottom button reads Open and is never
disabled, because "the box is a presentation, not a transaction": backing out cannot cost
the player the car, and no balance is ever consulted. See
[prize-rallies.md](prize-rallies.md).

## Tests

`tests/headless/test_save_manager.gd` — the ledger (an empty fresh ledger,
`award_stars` for non-rally sources, the `complete_rally` delta, a refused overdraft,
and the whole thing surviving a save/reload).
`tests/headless/test_reward_system.gd` — the two gates that decide what may be BOUGHT
(the per-car prerequisite rung, and a part refused until its event is won).
`tests/headless/test_rally_library.gd` — the star curve's shape and the
geometric reveal gate. `tests/headless/test_rally_session.gd` — `star_rating` /
`stars_gained` on the result. `tests/headless/test_menu_flow.gd` — the HQ/purchase
flow. `tests/headless/test_sim_career.gd` — the career simulator over the real
predicates.

Per `CLAUDE.md` the authored numbers are NOT test-pinned: `star_cost_per_part`,
`star_cost_per_repair`, `MAX_STARS_PER_RALLY` and every rally's `map_pos` /
`reveal_radius` are all
tunable content, so tests assert the logic (a debit moves the balance by the price; a
purchase needs the part discovered and its prerequisite fitted) and never the chosen
values.
