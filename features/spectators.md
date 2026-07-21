# Roadside spectators

Crowds of low-poly people standing trackside that react to the car: they shuffle
with simple steering preferences while upright, and are knocked flying when the
car hits them. Three groups per stage — one at the **start**, one at the **end**,
and one at a **seeded mid-stage point** (between 30% and 70% progress).

Spec/brainstorm history: [`todo/roadside-spectators.md`](../todo/roadside-spectators.md).

Placement/steering share the low-level scatter helpers: `ScatterMath`
(`scripts/scatter_math.gd`, seeded `hash01` + road-cell tests) and `SpatialGrid`
(`scripts/spatial_grid.gd`, point/index binning + 3x3 proximity). `build_point_grid`
is a thin wrapper over `SpatialGrid.of_points`.

## Files

| File | Role |
|------|------|
| `scripts/crowd.gd` | `Crowd` — the ONE place that owns the shared figure mesh (`mesh()`), the ground foot-offset (`foot_offset()`), and the static-crowd MultiMesh build (`multimesh_instance()`). Every decorative crowd goes through it (like `Foliage` for trees/bushes); `SpectatorGroup` pulls the mesh + foot offset through it too, so no crowd can drift from the others. |
| `scripts/spectator_scatter.gd` | Pure, seeded placement — `mid_offset()` (where the mid group goes) + `members()` (off-road, tree-avoiding, separated standing positions). Headless, no scene. |
| `scripts/spectator_group.gd` | `SpectatorGroup` (Node3D) — owns one LIVE crowd: steering, its own dynamic MultiMesh (rewritten each frame), LOD, knockdown→ragdoll, despawn. Pure steering forces are static (unit-tested). Not a `Crowd.multimesh_instance()` caller (dynamic, not static) but shares the figure via `Crowd.mesh()`/`Crowd.foot_offset()`. |
| `scripts/world.gd` | `_spawn_spectators()` / `_spawn_spectator_group()` build the three live groups in `_generate_track`; `_spawn_wreck_crowd()` builds a STATIC onlooker crescent at an opponent wreck via `Crowd.multimesh_instance()`. |
| `scripts/game_config.gd` | `@export_group("Spectators")` + `spectator_params()`. |
| `scripts/hq_environment.gd` | `_build_spectators()` — STATIC scenery spectators spread around the HQ clearing (3 × `spectator_group_size`, off the tarmac apron, out of the trees), built via `Crowd.multimesh_instance()`; no steering/ragdolls (no car in HQ). |
| `scripts/podium.gd` | `_spectator_layout()` — STATIC crowd arc behind the podium + a showroom fan, built via `Crowd.multimesh_instance()`. |
| `blender/spectator/spectator.glb` | The low-poly figure: 150 triangles, no armature (hence single-capsule ragdolls). Quadric-decimated for cheap crowds; one mesh used at all distances. |

## How it works

### Representation — "ghost crowd + impulse ragdolls"

