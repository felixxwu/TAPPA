# Rally / Event Flow — implementation spec

> Status: **planned, not yet implemented.** Implementation brief for the
> rally-level **session orchestration** — the controller that sequences a rally's
> three events and drives every handoff to the meta-game (HP, standings, rewards,
> podium, HQ). Sits one level **above** the per-stage `StageManager` in
> `todo/stage-start-and-end.md`. Follow the config-first convention (`CLAUDE.md`).
> Update the relevant `features/*.md` doc and add tests in the same piece of work.
>
> **Forks decided** (with the user): the session is an **autoload that survives
> per-event scene reloads**; **retries are allowed and damage sticks** (whole-rally
> re-run); a **mid-rally wreck keeps upgrades earned from completed events**. See
> *Decided (kept for trace)*.

## Goal

One coordinator that turns "the player picked rally R with owned car C" into the
full loop — field the car, run 3 events, show standings between them, total the
combined time, place against the opponent field, grant rewards, show the podium,
and return to HQ — calling into the systems that already (will) exist rather than
re-implementing any of them.

## What it owns vs. what it calls

- **Owns:** the rally-level state machine, the in-progress session state (which
  rally, event index, accumulated event times, the fielded car), scene
  transitions between events/standings/podium/HQ, and the retry decision.
- **Calls:** `StageManager` (one event's countdown→run→complete,
  `todo/stage-start-and-end.md`), `OpponentField` + `RallyLibrary`
  (`todo/rally-roster.md`, placement), `RewardSystem` (`todo/reward-system.md`,
  grants), `Save` (`todo/save-persistence.md`, HP/completion/grant), and the
  menus rigs/overlays (`todo/menus.md`: presence, standings, podium, reward
  reveal).

## Current state (measured from the code)

- **The run scene is `main.tscn`**, built live by `world.gd._ready()`
  (`world.gd:10`) which applies config, spawns the car (`apply_car(0)`,
  `world.gd:46`) and generates the track from `cfg.track_seed`
  (`world._generate_track`, `world.gd:58,64-66`). There is **no session, no event
  concept, no scene that outlives the run** — the game boots straight into one
  endless drivable track.
- **The only autoload today is `Config`** (`project.godot:18-20`). A session
  autoload would be the second.
- **`StageManager` (planned)** already gives a single event its lifecycle and a
  `stage_completed(elapsed_seconds)` signal (`todo/stage-start-and-end.md` §1) —
  the exact hook this controller waits on. The damage model adds a `wrecked`
  signal (`todo/damage-model.md`) — the other hook.

## Architecture: a `RallySession` autoload

`scripts/rally_session.gd`, `class_name RallySession extends Node`, registered as
an autoload alongside `Config`. It holds the in-progress rally and **survives the
per-event scene reloads** (the decided model): each event is a fresh load of
`main.tscn` with that event's seed written into `Config.data` first — clean state
isolation, and the load hides under the menus fly-through/fade.

```gdscript
enum Phase { IDLE, PRESENCE, RUNNING, STANDINGS, RESULTS, PODIUM }
var _rally: Dictionary          # the RallyDef being run (null when IDLE)
var _car_instance_id: int       # the fielded OwnedCar
var _event_index: int           # 0..2
var _event_times_ms: Array[int] # accumulated, one per completed event
var _dnf: bool                  # set true on wreck

signal rally_finished(result)   # {placed:int, completed:bool, combined_ms:int, dnf:bool}
```

`RallySession.start_rally(rally, owned_car)` (called from the map → Start line,
`todo/menus.md`) seeds the state and kicks the first event.

## Fielding the car (run-scene entry)

When a run scene loads for an event, the car is configured from the fielded
`OwnedCar`, applying the **effect pipeline** in `todo/upgrade-catalogue.md`:
1. `apply_car(CarLibrary.index_of(owned.model_id))` — baseline (`car.gd:253`).
2. `UpgradeLibrary.apply(owned, Config.data)` — installed upgrades.
3. per-car tuning deltas (`todo/menus.md`).
4. damage state from `owned.hp` (`todo/damage-model.md`) — the working HP for the
   run starts here; the immortal starter skips depletion.

This replaces today's hardcoded `apply_car(0)` (`world.gd:46`) when a session is
active; with no session (e.g. a dev boot), the current default still applies.

## The loop

```
start_rally(R, C)
  for event_index in 0..2:
    PRESENCE  → pre-launch beat (car ahead launching / behind waiting,
                gameplay.md atmosphere) then hand to StageManager
    RUNNING   → StageManager run; await one of:
        stage_completed(elapsed):
            _event_times_ms.append(elapsed); Save.apply_damage(C, hp_lost); Save.save()
            draw + reveal a per-event upgrade (RewardSystem.draw_upgrade → Save.add_item)
        wrecked:
            _dnf = true; break            # keep upgrades already revealed this rally
    STANDINGS (after events 0 and 1, if not DNF) → Standings overlay interstitial,
               player's running combined vs the opponent field's partial times
    (reload main.tscn with the next event's seed)
  RESULTS → if _dnf: placement = DNF
            else: combined = sum(_event_times_ms);
                  placement = 1 + count(opponents non-DNF with lower combined)
  PODIUM  → Podium rig + full Standings overlay
            if placement <= 3 and not _dnf:
                Save.complete_rally(R.id, combined)
                model = RewardSystem.draw_car(R.difficulty, profile)   # may be null
                if model: Save.grant_car(model) + reward reveal (car arrives in HQ car park)
            else:
                offer Retry (see below)
  → fly-through back to HQ
```

