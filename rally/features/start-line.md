# Pre-event Start Line

**Source:** `scripts/start_line.gd` (`class_name StartLine extends Node3D`), created
and wired by `scripts/world.gd` for staged session runs. Holds the
[`StageManager`](stage.md) in its `STAGING` phase and launches it after a cinematic
reveal. Uses the scripted-control hook on [`car.gd`](car-physics.md) for the queue cars.

The diegetic sequence between picking a car in HQ and the `3·2·1·GO` countdown
(`todo/menus.md` location 2). It runs **inside the live run scene** (`main.tscn`)
once the world is built and a [`RallySession`](rally-session.md) is active, while the
car is held locked. Three phases, driven in `_process`:

1. **REVEAL (orbit)** — **design-system** (`UITheme`) black house panels show the
   times to beat: the **top three rivals** for this stage, fastest first, each as
   `P{n}  Driver — Car — m:ss.cc` (`RallySession.current_event_leaders(3)`; the leader
   is the gold **time to beat**, the chasers are dimmed, the car is dropped when
   unknown, and a single `—` stands in when no rival has a time yet). The panels follow
   the house rules (pure-black, uppercase, one font size). The times card **hugs the top
   edge** and a bare **Start** button (a standard house menu button at the fixed row
   height — no wrapping panel) **hugs the bottom**, with an expanding gap between — so
   they never cover the orbiting car, which shows through the **clear centre band**. The
   times card is headed by the `Rally — Event N of 3` line. Behind it an **orbit camera**
   circles the car, which is queued
   between a **leader** car ahead and a **trailing** car behind. The driving HUD +
   mobile controls are hidden. Launch with the button, `menu_select` (Enter / gamepad
   A), or a tap.
2. **DRIVE-OFF (launch)** — a **staggered rolling start**: the leader (sitting **on the
   line**) pulls away first, then one `start_queue_stagger_seconds` later the **player
   rolls up** to the line, then another stagger later the **trailer** rolls up to where
   the player started (a gap behind the line). The player and trailer each drive forward
   while well behind their slot, coast into a speed-aware brake point, then **brake to a
   complete stop** on it (rather than flooring it for a fixed window and coasting past).
   The overlay hides. The fade does **not** start until the player has rolled up and
   come to a **complete stop** (`STOP_SPEED_EPS`), so the chase-cam cut never happens
   mid-roll; `start_drive_off_seconds` is a safety cap.
3. **FADE** — the screen **fades to black** (`start_fade_seconds`); at full black the
   player is released to normal driving, the queue cars are despawned, the camera
   hands back to the **chase camera**, the **driving UI returns**, and
   `StageManager.begin_countdown()` starts the countdown; then it **fades back in**.

The cars are **flavour only — NOT the real opponent field** (that's `RallyLibrary`'s
per-seed roster, surfaced in the standings).

## Physically-simulated cars (rolling start)

The leader, trailer **and the player** drive under real physics during the roll-up,
so they load their suspension (squat / weight transfer) instead of sliding. They run
full physics but read **scripted control** instead of player Input via the `car.gd`
hook (`ai_controlled` + `ai_throttle` / `ai_steer` / `ai_handbrake`), with an auto
gearbox, and are **axis-locked to a straight line** (`axis_lock_linear_x` lateral +
`axis_lock_angular_y` yaw — the start heading is always world −Z — leaving suspension
linear-Y and pitch angular-X free) so they can't veer.

The **leader** sits **on the start line** and drives off down the lead-in, so it
actually starts from the line rather than spawning past it. The **player** is staged a
full `start_queue_gap` behind it (directly in the leader's old slot's queue) and rolls
the whole gap up to the line — so it travels a meaningful distance before braking —
while the **trailer**, staged a gap behind the player (two gaps behind the line), rolls
up to where the player started and **brakes to a stop** there too (so it doesn't coast
through and drift). At the fade the player is **released** — AI override and axis locks
cleared, gearbox-auto restored — so the run drives normally. The `StageManager` keeps it
locked through the countdown, so it holds at the line until GO. The player ends near
the line; track progress projects onto the lead-in, so the exact stop doesn't matter.

The two queue cars keep **collision exceptions** with the player and each other (so
they never shove it), engines silenced, and are **despawned at the fade** so they
cost nothing during the run. Cost is bounded: a couple of extra cars for ~2–3 s while
the player is otherwise stationary, then gone.

## Straight start lead-in (staged runs)

The queue needs straight road both ahead (for the leader's run-off) and behind (for
the trailer), but the generated track can start on a corner with no road behind the
spawn. So for staged runs `world.gd` generates the track from a point
`start_lead_in_ahead_m` **ahead** of the spawn, then `_with_start_lead_in` prepends a
handle-free straight stub `start_lead_in_behind_m` **behind** the spawn, through the
spawn, to the generated track. The road mesh, terrain flattening, `TrackProgress`,
tree rejection and tire marks all use this extended centerline; the **signs** keep
using the raw generated centerline, so the start gate sits ahead of the launch point
(the cars cross it as they pull away).

So the search doesn't loop the track back across that lead-in stub, `world.gd`
**reserves** the whole lead-in corridor in the generator — it passes
`reserve_behind_m = start_lead_in_ahead_m + start_lead_in_behind_m`, which
pre-occupies a straight corridor behind the generation start (see
[track.md](track.md)). Because the reservation is relative to the start frame, the
generated track SHAPE stays a pure function of `(seed, turn_count, width, reserve)`;
`RallySession._compute_event_targets` passes the **same** reserve at its canonical
pose, so the opponents' derived target times match the track the player actually
drives. Trade-offs (both small, configurable): the progress bar starts at a few %
(the spawn sits a few metres into the centerline), and the player drives the
~`ahead_m` of lead-in that the par time doesn't include (negligible vs the rival
pace band).

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
| `start_drive_off_seconds` | `5.0` | Safety cap on the drive-off; the fade normally waits for the player to roll the full gap up and fully stop. |
| `start_trailer_scoot_seconds` | `0.7` | Minimum roll-up window after the player's stagger before the fade may begin (it also waits for a complete stop). |
| `start_queue_stagger_seconds` | `0.35` | Delay between successive cars launching (leader → player → trailer). |
| `start_fade_seconds` | `0.6` | Length of each half (out, back) of the fade. |
| `start_lead_in_ahead_m` | `22.0` | Straight road forced ahead of the start line (staged runs). |
| `start_lead_in_behind_m` | `20.0` | Straight road extended behind the start line, for the staged player (a gap back) + trailer (two gaps back). |

See [configuration.md](configuration.md).

## Tests

- `tests/headless/test_start_line.gd` — the reveal lists the top three rivals to beat
  with each driver's name, car and time (and a single `—` when none) + context, hides
  the HUD and takes the camera; the queue cars are scripted + axis-locked + live (not
  frozen); the player is staged a full gap behind and scripted, `launch()` floors the
  leader, the player rolls up after its stagger, the trailer rolls up after its later
  stagger and brakes to a stop on its slot, the fade waits for the player to come to a
  complete stop, and after the drive-off + fade the player is released to normal
  driving and `begin_countdown()` fires exactly once (idempotent).
- `tests/headless/test_rally_session.gd` — `current_event_target_ms()` returns the
  fastest non-DNF rival's time for the current event and tracks the event index;
  `current_event_leaders()` returns the top three rivals (fastest first, with their
  cars, DNF-this-event omitted) for the start-line reveal.
- `tests/headless/test_stage_manager.gd` — the `STAGING` phase holds until
  `begin_countdown()`, which is a no-op outside `STAGING`.
