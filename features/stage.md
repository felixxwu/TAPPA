# Stage Start & End

**Source:** `scripts/stage_manager.gd` (`class_name StageManager extends Node`),
created and wired by `scripts/world.gd._generate_track()`. Drives the car's
control lock (`scripts/car.gd`) and the HUD stage widgets
(`scripts/hud.gd`, see [hud.md](hud.md)); reads the [`TrackProgress`](progress.md)
manager for the finish condition.

**Tests:** `tests/headless/test_stage_manager.gd`, `tests/headless/test_start_line.gd`, `tests/headless/test_countdown_hold.gd`, `tests/headless/test_hud.gd`

Turns the always-live track into a timed stage: a countdown holds the car, then
a run timer ticks until the finish line, then the car is locked (skidding to a stop
in the runoff past the finish) and a finish panel shows the time with a NEXT button
that advances to the leaderboard/podium flow.

## Flow (the state machine)

`enum Phase { STAGING, COUNTDOWN, RUNNING, COMPLETE }`, advanced in `_process(delta)`:

0. **STAGING** *(optional)* — when `setup(..., staged = true)`, the car is fully
   locked (`controls_locked`) and the manager simply **waits** (no countdown ticking) while the pre-event
   start-line sequence ([start-line.md](start-line.md)) plays its time-to-beat
   reveal + orbit camera + launch animation. When it finishes (after the fade),
   `StartLine` calls `begin_countdown()`, which moves to COUNTDOWN. A plain dev boot
   (or a car swap) is set up un-staged and skips this straight to COUNTDOWN, exactly
   as before the start-line scene existed.
1. **COUNTDOWN** — `setup()` (un-staged) or `begin_countdown()` drops any full lock
   and forces only the handbrake (`controls_locked = false`, `handbrake_locked = true`),
   so the player can rev the engine and steer on the line but the car holds put. It arms
   `_countdown_left = stage_countdown_seconds`. It also calls
   `TrackProgress.mark_start()` so progress reads **0% from the line** — the car is
   on the start line by now (the start-line sequence snapped it there), so the
   lead-in behind the start and any roll-up settle don't count
   ([progress.md](progress.md)). Each frame shows the big centered `3·2·1·GO` on
   the HUD. When the timer elapses: release the handbrake (so a revved car launches),
   flash `GO`, emit `stage_started`, switch to RUNNING.
2. **RUNNING** — accrue `_elapsed` each frame and show it top-right (`m:ss.cc`).
   The `GO` flash is held `GO_FLASH_SECONDS` (0.5 s, a const, not a config knob)
   then hidden. When progress reaches the finish, switch to COMPLETE.
