# Menus & game-loop shell

> **STALE — the diegetic 3D hub described below was DELETED.** Stage 2b of the
> roguelike pivot ([../todo/roguelike-pivot-plan.md](../todo/roguelike-pivot-plan.md))
> removed `hq.tscn`, `overworld.tscn` and their 29 collaborator scripts. `res://hub.tscn`
> is a bare placeholder Control until stage 3 builds the flat shell (title → car select →
> run) on `MenuPage` + `MenuNav.attach`; this doc is rewritten then. What below is still
> TRUE: the `Scenes` routing seam, `MenuPage`/`MenuNav`, `PauseMenu`, the modals, and
> `RallyDetail` — everything naming `HqController` or an `hq_*.gd` script is not.
>
> **ALSO DELETED, same wave:** `podium.tscn`/`scripts/podium.gd` and
> `standings.tscn`/`scripts/standings.gd`/`scripts/global_standings.gd` (decisions
> 19 and 30) — see their sections below, which are rewritten in place rather than
> just flagged. Every OTHER mention of "podium" or "standings" elsewhere in this
> file (the loop diagram, the Sources list, the Deferred/Tests sections) is now
> equally stale and NOT individually fixed here — this file's full rewrite is
> stage 3/9 work, not a demolition-wave patch.

**Sources:** `hq.tscn` + `scripts/hq.gd` (`class_name HqController`), the 2D
overlay/menu-layer builders in `scripts/hq_overlays.gd` (`class_name HqOverlays` —
the `build_*_overlay()` methods, split out of `hq.gd` to shrink it; each holds a
back-reference to the `HqController` and reaches into it for state + button
callbacks), the Rally Challenge screen in `scripts/hq_challenge.gd` (`class_name
HqChallenge`), the
map table's navigation in `scripts/hq_table.gd` (`class_name HqTable`) and its pin/fog layer in
`scripts/hq_map_table.gd` (`class_name HqMapTable`), the car park in
`scripts/hq_carpark.gd` (`class_name HqCarpark`), the tuning lift in
`scripts/hq_tuning_lift.gd` (`class_name HqTuningLift` — its `handle_input` is the LIFT branch
of `hq.gd::_unhandled_input`), the present-box car reveal in `scripts/hq_present_reveal.gd`
(`class_name HqPresentReveal`) — all of them the same shape as `HqOverlays`,
described below — the shared **rally-detail panel** in `scripts/rally_detail.gd` (`class_name
RallyDetail`, hosted by either hub rather than holding a back-reference), the hub-scene
routing seam in `scripts/scenes.gd` (`class_name Scenes` — `hub_path()` / `is_hub_scene()`,
plus the plain path consts `HUB`/`MAIN`/`PODIUM`/`STANDINGS`/`CAR` and the
`car_scene()` cached-load accessor — the ONE place "res://car.tscn" is spelled in
production code, the same seam as the other scene paths; `preload(Scenes.CAR)` does not
compile in GDScript 4.6 (preload needs a literal string constant), which is why the three
sites that used to `preload()` the car scene now call `Scenes.car_scene()` instead),
`podium.tscn` + `scripts/podium.gd`, plus the
session-aware fielding
in `scripts/world.gd`. See the full design in [../todo/menus.md](../todo/menus.md).

**Tests:** `tests/headless/test_menu_nav.gd`, `tests/headless/test_menu_flow.gd`, `tests/headless/test_menu_page.gd`, `tests/headless/test_pause_menu.gd`, `tests/headless/test_settings_menu.gd`

This is the **diegetic 3D build** of the menu shell: HQ is one continuous 3D space
the camera flies through (an exterior title shot, a garage interior, the map table,
and the outdoor car park) rather than flat overlay screens. It still closes the
whole meta-game loop — pick a rally on a 3D map, choose an eligible car in the car
park, run it, see the podium — and wires [rally-session.md](rally-session.md) into
the run scene. The podium + between-event standings are still flat scenes (the 3D
reward rig / podium are later refinements); remaining diegetic polish (tuning UI,
per-car paint, camera fly-throughs *between* far stations) is tracked in the
"Deferred (rest of the diegetic 3D build)" section below.

## The loop

