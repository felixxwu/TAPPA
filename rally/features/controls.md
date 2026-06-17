# Controls / Input Map

Defined in `project.godot` `[input]`. Handled mainly by `scripts/car.gd`; the
HUD buttons mirror the gearbox/drive-mode toggles.

| Action | Key | Alt | Effect |
|--------|-----|-----|--------|
| `accelerate` | W | ↑ | Throttle forward (reverse throttle in R gear) |
| `brake_reverse` | S | ↓ | Brake / reverse |
| `steer_left` | A | ← | Steer left |
| `steer_right` | D | → | Steer right |
| `shift_up` | E | — | Manual upshift |
| `shift_down` | Q | — | Manual downshift |
| `handbrake` | Space | — | Rear-axle handbrake (drift) |
| `toggle_gearbox` | T | — | Toggle manual / auto transmission |
| `cycle_drive_mode` | Y | — | Cycle RWD → AWD → FWD |
| `reset_car` | R | — | Teleport to start, zero velocity |
| `toggle_debug_arrows` | H | — | Show/hide force debug overlay |
| `toggle_perf_overlay` | P | — | Show/hide frame profiler overlay |

All actions use a 0.2 deadzone.

## Touch / mobile

On touch devices the same actions are driven by on-screen buttons (steer left,
steer right, throttle, brake) — see [mobile-controls.md](mobile-controls.md).

See also: [car-physics.md](car-physics.md),
[engine-and-transmission.md](engine-and-transmission.md),
[drivetrain-and-tires.md](drivetrain-and-tires.md),
[debug-tools.md](debug-tools.md).
