# Cameras

The game has two camera modes, cycled with the **C / R keys** or the gamepad
**Y / Triangle (North)** button (`cycle_camera` action) or picked directly on the **settings page** (title-screen Settings or the
in-run pause menu — see [menus.md](menus.md)). A `CameraManager` node
(`scripts/camera_manager.gd`, `class_name CameraManager`) in `main.tscn` owns the
ordered cycle list `[CHASE, BONNET]` and makes exactly one camera `current` at a
time. Appending another `Camera3D` + `Mode` entry to its `ORDER` list extends the
cycle.

**Tests:** `tests/headless/test_camera_manager.gd`, `tests/headless/test_chase_camera_aim.gd`, `tests/headless/test_chase_camera_fov.gd`, `tests/headless/test_chase_camera_ground.gd`, `tests/headless/test_chase_camera_shake.gd`

## Persistence & the settings page

The chosen mode is **persisted** in the save profile under
`CameraManager.SETTING_KEY` (`"camera_mode"`), so whatever the player last used —
whether by cycling with C or picking it in settings — is restored on the next run
(`_ready` reads `_saved_index()`; `cycle()`/`set_mode()` write via `_persist()`).
`CameraManager.MODES` is the display metadata (name + how-to per mode) the shared
`SettingsMenu` (`scripts/settings_menu.gd`) renders. `set_mode(mode)` jumps straight
to a mode (used by the pause-menu settings, which switch the live camera the instant
you pick it via the `SettingsMenu.camera_changed` signal); `current_mode()` reports
the active mode. With no `Save` autoload (a bare-logic harness) it falls back to
chase.

`activate_current()` re-asserts the player's chosen camera as the active one. It's
used when another system temporarily took over the viewport with its own `Camera3D` —
the **start-line reveal**'s orbiting camera (`scripts/start_line.gd`), the diegetic
car picker's showroom camera (`scripts/overworld_picker.gd`, `ShowroomCamera`), and
the drive-in garage's own lift-shot camera (`scripts/overworld_garage.gd`, see
`features/overworld.md` → "The garage camera") — and must hand control back once
done. The hand-off goes through the manager (not a hard-coded chase camera), so a
player who picked **bonnet** keeps it through any of these instead of being snapped
back to chase.

## Chase camera

**Source:** `scripts/chase_camera.gd` (extends `Camera3D`). Node `ChaseCamera`
in `main.tscn`, with `target` wired to the `Car`.

A third-person follow camera that sits behind the car's **direction of
travel**. What is smoothed is *where the camera orbits to* — the direction it
sits relative to the car eases toward the travel direction instead of snapping
when the car's heading changes suddenly. The camera always looks **directly at
the car** (the look-at is not smoothed), so the target stays centred while the
viewpoint swings around gently.

The camera's **height is measured from the terrain directly below the camera**,
not from the car: it samples the ground height at its own horizontal position
(via a `height_at` sibling — the hilly `Floor`) and sits `follow_distance *
follow_height_ratio` above that (height is a multiple of the follow distance, not
an independent value). So the camera keeps a constant clearance over the ground it is flying
over, rather than rising and falling as the car climbs and descends hills. On
flat test fixtures (no `height_at` sibling) the ground height falls back to 0. The
sampled ground is **clamped up to the lake water surface** (`maxf(ground,
track_water_level_m)` in `_ground_height_at`), so over a submerged basin the camera
stays above the water instead of dunking under the lake plane (the roadside replay cam
does the same).

> The waterline is read **live from the config on every frame**, deliberately not
> cached in `_ready()`. `ChaseCamera` is a child of `main.tscn`'s root, so its
> `_ready` runs *before* `world.gd::_ready`, which is where the event's/stage's
> track params reach the live config (`DrivingContext.apply_stage_config`) — and
> where the generated waterline is reconciled back onto it (see
> [lakes.md](lakes.md) → "Dry start"). A cached copy is the *previous* run's
> waterline, which floats the camera above the car over any basin whose real water
> sits lower. Guarded by `test_chase_camera_ground`.

### Behavior (`_physics_process`)

