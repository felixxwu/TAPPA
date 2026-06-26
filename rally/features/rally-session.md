# Rally Session (event-flow orchestrator)

**Source:** `scripts/rally_session.gd` — the `RallySession` autoload (registered in
`project.godot` alongside `Config`/`Save`; no `class_name`, reached by the global
`RallySession`). See the brief in [../todo/rally-event-flow.md](../todo/rally-event-flow.md).

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
| `report_event_result(elapsed_ms, hp_lost)` | accumulate the time, persist chip damage (`Save.apply_damage`), draw + grant a per-event upgrade (`RewardSystem.draw_upgrade` → `Save.add_item` → `Save.save`), then **pause on the standings** (non-final event) or resolve (final). |
| `continue_to_next_event()` | resume from the between-event standings interstitial into the next event. |
| `current_standings()` | the leaderboard AS OF the events completed so far (each rival's + the player's cumulative time, ranked via `build_standings`); read by the standings scene. `events_completed()` gives the count for its header. |
| `report_wreck()` | DNF: destroy the instance (`Save.wreck_car`), skip remaining events, resolve. Upgrades earned earlier this rally are kept. Only valid while `RUNNING` (you can't wreck on the standings screen). |
| `abandon()` | end back at HQ, rally incomplete, no reward (Pause overlay; no retry). |

Signals: `rally_finished(result)`, `phase_changed(phase)`, `event_started(i,
event)`, `standings_ready(i)`, `upgrade_revealed(item_id)`,
`car_rewarded(model_id)`, `showdown_won()`.

`last_result()` (the podium reads it) returns the finish dict — the base
`{placed, completed, combined_ms, dnf}` plus, for the reveal/standings:
`rally_id`, `rally_name`, `standings` (the full ranked field +
player via `RallyLibrary.build_standings`), `upgrades` (the per-event ids drawn
this rally), `car_reward` (model id, `""` if none), `car_reward_is_new` (bool), and
`showdown_won` (bool).

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
`(seed, turn_count, width)` into `Config.data` and reloads `main.tscn`. Between
events the session loads `standings.tscn` (the leaderboard interstitial) and waits;
its Continue calls `continue_to_next_event()`, which loads the next event. The
final event loads `podium.tscn` instead. Headless tests set
`auto_load_scenes = false`, drive `report_*` directly, and call
`continue_to_next_event()` to step past the standings pause (no scenes load).

## Run-scene wiring

The **run-scene fielding + signal wiring** is in place ([menus.md](menus.md)):
`world.gd` configures the car from the fielded OwnedCar via the
upgrade/tuning/damage pipeline and routes `StageManager.stage_completed` / car
`wrecked` to `report_*` when a session is active. The placeholder HQ calls
`start_rally`, so the loop runs end-to-end. The **diegetic presentation** around
it (standings / podium / reward-reveal staging, `standings_ready` etc.) is the
deferred full menus build — RallySession already emits the signals it hooks.

## Tests

`tests/headless/test_rally_session.gd` — happy path + placement, per-event upgrade
grants, wreck DNF (upgrades kept, instance destroyed), no-retry re-entry (state
reset, field fixed), showdown win beat, farming re-win, idle-at-rest.
