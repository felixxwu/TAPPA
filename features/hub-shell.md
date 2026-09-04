# Hub Shell — the flat UI

**Source:** `scripts/hub_shell.gd` (`HubShell`), `hub.tscn` (the main scene — a bare
full-rect `Control` the shell builds pages under). Built on `MenuPage` + `MenuNav`
([menu-navigation.md](menu-navigation.md)).

**Tests:** `tests/headless/test_hub_shell.gd`

The game's main scene and **the only way into a run**. It replaces the diegetic 3D hub
(`hq.tscn`, 3527 lines, plus nine collaborator scripts) and the overworld, both deleted in
stage 2b of the roguelike pivot; decision 9 chose a flat 2D UI outright. See
`todo/roguelike-pivot.md`.

## Deliberately plain, and deliberately temporary

Stage 3's bar was *the loop runs start to finish*, not *the loop looks good*, and that bar
still holds — the shell is stacked pages of plain buttons, now six of them rather than
four (stage 6 added `SHOP` / `BOOST_SHOP` in place, on this same script, rather than
spinning off a dedicated one). Stages 7–8 still owe perks and lifetime stats. **Do not
invest in its looks, and do not grow it past what a plain button list can hold** — give a
future screen its own script if it needs anything richer than a row-of-buttons page. The
whole shell is still smaller than any single one of the nine hub scripts it replaced.

## The six pages

`HubShell.View` — `MAIN`, `REGION`, `CAR`, `SUMMARY`, `SHOP`, `BOOST_SHOP`. One page is
live at a time; `_show(view)` frees the previous page's `CanvasLayer` before building the
next, so a stale page can never sit under the tree still claiming input.

| Page | Offers |
| --- | --- |
| `MAIN` | Money, **Resume run** (only when one is paused), New run, Shop, Quit |
| `REGION` | Every region in AUTHORED order, marked when cleared; locked ones named with their gate |
| `CAR` | Every owned car (selectable to start the run) PLUS every unowned `CarLibrary` car with a `Buy <name> — <cost>` row (decision 28) |
| `SUMMARY` | Stages cleared, money earned, per-stage times |
| `SHOP` | Boost levels (→ `BOOST_SHOP`), the Engine Swap unlock |
| `BOOST_SHOP` | One row per `BoostLibrary.CATALOGUE` id: level, price of the next level, `BoostLibrary.effect_range_text` |

`_back()` (Esc / gamepad B) walks `CAR → REGION → MAIN` and `BOOST_SHOP → SHOP → MAIN`.
`MAIN` and `SUMMARY` are roots and absorb Back rather than dropping the player into a page
they never opened.

Car BUYING lives on the `CAR` page rather than a `SHOP` sub-page, per decision 28's own
wording ("the car select screen offers a Buy action for unowned cars") — one list serves
both picking and buying, since a player looking at "which car" is already looking at
exactly the list a shop would show. Boost levels and the Engine Swap unlock are different:
permanent purchases with no tie to picking a car for THIS run, so they hang off `MAIN`
instead. See [region-runs.md](region-runs.md) → *The meta tier* for what each purchase
actually does.

## Navigation is a hard requirement, not a nicety

`CLAUDE.md` requires **every** menu in the game to be keyboard + gamepad navigable, and a
new menu to ship with a nav test in the same piece of work. Every page here goes through
`MenuNav.attach`, and every body row is a `Button` rather than a `Label` **because
`MenuNav` only walks focusable controls** — a label row would be invisible to the keyboard
and silently break the contract. `test_hub_shell.gd` walks all six views and asserts each
has a `MenuNav` and at least one focusable control — including `SHOP` and `BOOST_SHOP`
even when every purchasable row on them is disabled (unaffordable or at its level cap):
`Back` is always a live `_action`, so the assertion holds regardless of the player's money.

The test file pins the **screen graph and the navigation**, and deliberately nothing about
looks, wording or button order — stages 7–8 still rewrite parts of it, and a layout
assertion would break on those while proving nothing.

## Locked regions are shown, not hidden

Regions unlock linearly: region `order` 0 is always open, every other is gated on the one
before it being in `Save.KEY_REGIONS_CLEARED`. The page lists them via
`RegionLibrary.ordered()` — **never array position**, which that table's header states
carries no meaning.

A locked region stays on the page, named, saying what opens it. Hiding it leaves a new
player with one row and no idea the game continues; showing it unpressable with no
explanation is worse. Its button is `disabled` **and carries the `menu_nav_skip` meta** —
that meta is the framework's own opt-out, and it is required rather than optional:
`MenuNav.attach` runs *after* the page is built and re-enables focus on every `BaseButton`
it finds, so setting `focus_mode` alone is silently undone and the keyboard lands on a dead
row.

## The run summary is one-shot

`_ready()` opens `SUMMARY` instead of `MAIN` whenever `RunSession.last_result()` is
non-empty. A run that ends hands control back here via `world.gd` →
`Scenes.hub_path()`, and without this the player is dropped at a title screen with no idea
whether they cleared the region.

That makes clearing the result load-bearing: `RunSession.clear_last_result()` exists for
exactly this, is called only by the screen that displayed the result, and is deliberately
**not** called by `start()`/`begin()` — a run's outcome has to outlive the run object,
because the scene change back to the hub happens after the session has already gone idle.
A summary that failed to clear would trap the player on it forever.

One screen serves **both** outcomes — region cleared, and stopped by the clock. A run that
ends on a missed target has no placement to celebrate, and the same information is worth
reading either way (`gameplay.md` → *The run, end to end*).

## Decision 48's confirm lives here

The profile holds **one run slot** (decision 27), so starting a run discards any paused run
of either kind — and discarding **burns its attempt** (decision 48, implemented in
`RunSession.discard_run`). The shell owes the other half of that rule: `_start_run` raises
a `ConfirmPopup` that says in plain words that the attempt is used and cannot be gone back
to. The rule is defensible; discovering it after the fact is not.

`MAIN` therefore lists **Resume run first**, above New run. Putting it anywhere else is how
a player loses a run they meant to finish.

## Known gaps, by design

- **No perk or lifetime-stats pages.** Stage 7.
- **No collectables HUD.** Stage 8.
- **No challenge entry point.** The Daily/Weekly/Monthly challenge is retained (decision
  15) and `RunSession` already drives it through `ChallengeRunMode`, but its flat screen is
  still outstanding — see `todo/roguelike-pivot.md` → *Salvaged from `hq_challenge.gd`* for
  the orchestration that screen must reproduce.
- **No re-displayed "locked" swap UI.** The Engine Swap unlock can be BOUGHT (the `SHOP`
  page), but there is no picker screen yet that re-checks
  `RallyLibrary.engine_swaps_unlocked` and shows a locked state — see
  [engine-swap.md](engine-swap.md) for the two old consumers that used to and are gone.
