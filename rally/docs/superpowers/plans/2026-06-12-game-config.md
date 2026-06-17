# Central GameConfig Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every tunable value lives in one Inspector-editable file, `config/game_config.tres`, applied at startup, with tests proving the values are actually applied.

**Architecture:** A `GameConfig` custom Resource defines typed, grouped properties. A `Config` autoload loads the .tres once (falling back to code defaults). Each owner applies its own values in `_ready()`: `car.gd` (handling/wheels), `chase_camera.gd` (follow), and a new `world.gd` on the Main root (environment + materials). Behavior must be byte-identical: the .tres carries today's exact values, so all existing tests and the visual golden must pass unchanged.

**Tech Stack:** Godot 4.6, GDScript, GUT (run `./run_tests.sh`; binary `/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot`, override `$GODOT`).

**Notes:** Project intentionally NOT under git — no git commands; verification replaces commits. Spec: `docs/superpowers/specs/2026-06-12-game-config-design.md`. Per CLAUDE.md: if a previously-green test breaks, suspect the new code, not the test.

---

### Task 1: GameConfig resource, .tres, autoload (TDD)

**Files:**
- Create: `tests/headless/test_config_applied.gd` (first test only)
- Create: `scripts/game_config.gd`
- Create: `config/game_config.tres`
- Create: `scripts/config.gd`
- Modify: `project.godot` (add `[autoload]` section)

- [ ] **Step 1: Write the failing test**

Create `tests/headless/test_config_applied.gd`:

```gdscript
extends GutTest


func test_config_resource_loads() -> void:
	var cfg := load("res://config/game_config.tres") as GameConfig
	assert_not_null(cfg, "game_config.tres loads as a GameConfig")
	assert_gt(cfg.engine_force, 0.0, "engine_force sane")
	assert_gt(cfg.wheel_radius, 0.0, "wheel_radius sane")
```

- [ ] **Step 2: Run to verify it fails**

Run: `./run_tests.sh --skip-visual`
Expected: FAIL (GameConfig type unknown / file missing). Exit 1.

- [ ] **Step 3: Create `scripts/game_config.gd`**

```gdscript
class_name GameConfig
extends Resource
# Central tuning knobs for the whole game. Edit config/game_config.tres
# (Inspector or text), not the per-node values in main.tscn — runtime
# config overrides those defaults at startup.

@export_group("Car")
@export var mass := 120.0
@export var engine_force := 1000.0
@export var brake_force := 6.0
@export_range(0.0, 1.2) var steer_limit := 0.5
@export var steer_speed := 5.0
@export var wheel_friction_slip := 3.0
@export var suspension_travel := 0.25
@export var wheel_radius := 0.35

@export_group("Camera")
@export var follow_distance := 6.0
@export var follow_height := 3.0
@export var smoothing := 5.0

@export_group("World")
@export var fog_density := 0.02
@export var background_color := Color(0.35, 0.3, 0.45)
@export var terrain_tile_per_meter := 0.125  # checker tiles per metre, baked into terrain UVs

@export_group("PS1 Look")
@export var virtual_resolution := Vector2(640, 480)  # keep matching [display] in project.godot
@export var chassis_color := Color(0.85, 0.2, 0.15)
@export var cabin_color := Color(0.25, 0.3, 0.4)
@export var wheel_color := Color(0.12, 0.12, 0.12)
```

- [ ] **Step 4: Create `config/game_config.tres`**

```ini
[gd_resource type="Resource" script_class="GameConfig" load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/game_config.gd" id="1"]

[resource]
script = ExtResource("1")
mass = 120.0
engine_force = 1000.0
brake_force = 6.0
steer_limit = 0.5
steer_speed = 5.0
wheel_friction_slip = 3.0
suspension_travel = 0.25
wheel_radius = 0.35
follow_distance = 6.0
follow_height = 3.0
smoothing = 5.0
fog_density = 0.02
background_color = Color(0.35, 0.3, 0.45, 1)
terrain_tile_per_meter = 0.125
virtual_resolution = Vector2(640, 480)
chassis_color = Color(0.85, 0.2, 0.15, 1)
cabin_color = Color(0.25, 0.3, 0.4, 1)
wheel_color = Color(0.12, 0.12, 0.12, 1)
```

- [ ] **Step 5: Create `scripts/config.gd`**

```gdscript
extends Node
# Autoload "Config": loads the central GameConfig once at startup.

const CONFIG_PATH := "res://config/game_config.tres"

var data: GameConfig


func _init() -> void:
	data = load(CONFIG_PATH) as GameConfig
	if data == null:
		push_error("Failed to load %s — using code defaults" % CONFIG_PATH)
		data = GameConfig.new()
```

- [ ] **Step 6: Register the autoload in `project.godot`**

Insert after the `[application]` section (alphabetical section order is conventional but not required):

