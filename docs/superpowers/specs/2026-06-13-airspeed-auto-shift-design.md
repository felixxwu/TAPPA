# Airspeed-based auto-shifting

## Problem

The automatic gearbox (`EngineSim.update_auto`) chose gears from engine
flywheel RPM (`rpm()`). Under wheelspin from a standstill the flywheel revs
climb while the car barely moves, so the box upshifted through the gears
unnecessarily. Shift decisions should track the vehicle's actual forward
ground speed, not engine revs.

## Approach: per-gear redline-speed thresholds on airspeed

For each gear, precompute the forward ground speed at which the gear reaches a
fraction of redline rpm. The box upshifts on reaching that speed and downshifts
below a hysteresis gap under the lower gear's threshold.

A torque-crossover ("shift where the next gear out-pulls the current one") was
prototyped first but rejected: with this car's wide ratio gaps and shallow
torque curve, every crossover lands right at the rev limiter — a speed the car
can never reach (it hits the limiter at ~94% of the no-slip redline speed
because of steady-state wheel slip), so it stuck in gear. A plain
redline-fraction threshold is simpler and always reachable.

### Precomputed thresholds

For gear `g`, redline speed (no slip):
`redline_v(g) = redline_omega / (|gear_ratios[g-1]| * final_drive) * wheel_radius`

- `shift_up_speeds[g-1]` for `g` in `1 .. N-1`:
  `redline_v(g) * upshift_redline_fraction`. The top gear's slot is `INF`.
- downshift threshold for gear `g` (`g` in `2 .. N`):
  `shift_up_speeds[g-2] * (1 - shift_hysteresis)`.

`upshift_redline_fraction` must sit below the steady-state ground/redline-speed
ratio (~0.94 here, the full-power wheel-slip gap) or the car never reaches the
point. Default `0.90`, which lands the next gear near peak torque.

Computed once in `EngineSim._init`.

### Shift logic

`update_auto(throttle, airspeed)`:

- upshift if `gear < N` and `airspeed > shift_up_speeds[gear-1]` and `throttle > 0.1`
- downshift if `gear > 1` and `airspeed < _downshift_speed(gear)`

`airspeed` is the forward ground speed `linear_velocity.dot(-basis.z)` clamped
to `>= 0`, passed from `car.gd` where `update_auto` is called.

## Config changes

In `game_config.gd`:

- remove `upshift_rpm` and `downshift_rpm`
- add `upshift_redline_fraction` (range 0.5..0.95, default `0.90`)
- add `shift_hysteresis` (range 0..1, default `0.15`)

(`config/game_config.tres` stores only overridden values and referenced none of
these, so it is unchanged — the new defaults apply.)

## Tests (`tests/headless/test_engine.gd`)

- `shift_up_speeds` are strictly increasing per gear and below each gear's
  redline speed (so reachable).
- High engine revs with zero airspeed do **not** upshift (the wheelspin case);
  airspeed past a shift point does upshift — both exercised directly through
  `update_auto`.
- `test_auto_climbs_from_a_standstill_under_power`: full-throttle launch climbs
  out of 1st within a few seconds (the regression this work fixes).
- `test_auto_upshifts_through_the_gears`: end-to-end through `car.gd`, seeded
  above the 1st→2nd shift speed, upshifts.

## Notes

- The repo is intentionally not under git, so this spec is written but not
  committed.
