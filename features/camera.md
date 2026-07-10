# Cameras

The game has two camera modes, cycled with the **C key** (`cycle_camera`
action) or picked directly on the **settings page** (title-screen Settings or the
in-run pause menu — see [menus.md](menus.md)). A `CameraManager` node
(`scripts/camera_manager.gd`, `class_name CameraManager`) in `main.tscn` owns the
ordered cycle list `[CHASE, BONNET]` and makes exactly one camera `current` at a
time. Appending another `Camera3D` + `Mode` entry to its `ORDER` list extends the
cycle.

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
the **start-line reveal**'s orbiting camera (`scripts/start_line.gd`) — and must hand
control back at the fade. The hand-off goes through the manager (not a hard-coded
chase camera), so a player who picked **bonnet** keeps it through the start line
instead of being snapped back to chase every stage.

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
(via a `height_at` sibling — the hilly `Floor`) and sits `follow_height` above
that. So the camera keeps a constant clearance over the ground it is flying
over, rather than rising and falling as the car climbs and descends hills. On
flat test fixtures (no `height_at` sibling) the ground height falls back to 0.

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
position.y = ground_height_at(position.xz) + follow_height    # fixed clearance over terrain
look_at(target.position, UP)                 # exact — look-at is NOT smoothed
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

### Exported / config

- `target: Node3D` — the node to follow (set in the scene to `Car`).
- `follow_distance` (6.0 m), `follow_height` (3.0 m) — read from `Config.data`.
- `smoothing` (5.0) — rate at which the camera's orbital position eases toward
  the travel direction; higher snaps faster, lower is more languid. The look-at
  is unaffected. See [configuration.md](configuration.md).
- `chase_fov` (100.0) — base field of view at a standstill.
- `chase_fov_speed_boost` (15.0) — extra FOV degrees added at full speed.
- `chase_fov_speed` (55.0 m/s) — speed at which the full boost is reached.
- `chase_fov_smoothing` (4.0) — easing rate for FOV changes.
- `chase_dolly_mix` (0–1) — how strongly the follow distance is pulled in to
  counteract the speed FOV (0 = distance fixed, 1 = full dolly zoom holding the
  car's on-screen size).

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

The `CameraManager` applies these on `_ready()` and re-applies them when the
active car is swapped: `world.gd:cycle_car()` parks the bonnet camera on the
world root while the old car is freed, then `CameraManager.retarget(fresh)`
re-parents it onto the new car (and re-points the chase camera's `target`).
