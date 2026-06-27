# Controls / Input Map

Defined in `project.godot` `[input]`. Handled mainly by `scripts/car.gd`; the
HUD buttons mirror the gearbox/drive-mode toggles.

| Action | Key | Alt | Controller | Effect |
|--------|-----|-----|------------|--------|
| `accelerate` | W | ↑ | Right Trigger (RT/R2) | Throttle forward (reverse throttle in R gear) |
| `brake_reverse` | S | ↓ | Left Trigger (LT/L2) | Brake / reverse |
| `steer_left` | A | ← | Left stick ← | Steer left |
| `steer_right` | D | → | Left stick → | Steer right |
| `shift_up` | E | — | Right bumper (RB/R1) | Manual upshift |
| `shift_down` | Q | — | Left bumper (LB/L1) | Manual downshift |
| `handbrake` | Space | — | A / Cross (South) | Rear-axle handbrake (drift) |
| `toggle_gearbox` | T | — | X / Square (West) | Toggle manual / auto transmission |
| `cycle_drive_mode` | Y | — | D-pad Up | Cycle RWD → AWD → FWD |
| `reset_car` | R | — | Y / Triangle (North) | Teleport to start, zero velocity |
| `cycle_camera` | C | — | B / Circle (East) | Cycle through cameras |
| `toggle_debug_arrows` | H | — | — | Show/hide force debug overlay |
| `toggle_perf_overlay` | P | — | — | Show/hide frame profiler overlay |

All actions use a 0.2 deadzone.

## Controller (gamepad)

The standard racing layout maps to any Godot-recognised gamepad (Xbox / Steam
Deck / PlayStation, button glyphs follow the SDL standard layout):

- **Throttle / brake on the analog triggers** — RT accelerates, LT brakes /
  reverses. Because `car.gd` reads them through `Input.get_axis(...)`, trigger
  pressure gives *proportional* throttle and braking, not on/off.
- **Steering on the left stick X axis** — also read via `get_axis`, so stick
  deflection steers proportionally (the 0.2 deadzone ignores stick drift).
- **Bumpers are the shift paddles** (manual gearbox), face buttons cover the
  remaining toggles, and the D-pad cycles drive mode.

The debug overlays (`toggle_debug_arrows`, `toggle_perf_overlay`) are
intentionally keyboard-only.

## Touch / mobile

On touch devices the same actions are driven by on-screen controls: stacked
gas/brake pedals (bottom-right) and an analog steering slider that recentres on
release (bottom-left) — see [mobile-controls.md](mobile-controls.md).

See also: [car-physics.md](car-physics.md),
[engine-and-transmission.md](engine-and-transmission.md),
[drivetrain-and-tires.md](drivetrain-and-tires.md),
[debug-tools.md](debug-tools.md).
