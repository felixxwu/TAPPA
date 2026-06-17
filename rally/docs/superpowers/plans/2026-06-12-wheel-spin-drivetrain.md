# Wheel Spin State & Full Drivetrain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wheels get real spin state (wheelspin, lockup, handbrake turns) via a custom drivetrain + combined-slip tire model that fully replaces Godot's wheel friction, plus spoked wheel meshes spun from the simulated state.

**Architecture:** `VehicleBody3D`/`VehicleWheel3D` keep doing suspension + raycasts only (`wheel_friction_slip = 0`). A new `scripts/drivetrain.gd` (RefCounted, stepped from `car.gd._physics_process`) owns spin states (locked rear axle + per-front-wheel), integrates drive/brake/reaction torques, computes combined-slip tire forces, applies them at the contact patches, stores readouts for the debug overlay, and writes wheel-mesh spin orientation.

**Tech Stack:** Godot 4.6 / GDScript / GUT. Test via `./run_tests.sh` (`--skip-visual` while iterating). **This project is NOT under git — no commit steps; verify with the test suite instead.**

**Spec:** `docs/superpowers/specs/2026-06-12-wheel-spin-drivetrain-design.md`

---

## File map

- Create: `scripts/drivetrain.gd` — spin states, tire model, force application, readouts, visual spin
- Create: `tests/headless/test_drivetrain.gd` — wheelspin / lockup / handbrake / parking tests
- Modify: `scripts/game_config.gd` — new sliders, remove `brake_force`
- Modify: `scripts/car.gd` — delete `_apply_drive` + contact helpers (they move to drivetrain), wire inputs to drivetrain
- Modify: `scripts/wheel_force_debug.gd` — draw drivetrain readouts instead of estimating
- Modify: `scripts/world.gd` — apply spoke colour
- Modify: `project.godot` — `handbrake` input action (Space)
- Modify: `car.tscn` — spoked wheel visuals (the car is its own scene, instanced by `main.tscn` and the flat test fixture `tests/fixtures/test_track.tscn`)
- Modify: `tests/headless/test_config_applied.gd` — friction now zeroed on wheels; new sliders sane

---

### Task 1: Config sliders and handbrake input action

**Files:**
- Modify: `scripts/game_config.gd`
- Modify: `project.godot`
- Modify: `tests/headless/test_config_applied.gd`

- [ ] **Step 1: Add failing config assertions**

In `tests/headless/test_config_applied.gd`, inside `test_config_resource_loads()` after the `engine_power` assertion, add:

```gdscript
	assert_gt(cfg.brake_torque, 0.0, "brake_torque sane")
	assert_gt(cfg.handbrake_torque, 0.0, "handbrake_torque sane")
	assert_gt(cfg.axle_inertia, 0.0, "axle_inertia sane")
	assert_gt(cfg.tire_slip_peak, 0.0, "tire_slip_peak sane")
	assert_between(cfg.sliding_grip_ratio, 0.0, 1.0, "sliding_grip_ratio sane")
	assert_true(InputMap.has_action("handbrake"), "handbrake action bound")
```

- [ ] **Step 2: Run to verify failure**

Run: `./run_tests.sh --skip-visual`
Expected: FAIL — `Invalid access to property 'brake_torque'` (script error in test).

- [ ] **Step 3: Update game_config.gd**

In `scripts/game_config.gd`, replace the line `@export var brake_force := 6.0` with:

```gdscript
@export var brake_torque := 150.0  # N·m per axle from the foot brake (S)
@export var handbrake_torque := 400.0  # N·m on the rear axle (Space)
@export var engine_braking := 30.0  # N·m drag on the rear axle at zero throttle
@export var axle_inertia := 1.5  # kg·m² rear axle spin inertia; fronts use half each
```

After the `wheel_friction_slip_rear` line, add:

```gdscript
# Tire grip curve: force rises linearly to full μN at tire_slip_peak (m/s of
# contact-patch slip), then falls off to sliding_grip_ratio when fully sliding.
@export var tire_slip_peak := 1.5
@export_range(0.1, 1.0) var sliding_grip_ratio := 0.7
```

