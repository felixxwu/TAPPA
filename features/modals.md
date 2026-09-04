# Modals and confirms

**Sources:** `scripts/confirm_popup.gd` (`class_name ConfirmPopup` — the shared confirm
dialog and the tree-wide `MODAL_GROUP` that keeps one modal at a time), `scripts/menu_page.gd`
(`class_name MenuPage` — `open_modal`, the scrolled-body / pinned-exit page shape), and
`scripts/hq.gd::_make_modal_overlay`.

**Tests:** `tests/headless/test_menu_page.gd`, `tests/headless/test_menu_flow.gd`, `tests/headless/test_menu_nav.gd`

Anything that takes over the screen and must be dismissed before the player can carry on.
A modal is also a menu, so it must be keyboard + gamepad navigable — see
[menu-navigation.md](menu-navigation.md), and note `MenuNav.input_blocked(node)`, the one
"am I deaf right now?" question a screen behind a modal needs to ask.

## ConfirmPopup (`confirm_popup.gd`)

A reusable on-brand confirm modal for blocking decisions — a full-screen **dim
mouse-consuming backdrop** (`MOUSE_FILTER_STOP`, swallows clicks) + **centred house
`UITheme.panel`** with a title, an autowrap body, and one button per action. Each action is
a dict `{ "label": String, "callback": Callable, "disabled": bool (optional) }`. When an
action's button is pressed, the popup dismisses and runs its callback; Back routes to the
configured action (default: the **first** one — dismiss/leave sits leftmost, see
"Button order" above).

**Contract:** `ConfirmPopup.open(host, title, body, actions, default_index := 0, back_index := -1, allow_stack := false) -> ConfirmPopup` — **returns `null` when refused; callers must not assume a popup came back.**

- `host` — parent Node to attach under (its process mode is inherited — a paused host's
  popup still processes).
- `title` / `body` — confirm header + message text.
- `actions` — Array of action dicts; disabled actions are greyed and unselectable.
- `default_index` — 0-based index to focus on open (defaults to 0, falls back to first
  enabled if the default is disabled).
- `back_index` — 0-based index of the action to fire on Back / cancel. **Defaults to the
  FIRST action**, because the house order puts the leaving/cancel action leftmost (it used
  to default to the last, which after that reorder pointed Esc at the *confirming* button —
  see the comment in `ConfirmPopup.open`). Pass an explicit index to override; a negative
  one is replaced by the default rather than dismissing silently.

The popup **builds its own CanvasLayer** under `host` (layer 101, above overlays), so it's
independent of the hosting scene. It's **MenuNav-wired** (keyboard + gamepad navigable),
emits `finished`, and **`queue_free`s on dismiss** — the host doesn't track it. **New
confirm dialogs should use `ConfirmPopup.open()` instead of Godot's native
`ConfirmationDialog`**, which is unstyled and not `MenuNav`-wired. Examples: the **pause
menu quit-to-HQ confirm** (`PauseMenu`), HQ **engine-swap confirms** (`hq.gd::_show_swap_confirm`, which is just two branches now
— capability locked, or go ahead — since a permitted swap costs nothing to spend), HQ **detune-to-enter confirm** (over-powered car), and the HQ **"Update available" prompt** on the native builds (`hq.gd::_check_for_update` — see [update-check.md](update-check.md)).

**Body scrolls, buttons stay pinned.** A ConfirmPopup has no touch dismissal other than its
own action buttons (`trigger_back` is reachable only from `ui_cancel`/`menu_back` — Escape
or gamepad B) and its dim backdrop swallows taps, so a long caller-supplied body (server
error text via `cloud_busy.gd::report_failure`, a computed multi-line reward via
`world.gd`) must never be able to push the buttons past reach. `_build` wraps the body
`Label` in a `TouchScrollContainer` (`scripts/touch_scroll_container.gd`, `horizontal_scroll_mode
= SCROLL_MODE_DISABLED`); the button row stays a sibling OUTSIDE the scroll so focus never
has to enter it. Because a `ScrollContainer` doesn't report its child's minimum size on an
axis it's allowed to scroll (that's what makes clipping work — vertical here defaults to
`AUTO`), an untouched scroll would collapse to ~0 tall and never hug a short body either.
So `_build` hands the sizing to **`UITheme.fit_body_scroll(scroll, body_label, wrap_width)`**
(see `features/ui-design-system.md` → "Sizing a scrolled body"), which gives the scroll the
body's true wrapped height and caps it against the viewport only as a fallback. **In practice
nothing scrolls**: these popups are fullscreen and their bodies are short, so the panel hugs
the text and all of it is visible. The panel width is likewise adaptive: `clampf(420.0,
200.0, viewport_width - 32.0)` instead of a bare `420` — on a narrow/portrait device
(`DisplayStretch`) the logical width can be well under 420.
`scripts/username_popup.gd` shares this exact shape and calls the same
`UITheme.fit_body_scroll` — keep the two in sync if this changes.

