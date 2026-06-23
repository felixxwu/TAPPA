# Roadside Signs — implementation spec

> Status: **planned, not yet implemented.** Implementation brief, referencing the
> code as it exists on this branch. Follow the config-first convention
> (`CLAUDE.md`): every new tunable goes in `GameConfig`
> (`scripts/game_config.gd` + `config/game_config.tres`), never hardcoded.
> Update the relevant `features/*.md` doc and add/adjust tests in the same piece
> of work.
>
> **Dependencies:** none blocking. Builds only on the existing track generator
> (`scripts/track_generator.gd`) and terrain (`scripts/terrain_manager.gd`).
> *Related* (not required): `todo/stage-start-and-end.md` (the start/finish
> markers and the 4 equal sectors could later line up with the stage timer /
> per-sector splits) and `todo/track-progress-and-reset.md` (both use the
> centerline `Curve2D` offset API). No need to implement those first.

## ⚠️ Open action items (asset / prerequisite work)

- [ ] **Author the sign-face texture atlas** (PNGs, PS1 look, `filter_nearest`).
      Needed because we chose authored textures over runtime text. One face image
      per sign variant. Owner: Felix. Required set:
      - **Sector**: "SECTOR 2", "SECTOR 3", "SECTOR 4" (sector 1 is implied by the
        start gate — see §3). Add "SECTOR 1" too if you'd rather sign it as well.
      - **Turn arrows**, with **left and right variants** (mirror) because
        `piece["flip"]` decides turn direction: curved arrow (for gradients `1`
        and `2`), right-angle arrow (for `Square`), U-turn arrow (for `Hairpin`).
        → 3 shapes × 2 directions = 6 arrow images.
      - **Start** and **Finish** banners.
      Drop them in `textures/signs/` and wire keys in config (see §6). Until they
      exist, the field can fall back to a flat colour per kind so the geometry is
      testable.

## Context / current state (measured from the code)

- **Track pieces** come from `TrackGenerator.generate(...)`
  (`scripts/track_generator.gd:84-99`); each piece dict is built at
  `:226-231` with `{ "corner", "flip", "straight", "cells" }`. **It does NOT
  record where the piece starts along the centerline** — only its corner name,
  L/R flip, connecting-straight length, and rasterised cells. At commit time the
  search holds `frame_pos` / `frame_heading` = the piece's **entry pose**
  (`:197`, `:232-233`), but these aren't saved. §1 adds them.
- **Corner library** (`scripts/corner_library.gd:14-88`): gradients `"1"`
  (sharpest) … `"6"` (gentlest), plus `"Square"` (~90°), `"Hairpin"` (~180°),
  `"Straight"`, and the compound `"Right 4 tightens 2"`. Sharpness is encoded in
  the name. **"2 or sharper" → name in `["1","2","Square","Hairpin"]`** (chosen).
  (`"Right 4 tightens 2"` is excluded by exact-name match — see §2 note.)
- **Centerline** is a `Curve2D` in the XZ plane (`Vector2(x,z)`), returned under
  `"centerline"` (`:258-260`). World position at an arc-distance: `sample_baked(offset)`;
  total length: `get_baked_length()`; nearest arc-distance to a point:
  `get_closest_offset(point)`. Tangent = finite difference of two samples;
  perpendicular = `Vector2(-tan.y, tan.x)`.
- **Road geometry:** the road is **laterally flat** — `bake_track()` flattens the
  road band to the centerline height at each arc position and blends out over the
  transition (`scripts/terrain_manager.gd:307-349`, `smooth_ramp` `:288-297`).
  So a point at the **road edge** (`±track_width/2` perpendicular to the tangent)
  sits at the **centerline's surface height** at that arc position — query it with
  `floor.height_at(centerline_point.x, centerline_point.y)`
  (`terrain_manager.gd:153-155`). Use the **centerline** sample for the height,
  not the raw edge point (raw terrain there may differ). This is exactly why a
  sign can "stand by itself on the edge of the road".
- **Road width / edge:** `track_width` (`game_config.gd:252-267`, default `6.0`,
  `.tres` `7.0`); visible half-width `track_width/2`.
- **Placing objects along the road** (pattern to mirror): `TreeScatter.scatter()`
  anchors per piece via `turn_anchor()` (`scripts/tree_scatter.gd:17-22`,
  `:33-60`); `BillboardField.build()` creates a `StaticBody3D` and adds one
  `BoxShape3D` per instance via
  `PhysicsServer3D.body_add_shape(body.get_rid(), shape.get_rid(), xform)`
  (`scripts/billboard_field.gd:18-61`). **Signs are NOT billboards** (they must
  keep a fixed orientation, not yaw to camera), so they use plain oriented
  meshes, not the billboard MultiMesh.
