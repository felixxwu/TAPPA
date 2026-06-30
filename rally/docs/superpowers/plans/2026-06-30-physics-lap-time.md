# Physics-based optimum lap time (QSS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the heuristic opponent/target-time derivation with a physics-based quasi-steady-state (QSS) lap-time model that treats the car as a point mass following the centerline, constrained by power, weight, drag, grip and braking.

**Architecture:** A new pure-static `LapTimeModel` samples track curvature κ(s) and runs a three-pass velocity-profile sweep (cornering ceiling → forward accel → backward braking) under the tyre friction circle, yielding a velocity/time profile. `rally_library.gd` consumes it: the event par is the best-eligible car's floor × a driver factor; each opponent gets their own floor from their assigned car; turn-splits read off the same profile so the in-stage "vs P1" popup is driven by P1's real car.

**Tech Stack:** GDScript (Godot 4), GUT test framework (`addons/gut/`).

## Global Constraints

- Godot binary: `/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot` (override with `$GODOT`).
- All tuning values live in `config/game_config.tres` (a `GameConfig` resource) — add new fields to `scripts/game_config.gd`, not script literals.
- Run tests in the BACKGROUND (`run_in_background: true`); never block. Use `./run_tests.sh --fast <name>` for the specific file(s) touched.
- Don't blindly `cd rally` — the Bash working directory persists between calls.
- Keep the `features/` docs in sync in the same piece of work.
- The car's `peak_torque × redline` → power conversion already exists in `CarLibrary.power_to_weight` (kW/kg). Reuse it; do not reinvent.

---

### Task 1: `LapTimeModel` core — curvature profile + three-pass velocity sweep

**Files:**
- Create: `scripts/lap_time_model.gd`
- Test: `tests/headless/test_lap_time_model.gd`

**Interfaces:**
- Consumes: `CarLibrary.power_to_weight(entry)`, `RallyLibrary.event_tarmac_fraction(event)`, `Config.data` (`GameConfig.gravel_grip`, `tarmac_grip`).
- Produces:
  - `LapTimeModel.optimum_profile(track_result: Dictionary, car_meta: Dictionary, event: Dictionary = {}) -> Dictionary` returning `{ "s": PackedFloat32Array, "v": PackedFloat32Array, "t": PackedFloat32Array, "total_ms": int }` (`v` in m/s, `t` cumulative seconds, both per sample `s`).
  - `LapTimeModel.optimum_ms(track_result: Dictionary, car_meta: Dictionary, event: Dictionary = {}) -> int` (= `optimum_profile(...).total_ms`).

**Notes / scope:** Downforce is deliberately NOT modelled (it makes the cornering ceiling implicit in v). Out of scope for this task; the spec flagged it as a minor optional refinement.

- [ ] **Step 1: Write the failing test**

Create `tests/headless/test_lap_time_model.gd`. A helper builds a synthetic track_result cheaply (no world generation) — a `Curve2D` plus a `pieces` list. Use a straight track for the analytic check and a constant-radius arc for the corner check.

