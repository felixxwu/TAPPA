# Stage Start & End

**Source:** `scripts/stage_manager.gd` (`class_name StageManager extends Node`),
created and wired by `scripts/world.gd._generate_track()`. Drives the car's
control lock (`scripts/car.gd`) and the HUD stage widgets
(`scripts/hud.gd`, see [hud.md](hud.md)); reads the [`TrackProgress`](progress.md)
manager for the finish condition.

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

## In-stage "vs P1" pace popup

During RUNNING the manager can pulse a small top-centre HUD popup **every few turns**
telling the player how their elapsed time compares to the **leading (P1) rival** at
that point — `−` (green) when ahead, `+` (red) when behind (see [hud.md](hud.md) →
`show_stage_delta`). It reuses the **turn-based time estimate** the rest of the rally
runs on rather than inventing a new one:

- **Boundaries** come from `RallyLibrary.derive_turn_splits(track_result, car_meta,
  event)` — for each placed turn, the arc length reached — since it is the only thing
  that knows where each placed piece ends.
- **Times** come from the shared `RivalPace` object the rival ghost is posed from
  ([rival-ghost.md](rival-ghost.md)), NOT from `derive_turn_splits`' own cumulative
  times. One pace model serves both, so the delta on the HUD and the ghost car in the
  windscreen cannot disagree about the same rival.
- The wiring is therefore **two-phase** in `world.gd`: `_setup_stage_splits()` snapshots
  P1 and captures the turn boundaries during generation, then `_solve_rival_pace()` at
  `stage_started` solves the pace and `_wire_stage_splits()` calls
  `StageManager.setup_splits(turn_progress, turn_time_frac, p1_total_ms)`. It must wait
  for GO because the span is measured from `TrackProgress.origin_offset()`, which
  `mark_start()` only anchors once the player has been placed in their grid slot.
- `derive_turn_splits` measures offsets on the **raw** generated curve while the pace
  profile starts at the timing origin, so `_wire_stage_splits` shifts each boundary by
  `start_lead_in_ahead_m` on a staged run first. Without that shift every turn reads one
  lead-in early and the last boundary stops landing on the total.
- P1 is resolved from `RallySession.current_event_p1()` — one snapshot carrying the time,
  the car id, the engine id and the effective meta together. Only wired for a session run
  that has a classified P1 rival; a plain dev boot shows no popup.
- Each RUNNING frame, `_maybe_show_split()` advances past every turn boundary the
  player has now crossed (progress is monotonic) and, when the count reaches a whole
  `stage_delta_interval_turns`, fires the popup for the latest crossed turn. The rival's
  estimated time **at that turn** is `p1_total_ms × turn_time_frac[turn]` — its total
  event time distributed across the stage by the same par-time profile — and the delta
  shown is `player_elapsed − that`. A re-arm (`setup()`, e.g. a car swap / new event)
  clears the splits so they don't leak between stages.

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
  [corner-cutting](corner-cutting.md) penalty snapshot at `_complete()`), so
  `RallySession`'s rally-total accumulation sees the penalized time without any
  change on its end.

These are the hooks the rally/menu layer attaches to. The **post-stage flow**
(standings, podium, rewards, back to HQ) is out of scope here and owned by
`features/rally-session.md` — this feature only provides the signals, the finish
panel, and the NEXT → `proceed_to_results()` gate.

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
| `hud_stage_delta_enabled` | `true` | Show the in-run "vs P1" pace popup (mirrors `hud_enabled`; needs a session P1). |
| `stage_delta_interval_turns` | `5` | Turns between pace popups (every Nth turn). |
| `stage_delta_show_seconds` | `3.0` | How long the pace popup stays before fading. |

See [configuration.md](configuration.md). No quality-tier branching — single
shipped values, tunable for dev/debug.

## Tests

- `tests/headless/test_stage_manager.gd` — the state machine driven against stub
  car/HUD/progress (lock-at-start, countdown→run, timer accrual, GO flash,
  completion freeze/relock/signal, configured percent), the **pace-popup splits**
  (fires every N turns, ahead reads negative / behind positive, configurable
  interval, no popup without wired splits), plus a `main.tscn` integration check
  that the car boots locked.
- `tests/headless/test_rally_library.gd` — includes `derive_turn_splits` (monotonic
  offsets + cumulative times, final split equals the derived target, empty without
  pieces).
- `tests/headless/test_hud.gd` — the countdown/elapsed/complete widget formatting
  and the `hud_elapsed_enabled` gate.
- `tests/headless/test_smoke.gd` — structural check that the scene wires a
  `StageManager` and the three HUD widgets.
