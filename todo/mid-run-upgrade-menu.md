# Mid-run upgrade menu — repair/upgrade → power/handling → random roll

**Status: draft, not yet implemented — brainstorming with the user before writing code.**

## The ask

Replace the current between-stage pick (`RunPickPanel.open`, `scripts/run_pick_panel.gd`)
— today a single card list mixing repair + N randomly-drawn boosts/drivetrain/engine-swap
— with a multi-step, player-directed flow:

1. **Repair or Upgrade car** (card list, 2 cards). Repair card omitted when
   `RunSession.offer_repair()` is false (the undamaged-arrival case), same as today —
   goes straight to step 2.
2. **Better Handling or More Power** (card list, 2 cards) — the player's own choice of
   *direction*, replacing today's "3 random options, one of which you like" model.
3. **The roll** — a slow-machine-style reveal that randomly lands on ONE upgrade from
   the chosen category. No further player choice: whatever lands is what's applied.
   Shows the landed upgrade; a **Next** button carries on.
4. **Next → the existing stats screen** (`world.gd::_confirm_pick`, `CarStatsPanel`)
   showing before/after for the landed upgrade, then the existing skill-progress screen
   (`_show_skill_progress`), then apply + advance (`_apply_pick`) — **unchanged**, except
   the stats screen loses its Cancel button (there is nothing to cancel back to any more:
   the roll already committed the choice) and Apply becomes a plain **Next**.

## Category split (confirmed with the user)

| Category | Ids |
| --- | --- |
| **More Power** | `gearbox` (quick-shift), `engine_swap:<id>` (the real engine swap) |
| **Better Handling** | `lightweight`, `grip`, `aero`, `brakes`, `streamline`, `drivetrain:<mode>` (the AWD conversion) |

Stored as a new `"category"` field (`"power"` / `"handling"`) on each
`BoostLibrary.CATALOGUE` entry, plus a `BoostLibrary.category_of(id)` helper that also
classifies the two pseudo-id families (`drivetrain:` → handling, `engine_swap:` → power)
so callers never need to special-case the prefixes themselves.

## What does NOT change (deliberately)

**`RunSession`'s draw stays exactly as it is today.** `report_event_result`/`resume`
still call `_mode.boost_choices(...)` and still draw `Config.data.run_boost_choices`
(default 3) distinct entries — or `+1` for the undamaged-arrival reward — from the
merged pool (`BoostLibrary.CATALOGUE.keys() + drivetrain/engine-swap extras`), exactly
as `RegionRunMode.boost_choices` does now. `RunSession.pending_pick()`,
`choose_boost()`/`choose_drivetrain()`/`choose_engine_swap()`/`choose_repair()`, the
persisted `pick_awaiting`/`pick_offers_repair` fields, and every existing
`tests/headless/test_region_run.gd` assertion about pick size/content are untouched.

Why keep the pre-draw instead of rolling from the WHOLE catalogue per category: it's a
much smaller change (zero `RunSession`/`RegionRunMode`/persistence changes, zero
resume-safety work, zero test churn in `test_region_run.gd`), and it still delivers the
ask — the player picks a direction, then something in that direction is randomly
chosen for them. The trade-off: with only 3-4 pre-drawn entries, a category can end up
with zero eligible entries in a given pick (e.g. all 3 draws land on handling ids). See
below for how that's handled.

**The reveal step is presentation-only, not persisted.** If the app closes mid-flow
(after picking a category, before pressing Next), nothing has been committed —
`choose_boost`/etc. haven't run yet — so on resume the flow simply restarts at step 1
against the same re-derived `pending_pick()`. This mirrors how `_confirm_pick`/
`_show_skill_progress` already work today (not persisted, restart from the card list on
resume) — no new persisted state needed.

## Handling an empty/skewed category

Because the pool actually drawn is small (3-4 entries), one of the two categories can
have zero eligible entries this pick (e.g. `run_boost_choices = 3` and all three drawn
ids are `grip`/`aero`/`lightweight` — no power entry at all). The category-choice
screen (step 2) disables that card — same "locked rows stay visible, disabled,
`menu_nav_skip`" convention already used for locked regions/unaffordable shop rows
(`features/menus.md`) — rather than hiding it or letting it roll from an empty pool.

## File-by-file plan

### `scripts/boost_library.gd`
- Add `"category": "power"` / `"category": "handling"` to each `CATALOGUE` entry per
  the table above.
- Add `static func category_of(id: String) -> String` — reads the catalogue entry's
  `category`; for `id.begins_with("drivetrain:")` returns `"handling"`; for
  `"engine_swap:"` returns `"power"`; `""` for an unknown id.

### `scripts/run_pick_panel.gd` — restructured into per-step builders
Today's single `RunPickPanel.open(host, pick, on_choice, offer_repair)` becomes four
entry points, each returning a `MenuPage` built the same way (`MenuPage.open_modal` +
`CardUI.build_carousel`, `MenuNav.attach`) so every step reads as the same visual
system:

