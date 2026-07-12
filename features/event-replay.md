# Event replay (behind the standings screen)

**Sources:** `scripts/replay_recorder.gd` (`ReplayRecorder`), `scripts/replay_camera.gd`
(`ReplayCamera`), `scripts/car.gd` (`replay_playback` / `begin_replay` / `end_replay` /
`_step_replay`), `scripts/drivetrain.gd` (`replay_omega`), `scripts/world.gd`
(`_present_standings_overlay` / `_on_leaderboard_hidden_changed`), `scripts/standings.gd`
(`overlay_mode`), `scripts/rally_session.gd` (`standings_overlay_host`).

After each event, instead of cutting straight to a flat standings screen, the run world
stays alive and the just-driven lap plays back as a short cinematic behind a
transparent standings overlay — the car re-drives its own recorded run while a
`ReplayCamera` cuts between a handful of chase shots.

## `ReplayRecorder` — capture

A plain `Node` (`class_name ReplayRecorder`), one per run scene, wired to the car via
`setup(car)` (it pulls the wheel list — front wheels then rear, in stable order — off
`car.drivetrain`). `start()`/`stop()` toggle `recording`; `_physics_process` samples at
a fixed **`SAMPLE_HZ = 30.0`**, gated by an accumulator (`_accum`) so it captures at a
wall-clock cadence rather than every physics tick. Frames are kept **in memory only**
(`_frames: Array[Dictionary]`, no serialization) — the recording only needs to survive
until the following standings screen finishes.

Each captured frame (`_capture()`) is a dict:

| Key | What |
|-----|------|
| `t` | elapsed seconds since `start()` |
| `xform` | car's `global_transform` |
| `velocity` | car's `linear_velocity` |
| `rpm` | `engine.rpm()` |
| `throttle` | `engine.throttle` |
| `misfire` | `engine.misfire_level` (drives engine smoke puffs) |
| `handbrake` | `car.ai_handbrake` |
| `wheel_steer` | `PackedFloat32Array`, one entry per wheel, `wheel.steering` |
| `wheel_omega` | `PackedFloat32Array`, one entry per wheel, `drivetrain.wheel_omega(wheel)` |

