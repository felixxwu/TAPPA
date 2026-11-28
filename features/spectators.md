# Roadside spectators

Crowds of low-poly people standing trackside that react to the car: they shuffle
with simple steering preferences while upright, and are knocked flying when the
car hits them. The level authors where each group stands (see "Level spectator groups").

**Source:** `scripts/level_spectators.gd` (`LevelSpectators`), `scripts/spectator_group.gd` (`SpectatorGroup`);
where crowds stand at load is pinned by the scene counts golden (`benchmark/scene_counts.gd`, [benchmark.md](benchmark.md)).

Placement/steering share the low-level scatter helpers: `ScatterMath`
(`scripts/scatter_math.gd`, seeded `hash01` + road-cell tests) and `SpatialGrid`
(`scripts/spatial_grid.gd`, point/index binning + 3x3 proximity). `build_point_grid`
is a thin wrapper over `SpatialGrid.of_points`.

**Tests:** `tests/headless/test_level_spectators.gd`, `tests/headless/test_spectator_steering.gd`, `tests/headless/test_spectator_damage.gd`, `tests/headless/test_smoke.gd`

## Files

| File | Role |
|------|------|
| `scripts/crowd.gd` | `Crowd` — the ONE place that owns the shared figure mesh (`mesh()`) and the ground foot-offset (`foot_offset()`). Every crowd goes through it (like `Foliage` for trees/bushes); `SpectatorGroup` pulls the mesh + foot offset through it too, so no crowd can drift from the others. |
| `scripts/crowd_pool.gd` | `CrowdPool` — Hafren level only: ONE MultiMesh + instance per character model, shared by every `SpectatorGroup` (passed as `params["pool"]`). Groups lease slots (`acquire`) in `setup` and return them (`release`, hidden at zero scale, reusable) when they leave the tree; the pool grows by doubling and rewrites kept transforms. Pooled MMIs sit at world origin with no per-crowd visibility range. Without a pool (the dev stage) a group still owns its own MultiMesh. |
| `scripts/spectator_group.gd` | `SpectatorGroup` (Node3D) — owns one LIVE crowd: steering, its own dynamic MultiMesh (rewritten each frame), LOD, knockdown→ragdoll, despawn. Pure steering forces are static (unit-tested). Shares the figure via `Crowd.mesh()`/`Crowd.foot_offset()`. |
| `scripts/level_spectators.gd` | `LevelSpectators` spawns the level's saved spectator groups while the car is near. |
| `scripts/game_config.gd` | `spectator_params()`. |
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
the car is `spectator_despawn_behind_m` behind a ragdoll, it is **retired** — see the
pool below.

#### Ragdoll bodies are pre-built and recycled, never built on the knock frame

