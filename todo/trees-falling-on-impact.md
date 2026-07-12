# Trees fall over when you crash into them fast enough — implementation spec

> Status: **planned, not yet implemented.** Implementation brief for felling a
> tree when the car hits it above a speed threshold: the struck tree topples over
> and **loses its hitbox**, so you plough straight through instead of pinning
> against it. Below the threshold, trees behave exactly as they do today (solid
> obstacle, chip HP). Follow the config-first convention (`CLAUDE.md`). Update
> `features/trees.md` and add tests in the same piece of work.

## Goal

Hit a tree carrying real speed → the tree topples in your travel direction and
becomes non-colliding scenery lying on the ground. Hit one slowly → it stays a
solid obstacle (today's behaviour). Damage (HP loss, wheel bend) still flows
through the existing impact path unchanged in both cases — felling is *additive*
feedback, not a replacement for the crash.

## Why it's a gap

Trees are currently indestructible solid boxes: `TreeMeshField` builds one static
box hitbox per tree (`scripts/obstacle_body.gd`) and the car crashes into it
forever. There's no reward for smashing through a tree at speed — a 120 km/h
head-on and a 15 km/h nudge both just chip HP and stop you dead. Felling gives
speed a visible, satisfying consequence and opens up "ram through the treeline"
moments.

## Current state (measured from the code)

- **Rendering.** `TreeMeshField` (`scripts/tree_mesh_field.gd`) renders trees as
  MultiMesh instances, **binned** into one `MultiMeshInstance3D` per
  `tree_bin_size_m` grid cell (`build()`, lines 42–95). Instance transforms live
  in the RenderingServer (no-op stub under `--headless`); `instance_positions:
  PackedVector3Array` is the renderer-independent mirror in **build order**.
  Per-instance transform is `Basis(UP, yaw).scaled(uscale)` at bin-local origin
  `pos - centre` (`tree_mesh_field.gd:78-81`), where `pos` is the trunk base at
  ground height and the mesh AABB sits from y≈0 upward — so rotating that basis
  about its origin pivots the tree **about its base**.
- **Collision.** One shared `StaticBody3D` named `Collision`
  (`DamageModel.OBSTACLE_GROUP`) holds N box shapes added via
  `PhysicsServer3D.body_add_shape(body_rid, shape_rid, xform)` in `world_pos`
  order — the **same order** as `instance_positions` and as the tree index
  (`obstacle_body.gd:15-26`). All boxes share one `BoxShape3D`. Built only when
  `with_collision` is true (`tree_mesh_field.gd:100-101`).
- **Impact detection.** `car.gd._integrate_forces` (`car.gd:559-567`) walks the
  chassis contacts; for any collider in `OBSTACLE_GROUP` it calls
  `damage.register_impact(_approach_speed, state.get_contact_local_position(i),
  cfg)`. `_approach_speed` is the **pre-solve** travel speed captured at the top
  of `_physics_process` (`car.gd:288`) — the true crash speed (a head-on hit's
  post-solve `state.linear_velocity` is ~0; see the `car.gd:547-558` rationale).
- **Damage maths.** `DamageModel.hp_loss_for_speed` (`damage_model.gd:154-162`)
  is a square law: 0 below `impact_min_speed_kmh`, climbing to
  `impact_ref_hp_loss` at `impact_ref_speed_kmh`. `register_impact`
  (`damage_model.gd:168-188`) caps one hit at `max_hp * impact_max_loss_frac` and
  groups a sustained crash into one hit via `_impact_cooldown`.
- **Precedent for "wake one instance out of a shared field."** `SignField`
  (`scripts/sign_field.gd`) renders resting signs in shared MultiMeshes and, when
  the car hits one, zero-scales that instance's MultiMesh transform and swaps in a
  real tumbling body (`_wake_sign`, `_materialize_sign`). We reuse the *idea*
  (mutate one instance's MultiMesh transform on contact) but **not** the RigidBody
  — see "Approach" below.
- **Billboard A/B path.** When `cfg.use_billboard_trees` is true,
  `Foliage.spawn_trees` (`scripts/foliage.gd:37-52`) builds a `BillboardField`
  instead, which also carries an `ObstacleBody` collision body
  (`billboard_field.gd:100`). Default play uses `TreeMeshField`; billboards are a
  perf toggle. This spec targets `TreeMeshField`; the billboard field is **out of
  scope for phase 1** (noted under "Open questions").

## Approach: kinematic tilt on the MultiMesh instance

Chosen over converting the struck tree to a tumbling `RigidBody3D` (the sign
pattern): trees are far more numerous than signs, a physics body per felled tree
is heavier and non-deterministic, and we already have direct access to the
instance transform. Instead we **animate the existing MultiMesh instance** —
rotate it about its base from upright to flat over a short duration — and
**disable its hitbox immediately** so the car passes through from the moment of
impact.

Two API facts make this clean without disturbing the shared shape resource or the
bin structure:

- `state.get_contact_collider_shape(i)` → the **shape index** within the
  `Collision` body. Because shapes were added in `world_pos` build order, that
  index **is** the tree's global index (same order as `instance_positions`).
- `PhysicsServer3D.body_set_shape_disabled(body_rid, shape_idx, true)` → kills
  one tree's hitbox **in place**, with no reindexing of the other shapes (unlike
  `body_remove_shape`, which would shift every higher index and break the
  index→tree mapping).

### 1. New plumbing in `TreeMeshField`

`build()` bins instances, which reorders them away from build order, so we need a
**global-index → (MultiMeshInstance3D, local slot j)** map to find the one
instance to animate. Record it while building each bin's MultiMesh
(`tree_mesh_field.gd:76-84` loop):

```gdscript
# global tree index -> where its instance lives in the binned MultiMeshes
var _slot_of: Dictionary = {}   # int idx -> {"mmi": MultiMeshInstance3D, "j": int, "centre": Vector3}
```
Populate it as `_slot_of[idxs[j]] = {"mmi": mmi, "j": j, "centre": centre}`, and
keep the collision body RID from `_collision_shape`'s owner (store
`_collision_body: StaticBody3D` when `ObstacleBody.build` returns — extend
`ObstacleBody.build` to also hand back the body, or capture it via
`get_node("Collision")`).

