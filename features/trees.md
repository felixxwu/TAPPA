# Trees

**Source:** `scripts/level_trees.gd` (`class_name LevelTrees`, the level's trees: tiles of
MultiMeshes packed from the bake, hitboxes near the car, felling), `shaders/level_tree.gdshader`,
`scripts/foliage.gd` (`Foliage._alpha_card_mesh`, the 6-card star every tree is drawn on, also
used by `tools/bake_level.gd`), `scripts/tree_fall.gd` (`class_name TreeFall`, the felling
maths), `scripts/obstacle_body.gd` (the hitbox body), `scripts/wind_sway.gd`
(`class_name WindSway`) + `shaders/wind_sway.gdshaderinc` (the wind sway). Ground-cover bushes
are `scripts/ground_cover.gd` + `scripts/bush_field.gd` ([level-editor.md](level-editor.md)).

**Tests:** `tests/headless/test_foliage.gd`, `tests/headless/test_level_trees.gd`,
`tests/headless/test_tree_fall.gd`, `tests/headless/test_wind_sway.gd`

How the level bakes, streams and draws its trees is in [level-editor.md](level-editor.md)
("Tree tiles"). This file covers felling, wind sway, the labs the tree art comes from and the
star-card layout.

## Felling — crash a tree over at speed (`TreeFall` + `LevelTrees`)

Crash into a tree carrying real speed and it topples over and loses its hitbox, so
you can drive on through where it stood. Hit one slowly and it stays a solid
obstacle.

- **Threshold (size-aware).** `TreeFall.should_fell_sized(speed_mps, size, cfg)`
  (`scripts/tree_fall.gd`, a pure static module like `ScatterMath`) returns true when
  the km/h-converted approach speed is `>= TreeFall.fell_speed_kmh(size, cfg)`, which
  scales **linearly** with the tree's visual `size`: `cfg.tree_fell_speed_kmh * size`
  (0 disables felling). `LevelTrees.size_factor` is the tree's baked height over
  `level_tree_full_height_m`, clamped to 1, so a small tree topples at a low speed while a
  full-size tree keeps the configured threshold. Keyed to the car's **pre-solve**
  `_approach_speed` / `_approach_dir` (`car.gd`), captured at the top of
  `_physics_process` — a head-on hit's post-solve velocity is ~0, so reading it later
  would never fell (same rationale as the damage speed).
- **Trigger.** `car.gd._integrate_forces`'s object-reaction loop (contact-driven, and
  now run **before** the global deceleration-damage tick): for each obstacle contact
  it reads the struck tree's `LevelTrees.size_factor(shape_idx)` and, if the approach
  speed fells a tree that size, calls
  `knock_down(state.get_contact_collider_shape(i), _approach_dir, cfg.tree_fell_duration_s)`. Ploughing into a line of trees drops each one.
- **Plough-through (size-aware collision).** A felled tree no longer necessarily stops
  the car dead. Because Godot's solver arrests the car head-on *before*
  `_integrate_forces` runs, the loop restores a size-scaled slice of the shed **forward
  momentum**: `keep = TreeFall.plough_keep(size, cfg)` rises from `0` at full size
  (`plough_keep(1.0) == 0` → a big tree hard-stops exactly as before) toward
  `cfg.tree_plough_keep_max` as the tree shrinks. The restore
  (`TreeFall.plough_restore_velocity`) sets `state.linear_velocity` to hand back
  `keep`·(shed horizontal momentum), clamped to the pre-solve approach speed — a
  **central** change (linear velocity only), so the solver's off-center contact
  response is untouched and **clipping a tree with the rear quarter still spins the
  car** (drift tail-swing preserved). The restore only fires when *every* obstacle
  touched this tick was felled; a still-standing wall (a big tree below its threshold,
  or a non-tree obstacle) legitimately stops the car (`solid_wall` guard). Across
  several felled contacts the **largest** felled tree governs (`keep` is the `min`).
  `cfg.tree_plough_keep_max == 0` disables plough-through entirely (every felled tree
  hard-stops).
- **`LevelTrees.knock_down(idx, dir, duration)`** (idempotent). Disables that tree's box
  via `PhysicsServer3D.body_set_shape_disabled` (never `body_remove_shape`, which would shift
  every later shape index), then queues a fall record; `is_fallen(idx)` reports it.
  `_step_falls` rebuilds the tree's pose each frame as `Basis(axis,
  TreeFall.fall_angle(elapsed, duration)) * standing basis` at the trunk base and marks its
  tile for a repack. `topple_axis(dir)` is horizontal and perpendicular to travel;
  `fall_angle` eases from 0 to just past PI/2.
- **Persistence.** Transient: felled trees stand again when the level reloads.

Config knobs `tree_fell_speed_kmh` / `tree_fell_duration_s` are balance values (see
Configuration); tests assert the felling *logic*, never the chosen numbers.

## Wind sway

Standing trees bend in the wind — a per-vertex offset in
`shaders/level_tree.gdshader` (`#include "res://shaders/wind_sway.gdshaderinc"`,
`wind_sway_offset(origin, VERTEX.y, height)`),
computed in the vertex stage so it costs zero CPU per frame: trees are `MultiMesh`
instances with no per-instance CPU object to animate, so the alternative would be
touching every live tree's transform buffer every frame for a purely cosmetic wobble.

The maths lives in `shaders/wind_sway.gdshaderinc::wind_sway_offset` — a deterministic
per-instance phase hashed off the instance's horizontal world origin (so neighbouring
trees don't sway in lockstep with no per-instance uniform needed), two summed sines at
different rates so the motion doesn't read as a metronome, and a `height_frac^2` bend
profile so the base stays planted and only the crown moves.

