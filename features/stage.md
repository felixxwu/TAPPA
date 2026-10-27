# Stage Start & End

> **Free-roam pivot (2026-10):** the stage scene (`main.tscn` / `world.gd`) is no longer reachable from the game. It survives as a **dev stage and the physics test harness**: it builds a track from the live config and fields the first library car. The run loop, start line, rival ghost, pacenotes, signs, arches, coins, the on-screen countdown / run timer / finish panel and the corner-cut penalty are deleted; see `PIVOT-CHANGES.md`.

**Source:** `scripts/stage_manager.gd` (`class_name StageManager extends Node`),
created and wired by `scripts/world.gd`. Drives the car's control lock
(`scripts/car.gd`); reads the [`TrackProgress`](progress.md) manager for the finish
condition. It shows nothing on screen.

**Tests:** `tests/headless/test_stage_manager.gd`, `tests/headless/test_countdown_hold.gd`

Holds the car on the line through a countdown, times the run until the finish line, then
locks the car (skidding to a stop in the runoff past the finish).

## Flow (the state machine)

`enum Phase { COUNTDOWN, RUNNING, COMPLETE }`, advanced in `_process(delta)`:

1. **COUNTDOWN** — `setup(car, progress)` drops any full lock and forces only the handbrake
   (`controls_locked = false`, `handbrake_locked = true`), so the player can rev the engine and
   steer on the line but the car holds put. It arms `_countdown_left = stage_countdown_seconds`
   and calls `TrackProgress.mark_start()` so progress reads **0% from the line**
   ([progress.md](progress.md)). When the timer elapses: release the handbrake (so a revved car
   launches), emit `stage_started`, switch to RUNNING.
2. **RUNNING** — accrue `_elapsed` each frame. When progress reaches the finish, switch to COMPLETE.
3. **COMPLETE** — freeze the timer and re-lock the car (`controls_locked = true` +
   `finish_stop = true`): the car **brakes itself to a stop** — full foot brake +
   handbrake while rolling, foot brake released once stopped, clutch kept engaged so
   the engine winds down to idle instead of free-revving ([car-physics.md](car-physics.md)) —
   staying visible in the runoff road past the finish ([track.md](track.md)).

The finish edge is `progress_percent() * 100.0 >= stage_complete_percent`.
`TrackProgress.progress_percent()` returns a **0..1 fraction**, so it is scaled to
the 0..100 config percentage. Progress is monotonic, so this is a one-way edge —
once COMPLETE, the phase never leaves it. `TrackProgress` reaches 100% at the **finish
offset** (the end of the timed track, before the runoff; [progress.md](progress.md)).

## Control lock (`Car.controls_locked`)

`scripts/car.gd` gates its input reads on a public `controls_locked` flag
(default `false`). While locked: throttle and steering inputs read `0`, the
handbrake is **forced on** (so the car physically holds on a slope), and the
discrete gear/mode/reset actions are ignored. The rest of the simulation (drag,
downforce, suspension, camera) keeps running so the car settles naturally during
the countdown. On the flat test fixture there is no `StageManager`, so the flag
stays `false` and the car is freely drivable.

While the car is held — either lock — the forced handbrake plus the **static parking
hold** (`car.gd._apply_parking_hold`, a damped spring to the spot the car stopped on)
keeps it genuinely still: no vibration, no sideways creep, and therefore no spurious
deceleration damage (the damage rule has **no** held-car exemption — see
[damage.md](damage.md) and [car-physics.md](car-physics.md) → the parking hold).

## Signals

- `stage_started` — countdown finished, timer running.

## Wiring & lifecycle

`world.gd` creates the `StageManager` (named `StageManager`) right after the car, track and
`TrackProgress` exist, then calls `setup(car, progress)`. A benchmark run leaves it un-armed.
Initialisation lives in `setup()` (not `_ready()`) because `add_child` runs `_ready` before
`world.gd` hands over the refs.

## Config knobs

| Field | Purpose |
|-------|---------|
| `stage_countdown_seconds` | Countdown length before controls unlock. |
| `stage_complete_percent` | Track-progress % (0..100) that ends the stage. |

See [configuration.md](configuration.md).

## Tests

- `tests/headless/test_stage_manager.gd` — the state machine driven against stub
  car/progress (lock-at-start, countdown→run, timer accrual, completion freeze/relock, configured
  percent), plus a `main.tscn` integration check that the car boots with the handbrake held.
- `tests/headless/test_countdown_hold.gd` — a handbrake-held car sits still.
- `tests/headless/test_smoke.gd` — structural check that the scene wires a `StageManager`.