In the `PS1 Look` group, after `wheel_color`, add:

```gdscript
@export var wheel_spoke_color := Color(0.85, 0.85, 0.78)
```

- [ ] **Step 4: Add the handbrake action to project.godot**

In `project.godot` `[input]` section, after the `toggle_debug_arrows` block, add:

```
handbrake={
"deadzone": 0.2,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":0,"physical_keycode":32,"key_label":0,"unicode":0,"location":0,"echo":false,"script":null)
]
}
```

- [ ] **Step 5: Fix the brake_force reference in car.gd (temporary shim)**

`scripts/car.gd` still references `cfg.brake_force` (twice, in the brake if/elif). Replace both occurrences of `brake = cfg.brake_force` with `brake = 1.0` for now (Task 3 deletes this block entirely; the shim just keeps the project compiling).

- [ ] **Step 6: Run to verify pass**

Run: `./run_tests.sh --skip-visual`
Expected: ALL TESTS PASSED.

---

### Task 2: Drivetrain core — spin states, tire model, force application

**Files:**
- Create: `scripts/drivetrain.gd`
- Test: `tests/headless/test_drivetrain.gd`

- [ ] **Step 1: Write failing wheelspin test**

Create `tests/headless/test_drivetrain.gd`:

```gdscript
extends GutTest

var _scene: Node3D
var _car: VehicleBody3D


func before_each() -> void:
	# Flat-ground fixture (same as test_car.gd): drivetrain behavior must not
	# depend on terrain generation settings.
	_scene = load("res://tests/fixtures/test_track.tscn").instantiate()
	add_child_autofree(_scene)
	_car = _scene.get_node("Car")
	await _wait_physics(150)


func after_each() -> void:
	for action in ["accelerate", "brake_reverse", "steer_left", "steer_right", "handbrake"]:
		Input.action_release(action)


func _wait_physics(frames: int):
	for i in frames:
		await get_tree().physics_frame


func test_launch_wheelspin() -> void:
	# Full throttle from rest: the driven axle's surface speed must run far
	# ahead of the car (wheelspin) while the car still accelerates.
	Input.action_press("accelerate")
	await _wait_physics(20)
	var r: float = Config.data.wheel_radius
	var speed := _car.linear_velocity.length()
	assert_gt(_car.drivetrain.rear_omega * r, speed * 2.0 + 1.0,
		"rear surface speed far exceeds car speed on launch")
	Input.action_release("accelerate")
	assert_gt(speed, 0.3, "car still accelerates while wheels spin")
```

- [ ] **Step 2: Run to verify failure**

Run: `./run_tests.sh --skip-visual`
Expected: FAIL — `Invalid access to property 'drivetrain'`.

- [ ] **Step 3: Create scripts/drivetrain.gd**

