# Bonnet Camera + Camera Cycling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a bonnet (hood) camera and let the player cycle camera views with the `C` key, where the bonnet camera is rigid to the car's heading.

**Architecture:** Use Godot's idiomatic multi-camera pattern — multiple `Camera3D` nodes, with the active one chosen via `Camera3D.current`. A new `CameraManager` node in `main.tscn` owns the ordered cycle list (`CHASE`, `BONNET`) and handles the `cycle_camera` input. The `BonnetCamera` is parented to the active car, so it is rigid to the car's heading for free; on car-swap the manager re-parents it onto the fresh car.

**Tech Stack:** Godot 4.x, GDScript, GUT (vendored in `addons/gut/`).

## Global Constraints

- Godot binary: `/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot` (override with `$GODOT`).
- This project is NOT under git — do NOT run git commands. The "Commit" step in each task is replaced by running the relevant test subset and confirming it passes.
- All tuning values live in `config/game_config.tres` (a `GameConfig` resource) and are declared in `scripts/game_config.gd`. Scene/script literals are fallback defaults only.
- A Node3D's forward is `-Z`; the car's front (bonnet) is toward `-Z`. Godot cameras look down their local `-Z` by default, so a camera parented to the car with no rotation looks forward out of the bonnet.
- Tests live in `tests/headless/`. Run a subset with `./run_tests.sh --fast <name>` and the full suite with `./run_tests.sh`. ALWAYS run tests in the background (`run_in_background: true`) and wait for the completion notification — never block in the foreground. Do not start a run if one is already running.
- Update `features/camera.md` in the same work (project rule: docs kept in sync with code).

---

## File Structure

- **Modify** `scripts/game_config.gd` — add `bonnet_offset: Vector3` and `bonnet_fov: float` to the `@export_group("Camera")`.
- **Modify** `config/game_config.tres` — add authored values for the two new fields.
- **Modify** `project.godot` — add the `cycle_camera` input action (key `C`).
- **Create** `scripts/camera_manager.gd` — owns the camera mode list, applies `bonnet_offset`/`bonnet_fov`, switches `current`, handles `cycle_camera`, and re-parents the bonnet camera on car-swap.
- **Modify** `main.tscn` — add a `BonnetCamera` `Camera3D` (child of `Car`) and a `CameraManager` node wired to both cameras and the car.
- **Modify** `scripts/world.gd` — in `cycle_car()`, notify the `CameraManager` so it re-targets the chase camera and re-parents the bonnet camera onto the fresh car.
- **Modify** `tests/headless/test_smoke.gd` — add `cycle_camera` to the `ACTIONS` list and add bonnet/cycling structural assertions.
- **Create** `tests/headless/test_camera_manager.gd` — behavioral tests for cycling and bonnet positioning.
- **Modify** `features/camera.md` — document both camera modes and the cycle key.

---

### Task 1: Add the `cycle_camera` input action

**Files:**
- Modify: `project.godot:96-100` (after the `cycle_drive_mode` block, inside `[input]`)
- Test: `tests/headless/test_smoke.gd:3-6` (the `ACTIONS` const)

**Interfaces:**
- Produces: input action named `cycle_camera`, bound to physical key `C` (physical_keycode `67`).

- [ ] **Step 1: Add `cycle_camera` to the smoke test's ACTIONS list (failing test)**

In `tests/headless/test_smoke.gd`, change the `ACTIONS` const to include the new action:

```gdscript
const ACTIONS := [
	"accelerate", "brake_reverse", "steer_left", "steer_right", "reset_car",
	"shift_up", "shift_down", "toggle_gearbox", "cycle_drive_mode", "cycle_camera",
]
```

(There is an existing test in this file that iterates `ACTIONS` and asserts each is a registered InputMap action. If not present, add one:)

```gdscript
func test_input_actions_registered() -> void:
	for action in ACTIONS:
		assert_true(InputMap.has_action(action), "input action registered: " + action)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./run_tests.sh --fast smoke` (background; wait for notification)
Expected: FAIL — `cycle_camera` is not a registered action.

- [ ] **Step 3: Add the action to `project.godot`**

In the `[input]` section, immediately after the `cycle_drive_mode={...}` block (ends at line 100), add:

```
cycle_camera={
"deadzone": 0.2,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":0,"physical_keycode":67,"key_label":0,"unicode":0,"location":0,"echo":false,"script":null)
]
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./run_tests.sh --fast smoke` (background; wait for notification)
Expected: PASS.

- [ ] **Step 5: Verify (no git) — confirm the smoke subset is green before moving on.**

---

### Task 2: Add bonnet camera config fields

**Files:**
- Modify: `scripts/game_config.gd:200-203` (the `@export_group("Camera")` block)
- Modify: `config/game_config.tres`
- Test: `tests/headless/test_config_applied.gd` (add an assertion) OR a new check in `test_camera_manager.gd` (added in Task 4 — this task just adds the fields and a minimal config test)

**Interfaces:**
- Produces: `GameConfig.bonnet_offset: Vector3` (default `Vector3(0, 0.7, -0.6)`), `GameConfig.bonnet_fov: float` (default `75.0`). Front of car is `-Z`, so a negative Z offset places the camera over the bonnet.

- [ ] **Step 1: Write a failing test for the new config fields**

Add to `tests/headless/test_config_applied.gd` (a GutTest that loads `Config.data`):

```gdscript
func test_bonnet_camera_config_present() -> void:
	var cfg: GameConfig = Config.data
	assert_typeof(cfg.bonnet_offset, TYPE_VECTOR3, "bonnet_offset is a Vector3")
	assert_lt(cfg.bonnet_offset.z, 0.0, "bonnet_offset sits toward the car's front (-Z)")
	assert_gt(cfg.bonnet_fov, 0.0, "bonnet_fov is a positive FOV")
```

If `test_config_applied.gd` does not call `Config.reset()` in `before_each`, follow its existing pattern for obtaining `Config.data`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `./run_tests.sh --fast config_applied` (background; wait for notification)
Expected: FAIL — `bonnet_offset`/`bonnet_fov` do not exist on `GameConfig`.

- [ ] **Step 3: Add the fields to `game_config.gd`**

In `scripts/game_config.gd`, extend the Camera group (currently lines 200-203):

```gdscript
@export_group("Camera")
@export var follow_distance := 6.0
@export var follow_height := 3.0
@export var smoothing := 5.0
## Bonnet (hood) camera local offset on the car. Front of the car is -Z, so a
## negative Z sits the camera over the bonnet; +Y raises it to eye height.
@export var bonnet_offset := Vector3(0.0, 0.7, -0.6)
## Field of view (degrees) for the bonnet camera.
@export_range(30.0, 120.0) var bonnet_fov := 75.0
```

- [ ] **Step 4: Add authored values to `config/game_config.tres`**

Open `config/game_config.tres` and add the two properties to the resource's property list (matching the existing `follow_distance`/`follow_height`/`smoothing` lines' format):

```
bonnet_offset = Vector3(0, 0.7, -0.6)
bonnet_fov = 75.0
```

Place them alongside the other camera properties. (If the `.tres` does not currently serialize the camera fields because they equal their defaults, adding them explicitly is fine and harmless.)

- [ ] **Step 5: Run the test to verify it passes**

Run: `./run_tests.sh --fast config_applied` (background; wait for notification)
Expected: PASS.

- [ ] **Step 6: Verify (no git) — confirm the config subset is green.**

---

### Task 3: Create the CameraManager script and wire the scene

**Files:**
- Create: `scripts/camera_manager.gd`
- Modify: `main.tscn` (add `BonnetCamera` under `Car`; add `CameraManager` node; register the script as an ext_resource)
- Test: `tests/headless/test_smoke.gd` (structural assertions)

**Interfaces:**
- Consumes: `Config.data.bonnet_offset`, `Config.data.bonnet_fov` (Task 2); the `cycle_camera` action (Task 1).
- Produces: `scripts/camera_manager.gd` with:
  - `@export var chase_camera: Camera3D`
  - `@export var bonnet_camera: Camera3D`
  - `func cycle() -> void` — advance to the next camera mode (wrapping) and set its `current = true`.
  - `func active_index() -> int` — current mode index (0 = chase, 1 = bonnet).
  - `func retarget(car: Node3D) -> void` — point the chase camera at `car` and re-parent the bonnet camera under `car`, re-applying `bonnet_offset`.
  - Node named `CameraManager` in `main.tscn`; `BonnetCamera` `Camera3D` parented to `Car`.