### One modal at a time (`ConfirmPopup.MODAL_GROUP`)

Every modal in the game is a `ConfirmPopup` or a `UsernamePopup`, both on layer 101,
and both join the scene-tree group **`"modal"`** when built. `ConfirmPopup.open` and
`UsernamePopup.open` refuse (return `null`, with a `push_warning`) when
`ConfirmPopup.any_open(tree)` reports one already on screen. `allow_stack := true`
opts out — used only by `CloudBusy.report_failure`, because a silently dropped
"couldn't sync" is how a failed resolution becomes invisible. There is deliberately
**no queue**: re-showing a modal the player has moved past invents an ordering nobody
asked for.

`any_open` skips nodes that are `is_queued_for_deletion()`. A dismissed popup emits
`finished` and *then* `queue_free`s, and a freed node stays in its groups until the
end of the frame — without the skip, a host that re-checks from its own `finished`
handler (`account_menu.rebuild` does exactly this) would be refused by the very popup
that just closed.

**The rule this encodes, worth generalising:** *a shared helper whose correctness
depends on "how many of these exist right now" must answer that from a scene-tree
group it owns — never from a per-host bool.* Centralising **what** a helper does while
leaving each caller to track **whether** it is already doing it is only half a
consolidation, and the half that is left behind is the half that drifts. This has now
been arrived at independently three times: `"loading_screen"` (queried by
`music_director.gd`), `CloudBusy.GROUP`, and this group. The bug that forced it: one
`Cloud.conflict_detected` broadcast reached two subscribers, each checking its own
private latch, so **both** opened a conflict prompt — dismissing the top one appeared
to "do nothing" except reveal a twin with the focus cursor reset. `hq.gd` and
`account_menu.gd` no longer keep modal latches at all; `account_menu` in particular
can be instantiated three times over (Settings, the HQ title overlay, the standings
page), so a per-instance bool could never have answered the question.

#### Commit AFTER you have the screen (`ConfirmPopup.open_committing`)

Because `open` can be **refused**, *an irreversible mutation must never run before the
presentation that reports it.* Doing it the other way round is a silent data loss:
the rule was learned the hard way by a since-deleted consumable flow that *consumed the
item, installed the part and saved* and only **then** opened the reveal — so a player
holding two of them spent both and saw one reveal, the second popup having been refused
behind the first. The mechanism is gone; the ordering rule it taught is not.

`ConfirmPopup.open_committing(host, title, placeholder, actions, commit, …)` inverts
the order so that state is unrepresentable: it **acquires the modal slot first**, and
runs `commit` only once the popup that will report the result is already on screen. If
the slot cannot be had it returns `null` and **`commit` is never called** — the caller
has mutated nothing and can just return.

The body is **deferred**, not a return value, because `world.gd`'s challenge reward has
to `await` its grant (`ChallengeRunMode.try_grant_completion_reward`) and a synchronous
`Callable -> String` contract cannot express that. So the popup is built with
`placeholder`; `commit` may be a plain function *or* a coroutine (its result is awaited
either way), and either returns a non-empty `String` to become the body or writes one
itself via `popup.set_body(...)` on the popup it is handed. `open_committing` is
therefore itself a coroutine — call it as `await ConfirmPopup.open_committing(...)`.
There is deliberately no `allow_stack` here: the refusal *is* the feature.

Covered by `test_confirm_popup.gd` — the commit does not run when a modal is already
up, does run (once) when the slot is free, a coroutine commit is awaited, `set_body`
fills the placeholder, and the popup it returns behaves like any other (buttons, Back,
dismissal).

