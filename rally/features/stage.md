# Stage Start & End

**Source:** `scripts/stage_manager.gd` (`class_name StageManager extends Node`),
created and wired by `scripts/world.gd._generate_track()`. Drives the car's
control lock (`scripts/car.gd`) and the HUD stage widgets
(`scripts/hud.gd`, see [hud.md](hud.md)); reads the [`TrackProgress`](progress.md)
manager for the finish condition.

Turns the always-live track into a timed stage: a countdown holds the car, then
a run timer ticks until the finish line, then a placeholder complete panel shows.

## Flow (the state machine)

`enum Phase { STAGING, COUNTDOWN, RUNNING, COMPLETE }`, advanced in `_process(delta)`:

0. **STAGING** *(optional)* — when `setup(..., staged = true)`, the car is locked
   and the manager simply **waits** (no countdown ticking) while the pre-event
   start-line sequence ([start-line.md](start-line.md)) plays its time-to-beat
   reveal + orbit camera + launch animation. When it finishes (after the fade),
   `StartLine` calls `begin_countdown()`, which moves to COUNTDOWN. A plain dev boot
   (or a car swap) is set up un-staged and skips this straight to COUNTDOWN, exactly
   as before the start-line scene existed.
1. **COUNTDOWN** — `setup()` (un-staged) or `begin_countdown()` locks the car
   (`controls_locked = true`) and arms
   `_countdown_left = stage_countdown_seconds`. Each frame shows the big centered
   `3·2·1·GO` on the HUD. When the timer elapses: unlock the car, flash `GO`,
   emit `stage_started`, switch to RUNNING.
2. **RUNNING** — accrue `_elapsed` each frame and show it top-right (`m:ss.cc`).
   The `GO` flash is held `GO_FLASH_SECONDS` (0.5 s, a const, not a config knob)
   then hidden. When progress reaches the finish, switch to COMPLETE.
3. **COMPLETE** — freeze the timer, re-lock the car (so the finished car doesn't
   drive on under the panel), show the placeholder stage-complete panel, and emit
   `stage_completed(elapsed_seconds)`.

The finish edge is `progress_percent() * 100.0 >= stage_complete_percent`.
`TrackProgress.progress_percent()` returns a **0..1 fraction**, so it is scaled to
the 0..100 config percentage. Progress is monotonic, so this is a one-way edge —
once COMPLETE, the phase never leaves it. `stage_complete_percent` is **100**, so
the stage ends exactly as the car crosses the finish arch ([finish-arch.md](finish-arch.md)),
which `world.gd` places at the centerline end; `TrackProgress` samples the curve's
far edge so 100% is reachable ([progress.md](progress.md)).

## Control lock (`Car.controls_locked`)

`scripts/car.gd` gates its input reads on a public `controls_locked` flag
(default `false`). While locked: throttle and steering inputs read `0`, the
handbrake is **forced on** (so the car physically holds on a slope), and the
discrete gear/mode/reset actions are ignored. The rest of the simulation (drag,
downforce, suspension, camera) keeps running so the car settles naturally during
the countdown. On the flat test fixture there is no `StageManager`, so the flag
stays `false` and the car is freely drivable.

## Signals

- `stage_started` — countdown finished, timer running.
- `stage_completed(elapsed_seconds: float)` — finish line reached, timer frozen.

These are the hooks a future rally/menu layer attaches to. The **post-stage flow**
(standings, podium, rewards, back to HQ) is out of scope here and owned by
`features/rally-session.md` — this feature only provides the signal and a
placeholder panel.

## Wiring & lifecycle

`world.gd._generate_track()` creates the `StageManager` (named `StageManager`)
right after the car, track and `TrackProgress` exist, then calls
`setup(car, hud, progress)`. Initialisation lives in `setup()` (not `_ready()`)
because `add_child` runs `_ready` before `world.gd` hands over the refs. On track
regeneration (entering a new event) the prior manager is freed so only one ticks.
A car swap (`world.cycle_car`) re-arms the manager on the fresh car, restarting
the countdown.

## Config knobs

| Field | Default | Purpose |
|-------|---------|---------|
| `stage_countdown_seconds` | `3.0` | Countdown length before controls unlock. |
| `stage_complete_percent` | `100.0` | Track-progress % (0..100) that ends the stage. 100 so it coincides with the finish arch at the centerline end; `TrackProgress` samples the curve's far edge so 100% is reachable. |
| `hud_elapsed_enabled` | `true` | Show the top-right run timer (mirrors `hud_enabled`). |

See [configuration.md](configuration.md). No quality-tier branching — single
shipped values, tunable for dev/debug.

## Tests

- `tests/headless/test_stage_manager.gd` — the state machine driven against stub
  car/HUD/progress (lock-at-start, countdown→run, timer accrual, GO flash,
  completion freeze/relock/signal, configured percent) plus a `main.tscn`
  integration check that the car boots locked.
- `tests/headless/test_hud.gd` — the countdown/elapsed/complete widget formatting
  and the `hud_elapsed_enabled` gate.
- `tests/headless/test_smoke.gd` — structural check that the scene wires a
  `StageManager` and the three HUD widgets.
