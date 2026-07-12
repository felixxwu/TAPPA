# Rally Session (event-flow orchestrator)

**Source:** `scripts/rally_session.gd` — the `RallySession` autoload (registered in
`project.godot` alongside `Config`/`Save`; no `class_name`, reached by the global
`RallySession`).

The rally-level coordinator: it turns "the player picked rally R with owned car C"
into the full loop — field the car, run 3 events, accumulate times, place against
the fixed opponent field, grant rewards, finish. It sits **one level above** the
per-stage `StageManager` ([stage.md](stage.md)): `StageManager` owns one event's
countdown→run→complete; `RallySession` owns the rally and survives the per-event
scene reloads. It **calls** the systems that already exist
([rally-roster.md](rally-roster.md), [reward-system.md](reward-system.md),
[save-persistence.md](save-persistence.md), [damage.md](damage.md)) rather than
re-implementing them.

## State machine

`Phase { IDLE, PRESENCE, RUNNING, STANDINGS, RESULTS, PODIUM }`. Idle until
`start_rally`; each `report_*` advances it; `_resolve_results` returns it to IDLE.

| Field | Meaning |
|-------|---------|
| `_rally` | the RallyDef being run (`{}` when IDLE) |
| `_car_instance_id` | the fielded OwnedCar instance |
| `_event_index` | 0..2 |
| `_event_times_ms` | accumulated event times, one per completed event |
| `_opponent_field` | fixed per rally seed (`RallyLibrary.generate_opponent_field`) |
| `_dnf` | set on a wreck |

## API