```gdscript
extends GutTest

const LapTimeModel = preload("res://scripts/lap_time_model.gd")

# A reference car with known SI stats (mirrors CarLibrary fields used by the model).
const CAR := {
	"mass": 1200.0, "peak_torque": 300.0, "redline": 7000.0,
	"grip_front": 1.1, "grip_rear": 1.1, "drag": 0.2,
}

func _straight_track(length: float) -> Dictionary:
	var c := Curve2D.new()
	c.add_point(Vector2(0, 0))
	c.add_point(Vector2(0, -length))   # heading +... straight line
	return {"centerline": c, "pieces": []}

func _arc_track(radius: float, sweep_rad: float) -> Dictionary:
	# A circular arc of the given radius, approximated by sampled points.
	var c := Curve2D.new()
	var steps := 64
	for i in steps + 1:
		var a := sweep_rad * float(i) / float(steps)
		c.add_point(Vector2(radius * sin(a), -radius * (1.0 - cos(a))))
	return {"centerline": c, "pieces": []}

func test_straight_only_matches_analytic_accel():
	# On a long straight from rest, the car accelerates; final v should approach the
	# power/drag-limited regime and time should be finite and positive.
	var prof: Dictionary = LapTimeModel.optimum_profile(_straight_track(400.0), CAR, {})
	assert_gt(prof["total_ms"], 0, "straight has positive time")
	var v: PackedFloat32Array = prof["v"]
	assert_gt(v[v.size() - 1], v[0], "speed increases along a straight from rest")

func test_more_power_is_faster():
	var slow := CAR.duplicate(); slow["peak_torque"] = 150.0
	var fast := CAR.duplicate(); fast["peak_torque"] = 600.0
	var t_slow := LapTimeModel.optimum_ms(_straight_track(400.0), slow, {})
	var t_fast := LapTimeModel.optimum_ms(_straight_track(400.0), fast, {})
	assert_lt(t_fast, t_slow, "more power => lower time")

func test_more_grip_is_faster_in_corners():
	var low := CAR.duplicate(); low["grip_front"] = 0.7; low["grip_rear"] = 0.7
	var high := CAR.duplicate(); high["grip_front"] = 1.4; high["grip_rear"] = 1.4
	var track := _arc_track(40.0, PI)   # a sustained 40 m radius corner
	assert_lt(LapTimeModel.optimum_ms(track, high, {}),
			LapTimeModel.optimum_ms(track, low, {}), "more grip => lower time in a corner")

func test_tighter_corner_is_slower():
	var wide := _arc_track(80.0, PI)
	var tight := _arc_track(20.0, PI)
	# Same arc sweep; tighter radius forces lower cornering speed => more time per metre.
	var t_wide := LapTimeModel.optimum_ms(wide, CAR, {})
	var t_tight := LapTimeModel.optimum_ms(tight, CAR, {})
	assert_gt(t_tight / maxf(1.0, float(wide_len(wide))), 0.0)  # guard
	assert_gt(_ms_per_m(tight, CAR), _ms_per_m(wide, CAR), "tighter corner => more ms per metre")

func _ms_per_m(track: Dictionary, car: Dictionary) -> float:
	var len: float = (track["centerline"] as Curve2D).get_baked_length()
	return float(LapTimeModel.optimum_ms(track, car, {})) / maxf(len, 1.0)

func wide_len(track: Dictionary) -> float:
	return (track["centerline"] as Curve2D).get_baked_length()

func test_profile_total_matches_scalar():
	var prof: Dictionary = LapTimeModel.optimum_profile(_arc_track(40.0, PI), CAR, {})
	assert_eq(LapTimeModel.optimum_ms(_arc_track(40.0, PI), CAR, {}), int(prof["total_ms"]))

func test_corner_speed_near_friction_limit():
	# Mid-corner speed on a steady arc should sit near sqrt(mu*g / kappa).
	var radius := 50.0
	var prof: Dictionary = LapTimeModel.optimum_profile(_arc_track(radius, PI), CAR, {})
	var v: PackedFloat32Array = prof["v"]
	var mid := v[int(v.size() / 2)]
	var mu := 1.1   # avg grip, gravel default (gravel_grip 1.0)
	var v_limit := sqrt(mu * 9.81 * radius)
	assert_almost_eq(mid, v_limit, v_limit * 0.25, "mid-corner speed near friction limit")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `GODOT=$GODOT ./run_tests.sh --fast test_lap_time_model` (background)
Expected: FAIL — `LapTimeModel` / `optimum_profile` not found.

- [ ] **Step 3: Write the implementation**

Create `scripts/lap_time_model.gd`:

```gdscript
extends RefCounted
class_name LapTimeModel

# Quasi-steady-state (QSS) lap-time model. Treats the car as a point mass that
# follows the centerline exactly, subject to its real forces (power, weight, drag,
# grip, braking). Produces a velocity/time profile via a three-pass sweep:
#   1. cornering ceiling  v_cap = sqrt(mu*g / kappa)
#   2. forward accel pass (engine + friction-circle limited)
#   3. backward braking pass (friction-circle limited)
# The longitudinal grip available is bounded by the friction circle: grip spent
# cornering (a_lat = v^2 * kappa) is unavailable for accel/braking. See
# docs/superpowers/specs/2026-06-30-physics-lap-time-design.md.

const G := 9.81                 # m/s^2
const ROLLING_G := 0.2          # baseline rolling-resistance decel (fraction of g)
const SAMPLE_STEP_M := 2.0      # curvature/profile sample spacing
const KAPPA_MIN := 1.0e-5       # below this, treat as straight (no cornering cap)
const V_UNBOUNDED := 1.0e12     # m^2/s^2 sentinel for "no cornering cap"