```ini
[autoload]

Config="*res://scripts/config.gd"
```

- [ ] **Step 7: Re-import and verify the test passes**

Run: `"$GODOT" --headless --import .` then `./run_tests.sh --skip-visual` (GODOT defaulting to the binary above; the import registers the new `class_name`).
Expected: all headless tests pass (13 total now), exit 0.

---

### Task 2: Apply config in car.gd and chase_camera.gd (TDD)

**Files:**
- Modify: `tests/headless/test_config_applied.gd` (add car test)
- Modify: `scripts/car.gd`
- Modify: `scripts/chase_camera.gd`

- [ ] **Step 1: Add the failing car-application test**

Append to `tests/headless/test_config_applied.gd`:

```gdscript
func test_car_values_applied() -> void:
	var scene: Node3D = load("res://main.tscn").instantiate()
	add_child_autofree(scene)
	await get_tree().physics_frame  # let _ready() run
	var cfg: GameConfig = Config.data
	var car: VehicleBody3D = scene.get_node("Car")
	assert_eq(car.mass, cfg.mass, "car mass from config")
	for wheel in car.find_children("*", "VehicleWheel3D", false):
		assert_eq(wheel.wheel_friction_slip, cfg.wheel_friction_slip, str(wheel.name))
		assert_eq(wheel.suspension_travel, cfg.suspension_travel, str(wheel.name))
		assert_eq(wheel.wheel_radius, cfg.wheel_radius, str(wheel.name))
```

- [ ] **Step 2: Run to verify it fails**

