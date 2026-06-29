# Roadside Signs

**Sources:** `scripts/sign_layout.gd` (`SignLayout`, pure planner) +
`scripts/sign_field.gd` (`SignField`, the Node3D builder), planned/built in
`scripts/world.gd._generate_track`. Tunables in the `Roadside Signs` group of
`scripts/game_config.gd`. See the brief in [../todo/roadside-signs.md](../todo/roadside-signs.md).

Free-standing **A-frame ("wet-floor") boards** along the stage that read the road
to a driver: **sector** boards, **turn arrows**, and a **finish** gate. (The start
is marked by the inflatable start arch — [finish-arch.md](finish-arch.md) — so the
planner no longer plants A-frame start boards, though `SignField` can still build
the "start" kind if handed one.) Each is a **light, knockable `RigidBody3D`** — the car scatters them on contact and
they deal **no HP damage** (they are cosmetic clutter, deliberately *not* in the
damage `OBSTACLE_GROUP`, unlike the solid trees in [damage.md](damage.md)).

## Two layers: plan, then build

**`SignLayout.plan(centerline, pieces, params)` — pure, scene-free** (mirrors
`TrackGenerator`/`TreeScatter`, unit-tested without a scene). Returns one
placement dict per physical sign:

```
{ kind: "sector"|"turn"|"start"|"finish",
  texture_key: String,   # GameConfig.sign_textures key, e.g. "sector_2", "arrow_square_left"
  pos: Vector2,          # centerline point (XZ) at this sign's arc offset
  tangent: Vector2,      # unit road direction there
  side: int }            # +1 / -1 : which road edge
```

Placement rules:
- **Sectors** — the stage is split into `sign_sector_count` (default 4) equal
  arc-length segments; a **pair** (both sides) marks entering sectors 2..N at
  `k*L/count`. Sector 1 is the start line, so offset 0 isn't signed.
- **Turns** — for each piece whose corner ∈ `{1, 2, Square, Hairpin}` ("2 or
  sharper"; the compound `Right 4 tightens 2` is excluded), a pair at the
  **corner entry** = `entry_pos + entry_heading * straight` snapped to the curve
  via `get_closest_offset`. The arrow `texture_key` encodes the grade + direction:
  numbered corners use `arrow_<grade>_<dir>` (e.g. `arrow_1_right`, `arrow_2_left`)
  so each board shows its own number; `Square` → `arrow_square_<dir>`, `Hairpin` →
  `arrow_uturn_<dir>` (`flip` → left, else right).
- **Finish** — a pair at offset `L`, forming the finish gate. (No start pair; the
  start arch marks the start line.)

`SignLayout.sector_offsets(centerline, count)` exposes the boundary offsets so the
stage timer can reuse them for per-sector splits later ([stage.md](stage.md), §5
of the brief) instead of recomputing.

**`SignField.build(layout, terrain, params)` — the builder.** One `RigidBody3D`
per sign (signs number in the tens, so individual nodes; no MultiMesh/culling —
the engine frustum-culls them and each face texture is unique). The panels and
hitbox are **children of the body**, so the whole sign tumbles as one. Per sign:
- **Placement** — `edge = pos + side * perp * (track_width/2 - sign_edge_inset_m)`;
  ground `y = terrain.height_at(pos.x, pos.y)` (the **centerline** height = the
  flat road surface). This is the **resting pose**; physics takes over once the
  car hits it. Oriented so **-Z runs along the road tangent** and the ridge
  (local X) crosses the road, so the large faces point up-track / down-track.
- **Geometry** — two thin `BoxMesh` panels tilted `±sign_splay_deg` about the
  ridge: tops meet at the apex, bottoms splay into a stable footprint.
- **Material** — `shaders/ps1_models.gdshader`; the atlas face texture if one is
  wired in `sign_textures` for the key, otherwise a **flat per-kind colour
  fallback** so geometry is visible before the art lands.
- **Body** — a `RigidBody3D` of mass `sign_mass_kg` (light, so the heavy car
  scatters it) with a single `BoxShape3D` child sized `panel_size ×
  sign_base_depth_m`, centred half its height up so the box bottom rests on the
  ground and the centre of mass sits above the base (a low hit tips it over). The
  body sleeps once settled, so the at-rest cost is negligible. It is **not** in
  the damage obstacle group — clipping a sign costs no HP.

## Config (`GameConfig` › *Roadside Signs*)

`sign_sector_count`, `sign_panel_size_m`, `sign_thickness_m`, `sign_splay_deg`,
`sign_edge_inset_m`, `sign_base_depth_m`, `sign_mass_kg`, `sign_textures`. Bundled
for the two layers by `sign_params()` (layout) and `sign_render_params()` (field).

## Assets

**Turn-arrow boards** are authored and wired. `tools/bake_sign_arrows.gd` renders one
PS1-look pacenote face per turn type: a bold arrow whose bend traces the REAL corner
shape from `CornerLibrary` (so it encodes the turn intensity), an orange rule, and the
grade below (`1`..`6`, `SQ`, `U`). Each is baked in a left and a right (mirrored)
variant to `textures/signs/arrow_*_<dir>.png` (cream/ink/orange palette, shared with the
finish banners), and the full set is mapped in `sign_textures` (`config/game_config.tres`).
By default only `{1, 2, Square, Hairpin}` are signed (`SignLayout.TURN_CORNERS`), but the
`3`..`6` boards are baked + wired too, so widening that set needs no new art. Re-bake with:

```
xvfb-run -a godot --path rally --rendering-driver opengl3 --script tools/bake_sign_arrows.gd
godot --headless --path rally --import   # regenerate the .import files
```

**Still pending:** sector boards (`sector_2`..) and the start/finish *A-frame* banners
keep their per-kind colour fallback (the finish *gate* itself is the inflatable arch,
already textured — see [finish-arch.md](finish-arch.md)). Any key absent from
`sign_textures` simply shows its colour fallback.

## Tests

`tests/headless/test_sign_layout.gd` — sector/turn/finish counts (and that no
start boards are planted), keys, offsets, left/right arrow mapping, determinism,
`sector_offsets`.
`tests/headless/test_smoke.gd` — `SignField.build` creates one node per sign, two
panels each, an obstacle-group collision body, sitting at the road-surface height.
