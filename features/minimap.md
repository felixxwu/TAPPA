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
- **Tilted like the ground.** The flat map is shown as a plane tilted away from the viewer:
  the far edge (top) is narrower and compressed, the near edge (bottom) full size, with a soft
  fade at every edge (far, near and sides) — no backdrop, rim or shadow; the roads float over
  the world (the shader's `bg_color`, `rim_color` and `shadow_color` are transparent). `minimap_tilt` is how
  much wider the ground at the far edge is than at the near edge.
- **Roads you've driven** (`WorldSession.has_driven` on the segment's midpoint cell, the same
  rule as the full map), in ink with a dark casing, `minimap_road_width` wide.
- **A little road ahead** (off: `minimap_nearby_road_m` is 0, so only driven road shows): undriven road within `minimap_nearby_road_m` of a point a little
  ahead of the car, drawn faint, so the road you're on and the next junction show. Its look is
  `minimap_undriven_road_alpha` / `_width` / `_outline_alpha` (a thin dark outline so it reads
  on bright ground); the chevron's size is `minimap_car_arrow_px`.
- **Rest stops you've come across** (`WorldSession.seen_sites`) as dots (orange lit, grey unlit:
  `TerrainStreamer.BEACON_LIT` / `BEACON_UNLIT`), and **cars waiting to be found** as a gold car key
  (`Marker.CAR_KEY`, `MiniMap.draw_key`) once their side road has been seen (`mark_seen_near` also
  counts coming near where the side road starts, `RoadSites.branch`), until the car is owned. Coins aren't shown on either map; the full map also marks dropped money (`WorldPages.dropped_xz`). Icons are drawn
  upright on top of the tilted ground, smaller with distance. `MiniMap.site_markers` decides this for both the minimap and the
  full map.
- **A line under the frame** (`MiniMap.update_prompt_label`, per frame): the action prompt
  ("ENTER / A: OPEN REST STOP", or "TAP: …" on touch, while `RestStops.prompt_site` >= 0; "ENTER / A: DRIVE IT" on the pad of a car just found, `ParkedCars.offer`), else the latest money message ("+$n", "Drift +$n", …: `LootDirector.said` →
  `MiniMap.toast`, for `FreeRoamSettings.toast_s`), else the standing `MiniMap.hint` (the cold open's
  throttle button), hidden otherwise. One box, so the two never show at once, and the
  prompt always wins. It hugs its text (black, small padding) centred under the frame. Tapping the prompt opens the rest stop (`_on_prompt_input` → `RestStops.open_here`). The money
  counter is top-left, not here (`LootDirector.money_label`, [loot.md](loot.md)).

## Seen sites

Every 0.25 s free roam calls `MiniMap.mark_seen_near(sites, car xz, minimap_seen_radius_m)`,
which adds any site within the radius to the world's `seen` list (`WorldSession.see`;
[world-session.md](world-session.md)). Lit rest stops always show, seen or not.

## Opening the whole map

Tap or click anywhere on the minimap's box (not only the tilted map inside it), or press
**M** / gamepad **Back** (`toggle_map`). It emits `open_requested`; `free_roam.gd →
open_full_map` pauses the game, disarms the pause menu and shows `WorldPages.show_map`.
Closing the map (Back, Esc / B, or M again) unpauses and goes straight back to driving.

The full map's ground is a top-down terrain picture copied from `tools/road_network_lab.html`'s
2D view (`drawTerrain`): `MapTerrain` (`scripts/free_roam/map_terrain.gd`) samples heights
over the map's view and `paint`s them: each biome ring in its `map_ring_colors` entry, shaded by
slope, darkened along contour lines every `map_contour_m`, higher ground lighter (over
`map_lift_range_m` above the water), lakes flat `map_lake_color`, the sea left clear over
`map_sea_color`.

It is built from 32×32-cell tiles cached for the session (`WorldPages.map_terrain`). A tile's cell
size is the power of two (in metres) that puts about `map_terrain_cells` cells across the view, so
moving the car or growing the explored area a little reuses the tiles already drawn. Each tile is
sampled with a one-cell border so slopes and contour lines run across tile edges. While driving,
`WorldPages._process` asks for the tiles of the current `explored_view` every `map_terrain_refresh_s` (if a new cell has been driven since) and samples them
at `map_terrain_driving_budget_us` per frame, stopping mid-tile when the budget runs out (`MapTerrain.step`), so the map usually opens ready; any tiles still
missing are drawn while the map is open at `map_terrain_budget_us` per frame, over a plain coast. `MapCanvas` works out its view and road lists once per opening, since the game is frozen under it. The
pause menu's Map row still opens the same page and returns to the pause menu.

## Hiding and input

`MiniMap.is_live()`: hidden and deaf whenever the tree is paused (the pause menu, the rest-stop
page and the world pages all pause), or when the HUD is off (`hud_enabled`).
**`GameConfig.minimap_enabled` is off by default (2026-10-25, the user's call: the full map is
enough).** Off, the frame isn't drawn and taps pass through, but the prompt line under it still
shows and M / gamepad Back still open the full map. It runs `PROCESS_MODE_ALWAYS` so it can hide itself while paused.

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