Also stash per-instance `yaw` and the uniform `instance_scale` (already a field)
so the animation can rebuild the transform.

### 2. Felling entry point

```gdscript
# Fell tree `idx`, toppling it in horizontal unit direction `dir`. Idempotent:
# a second contact on an already-felled tree (same frame or later) is a no-op.
func knock_down(idx: int, dir: Vector3) -> void
```
- Guard: `if _fallen.has(idx): return` (`_fallen` is a `{}` used as a set).
- Disable the hitbox now: `PhysicsServer3D.body_set_shape_disabled(
  _collision_body.get_rid(), idx, true)`.
- Look up `_slot_of[idx]`; if missing, return (defensive).
- Push a falling record: `{mmi, j, base_pos, yaw, axis, elapsed = 0.0}` where
  `axis = Vector3.UP.cross(dir).normalized()` (topple *along* `dir`), falling back
  to a fixed axis if `dir` is ~vertical/zero.
- Mark `_fallen[idx] = true`.

### 3. Per-frame animation (`_process`)

`TreeMeshField extends Node3D`, so it can `_process(delta)`. Advance each active
falling record, rebuild only that instance's transform, and retire it when flat
(so a settled forest costs nothing per frame):

```gdscript
var t := TreeFall.fall_angle(elapsed, duration)        # 0 -> ~PI/2, pure + testable
var basis := Basis(rec.axis, t) * Basis(Vector3.UP, rec.yaw).scaled(scale_v)
rec.mmi.multimesh.set_instance_transform(rec.j, Transform3D(basis, rec.base_pos - rec.centre))
```
`base_pos - centre` is unchanged (we pivot about the base, which is the instance
origin). When `elapsed >= duration` clamp to the final angle and drop the record
from the active list; the instance stays flat forever with no further updates.

### 4. Car-side trigger (`car.gd._integrate_forces`)

Alongside the existing `register_impact` call (`car.gd:567`), add the felling
decision. It is **independent of the damage cooldown** (you plough through a line
of trees; each should fall even though only the first chips HP):

```gdscript
if collider.is_in_group(DamageModel.OBSTACLE_GROUP):
    damage.register_impact(_approach_speed, state.get_contact_local_position(i), cfg)
    if TreeFall.should_fell(_approach_speed, cfg) and collider.get_parent().has_method("knock_down"):
        collider.get_parent().knock_down(state.get_contact_collider_shape(i), _approach_dir)
```
- Capture `_approach_dir` next to `_approach_speed` in `_physics_process`
  (`car.gd:288`): the horizontal component of `linear_velocity`, normalized (zero
  vector when nearly stationary). Pre-solve, same rationale as the speed.
- `collider` is the `Collision` `StaticBody3D`; its parent is the `TreeMeshField`
  (or `BillboardField`). The `has_method("knock_down")` guard keeps signs /
  future obstacle bodies safe.

### 5. Pure helper `TreeFall` (for testability)

New `scripts/tree_fall.gd` (`class_name TreeFall`), a `ScatterMath`-style pure
static module — no scene, unit-testable headless:

- `static func should_fell(speed_mps: float, cfg: GameConfig) -> bool` →
  `speed_mps * DamageModel.MPS_TO_KMH >= cfg.tree_fell_speed_kmh` (and threshold
  > 0). Keeps the km/h conversion in one place.
- `static func fall_angle(elapsed: float, duration: float) -> float` → eased
  0 → target angle (≈`PI/2`, or slightly past for a settle). Ease-out so it
  snaps then settles; optional ease-out-back for a small ground bounce.
