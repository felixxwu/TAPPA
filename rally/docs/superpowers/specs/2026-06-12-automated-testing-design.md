# Automated Testing — Design

**Date:** 2026-06-12
**Project:** rally (Godot 4.6, GL Compatibility, Jolt physics; not under git by user choice)

## Goal

Local automated tests for the PS1 car prototype covering three layers: scene
smoke checks, gameplay behavior, and visual regression — all runnable with one
command. Plus a project `CLAUDE.md` requiring future sessions to add tests with
new functionality and run the suite before claiming work done.

## Harness

- **GUT 9.x** (Godot Unit Test) installed at `addons/gut/` (release zip matching
  Godot 4.x, addon folder only). Enabled in `project.godot` editor plugins is
  NOT required for the CLI runner.
- **`run_tests.sh`** at project root:
  - Resolves the Godot binary from `$GODOT`, falling back to
    `/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot`; errors clearly
    if neither exists.
  - Pass 1 (headless): GUT CLI (`addons/gut/gut_cmdln.gd`) over `tests/headless/`.
  - Pass 2 (windowed): GUT CLI without `--headless` over `tests/visual/` — a
    real window appears for a few seconds because the dummy headless renderer
    cannot produce screenshots.
  - `--skip-visual` flag skips pass 2. `--regen-goldens` regenerates golden
    images instead of comparing (implies windowed pass).
  - Exits non-zero if either pass fails; prints a combined summary.

## Test files

### `tests/headless/test_smoke.gd`
- `main.tscn` loads and instantiates without errors.
- Key nodes exist with expected types: `Car` (VehicleBody3D) with 4
  VehicleWheel3D children (front pair `use_as_steering`, rear pair
  `use_as_traction`), `ChaseCamera` (Camera3D) with `target` wired to Car,
  `PostProcess/ColorRect` with a ShaderMaterial, `WorldEnvironment` with fog
  enabled, `Floor` (StaticBody3D).
- Both `.gdshader` files load as valid `Shader` resources with non-empty code.
- Input map contains the five actions (`accelerate`, `brake_reverse`,
  `steer_left`, `steer_right`, `reset_car`).

### `tests/headless/test_car.gd`
Instantiates `main.tscn` into the tree (physics runs headless). Simulates
input via `Input.action_press()` / `Input.action_release()` (valid because
`car.gd` polls `Input`), awaits physics frames between phases. Asserts:
- **Settle:** after ~60 physics frames idle, the car rests near its spawn
  XZ position with |linear_velocity| small and y in a sane range (0.3–1.2) —
  on the floor, not sunk or launched.
- **Forward drive:** holding `accelerate` ~90 frames moves the car
  significantly along its local **-Z** (dot(displacement, -start_basis.z) >
  2.0). This is the regression test for the reversed-controls bug.
- **Steering:** holding `accelerate` + `steer_left` curves the path — yaw
  (rotation.y) changes by more than ~0.1 rad and the sign matches a left turn
  (positive yaw delta in Godot).
- **Reset:** after driving away, pressing `reset_car` returns the car to
  within 0.5 of its start position with near-zero velocity within a few
  frames.
- Each test releases all actions in teardown so failures don't leak input
  state into the next test.

### `tests/visual/test_visual.gd`
- Instantiates `main.tscn`, waits ~30 rendered frames (car stationary; scene
  is deterministic at rest), captures
  `get_viewport().get_texture().get_image()`.
- Compares to `tests/golden/main_scene.png`: fail if more than **0.5%** of
  pixels differ by more than **8 per channel** (absorbs GPU float rounding;
  catches real look changes: lighting accidentally added, dither/quantization
  broken, resolution changed).
- If the golden file is missing: fail with the message "golden image missing —
  run ./run_tests.sh --regen-goldens".
- With `--regen-goldens`: `run_tests.sh` sets the environment variable
  `REGEN_GOLDENS=1`; the test reads it via `OS.get_environment()`, writes the
  captured image to the golden path, and passes.
- Golden must be regenerated deliberately after intentional visual changes;
  the test failure message says so.

## CLAUDE.md (project root)

Short rules file stating:
- When adding or changing functionality, add or update tests in the same
  piece of work: behavior tests in `tests/headless/`, golden regen for
  intentional visual changes.
- Run `./run_tests.sh` after changes and before declaring work complete; all
  tests must pass. Use `--skip-visual` only for iterating, never for the
  final check.
- The Godot binary lives at `/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot`
  (override with `$GODOT`).
- The project is intentionally not under git; do not run git commands.

## Out of scope (YAGNI)

- CI; performance tests; multiple golden images/angles; input-event-level
  simulation (InputEventKey injection); testing GUT itself.

## Risks / known limitations

- GUT version must match Godot 4.6 — pin the release zip version in the plan.
- Headless physics determinism is good with Jolt, but thresholds are kept
  loose (e.g. "> 2.0 units moved", not exact positions) to avoid flakiness.
- The windowed visual pass steals focus briefly on macOS; accepted, and
  skippable via `--skip-visual`.