- [ ] **Step 1: Write the CameraManager script**

Create `scripts/camera_manager.gd`:

```gdscript
extends Node
# Owns the ordered list of camera modes and the C-key cycling between them.
# Exactly one camera is `current` at a time. The bonnet camera is parented to
# the active car (rigid to the car's heading); the chase camera follows from the
# scene root. See features/camera.md.

enum Mode { CHASE, BONNET }

# Cycle order. Appending a future Camera3D + Mode entry extends the cycle.
const ORDER := [Mode.CHASE, Mode.BONNET]

@export var chase_camera: Camera3D
@export var bonnet_camera: Camera3D

var _index := 0


func _ready() -> void:
	var cfg: GameConfig = Config.data
	bonnet_camera.transform.origin = cfg.bonnet_offset
	bonnet_camera.fov = cfg.bonnet_fov
	_apply()


func _process(_delta: float) -> void:
	if Input.is_action_just_pressed("cycle_camera"):
		cycle()


# Advance to the next camera in ORDER (wrapping) and make it current.
func cycle() -> void:
	_index = (_index + 1) % ORDER.size()
	_apply()


func active_index() -> int:
	return _index


# Re-point the chase camera and re-parent the bonnet camera onto a (possibly
# fresh) car. Called by world.gd:cycle_car() after a car swap.
func retarget(car: Node3D) -> void:
	chase_camera.target = car
	var cfg: GameConfig = Config.data
	if bonnet_camera.get_parent() != car:
		bonnet_camera.get_parent().remove_child(bonnet_camera)
		car.add_child(bonnet_camera)
	bonnet_camera.transform.origin = cfg.bonnet_offset
	bonnet_camera.fov = cfg.bonnet_fov


# Make the camera for the current mode active; clear the others.
func _apply() -> void:
	var cams := [chase_camera, bonnet_camera]
	var target_mode: int = ORDER[_index]
	chase_camera.current = (target_mode == Mode.CHASE)
	bonnet_camera.current = (target_mode == Mode.BONNET)
```

- [ ] **Step 2: Add the BonnetCamera and CameraManager to `main.tscn`**

In `main.tscn`:

(a) Register the script as an ext_resource (after the existing `id="5_cam"` line, line 8):

```
[ext_resource type="Script" path="res://scripts/camera_manager.gd" id="10_cammgr"]
```

(b) Add a `BonnetCamera` as a child of `Car`. After the `Car` node block (lines 57-58), add:

```
[node name="BonnetCamera" type="Camera3D" parent="Car"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.7, -0.6)
fov = 75.0
current = false
```

(c) Add the `CameraManager` node (after the `ChaseCamera` block, line 64), wiring both cameras:

```
[node name="CameraManager" type="Node" parent="." node_paths=PackedStringArray("chase_camera", "bonnet_camera")]
script = ExtResource("10_cammgr")
chase_camera = NodePath("../ChaseCamera")
bonnet_camera = NodePath("../Car/BonnetCamera")
```

- [ ] **Step 3: Add structural smoke assertions (failing test)**

Add to `tests/headless/test_smoke.gd`:

```gdscript
func test_bonnet_camera_parented_to_car_facing_forward() -> void:
	var car := _scene.get_node("Car") as VehicleBody3D
	var bonnet := car.get_node("BonnetCamera") as Camera3D
	assert_not_null(bonnet, "BonnetCamera is a child of Car")
	# Bonnet sits toward the car's front (-Z local) and is raised (+Y).
	assert_lt(bonnet.transform.origin.z, 0.0, "bonnet camera is toward the front (-Z)")
	assert_gt(bonnet.transform.origin.y, 0.0, "bonnet camera is raised")

func test_camera_manager_present_with_both_cameras() -> void:
	var mgr := _scene.get_node("CameraManager")
	assert_not_null(mgr, "CameraManager node exists")
	assert_eq(mgr.chase_camera, _scene.get_node("ChaseCamera"), "chase camera wired")
	assert_eq(mgr.bonnet_camera, _scene.get_node("Car/BonnetCamera"), "bonnet camera wired")
```

