# Cameras

The game has two camera modes, cycled with the **C key** (`cycle_camera`
action). A `CameraManager` node (`scripts/camera_manager.gd`) in `main.tscn`
owns the ordered cycle list `[CHASE, BONNET]` and makes exactly one camera
`current` at a time. Appending another `Camera3D` + `Mode` entry to its `ORDER`
list extends the cycle.

## Chase camera

**Source:** `scripts/chase_camera.gd` (extends `Camera3D`). Node `ChaseCamera`
in `main.tscn`, with `target` wired to the `Car`.

A third-person follow camera that sits behind the car's **direction of
travel**. What is smoothed is *where the camera orbits to* — the direction it
sits relative to the car eases toward the travel direction instead of snapping
when the car's heading changes suddenly. The camera always looks **directly at
the car** (the look-at is not smoothed), so the target stays centred while the
viewpoint swings around gently.

### Behavior (`_physics_process`)

```
target_dir = horizontal(target.linear_velocity).normalized()   # direction of motion
# below MIN_TRAVEL_SPEED (1 m/s), fall back to the car's facing direction
travel_dir = slerp(travel_dir, target_dir, 1 - exp(-smoothing * delta))  # eased orbit
position   = target.position
           - travel_dir * follow_distance    # behind the (smoothed) orbital direction
           + UP * follow_height
look_at(target.position, UP)                 # exact — look-at is NOT smoothed
```

`travel_dir` is the smoothed orbital direction, carried between frames; while
the car is stationary or crawling it eases toward the car's facing instead of
chasing velocity noise. The `1 - exp(-rate·dt)` slerp weight keeps the easing
frame-rate independent.

### Exported / config

- `target: Node3D` — the node to follow (set in the scene to `Car`).
- `follow_distance` (6.0 m), `follow_height` (3.0 m) — read from `Config.data`.
- `smoothing` (5.0) — rate at which the camera's orbital position eases toward
  the travel direction; higher snaps faster, lower is more languid. The look-at
  is unaffected. See [configuration.md](configuration.md).

## Bonnet camera

**Source:** `BonnetCamera` `Camera3D` parented to the `Car` in `main.tscn`; no
per-frame script. Because it is a child of the car it is rigid to the car's
heading — a classic hood-cam that turns with the car and looks straight forward
(Godot cameras look down local `-Z`, which is the car's front).

Position and field of view come from `GameConfig`:

- `bonnet_offset` (default `Vector3(0, 0.7, -0.6)`) — local offset on the car;
  `-Z` is the front, `+Y` raises it to eye height.
- `bonnet_fov` (default `75.0`).

The `CameraManager` applies these on `_ready()` and re-applies them when the
active car is swapped: `world.gd:cycle_car()` parks the bonnet camera on the
world root while the old car is freed, then `CameraManager.retarget(fresh)`
re-parents it onto the new car (and re-points the chase camera's `target`).