```gdscript
class_name Drivetrain
extends RefCounted
# Custom drivetrain + tire model. Godot's wheel friction is disabled
# (wheel_friction_slip = 0); VehicleBody3D only provides suspension and the
# wheel raycasts. This object owns the wheel spin states, integrates torques,
# computes combined-slip tire forces and applies them at the contact patches.
#
# Spin states: one omega for the locked rear axle, one per free-rolling front
# wheel. Per tick: tire forces are computed from the slip between wheel
# surface speed and ground speed; their longitudinal component reacts back on
# the spin state; drive/brake torques integrate on top.

var car: VehicleBody3D
var rear_wheels: Array = []
var front_wheels: Array = []
var hardpoints: Dictionary = {}  # wheel -> rest-pose local position
var rear_omega := 0.0  # rad/s, locked axle (both rear wheels)
var front_omega: Dictionary = {}  # front wheel -> rad/s
var spin_angle: Dictionary = {}  # wheel -> accumulated visual angle (rad)
# wheel -> {normal: float, demand: Vector3, applied: Vector3} for debug arrows
var readouts: Dictionary = {}


func _init(p_car: VehicleBody3D) -> void:
	car = p_car
	for wheel in car.find_children("*", "VehicleWheel3D", false):
		hardpoints[wheel] = wheel.position
		spin_angle[wheel] = 0.0
		if wheel.use_as_traction:
			rear_wheels.append(wheel)
		else:
			front_wheels.append(wheel)
			front_omega[wheel] = 0.0


# throttle: -1..1 drive request. brake: 0..1 foot brake. handbrake: bool.
func step(delta: float, throttle: float, brake: float, handbrake: bool) -> void:
	var cfg: GameConfig = Config.data
	readouts.clear()
	var r := cfg.wheel_radius

	# --- Tire forces from current spin state; collect reaction torques. ---
	var rear_reaction := 0.0  # N·m slowing the rear axle
	var front_reaction: Dictionary = {}
	for wheel in hardpoints:
		var f_long := _apply_tire_force(wheel, _omega_of(wheel), delta)
		if wheel.use_as_traction:
			rear_reaction += f_long * r
		else:
			front_reaction[wheel] = f_long * r

	# --- Rear axle: drive + engine braking + reaction, then brakes. ---
	# Engine torque reuses the force/power sliders, evaluated at the wheel
	# surface speed so free wheelspin self-limits at the power cap.
	var surface_speed := absf(rear_omega) * r
	var drive_torque := throttle * minf(
		cfg.engine_force, cfg.engine_power / maxf(surface_speed, 1.0)
	) * r
	if throttle == 0.0:
		drive_torque = -signf(rear_omega) * cfg.engine_braking
	rear_omega += (drive_torque - rear_reaction) / cfg.axle_inertia * delta
	var rear_brake := brake * cfg.brake_torque
	if handbrake:
		rear_brake += cfg.handbrake_torque
	# Brakes move omega toward zero but never reverse it (no sign flip-flop).
	rear_omega = move_toward(rear_omega, 0.0, rear_brake / cfg.axle_inertia * delta)

	# --- Front wheels: free-rolling, reaction + foot brake only. ---
	var front_inertia := cfg.axle_inertia * 0.5
	for wheel in front_wheels:
		var omega: float = front_omega[wheel]
		omega += -front_reaction.get(wheel, 0.0) / front_inertia * delta
		omega = move_toward(omega, 0.0, brake * cfg.brake_torque / front_inertia * delta)
		front_omega[wheel] = omega

	for wheel in hardpoints:
		spin_angle[wheel] = fmod(spin_angle[wheel] + _omega_of(wheel) * delta, TAU)


func _omega_of(wheel: VehicleWheel3D) -> float:
	return rear_omega if wheel.use_as_traction else front_omega[wheel]


# Computes and applies this wheel's tire force; returns the longitudinal
# component (N, positive = pushing the car forward) for the reaction torque.
func _apply_tire_force(wheel: VehicleWheel3D, omega: float, delta: float) -> float:
	if not wheel.is_in_contact():
		return 0.0
	var n_force := wheel_normal_force(wheel)
	if n_force <= 0.0:
		return 0.0
	var cfg: GameConfig = Config.data
	var cp: Vector3 = wheel.get_contact_point()
	var fwd := wheel_forward(wheel)
	var side := wheel_side(wheel)
	var vel := velocity_at(cp)
	# Slip velocity of the contact patch vs the ground. Positive s_long =
	# wheel surface running ahead of the ground (wheelspin) -> force forward.
	var s_long := omega * cfg.wheel_radius - fwd.dot(vel)
	var s_lat := -side.dot(vel)
	var mu: float = (
		cfg.wheel_friction_slip_front if wheel.use_as_steering
		else cfg.wheel_friction_slip_rear
	)
	# Traction ellipse via scaled slip space: weight longitudinal slip by the
	# ratio, take the grip curve on the combined magnitude, then unscale the
	# longitudinal force component (max long force = μN / ratio).
	var er: float = cfg.traction_ellipse_ratio
	var scaled := Vector2(s_long * er, s_lat)
	var s := scaled.length()
	if s < 0.001:
		readouts[wheel] = {normal = n_force, demand = Vector3.ZERO, applied = Vector3.ZERO}
		return 0.0
	var f_scaled := scaled / s * mu * n_force * _grip_curve(s)
	var f_long := f_scaled.x / er
	var f_lat := f_scaled.y
	# Low-speed stability: never push harder than what would zero the slip
	# this tick (per component, for this wheel's share of the chassis mass).
	var share := car.mass / float(hardpoints.size())
	f_long = clampf(f_long, -absf(s_long) * share / delta, absf(s_long) * share / delta)
	f_lat = clampf(f_lat, -absf(s_lat) * share / delta, absf(s_lat) * share / delta)
	var force := fwd * f_long + side * f_lat
	car.apply_force(force, cp - car.global_position)
	readouts[wheel] = {
		normal = n_force,
		demand = fwd * s_long * share / delta + side * s_lat * share / delta,
		applied = force,
	}
	return f_long


# Grip fraction (0..1 of μN) for a combined slip speed s (m/s): linear up to
# the peak, then falling off to sliding_grip_ratio over three more peaks.
func _grip_curve(s: float) -> float:
	var cfg: GameConfig = Config.data
	if s <= cfg.tire_slip_peak:
		return s / cfg.tire_slip_peak
	var t := clampf((s - cfg.tire_slip_peak) / (3.0 * cfg.tire_slip_peak), 0.0, 1.0)
	return lerpf(1.0, cfg.sliding_grip_ratio, t)


# Normal force the suspension presses this wheel into the ground with,
# mirroring the engine's spring + damper model. Zero when airborne.
func wheel_normal_force(wheel: VehicleWheel3D) -> float:
	if not wheel.is_in_contact():
		return 0.0
	var cp: Vector3 = wheel.get_contact_point()
	var down := -car.global_transform.basis.y
	var hardpoint: Vector3 = car.global_transform * hardpoints[wheel]
	var length: float = (cp - hardpoint).dot(down) - wheel.wheel_radius
	var compression: float = wheel.wheel_rest_length - length
	var proj_vel := wheel.get_contact_normal().dot(velocity_at(cp))
	var damping: float = (
		wheel.damping_compression if proj_vel < 0.0 else wheel.damping_relaxation
	)
	return maxf(
		car.mass * (wheel.suspension_stiffness * compression - damping * proj_vel), 0.0
	)


# The wheel's rolling direction projected onto the contact plane. Built from
# the car's forward plus the steering angle — the wheel node's own basis
# spins about its axle as it rolls, so it can't be used directly.
func wheel_forward(wheel: VehicleWheel3D) -> Vector3:
	var n: Vector3 = wheel.get_contact_normal()
	var fwd := (-car.global_transform.basis.z).rotated(
		car.global_transform.basis.y, wheel.steering
	)
	return (fwd - n * n.dot(fwd)).normalized()


func wheel_side(wheel: VehicleWheel3D) -> Vector3:
	return wheel_forward(wheel).cross(wheel.get_contact_normal()).normalized()


func velocity_at(point: Vector3) -> Vector3:
	return car.linear_velocity + car.angular_velocity.cross(point - car.global_position)
```

