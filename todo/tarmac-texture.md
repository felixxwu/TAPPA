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
- `shaders/ps1_models.gdshader` fragment mixes the gravel texture toward a flat
  `tarmac_color` by `UV2.x`, then `mix(ground, road, COLOR.a)`. The `tarmac_color`
  uniform is the placeholder.
- **This is no longer a one-sampler change — there are four sites.** The shader now
  carries a **two-slot region blend**: `tarmac_color` (slot A) and `tarmac_color_b`
  (slot B), lerped by `region_t` so a region boundary crossfades. And a **second copy
  of the same block lives in `shaders/ps1_terrain_snow.gdshader`** (same
  `tarmac_color` / `tarmac_color_b` / `region_t` structure). On top of that,
  `scripts/overworld.gd` pushes `tarmac_color` and `tarmac_color_b` per region
  (`floor_mat.set_shader_parameter`) and also reads the colour directly for its map
  colouring.

## To do

1. Source / author a tileable tarmac texture (CC0, PS1-grade — low res, nearest
   filtered, mipmapped like `textures/gravel.jpg.import`). Drop it in `textures/`.
2. Add the sampler in **both** shaders and for **both** region slots — a
   `tarmac_texture` / `tarmac_texture_b` pair (mirroring `tarmac_color` /
   `tarmac_color_b`) in `ps1_models.gdshader` AND `ps1_terrain_snow.gdshader` — and
   replace the flat colour in the `region_t` blend with samples of them. Reuse
   `road_uv_scale`, or add a `tarmac_uv_scale` if it needs a different tiling density.
   Keep `tarmac_color*` as a tint/fallback so the region tint still works. **Keep the
   two shaders in step** — they duplicate this block, and a change to one that misses
   the other shows up only in the snow region.
3. Set the texture on the floor material in `main.tscn`, and push it per region from
   `scripts/overworld.gd` alongside `tarmac_color` / `tarmac_color_b` (and from
   `world.gd` like `road_uv_scale` if a separate scale is added). Decide whether a
   region can override the texture as well as the tint, or whether one shared tarmac
   texture is enough — if the latter, only slot A/B *tints* stay per-region.
4. Update `features/rendering.md` (the shader table + fragment description) and
   `features/terrain.md`'s surface section.

## Dependencies

None — the surface-split plumbing (UV2 weight, config, per-wheel grip) already
landed with the gravel/tarmac grip-mix work. This is purely the art swap.
