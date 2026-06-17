# Automated Testing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One-command automated test suite (GUT) covering scene smoke checks, gameplay behavior, and visual regression, plus a project CLAUDE.md mandating tests for new functionality.

**Architecture:** GUT 9.x addon vendored into `addons/gut/`. `run_tests.sh` runs two GUT CLI passes: headless (`tests/headless/`: smoke + car behavior) and windowed (`tests/visual/`: golden-image comparison — headless rendering can't screenshot). Golden regeneration is signaled via the `REGEN_GOLDENS=1` env var.

**Tech Stack:** Godot 4.6 (binary at `/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot`, overridable via `$GODOT`), GUT 9.x, bash, GDScript.

**Notes:** Project is intentionally NOT under git — no git commands; "Commit" steps are replaced by verification. Spec: `docs/superpowers/specs/2026-06-12-automated-testing-design.md`.

---

### Task 1: Vendor GUT + run_tests.sh (headless pass)

**Files:**
- Create: `addons/gut/` (vendored from GUT's godot_4x branch)
- Create: `run_tests.sh`
- Create: `tests/headless/test_harness_check.gd` (temporary sanity test, deleted in Task 2)

- [ ] **Step 1: Download and vendor GUT**

```bash
cd /Users/felixwu/rally
curl -sL -o /tmp/gut.zip https://github.com/bitwes/Gut/archive/refs/heads/godot_4x.zip
unzip -q -o /tmp/gut.zip -d /tmp/gut_src
mkdir -p addons
cp -R /tmp/gut_src/Gut-godot_4x/addons/gut addons/
ls addons/gut/gut_cmdln.gd
```

Expected: the final `ls` prints `addons/gut/gut_cmdln.gd`. If the branch zip layout differs (`Gut-godot_4x` folder name changed), inspect `/tmp/gut_src` and copy the inner `addons/gut` folder; if the godot_4x branch no longer supports 4.6, download the latest 9.x release zip from https://github.com/bitwes/Gut/releases instead and report which version was used.

- [ ] **Step 2: Write a temporary harness sanity test**

Create `tests/headless/test_harness_check.gd`:

```gdscript
extends GutTest


func test_harness_runs() -> void:
	assert_true(true)
```

- [ ] **Step 3: Write run_tests.sh**

Create `run_tests.sh` (then `chmod +x run_tests.sh`):

```bash
#!/usr/bin/env bash
# Test runner for the rally project. Two passes:
#   1. headless: smoke + gameplay tests (tests/headless/)
#   2. windowed: visual regression (tests/visual/) — headless rendering
#      cannot capture screenshots, so a window appears briefly.
# Flags:
#   --skip-visual     skip pass 2 (iteration only; final checks run both)
#   --regen-goldens   regenerate golden images instead of comparing
set -u

GODOT="${GODOT:-/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot}"
if [[ ! -x "$GODOT" ]]; then
  echo "error: Godot binary not found at $GODOT (set \$GODOT to override)" >&2
  exit 2
fi

SKIP_VISUAL=0
REGEN=0
for arg in "$@"; do
  case "$arg" in
    --skip-visual) SKIP_VISUAL=1 ;;
    --regen-goldens) REGEN=1 ;;
    *) echo "error: unknown flag $arg (known: --skip-visual --regen-goldens)" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")"
FAIL=0

echo "=== Pass 1: headless (smoke + gameplay) ==="
"$GODOT" --headless -d -s addons/gut/gut_cmdln.gd -gdir=res://tests/headless -ginclude_subdirs -gexit
[[ $? -ne 0 ]] && FAIL=1

if [[ $SKIP_VISUAL -eq 0 ]]; then
  echo "=== Pass 2: windowed (visual regression) ==="
  REGEN_GOLDENS=$REGEN "$GODOT" -d -s addons/gut/gut_cmdln.gd -gdir=res://tests/visual -ginclude_subdirs -gexit
  [[ $? -ne 0 ]] && FAIL=1
else
  echo "=== Pass 2 skipped (--skip-visual) ==="
fi

if [[ $FAIL -eq 0 ]]; then
  echo "ALL TESTS PASSED"
else
  echo "TESTS FAILED" >&2
fi
exit $FAIL
```

- [ ] **Step 4: Verify the headless pass runs**

Create an empty `tests/visual/` directory (`mkdir -p tests/visual`), then:

Run: `./run_tests.sh --skip-visual`
Expected: GUT banner, `1 passing`, `ALL TESTS PASSED`, exit code 0 (`echo $?` → 0).

- [ ] **Step 5: Verify failures propagate**

Temporarily change `assert_true(true)` to `assert_true(false)`, run `./run_tests.sh --skip-visual`, expect `TESTS FAILED` and exit code 1. Revert to `assert_true(true)` and re-run to confirm green again.

---

### Task 2: Smoke tests

**Files:**
- Create: `tests/headless/test_smoke.gd`
- Delete: `tests/headless/test_harness_check.gd`

- [ ] **Step 1: Write the smoke tests**

Create `tests/headless/test_smoke.gd`:

```gdscript
extends GutTest

const ACTIONS := ["accelerate", "brake_reverse", "steer_left", "steer_right", "reset_car"]

var _scene: Node3D


func before_each() -> void:
	_scene = load("res://main.tscn").instantiate()
	add_child_autofree(_scene)


func test_scene_instantiates() -> void:
	assert_not_null(_scene)


func test_car_is_vehicle_with_four_wheels() -> void:
	var car := _scene.get_node("Car") as VehicleBody3D
	assert_not_null(car, "Car node must be a VehicleBody3D")
	var wheels := car.find_children("*", "VehicleWheel3D", false)
	assert_eq(wheels.size(), 4, "Car must have 4 wheels")
	for name in ["WheelFL", "WheelFR"]:
		assert_true((car.get_node(name) as VehicleWheel3D).use_as_steering, name + " steers")
	for name in ["WheelRL", "WheelRR"]:
		assert_true((car.get_node(name) as VehicleWheel3D).use_as_traction, name + " drives")


func test_chase_camera_targets_car() -> void:
	var cam := _scene.get_node("ChaseCamera") as Camera3D
	assert_not_null(cam)
	assert_eq(cam.target, _scene.get_node("Car"), "camera target wired to Car")


func test_post_process_present() -> void:
	var rect := _scene.get_node("PostProcess/ColorRect") as ColorRect
	assert_not_null(rect)
	assert_not_null(rect.material as ShaderMaterial, "post-process ShaderMaterial assigned")


func test_environment_has_fog_and_no_lights() -> void:
	var env := (_scene.get_node("WorldEnvironment") as WorldEnvironment).environment
	assert_true(env.fog_enabled, "fog enabled")
	assert_eq(_scene.find_children("*", "Light3D", true).size(), 0, "no lights in scene")


func test_floor_is_static_body() -> void:
	assert_not_null(_scene.get_node("Floor") as StaticBody3D)


func test_shaders_load_with_code() -> void:
	for path in ["res://shaders/ps1_models.gdshader", "res://shaders/ps1_post_process.gdshader"]:
		var shader := load(path) as Shader
		assert_not_null(shader, path + " loads")
		assert_true(shader.code.length() > 0, path + " has code")


func test_input_actions_exist() -> void:
	for action in ACTIONS:
		assert_true(InputMap.has_action(action), "action exists: " + action)
```

Note: `cam.target` works because `chase_camera.gd` declares `@export var target: Node3D` — the script is attached, so the property is accessible.

- [ ] **Step 2: Delete the temporary harness test**

```bash
rm tests/headless/test_harness_check.gd
```

- [ ] **Step 3: Run and verify**

Run: `./run_tests.sh --skip-visual`
Expected: all smoke tests pass (8 passing), exit 0. If `cam.target` fails to resolve as a property, access it via `cam.get("target")` instead and note the change.

---

### Task 3: Car behavior tests

**Files:**
- Create: `tests/headless/test_car.gd`

- [ ] **Step 1: Write the behavior tests**

Create `tests/headless/test_car.gd`:

```gdscript
extends GutTest

const ACTIONS := ["accelerate", "brake_reverse", "steer_left", "steer_right", "reset_car"]

var _scene: Node3D
var _car: VehicleBody3D


func before_each() -> void:
	_scene = load("res://main.tscn").instantiate()
	add_child_autofree(_scene)
	_car = _scene.get_node("Car")
	await _wait_physics(60)  # let the car drop onto its suspension and settle


func after_each() -> void:
	for action in ACTIONS:
		Input.action_release(action)


func _wait_physics(frames: int) -> void:
	for i in frames:
		await get_tree().physics_frame


func test_car_settles_on_floor() -> void:
	assert_between(_car.global_position.y, 0.3, 1.2, "car rests on floor, not sunk/launched")
	assert_lt(_car.linear_velocity.length(), 0.5, "car nearly stationary after settling")


func test_accelerate_moves_car_forward() -> void:
	var start_pos := _car.global_position
	var forward := -_car.global_transform.basis.z
	Input.action_press("accelerate")
	await _wait_physics(90)
	Input.action_release("accelerate")
	var displacement := _car.global_position - start_pos
	assert_gt(displacement.dot(forward), 2.0,
		"W must move the car along its -Z forward (regression: reversed controls)")


func test_steer_left_turns_left() -> void:
	var start_yaw := _car.rotation.y
	Input.action_press("accelerate")
	Input.action_press("steer_left")
	await _wait_physics(90)
	Input.action_release("accelerate")
	Input.action_release("steer_left")
	var yaw_delta := wrapf(_car.rotation.y - start_yaw, -PI, PI)
	assert_gt(yaw_delta, 0.1, "steering left while driving forward increases yaw")


func test_reset_returns_to_start() -> void:
	var start_pos := _car.global_position
	Input.action_press("accelerate")
	await _wait_physics(90)
	Input.action_release("accelerate")
	assert_gt((_car.global_position - start_pos).length(), 1.0, "car drove away first")
	Input.action_press("reset_car")
	await _wait_physics(5)
	Input.action_release("reset_car")
	await _wait_physics(30)  # settle after reset teleport
	assert_lt((_car.global_position - start_pos).length(), 0.5, "reset returns to start")
	assert_lt(_car.linear_velocity.length(), 0.5, "reset zeroes velocity")
```

- [ ] **Step 2: Run and verify**

Run: `./run_tests.sh --skip-visual`
Expected: all headless tests pass (12 passing total), exit 0.

Troubleshooting guidance:
- If `test_accelerate_moves_car_forward` fails: do NOT silently flip the sign — that test encodes the agreed forward convention (W drives -Z, away from the chase camera). Investigate `car.gd`'s `engine_force = -throttle * MAX_ENGINE_FORCE` line.
- If `test_steer_left_turns_left` fails on sign only (car turns but yaw_delta is negative): verify visually by running the game (`$GODOT --path .`, hold W+A — does it curve left on screen?). If it visibly turns left but yaw decreases, the assertion's sign expectation is wrong; flip the assertion to `assert_lt(yaw_delta, -0.1, ...)` and document why. Report this in your summary either way.
- If physics timing is flaky (settle not reached), increase the `before_each` wait from 60 to 120 frames rather than loosening position thresholds.

---

### Task 4: Visual regression test + golden

**Files:**
- Create: `tests/visual/test_visual.gd`
- Create: `tests/golden/main_scene.png` (generated via --regen-goldens)

- [ ] **Step 1: Write the visual test**

Create `tests/visual/test_visual.gd`:

```gdscript
extends GutTest

const GOLDEN_PATH := "res://tests/golden/main_scene.png"
const CHANNEL_TOLERANCE := 8        # per-channel 0-255 delta considered equal
const MAX_DIFF_PIXEL_RATIO := 0.005 # fraction of pixels allowed to exceed tolerance


func test_main_scene_matches_golden() -> void:
	var scene: Node3D = load("res://main.tscn").instantiate()
	add_child_autofree(scene)
	for i in 30:  # let rendering and post-process settle; car stays stationary
		await get_tree().process_frame
	var captured: Image = get_viewport().get_texture().get_image()
	captured.convert(Image.FORMAT_RGB8)

	if OS.get_environment("REGEN_GOLDENS") == "1":
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/golden"))
		var err := captured.save_png(ProjectSettings.globalize_path(GOLDEN_PATH))
		assert_eq(err, OK, "golden image written to " + GOLDEN_PATH)
		return

	assert_true(FileAccess.file_exists(ProjectSettings.globalize_path(GOLDEN_PATH)),
		"golden image missing — run ./run_tests.sh --regen-goldens")
	if not FileAccess.file_exists(ProjectSettings.globalize_path(GOLDEN_PATH)):
		return

	var golden := Image.load_from_file(ProjectSettings.globalize_path(GOLDEN_PATH))
	golden.convert(Image.FORMAT_RGB8)
	assert_eq(captured.get_size(), golden.get_size(),
		"resolution changed — if intentional, run ./run_tests.sh --regen-goldens")
	if captured.get_size() != golden.get_size():
		return

	var diff_count := 0
	var total := captured.get_width() * captured.get_height()
	for y in captured.get_height():
		for x in captured.get_width():
			var a := captured.get_pixel(x, y)
			var b := golden.get_pixel(x, y)
			if absf(a.r - b.r) * 255.0 > CHANNEL_TOLERANCE \
					or absf(a.g - b.g) * 255.0 > CHANNEL_TOLERANCE \
					or absf(a.b - b.b) * 255.0 > CHANNEL_TOLERANCE:
				diff_count += 1
	var ratio := float(diff_count) / float(total)
	assert_lt(ratio, MAX_DIFF_PIXEL_RATIO,
		"%.2f%% of pixels differ from golden (limit %.2f%%) — if the look change is intentional, run ./run_tests.sh --regen-goldens"
		% [ratio * 100.0, MAX_DIFF_PIXEL_RATIO * 100.0])
```

- [ ] **Step 2: Generate the golden image**

Run: `./run_tests.sh --regen-goldens`
Expected: headless pass green; a window flashes; visual test passes (golden written); `ls tests/golden/main_scene.png` exists; image is 640×480 (`file tests/golden/main_scene.png`).

- [ ] **Step 3: Verify comparison passes against the golden**

Run: `./run_tests.sh`
Expected: both passes green, `ALL TESTS PASSED`, exit 0.

- [ ] **Step 4: Verify the test catches a real visual change**

Temporarily edit `main.tscn`: change `fog_density=0.02` to `fog_density=0.2`. Run `./run_tests.sh`. Expected: visual test FAILS with the pixel-diff message. Revert to `fog_density=0.02`, run again, expected green. (This proves the golden actually guards the look.)

---

### Task 5: CLAUDE.md + final full run

**Files:**
- Create: `CLAUDE.md`

- [ ] **Step 1: Write CLAUDE.md**

Create `CLAUDE.md` at the project root:

```markdown
# rally — project rules for Claude

## Testing (mandatory)

- When adding or changing functionality, add or update tests in the same piece
  of work: gameplay/logic tests in `tests/headless/`, scene/structure checks in
  `tests/headless/test_smoke.gd`.
- After any change, run `./run_tests.sh` and make sure ALL tests pass before
  declaring the work complete. `--skip-visual` is allowed while iterating, but
  the final verification must run the full suite (the visual pass opens a
  window briefly — that's expected and OK).
- If a change intentionally alters the rendered look, regenerate the golden
  image with `./run_tests.sh --regen-goldens` and mention it in your summary.
  Never regenerate goldens to silence a failure you don't understand.

## Environment

- Godot binary: `/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot`
  (override with `$GODOT`). Tests use GUT, vendored in `addons/gut/`.
- This project is intentionally NOT under git. Do not run git commands.
```

- [ ] **Step 2: Final full-suite run**

Run: `./run_tests.sh`
Expected: headless pass (12 passing) + visual pass (1 passing), `ALL TESTS PASSED`, exit 0.

- [ ] **Step 3: Sanity-check the game still launches**

Run: `"$GODOT" --headless --path . --quit-after 120 2>&1 | tail -5` (with GODOT defaulting to the binary above)
Expected: version banner only, no errors.