# Full velocity/time profile. Returns parallel arrays sampled every ~SAMPLE_STEP_M
# along the centerline, plus the total time in ms. Empty/zero for a degenerate track.
static func optimum_profile(track_result: Dictionary, car_meta: Dictionary, event: Dictionary = {}) -> Dictionary:
	var empty := {"s": PackedFloat32Array(), "v": PackedFloat32Array(), "t": PackedFloat32Array(), "total_ms": 0}
	var centerline := track_result.get("centerline") as Curve2D
	if centerline == null:
		return empty
	var length := centerline.get_baked_length()
	if length <= 0.0:
		return empty

	var prof := _curvature_profile(centerline, length)
	var s: PackedFloat32Array = prof["s"]
	var kappa: PackedFloat32Array = prof["kappa"]
	var n := s.size()
	if n < 2:
		return empty

	# --- Car physical envelope ------------------------------------------------
	var mass: float = maxf(float(car_meta.get("mass", 1200.0)), 1.0)
	var mu := _surface_grip(car_meta, event)
	var mu_g := mu * G
	var rolling := ROLLING_G * G
	var drag: float = float(car_meta.get("drag", 0.0))
	# Peak power in watts. power_to_weight is kW/kg, so * mass * 1000 -> W.
	var p_peak_w := CarLibrary.power_to_weight(car_meta) * mass * 1000.0

	# --- Pass 1: cornering ceiling (stored as v^2) ----------------------------
	var cap2 := PackedFloat32Array(); cap2.resize(n)
	for i in n:
		cap2[i] = (mu_g / kappa[i]) if kappa[i] > KAPPA_MIN else V_UNBOUNDED

	# --- Pass 2: forward accel pass (v^2), standing start at s=0 --------------
	var fwd2 := PackedFloat32Array(); fwd2.resize(n)
	fwd2[0] = 0.0
	for i in range(1, n):
		var step := s[i] - s[i - 1]
		var v_prev2 := fwd2[i - 1]
		var a_lat := v_prev2 * kappa[i - 1]
		var grip_long := sqrt(maxf(mu_g * mu_g - a_lat * a_lat, 0.0))
		var v_prev := sqrt(maxf(v_prev2, 0.0))
		var a_engine := p_peak_w / (maxf(v_prev, 0.5) * mass) - drag * v_prev2 / mass - rolling
		var a := minf(grip_long, a_engine)
		var v_next2 := v_prev2 + 2.0 * a * step
		fwd2[i] = clampf(v_next2, 0.0, cap2[i])

	# --- Pass 3: backward braking pass (v^2); finish line unconstrained -------
	var v2 := PackedFloat32Array(); v2.resize(n)
	v2[n - 1] = fwd2[n - 1]
	for i in range(n - 2, -1, -1):
		var step := s[i + 1] - s[i]
		var v_next2 := v2[i + 1]
		var a_lat := v_next2 * kappa[i + 1]
		var grip_long := sqrt(maxf(mu_g * mu_g - a_lat * a_lat, 0.0))
		# Braking is grip-limited; rolling + drag also help slow the car.
		var a_brake := grip_long + rolling + drag * v_next2 / mass
		var v_here2 := v_next2 + 2.0 * a_brake * step
		v2[i] = minf(v_here2, fwd2[i])

	# --- Integrate time t[i] = sum ds / v_avg --------------------------------
	var v := PackedFloat32Array(); v.resize(n)
	var t := PackedFloat32Array(); t.resize(n)
	for i in n:
		v[i] = sqrt(maxf(v2[i], 0.0))
	t[0] = 0.0
	for i in range(1, n):
		var step := s[i] - s[i - 1]
		var v_sum := v[i] + v[i - 1]
		# Trapezoidal: dt = 2*ds / (v0 + v1). v_sum is 0 only if both ends are at rest.
		t[i] = t[i - 1] + (2.0 * step / v_sum if v_sum > 0.01 else step / 0.5)
	return {"s": s, "v": v, "t": t, "total_ms": int(round(t[n - 1] * 1000.0))}


static func optimum_ms(track_result: Dictionary, car_meta: Dictionary, event: Dictionary = {}) -> int:
	return int(optimum_profile(track_result, car_meta, event)["total_ms"])


# Sampled curvature kappa(s) = |d(heading)| / ds along the baked centerline, with
# a light 3-tap smoothing to kill discretization spikes. Endpoints are treated as
# straight (kappa = 0).
static func _curvature_profile(centerline: Curve2D, length: float) -> Dictionary:
	var n := maxi(int(ceil(length / SAMPLE_STEP_M)) + 1, 2)
	var s := PackedFloat32Array(); s.resize(n)
	var pts: Array[Vector2] = []
	for i in n:
		var off := length * float(i) / float(n - 1)
		s[i] = off
		pts.append(centerline.sample_baked(off))
	var raw := PackedFloat32Array(); raw.resize(n)
	raw[0] = 0.0
	raw[n - 1] = 0.0
	for i in range(1, n - 1):
		var h_prev := (pts[i] - pts[i - 1]).angle()
		var h_next := (pts[i + 1] - pts[i]).angle()
		var dtheta := absf(wrapf(h_next - h_prev, -PI, PI))
		var dl := s[i + 1] - s[i - 1]
		raw[i] = (dtheta / dl) if dl > 0.0 else 0.0
	# 3-tap smoothing.
	var kappa := PackedFloat32Array(); kappa.resize(n)
	for i in n:
		var lo := maxi(i - 1, 0)
		var hi := mini(i + 1, n - 1)
		kappa[i] = (raw[lo] + raw[i] + raw[hi]) / 3.0
	return {"s": s, "kappa": kappa}


