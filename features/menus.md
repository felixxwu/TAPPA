# Menus & game-loop shell

**Sources:** the hub-scene routing seam in `scripts/scenes.gd` (`class_name Scenes` —
`hub_path()` / `is_hub_scene()`, the path consts `HUB`/`MAIN`/`CAR`, and the
`car_scene()` cached-load accessor, the ONE place `"res://car.tscn"` is spelled in
production code; `preload(Scenes.CAR)` does not compile in GDScript 4.6, which is why
callers use `Scenes.car_scene()`), the flat shell in `scripts/hub_shell.gd`
(`class_name HubShell`), the in-run pause overlay in `scripts/pause_menu.gd`
(`class_name PauseMenu`), the shared settings page in `scripts/settings_menu.gd`, the
text input in `scripts/text_field.gd`, the cloud-save form in `scripts/account_menu.gd`,
the rally-detail panel in `scripts/rally_detail.gd`, and the session-aware fielding in
`scripts/world.gd`.

**Tests:** `tests/headless/test_menu_nav.gd`, `tests/headless/test_menu_page.gd`,
`tests/headless/test_pause_menu.gd`, `tests/headless/test_settings_menu.gd`,
`tests/headless/test_text_field.gd`, `tests/headless/test_hub_shell.gd`

**This file is the SHELL — the routing, the house rules and the screens that are not
part of the hub.** The hub's own pages are [hub-shell.md](hub-shell.md); the navigation
framework is [menu-navigation.md](menu-navigation.md); modals are
[modals.md](modals.md). This file does not duplicate them.

## What this file used to be

Everything here described the **diegetic 3D hub**: `hq.tscn` + `hq.gd`
(`HqController`, ~4,700 lines) and its eight collaborator scripts (`hq_overlays.gd`,
`hq_challenge.gd`, `hq_table.gd`, `hq_map_table.gd`, `hq_carpark.gd`,
`hq_tuning_lift.gd`, `hq_present_reveal.gd`, `hq_environment.gd`), the overworld, the
3D map table with its new-rally reveal parade, the car park, `podium.tscn` and
`standings.tscn`. **All of it is deleted** — decision 9 chose a flat 2D UI outright, and
stage 2b of `todo/roguelike-pivot-plan.md` removed the scenes and their 29 collaborator
scripts; decisions 19 and 30 took the podium and the standings interstitial.

Do not go looking for a "hub station", a `CarparkMode`, a camera pose, or an
`hq.gd::_unhandled_input` spatial input branch. Every menu is a flat `MenuPage` now.

## The loop

```
hub.tscn (HubShell)
  ├─ New run ─▶ region select ─▶ car select ─▶ RunSession.start_region
  ├─ Rally challenge ─▶ period ─▶ car select ─▶ RunSession.start
  ├─ Shop / Perks / Lifetime stats            (all flat pages on the same script)
  └─ Resume run ─▶ RunSession.resume
       └─ main.tscn (one stage) ─ start line ─▶ countdown ─▶ RUN
            ├─ StageManager.stage_completed ─▶ RunSession.report_event_result
            │     ├─ cleared, more stages ─▶ between-stage pick ─▶ next stage
            │     └─ cleared the last / missed the target ─▶ run over
            └─ pause menu ─ Quit to HQ ─▶ the run is PAUSED, back to hub.tscn
       └─ (on run end) hub.tscn opens on its SUMMARY page
```

There is **no branch out of the run for damage**: HP bottoms out at 0 and the car keeps
driving under a capped misfire and rev limit, so every stage the player enters reaches
its own end ([damage.md](damage.md)). Missing the target time is the only fail state
([region-runs.md](region-runs.md)).

## Button order — leaving is left, proceeding is right

**In any row of buttons: the action that LEAVES (Back / Exit / Cancel / Quit / Decide
later) is leftmost, and the action that PROCEEDS (Start / Enter / Confirm / Drive) is
rightmost.** Everything else sits between them. This is a house rule, not a per-screen
choice — apply it to every new row without asking.

Reference rows: `start_line.gd::_build_overlay`, `pause_menu.gd`'s Resume / Settings /
Quit column, and every `HubShell` page (its body rows are the choices; `Back` is an
`_action`, and actions render after the body).

**Two traps when reordering an existing row:**

