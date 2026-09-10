# Hub Shell — the flat UI

**Source:** `scripts/hub_shell.gd` (`HubShell`), `hub.tscn` (the main scene — a bare
full-rect `Control` the shell builds pages under). Built on `MenuPage` + `MenuNav`
([menu-navigation.md](menu-navigation.md)).

**`MAIN`, `REGION`, `CAR`, `SHOP` and `SKILLS` present their choices as a
`CardCarousel`** ([card-carousel.md](card-carousel.md)) — a horizontal, side-scrolling
card list — rather than a vertical row-of-buttons list. `CHALLENGE`,
`STATS` and `SETTINGS` were left as plain rows (not in scope for that conversion; STATS
in particular is pure read-out with nothing to put on a card). Where this doc below
still describes a page's choices as "one row per X", read that as "one CARD per X" for
the five converted pages — the underlying data/eligibility logic every section describes
is unchanged, only the presentation moved.

**Tests:** `tests/headless/test_hub_shell.gd`

The game's main scene and **the only way into a run**. It replaces the diegetic 3D hub
(`hq.tscn`, 3527 lines, plus nine collaborator scripts) and the overworld, both deleted in
stage 2b of the roguelike pivot; decision 9 chose a flat 2D UI outright. See
`todo/roguelike-pivot.md`.

## Deliberately plain, and deliberately temporary

Stage 3's bar was *the loop runs start to finish*, not *the loop looks good*, and that bar
still holds — the shell is stacked pages of plain buttons, now nine of them rather than
four (stage 6 added `SHOP` in place, on this same script, rather than
spinning off a dedicated one; stage 7 added `SKILLS` and `STATS`; stage 9 added
`CHALLENGE`; `SETTINGS` was added afterwards — see below, it was missing entirely for a
while). A `DRIVETRAIN` / `DRIVETRAIN_CAR` pair sold drivetrain conversions here as a
permanent purchase for a time (decision 52); that is superseded — a conversion is now a
run-scoped mid-run upgrade offered in the between-stage pick instead
([region-runs.md](region-runs.md) → *Drivetrain conversion*), so the pair is deleted along
with the purchase path it sold. **Do not
invest in its looks, and do not grow it past what a plain button list can hold** — give a
future screen its own script if it needs anything richer than a row-of-buttons page. The
whole shell is still smaller than any single one of the nine hub scripts it replaced.

## The nine pages

`HubShell.View` — `MAIN`, `REGION`, `CAR`, `SUMMARY`, `SHOP`, `SKILLS`,
`STATS`, `CHALLENGE`, `SETTINGS`. One page is
live at a time; `_show(view)` frees the previous page's `CanvasLayer` before building the
next, so a stale page can never sit under the tree still claiming input.

| Page | Offers |
| --- | --- |
| `MAIN` | Money, **Resume run** (only when one is paused), New run, Shop, Skills, Rally challenge, Free play, Lifetime stats, Settings, Quit |
| `REGION` | Every region in AUTHORED order, marked when cleared; locked ones shown "Locked" with their pay rate (not the gate they hide behind) |
| `CAR` | Every owned car (selectable to start the run) PLUS every unowned `CarLibrary` car with a `Buy <name> — <cost>` row (decision 28) |
| `SUMMARY` | Stages cleared, money earned, per-stage times |
| `SHOP` | ONE flat card list: every `BoostLibrary.CATALOGUE` id, shown as a 1-based current level (`Save.boost_level` storage is 0-based; the card displays `stored + 1`, so a never-upgraded boost reads "Lv 1"), what the boost actually does to the car at that level (`BoostLibrary.current_effect_text_for`, e.g. `-7%` — derived from the RESOLVED MAGNITUDE, never from how far the level pushed it, which reads as `+0%` on every un-upgraded boost; a `set`/`add` effect with no baseline to be a percentage of shows an absolute figure with its authored unit instead, e.g. `0.12 s`), and the price of the next level — no total rung count and no "how much the next level gives" shown — engine swap included, now that it is a boost — no sub-page hop |
| `SKILLS` | One row per `SkillLibrary.all()` entry — locked (naming its gate), Buy, or Equip/Unequip ([skills.md](skills.md)) |
| `STATS` | The lifetime ledger, one row per `LifetimeStats` id ([lifetime-stats.md](lifetime-stats.md)) |
| `CHALLENGE` | The three periods, one row each — stage count + rating cap; a period already run is shown and unfocusable ([rally-challenge.md](rally-challenge.md)) |
| `SETTINGS` | The shared `SettingsMenu` ([menus.md](menus.md) → *Account page*) — audio, display, camera, gearbox, key bindings, mobile controls, account/cloud save, Reset progress |
| `FREEPLAY_CAR` / `FREEPLAY_REGION` / `FREEPLAY_SETUP` | The Free Play sandbox flow — see below |