**Transport is `global uniform`**, exactly like the headlight cone
([rendering.md](rendering.md) → "The fake headlight cone") and for the same reason:
tree materials are built per streamed tile with no common registry, so a per-material
push would need re-registration bookkeeping on every tile load that a global sidesteps.
`scripts/wind_sway.gd` (`class_name WindSway`) is the driver — pure transport, no
logic beyond what `WeatherLibrary` names.

**Wind reads the SAME everywhere except in a storm.** `WindSway.strength()` reads the
live condition's own `"foliage_wind"` entry in `WeatherLibrary` (see
[weather.md](weather.md)) when it names one, else the shared base
`GameConfig.foliage_wind_strength`. Only `storm` and `sandstorm` name a field
(`storm_foliage_wind_strength`, `sand_foliage_wind_strength`), authored well above the
base — a stormy sky, not just a stormy road. This is pure authoring: no
`weather == "storm"` branch exists anywhere in the sway path, the same discipline
`WeatherLibrary`'s header requires of every consumer.

`LevelView` pushes the live condition's sway (`WindSway.push`) when the weather changes and
`WindSway.reset()`s it on leaving the level.

## Tree Lab (procedural tree playground)

`tools/tree_lab.html` is a standalone browser page (open the file directly, three.js from CDN)
for designing procedural trees: recursive tapered branches with alpha-cut leaf cards, sliders
for trunk / branching / growth / leaves, presets, and seeds. It exports a `.glb` mesh or a
transparent side-on PNG. Beside
the real tree it shows a cheap "star" version, rebuilt on every change (`buildImpostor`): N
(slider, default 6) transparent renders taken evenly around the tree, each on a double-sided card (mirrored on the back) facing the
direction it was shot from, all crossing at the trunk. All cards always draw. The game's tree textures were generated with it. `?preset=<name>` opens a preset and `&render=1` hides the star version and sway, for headless screenshots; the Welsh-forest presets (Sitka spruce, young spruce, birch, rowan, alder, roadside scrub) were tuned against a Hafren Forest roadside photo. The Snow section adds snowy leaf cards (`paintSnow`, the same pass the shipped snow atlases use) and low-poly snow clumps sitting on top of every twig (`snowGeometry`); the snow presets (snow-laden / young / dusted spruce, snow-bowed birch) were tuned against a photo of a snowy Nordic forest road. Their atlases are `tools/levels/trees/snow_laden_spruce.png`, `snowy_young_spruce.png`, `dusted_spruce.png` and `snow_bowed_birch.png`, registered (height, `low`) in the lab's `KINDS`, `LevelBake.TREE_HEIGHT` and `tools/tree_low_reach.py`. Their atlases in `tools/levels/trees/` are re-rendered one preset at a time: `--dump-dom` the lab headless with `?preset=<name>&atlas=1` and decode the data URL in `<pre id="atlasOut">` (default seed 1, 256 px tall).

## Ground Cover Lab

`tools/groundcover_lab.html` (open the file directly, like the tree lab; the tuft geometry, `PRESETS` and `tuftMaterial` live in `tools/groundcover_tufts.js`, loaded by it and by the level editor lab) designs grass/heather/rush tufts as
opaque, untextured, vertex-coloured triangles: each blade is a strip of quads up a bending centre line closed
by a tip triangle (`buildTuft`, 2*segments-1 triangles per blade). It previews them as one instanced field
around a car-sized box, with wind sway and a shrink-to-nothing distance fade done in the vertex shader
(`tuftMaterial`), an option to point every normal up so tufts light exactly like flat ground, and stats for
triangles per tuft and triangles in range. "Download tuft .glb" exports one tuft with vertex colours (a Godot
material needs `vertex_color_use_as_albedo` to show them). Shape "bush" builds a mound instead
(`addBush`): one lumpy low-poly dome (8 x 4, 64 triangles) shaded base-to-tip by height, with leaf clumps painted on by
the fragment shader (blocky nearest-neighbour 3D noise in the bush's own space, one clump per `leafSize`; game copy in `ground_cover.gd` `make_material`). "Flowers per tuft"
perches small flat triangles on blade tips (`addFlowers`). The Hafren presets were matched to Street View photos
of the Hafren Forest roadside, and `?scene=hafren` (or the checkbox) lays all of them out in bands off a
single-track road (`MIX`). Nothing in the game uses these tufts yet; the level editor lab draws painted ground cover with them ([level-editor.md](level-editor.md)).

## Level Editor Lab

See [level-editor.md](level-editor.md). Its Welsh tree atlases in `tools/levels/trees/` come from this
lab's "Download star atlas".

## Star trees (6-card atlas)

Standing trees are a static star, not a camera-facing billboard. Every tree texture
(`tree.png`, `tree-greece/taiga/snow/snow-laden.webp`) is a horizontal ATLAS of 6 equal frames; frame
i is the tree seen from direction (sin(i*60), 0, cos(i*60)), trunk centred, base at the bottom.
`Foliage._alpha_card_mesh` builds 6 vertical cards through the trunk at i*60 degrees (card i maps to
frame i, UV.x = (i+u)/6, per-vertex normals set); all draw at once and nothing faces the camera.
`level_tree.gdshader` places them with the baked instance transform (which carries each tree's
yaw); felling composes the topple tilt on top of it. The old
`tools/gen_*` outputs were replaced by tree_lab atlases. The settings (params + seed + snow share) for every
shipped tree live in `GAME_TREES` in `tools/tree_lab.html`; `tools/export_tree_atlases.sh [height]`
re-renders all five in headless Chrome and overwrites `textures/` (default 512 px tall frames, taiga
1.5x).