- [ ] **Step 4: Run again — still fails**

Run: `./run_tests.sh --skip-visual`
Expected: still FAIL on `drivetrain` access — `car.gd` doesn't create or step it yet. That's Task 3; proceed (the two tasks land together as one passing unit at the end of Task 3).

---

### Task 3: Wire car.gd to the drivetrain (replace old drive/brake/friction)

**Files:**
- Modify: `scripts/car.gd`

- [ ] **Step 1: Rewrite car.gd**

Replace the entire contents of `scripts/car.gd` with:

```gdscript
extends VehicleBody3D

var _start_transform: Transform3D
var drivetrain: Drivetrain


func _ready() -> void:
	_start_transform = global_transform
	var cfg: GameConfig = Config.data
	mass = cfg.mass
	linear_damp = 0.0  # aero drag below is the only speed-dependent loss
	for wheel in find_children("*", "VehicleWheel3D", false):
		# All contact friction is handled by the Drivetrain tire model; the
		# built-in solver only does suspension + raycasts.
		wheel.wheel_friction_slip = 0.0
		wheel.suspension_travel = cfg.suspension_travel
		wheel.wheel_rest_length = cfg.suspension_travel
		wheel.suspension_stiffness = cfg.suspension_stiffness
		wheel.damping_compression = cfg.suspension_damping_compression()
		wheel.damping_relaxation = cfg.suspension_damping_relaxation()
		wheel.wheel_radius = cfg.wheel_radius
	drivetrain = Drivetrain.new(self)
	var debug_overlay := WheelForceDebug.new(self)
	debug_overlay.visible = cfg.debug_wheel_forces
	add_child(debug_overlay)


func _physics_process(delta: float) -> void:
	var cfg: GameConfig = Config.data
	var throttle := Input.get_axis("brake_reverse", "accelerate")
	var moving_forward := linear_velocity.dot(-global_transform.basis.z) > 1.0
	var drive := 0.0
	var brake_input := 0.0
	if throttle < 0.0 and moving_forward:
		brake_input = 1.0  # S brakes while rolling forward, reverses otherwise
	elif throttle == 0.0 and linear_velocity.length() < 2.0:
		brake_input = 1.0  # parking brake: hold the car on slopes
	else:
		drive = throttle
	drivetrain.step(delta, drive, brake_input, Input.is_action_pressed("handbrake"))

	# Quadratic aero drag; with power-capped drive, terminal velocity is
	# cbrt(engine_power / c).
	apply_central_force(-linear_velocity * linear_velocity.length() * cfg.drag_coefficient)

	# Front wheels caster toward the direction of travel (blended in by
	# steer_travel_alignment; at 1.0 they fully track it, making countersteer
	# in a slide automatic). Steering input offsets them by a fixed steer_limit.
	var local_vel := global_transform.basis.inverse() * linear_velocity
	var travel_angle := 0.0
	if Vector2(local_vel.x, local_vel.z).length() > 2.0 and local_vel.z < 0.0:
		# Yaw of the travel direction relative to the car's forward (-Z),
		# positive to the left like VehicleWheel3D steering. Clamped so a deep
		# slide can't spin the wheels to extreme angles. Only applied when
		# moving forwards; when slow or reversing, plain input steering.
		travel_angle = clampf(atan2(-local_vel.x, -local_vel.z), -PI / 3.0, PI / 3.0)
	var steer_input := Input.get_axis("steer_right", "steer_left")
	var steer_target := travel_angle * cfg.steer_travel_alignment + steer_input * cfg.steer_limit
	steering = move_toward(steering, steer_target, cfg.steer_speed * delta)
	# Direct yaw torque about the car's up axis while steering, to fight
	# understeer when the front tires alone can't rotate the car.
	apply_torque(global_transform.basis.y * steer_input * cfg.steer_assist_torque)

	if Input.is_action_just_pressed("reset_car"):
		_reset()


func _reset() -> void:
	global_transform = _start_transform
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	drivetrain.rear_omega = 0.0
	for wheel in drivetrain.front_omega:
		drivetrain.front_omega[wheel] = 0.0
```

