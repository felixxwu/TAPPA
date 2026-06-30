# Front/Rear Downforce Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Speed-squared aerodynamic downforce at the front and rear axles, each tunable via an Inspector slider on `config/game_config.tres`.

**Architecture:** Two new `@export_range` coefficients on `GameConfig` (N per (m/s)², default 0.0). `car.gd` computes the front/rear axle midpoints once in `_ready` and, each physics tick, applies `v² * coefficient` along the body's `-basis.y` at each midpoint. Suspension compression then raises wheel normal force and grip through the existing `Drivetrain.wheel_normal_force` path — no tire-model changes.

**Tech Stack:** Godot 4 / GDScript, GUT tests via `./run_tests.sh`.

**Spec:** `docs/superpowers/specs/2026-06-12-downforce-design.md`

**IMPORTANT project constraints (from CLAUDE.md):**
- This project is intentionally NOT under git. There are NO commit steps in this plan — do not run any git commands.
- Godot binary: `/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot` (`$GODOT` overrides). Use `./run_tests.sh --skip-visual` while iterating; the FINAL verification (Task 3) must run the full suite including the visual pass (a window opens briefly — expected).
- Tuning values live in `config/game_config.tres`. The new coefficients default to 0.0, which is also the shipped value — Godot's .tres format omits properties equal to their script defaults, so no edit to the .tres file is needed (or possible without it being stripped on resave). The Inspector sliders appear automatically from `@export_range`.

---

### Task 1: Config fields

**Files:**
- Modify: `scripts/game_config.gd` (Car group, after `drag_coefficient` at line 17)
- Test: `tests/headless/test_config_applied.gd`

- [ ] **Step 1: Write the failing test**

Add to the end of `test_config_resource_loads()` in `tests/headless/test_config_applied.gd` (after the `handbrake` assertion):

```gdscript
	assert_true("downforce_front" in cfg, "downforce_front exists on GameConfig")
	assert_true("downforce_rear" in cfg, "downforce_rear exists on GameConfig")
	assert_gte(cfg.downforce_front, 0.0, "downforce_front sane")
	assert_gte(cfg.downforce_rear, 0.0, "downforce_rear sane")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./run_tests.sh --skip-visual`