```
exterior title ─Start─▶ garage ─tap table─▶ map table (pick rally pin) ─▶ rally detail ─Enter─▶ car park (pick eligible car) ─Start─▶ RallySession.start_rally ─▶ main.tscn (event 0) ─start line: briefing + presence ─launch─▶ countdown ─▶ RUN
   main.tscn ─StageManager.stage_completed─▶ report_event_result ─▶ standings.tscn (EVERY event pauses here) ─Continue─▶ next event
   final event's standings.tscn ─Continue─▶ continue_to_next_event resolves ─rally_finished─▶ podium.tscn ─Continue─▶ HQ
   (abandon) ─rally_finished─▶ podium.tscn or HQ

   there is NO branch out of the RUN for damage: HP bottoms out at 0 and the car keeps
   driving, so every rally the player enters reaches its standings screen.
```

## Button order — leaving is left, proceeding is right

**In any row of buttons: the action that LEAVES (Back / Exit / Cancel / Quit / Decide
later) is leftmost, and the action that PROCEEDS (Start / Enter / Confirm / Drive) is
rightmost.** Everything else sits between them. This is a house rule, not a per-screen
choice — apply it to every new row without asking.

Reference rows: `start_line.gd::_build_overlay` (`< Exit | Upgrades | Tune Car | Start`),
`hq_overlays.gd::build_title_overlay` (`Exit Game | Free Roam | Settings | Start`),
`hq.gd::_refresh_garage_row` (`< Back | Career | Garage | Online | Multiplayer` — a
fixed five),
`rally_detail.gd::RallyDetail.build` (`< Map | Enter Rally >`), `build_challenge_overlay`
(`< Back | Start`).

**Two traps when reordering an existing row:**

1. **`ConfirmPopup.open`'s `default_index` and `back_index` are POSITIONAL.** Reversing
   the `actions` array without updating them silently changes which button is focused
   and which one Esc / gamepad-B fires. `back_index` now defaults to the **first**
   action (it used to be the last, correct only while dismiss sat on the right) — get
   this wrong and Escape abandons a rally or overwrites a career. Single-action popups
   are unaffected: first and last are the same button.
2. **Cursor seat indices are not constants.** `ButtonCursor` rows seat the cursor by
   index, and some rows have CONDITIONAL members — "Exit Game" is skipped on web. So
   "the proceeding action is last" can be a different index per platform. Compute it
   (`hq.gd::_title_start_index`, `hq.gd::_garage_career_index`) rather than hardcoding,
   and have tests assert by button IDENTITY rather than by literal index. (The garage
   row is no longer one of the varying ones — its four stops are unconditional, so its
   focus chain is static — but keep asking `_garage_career_index` anyway: identity-based
   lookups survive the next reorder, literals don't.)

**Vertical columns are a separate convention and are deliberately NOT changed by this
rule:** they put the exit at the BOTTOM (last) — see `pause_menu.gd::_build_menu_panel`
(`Resume / Reset to track / Settings / Quit to HQ`), `account_menu.gd::_build_email_form`
and the `< Back` at the foot of every scrolled modal page. That is consistent across the
game; treat any change to it as its own decision.

## Menu navigation (keyboard / gamepad)

**Moved to [menu-navigation.md](menu-navigation.md).** The `MenuNav` framework — focus,
WASD/arrow/gamepad movement, back routing, remembering the selected row, and the diegetic-HQ
regime — is a framework rather than a screen, so it now has its own area doc. Every menu in this
file is navigable by keyboard and gamepad; how that works lives there.

## New-rally reveal (map table)

When rallies become enterable the player is **told**, rather than being left to notice
that a grey pin turned green. Opening the map table pans the camera to each new rally in
turn and flips its pin from the locked to the unlocked look.

- **Where.** `hq_table.gd._enter_table()`, before the usual `_focus_hardest_incomplete()`
  entry steer. There is no separate scene and no podium teaser — the map is the only
  place a reveal happens. The camera motion is the EXISTING map pan (`_pan_table_to` →
  `_move_camera_to`, `menu_camera_move_time`), not a second bespoke tween.
- **The queue** (`_pending_reveals()`) is derived **fresh on every map open from current
  state** — never hooked to rally completion. A rally is queued only when it is unlocked
  (`RallyLibrary.rally_revealed`), the player owns a car that can actually enter it
  (`_has_eligible_car` → `_entry_plan`, the same authoritative answer the green/grey pin
  flag uses), and it isn't already `Save.rally_revealed_seen`. That makes it a standing
  condition rather than an event, so it works for *any* unlock route: finishing a rally,
  buying a car, an engine swap that moves a car into a class, a cloud
  restore. A rally with no qualifying car is simply held back and appears later; nothing
  expires.
- **The sequence** (`_run_reveal_sequence`) builds the pending pins in their LOCKED look
  first (`_refresh_map_pins(hold_locked)`) so the flip is watchable, then per rally:
  pan → settle (`hq_reveal_pan_time`) → rebuild that pin unlocked, focus it, banner it
  ("NEW RALLY — <name>", or "SPECIAL EVENT UNLOCKED" and a doubled hold for a special)
  → hold (`hq_reveal_hold_time`). `hq_reveal_max_queue` caps one opening's parade (the
  dev "3-star everything" cheat opens the whole roster at once); the rest are banner'd as
  "+N more" and marked seen anyway. `_finish_reveals` marks every queued id seen, saves,
  and leaves selection on the **last revealed pin** — the player wants to look at the new
  thing, not be yanked back to `_focus_hardest_incomplete()`.
