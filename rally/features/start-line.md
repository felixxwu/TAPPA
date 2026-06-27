# Pre-event Start Line

**Source:** `scripts/start_line.gd` (`class_name StartLine extends Node3D`), created
and wired by `scripts/world.gd` for staged session runs. Holds the
[`StageManager`](stage.md) in its `STAGING` phase and launches it after a cinematic
reveal.

The diegetic sequence between picking a car in HQ and the `3·2·1·GO` countdown
(`todo/menus.md` location 2). It runs **inside the live run scene** (`main.tscn`)
once the world is built and a [`RallySession`](rally-session.md) is active, while the
car is held locked. Three phases, driven in `_process`:

1. **REVEAL (orbit)** — a flat overlay shows the **TIME TO BEAT** (the fastest
   non-DNF rival's time for this stage — `RallySession.current_event_target_ms()`,
   formatted `m:ss.cc`, or `—` if none) plus a `Rally — Event N of 3` subtitle and a
   **Start** button. Behind it an **orbit camera** circles the car, which is queued
   between a **leader** car ahead and a **trailing** car behind (frozen, collision-
   off, silenced car props — the HQ car-park pattern — with models picked
   deterministically from the rally seed). The driving HUD + mobile controls are
   hidden. The player launches with the button, `menu_select` (Enter / gamepad A),
   or a tap.
2. **DRIVE-OFF (launch)** — the leader **drives off** up the road and the trailing
   car **scoots up** toward the line over `start_drive_off_seconds` (eased). The
   overlay hides.
3. **FADE** — the screen **fades to black** (`start_fade_seconds`); at full black
   the camera hands back to the **chase camera**, the **driving UI returns**, and
   `StageManager.begin_countdown()` starts the countdown; then it **fades back in**.

The player car never moves during the sequence (it stays at its spawn = the start
line, so track progress lines up); only the two atmosphere cars animate. They are
**flavour only — NOT the real opponent field** (that's `RallyLibrary`'s per-seed
roster, surfaced in the standings).

## Launch / idempotency

`launch()` only fires from the waiting `ORBIT` phase, so the Start button, a key,
and a tap can't double-trigger, and a stray input during the animation is ignored.
`begin_countdown()` is itself a no-op outside `STAGING`.

## Wiring & lifecycle

`world.gd._should_stage()` decides whether a run opens with the start line: a session
run **and** `start_line_enabled` **and** a resolvable rally (so a missing rally never
strands the car in `STAGING` with nothing to launch it). When true, `world.gd` sets
up the `StageManager` `staged` (it waits in `STAGING`) and builds the `StartLine`
after the world is generated, handing it the `$ChaseCamera`, `$HUD` and
`$MobileControls` to restore at the fade. Each rally event reloads `main.tscn`, so
the `StartLine` is created fresh per event and freed with the scene. A plain dev boot
of `main.tscn` (no session) never builds a `StartLine` and the countdown arms
immediately.

## Config knobs

| Field | Default | Purpose |
|-------|---------|---------|
| `start_line_enabled` | `true` | Run the start-line sequence in a session. Off → straight to the countdown. |
| `start_orbit_speed` | `0.5` | Orbit camera angular speed (rad/s) during the reveal. |
| `start_orbit_radius` | `7.0` | Orbit camera radius (m) from the car. |
| `start_orbit_height` | `2.4` | Orbit camera height (m) above the car. |
| `start_queue_gap` | `7.0` | Gap (m) between queued cars along the start heading. |
| `start_drive_off_distance` | `60.0` | How far (m) the leader drives off on launch. |
| `start_drive_off_seconds` | `2.0` | Length of the drive-off / scoot-up animation. |
| `start_fade_seconds` | `0.6` | Length of each half (out, back) of the fade. |

See [configuration.md](configuration.md). The time to beat itself comes from
`RallySession.current_event_target_ms()` (the fastest rival's stage time).

## Tests

- `tests/headless/test_start_line.gd` — the reveal shows the formatted time to beat
  (and `—` when there's none) + rally/event context, hides the HUD and takes the
  camera, queues a leader + trailer; `launch()` starts the drive-off (not the
  countdown), and after the drive-off + fade the camera/UI hand back and
  `begin_countdown()` fires exactly once (idempotent).
- `tests/headless/test_rally_session.gd` — `current_event_target_ms()` returns the
  fastest non-DNF rival's time for the current event and tracks the event index.
- `tests/headless/test_stage_manager.gd` — the `STAGING` phase holds with no
  countdown until `begin_countdown()`, which is a no-op outside `STAGING`.
