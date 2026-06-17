# Gears, clutch and RPM UI — design

Approved 2026-06-13. Option chosen: real engine flywheel + simple clutch
(no stalling), manual up/down shifts with auto-clutch, automatic reverse,
text RPM/gear readout on the existing HUD.

## Engine + gearbox (`scripts/engine.gd`, `EngineSim`, owned by `Drivetrain`)

- State: `omega` (engine rad/s), `gear` (0 = reverse, 1..N forward),
  `shift_timer`.
- Crank torque from a curve over RPM: 50% of peak at 0 RPM rising linearly to
  100% at `peak_torque_rpm`, falling to 70% at `redline_rpm`, zero above
  (rev limiter). At zero throttle, `engine_braking` drags the crank.
- No stalling: `omega` is clamped to `[idle_rpm, redline_rpm * 1.02]`.
- Supersedes the old `engine_force` / `engine_power` sliders (removed).

## Clutch

Runs inside the drivetrain's existing spin substeps. Per substep the clutch
transmits the torque that would zero the engine↔gearbox-input slip in one
substep (the same stability-cap trick the tire model uses), clamped to
`clutch_max_torque`. Auto-clutch disengages when:
- a shift is in progress (`shift_timer > 0`),
- coasting below `clutch_engage_speed` at zero throttle (no idle creep, so
  the car still settles at rest), or
- the gearbox input is over redline (money-shift forgiveness; also keeps
  high-speed coast tests meaningful).

## Shifting + reverse

- New input actions `shift_up` (E) / `shift_down` (Q), handled in `car.gd`;
  a shift swaps the ratio and opens the clutch + cuts throttle for
  `shift_time`.
- Reverse stays automatic: `S` while not rolling forward selects the reverse
  ratio at near-stop; `W` selects 1st back. Drive torque only flows when the
  selected gear's direction matches the throttle sign — otherwise brake.

## Config (`GameConfig`, group "Engine & Transmission")

`idle_rpm 900`, `redline_rpm 7000`, `peak_torque 24`, `peak_torque_rpm 4500`,
`engine_inertia 0.01`, `gear_ratios [6.0, 4.0, 2.9, 2.2, 1.2]`,
`reverse_ratio 6.0`, `final_drive 4.0`, `clutch_max_torque 250`,
`clutch_engage_speed 4.0`, `shift_time 0.25`, `engine_braking 3` (now at the
crank, multiplied by gearing). Torque is balanced against grip (~103 N·m at
the rear axle) so 1st (total ratio 24) spins the tires and 5th (4.8) bogs.

## Follow-up: neutral gear + auto/manual toggle (2026-06-13)

- Gear numbering changed to `-1 = R, 0 = N, 1..N = forward`. Neutral opens
  the clutch fully (`engaged` requires `gear != 0`), so the throttle only
  revs the engine — no drive reaches the wheels.
- Manual shifting is now a sequential box `R - N - 1 - 2 ... N` via Q/E.
- `EngineSim.auto` flag (seeded from new config `auto_gearbox`, default
  manual). Auto mode upshifts above `upshift_rpm` (6000) and downshifts below
  `downshift_rpm` (2500), with reverse still auto-selected from a stop.
- UI: a clickable `ModeButton` in the HUD (focus_mode = NONE so it can't grab
  the Space/handbrake key) shows AUTO/MANUAL and toggles on click; the
  `toggle_gearbox` action (T) does the same from the keyboard. Gear label
  now renders R / N / 1..N.

## Follow-up: RWD / AWD / FWD drive modes (2026-06-13)

- `Drivetrain.drive_mode` enum (RWD/AWD/FWD), seeded from config `drive_mode`
  (default RWD). The engine now couples to a `driveline_omega()` — the driven
  axle(s)' representative spin (rear for RWD, front for FWD, open-centre-diff
  mean for AWD) — and its total wheel torque is split front/rear by
  `front_bias()` (0 / `awd_front_split` / 1). Undriven axles free-roll.
- `engine.step()`'s coupling param renamed `rear_omega` -> `driveline_omega`.
- UI: a `DriveButton` in the HUD cycles RWD -> AWD -> FWD (focus_mode = NONE),
  and the `cycle_drive_mode` action (Y) does the same from the keyboard.
- New config: `drive_mode` (enum), `awd_front_split` (0.5).
- Tests in `test_drive_mode.gd`: routing helpers per mode, the cycle wrap,
  and an FWD launch spinning the fronts while the rear free-rolls. HUD test
  for the drive button. Existing engine/drivetrain/car tests pin
  `engine.auto`/`drive_mode` in `before_each` for determinism now that the
  shipped config boots in automatic.

## Original clutch fix

Post-review fix: the clutch torque is additionally capped at what the crank
can sustain — crank torque plus the flywheel's margin above idle drained
over `FLYWHEEL_DRAIN_TIME` (0.3 s) — so the no-stall idle clamp can never
act as a free torque source (this is what made 5th-gear standstill launches
spin the wheels).

## HUD

Two more labels in the existing HUD style: gear (`R`, `1`–`5`) and RPM.
Golden image regenerated.

## Tests

- New `tests/headless/test_engine.gd`: idles at idle RPM; revs to (and is
  held at) redline in 1st; shift-up changes gear and drops RPM; launch never
  dips below idle; reverse drives the car backwards in gear 0.
- `test_engine_power_caps_top_speed` is REWRITTEN (agreed behavior change) as
  a redline-gearing top-speed test.
- `test_config_applied` engine_force/engine_power asserts replaced.
- HUD tests extended for the gear/RPM labels.
