# Roadside Signs — implementation spec

> Status: **✅ IMPLEMENTED (geometry / placement / collision).** Sector boards,
> turn arrows and start/finish gates are generated and placed along the track,
> with knockable physics props. See the living doc
> [`features/signs.md`](../features/signs.md) (source:
> `scripts/sign_layout.gd` pure planner, `scripts/sign_field.gd` meshes +
> collision, wired in `scripts/world.gd`; config in `scripts/game_config.gd` +
> `config/game_config.tres`; tests in `tests/headless/test_sign_layout.gd` and
> `test_smoke.gd`). The implementation brief that drove it has been struck; only
> the authored texture atlas and the two deferred decisions below remain.

## What shipped

- **Per-piece entry pose.** `TrackGenerator` records `entry_pos` / `entry_heading`
  on each committed piece (additive keys), so the planner can resolve a corner's
  entry to a robust on-curve arc offset via `centerline.get_closest_offset(...)`.
- **`SignLayout` pure planner** (`scripts/sign_layout.gd`, static): `plan(centerline,
  pieces, params)` → an `Array` of `{kind, texture_key, pos, tangent, side}`
  placement dicts. Sector boards at the `k·L/4` boundaries (sectors 2..N, both
  sides), turn arrows for pieces whose corner ∈ `{1,2,Square,Hairpin}` with
  left/right keys per `flip`, and start/finish gate pairs at offsets `0` and `L`.
  `sector_offsets(centerline, count)` is exposed so the stage timer can later
  reuse the exact same sector boundaries (the §5 cross-spec hook).
- **`SignField`** (`scripts/sign_field.gd`): builds one A-frame sign per placement
  — two splayed `BoxMesh` panels on the `ps1_models` shader, oriented to the road
  tangent and sat on the flat road surface (`floor.height_at(centerline pt)`),
  each with its own collision. Signs are **knockable cosmetic props** (the
  follow-up pass): a kart can shove one aside without taking damage. Missing
  texture → per-kind colour fallback, so the geometry is correct before art lands.
- **Config-first knobs.** A `Roadside Signs` `@export_group` in `game_config.gd`
  (`sign_sector_count`, `sign_panel_size_m`, `sign_thickness_m`, `sign_splay_deg`,
  `sign_edge_inset_m`, `sign_base_depth_m`, `sign_textures`) bundled via
  `sign_params()` / `sign_render_params()`.
- **Tests + docs.** `test_sign_layout.gd` covers sector/turn/gate counts, keys,
  arc offsets and seed determinism; `test_smoke.gd` asserts the field's node +
  collision counts and ground height. `features/signs.md` documents the model
  (indexed in `features/README.md`).

## Remaining / deferred

- ⚠️ **Authored sign-face texture atlas** (PNGs, PS1 look, `filter_nearest`).
  Owner: Felix. Code runs on the colour fallback until these land; once authored,
  drop them in `textures/signs/` and map `texture_key → res://textures/signs/*.png`
  in `sign_textures` (`config/game_config.tres`). Required set:
  - **Sector**: "SECTOR 2", "SECTOR 3", "SECTOR 4" (sector 1 is implied by the
    start gate). Add "SECTOR 1" too if you'd rather sign it as well.
  - **Turn arrows** with **left and right variants** (mirror), keyed off
    `piece["flip"]`: curved arrow (gradients `1` and `2`), right-angle arrow
    (`Square`), U-turn arrow (`Hairpin`). → 3 shapes × 2 directions = 6 images.
  - **Start** and **Finish** banners.
- **`"Right 4 tightens 2"` turn arrow** — excluded by the exact-name corner set
  (`{1,2,Square,Hairpin}`). Default: stays unsigned. If wanted, add it to the set
  in `SignLayout` and give it `arrow_curve_right`.
- **Arrow-correct-on-approach face** — both panel faces currently show the same
  texture (a back-face arrow reads mirrored). Default kept simple; if it ever
  looks wrong, give each panel its own material with the correct-direction arrow
  on the approach face.