- **In-code mesh + collision**: `wheel_force_debug.gd:40-52` builds a
  `MeshInstance3D` + `BoxMesh` + material in code; `billboard_field.gd:22-32`
  builds a mesh + `ShaderMaterial`. Reuse these patterns.
- **Material/shader**: world meshes use `shaders/ps1_models.gdshader` (unshaded,
  `filter_nearest`, `albedo_texture` + `albedo_color`). Create via
  `ShaderMaterial.new()` + `set_shader_parameter(...)` (`world.gd:36-40`,
  `billboard_field.gd:27-32`). Signs reuse this shader with their face texture.
- **No `Label3D`/`TextMesh`/`Decal`/`Sprite3D` exist** — consistent with the
  chosen authored-texture approach (no runtime text needed).
- **Tests**: pure generators are unit-tested without a scene
  (`tests/headless/test_track_generator.gd`, `test_tree_scatter.gd`); scene
  objects + collision counts in `test_smoke.gd:156-201`.
- **Feature docs**: `features/track.md` + index `features/README.md`; add
  `features/signs.md`.

---

## 1. Expose each piece's entry pose (small generation change)

Sign placement at the **start of a turn** needs the world position where each
piece begins. Record it when the piece is committed (`track_generator.gd:226-231`):

```gdscript
pieces.append({
    "corner": corners[cand["corner_index"]]["name"],
    "flip": cand["flip"],
    "straight": cand["straight"],
    "cells": added_cells,
    "entry_pos": frame_pos,          # NEW: world pos at the start of this piece
    "entry_heading": frame_heading,  # NEW: unit heading there
})
```

`frame_pos` / `frame_heading` are in scope at that point (set at `:180-181`,
updated at `:232-233` *after* the append). The **corner** itself starts after the
connecting straight, so:

```
corner_entry = entry_pos + entry_heading.normalized() * piece["straight"]
```

Then snap to the baked curve to get a robust arc-distance + on-curve point:
`offset = centerline.get_closest_offset(corner_entry)`. This avoids fragile
world_points index bookkeeping and reuses the same `Curve2D` API the other specs
use. Keep the change additive (extra dict keys) so existing tests/consumers are
unaffected.

## 2. Sign layout — a pure, testable planner

Add `scripts/sign_layout.gd` (`class_name SignLayout extends RefCounted`,
static), mirroring `TrackGenerator`/`TreeScatter` so it's unit-testable without a
scene. Input: the generate() result (`centerline` + `pieces`) + config. Output:
an `Array` of placement dicts:

```gdscript
# one entry per physical sign
{ "kind": "sector"|"turn"|"start"|"finish",
  "texture_key": String,    # which atlas image (see §6), e.g. "sector_2", "arrow_square_left"
  "pos": Vector2,           # centerline point (XZ) at this sign's arc offset
  "tangent": Vector2,       # unit road direction there
  "side": int }             # +1 / -1 : which road edge (perp sign)
```

Placement rules:

