# Engine type presets

Config-selectable engine character (sound + performance): i4, i5, i6, v6, v8, v10, v12.

## Decisions

- **Scope:** sound *and* performance. Each preset sets cylinder count, firing
  angles, redline, peak torque, and peak-torque rpm.
- **Control:** inspector-only (`@export_enum` in `GameConfig`). No in-game key,
  no HUD readout.
- **Presets win:** the previous individual sliders for `engine_cylinders`,
  `engine_firing_angles`, `redline_rpm`, `peak_torque`, `peak_torque_rpm` are
  removed as `@export`s and folded into the preset table. The `.tres`
  `redline_rpm = 8000` line becomes inert.

## Implementation

In `scripts/game_config.gd`:

- `const ENGINE_PRESETS: Array[Dictionary]` — one entry per type, in enum order,
  each `{cylinders, firing_angles, redline_rpm, peak_torque, peak_torque_rpm}`.
  Sound character is carried by cylinder count + firing-angle evenness (even →
  smooth, uneven → burble), per the existing `engine_firing_phases()` contract.
- `@export_enum("i4","i5","i6","v6","v8","v10","v12") var engine_type := 0`
  with a setter that copies the chosen preset into plain (non-exported, still
  writable) backing vars `engine_cylinders`, `engine_firing_angles`,
  `redline_rpm`, `peak_torque`, `peak_torque_rpm`.
- `_init()` applies the default (i4) so `GameConfig.new()` is fully populated
  before the loader assigns `engine_type`.

All existing readers (`engine.gd`, `engine_audio_synth.gd`, tests) keep reading
those names as properties — unchanged.

### Starting preset table (performance values are tunable starting points)

| type | cyl | firing      | redline | peak_tq | tq_rpm |
|------|-----|-------------|---------|---------|--------|
| i4   | 4   | even 180°   | 8000    | 24      | 4500   |
| i5   | 5   | even 144°   | 7500    | 30      | 4200   |
| i6   | 6   | even 120°   | 7500    | 36      | 4800   |
| v6   | 6   | uneven      | 7000    | 34      | 4000   |
| v8   | 8   | uneven (X)  | 7000    | 50      | 4200   |
| v10  | 10  | even 72°    | 8500    | 45      | 6000   |
| v12  | 12  | even 60°    | 8000    | 60      | 5500   |

i4 reproduces today's effective values.

## Tests

- Update `tests/headless/test_config_applied.gd`: drop the
  `peak_torque`-is-a-range-slider assertions (slider intentionally removed);
  assert `engine_type` exists as an enum property instead.
- New `tests/headless/test_engine_type.gd`:
  - default (`engine_type = 0`) yields i4 values;
  - selecting each preset applies its cylinders/firing/redline/peak_torque;
  - even presets (i6, v12) produce evenly-spaced firing phases; uneven presets
    (v6, v8) produce unevenly-spaced phases.

## Out of scope

In-game toggle key, HUD readout, per-preset gear ratios / inertia / idle tuning.
