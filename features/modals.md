# Modals and confirms

**Sources:** `scripts/confirm_popup.gd` (`class_name ConfirmPopup` — the shared confirm
dialog and the tree-wide `MODAL_GROUP` that keeps one modal at a time), `scripts/menu_page.gd`
(`class_name MenuPage` — the scrolled-body / pinned-exit page shape).

**Tests:** `tests/headless/test_menu_page.gd`, `tests/headless/test_menu_nav.gd`, `tests/headless/test_confirm_popup.gd`

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
`ConfirmationDialog`**, which is unstyled and not `MenuNav`-wired. Examples: the **pause menu's
quit-to-title confirm** (`PauseMenu.confirm_quit_to_title`) and the **"Update available"
prompt** on the native builds (see [update-check.md](update-check.md)).

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

### One modal at a time (`ConfirmPopup.MODAL_GROUP`)

Every modal in the game is a `ConfirmPopup` on layer 101, and each joins the scene-tree group **`"modal"`** when built. `ConfirmPopup.open` refuses (return `null`, with a `push_warning`) when
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
to "do nothing" except reveal a twin with the focus cursor reset. No host keeps a modal
latch of its own any more; `account_menu` in particular could be instantiated three times
over (Settings, the HQ title overlay, the standings page — the latter two now deleted), so
a per-instance bool could never have answered the question.

#### Commit AFTER you have the screen

Because `open` can be **refused** (it returns `null`), *an irreversible mutation must
never run before the presentation that reports it.* A since-deleted consumable flow
consumed the item, installed the part and saved, and only **then** opened the reveal, so
a player holding two spent both and saw one reveal. Open the popup first, and mutate only
once it is non-null. (The `open_committing` helper that enforced this is deleted; no live
code reserves a modal slot around a transaction.)

#### `MenuNav.input_blocked(node)` — the one "am I deaf right now?" question

Every menu host needs to know whether to ignore menu input, for two reasons that used
to be asked separately (or not at all): the player is **typing**
(`MenuNav.is_text_editing`), and **a modal owns the screen** (`ConfirmPopup.any_open`).
`MenuNav.input_blocked(node)` folds both into one shared predicate, the same convention
`is_text_editing` established. It exists because a host that
allowlisted only its own overlays still fired rows behind an open popup — which is what made
the double-open above reachable. The predicate is the rule for any new host.

**The carve-out: a node inside the open modal is NOT blocked.** The popup builds a
`MenuNav` of its own on its centring container (`ConfirmPopup._build`), and that nav has
to keep answering Back and directional nav — block it and the player is trapped in a
popup that no longer responds to anything. So the modal blocks everyone *except its own
subtree* (`node == modal or modal.is_ancestor_of(node)`), and the carve-out is tested
before the text-editing arm so a field inside a modal keeps its own
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

## Modal page shape — scrolled body, pinned exit (`MenuPage`)

**Every modal menu page must scroll its content and pin its exit control outside the
scroll.** `MenuPage` is the builder and the only one left: `body()` is a `VBoxContainer`
inside a `TouchScrollContainer` (`SIZE_EXPAND_FILL`), the action row is an
`HBoxContainer` pinned below it as a sibling, and the page itself is what you hand to
`MenuNav.attach` / `UITheme.enforce`. Variable-height content goes in the body; the control
that LEAVES the page (Back / Done / Close / Continue) goes in the action row.
`_sync_body_height` budgets the box against the frame height instead of centring it at its
full minimum size — which is what stops a tall body pushing the action row off screen. The
`dim` option makes it a true modal.

Every page in the game is a `MenuPage`.

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

**The passthrough carve-out is gone with its stations.** The diegetic 3D stations (garage,
map table, car park) set `MOUSE_FILTER_IGNORE` on their overlay roots so taps fell through
to the `Area3D` pickers behind the HUD — a `ScrollContainer` defaults to
`MOUSE_FILTER_STOP` and would have eaten those picks. No screen in the flat shell sits over
a 3D picker, so nothing needs it. The rule it implies survives: **never wrap a
tap-through overlay in the modal page shape.** The in-run HUD is the one live surface with
that shape of concern ([hud.md](hud.md)).

Pages on this shape today: the title and rest-stop card pages, the pause menu's settings page and the account form.

**Widths, not just heights.** A centred modal column asking for a fixed pixel width can
also exceed the frame: a narrow/portrait phone aspect can leave well under 445 logical units wide.
`MenuPage.set_body_width(preferred)` takes a width the caller has already clamped to what
the current canvas can actually show.