**Sectors** (`kind:"sector"`): split the stage into `sign_sector_count` (default
**4**) equal arc-length segments: `L = centerline.get_baked_length()`,
boundaries at `k * L / 4`. A driver **enters the next sector** at `L/4`, `L/2`,
`3L/4` → place "SECTOR 2/3/4" there. Sector 1 is covered by the **start** gate at
offset 0 (so we don't double-sign offset 0). At each boundary emit **two**
entries, one per side (`side:+1` and `side:-1`), as the user requested ("either
side of the road"). `texture_key = "sector_%d" % n`.

**Turns** (`kind:"turn"`): for each piece whose `corner` ∈
`["1","2","Square","Hairpin"]`, compute the corner-entry offset (§1) and emit
**two** entries (both sides — chosen). `texture_key` from corner + `flip`:
| corner | shape | flip=false (right) | flip=true (left) |
|---|---|---|---|
| `1`, `2` | curved arrow | `arrow_curve_right` | `arrow_curve_left` |
| `Square` | right-angle arrow | `arrow_square_right` | `arrow_square_left` |
| `Hairpin` | U-turn arrow | `arrow_uturn_right` | `arrow_uturn_left` |

> Note — `"Right 4 tightens 2"`: excluded by the exact-name set above even though
> it tightens to a 2. If you want it signed, add it to the set and pick an arrow
> (it's a right-hand corner tightening, so `arrow_curve_right`). Left as a
> one-line decision; default **excluded**.

**Start / Finish** (`kind:"start"` at offset 0, `kind:"finish"` at offset `L`):
emit two entries each (both sides), `texture_key` `"start"` / `"finish"`. These
form a gate. (If start and a sector-1 sign would collide, the start gate wins —
hence sector signs begin at sector 2.)

For every entry: `pos = centerline.sample_baked(offset)`,
`tangent = (centerline.sample_baked(min(offset+ε,L)) - pos).normalized()` (fall
back to a backward difference near the end).

## 3. Sign field — build the A-frame meshes + collision

Add `scripts/sign_field.gd` (`class_name SignField extends Node3D`). Given the
layout array + the `TerrainManager`, build one sign per entry. Signs are few
(4 sectors → up to ~6 sector signs depending on count, ~2 per sharp turn, 4
start/finish) — on the order of tens, not thousands — so **individual nodes are
fine**; no MultiMesh/culling needed (the engine frustum-culls `MeshInstance3D`
automatically, and each sign has a unique face texture anyway). This is unlike
the 6,000-instance foliage in `todo/performance-optimisations.md`.

Per sign:
- **World transform.** `edge = pos + side * Vector2(-tangent.y, tangent.x) * (track_width/2 - sign_edge_inset_m)`.
  Ground height `y = floor.height_at(pos.x, pos.y)` (the **centerline** height =
  the flat road surface; see Context). Build a `Transform3D` whose **forward
  (-Z)** runs along the road tangent (`Vector3(tangent.x, 0, tangent.y)`), `UP`
  world up, origin `Vector3(edge.x, y, edge.y)`.
- **Geometry — the wet-floor / A-frame structure.** Two **thin square panels**
  joined at a top ridge and splayed apart at the bottom (inverted V). Build
  procedurally (no Blender model needed since only textures are authored):
  - Two `BoxMesh` panels, each `size = Vector3(sign_panel_size_m.x,
    sign_panel_size_m.y, sign_thickness_m)`, parented to the sign root.
  - Tilt each panel about the ridge by `±sign_splay_deg` and offset so their top
    edges meet at the ridge height; bottoms separate by the splay → a stable
    free-standing footprint.
  - The ridge runs **across** the road (perpendicular to travel) so each panel's
    large face points up-track / down-track and is readable by an approaching
    driver. Apply the face texture to **both** faces (so it reads from both
    directions); arrow-correct-on-approach is a later refinement.
  - Material: `ShaderMaterial` with `shaders/ps1_models.gdshader`,
    `albedo_texture = <atlas image for texture_key>` (load from
    `textures/signs/`), `albedo_color = white`, `blend_road = false`. If the
    image is missing, fall back to a per-kind `albedo_color` so geometry is
    testable before art lands.
- **Collision.** One `StaticBody3D` + `BoxShape3D` per sign sized to the A-frame
  footprint (`Vector3(sign_panel_size_m.x, sign_panel_size_m.y,
  sign_base_depth_m)`), centred half-height above ground. Use the
  `wheel_force_debug.gd:40-52` node pattern (a `StaticBody3D` child with a
  `CollisionShape3D`), or the `PhysicsServer3D.body_add_shape` pattern from
  `billboard_field.gd:47-59` if batching onto one body. Either is fine at this
  count; individual `StaticBody3D` per sign is simplest and most readable.

Wire it in `world.gd._generate_track()` after the track is generated and the
terrain warmed (near `scripts/world.gd:68-69`, alongside the tree/bush fields):

```gdscript
var signs := SignLayout.plan(result["centerline"], result["pieces"], cfg.sign_params())
var sign_field := SignField.new()
add_child(sign_field)
sign_field.build(signs, $Floor as TerrainManager, cfg.sign_render_params())
```

## 4. Orientation / readability detail

The two panels face opposite ways along the road, so an approaching driver always
sees one face. Same texture on both faces is the simplest correct default for
sector/start/finish. For **arrows**, the back face shows a mirrored arrow; if that
ever looks wrong, give each panel its own material and put the correct-direction
arrow on the approach face. Start simple (both faces same texture); note the
refinement.

## 5. Sectors and the stage spec (relationship)

The 4 equal arc-length sectors here are a natural fit for per-sector split times
if `todo/stage-start-and-end.md` grows them later. Keep the sector-boundary
offsets computable from `SignLayout` (e.g. expose a small
`SignLayout.sector_offsets(centerline, count)` helper) so the stage timer can
reuse the exact same boundaries instead of recomputing. Not required now — just
don't bury the math where the timer can't reach it.

## 6. Config knobs (config-first)

Add a new `@export_group("Roadside Signs")` to `scripts/game_config.gd`
(alongside `Track`/`Trees`), defaults documented here; override in
`config/game_config.tres` only if needed:

| Field | Type | Default | Purpose |
|---|---|---|---|
| `sign_sector_count` | int | `4` | Equal arc-length sectors per stage. |
| `sign_panel_size_m` | Vector2 | `Vector2(1.2, 1.2)` | One panel's width × height (thin squares). |
| `sign_thickness_m` | float | `0.05` | Panel thickness. |
| `sign_splay_deg` | float | `20.0` | Half-angle each panel tilts from vertical (A-frame splay). |
| `sign_edge_inset_m` | float | `0.3` | How far inside the road edge the sign base sits (keeps it on the flat road). |
| `sign_base_depth_m` | float | `0.8` | Collision/footprint depth along the road. |
| `sign_textures` | Dictionary | `{}` | Map `texture_key` → `res://textures/signs/*.png`. Empty = colour fallback. |

`sign_params()` / `sign_render_params()` helper methods bundle these for the
layout/field, matching `tree_params()` (`game_config.gd`). No quality-tier
branching — single shipped values, consistent with the inherently-lean design.

## 7. Tests

Add to `tests/headless/` (GUT; `./run_tests.sh` in the background):
- **`test_sign_layout.gd`** (pure, no scene):
  - Sector signs: exactly `sign_sector_count - 1` boundaries signed (sectors
    2..4), **two per boundary** (both sides), labels `sector_2..sector_4`, at the
    expected arc offsets (`k*L/4` within tolerance).
  - Turn signs: a sign pair appears for every piece whose corner ∈
    `{1,2,Square,Hairpin}` and **none** for `Straight`/gentle gradients; correct
    `texture_key` incl. left/right per `flip`.
  - Start/finish: one pair each at offsets `0` and `L`.
  - Determinism: same seed → same layout.
- **`test_smoke.gd` addition**: `SignField.build(...)` creates the expected node
  count, each with a `StaticBody3D` collision child, and signs sit at the road
  surface height (Y ≈ `floor.height_at(centerline pt)` within tolerance).
- Use a fake/short generated track so tests stay fast; assert collision shape
  count like the existing `test_billboard_field_builds_instances_and_collision`.

## Implementation order

1. §1 — add `entry_pos`/`entry_heading` to pieces (tiny, additive, testable).
2. §6 — config group + helpers (so nothing is hardcoded).
3. §2 — `SignLayout.plan(...)` pure planner + its unit tests.
4. §3 — `SignField` geometry + collision; wire into `world.gd`.
5. §4 — orientation/readability pass.
6. §7 — remaining tests; `features/signs.md` (+ index in `features/README.md`),
   and fix `features/track.md` if it needs the new piece keys mentioned.
7. Asset: author the texture atlas (action item) and populate `sign_textures`.

## Files touched (summary)

| File | Change |
|---|---|
| `scripts/track_generator.gd` | Add `entry_pos`/`entry_heading` to each piece dict (`:226-231`). |
| `scripts/sign_layout.gd` | **New.** Pure planner: pieces+centerline+config → sign placements. |
| `scripts/sign_field.gd` | **New.** Builds A-frame panel meshes + per-sign collision, oriented to the road. |
| `scripts/world.gd` | Plan + build the sign field in `_generate_track` (`:68-69`). |
| `scripts/game_config.gd` | New `Roadside Signs` group + `sign_params()`/`sign_render_params()`. |
| `config/game_config.tres` | Overrides only if needed. |
| `textures/signs/` | **New (art).** Authored sign-face atlas (action item). |
| `features/signs.md` (+ `features/README.md`) | Document the signs model. |
| `tests/headless/test_sign_layout.gd`, `test_smoke.gd` | Layout + field/collision tests. |

## Open / deferred

- Authored texture atlas (action item above) — blocks the final in-engine look,
  not the geometry/placement code (colour fallback covers that).
- Whether `"Right 4 tightens 2"` gets a turn arrow (default: no — §2 note).
- Arrow-correct-on-approach face (default: same texture both faces — §4).
