# Bonnet Camera + Camera Cycling — Design

**Date:** 2026-06-17

## Goal

Add a bonnet (hood) camera and let the player cycle camera views with the `C`
key. The bonnet camera is rigid to the car's heading (classic hood-cam: it
turns with the car, no smoothing, no drift-awareness).

## Background

The project currently has a single camera: a chase camera
(`scripts/chase_camera.gd` on the `ChaseCamera` `Camera3D` node in `main.tscn`)
that follows the car's *direction of travel*. There is no camera-switching
infrastructure and no camera-related input action. `world.gd:cycle_car()`
re-points the chase camera's `target` when the active car changes.

## Approach

Use Godot's idiomatic multi-camera pattern: multiple `Camera3D` nodes, with the
active one selected via `Camera3D.current`. A small manager node owns the cycle
order and the key handling.

### 1. Input action

Add `cycle_camera` (key `C`) to the `[input]` section of `project.godot`,
following the existing action definitions.

### 2. BonnetCamera node

A new `Camera3D` parented under the active car (near the Cabin), positioned at a
bonnet offset (~`0, 0.7, -0.6`, looking forward along `-Z`). Because it is a
child of the car, it is automatically rigid to the car's heading — no per-frame
script needed for the "follows heading" behavior.

Configuration lives in `GameConfig` (per the project's config-driven rule):
- `bonnet_offset: Vector3` — local offset of the camera on the car.
- `bonnet_fov: float` — field of view for the bonnet view.

These are added to `scripts/game_config.gd` (`@export_group("Camera")`) and
`config/game_config.tres`. Scene/script literals are fallback defaults only.

### 3. CameraManager

New `scripts/camera_manager.gd` on a node in `main.tscn`. Responsibilities:
- Holds an ordered list of camera modes: `[CHASE, BONNET]` with a current index.
- On the `cycle_camera` action (pressed), advances the index (wrapping) and sets
  the corresponding camera's `current = true`. Exactly one camera is active at
  any time.
- Designed so adding a future mode is just appending to the ordered list.

### 4. Multi-car handling

The bonnet camera is parented to a car, so when the active car changes the
manager re-parents/re-positions the bonnet camera onto the new active car. Car
switching is routed through (or notifies) the manager so both the chase camera's
`target` and the bonnet camera's parent track the active car.

## Testing

- New headless test in `tests/headless/` asserting:
  - the `cycle_camera` input action exists,
  - cycling advances the mode and exactly one `Camera3D` has `current == true`,
  - the bonnet camera is parented to / positioned relative to the active car at
    the configured offset.
- Update `tests/headless/test_smoke.gd` for the new node(s).
- Update `features/camera.md` to document both camera modes and the cycle key.

## Trade-offs

Parenting `BonnetCamera` to the car (vs. a script copying the car transform each
frame) gives rigid-to-heading behavior for free and is simpler, at the cost of a
re-parent step on car-switch. Chosen for less code and no per-frame work.

## Out of scope (YAGNI)

- Additional camera angles beyond chase + bonnet (the design leaves room to add
  them, but none are built now).
- Free-look / orbit / mouse-controlled cameras.
- Per-camera tuning UI.