While **upright**, a group is NOT a set of physics bodies — just parallel agent
arrays (`_pos`, `_vel`, `_home`, `_yaw`, `_upright`) plus one `MultiMesh` for
rendering. So 50+ spectators cost almost nothing and never touch the vehicle
solver: no `MAX_CONTACTS_REPORTED` pressure, and they are **not** in
`DamageModel.OBSTACLE_GROUP` (they never block or bog the car — people aren't trees).
Hitting one is not free, though: knocking a member over applies a small speed-scaled
**soft drag** to the car (`car.apply_soft_drag(spectator_drag_strength)`, a bit more
than a bush — see [damage.md](damage.md) → "Soft contacts"). The resulting
deceleration feeds the unified damage rule for a light HP chip; grouping is natural (a
slowing car sheds ~0 more per member), so mowing a dense line doesn't wildly over-count.

When the car reaches a member (within `spectator_knock_radius_m`) that member
flips to a **ragdoll**: a single `RigidBody3D` capsule (the model has no skeleton,
so one body — not `PhysicalBone3D`) launched along the car's `linear_velocity`.
The **whole impulse scales with car speed**: the launch speed is `speed ×
spectator_knock_speed_factor` (clamped), the upward kick is a *fraction* of that
launch (`spectator_knock_lift_ratio`, a fixed angle rather than a constant m/s), and
the tumble spin tapers to zero as the car slows — so a slow nudge topples a spectator
gently instead of flinging them skyward. Ragdolls collide with the
terrain/trees (all on physics layer 1) but carry an explicit
`add_collision_exception_with(car)`, so a crowd can never bog the car down. Once
the car is `spectator_despawn_behind_m` behind a ragdoll, it is freed.

### Steering (boids on the XZ plane)

`SpectatorGroup._physics_process` batch-steers every upright member, clamped to
`spectator_max_speed_mps`. Each preference is a pure static force:

| Force | Preference | Notes |
|-------|-----------|-------|
| `flee_force` | move away from the car within `flee_radius_m` | squared near-field falloff = the "light push": the crowd parts/jostles hard as the car arrives |
| `road_force` | avoid the carriageway | 8-direction probe of the rasterised `road_cells`, each direction stepped out to `probe` and **distance-graded** (nearer road → stronger push, fading to zero at `probe`). The grading is what stops verge spectators jiggling on the spot: a bang-bang push (full within `probe`, zero just past it) has a hard switching surface that the anchor pull drags a member across and the road shoves back — a permanent chatter. The smooth gradient meets the anchor pull at a single static resting point instead |
| `obstacle_force` | avoid trees | probes a grid of tree points (`SpectatorScatter.build_point_grid`) |
| `separation_force` | keep ~`separation_m` apart | within-group only; a per-tick spatial grid (`build_separation_grid`, cell = radius) bounds it to a 3×3 neighbour scan (~O(n)), not every pair. Passing no grid falls back to the full O(n²) scan for the pure unit tests; both paths compute the identical force |
| `anchor_force` | drift home when idle | dead-zone'd so settled agents don't jitter |

**Prioritised arbitration (`combine`), not a flat weighted sum.** The two *urgent
local* forces — `flee_force` and `separation_force` — are **blended** at the top
tier; then static obstacle (road + tree) avoidance gets whatever budget is left
under `max_speed`, and the anchor pull comes last (`_add_priority`). So the crowd
commits to escaping the car **before** dodging static obstacles, while still keeping
its spacing as it flees.

Blending flee *with* separation (rather than gating separation behind a saturated
flee) is deliberate: if flee alone claimed the whole budget, a fleeing crowd would
pile onto the same escape point with **no** spacing force, collapse to
near-coincident positions, and never push apart again (coincident/symmetric
separation cancels) — the crowd would go **completely stuck in a clump**. Blended,
the crowd fans out sideways as it flees. Flee's larger weight (`w_flee > w_separation`)
keeps escaping the car the dominant direction, and the accel-limited integration
(`move_toward`) filters tick-to-tick wobble, so a tight clump doesn't jitter. With no
car nearby, flee is zero and the lower tiers get the full budget (so they still space
out and avoid the road when idle).

**LOD:** only the group within `spectator_active_radius_m` of the car runs
steering; the other two stand still until the car approaches.

**Sim decimation (perf):** within an active group the per-member steering runs only
every `spectator_sim_interval`-th physics tick, staggered per group (a phase from the
crowd centroid) so active groups don't all recompute on the same frame. The delta
accumulates across skipped ticks (`_sim_accum`) and is integrated in one step, so
crowd *motion* is unchanged over time — only the update rate is coarser. On-device
profiling showed the crowd sim was ~2 ms of the physics tick; decimation cuts that
proportionally. **Knock-over detection runs every tick regardless** (a discrete,
speed-sensitive event — a cheap per-member distance check split out from the
decimated steering), so fast cars still topple the crowd on contact.

**Render cull:** the group's single `MultiMeshInstance3D` is anchored at the crowd
centroid (`_mm_origin`; instance transforms are written relative to it) and carries
a `visibility_range_end`/fade set to the **shared world-prop render distance**
(`cfg.tree_render_distance_m` / `tree_render_fade_m`, threaded through
`spectator_params()`), so a crowd pops in at the same distance as the foliage/signs
it stands among instead of drawing across the whole stage. See
[rendering.md](rendering.md) → "Shared render distance".

### Placement

`mid_offset()` picks a seeded along-track distance in
`[spectator_mid_progress_min, spectator_mid_progress_max]`. Each group is a band
**centred on the road** at its anchor, oriented along the local heading:
`members()` lays a jittered grid (cell = separation) over a
`spectator_area_length_m` × `spectator_area_width_m` rectangle that straddles the
carriageway, rejecting on-road cells and points within `spectator_tree_avoid_m` of a
tree, thinned to `spectator_group_size`. Because the road cells in the middle are
rejected, the crowd lines **both verges** over that stretch. All deterministic per
`track_seed` (each group gets a distinct salt). Groups are named
(`SpectatorStart` / `SpectatorMid` / `SpectatorEnd`) so an in-place regeneration
replaces rather than stacks them (mirrors `_place_arch`).

## Collision layers

- Upright crowd: no physics bodies at all (pure data + MultiMesh).
- Ragdolls: own layer (bit 5) with mask = layer 1 (terrain + trees), plus a
  per-body collision exception with the car. The car's own layer/mask are
  unchanged.

## Config

`@export_group("Spectators")` in `game_config.gd` (group size, mid-progress band,
crowd-band length/width, separation, flee/knock radii, max speed + accel, LOD radius,
the five steering weights, ragdoll launch params, despawn distance). Disable with
`spectators_enabled = false` or `spectator_group_size = 0`. The knock-drag knob
(`spectator_drag_strength`) lives in the **Damage** group but is plumbed through
`spectator_params()`.

## Tests

- `tests/headless/test_spectator_scatter.gd` — placement: mid-offset band +
  determinism; member count cap, determinism, within-radius, separation floor,
  off-road, tree-avoid, grid bucketing.
- `tests/headless/test_spectator_steering.gd` — each steering force's direction +
  radius cutoff, and the speed clamp.
- `tests/headless/test_spectator_damage.gd` — knocking a member over applies soft drag
  to the car (`spectator_drag_strength`), which the unified damage rule turns into HP loss.
- `tests/headless/test_smoke.gd` — groups spawn with standing members and are not
  obstacles.

## Future

- Crowd-cheer audio (ties into `todo/audio.md`).
- Optional articulated ragdoll if the single capsule reads too stiff.
- Re-export `spectator.glb` from Blender for correct per-material colours
  (current colours are placeholders from a pure-Python extraction).