- [ ] **Step 4: Run the smoke subset to verify it passes**

Run: `./run_tests.sh --fast smoke` (background; wait for notification)
Expected: PASS (scene instantiates, CameraManager and BonnetCamera present and wired).

- [ ] **Step 5: Verify (no git) — confirm the smoke subset is green.**

---

### Task 4: Behavioral tests — cycling and exactly-one-current

**Files:**
- Create: `tests/headless/test_camera_manager.gd`

**Interfaces:**
- Consumes: `CameraManager.cycle()`, `CameraManager.active_index()`, `Camera3D.current` (Task 3).

- [ ] **Step 1: Write the cycling behavior tests**

Create `tests/headless/test_camera_manager.gd`:

```gdscript
extends GutTest
# Camera cycling: C advances chase -> bonnet -> chase, exactly one camera active.

var _scene: Node3D
var _mgr: Node


func before_each() -> void:
	Config.reset()
	_scene = load("res://main.tscn").instantiate()
	add_child_autofree(_scene)
	_mgr = _scene.get_node("CameraManager")


func _current_count() -> int:
	var n := 0
	if (_scene.get_node("ChaseCamera") as Camera3D).current:
		n += 1
	if (_scene.get_node("Car/BonnetCamera") as Camera3D).current:
		n += 1
	return n


func test_starts_on_chase_camera() -> void:
	assert_eq(_mgr.active_index(), 0, "starts on chase (index 0)")
	assert_true((_scene.get_node("ChaseCamera") as Camera3D).current, "chase is current at start")
	assert_eq(_current_count(), 1, "exactly one camera current")


func test_cycle_switches_to_bonnet_then_back() -> void:
	_mgr.cycle()
	assert_eq(_mgr.active_index(), 1, "after one cycle, on bonnet (index 1)")
	assert_true((_scene.get_node("Car/BonnetCamera") as Camera3D).current, "bonnet current after cycle")
	assert_eq(_current_count(), 1, "still exactly one camera current")
	_mgr.cycle()
	assert_eq(_mgr.active_index(), 0, "second cycle wraps back to chase")
	assert_true((_scene.get_node("ChaseCamera") as Camera3D).current, "chase current after wrap")
	assert_eq(_current_count(), 1, "still exactly one camera current")


func test_bonnet_uses_configured_offset_and_fov() -> void:
	var cfg: GameConfig = Config.data
	var bonnet := _scene.get_node("Car/BonnetCamera") as Camera3D
	assert_almost_eq(bonnet.transform.origin, cfg.bonnet_offset, Vector3(0.001, 0.001, 0.001), "bonnet at configured offset")
	assert_almost_eq(bonnet.fov, cfg.bonnet_fov, 0.001, "bonnet at configured fov")
```

- [ ] **Step 2: Run the test to verify it passes**

Run: `./run_tests.sh --fast camera_manager` (background; wait for notification)
Expected: PASS — all cycling assertions hold.

- [ ] **Step 3: Verify (no git) — confirm the camera_manager subset is green.**

---

### Task 5: Re-target cameras on car-swap

**Files:**
- Modify: `scripts/world.gd:98-102` (`cycle_car()`)
- Test: `tests/headless/test_camera_manager.gd` (add a swap test)

**Interfaces:**
- Consumes: `CameraManager.retarget(car)` (Task 3).
- Produces: after `world.gd:cycle_car()`, the chase camera's `target` and the bonnet camera's parent both point at the fresh car.

- [ ] **Step 1: Write a failing test for car-swap re-targeting**

Add to `tests/headless/test_camera_manager.gd`:

```gdscript
func test_cycle_car_retargets_both_cameras() -> void:
	var old_car := _scene.get_node("Car")
	_scene.cycle_car()
	var fresh := _scene.get_node("Car")
	assert_ne(fresh, old_car, "cycle_car spawns a fresh car node")
	var chase := _scene.get_node("ChaseCamera") as Camera3D
	assert_eq(chase.target, fresh, "chase camera re-targeted to fresh car")
	var bonnet := _mgr.bonnet_camera as Camera3D
	assert_eq(bonnet.get_parent(), fresh, "bonnet camera re-parented onto fresh car")
```