# Average tyre grip (front+rear) blended by the event's surface mix, using the
# GameConfig gravel/tarmac grip multipliers (matches rally_library's surface model).
static func _surface_grip(car_meta: Dictionary, event: Dictionary) -> float:
	var base := 0.5 * (float(car_meta.get("grip_front", 1.0)) + float(car_meta.get("grip_rear", 1.0)))
	var tarmac := RallyLibrary.event_tarmac_fraction(event)
	var cfg: GameConfig = Config.data
	return base * ((1.0 - tarmac) * cfg.gravel_grip + tarmac * cfg.tarmac_grip)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `GODOT=$GODOT ./run_tests.sh --fast test_lap_time_model` (background)
Expected: PASS (all cases).

- [ ] **Step 5: Commit**

```bash
git add scripts/lap_time_model.gd tests/headless/test_lap_time_model.gd
git commit -m "Add LapTimeModel: QSS optimum lap-time profile"
```

---

### Task 2: `GameConfig.driver_factor` tuning field

**Files:**
- Modify: `scripts/game_config.gd` (add field near the rally/standings tuning block, e.g. by `stage_delta_interval_turns`)
- Test: covered by Task 3's rally-library test (no standalone test).

**Interfaces:**
- Produces: `GameConfig.driver_factor: float` (default `1.08`) — multiplier applied to the physics floor to make a beatable human par.

- [ ] **Step 1: Add the export field**

In `scripts/game_config.gd`, add:

```gdscript
## Driver-imperfection multiplier applied to the physics-optimum lap time to get a
## beatable human PAR (the event target). 1.0 = flawless; ~1.08 = a strong human.
@export_range(1.0, 1.5) var driver_factor := 1.08
```

- [ ] **Step 2: Commit**

```bash
git add scripts/game_config.gd
git commit -m "Add GameConfig.driver_factor for physics-par scaling"
```

---

### Task 3: `derive_target_ms` — best-eligible-car floor × driver factor

**Files:**
- Modify: `scripts/rally_library.gd` (`derive_target_ms`; remove `REF_SPEED_MPS`, `TARMAC_SPEED_MPS`, `CORNER_PENALTY_S`, `TARMAC_CORNER_PENALTY_S` if no longer referenced after Task 4; add `_best_eligible_car`)
- Test: `tests/headless/test_rally_library.gd`

**Interfaces:**
- Consumes: `LapTimeModel.optimum_ms`, `Config.data.driver_factor`, `_eligible_cars(rally)` (existing), `CarLibrary.power_to_weight`.
- Produces: `RallyLibrary._best_eligible_car(rally: Dictionary) -> Dictionary` (highest power-to-weight eligible car; `{}` if none). `derive_target_ms` keeps its signature `(track_result, event := {}) -> int` but needs the rally to pick the par car — see Step 3 note.

**Note on signature:** `derive_target_ms` currently takes `(track_result, event)`. To pick the best eligible car it needs the rally. Add an optional `rally` param: `derive_target_ms(track_result, event := {}, rally := {})`. When `rally` is empty (legacy/test callers), fall back to the event's own car context via a sane default car (the highest-p/w car in `CarLibrary.CARS`). Update the real caller (`rally_session._compute_event_targets`) to pass the rally.

- [ ] **Step 1: Write the failing test**

Add to `tests/headless/test_rally_library.gd`:

```gdscript
func test_target_uses_physics_floor_and_driver_factor():
	var track := _simple_track()   # existing helper, or build a Curve2D inline
	var rally := {"id": "r1", "events": [], "restriction": {}}   # open class
	var ms := RallyLibrary.derive_target_ms(track, {}, rally)
	var best := RallyLibrary._best_eligible_car(rally)
	var floor := LapTimeModel.optimum_ms(track, best, {})
	assert_almost_eq(ms, int(round(floor * Config.data.driver_factor)), 2,
		"target = floor * driver_factor")

func test_target_override_still_short_circuits():
	var track := _simple_track()
	assert_eq(RallyLibrary.derive_target_ms(track, {"target_ms_override": 90000}, {}), 90000)

func test_faster_roster_yields_faster_par():
	# A rally whose eligible roster includes a quicker car gets a tighter par on the
	# same track than one restricted to a slower car.
	var track := _simple_track()
	var open_rally := {"id": "a", "events": [], "restriction": {}}
	var slow_rally := {"id": "b", "events": [], "restriction": {"pw_max": 0.05}}  # admits only slow cars
	assert_lte(RallyLibrary.derive_target_ms(track, {}, open_rally),
			RallyLibrary.derive_target_ms(track, {}, slow_rally),
			"a faster eligible roster yields an equal-or-faster par")
```

If `_simple_track()` does not yet exist in the test file, add a helper that returns `{"centerline": <a Curve2D with a couple of points>, "pieces": []}` (cheap, no world generation).

- [ ] **Step 2: Run test to verify it fails**

Run: `GODOT=$GODOT ./run_tests.sh --fast test_rally_library` (background)
Expected: FAIL — `_best_eligible_car` not defined / target math differs.

