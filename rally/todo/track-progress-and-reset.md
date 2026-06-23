# Track Progress & Off-Track Reset — implementation spec

> Status: **planned, not yet implemented.** This document is the implementation
> brief. It references the code as it exists on this branch so the work can be
> picked up later. Follow the project's config-first convention (`CLAUDE.md`):
> every new tunable goes in `GameConfig` (`scripts/game_config.gd` +
> `config/game_config.tres`), never hardcoded in scripts/scenes. Update the
> relevant `features/*.md` doc and add/adjust tests in the same piece of work.

## Goal

Two tightly-related behaviours, both driven off the generated road centerline:

1. **Track progress** — the game knows how far along the generated track the car
   is. A monotonic progress value advances every time the car gets further along
   the road than it has ever been. Progress only counts while the car is **near
   enough** to the road centerline (within a configurable distance).
2. **Off-track reset** — if the car strays **beyond** that same distance from the
   centerline, snap it back onto the road at the **last recorded progress
   position**, oriented **along the road's forward direction** there, with motion
   zeroed (same as the existing manual reset).

The single distance threshold does double duty: inside it, progress accrues;
crossing outside it triggers the reset.

## Context / current state (measured from the code)

- The road centerline is a **`Curve2D`** in the XZ plane (points are
  `Vector2(world_x, world_z)`), built by `TrackGenerator.generate(...)` and
  returned under the key `"centerline"`
  (`scripts/track_generator.gd:84-99`, `:258-266`).
- It is generated in `world.gd._generate_track()` and handed to the terrain
  manager via `$Floor.set_track(result["centerline"], ...)` — but **it is not
  retained anywhere after that** (`scripts/world.gd:58-69`, esp. `:64-68`). This
  feature's first job is to **keep a reference to that `Curve2D`.**
- The car already has a working reset: `Car._reset()` restores
  `_start_transform`, zeroes `linear_velocity` / `angular_velocity`, and resets
  drivetrain wheel spin + engine (`scripts/car.gd:209-217`). It is triggered by
  the `reset_car` input action (key `R`) in `_physics_process`
  (`scripts/car.gd:196-197`). `_start_transform` is the authored spawn pose,
  with Y lifted to ground height + `spawn_clearance` (`:25-27`).
- The car's live world pose is `global_transform` / `global_transform.origin`,
  read every physics tick in `_physics_process` (`scripts/car.gd:85-198`).
- Ground height under a world point is available via the private helper
  `Car._ground_height_at(pos)` (`scripts/car.gd`, used at `:26`); the terrain
  manager exposes the underlying height query (`$Floor`, a `TerrainManager`).
- **No progress / checkpoint / lap concept exists today.** The HUD
  (`scripts/hud.gd:39-46`) only shows speed/gear/RPM.
- Track config lives in `scripts/game_config.gd:252-267`
  (`track_width` default `6.0`, **`.tres` override `7.0`**; `track_clearance`
  default `8.0`; `track_turn_count`, `track_seed`, `track_transition_cells`).
  The road's visible half-width is `track_width / 2` (≈ **3.5 m** with the live
  config). The generator guarantees distinct track sections stay at least
  `track_clearance` (8 m) apart (`features/track.md`).
- Feature doc to update: `features/track.md`. Consider a short new
  `features/progress.md` (and index it in `features/README.md`).

---

## 1. Retain the centerline + a progress/reset manager

The `Curve2D` is currently discarded after `set_track`. Keep it, and own the
progress logic in one place.

**Approach — a small `TrackProgress` node** (`scripts/track_progress.gd`,
`class_name TrackProgress extends Node`), created and wired in
`world.gd._generate_track()` right after the centerline is produced
(`scripts/world.gd:64-68`):

```gdscript
# in _generate_track, after `result := TrackGenerator.generate(...)`
var progress := TrackProgress.new()
progress.setup(result["centerline"], $Car as Car, $Floor as TerrainManager)
add_child(progress)
```

State held by the node:
- `_centerline: Curve2D` — the road.
- `_baked_length: float` — `_centerline.get_baked_length()`, cached once.
- `_best_offset: float` — furthest baked offset (metres along the curve) ever
  reached **while on-road**. This IS the progress counter. Starts at the offset
  nearest the spawn point so the car doesn't appear to start mid-track.
