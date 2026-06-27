# Rally / Event Flow — implementation spec

> Status: **✅ IMPLEMENTED.** The `RallySession` autoload — the rally-level
> orchestrator — shipped, and the menus vertical slice wired it end-to-end
> (HQ → field car → 3 events → podium → HQ). See the living doc
> [`features/rally-session.md`](../features/rally-session.md) (source:
> `scripts/rally_session.gd`, run-scene fielding in `scripts/world.gd`; tests in
> `tests/headless/test_rally_session.gd` + `test_menu_flow.gd`). The brief that
> drove it has been struck; only the deferrals below remain.

## What shipped

The autoload survives per-event scene reloads and runs the full loop:
`start_rally(rally, owned, targets)` → field the car (CarLibrary baseline →
upgrades → bound damage from saved HP) → 3 events via `report_event_result`
(accumulate time, `Save.apply_damage`, per-event upgrade draw + grant) → place
against the fixed per-seed opponent field → top-3/non-DNF records completion and
grants a car (farming: fires on every re-win) or the showdown win beat → finish.
**No retry** (re-enter from the map; damage + field persist); a mid-rally
**wreck** DNFs but keeps upgrades already earned. Signals: `rally_finished`,
`phase_changed`, `event_started`, `standings_ready`, `upgrade_revealed`,
`car_rewarded`, `showdown_won`. `world.gd` routes `StageManager.stage_completed`
/ car `wrecked` → `report_*` when a session is active; a plain dev boot of
`main.tscn` still fields the default car (regression-guarded).

## Remaining / deferred (the presentation layer — `todo/menus.md`)

The session **brain** is done; what's left is the diegetic dressing around it,
all owned by the deferred full menus build:

- ~~**Pre-launch presence** — the ahead/behind atmosphere cars at the Start line.~~
  ✅ **DONE.** The pre-event start-line sequence shipped as `scripts/start_line.gd`
  (`StageManager` STAGING phase + `world.gd` wiring): a TIME-TO-BEAT reveal + orbit
  camera with a leader car ahead and a trailing car behind, the leader driving off
  and the field scooting up on launch, then a fade into the countdown. See
  [`features/start-line.md`](../features/start-line.md).
- **Standings interstitial** — between events 0→1→2 it's currently a straight
  reload; `RallySession` already emits `standings_ready(i)` for the overlay
  (`todo/menus.md` overlay 7) to hook the running combined-vs-field display onto.
- **Reward reveal** — `car_rewarded` / `upgrade_revealed` fire, but the physical
  reveal rig (spotlight / garage door, `todo/menus.md` rig 5) is deferred.
- **Pause overlay** — Resume / Abandon-to-HQ UI (`abandon()` exists; the overlay
  that calls it is `todo/menus.md` overlay 8, first user of `get_tree().paused`).
- **Showdown win / credits beat** — `showdown_won` fires, but the actual
  win presentation is unspecified (its own small spec when we reach it).
- **UI / countdown / sting audio** — the menu and result moments are silent until
  **`todo/audio.md`** lands the bus layout + SFX.