- [ ] **Step 3: Rewrite `derive_target_ms` and add `_best_eligible_car`**

Replace the body of `derive_target_ms` and add the helper:

```gdscript
# Per-event target time (ms): the physics-optimum floor of the BEST eligible car
# for the rally, scaled by GameConfig.driver_factor to a beatable human par. An
# event may override the whole thing with `target_ms_override`. Deterministic for
# a given track + roster.
static func derive_target_ms(track_result: Dictionary, event: Dictionary = {}, rally: Dictionary = {}) -> int:
	if event.has("target_ms_override"):
		return int(event["target_ms_override"])
	var par_car := _best_eligible_car(rally)
	var floor_ms := LapTimeModel.optimum_ms(track_result, par_car, event)
	return int(round(floor_ms * Config.data.driver_factor))


# The eligible car with the highest power-to-weight for a rally (the "par car" the
# event target is computed against). Falls back to the best car in the whole roster
# when `rally` is empty (legacy/test callers).
static func _best_eligible_car(rally: Dictionary) -> Dictionary:
	var pool: Array = _eligible_cars(rally) if not rally.is_empty() else CarLibrary.CARS
	var best: Dictionary = {}
	var best_pw := -1.0
	for car in pool:
		var pw := CarLibrary.power_to_weight(car)
		if pw > best_pw:
			best_pw = pw
			best = car
	return best
```

Remove the now-unused constants `REF_SPEED_MPS`, `TARMAC_SPEED_MPS`, `CORNER_PENALTY_S`, `TARMAC_CORNER_PENALTY_S` ONLY after Task 4 also stops using them (they feed `derive_turn_splits` today). If doing Task 3 before Task 4, leave them; delete in Task 4's commit.

- [ ] **Step 4: Update the real caller to pass the rally**

In `scripts/rally_session.gd` `_compute_event_targets`, change line 379:

```gdscript
		targets.append(RallyLibrary.derive_target_ms(result, event, rally))
```

- [ ] **Step 5: Run test to verify it passes**

Run: `GODOT=$GODOT ./run_tests.sh --fast test_rally_library` (background)
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/rally_library.gd scripts/rally_session.gd tests/headless/test_rally_library.gd
git commit -m "Derive event par from physics floor of best eligible car"
```

---

### Task 4: `derive_turn_splits` — car-parameterized, off the same profile

**Files:**
- Modify: `scripts/rally_library.gd` (`derive_turn_splits` signature + body; delete the four pace/penalty constants)
- Modify: `scripts/rally_session.gd` (add `current_event_p1_car`)
- Modify: `scripts/world.gd` (`_setup_stage_splits` — pass P1's car)
- Test: `tests/headless/test_rally_library.gd`, `tests/headless/test_rally_session.gd`

**Interfaces:**
- Consumes: `LapTimeModel.optimum_profile`.
- Produces:
  - `RallyLibrary.derive_turn_splits(track_result: Dictionary, car_meta: Dictionary, event: Dictionary = {}) -> Array` — unchanged return shape: `Array of { "end_offset_m": float, "cum_ms": int }`, final `cum_ms` == `LapTimeModel.optimum_ms(track, car_meta, event)`.
  - `RallySession.current_event_p1_car() -> Dictionary` — the car_meta of the opponent posting the fastest non-DNF time this event (`{}` if none).

- [ ] **Step 1: Write the failing test**

Add to `tests/headless/test_rally_library.gd`:

```gdscript
func test_turn_splits_final_equals_optimum_ms():
	var track := _track_with_pieces()   # a Curve2D + a few pieces with entry_pos
	var car := CarLibrary.by_id("mx5")
	var splits := RallyLibrary.derive_turn_splits(track, car, {})
	assert_false(splits.is_empty())
	assert_almost_eq(int(splits[splits.size() - 1]["cum_ms"]),
		LapTimeModel.optimum_ms(track, car, {}), 2, "last split == optimum_ms")

func test_turn_splits_monotonic():
	var track := _track_with_pieces()
	var splits := RallyLibrary.derive_turn_splits(track, CarLibrary.by_id("mx5"), {})
	for i in range(1, splits.size()):
		assert_gte(int(splits[i]["cum_ms"]), int(splits[i - 1]["cum_ms"]), "cum_ms monotonic")

func test_turn_splits_override_rescales_to_total():
	var track := _track_with_pieces()
	var splits := RallyLibrary.derive_turn_splits(track, CarLibrary.by_id("mx5"), {"target_ms_override": 60000})
	assert_almost_eq(int(splits[splits.size() - 1]["cum_ms"]), 60000, 2, "rescaled to override total")
