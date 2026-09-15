# Anti-lock braking (ABS)

Since brakes were made more powerful, hard braking can lock a wheel: brake
torque outpaces available tire traction, angular velocity gets driven to (near)
zero while ground speed is still high, and the tire model's slip ratio
saturates past `tire_slip_peak` onto the sliding plateau — full lockup, reduced
grip, no steering authority on a locked front wheel. ABS should pulse the
brake torque back off per-axle when this happens, the way a real ABS module
does, using state the tire model already computes.

## What exists now (braking/tire pipeline this builds on)

- `scripts/car.gd._resolve_drive_inputs()` (line 695) turns pedal/handbrake
  input into `brake_input` (0..1), already scaled by
  `longitudinal_demand_scale` (car.gd:903, called at car.gd:773-776) so
  braking + steering share one friction budget on the steered axle.
  `drivetrain.step(delta, drive, brake_input, handbrake, declutch)`
  (car.gd:605) is the hand-off.
- `scripts/drivetrain.gd.step()` (line 217) is the real per-tick model:
  - `total_brake = brake * cfg.brake_torque * 2.0`, split front/rear via
    `cfg.brake_bias` into `front_brake` (per FRONT WHEEL, not a per-axle
    total — drivetrain.gd:274) / `rear_brake` (drivetrain.gd:275, which
    ALREADY sums the foot-brake share with `handbrake_torque` when handbrake
    is held — the two aren't separated in the current code).
  - Per substep, brake torque is applied by `move_toward(omega, 0.0,
    brake_torque / inertia * h)` on each axle's angular velocity
    (drivetrain.gd:314-352). **This branches by drive mode**: RWD keeps
    `front_omega` genuinely per-wheel (348-352); FWD runs the fronts as a
    locked spool (336-344); AWD with handbrake locks only the rear
    (318-324); AWD without handbrake folds front+rear into a single combined
    inertia with one `move_toward` (326-335) — the centre diff means front
    and rear can't be modulated independently there without opening it.
    `rear_omega` is always a single float (locked/diff-less rear axle).
  - `_tire_force()` (line 673) computes each wheel's `WheelContact`
    (`WheelContact` class, lines 65-103), including signed `slip_long_norm`
    (fore/aft slip only) and `slip_use` (`grip_fraction` on the COMBINED
    traction-ellipse magnitude, line 492/696) — `slip_use` is NOT a lockup
    signal by itself, since it also rises from pure cornering slip. The pure
    longitudinal reading is `grip_fraction(absf(c.slip_long_norm),
    c.slip_peak)` (`wheel_long_grip_usage`, ~line 542), with
    `slip_long_norm < 0` meaning the wheel is slower than the ground
    (locking under braking, as opposed to wheelspin).
- `scripts/game_config.gd` (not under `config/`): `brake_torque` (line 45,
  1500 N·m/axle default), `handbrake_torque` (line 46, 5000 N·m rear),
  `brake_bias` (line 493, 0.5, retunable per car), `tire_slip_peak` (line
  399, 0.15, plus surface-specific `tarmac_slip_peak` / `gravel_slip_peak` /
  `grass_slip_peak`), `sliding_grip_ratio` (line 408, grip floor once past
  peak). "Big brakes" upgrade multiplies `brake_torque` via
  `run_boost_brake_mult` (game_config.gd:4142).

## Approach

Modulate the brake torque actually applied to each axle inside
`drivetrain.gd.step()`'s substep loop, right before the `move_toward(omega,
0.0, ...)` calls (314-352) — not a separate system bolted on top:

1. Each substep, use the SIGNED longitudinal slip only —
   `wheel_long_grip_usage`-style `grip_fraction(absf(c.slip_long_norm),
   c.slip_peak)` with `slip_long_norm < 0` (wheel slower than ground) — to
   detect lockup. **Do not use `slip_use`**: it's `grip_fraction` on the
   combined traction-ellipse magnitude, so it rises from pure cornering slip
   too and would falsely trigger ABS mid-corner with no braking involved.
2. If a wheel is past its slip peak on the braking side, release brake torque
   for it this substep (scale down by an `abs_release_ratio` rather than a
   hard cut to 0 — real ABS pulses). Reapply once slip drops back under the
   peak, with a hysteresis margin (`abs_slip_margin`) between release and
   reapply thresholds — without it, a several-hundred-Hz bang-bang controller
   re-triggering every substep will chatter and read as mush rather than a
   clean pulse.
3. Per-wheel granularity depends on drive mode, since `front_omega` is only
   genuinely per-wheel in the RWD branch (drivetrain.gd:348-352):
   - **RWD**: front ABS can release each front wheel independently.
   - **FWD**: fronts are a locked spool (336-344) — ABS is axle-level there.
   - **AWD + handbrake**: only the rear locks (318-324) — same as above for
     rear.
   - **AWD without handbrake**: front+rear share one combined inertia with a
     single `move_toward` (326-335) via the centre diff — ABS can only act
     axle-pair-level here without opening the diff, which is out of scope.
   - **Rear** (`rear_omega`) is always a single float — axle-level ABS only,
     matching the existing diff-less rear model.
4. `rear_brake` (drivetrain.gd:275) already sums foot-brake share with
   `handbrake_torque`; keeping ABS off the handbrake (see open questions)
   requires splitting that sum apart, not just gating on `handbrake` bool —
   flag this as real implementation work, not a one-line exclusion.
5. Gate ABS behind a car/upgrade flag rather than making it universal, mirroring
   the existing "Big brakes" `brake_torque` upgrade multiplier pattern
   (`run_boost_brake_mult`, game_config.gd:4142) — decide with the user
   whether it's a tiered unlock or on by default for all cars before
   implementing. AI drivers brake through the identical path (`ai_throttle`
   → `_axis_input`, car.gd:698, → same `brake_input`), so whatever gate is
   chosen applies to AI cars automatically based on their own car config.
6. `longitudinal_demand_scale` (car.gd:773-776, function at car.gd:903)
   already bleeds off `brake_input` on the steered axle when the player is
   also steering hard. Decide whether ABS release stacks on top of that
   (double-reducing front brake torque) or supersedes it for the front axle
   while ABS is actively releasing.
7. Add a low-speed floor (`abs_min_speed`) below which ABS is inert, so it
   doesn't fight the parking/finish-line brake_hold stiction logic
   (car.gd:723, 737, 749, which sets `brake_input = 1.0` at standstill).

## Open questions (resolve before implementing)

- Pulse frequency / release ratio: tune as `GameConfig` fields
  (`abs_release_ratio`, `abs_slip_margin`, `abs_min_speed`) rather than
  hardcoded constants, per the "tunables live in game_config.tres" project
  rule.
- Should ABS engagement have an audible/visual tell (chatter sound, brake
  light flicker) so the player can feel it working, or should it be silent?
- Does ABS apply to handbrake-triggered rear lockup, or is handbrake lockup
  intentional (handbrake turns/drifting rely on the rear locking)? Likely: ABS
  should NOT touch `handbrake_torque` — only the pedal-brake share of
  `rear_brake` (see approach step 4, this needs the sum split apart first).

## Testing note (for the implementation, not this spec)

Tests must assert BEHAVIOUR, not pin tunable values — e.g. "with ABS on, a
hard brake from speed keeps `|slip_long_norm|` under the sliding plateau" or
"ABS never modulates handbrake torque," never a specific
`abs_release_ratio`/`abs_slip_margin` number, per the project's
never-test-tunables rule.

## Docs to update alongside implementation

`features/drivetrain-and-tires.md` and `features/car-physics.md` (plus
whichever file documents tunables), per the project's "update `features/` in
the same piece of work" rule.

## Dependencies

None — builds entirely on the existing tire-slip/`WheelContact` model and
`brake_torque`/`brake_bias` config fields already in place.