#### `MenuNav.input_blocked(node)` — the one "am I deaf right now?" question

Every menu host needs to know whether to ignore menu input, for two reasons that used
to be asked separately (or not at all): the player is **typing**
(`MenuNav.is_text_editing`), and **a modal owns the screen** (`ConfirmPopup.any_open`).
`MenuNav.input_blocked(node)` folds both into one shared predicate, the same convention
`is_text_editing` established. `hq.gd`'s `_unhandled_input` had rolled its own version
that allowlisted its two overlays but not `ConfirmPopup`, so HQ station rows still fired
behind an open popup — which is exactly what made the double-open reachable.

**The carve-out: a node inside the open modal is NOT blocked.** The popup builds a
`MenuNav` of its own on its centring container (`ConfirmPopup._build`), and that nav has
to keep answering Back and directional nav — block it and the player is trapped in a
popup that no longer responds to anything. So the modal blocks everyone *except its own
subtree* (`node == modal or modal.is_ancestor_of(node)`), and the carve-out is tested
before the text-editing arm so a field inside a modal (`UsernamePopup`) keeps its own
typing rules.

`MenuNav._unhandled_input` applies the guard itself, so every MenuNav-driven page
(settings, upgrades, standings, account, the HQ overlays) goes inert behind a modal
rather than relying on tree ordering to mask it — tree ordering is not a rule, and it
never covered `menu_select` at all.

Covered by `test_menu_nav.gd` — blocked behind a modal, not blocked with nothing up,
blocked while typing, **not** blocked inside the open modal, a MenuNav page neither
moves its cursor nor fires Back behind a modal, and the modal's own nav still answers
Back.

Covered by `test_confirm_popup.gd` — joins the group, a second popup is refused, a
*different host* is refused, a popup being freed does not block its replacement,
`allow_stack` gets through, and the exclusivity holds in both directions between the
two popup kinds.

## Modal page shape — scrolled body, pinned exit (`hq.gd::_make_modal_overlay`)