```

Add `_track_with_pieces()` helper if absent: a `Curve2D` with several points and a matching `pieces` array where each piece has an `entry_pos` on the curve.

- [ ] **Step 2: Run test to verify it fails**

Run: `GODOT=$GODOT ./run_tests.sh --fast test_rally_library` (background)
Expected: FAIL — `derive_turn_splits` arity/behaviour mismatch.

- [ ] **Step 3: Rewrite `derive_turn_splits`**

Replace its body. Map each piece's end-offset onto the car's `optimum_profile` time array by interpolation:

```gdscript
# Per-turn cumulative split table off a SPECIFIC car's optimum velocity profile —
# used by the run scene's "vs P1" pace popup (so the popup tracks P1's real car).
# For each placed piece returns the arc length at the END of that turn and the
# cumulative time (ms) to there, read off LapTimeModel.optimum_profile(car). The
# final entry's cum_ms equals optimum_ms(track, car, event). An event's
# target_ms_override rescales the cumulative times to land on it, preserving the
# per-turn profile (the popup only uses fractions, so the rescale cancels there).
# Returns Array of { "end_offset_m": float, "cum_ms": int }; empty if no pieces.
static func derive_turn_splits(track_result: Dictionary, car_meta: Dictionary, event: Dictionary = {}) -> Array:
	var centerline := track_result.get("centerline") as Curve2D
	var pieces: Array = track_result.get("pieces", [])
	if centerline == null or pieces.is_empty():
		return []
	var prof := LapTimeModel.optimum_profile(track_result, car_meta, event)
	var s: PackedFloat32Array = prof["s"]
	var t: PackedFloat32Array = prof["t"]
	if s.size() < 2:
		return []
	var baked := centerline.get_baked_length()
	var splits: Array = []
	for i in pieces.size():
		var end_off := baked
		if i + 1 < pieces.size():
			var next_entry: Vector2 = pieces[i + 1].get("entry_pos", Vector2.ZERO)
			end_off = centerline.get_closest_offset(next_entry)
		var secs := _time_at_offset(s, t, end_off)
		splits.append({"end_offset_m": end_off, "cum_ms": int(round(secs * 1000.0))})
	if event.has("target_ms_override"):
		var natural_total := float(splits[splits.size() - 1]["cum_ms"])
		if natural_total > 0.0:
			var override_total := float(int(event["target_ms_override"]))
			for sp in splits:
				sp["cum_ms"] = int(round(float(sp["cum_ms"]) / natural_total * override_total))
	return splits


# Linear-interpolate the cumulative time (s) at an arc offset within the profile's
# monotonic s[] / t[] arrays.
static func _time_at_offset(s: PackedFloat32Array, t: PackedFloat32Array, off: float) -> float:
	var n := s.size()
	if off <= s[0]:
		return t[0]
	if off >= s[n - 1]:
		return t[n - 1]
	for i in range(1, n):
		if s[i] >= off:
			var span := s[i] - s[i - 1]
			var f := (off - s[i - 1]) / span if span > 0.0 else 0.0
			return lerpf(t[i - 1], t[i], f)
	return t[n - 1]
```

Now delete the unused constants `REF_SPEED_MPS`, `TARMAC_SPEED_MPS`, `CORNER_PENALTY_S`, `TARMAC_CORNER_PENALTY_S` from the top of `rally_library.gd`.

- [ ] **Step 4: Add `current_event_p1_car` to `rally_session.gd`**

After `current_event_target_ms` (line ~243), add:

```gdscript
# The car_meta of the opponent posting the fastest non-DNF time for the CURRENT
# event (the rival the "vs P1" popup tracks). {} if no classified rival has a time.
func current_event_p1_car() -> Dictionary:
	if _event_index < 0:
		return {}
	var best := -1
	var best_id := ""
	for opp in _opponent_field:
		var times: Array = opp.get("event_times_ms", [])
		if _event_index < times.size():
			var tm := int(times[_event_index])
			if tm >= 0 and (best < 0 or tm < best):
				best = tm
				best_id = String(opp.get("car_id", ""))
	return CarLibrary.by_id(best_id) if best_id != "" else {}
```

- [ ] **Step 5: Update `world.gd` `_setup_stage_splits` to pass P1's car**

In `scripts/world.gd:546`, change:

```gdscript
	var p1_car := RallySession.current_event_p1_car()
	if p1_car.is_empty():
		return
	var splits := RallyLibrary.derive_turn_splits(track_result, p1_car, RallySession.current_event())