3. **COMPLETE** — freeze the timer and re-lock the car (`controls_locked = true` +
   `finish_stop = true`): the car **brakes itself to a stop** — full foot brake +
   handbrake while rolling, foot brake released once stopped, clutch kept engaged so
   the engine winds down to idle instead of free-revving ([car-physics.md](car-physics.md)) —
   staying visible in the runoff road past the finish ([track.md](track.md)). It also
   snapshots any [corner-cutting](corner-cutting.md) penalty here — `_penalty_s =
   TrackProgress.cut_penalty_s()` — and folds it into the **reported** event time,
   `_reported_seconds = _elapsed + _penalty_s`; the on-screen run timer (`_elapsed`)
   itself stays clean throughout the run and is never touched by the penalty. Then
   show the finish panel with the run time (+ cut breakdown, [hud.md](hud.md)). It **does** emit
   `finish_reached` here — the "car crossed the line" moment, distinct from the deferred
   `stage_completed`. Anything that should reflect the *driven run* rather than the
   player's panel-dismiss must key off `finish_reached`: `world.gd` stops the replay
   recorder (else the runoff idle tails the recording — [event-replay.md](event-replay.md))
   and snapshots the event's HP loss + persisted wheel-toe here (else damage taken during
   the post-finish coast is wrongly charged). `stage_completed` is **not**
   emitted here: it's **deferred** to `proceed_to_results()`, which the finish
   panel's **NEXT** button fires (via the HUD's `finish_next_pressed` signal, wired
   in `world.gd`). So the leaderboard/podium flow only starts once the player
   dismisses the time. `proceed_to_results()` is guarded — it emits
   `stage_completed(elapsed_seconds)` only while COMPLETE and only once (a
   double-press can't re-enter the flow). `force_complete()` (the dev F cheat) takes
   the same path: panel now, results on NEXT.

The finish edge is `progress_percent() * 100.0 >= stage_complete_percent`.
`TrackProgress.progress_percent()` returns a **0..1 fraction**, so it is scaled to
the 0..100 config percentage. Progress is monotonic, so this is a one-way edge —
once COMPLETE, the phase never leaves it. `stage_complete_percent` is **100**, so
the stage ends exactly as the car crosses the finish arch ([finish-arch.md](finish-arch.md)),
which `world.gd` places at the **finish offset** (the end of the timed track, before
the runoff); `TrackProgress` reaches 100% at that offset ([progress.md](progress.md)).

## In-stage live standings readout — DELETED (rivals deleted)

The roguelike pivot dropped the rival field entirely (`todo/roguelike-pivot.md`
decision 5), and the in-stage position/gap readout went with it: it projected the
player's finishing time and slotted it into a field of rivals, which is not a
question this game asks any more.

Deleted outright, not left dormant: `hud.show_position` / `hide_position` /
`PositionLabel` / `PositionGapLabel` ([hud.md](hud.md)),
`StageManager.setup_live_standings`, `StageManager._update_live_standings`, its
`_field_times`, the two HUD capabilities in `StageManager.setup`'s duck-type list,
and `scripts/live_standings.gd` with its test file. `world.gd`'s
`_setup_stage_splits`, `_solve_rival_pace` and `_wire_stage_splits` went with the
rival ghost.

**`StageManager.setup_splits` survives**, and this is the distinction that matters:
the pace table it wires (`_turn_progress` / `_turn_time_frac` / `_p1_total_ms`) is
per-turn pace data, not rival data. The pivot's fixed per-stage timer still needs
it — see the spec's *The timer — the one fail state*, which sources the target from
`LapTimeModel.optimum_ms()` against `CarPerformance.REFERENCE_CAR`.

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
- `finish_reached` — car crossed the finish (phase → COMPLETE), fired in `_complete()`
  before the NEXT button; for run-end snapshots that must exclude the post-finish coast.
- `stage_completed(elapsed_seconds: float)` — emitted by `proceed_to_results()`
  when the player presses **NEXT** on the finish panel (NOT on the raw finish),
  timer frozen. This deferral gives the car room to skid to a stop and lets the
  player read the time before the leaderboard. The value carried is the
  **reported** event time (`_reported_seconds`, `_elapsed` plus any
  [corner-cutting](corner-cutting.md) penalty snapshot at `_complete()`), so the
  session's total-time accumulation sees the penalized time without any change
  on its end.

These are the hooks the run/menu layer attaches to. The **post-stage flow**
(standings, rewards, back to the hub) is out of scope here — this feature only
provides the signals, the finish panel, and the NEXT → `proceed_to_results()`
gate. `RallySession`, the career-rally orchestrator this doc used to point at, is
deleted (`todo/roguelike-pivot.md`); `RunSession` is the surviving session
caller until the roguelike `RunSession` lands.

## Wiring & lifecycle

`world.gd._generate_track()` creates the `StageManager` (named `StageManager`)
right after the car, track and `TrackProgress` exist, then calls
`setup(car, hud, progress)`. Initialisation lives in `setup()` (not `_ready()`)
because `add_child` runs `_ready` before `world.gd` hands over the refs. On track
regeneration (entering a new event) the prior manager is freed so only one ticks.

## Config knobs

| Field | Default | Purpose |
|-------|---------|---------|
| `stage_countdown_seconds` | `3.0` | Countdown length before controls unlock. |
| `stage_complete_percent` | `100.0` | Track-progress % (0..100) that ends the stage. 100 so it coincides with the finish arch at the finish offset (the timed-track end, before the runoff); `TrackProgress` reaches 100% there. |
| `hud_elapsed_enabled` | `true` | Show the top-right run timer (mirrors `hud_enabled`). |
| `hud_popup_show_seconds` | `3.0` | How long a transient in-run tag (the corner-cut flash) stays before fading. |

See [configuration.md](configuration.md). No quality-tier branching — single
shipped values, tunable for dev/debug.

## Tests

- `tests/headless/test_stage_manager.gd` — the state machine driven against stub
  car/HUD/progress (lock-at-start, countdown→run, timer accrual, GO flash,
  completion freeze/relock/signal, configured percent), plus a `main.tscn`
  integration check that the car boots locked. `setup_splits` /
  `setup_live_standings` are DORMANT (see above) and untested here beyond
  compiling — nothing calls them.
- `tests/headless/test_hud.gd` — the countdown/elapsed/complete widget formatting
  and the `hud_elapsed_enabled` gate.
- `tests/headless/test_smoke.gd` — structural check that the scene wires a
  `StageManager` and the three HUD widgets.