`sample_at(t)` linearly interpolates between the bracketing pair of frames
(`_lerp_frame`) — transforms via `Transform3D.interpolate_with`, vectors via `lerp`,
scalars via `lerpf`, `handbrake` snapping to whichever side of the pair `t` is closer
to. `frame_count()` / `duration()` (the last frame's `t`) let callers query the
recording; a `_push_test_frame` seam lets tests inject frames without running physics.

**Lifecycle:** `world.gd` creates the recorder once (`_ensure_child("ReplayRecorder",
...)`, wired to `$Car` in `setup`) and drives it off the stage lifecycle — `start()` on
`StageManager.stage_started` (`_on_stage_started`, the GO moment), and `stop()` on
`StageManager.finish_reached` (`_on_finish_reached`), which fires the instant the car
crosses the finish (phase → `COMPLETE`). Stopping at the **crossing** — not at
`stage_completed` (the finish panel's NEXT button, which is deferred) — is deliberate:
everything after the line (the skid to a stop in the runoff, idling under the panel
until NEXT) is not part of the driven run, and recording it would tack a stationary
tail onto the replay (the car would appear to "float" at the finish for the loop's
final seconds). A redundant `stop()` right before `report_event_result` remains as a
harmless idempotent fallback. So each event gets its own fresh recording covering
exactly the GO→finish drive.

## Car playback (`replay_playback`)

`car.gd` exposes `begin_replay(recorder)` / `end_replay()` / `replay_cursor()`. Entering
replay sets `replay_playback = true`, `custom_integrator = true` (so the physics body
takes no gravity/forces and won't fall between our per-frame writes), and
`process_priority = REPLAY_PROCESS_PRIORITY` (a named const); `end_replay()` reverses all three and clears
`drivetrain.replay_omega`.

**How the body is moved (and why it's fiddly).** The `Car` is a `VehicleBody3D`
(`RigidBody3D`). Physics-server-side writes to a scripted position all fail to reach the
render/`_process` transform: assigning `global_transform` in `_physics_process` is
overridden by the server; a **frozen** body renders at its freeze pose regardless of
scripted transforms; `state.transform` in `_integrate_forces` and even
`PhysicsServer3D.body_set_state` never synced to the node for other nodes' `_process`
reads. The reliable path is to set `global_transform` in **`_process`** (the render
context) — that DOES reach the render transform and any node that reads the car in
`_process` (the chase-less cinematic `ReplayCamera`, and the terrain's chunk-load focus
`TerrainManager._process`). The catch is `_process` **order**: a reader earlier in the
tree would read the car *before* we update it (the terrain sat one node ahead, so it
saw a stale pose and loaded chunks at the finish while the car drove off over
un-generated ground). `process_priority = REPLAY_PROCESS_PRIORITY` (a named const) forces the car to process first, so
**every** observer reads the fresh pose. So:

- `_physics_process` → `_step_replay(delta)`: advances a local clock `_replay_t`, **loops**
  via `fmod(_replay_t, duration)` (the standings screen can sit open indefinitely),
  samples the recorder, and stashes `_replay_xform` + the recorded velocity. It also sets
  the script `linear_velocity` (read by systems like the tire-mark speed gate) and pins
  the engine/wheel state (below).
- `_process` applies the stashed pose: `global_transform = _replay_xform`. This is the
  authoritative visual move for the frame.
- **Pins the engine state** so the engine note and smoke read as live: `engine.omega`
  from the recorded `rpm` (`rpm * TAU / 60.0`), `engine.throttle` and
  `engine.misfire_level` copied straight from the frame. Because `engine.step()` does
  **not** run during replay, the synth's other ducking inputs (`fuel_cut`, `limiting`,
  `boost`, `omega_turbo`, `bov_event`, `antilag_active`, `shift_timer`) are **cleared to
  neutral** each tick — otherwise they'd stay frozen at whatever the car was doing at the
  finish (usually braking / rev-limiting), muffling the note for the whole replay and
  only sounding right near the end. Result: a clean rev tracking the recorded rpm
  (turbo/backfire nuance is dropped, acceptable for the replay).
- Writes each wheel's recorded `steering` value directly (visual toe/steer angle,
  including any damage-induced offset baked into the original recording).
- Builds a `wheel -> recorded_omega` map and assigns it to `drivetrain.replay_omega`
  (see below). The wheel meshes are **spun** by `drivetrain.replay_spin(delta)`, called
  from `_process` after the transform is applied — `drivetrain.step()` (which normally
  advances the visual spin) doesn't run during replay, so without this the wheels would
  sit dead-still.

Everything **not** driven by the recording stays live: the wheels' own suspension
raycasts still run every physics tick (contact + compression), so the car visually
settles onto whatever terrain the camera is currently looking at, and the particle/mark
effect systems (`wheel_particles`, `tire_marks`, `engine_smoke`) keep running off
whatever state they read each frame — most of which is now fed recorded values.

**Damage is disabled during replay.** `car.gd._integrate_forces` early-returns when
`replay_playback` is set. Otherwise the per-frame reposition along the path reads as a
huge deceleration every tick (the stale `_approach_velocity` vs the near-zero body
velocity), drains HP, and "wrecks" the ghost — firing the wreck screen and even a
spurious `RallySession.report_wreck()` DNF. The ghost
must take no damage and fell no trees, so the whole handler is skipped in replay.

### `drivetrain.replay_omega`

`drivetrain.gd`'s `wheel_omega(wheel)` — read by the wheel-spin effects
(`wheel_particles`, `tire_marks`) to decide spray/skid amount — checks
`replay_omega` first: `if not replay_omega.is_empty() and replay_omega.has(wheel): return
float(replay_omega[wheel])`. So during replay those effects see the recorded spin rate
per wheel instead of computing it from a (frozen, non-simulating) drivetrain — gravel
spray and tire marks still look plausible frame to frame instead of vanishing. Emptying
the dict in `end_replay()` restores the live-computed path.

## `ReplayCamera` — cinematic director

A small `Camera3D` subclass (`class_name ReplayCamera`) created fresh by `world.gd` for
each standings overlay (`ReplayCamera.new()`, `setup(target, recorder)`, `current = true`
to take over the viewport). It cycles through four shots
(`enum Shot { ORBIT, FLYBY, LOW_CHASE, HIGH_WIDE }`), dwelling on each for
`SHOT_DWELL := 4.0` seconds before advancing (`_shot = (_shot + 1) % Shot.size()`), all
driven by a deterministic, testable `_tick(delta)` (no RNG, no engine-clock reads):

- **ORBIT** — circles the target at radius 9 m, height +0.35 m, angle advancing at
  `0.4 rad/s` (`_orbit_angle`).
- **FLYBY** — a fixed offset `(6, 2, 6)` from the target.
- **LOW_CHASE** — parked 7 m directly behind the target's facing (`basis.z`), 1.2 m up.
- **HIGH_WIDE** — a high, pulled-back `(0, 14, 16)` establishing shot.

Every shot `look_at`s the target each frame (skipped only if the camera is already
sitting on top of it). The recorder reference is accepted by `setup` but not currently
read by `_tick` — the camera frames the car's live (replayed) position rather than
scrubbing the recording independently.

## Standings overlay presentation

Previously the between-event standings were a flat scene swap
(`standings.tscn`, opaque background). Now `world.gd` presents them as an **in-world
overlay** so the replay is visible behind the leaderboard:

- `RallySession.standings_ready` (emitted from `report_event_result`) is connected to
  `world._present_standings_overlay`, which — skipped entirely under headless runs
  (`_headless`, no display) — stops the recorder if still running, hides the HUD,
  spins up the `ReplayCamera`, puts the car into `begin_replay`, and instantiates
  `standings.tscn` with `overlay_mode = true` onto its own `CanvasLayer`
  (`_standings_overlay`).
- `RallySession.standings_overlay_host` is set by `world.gd` on setup
  (`not _headless`) and read by `RallySession._load_standings_scene()`, which becomes a
  **no-op** when the flag is set — the host (`world.gd`) owns showing the panel instead
  of `RallySession` changing to `standings.tscn` itself. `continue_to_next_event()`
  still changes scene as usual (to the next event, or to the podium on the final
  event).
- In `overlay_mode`, `standings.gd`'s `Background` `ColorRect` is transparent
  (alpha 0) instead of opaque `UITheme.BLACK`, and the scene does **not** connect
  `RallySession.rally_finished` itself — the live host (`world.gd`) still exists and
  owns that transition in overlay mode, unlike the flat/non-overlay scene which
  connects it because the run scene is already gone by then.
- A **hide/show leaderboard toggle** (`toggle_leaderboard()`,
  `leaderboard_hidden_changed(hidden)` signal, `leaderboard_hidden` var) lets the player
  watch the replay full-screen: hidden state rebuilds the overlay down to just a "Show
  leaderboard >" button; shown state adds a "Hide leaderboard" button next to Continue.
  See [menus.md](menus.md) for the `MenuNav` wiring of both states.
- `world._on_leaderboard_hidden_changed(hidden)` is the **engine-audio gate**: it mutes
  the car's `EngineAudio` player (`volume_db = -60.0`) while the leaderboard is shown,
  and un-mutes it (`0.0`) while hidden — so the replay is silent-but-visible behind the
  UI by default, and only sounds once the player explicitly clears the leaderboard to
  watch.

## Named limitations (this pass)

- **Pre-fallen trees**: the replay doesn't restage knocked-over trees/foliage — the
  scenery reads as it currently stands in the live world, not as it looked at the
  recorded moment.
- **No podium replay**: this cinematic only covers the between-event standings
  interstitial. The podium sequence ([menus.md](menus.md) → Podium) has its own
  reward-reveal staging and does not play back the replay.
- **Non-positional engine audio**: the engine note is muted/un-muted as a flat gate
  (see above), not spatialized to the replay camera's shifting position — it's an
  on/off cue, not a 3D-panned mix.

## Tests

`tests/headless/test_replay_recorder.gd` — sampling cadence/frame contents and
`sample_at` interpolation. `tests/headless/test_replay_playback.gd` — car
`begin_replay`/`end_replay`, the ghost taking no damage, pinned engine/wheel signals, and
looping via `fmod`. `tests/headless/test_replay_camera.gd` — deterministic shot cycling
(`_tick`) across the four shots. `tests/headless/test_replay_standings.gd` — the
overlay presentation: transparent background, hide/show toggle, and the
`standings_overlay_host` / `_load_standings_scene` no-op wiring. See
[testing.md](testing.md) for the general test-cost patterns used throughout.
