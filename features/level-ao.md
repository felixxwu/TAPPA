# Level ambient occlusion

Cheap fake AO for the level view only (the renderer is unshaded, so it is all baked or faked). Strengths and reaches are `GameConfig.level_ao_*`.

**Source:** `scripts/level_ao.gd` (`LevelAO`), `scripts/level_view.gd` (`load_level`), `shaders/level_ground.gdshader` (`ao_map`), `shaders/level_tree.gdshader`, `shaders/log_pile.gdshader`, `scripts/ground_cover.gd` (`make_material`, `bush_ids`, `bush_shade`), `scripts/level_streamer.gd` (`_pack_vertex`), `scripts/level_buildings.gd` (`_building`, `boxes`)

**Tests:** `tests/headless/test_level_ao.gd`

## Layer 1: ground

- `LevelAO` is an L8 map on the road frame's texel grid (`LevelBake.FRAME_CELL`, `frame_n`). `load_level` builds it every load (not in the bake, so editing buildings or log piles never rebakes) and `apply_to` hands it to the ground shader, which multiplies the surface colour by it before the headlight term.
- Trees live in a second RG8 map (`tree_ao_map`, nearest-filtered): one tree per texel (the wider wins), R = its offset from the texel centre in 4 bits per axis, G = patch radius (fraction of a texel, from tree width x `level_ao_tree_radius_scale`, capped at one texel). The ground shader reads the 3x3 texels round each pixel, rebuilds each tree's exact xz and darkens with a radial falloff, darkest at the trunk (`stamp_trees`, `tree_at`). Buildings and log piles: `stamp_box` (a rotated box that fades out over a reach). Overlaps keep the darker value.
- Bushes are too dense to stamp: `LevelStreamer._pack_vertex` multiplies the vertex colour by `GroundCover.bush_shade` under bush cover.

## Layer 2: objects

- Trees (`level_tree.gdshader`) and bushes (`GroundCover.make_material`'s inline shader) darken toward their base by model height; log piles do the same in `log_pile.gdshader` (uniforms set in `LogPile.build`).
- Buildings have the darkening baked into their vertex colours in `LevelBuildings._building`, so it costs nothing at runtime.