- `_best_reset: Transform3D` — the 3D pose to restore on an off-track event:
  position = centerline point at `_best_offset` (XZ) lifted to ground height +
  `spawn_clearance`; orientation = facing along the road's forward tangent there.

Keeping it a node (not free functions in `world.gd`) makes it testable in
isolation and keeps `world.gd` lean. Config-first: all thresholds come from
`Config.data`.

## 2. Sample progress each tick

Run the check from the manager's `_physics_process` (physics-rate is plenty;
matches where the car pose updates). Per tick:

```gdscript
func _physics_process(_delta: float) -> void:
    var p := _car.global_transform.origin
    var here := Vector2(p.x, p.z)
    var offset := _centerline.get_closest_offset(here)        # metres along curve
    var on_curve := _centerline.sample_baked(offset)          # nearest centerline pt (XZ)
    var dist := here.distance_to(on_curve)                     # lateral distance to road
    var max_dist: float = Config.data.track_progress_max_dist_m

    if dist <= max_dist:
        if offset > _best_offset:
            _best_offset = offset
            _best_reset = _reset_xform_at(offset)             # see §3
    else:
        _car.reset_to(_best_reset)                            # see §4
```

Notes / pitfalls to handle:
- **`get_closest_offset` is a global nearest-point query.** On a winding track
  that passes near itself it could snap to the wrong section. The generator's
  `track_clearance` (8 m) keeps distinct sections apart, so as long as
  `track_progress_max_dist_m` stays comfortably below `track_clearance` this is
  safe. Recommended default ≈ road half-width + a small margin
  (`track_width/2 ≈ 3.5` → default **5.0 m**), which is well under 8 m. **Add an
  assertion / doc note** that `track_progress_max_dist_m < track_clearance`.
- Progress is **monotonic** — it only ever advances. Driving backwards lowers the
  live `offset` but not `_best_offset`, so the recorded reset stays at the
  furthest point reached (which is what we want for an off-track recovery).
