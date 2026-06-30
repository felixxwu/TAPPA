# Roadside spectators

Crowds of low-poly people standing trackside that react to the car: they shuffle
around with simple steering preferences while upright, and get knocked flying
when the car hits them. Three groups per stage — one at the start, one at the
end, and one at a random mid-stage point.

Status: **spec / not yet implemented.** Brainstormed with the user 2026-06; all
four design forks below were deferred to the recommended option.

## Design decisions (locked)

1. **Car ↔ crowd = light push (kinematic).** Upright spectators stay **non-solid
   to the car** — they are NOT in `DamageModel.OBSTACLE_GROUP` and never slow or
   damage the vehicle (avoids blowing the car's `MAX_CONTACTS_REPORTED` cap). The
   "push" is a **strong close-range kinematic shove**: when the car is right on
   top of them the crowd visibly parts/jostles aside, and an actual strike flips
   that spectator to a tumbling ragdoll. So the upright crowd has **no physics
   bodies at all** — it is pure agent data + a MultiMesh, and knockdown is a
   distance test against the car. Only ragdolls are real `RigidBody3D`s.
2. **Ragdoll = single tumbling capsule.** The spectator model has **no armature**
   (confirmed when extracting `spectator.glb` — 0 bones), so a `PhysicalBone3D`
   ragdoll is not available without rigging. A single `RigidBody3D` capsule that
   tumbles under an impulse is the v1 fidelity; reads fine for a stylized figure
   flung by a rally car.
3. **Aftermath = stay down, then despawn.** Knocked spectators tumble, settle,
   remain as props, and are quietly freed once the car is well past them
   (distance-behind threshold). No get-back-up in v1.
4. **Render the model.** Use `blender/spectator/spectator.glb` (the extracted low-poly
   figure). Real material colours are placeholders for now (see that file's
   provenance); a clean re-export from Blender can replace it later without
   touching this system.

## Architecture

### Representation — "ghost crowd + impulse ragdolls"

Each spectator is a `RigidBody3D` with a single `CapsuleShape3D`, on a new
dedicated collision layer (call it `spectator`). Two states:

- **Upright (default):** `freeze = true`, `freeze_mode = FREEZE_MODE_KINEMATIC`.
  The body is moved by its group manager each physics tick (kinematic). Its layer
  is **not** in the car's `collision_mask`, so there is zero vehicle interaction.
- **Knocked:** `freeze = false` → dynamic. An impulse derived from the car's
  `linear_velocity` (direction + speed-scaled magnitude + a little torque/lift) is
  applied once. Ragdoll layer collides with ground/terrain (lands + rolls) but is
  **masked out from the car**, so a crowd can never bog the car down.

Why not the tree pattern (`billboard_field.gd`): trees are one static body with N
fixed `BoxShape3D` transforms, tagged as obstacles. Spectators move per-tick and
each transitions individually — they need per-agent identity and movable
transforms, and must NOT be obstacles.

### Steering (boids on the XZ plane)

A `SpectatorGroup` manager node owns ~50 members and runs ONE `_physics_process`
that batch-computes a desired velocity per agent (clamped to `max_speed`) from
weighted terms, then writes each body's transform:

1. **Separation (≈0.5 m):** push away from within-group neighbours. Only O(n²)
   piece — 50²≈2.5k checks/tick is trivial; a uniform grid hash is the escape
   hatch if counts rise.
2. **Flee car (≈5 m radius):** push along the away-from-car vector, scaled by
   closeness. The manager already needs the car vector for knockdown detection.
3. **Avoid road:** reuse the rasterized `road_cells` + the `_on_road` idea from
   `tree_scatter.gd` (`floori(p / CELL_M)` cell lookup), or distance-to-centerline,
   as a gradient pushing off the road.
4. **Avoid obstacles (trees etc.):** `world.gd` already has the tree
   `PackedVector2Array`; push away from nearby tree points (grid-hashed).
5. **Return-to-anchor:** gentle pull back to spawn anchor when no car is near, so
   the crowd doesn't drift away over a stage.

### Knockdown detection

One `Area3D` child on the car (`$Car`), monitoring only the `spectator` layer.
`body_entered` reports exactly which spectators the car touched → flip each to the
knocked state. No per-agent polling; Area cost is low.

### Performance / LOD

- **Distance LOD:** only the group nearest the car runs steering each tick; the
  other two idle (static) until the car approaches. Active steering ≈ one group.
- **Render:** draw the 50 upright figures via a `MultiMeshInstance3D` updated from
  the manager transforms (one draw call), mirroring `billboard_field.gd`'s
  one-MultiMesh approach. Knocked ragdolls become individual `MeshInstance3D` +
  `RigidBody3D` (few at a time).

### Spawning

In `world.gd._generate_track`, after centerline + `road_cells` + `trees` exist
(it already computes all three around lines 179–217):

- **Mid group:** seeded pick of progress in `[0.30, 0.70]` → offset on
  `road_centerline`; sample point + tangent (cf. the finish-arch placement at
  lines 230–240); lay ~50 spectators clustered to one side, off-road. Reject
  on-road points (`_on_road`) and points too close to a tree. Deterministic via
  `cfg.track_seed` (+ a salt), like `TreeScatter`.
- **Start group:** cluster near `start_pos` / `start_heading` (the real spawn).
- **End group:** cluster near `road_centerline.sample_baked(baked_length)` (the
  finish-arch anchor).

## Config (game_config.gd → game_config.tres)

New `@export_group("Spectators")` + a `spectator_params()` accessor returning a
Dictionary, mirroring `tree_params()` / `sign_render_params()`:

- `spectator_group_size := 50`
- `spectator_mid_progress_min := 0.30`, `spectator_mid_progress_max := 0.70`
- `spectator_spawn_radius_m`, `spectator_road_margin_m`
- `spectator_separation_m := 0.5`, `spectator_flee_radius_m := 5.0`
- `spectator_max_speed_mps`
- steering weights (separation / flee / road / obstacle / anchor)
- `spectator_knockdown_impulse`, `spectator_knockdown_torque`
- `spectator_despawn_behind_m`
- collision layer/mask bits for upright + ragdoll
- `spectator_size_m`, render distance/fade (cf. tree render fields)

## Files

- **Add** `scripts/spectator_group.gd` (`class_name SpectatorGroup`) — owns
  members, steering, LOD, detection wiring, knockdown.
- **Add** `scripts/spectator.gd` (or keep per-agent state in the group) — the
  RigidBody3D upright/knocked state machine + impulse.
- **Add** placement helper (pure/seeded/headless, like `TreeScatter`) — e.g.
  `scripts/spectator_scatter.gd`, returning cluster anchor + member offsets so it
  can be unit-tested without a scene.
- **Edit** `scripts/world.gd._generate_track` — spawn the three groups.
- **Edit** `scripts/game_config.gd` + `config/game_config.tres` — config block.
- **Edit** `scripts/car.gd` — add the detection `Area3D` (no physics-layer change
  to the car body itself).
- **Add** `features/spectators.md` + index it in `features/README.md`.

## Testing (tests/headless/)

- Placement helper (pure): groups land off-road, respect separation, cluster
  within radius, are deterministic per seed, avoid tree points. (Bare-logic, no
  scene — cheapest.)
- Steering: separation pushes overlapping agents apart; flee moves agents away
  from a mock car within radius; speed never exceeds `max_speed`; road-avoid keeps
  agents off `road_cells`.
- Knockdown transition: a frozen agent flipped to knocked becomes non-frozen and
  receives a velocity; stays masked off the car.
- Smoke (`test_smoke.gd`): three groups exist after world gen; spectators are NOT
  in `OBSTACLE_GROUP`; car has the detection Area.

## Open questions / future

- Crowd cheering audio (ties into `todo/audio.md`).
- Optional articulated ragdoll if single-capsule reads too stiff.
- Re-export `spectator.glb` from Blender for correct material colours.
- Tune group size / LOD against the perf budget (`todo/performance-optimisations.md`).

## Dependencies

- Reuses `road_centerline` (Curve2D), `road_cells`, `trees` and `$Floor`
  (`TerrainManager.height_at`) — all already built in `world.gd._generate_track`.
- No dependency on unfinished specs.