Constructing a ragdoll (a `RigidBody3D` + `CollisionShape3D` + `CapsuleShape3D` + a
`MeshInstance3D`, all three registered with the servers) is work that used to land on
the exact frame the car ploughs into a crowd — and a fast pass knocks *several* members
on the same tick. `setup()` now pre-builds `spectator_ragdoll_pool_size` bodies per group
while the loading screen is up (`SpectatorGroup._build_ragdoll`), parked **inert**:
`freeze = true`, `collision_layer`/`collision_mask` 0, hidden, no residual velocity
(`_park_ragdoll`). A knock takes one from the pool and brings it live
(`_acquire_ragdoll` — configured layers, unfrozen, visible, pose reset to standing so a
recycled body can't start mid-tumble); a retired ragdoll goes back into the pool
(`_release_ragdoll`) instead of being freed, so mowing through several crowds over a
whole stage pays the build cost once.

The pool bounds only the **prebuilt** set, never how many spectators can be knocked
over: a knock that finds the pool empty still builds a body on the spot, and a release
with the pool already full still frees it (which is what keeps bodies from accumulating,
exactly as the old `queue_free()` did). `ragdolls_built()` / `pooled_ragdoll_count()`
are the test readouts.

The other first-hit cost, the shader program for the ragdoll's **single**-instance draw
of the crowd mesh (a different `gl_compatibility` program than the upright crowd's
MultiMesh, so `_prewarm_corridor`'s flythrough never compiles it), is primed by
`SpectatorGroup.warm_up` / `clear_warm_up` via `level_view.gd`'s warm-up contract walk (`_warm_up`) — see
[rendering.md](rendering.md) → *Shader pre-warm*.

### Steering (boids on the XZ plane)

`SpectatorGroup._physics_process` batch-steers every upright member, clamped to
`spectator_max_speed_mps`. Each preference is a pure static force:

| Force | Preference | Notes |
|-------|-----------|-------|
| `flee_force` | move away from the car within `flee_radius_m` | squared near-field falloff = the "light push": the crowd parts/jostles hard as the car arrives |
| `road_force` | avoid the carriageway | 8-direction probe of the rasterised `road_cells`, each direction stepped out to `probe` and **distance-graded** (nearer road → stronger push, fading to zero at `probe`). The grading is what stops verge spectators jiggling on the spot: a bang-bang push (full within `probe`, zero just past it) has a hard switching surface that the anchor pull drags a member across and the road shoves back — a permanent chatter. The smooth gradient meets the anchor pull at a single static resting point instead |
| `obstacle_force` | avoid trees | probes a grid of tree points (`SpatialGrid.of_points`) |
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

**Static-field cache (perf):** the road and the trees **do not move**, so the combined
weighted `road_force + obstacle_force` push is a *static field* sampled at the member's
position — re-deriving it every steered tick (8 dirs × 10 steps of `ScatterMath.on_road`
= up to 80 dictionary probes per member, plus a 3×3 tree-grid scan) recomputes the same
answer over and over. `SpectatorGroup` caches that push per member alongside the position
it was sampled at (`_avoid` / `_avoid_at`), and re-samples only once the member has
drifted `AVOID_CACHE_STEP_M` (= `ScatterMath.CELL_M`, one road-raster cell — the
resolution the field is rasterised at, so a cached push can't hide a road boundary).
A standing member samples once, ever; a fleeing member re-samples every half metre of
travel. `live_avoid_force()` / `cached_avoid_force()` / `avoid_sample_count()` expose the
field and the probe count for tests. Separation is deliberately **not** cached —
neighbours move. The two grid scans also share a `static var _EMPTY_*` default instead of
allocating a throwaway Packed array on each of their nine `Dictionary.get` cell probes,
the `_p[...]` param lookups are hoisted out of the per-member loop, and the every-tick
knock-over scan uses `distance_squared_to`.

**LOD:** only the group within `spectator_active_radius_m` of the car runs
steering; the other two stand still until the car approaches.

**Sim decimation (perf):** within an active group the per-member steering runs only
every `spectator_sim_interval`-th physics tick, staggered per group (a phase from the
crowd centroid, added to the group's own tick counter `_ticks` — not
`Engine.get_physics_frames()`, whose count includes the level's pre-roll and so varies by machine) so active groups don't all recompute on the same frame. The delta
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

## Level spectator groups

The level view (`LevelView`) reads the save's top-level `spectators: [{x, z, r, n}]` (origin m, radius m, count) into `LevelSpectators` (`scripts/level_spectators.gd`). A group exists only while the car is within `level_spectator_spawn_m` of its centre and is freed past `level_spectator_despawn_m` (`wants_alive`, with hysteresis); the seed comes from the group index, so a respawn looks identical. A group whose placement finds no spot is remembered as empty until the car leaves, so it isn't rebuilt every `CHECK_S` (counted on the physics tick, `LevelSpectators._physics_process`, so crowds appear on the same tick at any frame rate; that rebuild was a ~60 ms stutter every half second). Their road cells come from `LevelSpectators.road_only` (the road edge from `road_nearest`), not `surface_at`, so the gravel pads round buildings count as ground they can stand and walk on.
The Hafren level's groups come from `node tools/geo/place_spectators.js` (seeded; rewrites only the save's `spectators` key): groups by buildings near a road, on the inside of sharp bends and by junctions, each circle snapped to overlap the nearest road edge by 2 m (`snapToEdge`) so people fill right up to the verge. Group counts and sizes are the `kinds` table and the `n` ranges in the script.
`place()` scatters `n` seeded spots in the disc, off the road (`road_cells_near`, rasterised from `LevelBake.surface_at`), clear of baked trees (`tree_points_near`) and building footprints (`LevelBuildings.footprint_points`), `spectator_separation_m` apart.
Each member gets a model from `Crowd.level_meshes()` (`assign_models`); `SpectatorGroup` keeps one MultiMesh per model (`_mms`, with per-member `_model` / `_slot`) and ragdolls wear the member's own model. Params: `meshes`, `models`, `face_car` (upright members turn their +Z front towards the car each steer tick, `face_yaw`; default off so free roam is unchanged). Behaviour is otherwise the free-roam crowd's. Members start at their scattered spot but their home (anchor) is set by `edge_homes`: nearest-road members take spots `level_spectator_edge_gap_m` off the road's edge cells, later ones step back towards their own spot in `spectator_separation_m * 1.5` steps until clear of earlier homes, so they shuffle to the verge on spawn and stay put (`setup` param `homes`). Level groups use `level_spectator_road_probe_m` as `road_probe_m` (in place of the generic `spectator_road_probe_m`) so road avoidance doesn't hold them off the edge. They walk to their home at `level_spectator_walk_mps` (passed as `w_anchor`, which is the anchor pull's speed in m/s). `spectators` is erased from `LevelBake.key_of`. Tests: `tests/headless/test_level_spectators.gd`.

## Collision layers

- Upright crowd: no physics bodies at all (pure data + MultiMesh).
- Ragdolls: own layer (bit 5) with mask = layer 1 (terrain + trees), plus a
  per-body collision exception with the car. The car's own layer/mask are
  unchanged. A **pooled** (not-yet-knocked or already-retired) body sits on layer/mask
  **0** and is frozen, so the prebuilt set never touches the broadphase.

## Config

The spectator fields in `game_config.gd` (group size, mid-progress band,
crowd-band length/width, separation, flee/knock radii, max speed + accel, LOD radius,
the five steering weights, ragdoll launch params, `spectator_ragdoll_pool_size`, despawn
distance). Disable with
`spectators_enabled = false` or `spectator_group_size = 0`. The knock-drag knob
(`spectator_drag_strength`) lives in the **Damage** group but is plumbed through
`spectator_params()`.

## Tests

- `tests/headless/test_spectator_steering.gd` — each steering force's direction +
  radius cutoff, the speed clamp, and the static-field cache (cached push equals the
  live probe, reused while the member barely moves, re-probed after real movement, a
  settled crowd stops probing, road avoidance + neighbour separation still hold).
- `tests/headless/test_spectator_damage.gd` — knocking a member over applies soft drag
  to the car (`spectator_drag_strength`), which the unified damage rule turns into HP loss.
- `tests/headless/test_smoke.gd` — groups spawn with standing members and are not
  obstacles.

## Future

- Crowd-cheer audio (ties into `todo/audio.md`).
- Optional articulated ragdoll if the single capsule reads too stiff.
- Re-export `spectator.glb` from Blender for correct per-material colours
  (current colours are placeholders from a pure-Python extraction).

## Spectator Lab

`tools/spectator_lab.html` is a standalone browser page (open the file directly, three.js from CDN, like the building lab)
that generates a crowd of abstract, faceless low-poly peg-figure spectators from a seed. Not wired into the game yet: the game still uses `blender/spectator/spectator.glb` (150 triangles) for every crowd.

`spectator(out, root, seed, opts)` builds one person from a handful of primitives (4-sided prisms for limbs, a 6-sided
torso, a 20-face icosahedron head, low partial spheres for hair and hats; no hands, feet or neck), modelled at 1.75 m and scaled per person to a height drawn from
the height range. Random per person: skin, hair, jacket/trousers colours, body width and belly, coat / t-shirt, hat
(beanie, cap, bucket hat, hood in rain), backpack, orange marshal tabard, and a pose from `POSES`
(two arm directions per side: stand, pockets, folded, wave, cheer, camera, umbrella).

Cheap to render by construction: no textures, colours are per-vertex, and the whole crowd is merged into ONE mesh with ONE
flat-shaded material (one draw call), ~130 triangles per person (~105 in the "limbless" style, where legs are one tapered trouser block and there are no arms; only the umbrella and camera poses still show, the camera floating in front of the face). "Download .glb" exports the current crowd.

## Baked export for the game

`node tools/bake_spectators.js` runs `tools/spectators.js` under node (three r128 downloaded once into the OS temp dir) and writes `models/spectators/spectators.glb`: 10 limbless people (`Spectator0`..`Spectator9`, one mesh each, flat normals, `COLOR_0` linear vertex colours, one shared double-sided roughness-1 material, feet at y=0, facing +Z, real metres). People are the `PEOPLE` list (seed, height) in the script; `SCAN=40 node tools/bake_spectators.js` prints triangle counts per seed to help pick. After changing it run `godot --headless --import`. `Crowd.level_meshes()` (`scripts/crowd.gd`) returns the 10 meshes in node order with a shared vertex-colour material.

Dialogue portraits are rendered from the same figures: `tools/render_npc.sh`, see [npc-dialogue.md](npc-dialogue.md).

## Threaded steering

Groups with at least `GameConfig.threaded_spectator_min_members` members (and `threaded_spectators` on, and `OS.has_feature("threads")`) steer in two passes (`SpectatorGroup._steer_wide`): `_steer_member` runs per member on a `WorkerThreadPool` group task and writes `_nvel[i]` (it reads only start-of-tick `_pos`, so it differs slightly from the sequential loop, where later members see earlier members' moved positions); then the main thread integrates positions, yaw and MultiMesh writes. Knock-overs and ragdoll ageing stay on main. Smaller groups or the toggle off run the original single loop. `threaded_spectators` is **off** by default: in the web replay benchmark (2026-11-26) the 58-member group spent ~25 ms a tick in the wide pass against under 1 ms in the plain loop, since handing tiny per-member jobs to the web build's two workers costs far more than the work.

**Threaded placement:** with `OS.has_feature("threads")`, `LevelSpectators.refresh` works out a group's placement (`_place_job`: road cells, obstacle grid, members, homes; reads only the bake and building footprints) on a `WorkerThreadPool` task, and `_collect_placed` builds the `SpectatorGroup` on the main thread (`_build`) once it lands; a group the car leaves meanwhile is dropped. Doing it inline cost 17–72 ms hitches as the car approached crowds. A golden replay (`Benchmark.golden`) places inline (`_threaded()` is false), so groups appear on the same tick every run.