```
target_dir = horizontal(target.linear_velocity).normalized()   # direction of motion
# below MIN_TRAVEL_SPEED (1 m/s), fall back to the car's facing direction
travel_dir = slerp(travel_dir, target_dir, 1 - exp(-smoothing * delta))  # eased orbit
# follow_distance is the EUCLIDEAN distance to the car. position.y is a fixed
# clearance over the terrain UNDER the camera, so the vertical gap dy depends on
# where the camera ends up — and the horizontal reach must shrink to compensate:
# horizontal = sqrt(follow_distance^2 - dy^2). Since dy depends on the reach and
# the reach depends on dy, it is solved with a couple of fixed-point iterations.
horizontal = sqrt(follow_distance^2 - dy^2)
position   = target.position - travel_dir * horizontal       # behind the smoothed orbit
position.y = ground_height_at(position.xz) + follow_distance * follow_height_ratio  # clearance over terrain
aim = target.position + (-target.basis.z) * half_length * chase_look_ahead_ratio
look_at(aim, UP)                             # exact — look-at is NOT smoothed
```

`travel_dir` is the smoothed orbital direction, carried between frames; while
the car is stationary or crawling it eases toward the car's facing instead of
chasing velocity noise. The `1 - exp(-rate·dt)` slerp weight keeps the easing
frame-rate independent.

**Speed FOV (dolly zoom).** The chase camera widens its field of view with
horizontal speed to sell a sense of speed. The target FOV ramps linearly from
`chase_fov` (stationary) to `chase_fov + chase_fov_speed_boost` once the car
reaches `chase_fov_speed` (m/s), and the live `fov` eases toward that target with
the same frame-rate-independent `1 - exp(-chase_fov_smoothing · dt)` weight so it
breathes in and out rather than snapping.

**Nitrous FOV punch.** On top of the speed ramp, a further **fixed**
`chase_fov_nitrous_boost` degrees are added for as long as nitrous is actually
delivering — `chase_camera.gd` → `_nitrous_delivering`, which reads the target's
`drivetrain.engine.nitrous_delivering` (EngineSim's latched held-AND-charged-AND-combusting
state, *not* the `nitrous` input action, so a dry tank or a fuel cut punches nothing).
Fixed rather than speed-scaled because nitrous is used near the top of the speed ramp,
where a proportional boost would have almost nothing left to give. It eases in and out on
the same `chase_fov_smoothing` weight, and — being an ordinary FOV change — it is dollied
like any other, so at `chase_dolly_mix > 0` the car holds its size while the world
stretches past it. Targets with no drivetrain (replay/ghost bodies, test fixtures) are
skipped. See [nitrous.md](nitrous.md).

To keep the car itself roughly the same on-screen size while the FOV breathes,
the follow distance is scaled inversely — a **dolly zoom** (Vertigo effect). An
object of fixed size subtends an angle proportional to `1/(distance · tan(fov/2))`,
so holding that product at its standstill value means the full-dolly distance is
`follow_distance · tan(chase_fov/2) / tan(fov/2)`: the wider the FOV, the closer
the camera pulls in. The background rushes past faster while the car stays put.

`chase_dolly_mix` (0–1) sets how much of that correction is applied: the effective
ratio is `lerp(1.0, tan(chase_fov/2)/tan(fov/2), chase_dolly_mix)`. At `0` the
follow distance never changes (pure FOV zoom — the car grows with speed); at `1`
it's the full dolly zoom (the car keeps its size); in between softens an
over-eager pull-in. This effective distance (not the raw `follow_distance`) is
what feeds the terrain clearance solve below.

