# Roadside Signs

**Sources:** `scripts/sign_layout.gd` (`SignLayout`, pure planner) +
`scripts/sign_field.gd` (`SignField`, the Node3D builder), planned/built in
`scripts/world.gd._generate_track`. Tunables in the `Roadside Signs` group of
`scripts/game_config.gd`. See the brief in [../todo/roadside-signs.md](../todo/roadside-signs.md).

Free-standing **A-frame ("wet-floor") boards** along the stage that read the road
to a driver — **turn arrows** only. The start and finish are marked by the
inflatable arches ([finish-arch.md](finish-arch.md)), not signs, and the stage is no
longer split into signed sectors (it is too short to carve into meaningful sector
boards). Each board is a **light, knockable `RigidBody3D`** that behaves like a
knocked **spectator** ([spectators.md](spectators.md)) rather than a solid prop: it
**never runs real collision physics against the car**. It lives on its own collision
layer (off the car's mask) and masks only the world layer (terrain + trees), so the
car drives straight through it; on contact the waker **flings it along the car's
travel direction** — a fake collision — and it then tumbles on the terrain on its own.
They deal **no HP damage**: their collision is decoupled from the car (own layer, off
the car's mask — see below), so the car never decelerates against a sign, and damage is
keyed purely to deceleration ([damage.md](damage.md)). They're also *not* in the
`OBSTACLE_GROUP`, so they trigger no tree-style fell reaction.
(`SignField` is still a kind-agnostic builder — it can render a "sector"/"start"/
"finish" board if ever handed one — but `plan` only emits turns.)

## Two layers: plan, then build

**`SignLayout.plan(centerline, pieces)` — pure, scene-free** (mirrors
`TrackGenerator`/`TreeScatter`, unit-tested without a scene). Returns one
placement dict per physical sign:

```
{ kind: "turn",          # the only kind plan() emits
  texture_key: String,   # GameConfig.sign_textures key, e.g. "arrow_2_left"
  pos: Vector2,          # centerline point (XZ) at this sign's arc offset
  tangent: Vector2,      # unit road direction there
  side: int }            # +1 / -1 : which road edge
```

Placement rule — **Turns only:** for each piece whose corner ∈
`{1, 2, 3, 4, Square, Hairpin}` ("4 or sharper"; gentle 5s/6s are too straight to
sign, and the compound `Right 4 tightens 2` is excluded), a **pair** (both sides) at
the **corner entry** = `entry_pos + entry_heading * straight` snapped to the curve
via `get_closest_offset`. The arrow `texture_key` encodes the grade + direction:
numbered corners use `arrow_<grade>_<dir>`, `Square` → `arrow_square_<dir>`, `Hairpin`
→ `arrow_uturn_<dir>`. The board is an A-frame facing the oncoming driver, which
**mirrors** the arrow's left/right relative to the corner's mathematical handedness,
so `_arrow_key` picks the **opposite-handed** source art (`dir = "right" if flip else
"left"`) — a left-hand corner gets the `*_right` art, which reads as a left turn on
the facing panel. The swap is done at selection time (not by mirroring the texture)
so the printed grade digit stays correct.

`SignLayout.sector_offsets(centerline, count)` still exposes equal arc-length
boundary offsets, now decoupled from signs — kept only as the stage timer's hook for
per-sector splits later ([stage.md](stage.md), §5 of the brief).

**`SignField.build(layout, terrain, params)` — the builder.** One `RigidBody3D`
per sign for physics, but resting signs are RENDERED through shared MultiMeshes:
one `MultiMeshInstance3D` per distinct face material (texture key), two panel
instances per sign, so the whole field costs a handful of draw calls. Materials
are cached per texture key (`_materials`) so same-faced signs batch. Each resting
`MultiMeshInstance3D` is culled at the **shared world-prop render distance**
(`cfg.tree_render_distance_m` / `tree_render_fade_m`, via `sign_render_params()` →
`MeshUtil.apply_visibility_range`), so far signs stop drawing with the rest of the
roadside dressing — see [rendering.md](rendering.md) → "Shared render distance". A sign only
gains its own panel `MeshInstance3D`s when knocked: `_wake_sign` zero-scales its
MultiMesh instances (`_materialize_sign`; a MultiMesh can't remove single
instances) and attaches real panels to the body, which then tumbles as one with
the hitbox. Per sign:
- **Placement** — `edge = pos + side * perp * (track_width/2 - sign_edge_inset_m)`;
  ground `y = terrain.height_at(pos.x, pos.y)` (the **centerline** height = the
  flat road surface). This is the **resting pose**; physics takes over once the
  car hits it. Oriented so **-Z runs along the road tangent** and the ridge
  (local X) crosses the road, so the large faces point up-track / down-track.
- **Geometry** — two thin double-sided **quad** panels tilted `±sign_splay_deg`
  about the ridge: tops meet at the apex, bottoms splay into a stable footprint.
  Each quad maps the **full** face texture (UV 0..1) on both sides — a `BoxMesh`
  would unwrap its six faces into an atlas, showing only a zoomed-in slice.
- **Material** — `shaders/ps1_models.gdshader`; the atlas face texture if one is
  wired in `sign_textures` for the key, otherwise a **flat per-kind colour
  fallback** so geometry is visible before the art lands.
- **Body** — a `RigidBody3D` of mass `sign_mass_kg` (light, so it scatters readily)
  with a `BoxShape3D` child sized `panel_size × sign_base_depth_m`, centred half its
  height up so the box bottom rests on the ground and the centre of mass sits above
  the base (a low hit tips it over). It is **not** in the damage obstacle group —
  clipping a sign costs no HP. **Collision is decoupled from the car:** the body sits
  on its own layer (`knock_layer = 1 << 4`, off the car's default mask) and masks only
  the world layer (`knock_mask = 1`, terrain + trees), so the car never collides with
  it.
- **Spawned frozen** — the body starts `freeze = true` (`FREEZE_MODE_STATIC`),
  resting exactly at the placed road-surface pose. **This is essential:** terrain
  collision is only streamed in a small ring around the car (`TerrainManager`
  `RADIUS`), so a live `RigidBody3D` on a far part of the track would have no ground
  and **free-fall into the void** before the player ever drove there (the cause of
  "missing / wrong" signs). A child **`Area3D` waker**, a touch larger than the
  hitbox, knocks the sign over when the car enters it. The waker ignores the sign's
  **own** body and any **`StaticBody3D`** (streamed terrain chunks + tree hitboxes
  share the world layer) — only the dynamic car wakes a sign.
- **Knocked, not collided** — when the car enters the waker, `_wake_sign` adds an
  explicit collision exception with the car (belt-and-braces over the layer split,
  since the sign's world-layer mask would otherwise still pair it with the car),
  unfreezes the body, and **launches it** along the car's velocity. The **whole impulse
  scales with the car's speed**: launch speed is `clampf(speed × knock_speed_factor,
  knock_speed_min, knock_speed_max)`, the upward kick is a *fraction* of that launch
  (`knock_lift_ratio`, a fixed angle — not a constant m/s that would dominate slow
  hits), and the `knock_spin` tumble tapers to zero as the car slows. So crawling into a
  sign nudges it gently along the ground instead of flinging it into the air. This is
  the same recipe `SpectatorGroup` uses for ragdolls: the impulse fakes the collision,
  then physics rolls the sign over the terrain without the car ever touching it.
- **Reset for the replay** — `reset_knocked()` stands every knocked sign back up at its
  build-time resting pose. Build records each body's resting transform + MultiMesh
  panel slots in a persistent `_home` map (never erased on knock, unlike `_rendered`).
  Reset re-freezes the body, restores `_home[body].rest`, `queue_free`s the per-node
  panel `MeshInstance3D`s `_materialize_sign` attached, un-hides the shared MultiMesh
  panels (rebuilding each instance transform as `rest × panel-local`), and returns the
  body to `_rendered` so a fresh run can wake it again. Only signs that actually left the
  batch (in `_home` but not `_rendered`) are touched. `world.gd._present_standings_overlay`
  calls this via `_reset_props_for_replay()` when the run ends, so the replay shows the
  signs intact (same pass resets felled trees — see [trees.md](trees.md)).

## Config (`GameConfig` › *Roadside Signs*)

`signs_enabled` (master switch — false skips the sign build entirely; the
benchmark's signs toggle drives it, see [benchmark.md](benchmark.md)),
`sign_panel_size_m`, `sign_thickness_m`, `sign_splay_deg`, `sign_edge_inset_m`,
`sign_base_depth_m`, `sign_mass_kg`, `sign_textures`, and the knock-over launch
(`sign_knock_speed_factor`, `sign_knock_speed_min`, `sign_knock_speed_max`,
`sign_knock_lift_ratio`, `sign_knock_spin`) — bundled for the build layer by
`sign_render_params()` (which also adds the structural `knock_layer`/`knock_mask`).
(`sign_sector_count` also lives in this group but no longer drives any signs; it is
the stage timer's `sector_offsets` hook — see above.)

## Assets

**Turn-arrow boards** are authored and wired. `tools/bake_sign_arrows.gd` renders one
PS1-look pacenote face per signed turn type: a bold arrow whose bend traces the REAL
corner shape from `CornerLibrary` (so it encodes the turn intensity), an orange rule,
and the grade below (`1`..`6`, `SQ`, `U`). Each is baked in a left and a right
(mirrored) variant to `textures/signs/arrow_*_<dir>.png` (cream/ink/orange palette,
shared with the finish banners) and mapped in `sign_textures`
(`config/game_config.tres`). The **roadside** signs only plant the `SignLayout.TURN_CORNERS`
subset (`{1, 2, 3, 4, Square, Hairpin}` — gentle 5s/6s are too straight to warrant a
board), but the gentle `arrow_5`/`arrow_6` boards **are** baked here because the in-run
HUD pacenote strip ([hud.md](hud.md)) calls every corner and reuses this same art.
Re-bake with:

```
xvfb-run -a godot --path rally --rendering-driver opengl3 --script tools/bake_sign_arrows.gd
godot --headless --path rally --import   # regenerate the .import files
```

Any key absent from `sign_textures` simply shows the per-kind colour fallback.

## Tests

`tests/headless/test_sign_layout.gd` — that only turn signs are planted (no
start/finish/sector boards), the turn count, keys (incl. 5/6 unsigned), left/right
arrow mapping, determinism, and the `sector_offsets` helper.
`tests/headless/test_sign_field.gd` — the MultiMesh rendering contract: resting
signs have no per-node panels (one MultiMesh per face material, two instances per
sign); a knocked sign leaves the batch and gains its two real panels, exactly once.
`tests/headless/test_smoke.gd` — `SignField.build` creates one body per sign
(panels batched, not nodes), a collision body + an `Area3D` waker, spawned **frozen** and sitting at
the road-surface height, on its own layer + world-only mask (so the car can't collide
with it); and that a sign wakes only on a dynamic non-self contact (the car), never
from its own body or a `StaticBody3D` (terrain/trees) — and that waking **launches**
it (non-zero velocity) and adds a **collision exception** with the car.
