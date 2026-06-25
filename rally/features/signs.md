# Roadside Signs

**Sources:** `scripts/sign_layout.gd` (`SignLayout`, pure planner) +
`scripts/sign_field.gd` (`SignField`, the Node3D builder), planned/built in
`scripts/world.gd._generate_track`. Tunables in the `Roadside Signs` group of
`scripts/game_config.gd`. See the brief in [../todo/roadside-signs.md](../todo/roadside-signs.md).

Free-standing **A-frame ("wet-floor") boards** along the stage that read the road
to a driver: **sector** boards, **turn arrows**, and **start/finish** gates. They
are cosmetic *and* physical — each carries an obstacle collision body, so clipping
one drains HP through the same path as trees ([damage.md](damage.md)).

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
  `k*L/count`. Sector 1 is the start gate, so offset 0 isn't double-signed.
- **Turns** — for each piece whose corner ∈ `{1, 2, Square, Hairpin}` ("2 or
  sharper"; the compound `Right 4 tightens 2` is excluded), a pair at the
  **corner entry** = `entry_pos + entry_heading * straight` snapped to the curve
  via `get_closest_offset`. The arrow `texture_key` encodes shape (curve / square
  / uturn) + direction (`flip` → left, else right).
- **Start / Finish** — a pair each at offsets `0` and `L`, forming gates.

`SignLayout.sector_offsets(centerline, count)` exposes the boundary offsets so the
stage timer can reuse them for per-sector splits later ([stage.md](stage.md), §5
of the brief) instead of recomputing.

**`SignField.build(layout, terrain, params)` — the Node3D.** One child node per
sign (signs number in the tens, so individual nodes; no MultiMesh/culling — the
engine frustum-culls them and each face texture is unique). Per sign:
- **Placement** — `edge = pos + side * perp * (track_width/2 - sign_edge_inset_m)`;
  ground `y = terrain.height_at(pos.x, pos.y)` (the **centerline** height = the
  flat road surface). Oriented so **-Z runs along the road tangent** and the ridge
  (local X) crosses the road, so the large faces point up-track / down-track.
- **Geometry** — two thin `BoxMesh` panels tilted `±sign_splay_deg` about the
  ridge: tops meet at the apex, bottoms splay into a stable footprint.
- **Material** — `shaders/ps1_models.gdshader`; the atlas face texture if one is
  wired in `sign_textures` for the key, otherwise a **flat per-kind colour
  fallback** so geometry is visible before the art lands.
- **Collision** — one `StaticBody3D` (+ `BoxShape3D` sized
  `panel_size × sign_base_depth_m`, resting on the ground) in
  `DamageModel.OBSTACLE_GROUP`, so a hit is counted by the damage model.

## Config (`GameConfig` › *Roadside Signs*)

`sign_sector_count`, `sign_panel_size_m`, `sign_thickness_m`, `sign_splay_deg`,
`sign_edge_inset_m`, `sign_base_depth_m`, `sign_textures`. Bundled for the two
layers by `sign_params()` (layout) and `sign_render_params()` (field).

## Assets (pending)

`sign_textures` is empty by default → everything shows on its colour fallback. The
authored PS1-look atlas (sector boards, 6 arrow variants, start/finish banners) in
`textures/signs/` is an open art action item (todo/roadside-signs.md); wiring the
keys into `sign_textures` is all the code needs once they exist.

## Tests

`tests/headless/test_sign_layout.gd` — sector/turn/start-finish counts, keys,
offsets, left/right arrow mapping, determinism, `sector_offsets`.
`tests/headless/test_smoke.gd` — `SignField.build` creates one node per sign, two
panels each, an obstacle-group collision body, sitting at the road-surface height.