**Per-car length.** Before the dolly ratio is applied, the target car's half
length (`Car.half_length()` — half the spec's `body.z`) is added to
`follow_distance`. The camera is placed relative to the body origin (the wheelbase
centre), so a longer car would otherwise poke its nose/tail out of frame; pushing
the camera back by half the body length keeps the whole car visible. Falls back to
no adjustment when the target doesn't expose `half_length()` (flat test fixtures).

**Aim point (`_aim_point`).** The look-at does NOT target the middle of the car —
it targets a point `chase_look_ahead_ratio × half_length()` forward along the
car's **facing** (`-basis.z`), i.e. the nose at the default `1.0`. Because the
camera sits behind the car's direction of **travel** while the aim point rides its
facing, a drift (non-zero slip angle) swings the nose off the travel axis and the
whole frame slides sideways with it — motion a centred aim can't show. Set
`chase_look_ahead_ratio = 0` to go back to aiming at the body origin; targets
without `half_length()` (flat test fixtures) always aim at the origin.

**G-force lean.** After the look-at aims the camera, it leans into the car's
acceleration for a sense of weight transfer. The acceleration is the
frame-to-frame change in the car's `linear_velocity` (`(v - prev_v)/dt`, world
space, skipped on the first frame and whenever `dt == 0` so an unpause doesn't
spike it), projected onto the car's local axes: the **lateral** component
(`accel · basis.x`) rolls the view, the **longitudinal** component
(`accel · -basis.z`) pitches it (throttle lifts the nose, braking dips it). The
target angles are `component · gain` (degrees per m/s²), clamped to
`±chase_tilt_max_deg`, and the live roll/pitch ease toward them with the same
`1 - exp(-chase_tilt_smoothing · dt)` weight as the orbit/FOV smoothing — so the
lean decays back to level once the g-forces drop. A negative gain inverts that
axis. Applied via `rotate_object_local` (pitch about local `RIGHT`, roll about
local `FORWARD`), so it composes on top of the un-smoothed look-at. The bonnet
camera is unaffected (it already inherits the car body's suspension roll/pitch).

**Camera shake.** `chase_camera.gd` → `_update_shake`, applied last, on top of the
aimed-and-leaned shot. **Rotation only, never position**: a positional shake fights the
dolly zoom (which sets the follow distance precisely so the car holds its on-screen size)
and walks a close mount through the bodywork.

Every source pushes into **one** intensity, clamped to 1, scaled by the single
`shake_max_deg` amplitude — so sources stack but simultaneous events can never multiply
into nausea, and one dial bounds how violent it can ever get. Sources come in two kinds:

- **Impulsive — the g-force term, which covers every impact in the game.** A crash, a hard
  landing, a clipped bush, a kerb strike and a spectator are all the same thing to the
  camera: one spike in the car's acceleration. So there is no per-event plumbing and nothing
  to forget to wire up when a new hazard is added. It reuses the acceleration
  `_apply_gforce_tilt` already derives (which now returns it) rather than deriving a second,
  subtly different one, and takes the **full 3D magnitude** — unlike the lean's two
  projections — because a hard landing is almost entirely vertical. Gravity is not
  subtracted: free flight reads a steady ~1 g, below any sensible `shake_g_threshold`, and
  the landing spike after it is the part that matters. Same convention as `DamageModel`'s
  deceleration rule, and `shake_g_threshold` plays the same role as `impact_threshold_g` —
  it keeps ordinary cornering and braking quiet. It charges a decaying envelope
  (`shake_decay`), because an impact is over in one tick but must be *felt* for a moment
  after. The envelope is clamped to 1 **as it charges**, not where it is read: a 300 g
  arrest would otherwise store hundreds and spend seconds decaying back down through that
  headroom with the shake pinned at full.
- **Continuous — speed, wheelspin, nitrous.** Re-read every tick and never latched, so they
  stop the instant the condition does. Speed ramps to `shake_speed_gain` at
  `chase_fov_speed` — the same reference speed the FOV ramp uses, so the two "sense of
  speed" effects cannot disagree. Wheelspin reads
  `Drivetrain.drive_wheelspin_excess()`; nitrous keys off the same latched
  `nitrous_delivering` as the FOV punch.

The oscillation is **deterministic** — three incommensurate sines per axis on a phase
accumulator, not `randf` — so a replay of a run shakes the same way and the suite can assert
on it. The per-axis frequencies differ so pitch/yaw/roll never move together, which would
read as one wobble rather than a rattle.

Only the chase camera shakes. The bonnet camera is untouched (it already rides the body's
suspension), and the replay/cinematic cameras are deliberately steady.

### Exported / config

- `target: Node3D` — the node to follow (set in the scene to `Car`).
- `follow_distance` (m) and `follow_height_ratio` (height = `follow_distance *
  follow_height_ratio`, default 1.0) — read from `Config.data`.
- `smoothing` (5.0) — rate at which the camera's orbital position eases toward
  the travel direction; higher snaps faster, lower is more languid. The look-at
  is unaffected. See [configuration.md](configuration.md).
- `chase_fov` (100.0) — base field of view at a standstill.
- `chase_fov_speed_boost` (15.0) — extra FOV degrees added at full speed.
- `chase_fov_speed` (55.0 m/s) — speed at which the full boost is reached.
- `chase_fov_nitrous_boost` — extra FOV degrees while nitrous is delivering, a
  fixed amount at any speed (0 disables it).
- `shake_max_deg` — peak shake amplitude per axis; the master switch (0 = off).
- `shake_frequency`, `shake_decay` — oscillation rate, and how fast an impulse fades.
- `shake_g_threshold`, `shake_g_gain` — the impact source: g above which it shakes,
  and how much per g of excess.
- `shake_speed_gain`, `shake_wheelspin_gain`, `shake_nitrous_gain` — the three
  continuous sources' shares of the amplitude.
- `chase_fov_smoothing` (4.0) — easing rate for FOV changes.
- `chase_dolly_mix` (0–1) — how strongly the follow distance is pulled in to
  counteract the speed FOV (0 = distance fixed, 1 = full dolly zoom holding the
  car's on-screen size).
- `chase_look_ahead_ratio` (0–2) — how far forward the look-at aims, in multiples
  of the car's half length (0 = body centre, 1 = nose).
- `chase_tilt_roll_gain` / `chase_tilt_pitch_gain` (deg per m/s²) — how far the
  view leans per unit of lateral / longitudinal acceleration; negative inverts.
- `chase_tilt_max_deg` — clamp on the g-force lean magnitude (either axis).
- `chase_tilt_smoothing` — easing rate for the lean; higher settles faster.

## Bonnet camera

**Source:** `BonnetCamera` `Camera3D` parented to the `Car` in `main.tscn`; no
per-frame script. Because it is a child of the car it is rigid to the car's
heading — a classic hood-cam that turns with the car and looks straight forward
(Godot cameras look down local `-Z`, which is the car's front).

Position and field of view come from `GameConfig`:

- `bonnet_offset` (default `Vector3(0, 0.7, -0.6)`) — local offset on the car;
  `-Z` is the front, `+Y` raises it to eye height.
- `bonnet_fov` (default `75.0`).

On top of the shared `bonnet_offset`, each `CarLibrary` entry carries a
`bonnet_cam_offset` (`Vector3`, metres, car-local; defaults to `Vector3.ZERO`) so
an individual body can nudge its hood cam to the right spot. `car.gd`'s
`bonnet_cam_offset()` returns the active car's value (zero for the untouched
baseline), and `CameraManager.refresh_bonnet_offset()` sets the bonnet camera's
origin to `bonnet_offset + bonnet_cam_offset`. Because the bonnet camera is a
scene child of `$Car` (not re-parented at boot), `world.gd` calls
`refresh_bonnet_offset()` right after fielding the car (`apply_car` /
`apply_owned`) — otherwise the per-car offset would only take effect on a later
car swap. `retarget()` (car swap) re-parents the camera and then calls
`refresh_bonnet_offset()` itself.

The `CameraManager` applies these on `_ready()` and via `retarget(fresh)`,
which re-parents the bonnet camera onto a fresh car and re-points the chase
camera's `target`.

## Replay camera (cinematic director)

**Source:** `scripts/replay_camera.gd` (`ReplayCamera`, extends `Camera3D`). Not part of
the `CameraManager` cycle — it's a **standalone camera created on demand** by
`world.gd` for the between-event standings overlay (see
[event-replay.md](event-replay.md)), not one of the player-selectable modes above.

`world._present_standings_overlay` instantiates a fresh `ReplayCamera`, calls
`setup(target, recorder, terrain, water_level)` (target = `$Car`, terrain = `$Floor`,
`water_level` = `track_water_level_m` so the roadside plant stays above any lake), and
sets `current = true`
to take over the viewport for the duration of the standings screen. A deterministic,
testable `_tick(delta)` (no RNG, no engine-clock reads) cycles through five shots
(`enum Shot { ORBIT, FLYBY, WHEEL, HIGH_WIDE, ROADSIDE }`): an orbiting shot circling the
car, a fixed offset flyby, an onboard **wheel cam** by the front wheel looking forward
down the road (its lateral mount clears the target's actual body half-width plus a
clearance margin — `GameConfig.wheel_cam_lateral_clearance` / `wheel_cam_fallback_lateral`
— rather than a fixed offset, so it never clips a wide car's body; see
[event-replay.md](event-replay.md)), a high wide establishing shot, and a planted
**roadside** "filming from the verge" shot. The four tracking shots dwell `SHOT_DWELL := 4.0` s each; ROADSIDE
instead holds a fixed trackside spot and cuts only after the car passes and drives off.
The two shots whose distance to the car varies (ROADSIDE, HIGH_WIDE) **zoom to hold the car
at a constant share of the frame** — FOV solved from the distance
(`GameConfig.replay_frame_subject_size` / `replay_frame_screen_fraction`, clamped to
`replay_frame_fov_min`/`_max`, eased at `replay_fov_smoothing` and snapped across cuts);
the fixed-offset shots just use `replay_fov`.
See [event-replay.md](event-replay.md) for the full shot list. It goes away with the
overlay once the standings screen closes (the player's chosen `CameraManager` mode
resumes on the next event / return to HQ).