Notes on what changed vs the old file: `_apply_drive`, `wheel_normal_force`, `wheel_forward`, `wheel_side`, `wheel_lateral_demand`, `velocity_at`, `_hardpoints`, `_traction_wheels`, `drive_request` all removed (the drivetrain owns them); `engine_force`/`brake` properties never touched; `wheel_roll_influence` no longer applied (inert with friction zeroed); reset also zeroes spin states.

- [ ] **Step 2: Update test_config_applied.gd for zeroed wheel friction**

In `tests/headless/test_car_values_applied`, replace the `expected_slip` block:

```gdscript
		var expected_slip: float = (
			cfg.wheel_friction_slip_front if wheel.use_as_steering
			else cfg.wheel_friction_slip_rear
		)
		assert_almost_eq(wheel.wheel_friction_slip, expected_slip, 0.001, "friction " + str(wheel.name))
```

with:

```gdscript
		# Built-in friction must be OFF — the Drivetrain tire model owns all
		# contact forces (the μ sliders are consumed by drivetrain.gd instead).
		assert_almost_eq(wheel.wheel_friction_slip, 0.0, 0.001, "friction disabled " + str(wheel.name))
```

Also delete the `wheel_roll_influence` assertion line (property no longer applied).

- [ ] **Step 3: Run headless suite**

