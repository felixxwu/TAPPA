# Roadside Signs

**Sources:** `scripts/sign_layout.gd` (`SignLayout`, pure planner) +
`scripts/sign_field.gd` (`SignField`, the Node3D builder), planned/built in
`scripts/world.gd._generate_track`. Tunables in the `Roadside Signs` group of
`scripts/game_config.gd`. See the brief in [../todo/roadside-signs.md](../todo/roadside-signs.md).

Free-standing **A-frame ("wet-floor") boards** along the stage that read the road
to a driver — **turn arrows** only. The start and finish are marked by the
inflatable arches ([finish-arch.md](finish-arch.md)), not signs, and the stage is no
longer split into signed sectors (it is too short to carve into meaningful sector
boards). Each board is a **light, knockable `RigidBody3D`** — the car scatters them
on contact and they deal **no HP damage** (cosmetic clutter, deliberately *not* in
the damage `OBSTACLE_GROUP`, unlike the solid trees in [damage.md](damage.md)).
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
numbered corners use `arrow_<grade>_<dir>` (e.g. `arrow_1_right`, `arrow_2_left`) so
each board shows its own number; `Square` → `arrow_square_<dir>`, `Hairpin` →
`arrow_uturn_<dir>` (`flip` → left, else right).

`SignLayout.sector_offsets(centerline, count)` still exposes equal arc-length
boundary offsets, now decoupled from signs — kept only as the stage timer's hook for
per-sector splits later ([stage.md](stage.md), §5 of the brief).

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

`sign_panel_size_m`, `sign_thickness_m`, `sign_splay_deg`, `sign_edge_inset_m`,
`sign_base_depth_m`, `sign_mass_kg`, `sign_textures` — bundled for the build layer by
`sign_render_params()`. (`sign_sector_count` also lives in this group but no longer
drives any signs; it is the stage timer's `sector_offsets` hook — see above.)

## Assets

**Turn-arrow boards** are authored and wired. `tools/bake_sign_arrows.gd` renders one
PS1-look pacenote face per signed turn type: a bold arrow whose bend traces the REAL
corner shape from `CornerLibrary` (so it encodes the turn intensity), an orange rule,
and the grade below (`1`..`4`, `SQ`, `U`). Each is baked in a left and a right
(mirrored) variant to `textures/signs/arrow_*_<dir>.png` (cream/ink/orange palette,
shared with the finish banners) and mapped in `sign_textures`
(`config/game_config.tres`). The set matches `SignLayout.TURN_CORNERS` exactly
(`{1, 2, 3, 4, Square, Hairpin}`); gentle 5s/6s are unsigned, so no board is baked for
them. Re-bake with:

```
xvfb-run -a godot --path rally --rendering-driver opengl3 --script tools/bake_sign_arrows.gd
godot --headless --path rally --import   # regenerate the .import files
```

Any key absent from `sign_textures` simply shows the per-kind colour fallback.

## Tests

`tests/headless/test_sign_layout.gd` — that only turn signs are planted (no
start/finish/sector boards), the turn count, keys (incl. 5/6 unsigned), left/right
arrow mapping, determinism, and the `sector_offsets` helper.
`tests/headless/test_smoke.gd` — `SignField.build` creates one node per sign, two
panels each, a collision body, sitting at the road-surface height.