- Curve2D baked sampling is cheap (it's precomputed); one query per physics tick
  is negligible. No allocations in the hot path.

## 3. Build the on-road reset pose (`_reset_xform_at`)

Convert a baked offset on the 2D curve into a 3D pose facing along the road:

```gdscript
func _reset_xform_at(offset: float) -> Transform3D:
    var here := _centerline.sample_baked(offset)
    # Forward tangent: sample a little further along (clamped to the curve).
    var ahead := _centerline.sample_baked(minf(offset + 1.0, _baked_length))
    var dir2 := (ahead - here)
    if dir2.length() < 0.001:
        dir2 = (here - _centerline.sample_baked(maxf(offset - 1.0, 0.0)))
    var fwd := Vector3(dir2.x, 0.0, dir2.y).normalized()       # XZ → world forward
    var ground := _terrain.height_at(here.x, here.y)           # confirm exact API
    var pos := Vector3(here.x, ground + Config.data.spawn_clearance, here.y)
    # A Node3D faces -Z, so look toward pos + fwd with world up.
    var basis := Basis.looking_at(fwd, Vector3.UP)
    return Transform3D(basis, pos)
```

- Use the **same `spawn_clearance` lift** the spawn uses (`car.gd:26`) so the car
  drops cleanly onto the road instead of spawning buried or hovering.
- Confirm the terrain height query name/signature against `scripts/car.gd`'s
  `_ground_height_at` and `TerrainManager`; reuse whatever that calls rather than
  duplicating the noise sampling.
- `Basis.looking_at(fwd, Vector3.UP)` orients -Z down the road. Alternatively use
  `Curve2D.sample_baked_with_rotation(offset, false, false)` and map its tangent;
  the two-sample approach above is the most transparent and robust to the
  tangent-axis convention.

## 4. Add a parametric reset on the car

`Car._reset()` hardcodes `_start_transform`. Generalise it so the progress
manager can request a reset to an arbitrary pose, without duplicating the
velocity/drivetrain zeroing (`scripts/car.gd:209-217`):

```gdscript
func _reset() -> void:
    reset_to(_start_transform)

func reset_to(xform: Transform3D) -> void:
    global_transform = xform
    linear_velocity = Vector3.ZERO
    angular_velocity = Vector3.ZERO
    drivetrain.rear_omega = 0.0
    for wheel in drivetrain.front_omega:
        drivetrain.front_omega[wheel] = 0.0
    drivetrain.engine.reset()
```

The manual `R` reset (`car.gd:196-197`) and the off-track reset then share one
code path. (The existing `respawn()` static car-swap helper at `car.gd:226` is
unaffected.)

Optional polish: skip / debounce the off-track reset if `dist` only just crossed
the threshold for a single tick (e.g. moving fast across a corner apex), or
require the car to be off-road for N consecutive ticks, to avoid a reset on a
momentary clip. Start without it; add only if testing shows false triggers.

## 5. Config knobs (config-first)

Add to the **Track** group in `scripts/game_config.gd` (around `:252-267`) and
document defaults; override in `config/game_config.tres` only if the live game
needs different values:

| Field | Type | Default | Purpose |
|---|---|---|---|
| `track_progress_max_dist_m` | float | `5.0` | Lateral distance from the centerline within which progress counts; crossing beyond it triggers the off-track reset. Must stay `< track_clearance`. |
| `off_track_reset_enabled` | bool | `true` | Master switch for the auto-reset (progress tracking can run regardless, e.g. for the HUD). |

No new "quality"/tier branching — these are single shipped values, tunable for
dev/debug, consistent with the project's inherently-lean design.

## 6. HUD progress readout (optional but cheap)

Surface progress in `scripts/hud.gd` (`_process` at `:39-46`, alongside the
speed label). Express `_best_offset / _baked_length` as a percentage, or map it
to "turn X of `track_turn_count`". Reuse the existing label-update pattern; avoid
per-frame string churn beyond what the HUD already does (see the HUD note in
`todo/performance-optimisations.md` item 10). Expose `_best_offset` /
`_baked_length` via a getter on `TrackProgress`.

## 7. Tests

Add to `tests/headless/` (GUT; run via `./run_tests.sh` in the background):
- **Progress advances on-road:** place the car at successive points along a known
  generated `Curve2D` within `track_progress_max_dist_m`; assert `_best_offset`
  increases monotonically and never decreases when the car moves backward.
- **Progress gated by distance:** a point beyond the threshold does not advance
  `_best_offset`.
- **Off-track reset pose:** with the car beyond the threshold, assert
  `reset_to` is invoked with a transform whose XZ matches the centerline at
  `_best_offset` (within tolerance) and whose -Z forward aligns with the road
  tangent there; velocities zeroed.
- **`reset_to` parity:** `_reset()` still restores `_start_transform` exactly
  (guards the refactor in §4).
- Drive the math against a `Curve2D` built directly in the test so it doesn't
  depend on the full scene where possible.

## Implementation order

1. §4 — refactor `Car._reset()` → `reset_to(xform)` (small, low-risk, testable).
2. §1 — retain the centerline + create `TrackProgress`, wired in `world.gd`.
3. §3 + §2 — pose builder, then the per-tick progress/reset loop.
4. §5 — config knobs (do alongside §2 so nothing is hardcoded).
5. §6 — HUD readout.
6. §7 — tests; update `features/track.md` (+ optional `features/progress.md`).

## Files touched (summary)

| File | Change |
|---|---|
| `scripts/car.gd` | Split `_reset()` into `_reset()` + `reset_to(xform)` (`:209-217`). |
| `scripts/world.gd` | Retain `result["centerline"]`; create/wire `TrackProgress` in `_generate_track` (`:64-68`). |
| `scripts/track_progress.gd` | **New.** Owns centerline, `_best_offset`, `_best_reset`; per-tick query + reset. |
| `scripts/game_config.gd` | New Track knobs `track_progress_max_dist_m`, `off_track_reset_enabled` (`:252-267`). |
| `config/game_config.tres` | Overrides only if needed. |
| `scripts/hud.gd` | Optional progress label (`:39-46`). |
| `features/track.md` (+ `features/README.md`, opt. `features/progress.md`) | Document the new model. |
| `tests/headless/` | New progress + reset tests. |
