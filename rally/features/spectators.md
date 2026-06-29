# Roadside spectators

Crowds of low-poly people standing trackside that react to the car: they shuffle
with simple steering preferences while upright, and are knocked flying when the
car hits them. Three groups per stage — one at the **start**, one at the **end**,
and one at a **seeded mid-stage point** (between 30% and 70% progress).

Spec/brainstorm history: [`todo/roadside-spectators.md`](../todo/roadside-spectators.md).

## Files

| File | Role |
|------|------|
| `scripts/spectator_scatter.gd` | Pure, seeded placement — `mid_offset()` (where the mid group goes) + `members()` (off-road, tree-avoiding, separated standing positions). Headless, no scene. |
| `scripts/spectator_group.gd` | `SpectatorGroup` (Node3D) — owns one crowd: steering, MultiMesh render, LOD, knockdown→ragdoll, despawn. Pure steering forces are static (unit-tested). |
| `scripts/world.gd` | `_spawn_spectators()` / `_spawn_spectator_group()` build the three groups in `_generate_track`, after the centerline + `road_cells` + trees exist. |
| `scripts/game_config.gd` | `@export_group("Spectators")` + `spectator_params()`. |
| `blender/spectator.glb` | The low-poly figure (no armature — hence single-capsule ragdolls). |

## How it works

### Representation — "ghost crowd + impulse ragdolls"

While **upright**, a group is NOT a set of physics bodies — just parallel agent
arrays (`_pos`, `_vel`, `_home`, `_yaw`, `_upright`) plus one `MultiMesh` for
rendering. So 50+ spectators cost almost nothing and never touch the vehicle
solver: no `MAX_CONTACTS_REPORTED` pressure, no HP damage, and they are **not** in
`DamageModel.OBSTACLE_GROUP`. People aren't trees.

When the car reaches a member (within `spectator_knock_radius_m`) that member
flips to a **ragdoll**: a single `RigidBody3D` capsule (the model has no skeleton,
so one body — not `PhysicalBone3D`) launched along the car's `linear_velocity`
(speed-scaled, plus lift + a random tumble spin). Ragdolls collide with the
terrain/trees (all on physics layer 1) but carry an explicit
`add_collision_exception_with(car)`, so a crowd can never bog the car down. Once
the car is `spectator_despawn_behind_m` behind a ragdoll, it is freed.

### Steering (boids on the XZ plane)

`SpectatorGroup._physics_process` batch-steers every upright member from weighted
preferences, clamped to `spectator_max_speed_mps`. Each is a pure static function:

| Force | Preference | Notes |
|-------|-----------|-------|
| `separation_force` | keep ~`separation_m` apart | within-group only; O(n²) but n≈50 |
| `flee_force` | move away from the car within `flee_radius_m` | squared near-field falloff = the "light push": the crowd parts/jostles hard as the car arrives |
| `road_force` | avoid the carriageway | 8-direction probe of the rasterised `road_cells` |
| `obstacle_force` | avoid trees | probes a grid of tree points (`SpectatorScatter.build_point_grid`) |
| `anchor_force` | drift home when idle | dead-zone'd so settled agents don't jitter |

**LOD:** only the group within `spectator_active_radius_m` of the car runs
steering; the other two stand still until the car approaches.

### Placement

`mid_offset()` picks a seeded along-track distance in
`[spectator_mid_progress_min, spectator_mid_progress_max]`. Each group's centre is
offset `spectator_side_offset_m` to the **left** of the road (perpendicular to the
local heading); `members()` then lays a jittered grid (cell = separation) over a
`spectator_spawn_radius_m` disc, rejecting on-road cells and points within
`spectator_tree_avoid_m` of a tree, thinned to `spectator_group_size`. All
deterministic per `track_seed` (each group gets a distinct salt). Groups are named
(`SpectatorStart` / `SpectatorMid` / `SpectatorEnd`) so an in-place regeneration
replaces rather than stacks them (mirrors `_place_arch`).

## Collision layers

- Upright crowd: no physics bodies at all (pure data + MultiMesh).
- Ragdolls: own layer (bit 5) with mask = layer 1 (terrain + trees), plus a
  per-body collision exception with the car. The car's own layer/mask are
  unchanged.

## Config

`@export_group("Spectators")` in `game_config.gd` (group size, mid-progress band,
spawn/side radii, separation, flee/knock radii, max speed + accel, LOD radius,
the five steering weights, ragdoll launch params, despawn distance). Disable with
`spectators_enabled = false` or `spectator_group_size = 0`.

## Tests

- `tests/headless/test_spectator_scatter.gd` — placement: mid-offset band +
  determinism; member count cap, determinism, within-radius, separation floor,
  off-road, tree-avoid, grid bucketing.
- `tests/headless/test_spectator_steering.gd` — each steering force's direction +
  radius cutoff, and the speed clamp.
- `tests/headless/test_smoke.gd` — groups spawn with standing members and are not
  obstacles.

## Future

- Crowd-cheer audio (ties into `todo/audio.md`).
- Optional articulated ragdoll if the single capsule reads too stiff.
- Re-export `spectator.glb` from Blender for correct per-material colours
  (current colours are placeholders from a pure-Python extraction).
