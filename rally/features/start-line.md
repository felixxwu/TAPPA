# Pre-event Start Line

**Source:** `scripts/start_line.gd` (`class_name StartLine extends Node3D`), created
and wired by `scripts/world.gd` for staged session runs. Holds the
[`StageManager`](stage.md) in its `STAGING` phase and launches it after a cinematic
reveal. Uses the scripted-control hook on [`car.gd`](car-physics.md) for the queue cars.

The diegetic sequence between picking a car in HQ and the `3·2·1·GO` countdown
(`todo/menus.md` location 2). It runs **inside the live run scene** (`main.tscn`)
once the world is built and a [`RallySession`](rally-session.md) is active, while the
car is held locked. Three phases, driven in `_process`:

1. **REVEAL (orbit)** — a flat overlay shows the **TIME TO BEAT** (the fastest
   non-DNF rival's time for this stage — `RallySession.current_event_target_ms()`,
   `m:ss.cc`, or `—`) plus a `Rally — Event N of 3` subtitle and a **Start** button.
   Behind it an **orbit camera** circles the car, which is queued between a
   **leader** car ahead and a **trailing** car behind. The driving HUD + mobile
   controls are hidden. Launch with the button, `menu_select` (Enter / gamepad A),
   or a tap.
2. **DRIVE-OFF (launch)** — the leader and trailer **floor the throttle**; the
   leader pulls away up the road while the trailer rolls up to the line and eases
   off (`start_trailer_scoot_seconds`) so its parking brake settles it. The overlay
   hides. This runs for `start_drive_off_seconds`.
3. **FADE** — the screen **fades to black** (`start_fade_seconds`); at full black the
   queue cars are despawned, the camera hands back to the **chase camera**, the
   **driving UI returns**, and `StageManager.begin_countdown()` starts the countdown;
   then it **fades back in**.

The player car never moves during the sequence (it stays at its spawn = the start
line, so track progress lines up); only the two atmosphere cars move. They are
**flavour only — NOT the real opponent field** (that's `RallyLibrary`'s per-seed
roster, surfaced in the standings).

## Physically-simulated queue cars

The leader and trailer are **live `Car` props** (not frozen), so they drive off with
real suspension load, squat and weight transfer. They run full physics but read
**scripted control** instead of player Input via the `car.gd` hook
(`ai_controlled` + `ai_throttle` / `ai_steer` / `ai_handbrake`), with an auto
gearbox. To stop them veering they are **axis-locked to a straight line**:
`axis_lock_linear_x` (lateral) + `axis_lock_angular_y` (yaw) — the start heading is
always world −Z — while suspension travel (linear Y) and pitch (angular X) stay
free. They keep **collision exceptions** with the player and each other (so they
never shove the staged car), their engines are silenced, and they're **despawned at
the fade** so they cost nothing during the run. Cost is bounded: two extra cars for
~2–3 s while the player is stationary, then gone.

## Straight start lead-in (staged runs)

The queue needs straight road both ahead (for the leader's run-off) and behind (for
the trailer), but the generated track can start on a corner with no road behind the
spawn. So for staged runs `world.gd` builds a straight lead-in **without touching the
generator**: it generates the track from a point `start_lead_in_ahead_m` **ahead** of
the spawn, then `_with_start_lead_in` prepends a handle-free straight stub
`start_lead_in_behind_m` **behind** the spawn, through the spawn, to the generated
track. The road mesh, terrain flattening, `TrackProgress`, tree rejection and tire
marks all use this extended centerline; the **signs** keep using the raw generated
centerline, so the start gate sits ahead of the launch point (the cars cross it as
they pull away). Trade-offs (both small, configurable): the progress bar starts at a
few % (the spawn sits a few metres into the centerline), and the player drives the
~`ahead_m` of lead-in that the opponents' par time doesn't include (negligible vs the
rival pace band). The opponents' target times are derived from the raw generator and
so are unaffected.

## Wiring & lifecycle

`world.gd._should_stage()` decides whether a run opens with the start line: a session
run **and** `start_line_enabled` **and** a resolvable rally (so a missing rally never
strands the car in `STAGING`). When true, `world.gd` sets up the `StageManager`
`staged`, builds the lead-in, and builds the `StartLine` after generation, handing it
the `$ChaseCamera`, `$HUD` and `$MobileControls` to restore at the fade. Each event
reloads `main.tscn`, so the `StartLine` is created fresh per event and freed with the
scene. A plain dev boot (no session) never builds a `StartLine`, gets no lead-in, and
the countdown arms immediately.

## Config knobs

| Field | Default | Purpose |
|-------|---------|---------|
| `start_line_enabled` | `true` | Run the start-line sequence in a session. Off → straight to the countdown. |
| `start_orbit_speed` | `0.5` | Orbit camera angular speed (rad/s) during the reveal. |
| `start_orbit_radius` | `7.0` | Orbit camera radius (m) from the car. |
| `start_orbit_height` | `2.4` | Orbit camera height (m) above the car. |
| `start_queue_gap` | `7.0` | Gap (m) between queued cars along the start heading. |
| `start_drive_off_seconds` | `2.0` | Length of the drive-off animation before the fade. |
| `start_trailer_scoot_seconds` | `0.7` | How long the trailer holds throttle before easing off. |
| `start_fade_seconds` | `0.6` | Length of each half (out, back) of the fade. |
| `start_lead_in_ahead_m` | `22.0` | Straight road forced ahead of the start line (staged runs). |
| `start_lead_in_behind_m` | `12.0` | Straight road extended behind the start line (staged runs). |

See [configuration.md](configuration.md).

## Tests

- `tests/headless/test_start_line.gd` — the reveal shows the formatted time to beat
  (and `—` when none) + context, hides the HUD and takes the camera; the queue cars
  are scripted + axis-locked + live (not frozen); `launch()` floors the leader and
  starts the drive-off (not the countdown); after the drive-off + fade the camera/UI
  hand back and `begin_countdown()` fires exactly once (idempotent).
- `tests/headless/test_rally_session.gd` — `current_event_target_ms()` returns the
  fastest non-DNF rival's time for the current event and tracks the event index.
- `tests/headless/test_stage_manager.gd` — the `STAGING` phase holds until
  `begin_countdown()`, which is a no-op outside `STAGING`.