**Every modal menu page must scroll its content and pin its exit control outside the
scroll.** `hq.gd::_make_modal_overlay(margin)` is the builder: it returns
`[layer, body, footer, root]` — `body` is a `VBoxContainer` inside a
`TouchScrollContainer` (`SIZE_EXPAND_FILL`), `footer` is an `HBoxContainer` pinned
below it as a sibling, and `root` is the outer full-rect VBox you hand to
`MenuNav.attach` / `UITheme.enforce`. Variable-height content goes in `body`; the
control that LEAVES the page (Back / Done / Close / "Continue") goes in `footer`.
`hq_carpark.gd::_make_carpark_modal(build_body, build_footer)` is the same contract for the
car-park's centred house panel. It is now a thin wrapper over `MenuPage`
(`{"dim": true, "margin": 16.0, "padding": 20}`) rather than a hand-rolled stack: `MenuPage`
gained a **`dim`** option for true modals like this one, and its `_sync_body_height` already
budgets the box against the frame height instead of centring it at its full minimum size —
which is what stops a tall body pushing the footer off screen. Note the footer callable is
handed an **`HBoxContainer`** (the page's action row, outside the box), not a `VBoxContainer`.

### Hosting a modal (`MenuPage.open_modal`) — not optional either

**A modal page never goes on a station's `CanvasLayer`.** `MenuPage.open_modal(host, opts)`
is the one way to put a full-screen page on screen; it owns three things callers kept getting
wrong, each with a silent failure mode:

1. **Its own `CanvasLayer`.** `WorldPanelHost.sync` migrates a station's UI tree into a 3D
   `WorldPanel` and sets `flat_layer.visible = false` whenever `world_space_menus` is on —
   which `game_config.tres` **ships on**. A page added to `_car_layer` was built, gated and
   nav-wired but rendered NOWHERE: "Change Upgrades" on the car park's "Too powerful" prompt
   looked like it dropped the player straight back to car-select.
2. **`MenuPage.MODAL_LAYER` (100) — above the station overlays, strictly below
   `ConfirmPopup`'s 101.** A modal page HOSTS confirms rather than being one. On a tie the confirm can be drawn *under* the page's
   opaque panel while its full-screen `MOUSE_FILTER_STOP` dim goes on swallowing clicks — an
   invisible confirm behind a menu that has gone dead.
3. **A screen claim via `MenuNav.SCREEN_CLAIMER_GROUP`.** `WorldPanel._input` projects clicks
   landing inside its 3D quad into the panel's `SubViewport` and marks them handled, standing
   down only for `MenuNav.input_blocked`. A page outside that predicate renders on top while
   the station underneath eats its clicks. It is deliberately NOT `ConfirmPopup.MODAL_GROUP`
   (see "One modal at a time") — that group *refuses* a second modal, and these pages must be
   allowed to open the confirms they host. Membership sits on the page, not its layer, so
   hiding the page releases the claim (hosts keep these pages alive and toggle `visible`).

`hq.gd::_make_modal_overlay` and `hq_carpark.gd::_make_carpark_modal` are both thin wrappers
over it now, so all three HQ modals (rally detail, challenge, Android notice) get the same
hosting. The **Android boot notice** additionally stands the title down through
`update_overlays` — `_title_layer.visible = false` only ever addressed the flat host, so
with world menus on it stood nothing down and left two live `MenuNav`s fighting one keypress.

**Why it isn't optional.** Overlays are laid out against a logical canvas whose HEIGHT is
fixed — `DisplayStretch.DESIGN_HEIGHT`, read from `project.godot`'s
`window/size/viewport_height` (currently 400) on every target — while the WIDTH follows the device aspect
(`DisplayStretch.logical_size`) and gets narrow on a phone, which makes autowrapped
labels wrap to more lines. So a fixed, unscrolled column whose Back button is laid out
AFTER the content does not overflow by device roulette: with a long restriction string or
a server error string spliced in, the exit is *deterministically* pushed off the bottom.
And there is no second way out — `menu_back` binds Escape and gamepad B only
(`project.godot`), so there is NO touch-reachable back and the player is simply trapped
in the page. Pinning makes that unreachable-by-construction.

**Focus still crosses into the footer.** Footer controls are `FOCUS_ALL`; `MenuNav` moves
focus across container boundaries by geometry, so down-nav off the last body row lands on
the footer, and `MenuNav._enable_scroll_follow` sets `follow_focus = true` on every
`ScrollContainer` under the attached root so walking back up scrolls the body to reveal
the row the cursor moved onto. `build_settings_overlay` (title → scroll → `< Back`
sibling) and `build_lift_overlay` are the reference implementations.

**The passthrough carve-out.** This is for MODAL pages only. The diegetic 3D stations —
garage, map table, car park (`build_garage_overlay`, `build_table_overlay`,
`build_car_overlay`) — call `hq.gd::_passthrough_overlay`, which sets
`MOUSE_FILTER_IGNORE` on the overlay root and its non-button children so taps fall through
to the `Area3D` pickers behind the HUD. A `ScrollContainer` defaults to
`MOUSE_FILTER_STOP` and would eat those picks (and its drag gesture would fight the map
pan). Plain `_make_overlay` stays as-is for those; **never** wrap a passthrough overlay in
`_make_modal_overlay`.

Pages on this shape: the rally detail card (`rally_detail.gd::RallyDetail.build` — its
`< Map` stays `FOCUS_NONE` because the panel has no MenuNav; in `hq.tscn` the
`hq_table.gd::handle_input` branch drives it from the TABLE view), the challenge entry screen (`build_challenge_overlay`), Settings
(`build_settings_overlay`), the Android
app notice (`hq._show_android_app_notice`), and the car-park Change-Upgrades popup
(`hq_carpark.gd::_show_upgrades_popup`, whose Done is additionally p/w-gated).

**Widths, not just heights.** A centred modal column asking for a fixed pixel width can
also exceed the frame: a narrow/portrait phone aspect can leave well under 445 logical units wide.
`RallyDetail.body_width(host, preferred, chrome)` clamps an authored desktop width to what the
current canvas can actually show (`viewport width - chrome`, floored at 160);
`hq.gd::_modal_body_width` is the HQ-hosted wrapper over it, and the upgrades popup and the
account menu both go through that.

