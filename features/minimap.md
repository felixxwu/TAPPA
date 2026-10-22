# Minimap (free roam)

**Source:** `scripts/free_roam/mini_map.gd` (`MiniMap`), `shaders/mini_map.gdshader`, wired in
`free_roam.tscn` (`MiniMapLayer/MiniMap`) and `scripts/free_roam/free_roam.gd`
(`open_full_map`, the seen-sites tick). Tunables: `GameConfig` → *Minimap* group
(`minimap_*`). Capture tool: `tools/minimap_capture.tscn` (drives with the `AutoDriver`, saves
PNGs of the minimap and the full map, prints the costs).

**Tests:** `tests/headless/test_mini_map.gd`

A navigation-software style map at the top centre of the screen while driving.

## What it shows

- **Heading-up.** The map turns so the car's facing is up. The car is a fixed green chevron
  low in the frame (`minimap_car_depth`), so most of the view is road ahead.
- **Way out.** A small orange arrow circles the chevron, pointing straight away from spawn
  (the world origin) toward the outer rings (`outward_dir`); hidden right at spawn.
- **Tilted like the ground.** The flat map is shown as a plane tilted away from the viewer:
  the far edge (top) is narrower and compressed, the near edge (bottom) full size, with a soft
  fade at every edge (far, near and sides) — no backdrop, rim or shadow; the roads float over
  the world (the shader's `bg_color`, `rim_color` and `shadow_color` are transparent). `minimap_tilt` is how
  much wider the ground at the far edge is than at the near edge.
- **Roads you've driven** (`WorldSession.has_driven` on the segment's midpoint cell, the same
  rule as the full map), in ink with a dark casing.
- **A little road ahead:** undriven road within `minimap_nearby_road_m` of a point a little
  ahead of the car, drawn faint, so the road you're on and the next junction show.
- **Rest stops you've come across** (`WorldSession.seen_sites`) as dots (orange lit, grey unlit:
  `TerrainStreamer.BEACON_LIT` / `BEACON_UNLIT`). Loot isn't shown on either map. Icons are drawn
  upright on top of the tilted ground, smaller with distance. `MiniMap.site_markers` decides this for both the minimap and the
  full map.
- **A line under the frame** (`MiniMap.update_carried_label`, per frame): the action prompt
  ("ENTER / A: OPEN REST STOP" while `RestStops.prompt_site` >= 0), then "CARRYING N ITEMS" while
  `WorldSession.list("carried")` isn't empty. Hidden when both are empty.

## Seen sites

Every 0.25 s free roam calls `MiniMap.mark_seen_near(sites, car xz, minimap_seen_radius_m)`,
which adds any site within the radius to the world's `seen` list (`WorldSession.see`;
[world-session.md](world-session.md)). Lit rest stops always show, seen or not.

## Opening the whole map

Tap or click anywhere on the minimap's box (not only the tilted map inside it), or press
**M** / gamepad **Back** (`toggle_map`). It emits `open_requested`; `free_roam.gd →
open_full_map` pauses the game, disarms the pause menu and shows `WorldPages.show_map`.
Closing the map (Back, Esc / B, or M again) unpauses and goes straight back to driving. The
pause menu's Map row still opens the same page and returns to the pause menu.

## Hiding and input

`MiniMap.is_live()`: hidden and deaf whenever the tree is paused (the pause menu, the rest-stop
page and the world pages all pause), when `minimap_enabled` is off, or when the HUD is off
(`hud_enabled`). It runs `PROCESS_MODE_ALWAYS` so it can hide itself while paused.

Layout (`_layout`): `minimap_height_frac` of the screen height, `minimap_aspect` wide, narrowed
on a thin screen to keep 140 px clear each side (the HUD speed/gear labels top-left, the pause
button top-right). Keep `minimap_top_px` + height under a fifth of the screen: the touch
controls read raw touches (`mobile_controls.gd → _input`) and the simple scheme's steering
halves start at 20% of the height. Only the minimap control itself stops the mouse; its
children ignore it.

## Cost

- The flat map is a `Node2D` (`RoadLayer`) in a `minimap_texture_px` square `SubViewport`,
  drawn **world-aligned** around a draw centre with `draw_multiline` batches. Its command list
  is rebuilt only when the car has moved `minimap_redraw_move_m` or entered a new 40 m cell, at
  most `minimap_redraw_hz` times a second. Every frame only the node's rotation and position
  change, so turning and driving are smooth for free.
- Road lookup: segments are bucketed once at boot by the 40 m driven cell of their midpoint
  (`index_roads`), so a redraw makes one `has_driven` lookup per cell.
- Measured on the default island (container CPU, 2026-10-20): a road rebuild's gathering
  about 150–300 µs, about 2 rebuilds a second at auto-driver speed (50 km/h); a frame without a
  rebuild about 2 µs; the site-marker refresh (1 Hz, or
  when a site is newly seen) about 45 µs.
- The tilt is a canvas_item shader (`ground` in the shader, `screen_of` / `ground_of` its
  GDScript twins used for the icons only: a tap anywhere on the minimap box opens the map, so there
  is no per-point hit test).