Run: `./run_tests.sh --skip-visual`
Expected: `test_launch_wheelspin` PASSES. Existing behavior tests (accelerate, steer, powerslide, top speed, settle, reset, border) should pass — if any fail, debug the tire model before moving on; the prime suspects are sign errors in `s_long`/`s_lat` and the demand clamp. Do NOT weaken existing test thresholds.

---

### Task 4: Lockup, handbrake and parking-brake tests

**Files:**
- Modify: `tests/headless/test_drivetrain.gd`

- [ ] **Step 1: Add the failing tests**

Append to `tests/headless/test_drivetrain.gd`:

```gdscript
func test_brake_lockup() -> void:
	# Hard braking at speed locks the wheels (omega -> 0) while the car is
	# still moving — the slip curve then governs the sliding grip.
	var fwd := -_car.global_transform.basis.z
	var r: float = Config.data.wheel_radius
	_car.linear_velocity = fwd * 15.0
	_car.drivetrain.rear_omega = 15.0 / r
	for w in _car.drivetrain.front_omega:
		_car.drivetrain.front_omega[w] = 15.0 / r
	Input.action_press("brake_reverse")
	await _wait_physics(30)
	Input.action_release("brake_reverse")
	assert_lt(absf(_car.drivetrain.rear_omega) * r, 1.0, "rear axle locked")
	assert_gt(_car.linear_velocity.length(), 3.0, "car still sliding while locked")


func test_handbrake_locks_rear_only_and_breaks_grip() -> void:
	var fwd := -_car.global_transform.basis.z
	var r: float = Config.data.wheel_radius
	_car.linear_velocity = fwd * 15.0
	_car.drivetrain.rear_omega = 15.0 / r
	for w in _car.drivetrain.front_omega:
		_car.drivetrain.front_omega[w] = 15.0 / r
	Input.action_press("handbrake")
	Input.action_press("steer_left")
	await _wait_physics(60)
	Input.action_release("handbrake")
	Input.action_release("steer_left")
	assert_lt(absf(_car.drivetrain.rear_omega) * r, 1.0, "handbrake locks the rear axle")
	var front_speed: float = _car.drivetrain.front_omega.values()[0] * r
	assert_gt(front_speed, 2.0, "fronts keep rolling under handbrake")
	var local_vel: Vector3 = _car.global_transform.basis.inverse() * _car.linear_velocity
	var slip := rad_to_deg(absf(atan2(local_vel.x, -local_vel.z)))
	assert_gt(slip, 10.0, "locked rears lose lateral grip -> tail steps out")


func test_parking_brake_holds_longitudinally() -> void:
	# Small forward push at rest: the parking brake (locked wheels at near-zero
	# slip) must stop it instead of letting the car creep.
	_car.linear_velocity = -_car.global_transform.basis.z * 0.5
	await _wait_physics(60)
	assert_lt(_car.linear_velocity.length(), 0.2, "parking brake stops slow creep")
```

- [ ] **Step 2: Run to verify**

Run: `./run_tests.sh --skip-visual`
Expected: all three PASS (the mechanics exist from Tasks 2–3; these tests pin the behavior). If `test_handbrake_...` slip stays under 10°, check that the handbrake torque actually drives `rear_omega` to 0 within ~20 ticks and that a locked wheel's slip vector points mostly along −fwd (consuming the budget longitudinally).

---

### Task 5: Debug overlay reads drivetrain readouts