**`SETTINGS` was missing entirely for a while**: the diegetic HQ used to offer it, the
pivot's flat rebuild never added an equivalent row, and the only surviving route was
`pause_menu.gd`'s in-run overlay — unreachable for a player with no run in progress
(a fresh profile, or one sitting at the hub between runs). The hub's `MAIN` page now
mounts the same `SettingsMenu` instance the pause menu does, so both hosts present
identical options (per that script's own header comment) and neither route can drift.

`_back()` (Esc / gamepad B) walks `CAR → REGION → MAIN`,
`SKILLS`/`STATS`/`CHALLENGE → MAIN`, `FREEPLAY_SETUP → FREEPLAY_REGION →
FREEPLAY_CAR → MAIN`, and `SETTINGS → MAIN` (via `_settings_back()`, which
gives `SettingsMenu.go_back()` first refusal — its own sub-pages, and the Account page's
sign-in sub-forms in turn, back out one level at a time before the shell backs out to
`MAIN`; the same "first refusal" shape `pause_menu.gd::_on_settings_back` uses).
**The `CAR` page serves two flows**, so its back destination is conditional: `CHALLENGE`
when `_pending_challenge` is set, `REGION` otherwise — in `_back()` AND on the page's own
Back button, which is a thing to get wrong once and only once (a test pins both).
`MAIN` and `SUMMARY` are roots and absorb Back rather than dropping the player into a page
they never opened.

Drivetrain conversions are the sixth money sink and hang off `SHOP`, per-car rather than
as a global unlock — buying AWD on one car says nothing about another, because the
conversion is a physical change to that car. Buying and RUNNING a layout are separate
steps (the same split skills use): a bought layout becomes a free switch, since you buy the
hardware once and then run whichever you like. See [region-runs.md](region-runs.md) →
*The meta tier*.

Car BUYING lives on the `CAR` page rather than a `SHOP` sub-page, per decision 28's own
wording ("the car select screen offers a Buy action for unowned cars") — one list serves
both picking and buying, since a player looking at "which car" is already looking at
exactly the list a shop would show. Boost levels are different:
permanent purchases with no tie to picking a car for THIS run, so they hang off `MAIN`
instead. See [region-runs.md](region-runs.md) → *The meta tier* for what each purchase
actually does.

## Navigation is a hard requirement, not a nicety

`CLAUDE.md` requires **every** menu in the game to be keyboard + gamepad navigable, and a
new menu to ship with a nav test in the same piece of work. Every page here goes through
`MenuNav.attach`. On a still-row-based page, every body row is a `Button` rather than a
`Label` **because `MenuNav` only walks focusable controls** — a label row would be
invisible to the keyboard and silently break the contract. On the five carousel pages
(`MAIN`/`REGION`/`CAR`/`SHOP`/`SKILLS`), the `CardCarousel` itself is the one focusable
unit MenuNav lands on instead — it sets its own `FOCUS_ALL`, so MenuNav needs no special
case for it (see [card-carousel.md](card-carousel.md)). `test_hub_shell.gd` walks all nine
views and asserts each has a `MenuNav` and at least one focusable control (a carousel
counts as one) — including `SHOP` even when every purchasable card
on it is disabled (unaffordable or at its level cap): `Back` is always a live `_action`,
so the assertion holds regardless of the player's money.

The test file pins the **screen graph and the navigation**, and deliberately nothing about
looks, wording or button order — stages 7–8 still rewrite parts of it, and a layout
assertion would break on those while proving nothing.

## Locked regions are shown, not hidden

Regions unlock linearly: region `order` 0 is always open, every other is gated on the one
before it being in `Save.KEY_REGIONS_CLEARED`. The page lists them via
`RegionLibrary.ordered()` — **never array position**, which that table's header states
carries no meaning.

A locked region stays on the page, named, marked "Locked — pays $N/stage" — deliberately
NOT naming the gate it hides behind (the gate region's own card, a swipe away, answers
that better than a second-hand name does). Hiding it leaves a new player with one row and
no idea the game continues; showing it unpressable with no explanation is worse. Its button is `disabled` **and carries the `menu_nav_skip` meta** —
that meta is the framework's own opt-out, and it is required rather than optional:
`MenuNav.attach` runs *after* the page is built and re-enables focus on every `BaseButton`
it finds, so setting `focus_mode` alone is silently undone and the keyboard lands on a dead
row.

## Free play — the session-less sandbox

Three carousel pages off MAIN (`_build_freeplay_car` → `_build_freeplay_region` →
`_build_freeplay_setup`): ANY catalogue car (unowned cars are lent, not bought), ANY
region (the unlock gate is a progression rule for runs; a sandbox has none), and any
combination of the `BoostLibrary` catalogue as toggle cards. Start writes a plan to
`FreePlay` (`scripts/free_play.gd`) and boots the run scene — whose session-less
branch consumes it: `world.gd::_field_free_play_car` fields the chosen car with the
chosen boosts (plus equipped skills) on the same effects funnel a run's car rides,
and generation uses the plan's stage dict (`FreePlay.event()`). No clock, no run
state, nothing persisted — the car is unbound, so damage never touches the save, and
the finish panel's Next returns to the hub through the existing no-session branch.
`RunSession.start`/`start_region`/`resume` clear the plan so a real run never
inherits it.

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

### MAIN rebuilds when the cloud pull lands

The Resume card is decided from `Save.profile` at the moment `_build_main` runs — but on a
signed-in device the boot pull is **asynchronous** (`Cloud._kick_off_initial_pull` →
`CloudSync.apply_remote` → `profile_replaced`), so the cloud's copy of the profile can
arrive *after* MAIN has already been built. `_ready` therefore connects
`Cloud.profile_replaced` to `_on_profile_replaced`, which re-shows `MAIN` if that is the
live view. Without it a run paused on another device (or before a re-install) showed no
Resume card on first load and only appeared once the player navigated away and back. Other
views are deliberately left alone — the player is mid-interaction on them, and each re-reads
the profile the next time it is opened.

## Known gaps, by design

- **The challenge screen is MINIMAL, deliberately.** `CHALLENGE` names each period, its
  stage count and its rating cap, and hands off to the shared `CAR` page. It shows no cloud
  leaderboard, no standing, and no explanation of the placement reward — `hq_challenge.gd`
  did all three and is deleted. See `todo/roguelike-pivot.md` → *Salvaged from
  `hq_challenge.gd`* for the orchestration a full screen would reproduce.
- **The Engine Swap is a mid-run boost pick now** (BoostLibrary `"engine_swap"`,
  the catalogue's POWER entry); the old one-time SHOP unlock and its gate are
  deleted — see [engine-swap.md](engine-swap.md).