1. **`ConfirmPopup.open`'s `default_index` and `back_index` are POSITIONAL.** Reversing
   the `actions` array without updating them silently changes which button is focused
   and which one Esc / gamepad-B fires. `back_index` now defaults to the **first**
   action (it used to be the last, correct only while dismiss sat on the right) — get
   this wrong and Escape abandons a rally or overwrites a career. Single-action popups
   are unaffected: first and last are the same button.
2. **Cursor seat indices are not constants.** `ButtonCursor` rows seat the cursor by
   index, and a row can have CONDITIONAL members — "Exit Game" is skipped on web, and
   `HubShell`'s MAIN page shows "Resume run" only when a run is paused — so "the
   proceeding action is last" can be a different index per platform and per profile
   state. Compute it rather than hardcoding, and have tests assert by button IDENTITY
   rather than by literal index (`test_hub_shell.gd` presses by TEXT for the same
   reason). The two `hq.gd` helpers this rule used to cite as the worked example
   (`_title_start_index`, `_garage_career_index`) are deleted; the rule outlived them.

**Vertical columns are a separate convention and are deliberately NOT changed by this
rule:** they put the exit at the BOTTOM (last) — see `pause_menu.gd::_build_menu_panel`
(`Resume / Reset to track / Settings / Quit to HQ`), `account_menu.gd::_build_email_form`
and the `< Back` at the foot of every scrolled modal page. That is consistent across the
game; treat any change to it as its own decision.

## Menu navigation (keyboard / gamepad)

**Moved to [menu-navigation.md](menu-navigation.md).** The `MenuNav` framework — focus,
WASD/arrow/gamepad movement, back routing, remembering the selected row — is a framework
rather than a screen, so it has its own area doc. Every menu in the game is navigable by
keyboard and gamepad (CLAUDE.md requires it); how that works lives there. The
diegetic-HQ input regime that doc used to carry a second half for is deleted.

## The new-rally reveal is DELETED

The map-table reveal parade (`hq_table.gd::_run_reveal_sequence` — pan to each newly
enterable rally, flip its pin, banner it) went with the 3D map table. Its persistence
half SURVIVES: `Save._seed_reveals_if_needed` and the per-rally `revealed` flag are
still written (see [save-persistence.md](save-persistence.md)), because a flat
"here is what just opened up" beat may still want them — but nothing reads them for a
reveal today, and the roguelike's regions unlock linearly on a rule the region page
simply prints ([hub-shell.md](hub-shell.md)).

## Text input (`text_field.gd`)

`TextField` is the project's **only** text input (there was none at all before
the account form — see [cloud-save.md](cloud-save.md)). A labelled `LineEdit`,
built in code like every other menu widget. Making typing coexist with a menu
driven by bare letter keys took four things:

- **`MenuNav._make_focusable` now walks `LineEdit` too**, not just `BaseButton`
  and `Slider` — otherwise a form is unreachable without a mouse.
- **Up/down leave the field, left/right stay caret movement.**
  `TextField.wire_column([...])` chains a form's controls explicitly (top and
  bottom do not wrap — wrapping reads as the cursor teleporting) rather than
  relying on Godot's automatic neighbour search.
- **WASD is safe by construction**: a focused `LineEdit` consumes printable keys
  in the GUI phase, before `_unhandled_input`. **Esc is not**, so
  `MenuNav._unhandled_input` turns Back-while-typing into "release the field"
  instead of "leave the page", and any host with its own `_unhandled_input` stands down
  via the shared **`MenuNav.is_text_editing()`** static. One predicate, so those guards
  cannot drift apart. (The host that motivated it was `hq.gd`'s spatial input branch,
  now deleted — no flat page has an `_unhandled_input` of its own — but the static is
  the contract for the next one that does.)
- **Enter submits** (`submitted` signal) — on a phone the on-screen keyboard can
  cover the button, so this is sometimes the only way to submit at all.
  `virtual_keyboard_enabled` is on for Android/web.

Note that **Space is both `ui_accept` and a legal password character**; the
focused field consumes it first, so typing wins. That is correct, but it is the
thing to re-check by hand if the input map ever changes.

Covered by `tests/headless/test_text_field.gd`.

## Account page (`account_menu.gd`)