Run: `./run_tests.sh --skip-visual`
Expected: `test_car_values_applied` passes for values that happen to match the .tscn (they're identical today) — so to make it a REAL test, first bump `wheel_friction_slip` in `config/game_config.tres` to `3.5`, run, and confirm the test FAILS (scene still has 3.0). Then revert the .tres to `3.0`. This proves the test detects "config not applied".

- [ ] **Step 3: Rewrite `scripts/car.gd` to read config**

Replace the whole file with:

```gdscript
extends VehicleBody3D

var _start_transform: Transform3D


func _ready() -> void:
	_start_transform = global_transform
	var cfg: GameConfig = Config.data
	mass = cfg.mass
	for wheel in find_children("*", "VehicleWheel3D", false):
		wheel.wheel_friction_slip = cfg.wheel_friction_slip
		wheel.suspension_travel = cfg.suspension_travel
		wheel.wheel_radius = cfg.wheel_radius


func _physics_process(delta: float) -> void:
	var cfg: GameConfig = Config.data
	var throttle := Input.get_axis("brake_reverse", "accelerate")
	# VehicleBody3D's positive engine_force drives toward +Z, but the node's
	# forward (and the chase camera's expectation) is -Z, so negate.
	engine_force = -throttle * cfg.engine_force
	brake = cfg.brake_force if (throttle < 0.0 and linear_velocity.dot(-global_transform.basis.z) > 1.0) else 0.0

	var steer_target := Input.get_axis("steer_right", "steer_left") * cfg.steer_limit
	steering = move_toward(steering, steer_target, cfg.steer_speed * delta)

	if Input.is_action_just_pressed("reset_car"):
		_reset()


func _reset() -> void:
	global_transform = _start_transform
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
```

(The four constants are gone; values come from `Config.data`. The engine-force sign comment MUST be preserved.)

- [ ] **Step 4: Rewrite `scripts/chase_camera.gd` to read config**

Replace the whole file with:

```gdscript
extends Camera3D

@export var target: Node3D

var _distance: float
var _height: float
var _smoothing: float


func _ready() -> void:
	var cfg: GameConfig = Config.data
	_distance = cfg.follow_distance
	_height = cfg.follow_height
	_smoothing = cfg.smoothing


func _physics_process(delta: float) -> void:
	if target == null:
		return
	var back: Vector3 = target.global_transform.basis.z
	back.y = 0.0
	back = back.normalized()
	var desired := target.global_position + back * _distance + Vector3.UP * _height
	global_position = global_position.lerp(desired, 1.0 - exp(-_smoothing * delta))
	look_at(target.global_position, Vector3.UP)
```

- [ ] **Step 5: Verify all headless tests pass**

Run: `./run_tests.sh --skip-visual`
Expected: 14 passing (8 smoke + 4 car + 2 config), exit 0. The pre-existing car behavior tests MUST still pass — same values, same physics. If any behavior test fails, the refactor changed behavior: stop and investigate (per CLAUDE.md), don't touch the tests.

---

### Task 3: world.gd applies environment + materials (TDD)

**Files:**
- Modify: `tests/headless/test_config_applied.gd` (add world test)
- Create: `scripts/world.gd`
- Modify: `main.tscn` (attach script to Main root node)

- [ ] **Step 1: Add the failing world-application test**

Append to `tests/headless/test_config_applied.gd`:

```gdscript
func test_world_values_applied() -> void:
	var scene: Node3D = load("res://main.tscn").instantiate()
	add_child_autofree(scene)
	await get_tree().physics_frame  # let _ready() run
	var cfg: GameConfig = Config.data
	var env: Environment = scene.get_node("WorldEnvironment").environment
	assert_eq(env.fog_density, cfg.fog_density, "fog density from config")
	assert_eq(env.background_color, cfg.background_color, "background color from config")
	assert_eq(env.fog_light_color, cfg.background_color, "fog color matches background")
	assert_eq(scene.get_node("Floor").texture_tile_per_meter, cfg.terrain_tile_per_meter, "terrain tiling from config")
	var chassis_mat: ShaderMaterial = scene.get_node("Car/Chassis").get_surface_override_material(0)
	assert_eq(chassis_mat.get_shader_parameter("albedo_color"), cfg.chassis_color, "chassis color from config")
	var post_mat: ShaderMaterial = scene.get_node("PostProcess/ColorRect").material
	assert_eq(post_mat.get_shader_parameter("virtual_resolution"), cfg.virtual_resolution, "dither grid from config")
```

- [ ] **Step 2: Run to verify it can fail**

As in Task 2: temporarily set `fog_density = 0.03` in `config/game_config.tres`, run `./run_tests.sh --skip-visual`, confirm `test_world_values_applied` FAILS (env still has the scene's 0.02 because nothing applies config yet). Revert to `0.02`. (With matching values the assertions would pass vacuously — the mismatch proves detection.)

- [ ] **Step 3: Create `scripts/world.gd`**

```gdscript
extends Node3D
# Applies the central GameConfig to scene-owned resources at startup.
# Car handling is applied by car.gd; camera follow by chase_camera.gd.


func _ready() -> void:
	var cfg: GameConfig = Config.data
	var env: Environment = $WorldEnvironment.environment
	env.fog_density = cfg.fog_density
	env.background_color = cfg.background_color
	env.fog_light_color = cfg.background_color

	# Setting this property triggers a full terrain regeneration; skip when equal.
	if $Floor.texture_tile_per_meter != cfg.terrain_tile_per_meter:
		$Floor.texture_tile_per_meter = cfg.terrain_tile_per_meter
	_mat($Car/Chassis).set_shader_parameter("albedo_color", cfg.chassis_color)
	_mat($Car/Cabin).set_shader_parameter("albedo_color", cfg.cabin_color)
	# The wheel material is one shared resource; setting it once covers all four.
	_mat($Car/WheelFL/MeshInstance3D).set_shader_parameter("albedo_color", cfg.wheel_color)
	($PostProcess/ColorRect.material as ShaderMaterial).set_shader_parameter("virtual_resolution", cfg.virtual_resolution)


func _mat(mesh_instance: MeshInstance3D) -> ShaderMaterial:
	return mesh_instance.get_surface_override_material(0) as ShaderMaterial
```

- [ ] **Step 4: Attach world.gd to the Main root in `main.tscn`**

Two text edits:
1. Add to the ext_resource block (after the `5_cam` line):
```ini
[ext_resource type="Script" path="res://scripts/world.gd" id="6_world"]
```
2. Change the root node line from:
```ini
[node name="Main" type="Node3D"]
```
to:
```ini
[node name="Main" type="Node3D"]
script=ExtResource("6_world")
```
Also bump the header's `load_steps` by 1 (currently 18 → 19).

- [ ] **Step 5: Verify all headless tests pass**

Run: `./run_tests.sh --skip-visual`
Expected: 15 passing, exit 0.

---

### Task 4: Full-suite verification + doc touch-up

**Files:**
- Modify: `CLAUDE.md` (one line, see Step 3)

- [ ] **Step 1: Full suite including visual**

Run: `./run_tests.sh`
Expected: headless 15 passing, visual 1 passing, ALL TESTS PASSED, exit 0. The golden must NOT need regeneration — config carries today's exact values, so the rendered frame is identical. If the visual test fails, the config values drifted from the scene's: fix the .tres, never regen the golden for this refactor.

- [ ] **Step 2: Launch check**

Run: `"$GODOT" --headless --path . --quit-after 120 2>&1 | tail -5`
Expected: version banner only (the pre-existing terrain.gd parse errors may appear — they are an unrelated work-in-progress file; ignore them, but report if anything NEW appears).

- [ ] **Step 3: Point CLAUDE.md at the config**

In `CLAUDE.md`, add to the end of the `## Environment` section:

```markdown
- All gameplay/look tuning values live in `config/game_config.tres`
  (a `GameConfig` resource) — change values there, not in scripts or
  `main.tscn`. Scene/script literals are only fallback defaults.
```

- [ ] **Step 4: Final re-run**

Run: `./run_tests.sh --skip-visual`
Expected: 15 passing, exit 0.