- **Controls are LOCKED for the parade (keyboard + gamepad + pointer).** `_revealing` is
  checked in the same three places `_detail_open` is: the `_process` glide,
  `_table_pan_input`, and the `View.TABLE` branch of `_unhandled_input` — plus
  `_on_pin_input`, so a pin can't be opened mid-parade. A press is **swallowed**
  (`set_input_as_handled`, so nothing underneath reacts) and otherwise does nothing.
  It used to SKIP the whole queue, and that was wrong: skipping ran `_finish_reveals`, which
  marks every queued rally seen, so one stray keypress permanently burned the
  "NEW RALLY - …" beat for up to `hq_reveal_max_queue` rallies — and the reveal is the only
  place the game announces a new rally. The parade is short (`hq_reveal_pan_time` +
  `hq_reveal_hold_time` each, a special holding double, capped at `hq_reveal_max_queue`), so
  it simply plays out. Guarded by
  `test_menu_flow.gd::test_a_press_during_the_reveal_cannot_cancel_it`. Leaving the map
  mid-parade (`go_to`) still banks the queue.
- **Persistence + backfill.** A per-rally `revealed` bool beside `completed`. The seeding
  itself lives entirely in `Save` (`Save._seed_reveals_if_needed`), run at the points a
  profile actually becomes live — `load_or_new` and `adopt_profile` — rather than as a
  call `hq.gd` has to remember to make at every scene/entry point that reaches the map or
  replaces the profile. Details (what it seeds, why the eligible-car clause is
  deliberately NOT part of it) are in [save-persistence.md](save-persistence.md).
- **Generation guard.** `_run_reveal_sequence` bumps `hq_table.gd::_reveal_token` and captures it as
  `token` before its first `await`; every abort check calls `_reveal_continue(token)`
  instead of a bare predicate. This stops a STALE coroutine — parked mid-`await` after a
  skip, then woken up next to a second sequence that started before it resumed — from
  going on to pan the camera / rebuild pins / `erase()` entries out of the new sequence's
  queue. `_reveal_active()` itself stays a pure predicate (see next point); `_reveal_continue`
  is what actually calls `_finish_reveals()` when the player left the map view mid-parade.
- **`_reveal_active()` is a pure predicate.** It used to also call `_finish_reveals()` (a
  disk save + pin rebuild) when the view had changed away from `TABLE` — a side effect
  hiding inside what read as a query. That abort step now lives in `_reveal_continue`,
  the only thing `_run_reveal_sequence` actually calls between its steps.
- **Headless.** `_enter_table` drains the queue instantly under `Platform.is_headless()`
  (marking everything seen, then opening the table normally focused) — the final state
  with none of the awaits, which would otherwise hang the suite. Skip the animation,
  never the decision.

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
  instead of "leave the page", and any host with its own `_unhandled_input`
  (`hq.gd`) stands down via the shared **`MenuNav.is_text_editing()`** static.
  One predicate, so those guards cannot drift apart.
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
overlay on the standings page's sign-in prompt (`global_standings.gd`). It used to
have a third, a dedicated title-row Account button with its own modal layer; that was
removed as a duplicate of the Settings page (see [cloud-save.md](cloud-save.md)).
It exposes `at_root()` / `go_back()` so its
hosts treat its sub-forms exactly like Settings sub-pages —
`SettingsMenu.go_back()` gives it first refusal before backing out of the page.
See [cloud-save.md](cloud-save.md).