- Optionally `static func topple_axis(dir: Vector3) -> Vector3` →
  `Vector3.UP.cross(dir).normalized()` with the degenerate-direction fallback, so
  the axis choice is testable too.

## Configuration

New knob in the **Trees** group of `GameConfig` (`scripts/game_config.gd`, after
`tree_collision_height_m` ~line 1015), overridable in `config/game_config.tres`:

```gdscript
## Approach speed (km/h) at or above which crashing into a tree topples it and
## removes its hitbox (you plough through). Below this, a tree stays a solid
## obstacle. Should sit at/above impact_min_speed_kmh — a tree that falls but
## costs no HP is fine, but one that costs HP yet never falls at any speed is not.
@export_range(0.0, 200.0) var tree_fell_speed_kmh := 45.0
```
Fall animation duration is a look value → also a config knob (e.g.
`tree_fell_duration_s`, ~0.6 s) rather than a script literal, per the
config-first rule.

> **Balance values are placeholders.** Per `CLAUDE.md` testing rules, do NOT pin
> `tree_fell_speed_kmh` / `tree_fell_duration_s` in tests — test the *logic*
> (`should_fell` returns true above / false below whatever the threshold is, the
> hitbox is disabled, the animation reaches flat), never the chosen numbers.

## Persistence & reset

- The world regenerates per run (`world.gd._ready` → `_generate_track` →
  `Foliage.spawn_trees`), so a **fresh run always fields standing trees**. No save
  state — felling is run-local and transient.
- The off-track / progress **auto-reset** (`TrackProgress`) returns the car to the
  start line but does **not** regenerate the world, so **felled trees stay
  felled** after a mid-run reset. Default: keep it (you broke them, they're
  broken). See Open questions if standing-on-reset is wanted instead.

## Tests

Pure-logic + smoke, following the existing tree tests
(`tests/headless/test_tree_scatter.gd`, `test_smoke.gd`) and the `CLAUDE.md`
rule against pinning tunables:

- **`tests/headless/test_tree_fall.gd`** (new, pure — no scene):
  - `should_fell` is monotonic in speed for a fixed threshold: below → false,
    above → true (feed a synthetic `GameConfig` with a chosen `tree_fell_speed_kmh`;
    assert the boundary relative to *that* value, not a hardcoded number).
  - `fall_angle` starts at 0 at `elapsed = 0`, is non-decreasing, and reaches the
    flat target by `elapsed >= duration` (clamped, no overshoot past clamp).
  - `topple_axis(dir)` is horizontal and perpendicular to `dir`; degenerate input
    yields a valid unit axis.
- **`TreeMeshField` behaviour** (in `test_smoke.gd` or a focused test, built via
  a minimal field so no full world generation — see `features/testing.md`):
  - After `knock_down(idx, dir)`, `idx` is marked fallen and a **second**
    `knock_down(idx, …)` is a no-op (idempotent) — assert via a public
    `is_fallen(idx)` / the active-fall count, since MultiMesh transforms can't be
    read back headless.
  - `knock_down` on a field built `with_collision = false` (or out-of-range idx)
    is a safe no-op.
  - Hitbox disable is observable: after `knock_down`, the field reports the shape
    disabled (expose a tiny `is_hitbox_disabled(idx)` that queries the physics
    server, or assert the `_fallen` set — the physics-server disabled flag has no
    public getter, so prefer the field's own bookkeeping).
- **Regression guard:** a below-threshold hit does NOT fell the tree (the existing
  solid-obstacle behaviour and HP chipping via `register_impact` are unchanged).

## Out of scope / open questions

1. **Billboard trees.** `BillboardField` shares `ObstacleBody` and could get the
   same `knock_down` (the cross-billboard instance is one MultiMesh transform,
   identically tiltable). Deferred to keep phase 1 small — default play is
   `TreeMeshField`. Decide whether to fold it in now or leave billboards
   unfellable.
2. **Fall direction source.** Spec uses the car's horizontal velocity
   (`_approach_dir`). Alternative: car→tree vector (needs the tree world pos, which
   `_slot_of` has). Velocity reads well for head-on hits and is simpler.
3. **Full pass-through vs. stump.** Spec disables the whole hitbox (drive clean
   through). Alternative: shrink the shape to a low stump the car can still clip.
   Pass-through is simpler and more satisfying.
4. **Reset behaviour.** Default keeps felled trees down through a mid-run reset;
   flip to "stand back up on reset" if that's preferred (would need `TrackProgress`
   reset to call a `TreeMeshField.reset_all()` that re-enables shapes and restores
   upright transforms).
5. **Damage on a felling hit.** Spec leaves the square-law untouched — the tree
   falling *is* the reward. Decide if a felling hit should cost extra/less HP.
6. **Extra polish (all deferred):** SFX on fell (ties into `todo/audio.md`), a
   dust/leaf puff, a broken-trunk look vs. a clean uproot, a slight sink into the
   ground as it settles.