| Call | Effect |
|------|--------|
| `start_rally(rally, owned_car, event_targets_ms := [])` | seed state, build the opponent field, kick event 0. Targets are derived from each event's track when omitted; tests pass them in to skip generation. |
| `report_event_result(elapsed_ms, hp_lost)` | accumulate the time, persist chip damage (`Save.apply_damage`), then always **enter `STANDINGS`** and emit `standings_ready` — every event pauses on the interstitial, including the last. The reward upgrade is drawn **once per rally** at resolve, not per event. |
| `continue_to_next_event()` | resume from the between-event standings interstitial: enters the next event, or — once `_event_index >= EVENTS_PER_RALLY` (the final event) — calls `_resolve_results()` (→ podium) instead. |
| `current_standings()` | the leaderboard AS OF the events completed so far (each rival's + the player's cumulative time **and the car each drove**, ranked via `build_standings`); read by the standings scene's combined page. `events_completed()` gives the count for its header. |
| `current_event_standings()` | the leaderboard for the **JUST-COMPLETED event alone**: each racer's time for that one event, fastest first (a rival who DNF'd that event sinks to the bottom). The row's `combined_ms` field carries the single-event time, not a cumulative sum. Empty before any event completes. Read by the standings scene's event-only page. |
| `current_event_leaders(n := 3)` | the top `n` rivals for the CURRENT event — each rival's time for this event, fastest first, with the car they drove (`{name, car_name, time_ms}`); DNF-this-event omitted. Drives the start-line "times to beat" reveal. |
| `report_wreck()` | DNF: wreck the instance (`Save.wreck_car` — leaves it owned at 0 HP, repairable, **not** destroyed), skip remaining events, resolve. A DNF earns **no** upgrades (the per-rally draws only fire on a finished rally). Only valid while `RUNNING` (you can't wreck on the standings screen). In real play the run scene shows a **wreck menu** first (`scripts/wreck_screen.gd`) and calls this on *Return to HQ*. |
| `abandon()` | end back at HQ, rally incomplete, no reward (Pause overlay; no retry). |

Signals: `rally_finished(result)`, `phase_changed(phase)`, `event_started(i,
event)`, `standings_ready(i)`, `upgrade_revealed(item_id)`,
`car_rewarded(model_id)`, `showdown_won()`.

`last_result()` (the podium reads it) returns the finish dict — the base
`{placed, completed, combined_ms, dnf}` plus, for the reveal/standings:
`rally_id`, `rally_name`, `standings` (the full ranked field +
player via `RallyLibrary.build_standings`, each entry carrying `car_id` so the
podium can spawn the top-3 cars), `upgrades` (the single id won this rally — a
one-element array, `[]` on a DNF), `car_reward` (model id, `""` if none),
`car_reward_is_new` (bool), and `showdown_won` (bool).

`return_to_garage` is a one-shot navigation flag (not part of the result): the
podium's final Continue sets it so HQ boots straight to the **garage** view; HQ
reads + clears it on its next `_ready`.

## Results & rewards

On resolve: `combined = sum(event_times)`, `placed =
RallyLibrary.placement(field, combined)`. A **top-3, non-DNF** finish records
completion + best placement (`Save.complete_rally(id, combined, placed)`,
idempotent; the placement drives the world-map stars) and grants a reward — a **car** for
a normal rally (`RewardSystem.draw_car`, fires on **every** top-3 including
re-wins → renewable supply), or the **win beat** (`showdown_won`) for the
showdown. Non-top-3 / DNF grants nothing and leaves the rally incomplete (**no
retry** — re-enter from the map later; damage and the opponent field persist).

## Scene transitions

In real play (`auto_load_scenes = true`) each event writes its
`(seed, turn_count, width)` into `Config.data` and reloads `main.tscn`. After
EVERY event — including the last — `report_event_result` emits `standings_ready` and
waits at `Phase.STANDINGS`.

**Standings presentation is now an in-world overlay, not a scene swap.**
`world.gd` connects `standings_ready` to `_present_standings_overlay`, which — for a
real (non-headless) run — keeps the just-finished run scene alive, drops in a
cinematic replay of the event just driven, and shows `standings.tscn` as a transparent
`CanvasLayer` overlay on top of it (`standings.gd`'s `overlay_mode = true`). See
[event-replay.md](event-replay.md) for the recorder/camera/playback mechanics. To make
room for this, `world.gd` sets `RallySession.standings_overlay_host = true` on setup
(false under headless), and `_load_standings_scene()` — the method that would otherwise
`change_scene_to_file("res://standings.tscn")` — becomes a **no-op** whenever that flag
is set, since the host already owns showing the panel. Headless tests never set the
flag, so `_load_standings_scene()` behaves exactly as before there (in practice it never
fires anyway — `auto_load_scenes` is false and tests call `continue_to_next_event()`
directly).

Every event — **including the final one** — shows the standings screen's two pages (the
just-finished event's times, then the cumulative leaderboard) before anything else
happens; the final event's combined page still reads a "Continue to next event >"
button, but pressing it resolves the rally instead. Its Continue calls
`continue_to_next_event()`: for a non-final event this loads the next event; for
the final event it instead resolves the rally (`_resolve_results` → `PODIUM`) and
emits `rally_finished`. In overlay mode the **live host** (`world.gd`) owns the
`rally_finished` → podium transition (the run scene is still alive); in the older flat
mode the standings scene itself connects `rally_finished` and changes to `podium.tscn`
on that signal, since the run scene is already gone by then. Headless
tests set `auto_load_scenes = false`, drive `report_*` directly, and call
`continue_to_next_event()` to step past the standings pause (no scenes load).

## Run-scene wiring

The **run-scene fielding + signal wiring** is in place ([menus.md](menus.md)):
`world.gd` configures the car from the fielded OwnedCar via the
upgrade/tuning/damage pipeline and routes `StageManager.stage_completed` to
`report_event_result`; a car `wrecked` builds the **`WreckScreen`** whose *Return to
HQ* button calls `report_wreck` (headless skips the cinematic and reports at once).
The placeholder HQ calls
`start_rally`, so the loop runs end-to-end. The **diegetic presentation** around
it (standings / podium / reward-reveal staging, `standings_ready` etc.) is the
deferred full menus build — RallySession already emits the signals it hooks.

## Tests

`tests/headless/test_rally_session.gd` — happy path + placement, the per-rally
upgrade grants (`cfg.rally_upgrade_reward_count`, drawn at resolve, not per event), wreck DNF (no upgrade,
instance destroyed), no-retry re-entry (state reset, field fixed), showdown win
beat, farming re-win, idle-at-rest.