`AccountMenu` is the optional cloud-save UI — one builder with **two hosts**: a
category page inside Settings (`show_account`, the canonical route) and an inline
overlay raised by a host that needs a sign-in there and then. It has had two other hosts
in the past, both gone: a dedicated title-row Account button (removed as a duplicate of
the Settings page) and the standings page's sign-in prompt (deleted with
`global_standings.gd`). See [cloud-save.md](cloud-save.md).
It exposes `at_root()` / `go_back()` so its
hosts treat its sub-forms exactly like Settings sub-pages —
`SettingsMenu.go_back()` gives it first refusal before backing out of the page.
See [cloud-save.md](cloud-save.md).

## Modals and confirms

**Moved to [modals.md](modals.md).** `ConfirmPopup`, the one-modal-at-a-time group, the
scrolled-body/pinned-exit modal page shape, and `MenuPage.open_modal`.

## The hub

**See [hub-shell.md](hub-shell.md).** `HubShell` (`hub.tscn` + `scripts/hub_shell.gd`)
is the flat replacement for the diegetic HQ: eleven stacked `MenuPage` screens on one
script, smaller in total than any single one of the nine hub scripts it replaced. There
is no `features/hq.md` — the doc this section used to point at went with the code.

## Run-scene fielding (`world.gd`)

With a `RunSession` active, `world._ready` fields the player's OwnedCar through
`Car.apply_owned` (the CarLibrary baseline, then the effects funnel carrying the run's
picked boosts and the player's equipped perks, then tuning, then the damage bound from
the saved HP) instead of the default `apply_car(0)`, and wires this stage's
`StageManager.stage_completed` into `RunSession.report_event_result`. See
[region-runs.md](region-runs.md) and [perks.md](perks.md).

There is **no second exit** from the run: `world.gd` has no wreck screen and nothing
listens for a car reaching 0 HP, because nothing is signalled when it does. With no
session (a plain dev boot of `main.tscn`) the default car is fielded and none of this
runs — `main.tscn` stays independently runnable.

## Pause menu (`pause_menu.gd`)