- **HP persists at each event boundary** via `Save.apply_damage` (the save spec
  debounces/autosaves here), so chip damage carries across events and rallies.
- **Per-event upgrade reveal** fires after each completed event (`gameplay.md`:
  "a random upgrade per event"); a wreck stops further events but **keeps the
  upgrades already revealed** (decided).

## Wreck / DNF

On the `wrecked` signal (HP→0, non-immortal car, `todo/damage-model.md`):
- The rally is an immediate **DNF**; `Save.wreck_car(C)` returns installed
  upgrades to inventory then destroys the instance (save spec).
- Skip remaining events, go straight to RESULTS as DNF (no car reward, no
  further event upgrades), then back to HQ. Player DNF happens **only** this way.

## Retry (allowed, damage sticks)

If the player doesn't place top-3 (and isn't DNF), offer **Retry** (the Pause
overlay's Retry, `todo/menus.md` overlay 8). Retry **re-runs the whole rally**
from event 1 for a fresh combined time; **damage taken persists** and the
**opponent field is unchanged** (fixed per seed) — exactly `gameplay.md`'s locked
*Run stakes* decision. Declining returns to HQ; the rally stays **incomplete and
re-enterable later** from the map. *(Whole-rally vs from-failed-event retry: see
open questions — proceeding with whole-rally.)*

## Showdown

The showdown rally runs through this same loop, but on a **top-3 finish** it
triggers the game's **win / credits beat** instead of a reward draw + HQ return
(`gameplay.md`: winning the showdown is the game's "win"). It is only startable
when `RallyLibrary.showdown_unlocked(profile)` is true.

## Scene transitions

`RallySession` drives `get_tree().change_scene_to_file(...)`:
- Writes the next event's `(seed, turn_count, width)` into `Config.data` **before**
  loading `main.tscn` (the roster spec's entry pattern; mirrors `apply_car`'s
  runtime `Config.data` mutation).
- Standings is a `CanvasLayer` overlay shown **over the finished run scene** before
  the next load (no separate scene); Podium and HQ are their own scenes
  (`todo/menus.md` locations). Loads hide under the fly-through/fade.

## API / signals

```
RallySession.start_rally(rally: Dictionary, owned_car: Dictionary) -> void
RallySession.report_event_result(elapsed_ms: int, hp_lost: float) -> void  # from StageManager
RallySession.report_wreck() -> void                                        # from damage model
RallySession.retry() / RallySession.abandon() -> void                      # from Pause overlay
signal rally_finished(result: Dictionary)
```

The run scene wires `StageManager.stage_completed` / car `wrecked` to the
`report_*` calls in `world._ready()` when a session is active.

## Dependencies

- **`todo/stage-start-and-end.md`** — `StageManager` runs each event; this
  controller is the first real consumer of its `stage_completed` signal (its
  placeholder complete-panel becomes this spec's standings/podium handoff).
- **`todo/rally-roster.md`** — the `RallyDef`/events to run, `OpponentField` for
  placement, `showdown_unlocked`.
- **`todo/reward-system.md`** — `draw_upgrade` (per event) / `draw_car` (on win).
- **`todo/save-persistence.md`** — `apply_damage`, `wreck_car`, `complete_rally`,
  `grant_car`, `add_item`, `save`.
- **`todo/damage-model.md`** — the `wrecked` signal + working-HP handoff.
- **`todo/upgrade-catalogue.md`** — the field-the-car effect pipeline.
- **`todo/menus.md`** — Start line (presence), Standings/Pause overlays, Podium +
  reward-reveal rigs; the map's `start_rally` entry point.

## Testing

Headless GUT tests (`tests/headless/`), driving `RallySession` with stubbed
StageManager results (no real driving needed):
- **Happy path:** 3 `report_event_result` calls accumulate; combined = sum;
  placement computed against a fixed opponent field; top-3 calls
  `complete_rally` + `draw_car` once.
- **Per-event upgrade:** one `add_item` per completed event; three on a full run.
- **Wreck mid-rally:** `report_wreck` on event 2 → DNF, `wreck_car` called, no car
  reward, upgrades from event 1 retained, no event-3 upgrade.
- **Retry:** declining vs retrying; retry resets `_event_times_ms` and re-runs
  from event 0 while the (stubbed) opponent field and persisted HP are unchanged.
- **Showdown:** a top-3 showdown finish emits the win beat, not a reward draw.
- **No-session boot:** loading `main.tscn` with no active session still applies the
  default car/track (regression guard for `world._ready`).

## Out of scope / open questions

- **Retry granularity** — whole-rally (proceeding) vs resume-from-failed-event.
- **Presence scene contents** — the ahead/behind cars are atmosphere owned by the
  Start line (`todo/menus.md` / `todo/stage-start-and-end.md`); only the *trigger*
  is here.
- **Standings partial-time display** — how mid-rally combined-vs-field is shown
  between events (a Standings-overlay detail).
- **Abandon semantics** — abandoning mid-rally (Pause overlay) returns to HQ with
  damage persisted and the rally incomplete; confirm no extra penalty.
- **Win/credits beat** — the actual showdown-win presentation is unspecified
  (its own small spec when we get there).

### Decided (kept for trace)

- **Session home:** an autoload `RallySession` that survives per-event scene
  reloads; each event reloads `main.tscn` with its seed.
- **Retry:** allowed, whole-rally re-run, damage sticks, opponents fixed.
- **Mid-rally wreck:** keeps upgrades earned from completed events; car destroyed,
  rally DNF.