## Modals and confirms

**Moved to [modals.md](modals.md).** `ConfirmPopup`, the one-modal-at-a-time group, the
scrolled-body/pinned-exit modal page shape, and `MenuPage.open_modal`.

## HQ — the garage hub

**Moved to [hq.md](hq.md).** The diegetic 3D HQ (`hq.gd`, ~4,700 lines) — its stations and
input branches, the two hubs and the boot redirect, the rally-detail panel, the map table,
the upgrades/tune lift, and the Android boot notice.

## Run-scene fielding (`world.gd`)

When a `RallySession` is active, `world._ready` fields the player's OwnedCar via
`Car.apply_owned` (CarLibrary baseline → installed upgrades → bound damage from
the saved HP) instead of the default `apply_car(0)`, and wires this event's
`StageManager.stage_completed` → `report_event_result(elapsed_ms, hp_lost)`. The
`rally_finished` loads the podium. There is **no second exit** from the run: `world.gd`
has no `_wreck_screen` and nothing listens for a car reaching 0 HP, because nothing is
signalled when it does — a flattened car simply keeps driving to the finish under its
capped misfire and rev cap. With no session (a plain dev boot of `main.tscn`) the default
car is fielded and none of this runs — `main.tscn` is still independently runnable.

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
the Resume/Settings menu. **Quit to HQ** pops an *"Abandon rally?"* confirm and, on
accept (`quit_to_hq`), unfreezes and calls `RallySession.abandon()` — the rally is
left **incomplete with no retry penalty** (damage persisted, no reward); `abandon`
emits `rally_finished` which `world.gd` routes **straight back to HQ** (the garage
view) instead of the podium. (With no active session — a plain dev boot of
`main.tscn` — it just loads `Scenes.hub_path()` directly.) `ui_cancel` (Esc / gamepad B)
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

## Podium — DELETED

`podium.tscn` / `scripts/podium.gd` (the 3D reward sequence — podium stand,
leaderboard, stars beat, special-unlock card — this section used to document
in full) are deleted, roguelike pivot decision 19, `todo/roguelike-pivot.md`:
"A run ends on a run-summary screen, replacing `podium.tscn`." Placement,
stars and the prize-rally upgrade draw it presented are gone with it (decisions
5 and 21 — see [reward-system.md](reward-system.md) and
[star-economy.md](star-economy.md), both themselves mid-demolition in this
same wave). The run-summary screen that replaces this one is stage 3 work
(`todo/roguelike-pivot-plan.md`).

## Start line (location 2)

The pre-event **start-line scene** — the diegetic **briefing** panel (rally, event
N/3, restriction, fielded car + HP bar) and the **pre-launch presence** cars — is
built inside the run scene before the countdown; the player launches it into the
`StageManager` countdown. See [start-line.md](start-line.md). The in-run **Pause**
menu is covered above (`pause_menu.gd`); the between-event standings
interstitial it used to hand off to is deleted — see next section.

## Standings interstitial — DELETED

`scripts/standings.gd` / `standings.tscn` (the between-event two-leaderboard
page this section used to document, stacking "STAGE n RESULT" over "OVERALL")
and its overlay use behind the event-replay cinematic are deleted — roguelike
pivot decision 30, `todo/roguelike-pivot.md`. Rivals are gone (decision 5), so
there is no field left to rank on either page, and `RallyLibrary.build_standings`
(the field-standings computation both pages read) is deleted with `RallySession`.
Its replacement, a single run-summary screen, is stage 3 work
(`todo/roguelike-pivot-plan.md`) — decision 19.

