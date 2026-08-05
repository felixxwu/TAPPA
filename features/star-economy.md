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
gate governing its own ladder. Locked-special map pins quote "N/M events". Details in
[rally-roster.md](rally-roster.md).

Nothing in the game gates on the star balance. Upgrade parts gate on **winning a
particular special** (`UpgradeDef.unlocked_by_rally`, see
[upgrade-catalogue.md](upgrade-catalogue.md)), which is a rally id, not a currency.

## Spending: cars are bought

No rally pays a car any more — the draw is gone from `rally_session.gd`, and
`challenge_session.gd`'s `_COMPLETION_REWARD` no longer carries a `car_tier` (boxes
only). `RewardSystem.draw_car` survives as the *pick policy*, with exactly two callers:
the wreck safety net (`Save.open_mystery_box`, the one place a car is still free —
a player whose last car wrecked has no way to earn) and `RewardSystem.purchase_car`.

The purchase API (`reward_system.gd`) is pure over the profile it is handed, so the HQ
can price against the live profile and `sim_career` against a synthetic one:
`stars_available_in`, `car_price`, `is_stranded`, `purchase_car`. Price comes from
`GameConfig.star_cost_per_car`. `purchase_car` resolves the draw **before** any stars
move and abandons the whole transaction if it comes back empty — nothing to give means
nothing spent — and buys exactly one car per call, because the reveal is a moment, not a
slot machine. Full API and rationale in [reward-system.md](reward-system.md).

**The dead-end rescue.** `car_price` returns 0 when the player `is_stranded` AND cannot
afford a car. Without it, a stranded broke player has no eligible rally, so no way to
earn, so no way to buy the car that would open one — a state the old free-car model
could not produce. **Both** halves are required: free-whenever-merely-stranded is
farmable end to end, and requiring the player to also be broke closes it, since anyone
making progress is earning. `is_stranded` skips WRECKED cars — a wreck can never be
repaired, so a garage whose only in-band car is wrecked is as stuck as an empty one.

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
- **The HQ map meter** — `hq.gd` shows `"Stars: N"` from `Save.stars_available()`, the
  spendable balance, again with no denominator.
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