- `RunPickPanel.open_continue(host, on_choice) -> MenuPage` — the existing bare-Continue
  case (challenge stages; the run's own final/failed stage), now ALSO a one-card list
  ("Continue") rather than a bare action button, per "every choice-making menu should
  be a card list".
- `RunPickPanel.open_repair_or_upgrade(host, on_choice: Callable) -> MenuPage` — 2 cards,
  "Repair the car" / "Upgrade car". `on_choice` gets `"repair"` or `"upgrade"`.
- `RunPickPanel.open_category_choice(host, pick: Array, on_choice: Callable) -> MenuPage`
  — 2 cards, "Better Handling" / "More Power", each disabled when
  `_ids_for_category(pick, category)` is empty. `on_choice` gets `"handling"` or
  `"power"`.
- `RunPickPanel.open_roll(host, pick: Array, category: String, on_done: Callable) -> MenuPage`
  — builds a carousel with one card per `pick` entry in the chosen category (same card
  shapes `open()` already builds today — boost/drivetrain/engine-swap — factored into a
  shared `_add_pick_card` helper so the shape isn't duplicated a second time), picks a
  winner with `randi() % ids.size()` (not seeded — see "presentation-only" above), then
  runs a scripted "spin" (`CardCarousel.select(idx, true)` stepping toward the winner
  with growing intervals — new small helper, no CardCarousel API changes needed) that
  ends centred on the winner. A **Next** button (disabled until the spin finishes)
  fires `on_done(winner_id)`.

`label_for`/level-text logic for boost cards, and the drivetrain/engine-swap card
shapes, are lifted out of the old `open()` body into a shared helper so `open_roll`
reuses them exactly instead of re-deriving the display text.

### `scripts/world.gd`
- `_open_pick_panel()` becomes the top of the new step chain instead of a single
  `RunPickPanel.open` call:
  ```gdscript
  func _open_pick_panel() -> void:
      var pick := RunSession.pending_pick()
      if pick.is_empty():
          _interstitial_page = RunPickPanel.open_continue(self, _on_interstitial_choice)
      elif RunSession.offer_repair():
          _interstitial_page = RunPickPanel.open_repair_or_upgrade(self, _on_repair_or_upgrade)
      else:
          _open_category_panel()
  ```
- New `_on_repair_or_upgrade(choice)`: `"repair"` → `_on_interstitial_choice("repair")`;
  `"upgrade"` → `_open_category_panel()`.
- New `_open_category_panel()`: swaps in
  `RunPickPanel.open_category_choice(self, RunSession.pending_pick(), _open_roll_panel)`.
- New `_open_roll_panel(category)`: swaps in
  `RunPickPanel.open_roll(self, RunSession.pending_pick(), category, _on_interstitial_choice)`.
- `_on_interstitial_choice` is unchanged (still routes `""`/`"repair"` straight to
  `_show_skill_progress`, anything else to `_confirm_pick`).
- `_confirm_pick`: drop the **Cancel** button and its `_open_pick_panel_again` wiring —
  there is no card list to go back to any more (the choice was rolled, not picked from a
  visible list) — and rename **Apply** to **Next**. `MenuNav.attach(page, {})` (no
  `on_back`), matching `_show_skill_progress`'s already-Continue-only shape. Everything
  else in that function (the stats panel, the boost's own effect-text line) stays as is.
- `_open_pick_panel_again` is deleted along with its only caller.

### `features/region-runs.md`
Update "The pick screen" / "Three screens now, not one" sections to describe the new
4-step chain (repair-or-upgrade → category → roll → stats → skill progress → apply) in
place of the old single-card-list description, and note the category split table.

## Tests

- `tests/headless/test_run_pick_panel.gd` — extend for the new step builders: each
  step's card list is keyboard/gamepad-navigable (`MenuNav` nav test, per CLAUDE.md's
  mandatory menu rule), category cards disable correctly when a category has no
  eligible entries in a synthetic `pick`, `open_roll`'s winner is always drawn from the
  entries actually passed in for that category (never the other category's ids, never
  an id not in `pick`).
- `tests/headless/test_region_run.gd` — unchanged (RunSession's draw/persistence
  contract is untouched, per "what does not change" above).
- No new test touches `world.gd`'s `_confirm_pick`/step-chaining — same as today,
  that layer is compile-checked only (`main.tscn` instantiation cost), not unit tested.

## Open questions for the user

1. Is the **3-way pre-draw staying at `run_boost_choices` (default 3)** an acceptable
   trade-off, given it means a category can come up empty/disabled on a given pick? The
   alternative (roll from the ENTIRE catalogue per category, not just the pre-drawn
   subset) is a materially bigger change — it touches `RunSession`'s draw/persistence
   and `test_region_run.gd`'s pinned pick-size assertions — but guarantees both
   categories always have something to offer.
2. Any preference on the **spin/reveal feel** (roughly how long it should run, how many
   "tick" steps) — I'll default to something in the ~1.5-2.5s range with 8-10 ticks,
   authored as new `GameConfig` fields (not hardcoded) so it's designer-tunable, unless
   you'd rather specify numbers now.