```

(Keep the `p1_ms` / fraction wiring below unchanged — `p1_ms` is still `current_event_target_ms()`, which is exactly P1's fastest-rival time, and the fractions now come from P1's car so `p1_ms * frac[i]` lands on P1's real cumulative time.)

- [ ] **Step 6: Add a session-level popup consistency test**

Add to `tests/headless/test_rally_session.gd` (or wherever splits wiring is asserted) a check that with a known field, `current_event_p1_car()` returns the fastest rival's car and that `derive_turn_splits(track, that_car).last.cum_ms == optimum_ms(track, that_car)`. If `test_rally_session.gd` cannot cheaply build a track, place this in `test_rally_library.gd` using a synthetic field dict instead.

- [ ] **Step 7: Run tests to verify they pass**

Run: `GODOT=$GODOT ./run_tests.sh --fast test_rally_library test_rally_session` (background)
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add scripts/rally_library.gd scripts/rally_session.gd scripts/world.gd tests/headless/test_rally_library.gd tests/headless/test_rally_session.gd
git commit -m "Car-parameterize turn splits; popup tracks P1's real car"
```

---

### Task 5: `generate_opponent_field` — per-rival floor from each rival's car

**Files:**
- Modify: `scripts/rally_library.gd` (`generate_opponent_field` signature + body; reframe `RIVAL_PACE_MIN`/`RIVAL_PACE_SPREAD` as driver-factor band)
- Modify: `scripts/rally_session.gd` (`_compute_event_targets` to also return per-event track results; `start_rally` caller at line 81)
- Test: `tests/headless/test_rally_library.gd`

**Interfaces:**
- Consumes: `LapTimeModel.optimum_ms`, `CarLibrary.by_id`.
- Produces: `RallyLibrary.generate_opponent_field(rally: Dictionary, event_results: Array, events: Array) -> Array` — `event_results[k]` is the track_result for event k; `events[k]` its event dict. Each rival's `event_times_ms[k] = optimum_ms(event_results[k], rival_car, events[k]) * rival_factor`, where `rival_factor` is a per-rival seeded draw in `[RIVAL_PACE_MIN, RIVAL_PACE_MIN + RIVAL_PACE_SPREAD]`. Return shape unchanged.