**Files:**
- Modify: `scripts/wheel_force_debug.gd`

- [ ] **Step 1: Replace the estimation logic**

In `scripts/wheel_force_debug.gd`, replace the per-wheel body of the `for wheel in _wheels:` loop inside `_physics_process` (everything from `if not wheel.is_in_contact():` through the three `segments.append(...)` calls) with:

```gdscript
		var readout: Dictionary = car.drivetrain.readouts.get(wheel, {})
		if readout.is_empty():
			continue
		var cp: Vector3 = wheel.get_contact_point()
		var n: Vector3 = wheel.get_contact_normal()
		segments.append([cp, cp + n * readout.normal * scale_m_per_n, SUSPENSION_COLOR])
		segments.append([cp, cp + readout.demand * scale_m_per_n, RAW_FRICTION_COLOR])
		segments.append([cp, cp + readout.applied * scale_m_per_n, FRICTION_COLOR])
```

Update the header comment block to:

```gdscript
# Debug overlay drawing per-wheel force arrows, rebuilt every physics tick.
# Green = suspension force, yellow = raw tire friction demand (the impulse
# that would zero the contact-patch slip this tick), red = force actually
# applied by the Drivetrain tire model. Red shorter than yellow = saturated.
# Values are read directly from drivetrain.readouts — exact, not estimates.
```

Delete the now-unused private estimation helpers in this file (everything that duplicated normal-force / forward / side / lateral-demand math, and the brake-share computation).

- [ ] **Step 2: Run headless suite**

Run: `./run_tests.sh --skip-visual`
Expected: ALL TESTS PASSED (including `test_debug_arrows.gd` — arrows still drawn when grounded + H toggle works).

---

### Task 6: Spoked wheel visuals driven by spin state

**Files:**
- Modify: `car.tscn`
- Modify: `scripts/world.gd`
- Modify: `scripts/drivetrain.gd`
- Modify: `tests/headless/test_config_applied.gd`

- [ ] **Step 1: Add spoke material + meshes to car.tscn**