A `PauseMenu` `CanvasLayer` (`scripts/pause_menu.gd`) in `main.tscn`, set to
`PROCESS_MODE_ALWAYS` so its UI keeps working while the tree is frozen. It owns a
**top-right Pause button** (always visible during gameplay; the HUD's version/timer
labels were shifted left to clear it) — a square button bearing a **proper drawn
pause glyph** (`PauseIcon`, `scripts/pause_icon.gd`: two sharp-cornered ink bars,
since the font has no ⏸ glyph) rather than a cramped `| |` string — that **freezes the
game** (`get_tree().paused = true`) and shows an overlay with **Resume**, **Reset to
track**, **Settings** and **Quit to HQ**.
Resume unfreezes and closes. **Reset to track** snaps the car **onto the centerline
beside its current position** — "the middle of the road, regardless of where the car
is right now" (`TrackProgress.manual_reset_pose()`, a fresh nearest-point query).
This is deliberately **not** `recovery_pose()` (which the off-track reset / stuck
watchdog use): that pose is pinned to the *furthest* offset reached and freezes the
moment the car stops banking progress, so a strayed car would reset to a stale point that's
no longer beside it — feeling like the button does nothing. It's also **not** the full
start-line reset (`Car._reset()` / `reset_to(_start_transform)`). This "Reset to track"
menu item is now the **only** player-facing way to reset — there is no direct reset
input any more (see [controls.md](controls.md)). The menu owns no car reference, so it
emits `reset_to_track_requested`; `world.gd` connects that in `_ready` and performs
the reset (`$Car.reset_to(_track_progress.manual_reset_pose())`, which zeroes motion
and suppresses the teleport's impact damage — free), then the menu `resume()`s so the
player drops straight back in. `reset_to()` does **not** trust a bare `global_transform`
write — that only sticks when done inside the physics step, so a reset fired from a menu
signal (outside the physics frame) or on a stuck, **sleeping** body was silently reverted
by the physics server next frame (the car looked like it never moved, while the `R` reset,
which runs inside `_physics_process`, always worked). Instead it wakes the body and
**queues** the pose; `car.gd::_integrate_forces` applies it via `state.transform` — the
authoritative physics-write point — so it lands regardless of when the reset was fired.
Settings shows the **shared `SettingsMenu`** (camera
angle + mobile controls, identical to the title-screen page), with a **◄ Back** to
the Resume/Settings menu. **Quit to HQ** pops a confirm and, on accept (`quit_to_hq`), unfreezes and
**PAUSES** the run (`RunSession.pause_run()`), then loads `Scenes.hub_path()` itself.
Nothing is abandoned and nothing DNFs: the run slot stays persisted and the hub offers
**Resume run**, so the confirm's wording says the run is saved and the current stage
starts over rather than claiming it is lost. Quitting a CHALLENGE must not spend its
period either, which is the same rule. `pause_run()` deliberately emits no
`run_finished` — `world.gd`'s handler would post a DNF to the cloud board on it — which
is why this function owns the transition itself. A benchmark run exits through
`Benchmark.exit_to_hq` so its config overrides are restored; with no session (a plain dev
boot of `main.tscn`) it just loads the hub. The `RallySession.abandon()` this used to
call is deleted with `RallySession` (decision 5). `ui_cancel` (Esc / gamepad B)
toggles the menu and backs out of Settings first; the gamepad **Start** button
(`pause` action) also opens it (open-only — it does not double as a menu "back"). A camera pick applies
**immediately** to the live `CameraManager` (wired via the `SettingsMenu.camera_changed`
signal → `CameraManager.set_mode`), so the angle changes the moment you choose it.
A **mobile-control** pick applies just as immediately to the live `MobileControls`
(the `SettingsMenu.scheme_changed` signal → `MobileControls.set_scheme`), so the
on-screen touch layout rebuilds the instant you choose it rather than only on the next
run.
The menu is **default-inert** (`_input_enabled` starts `false`, mirroring
`StageManager`'s `_armed` gate): the Pause button and `ui_cancel` do nothing until
`world.gd` calls `set_input_enabled(true)` **after world generation completes**. This
stops the player pausing *during* the awaited generation window (loading overlay up) —
opening the menu then would freeze the tree mid-build and allow quit/resume into a
half-built world. Covered by `tests/headless/test_pause_menu.gd`.

## The podium and the standings interstitial are DELETED

`podium.tscn` / `scripts/podium.gd` (the 3D reward sequence) and `standings.tscn` /
`scripts/standings.gd` / `scripts/global_standings.gd` (the between-event two-leaderboard
page) are gone — decisions 19 and 30. Rivals went with them (decision 5), so there is no
field left to rank. `HubShell`'s `SUMMARY` page replaces both: stages cleared, money
earned, per-stage times, for a run that ended either way
([hub-shell.md](hub-shell.md)).

The event-replay overlay MECHANISM survives (`ReplayRecorder` / `ReplayCamera` /
`car.gd`'s `replay_playback`) — only the flat page it used to render behind is deleted.
See [event-replay.md](event-replay.md).

## Start line (location 2)

The pre-event **start-line scene** — the diegetic **briefing** panel (rally, event
N/3, restriction, fielded car + HP bar) and the **pre-launch presence** cars — is
built inside the run scene before the countdown; the player launches it into the
`StageManager` countdown. See [start-line.md](start-line.md). Its Exit button raises the
same confirm the pause menu's Quit does (`PauseMenu.confirm_quit_to_hq` is public for
exactly that reason — the wording branches on run-vs-no-run and the quit branches on
benchmark/run/plain, and neither belongs in two places). The between-stage beat it used
to hand off to is the run pick now, not a standings page — see
[region-runs.md](region-runs.md).

## Tests

- `tests/headless/test_hub_shell.gd` — the hub's screen graph and the keyboard/gamepad
  contract on every one of its pages ([hub-shell.md](hub-shell.md)).
- `tests/headless/test_pause_menu.gd` — the Pause button freezes the game and opens the
  menu; Resume unfreezes; Settings exposes the shared `SettingsMenu` (camera + control
  rows); Quit to HQ leaves the run and unfreezes; picking a camera applies live to the
  `CameraManager` and persists.
- `tests/headless/test_menu_nav.gd` / `test_menu_page.gd` — the navigation framework and
  the page shape ([menu-navigation.md](menu-navigation.md), [modals.md](modals.md)).
- `tests/headless/test_text_field.gd` — the text input rules above.
- `tests/headless/test_settings_menu.gd` — the shared settings page.

`tests/headless/test_menu_flow.gd` was this file's biggest test and is **quarantined**:
it drives `hq.gd`, `hq_carpark.gd`, `GlobalStandings` and `RallySession`, none of which
exist, so it fails to parse and GUT skips it. Decision 47 says salvage rather than
delete — see [testing.md](testing.md).