Expected: FAIL — the two `in cfg` assertions report false (properties don't exist yet). `assert_gte` on a missing property may also log script errors; either failure mode is fine.

- [ ] **Step 3: Add the properties**

In `scripts/game_config.gd`, immediately after the `drag_coefficient` line (line 17), add:

```gdscript
# Aero downforce per axle: F = coefficient * v², applied downward along the
# body at the axle midpoint. Compresses the suspension, so grip rises through
# the normal-force path. 0.2 ≈ half the car's weight at 25 m/s.
@export_range(0.0, 2.0) var downforce_front := 0.0  # N per (m/s)² at the front axle
@export_range(0.0, 2.0) var downforce_rear := 0.0  # N per (m/s)² at the rear axle
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./run_tests.sh --skip-visual`
Expected: ALL TESTS PASSED (pass 1).

---

### Task 2: Apply downforce in car.gd + gameplay tests

**Files:**
- Modify: `scripts/car.gd`
- Test: `tests/headless/test_car.gd`

- [ ] **Step 1: Write the failing tests**

Append to `tests/headless/test_car.gd`:

```gdscript
func _axle_normal_sum(rear: bool) -> float:
	var total := 0.0
	for wheel in _car.find_children("*", "VehicleWheel3D", false):
		if wheel.use_as_traction == rear:
			total += _car.drivetrain.wheel_normal_force(wheel)
	return total


# Measures the per-axle normal-force sums while coasting at the given speed
# with the given downforce coefficients, restoring config afterwards.
func _normals_at_speed(front_coef: float, rear_coef: float) -> Array[float]:
	var cfg: GameConfig = Config.data
	var saved_front := cfg.downforce_front
	var saved_rear := cfg.downforce_rear
	cfg.downforce_front = front_coef
	cfg.downforce_rear = rear_coef
	_car.linear_velocity = -_car.global_transform.basis.z * 30.0
	await _wait_physics(20)  # suspension reaches the new equilibrium
	var result: Array[float] = [_axle_normal_sum(false), _axle_normal_sum(true)]
	cfg.downforce_front = saved_front
	cfg.downforce_rear = saved_rear
	return result


func test_rear_downforce_loads_rear_axle_at_speed() -> void:
	# F = c * v²: at 30 m/s with c = 1.0 the rear axle gains ~900 N over the
	# zero-downforce baseline; the front axle must gain far less.
	var baseline: Array[float] = await _normals_at_speed(0.0, 0.0)
	var loaded: Array[float] = await _normals_at_speed(0.0, 1.0)
	assert_gt(loaded[1], baseline[1] + 300.0, "rear downforce raises rear normal force at speed")
	assert_lt(loaded[0] - baseline[0], (loaded[1] - baseline[1]) * 0.5,
		"rear downforce must load the rear axle, not the front")


func test_front_downforce_loads_front_axle_at_speed() -> void:
	var baseline: Array[float] = await _normals_at_speed(0.0, 0.0)
	var loaded: Array[float] = await _normals_at_speed(1.0, 0.0)
	assert_gt(loaded[0], baseline[0] + 300.0, "front downforce raises front normal force at speed")
	assert_lt(loaded[1] - baseline[1], (loaded[0] - baseline[0]) * 0.5,
		"front downforce must load the front axle, not the rear")


func test_downforce_inert_at_standstill() -> void:
	# v² scaling: at rest the coefficients must not change the suspension load.
	var baseline_rear := _axle_normal_sum(true)
	var cfg: GameConfig = Config.data
	cfg.downforce_front = 2.0
	cfg.downforce_rear = 2.0
	await _wait_physics(30)
	var loaded_rear := _axle_normal_sum(true)
	cfg.downforce_front = 0.0
	cfg.downforce_rear = 0.0
	assert_almost_eq(loaded_rear, baseline_rear, baseline_rear * 0.1,
		"downforce is speed-dependent: no effect at standstill")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./run_tests.sh --skip-visual`
Expected: the two `*_loads_*_axle_at_speed` tests FAIL (no normal-force gain — the car ignores the coefficients). `test_downforce_inert_at_standstill` passes trivially; that's fine, it's the regression guard.

- [ ] **Step 3: Implement downforce in car.gd**

In `scripts/car.gd`, add member variables after `var drivetrain: Drivetrain` (line 4):

```gdscript
var _front_axle := Vector3.ZERO  # local midpoints, computed from wheel rest positions
var _rear_axle := Vector3.ZERO
```

At the end of `_ready()` (after the debug overlay block), add:

```gdscript
	# Axle midpoints for the downforce application points, classified the same
	# way the drivetrain splits the wheels: use_as_traction = rear.
	var fronts: Array[Vector3] = []
	var rears: Array[Vector3] = []
	for wheel in find_children("*", "VehicleWheel3D", false):
		(rears if wheel.use_as_traction else fronts).append(wheel.position)
	for p in fronts:
		_front_axle += p / fronts.size()
	for p in rears:
		_rear_axle += p / rears.size()
```

In `_physics_process`, directly after the aero-drag `apply_central_force` line (line 44), add:

```gdscript
	# Speed-squared downforce per axle, pressing the body down so suspension
	# compression raises wheel normal force (and therefore grip).
	var v2 := linear_velocity.length_squared()
	var down := -global_transform.basis.y
	apply_force(down * v2 * cfg.downforce_front, global_transform.basis * _front_axle)
	apply_force(down * v2 * cfg.downforce_rear, global_transform.basis * _rear_axle)
```

(`apply_force`'s second argument is the offset from the centre of mass in global space; rotating the local midpoint by the basis gives exactly that.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `./run_tests.sh --skip-visual`
Expected: ALL TESTS PASSED (pass 1), including the three new tests.

---

### Task 3: Final full-suite verification

**Files:** none (verification only)

- [ ] **Step 1: Run the FULL test suite (visual pass included)**

Run: `./run_tests.sh`
Expected: `ALL TESTS PASSED`. A window opens briefly for the visual pass — expected. No golden regeneration: defaults are 0.0, the rendered look is unchanged.

- [ ] **Step 2: If anything fails**

Treat the new changes as the prime suspect (per project CLAUDE.md). Do not weaken thresholds or regenerate goldens to silence failures.
