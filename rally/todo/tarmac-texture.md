# Tarmac surface texture

Tarmac track sections currently render as a **flat solid grey** fill
(`GameConfig.tarmac_color`, default `Color(0.32, 0.32, 0.34)`), set as the
`tarmac_color` uniform on the floor material. It works and reads as "not gravel",
but it's a placeholder — the gravel road has a real photographic texture
(`textures/gravel.jpg`) and tarmac should too.

## What exists now (surface system this builds on)

- The track is split gravel/tarmac with a single feathered switch along its
  length — see `scripts/track_surface.gd` and `features/track.md` /
  `features/terrain.md`.
- `TerrainManager.bake_track` fills `track_surface` (cell → tarmac weight in
  `[0,1]`); `surface_uv2` averages it per vertex into the mesh **UV2.x**.
- `shaders/ps1_models.gdshader` fragment:
  `road = mix(gravel_texture, tarmac_color.rgb, UV2.x)`, then
  `mix(ground, road, COLOR.a)`. The `tarmac_color` uniform is the placeholder.

## To do

1. Source / author a tileable tarmac texture (CC0, PS1-grade — low res, nearest
   filtered, mipmapped like `textures/gravel.jpg.import`). Drop it in `textures/`.
2. Add a `tarmac_texture` sampler uniform to `ps1_models.gdshader` (alongside
   `road_texture`) and replace `tarmac_color.rgb` in the `road` mix with a sample
   of it (reuse `road_uv_scale`, or add a `tarmac_uv_scale` if it needs a
   different tiling density). Keep `tarmac_color` as a tint/fallback or remove it.
3. Set the texture on the floor material in `main.tscn` and (if a separate scale
   is added) push the scale from `world.gd` like `road_uv_scale`.
4. Update `features/rendering.md` (the shader table + fragment description) and
   `features/terrain.md`'s surface section.

## Dependencies

None — the surface-split plumbing (UV2 weight, config, per-wheel grip) already
landed with the gravel/tarmac grip-mix work. This is purely the art swap.