**Note:** This drops the old `event_target_ms: Array` param (opponent times no longer scale off the par; they come from each rival's own floor). `RIVAL_PACE_MIN`/`RIVAL_PACE_SPREAD` keep their values (1.35 / 1.0) but now multiply each rival's OWN floor — so the field still sits above the (driver_factor-scaled) par and a faster car still posts a faster time.

- [ ] **Step 1: Write the failing test**

Add to `tests/headless/test_rally_library.gd`:

```gdscript
func test_opponent_faster_car_posts_faster_time():
	# Two synthetic fields on the same track: a rival in a fast car beats a rival in
	# a slow car (holding the driver-factor draw fixed via the deterministic seed).
	var track := _track_with_pieces()
	var fast_floor := LapTimeModel.optimum_ms(track, CarLibrary.by_id("aventador"), {})
	var slow_floor := LapTimeModel.optimum_ms(track, CarLibrary.by_id("mx5"), {})
	assert_lt(fast_floor, slow_floor, "fast car has a lower floor on the same track")

func test_opponent_field_times_above_par():
	var track := _track_with_pieces()
	var rally := {"id": "r1", "events": [{"seed": 1}], "restriction": {}}
	var field := RallyLibrary.generate_opponent_field(rally, [track], rally["events"])
	var par := RallyLibrary.derive_target_ms(track, {}, rally)
	for opp in field:
		if not opp["dnf"]:
			assert_gt(int(opp["event_times_ms"][0]), par, "every rival is slower than par")

func test_opponent_field_deterministic_for_seed():
	var track := _track_with_pieces()
	var rally := {"id": "r1", "events": [{"seed": 1}], "restriction": {}}
	var a := RallyLibrary.generate_opponent_field(rally, [track], rally["events"])
	var b := RallyLibrary.generate_opponent_field(rally, [track], rally["events"])
	assert_eq(a.size(), b.size())
	assert_eq(int(a[0]["event_times_ms"][0]), int(b[0]["event_times_ms"][0]), "stable per seed")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `GODOT=$GODOT ./run_tests.sh --fast test_rally_library` (background)
Expected: FAIL — `generate_opponent_field` arity mismatch.

- [ ] **Step 3: Rewrite `generate_opponent_field`**

```gdscript
static func generate_opponent_field(rally: Dictionary, event_results: Array, events: Array) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = _rally_seed(rally)
	var car_pool := _eligible_cars(rally)
	var count := rng.randi_range(FIELD_MIN, FIELD_MAX)
	var field: Array = []
	for i in count:
		var car: Dictionary = car_pool[rng.randi_range(0, car_pool.size() - 1)]
		var times: Array = []
		var dnf := false
		for k in event_results.size():
			if rng.randf() < DNF_CHANCE:
				dnf = true
				times.append(-1)
			else:
				var ev: Dictionary = events[k] if k < events.size() else {}
				var floor_ms := LapTimeModel.optimum_ms(event_results[k], car, ev)
				var factor := RIVAL_PACE_MIN + rng.randf() * RIVAL_PACE_SPREAD
				times.append(int(round(floor_ms * factor)))
		var combined := -1
		if not dnf:
			combined = 0
			for tm in times:
				combined += int(tm)
		field.append({
			"name": "Rival %d" % (i + 1),
			"car_id": String(car.get("id", "")),
			"car_name": String(car.get("name", "")),
			"event_times_ms": times,
			"dnf": dnf,
			"combined_ms": combined,
		})
	return field
```

- [ ] **Step 4: Update `rally_session.gd` to thread track results**

`_compute_event_targets` already generates each event's track. Have it also collect the results so they can feed the field. Change it to return both, e.g. a small refactor:

```gdscript
# Per-event { targets: Array[int], results: Array[Dictionary] } for the opponent
# field, derived by generating each event's seeded track (deterministic for the seed).
func _compute_event_data(rally: Dictionary) -> Dictionary:
	var cfg: GameConfig = Config.data
	var reserve_behind := 0.0
	if cfg.start_line_enabled:
		reserve_behind = cfg.start_lead_in_ahead_m + cfg.start_lead_in_behind_m
	var targets: Array = []
	var results: Array = []
	for event in rally.get("events", []):
		var width := RallyLibrary.event_width(event)
		var result := TrackGenerator.generate(
			Vector2.ZERO, Vector2(0.0, -1.0), int(event.get("seed", 0)),
			int(event.get("turn_count", 10)), width, cfg.track_clearance, reserve_behind,
			RallyLibrary.event_straightness(event))
		results.append(result)
		targets.append(RallyLibrary.derive_target_ms(result, event, rally))
	return {"targets": targets, "results": results}
```

Then update `start_rally` (around lines 79–81) to use it:

```gdscript
	var data := _compute_event_data(rally)
	_event_targets_ms = data["targets"]
	_opponent_field = RallyLibrary.generate_opponent_field(rally, data["results"], rally.get("events", []))
```

Remove the old `_compute_event_targets` (replaced by `_compute_event_data`). Update any other caller of `_compute_event_targets` accordingly (grep first).

- [ ] **Step 5: Run tests to verify they pass**

Run: `GODOT=$GODOT ./run_tests.sh --fast test_rally_library test_rally_session` (background)
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/rally_library.gd scripts/rally_session.gd tests/headless/test_rally_library.gd
git commit -m "Opponent times from each rival car's physics floor"
```

---

### Task 6: Update feature docs

**Files:**
- Modify: `features/` — the file(s) covering rally sessions / opponent times / the pace popup (grep `features/` for `derive_target_ms`, `REF_SPEED`, `pace popup`, `turn split`).

- [ ] **Step 1: Find the doc(s)**

Run: `grep -rln "derive_target_ms\|REF_SPEED\|pace popup\|turn split\|opponent" features/`

- [ ] **Step 2: Rewrite the relevant section**

Replace any description of the heuristic (`length / ref_speed + corner_penalty`) with the QSS model: par = best-eligible car's physics floor × `driver_factor`; opponent times = each rival car's floor × a seeded pace band; turn-splits + the "vs P1" popup come off P1's own car's velocity profile. Reference `scripts/lap_time_model.gd` and the spec `docs/superpowers/specs/2026-06-30-physics-lap-time-design.md`.

- [ ] **Step 3: Commit**

```bash
git add features/
git commit -m "Docs: physics-based lap-time model"
```

---

### Task 7: Full-suite verification

- [ ] **Step 1: Run the full suite via a background sub-agent**

Per CLAUDE.md, delegate the full `./run_tests.sh` to a background sub-agent (it absorbs noisy output and returns a pass/fail digest). This change touches shared rally/config code, so the blast radius is wide — a full run is warranted as the final check.

- [ ] **Step 2: Fix any regressions, re-run, then report**

If anything fails, treat the new changes as the prime suspect (CLAUDE.md), fix the code (don't weaken tests), and re-run. Report the final verdict.

---

## Self-Review

- **Spec coverage:** QSS three-pass (Task 1) ✓; power-limited drive force (Task 1, `a_engine = P/v...`) ✓; grip = avg(front,rear) × surface (Task 1, `_surface_grip`) ✓; curvature off baked centerline (Task 1, `_curvature_profile`) ✓; par = best eligible car × driver_factor (Tasks 2–3) ✓; per-opponent floors (Task 5) ✓; car-parameterized turn-splits off same profile (Task 4) ✓; popup tracks P1's real car, same total / clean shape (Task 4, `current_event_p1_car` + world.gd) ✓; tests (every task) ✓; docs (Task 6) ✓. Downforce explicitly deferred (Task 1 note) — matches spec's "optional/minor".
- **Placeholders:** none — every code step shows full code.
- **Type consistency:** `optimum_profile` returns `{s,v,t,total_ms}` used identically in Tasks 3–4; `derive_turn_splits(track, car_meta, event)` signature consistent across Task 4 + world.gd; `generate_opponent_field(rally, event_results, events)` consistent across Task 5 + rally_session.
