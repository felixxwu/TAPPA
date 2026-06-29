# Roadside Signs — implementation spec

> Status: **✅ IMPLEMENTED & ART COMPLETE.** Turn-arrow pacenote boards are
> generated, placed and textured along the track as knockable physics props. Start
> and finish are the inflatable arches (not signs) and sectors are no longer signed,
> so turn arrows are the only roadside signs. See the living doc
> [`features/signs.md`](../features/signs.md) (source:
> `scripts/sign_layout.gd` pure planner, `scripts/sign_field.gd` meshes +
> collision, wired in `scripts/world.gd`; art in `tools/bake_sign_arrows.gd` →
> `textures/signs/`; config in `scripts/game_config.gd` + `config/game_config.tres`;
> tests in `tests/headless/test_sign_layout.gd` and `test_smoke.gd`). Only the two
> deferred polish decisions below remain.

## What shipped

- **Per-piece entry pose.** `TrackGenerator` records `entry_pos` / `entry_heading`
  on each committed piece (additive keys), so the planner can resolve a corner's
  entry to a robust on-curve arc offset via `centerline.get_closest_offset(...)`.
- **`SignLayout` pure planner** (`scripts/sign_layout.gd`, static): `plan(centerline,
  pieces)` → an `Array` of `{kind, texture_key, pos, tangent, side}` placement dicts.
  Turn arrows only — a pair (both sides) at the corner entry of every piece whose
  corner ∈ `{1,2,3,4,Square,Hairpin}`, with grade-specific left/right keys per
  `flip`. (No sector/start/finish signs: the arches mark start/finish and the stage
  is too short to carve into signed sectors.) `sector_offsets(centerline, count)` is
  still exposed — now decoupled from signs — as the stage timer's §5 hook.
- **Turn-arrow art** (`tools/bake_sign_arrows.gd`): a PS1-look pacenote face per
  signed turn type — a bold arrow tracing the REAL `CornerLibrary` centerline (so the
  bend = the turn intensity), an orange rule, and the grade below (`1`..`4`, `SQ`,
  `U`). Left + right (mirrored) variants → `textures/signs/arrow_*_<dir>.png`, mapped
  in `sign_textures`. `_arrow_key` emits grade-specific keys (`arrow_1_*` … `arrow_4_*`,
  `arrow_square_*`, `arrow_uturn_*`) so each board shows its own number. Gentle 5s/6s
  are unsigned (too straight), so no board is baked for them.
- **`SignField`** (`scripts/sign_field.gd`): builds one A-frame sign per placement
  — two splayed double-sided **quad** panels (full face texture per side) on the
  `ps1_models` shader, oriented to the road tangent and sat on the flat road surface
  (`floor.height_at(centerline pt)`), each with its own collision. Signs are
  **knockable cosmetic props**: a kart can shove one aside without taking damage.
  Spawned **frozen** (terrain collision is streamed only near the car, so a live
  body on a far part of the track would free-fall into the void); a child `Area3D`
  waker unfreezes a sign when the dynamic car reaches it. Missing texture → colour
  fallback. Still a kind-agnostic builder (could render a sector/start/finish
  board) though `plan` only feeds it turns.
- **Config-first knobs.** A `Roadside Signs` `@export_group` in `game_config.gd`
  (`sign_panel_size_m`, `sign_thickness_m`, `sign_splay_deg`, `sign_edge_inset_m`,
  `sign_base_depth_m`, `sign_mass_kg`, `sign_textures`) bundled via
  `sign_render_params()`. (`sign_sector_count` lives here too but only feeds the
  `sector_offsets` stage-timer hook now.)
- **Tests + docs.** `test_sign_layout.gd` covers turns-only placement, the turn
  count, keys (incl. 5/6 unsigned), arc offsets, seed determinism and `sector_offsets`;
  `test_smoke.gd` asserts the field's node + collision counts and ground height.
  `features/signs.md` documents the model (indexed in `features/README.md`).

## Remaining / deferred

- **`"Right 4 tightens 2"` turn arrow** — excluded by the exact-name corner set
  (`{1,2,3,4,Square,Hairpin}`). Default: stays unsigned. If wanted, add it to the set
  in `SignLayout` and bake/wire a board for it (e.g. reuse the grade-4 arrow).
- **Arrow-correct-on-approach face** — both panel faces currently show the same
  texture (a back-face arrow reads mirrored). Default kept simple; if it ever
  looks wrong, give each panel its own material with the correct-direction arrow
  on the approach face.