(Note: `respawn` re-instantiates the car under the same node name `Car`; the test compares object identity, not the path.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `./run_tests.sh --fast camera_manager` (background; wait for notification)
Expected: FAIL — `cycle_car()` does not yet re-parent the bonnet camera (and may error because the old bonnet camera was freed with the old car).

- [ ] **Step 3: Update `cycle_car()` to route through the manager**

In `scripts/world.gd`, replace the body of `cycle_car()` (lines 98-102):

```gdscript
func cycle_car() -> void:
	var car: Node = $Car
	# Move the bonnet camera off the outgoing car before it is freed, so it
	# survives the swap and can be re-parented onto the fresh car.
	var mgr := $CameraManager
	var bonnet: Camera3D = mgr.bonnet_camera
	if bonnet.get_parent() == car:
		car.remove_child(bonnet)
		add_child(bonnet)  # park on the world root during the swap
	var fresh: Node = car.respawn(car, car.next_car_index(), _car_spawn)
	mgr.retarget(fresh)
	($HUD as CanvasLayer).car = fresh
```

`retarget()` (Task 3) re-points the chase camera and re-parents the bonnet camera (currently parked on the world root) onto `fresh`, re-applying the configured offset/fov.

- [ ] **Step 4: Run the test to verify it passes**

Run: `./run_tests.sh --fast camera_manager` (background; wait for notification)
Expected: PASS.

- [ ] **Step 5: Verify (no git) — confirm the camera_manager subset is green.**

---

### Task 6: Update feature docs

**Files:**
- Modify: `features/camera.md`

**Interfaces:** none (docs).

- [ ] **Step 1: Rewrite `features/camera.md` to cover both modes and cycling**

Replace the title and add sections so the doc describes the camera system, not just the chase camera. Keep the existing chase-camera behavior section, and add:

```markdown
# Cameras

The game has two camera modes, cycled with the **C key** (`cycle_camera`
action). A `CameraManager` node (`scripts/camera_manager.gd`) in `main.tscn`
owns the ordered cycle list `[CHASE, BONNET]` and makes exactly one camera
`current` at a time.

## Chase camera

**Source:** `scripts/chase_camera.gd` (extends `Camera3D`). Node `ChaseCamera`
in `main.tscn`, with `target` wired to the `Car`.

(... existing chase-camera description ...)

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
active car is swapped (it re-parents the bonnet camera onto the fresh car in
`world.gd:cycle_car()`).
```

Integrate the existing chase-camera prose where indicated rather than duplicating it.

- [ ] **Step 2: Verify (no git) — re-read the file and confirm it accurately describes the implemented behavior.**

---

### Task 7: Full verification

- [ ] **Step 1: Run the full test suite**

Run: `./run_tests.sh` (background; wait for notification — the full suite takes a while)
Expected: `ALL TESTS PASSED`.

- [ ] **Step 2: If any previously-green test now fails**, treat the new changes as the prime suspect (per project rules). Do not weaken thresholds or delete assertions — fix the code, unless the user explicitly asked for the asserted behavior to change.

---

## Self-Review

**Spec coverage:**
- Input action `cycle_camera` (C) → Task 1. ✔
- Bonnet camera node, rigid to heading, config-driven offset/fov → Tasks 2, 3. ✔
- CameraManager cycling, exactly-one-current → Tasks 3, 4. ✔
- Multi-car re-parent/re-target on swap → Task 5. ✔
- Tests (action exists, cycling, bonnet position) + smoke update → Tasks 1, 3, 4, 5. ✔
- `features/camera.md` update → Task 6. ✔
- Full-suite final verification → Task 7. ✔

**Placeholder scan:** No TBD/TODO; every code step shows concrete code.

**Type consistency:** `CameraManager` exposes `chase_camera`, `bonnet_camera`, `cycle()`, `active_index()`, `retarget(car)` consistently across Tasks 3–5. `GameConfig.bonnet_offset: Vector3` / `bonnet_fov: float` used consistently in Tasks 2–4. The `Mode` enum (`CHASE`, `BONNET`) and `ORDER` list are internal to the manager.