The **event-replay overlay mechanism itself is not deleted** (`ReplayRecorder`
/ `ReplayCamera` / `car.gd`'s `replay_playback`) — see
[event-replay.md](event-replay.md) — only the flat page it used to render
behind. What re-hosts it, if anything, is undecided as of this change.

## Deferred (rest of the diegetic 3D build)

The diegetic HQ space (exterior / garage / 3D map table / car park / tuning lift,
with the camera flying between stations) is in. Still deferred:
per-car paint + duplicate-model name suffixes,
designed environment art (blocks are placeholder), the 3D
reward-reveal rig + 3D podium, and camera fly-through transitions for the longer
hops. The podium + between-event **standings interstitial** still ship as flat
scenes (`podium.tscn` / `standings.tscn`); the diegetic 3D versions are later
refinements.

## Tests

The **present-box car reveal** is covered in `tests/headless/test_menu_flow.gd`:
`test_a_won_car_opens_hq_on_a_forced_present_box` boots the HQ with
`RallySession.pending_car_reveal_instance_id` set and asserts it lands in
`CarparkMode.PRESENT`, that Back cannot leave an unopened box, and that the bottom button
opens it; `test_the_present_box_only_presents_a_car_already_owned` asserts a reveal id naming
a car the profile does not hold never enters the mode at all — the box is a presentation, so
there is no purchase to test. `test_the_present_box_panel_is_anchored_before_it_is_opened`
covers the anchor trap: the world panel already has a `Transform3D` anchor while the box is
still shut, and that anchor is unchanged after opening — a relationship check, not authored
offsets, so retuning the placement can't break it.

`tests/headless/test_menu_flow.gd` — HQ boots to the **exterior title** (one 3D map
pin per rally, a locked special pin non-pickable); **Start flies into the garage**;
tapping the table shows the **map view**; **stars reflect best placement** (1st→3,
3rd→1, unplayed→0); the map table **pans and clamps to its edges**, and a drag does
**not** open the pin under the finger (selection is release + no-drag); tapping a pin
opens the **rally detail**, and Enter flies to the
**car park**, which parks the **whole garage — eligible or not**. A car that cannot enter
is parked and **marked** rather than hidden: focusing it disables Start and puts the
rally's own `RallyLibrary.ineligibility_reason` on the warning label
(`hq_carpark.gd::_refresh_focus_eligibility`), so "why is my car not in the list?" is
answered on the car itself. **There is no auto-switch:** a wrong-drivetrain car used to be
counted as eligible and silently converted at the Start button for the duration of the
rally, then reverted. That is gone — conversion now costs stars per car
([upgrade-catalogue.md](upgrade-catalogue.md) → "Drivetrain conversion"), so a free silent
switch handed the player exactly what the garage charges for; the player converts the car
themselves, where the price is on screen. The rally-detail panel's
`N need a drivetrain conversion to fit` line counts those cars, and Enter is gated on
**owning** a car rather than on one qualifying — walking into a lineup with nothing
eligible is now where you find out why. An open rally parks the whole lineup with **per-car meshes** (a
mixed lineup keeps each body at its true size); cycling focus re-selects the car and
wraps; **no health level gates a car in the car park** (Start stays enabled at 0 HP —
damage only slows the car, and the lift will repair it); an **over-ceiling Rally Challenge car parks with the
over-limit prompt** (looks eligible; Start pops the on-brand modal offering
Cancel / Change Upgrades — Change Upgrades opens the gated shared `UpgradesGrid` to
shed performance permanently, then the
player re-presses Start); **Back** steps car park → table →
garage and clears the lineup; pin → enter →
car → Start launches a session; the **between-event standings interstitial** renders
both the stage-only and cumulative leaderboards stacked on one page (and the
final event's interstitial hands off to the podium on `rally_finished`); the podium
renders the finish summary **and the car reveal + standings**; and the run scene
fields the bound session car. The settings
test also checks the shared `SettingsMenu` exposes a **camera-angle row per mode** and
**persists the chosen angle**. The pure `RallyLibrary.build_standings` ranking and the
enriched `RallySession` result are covered in `test_rally_library.gd` /
`test_rally_session.gd`.

`tests/headless/test_pause_menu.gd` — the **Pause button freezes the game** and opens
the menu; **Resume unfreezes** and closes it; **Settings exposes the shared
`SettingsMenu`** (camera + control rows); **Quit to HQ abandons the active rally** and
unfreezes the game; and **picking a camera applies live** to the `CameraManager` (and
persists). Camera cycling / `set_mode` persistence is covered in `test_camera_manager.gd`.