In `car.tscn` (note: the car lives in its own scene now; it has no `unique_id` attributes — don't add any), after the `mat_wheel` sub_resource, add:

```
[sub_resource type="ShaderMaterial" id="mat_spoke"]
render_priority = 0
shader = ExtResource("1_models")
shader_parameter/albedo_color = Color(0.85, 0.85, 0.78, 1)
shader_parameter/texture_tile = Vector2(1, 1)

[sub_resource type="BoxMesh" id="mesh_spoke"]
size = Vector3(0.27, 0.62, 0.06)
```

(`mesh_spoke` is a full-diameter bar: 0.27 along the axle so it pokes out of the 0.25-wide tire, 0.62 across the 0.7 wheel diameter, 0.06 thick. Two crossed bars = 4 spokes.)

For EACH of the four wheels (`WheelFL`, `WheelFR`, `WheelRL`, `WheelRR`), replace its `MeshInstance3D` child block, e.g. for WheelFL:

```
[node name="MeshInstance3D" type="MeshInstance3D" parent="WheelFL"]
transform = Transform3D(0, -1, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0)
mesh = SubResource("mesh_wheel")
surface_material_override/0 = SubResource("mat_wheel")
```

with a Visual container:

```
[node name="Visual" type="Node3D" parent="WheelFL"]

[node name="Tire" type="MeshInstance3D" parent="WheelFL/Visual"]
transform = Transform3D(0, -1, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0)
mesh = SubResource("mesh_wheel")
surface_material_override/0 = SubResource("mat_wheel")

[node name="Spoke1" type="MeshInstance3D" parent="WheelFL/Visual"]
mesh = SubResource("mesh_spoke")
surface_material_override/0 = SubResource("mat_spoke")

[node name="Spoke2" type="MeshInstance3D" parent="WheelFL/Visual"]
transform = Transform3D(1, 0, 0, 0, 0, -1, 0, 1, 0, 0, 0, 0)
mesh = SubResource("mesh_spoke")
surface_material_override/0 = SubResource("mat_spoke")
```

(The spoke box's 0.27 dimension already lies along wheel-local X = the axle, and its 0.62 long axis along Y, so Spoke1 is an identity transform — a vertical bar — and Spoke2 is the same bar rotated 90° about the axle, forming a cross = 4 spokes. Repeat for FR/RL/RR, changing only the `parent=` paths.)

- [ ] **Step 2: world.gd — apply spoke colour and fix the wheel-colour path**

In `scripts/world.gd`, the wheel colour line references `$Car/WheelFL/MeshInstance3D` — update it and add the spoke colour:

```gdscript
	# Wheel materials are shared resources; setting each once covers all four.
	_mat($Car/WheelFL/Visual/Tire).set_shader_parameter("albedo_color", cfg.wheel_color)
	_mat($Car/WheelFL/Visual/Spoke1).set_shader_parameter("albedo_color", cfg.wheel_spoke_color)
```

(`_mat` uses `get_surface_override_material(0)` which matches `surface_material_override/0`.)

- [ ] **Step 3: Drivetrain writes visual spin**

In `scripts/drivetrain.gd`, extend `_init` to cache the visuals:

```gdscript
var visuals: Dictionary = {}  # wheel -> Node3D spun about the axle
```

and in the `_init` wheel loop add:

```gdscript
		visuals[wheel] = wheel.get_node_or_null("Visual")
```

At the end of `step()`, after the spin_angle update loop, add:

```gdscript
	_update_visuals()
```

and the method:

```gdscript
# Wheel meshes spin from the SIMULATED omega, not Godot's ground-speed
# estimate, so wheelspin and lockup are visible. The Visual node's basis is
# rebuilt in wheel-local space: the VehicleWheel3D node auto-rotates about
# its own axle for display, so we counter it by overwriting the child's
# global basis from the car + steering + our spin angle. The wheel nodes are
# rotated 180° about Y in the scene, hence the PI; positive omega must roll
# the wheel forward (car -Z), hence the negative spin sign.
func _update_visuals() -> void:
	for wheel in visuals:
		var visual: Node3D = visuals[wheel]
		if visual == null:
			continue
		visual.global_basis = (
			car.global_basis
			* Basis(Vector3.UP, wheel.steering + PI)
			* Basis(Vector3.RIGHT, -spin_angle[wheel])
		)
```

- [ ] **Step 4: Add a structural test**

In `tests/headless/test_config_applied.gd`, append to `test_world_values_applied()`:

```gdscript
	var tire_mat: ShaderMaterial = scene.get_node("Car/WheelFL/Visual/Tire").get_surface_override_material(0)
	assert_eq(tire_mat.get_shader_parameter("albedo_color"), cfg.wheel_color, "tire color from config")
	var spoke_mat: ShaderMaterial = scene.get_node("Car/WheelFL/Visual/Spoke1").get_surface_override_material(0)
	assert_eq(spoke_mat.get_shader_parameter("albedo_color"), cfg.wheel_spoke_color, "spoke color from config")
```

- [ ] **Step 5: Run headless suite**

Run: `./run_tests.sh --skip-visual`
Expected: ALL TESTS PASSED. If the scene fails to parse, re-check the sub_resource/node ordering in `main.tscn` (sub_resources must precede the nodes using them).

---

### Task 7: Full verification + golden regen

- [ ] **Step 1: Full suite (visual will fail on the new wheels)**

Run: `./run_tests.sh`
Expected: headless green; visual FAILS (spoked wheels changed the look — intentional).

- [ ] **Step 2: Regenerate the golden and verify**

Run: `./run_tests.sh --regen-goldens && ./run_tests.sh`
Expected: ALL TESTS PASSED. Eyeball `tests/golden/main_scene.png` — the car must show spoked wheels and otherwise look unchanged.

- [ ] **Step 3: Sanity sweep**

Run: `grep -rn "brake_force\|_apply_drive\|wheel_lateral_demand\|drive_request" --include="*.gd" .`
Expected: no hits (all old-model references gone).
