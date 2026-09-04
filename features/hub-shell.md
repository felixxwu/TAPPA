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

Stage 3's bar is *the loop runs start to finish*, not *the loop looks good*. The shell is
four stacked pages of buttons. Stages 4–8 replace the region and car pages with real
screens — a car shop, boost levels, perks, lifetime stats — and this file is expected to be
rewritten around them. **Do not invest in its looks, and do not grow it into the place
those features live**: give each its own script when it lands. The whole shell is smaller
than any single one of the nine hub scripts it replaced, which is why it is one file.

## The four pages

`HubShell.View` — `MAIN`, `REGION`, `CAR`, `SUMMARY`. One page is live at a time;
`_show(view)` frees the previous page's `CanvasLayer` before building the next, so a stale
page can never sit under the tree still claiming input.

| Page | Offers |
| --- | --- |
| `MAIN` | Money, **Resume run** (only when one is paused), New run, Quit |
| `REGION` | Every region, marked when cleared |
| `CAR` | Every owned car; a note when the profile has none |
| `SUMMARY` | Stages cleared, money earned, per-stage times |

`_back()` (Esc / gamepad B) walks `CAR → REGION → MAIN`. `MAIN` and `SUMMARY` are roots and
absorb Back rather than dropping the player into a page they never opened.

## Navigation is a hard requirement, not a nicety

`CLAUDE.md` requires **every** menu in the game to be keyboard + gamepad navigable, and a
new menu to ship with a nav test in the same piece of work. Every page here goes through
`MenuNav.attach`, and every body row is a `Button` rather than a `Label` **because
`MenuNav` only walks focusable controls** — a label row would be invisible to the keyboard
and silently break the contract. `test_hub_shell.gd` walks all four views and asserts each
has a `MenuNav` and at least one focusable control.

The test file pins the **screen graph and the navigation**, and deliberately nothing about
looks, wording or button order — stages 4–8 rewrite all of that, and a layout assertion
would break on each of those stages while proving nothing.

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

- **No car shop.** Decision 28 makes the shop the first screen carrying a decision for a
  new player; it is stage 6. Until then a profile with no cars is a dead end, and the `CAR`
  page says so rather than showing an empty list.
- **No boost, perk or stats pages.** Stages 5, 7 and 8.
- **No challenge entry point.** The Daily/Weekly/Monthly challenge is retained (decision
  15) and `RunSession` already drives it through `ChallengeRunMode`, but its flat screen is
  stage 4 — see `todo/roguelike-pivot.md` → *Salvaged from `hq_challenge.gd`* for the
  orchestration that screen must reproduce.
