# World session, title screen and world pages

**Source:** `scripts/world_session.gd` (the `WorldSession` autoload), `scripts/title_boot.gd`
(`title.tscn`, the game's main scene), `scripts/title_screen.gd` (`TitleScreen`, the menu over the world), `scripts/free_roam/world_pages.gd`
(`WorldPages`: the map and stats pages), and the session glue in `scripts/free_roam/free_roam.gd`.

**Tests:** `tests/headless/test_world_session.gd`, `tests/headless/test_title_screen.gd`, `tests/headless/test_free_roam_shell.gd`

The free-roam pivot's persistence (decisions 2, 19–22 and 26 in
`todo/2026-10-19-free-roam-pivot.md`): **one persistent world per save** that never resets.

## The world block (`Save.KEY_WORLD`)

`WorldSession` owns the block's shape and is its only writer. Every write goes through `Save.save()`
(debounced), so the world is saved continuously.

| Key | What |
|---|---|
| `seed` | the island's world seed (`FreeRoamSettings.world_seed`) |
| `car` | the active owned car's instance id (`Save.KEY_CARS`) |
| `pose` | `[x, y, z, yaw]`, written every `SAVE_EVERY_S` (5 s) and when leaving the scene |
| `car_state` | `{hp, cooling_broken, engine_temp, toe}`, so a reload resumes the damage too |
| `lit` / `last_site` | lit rest stops (site ids; spawn 0 always) and the respawn point |
| `driven` | map cells (`DRIVEN_CELL_M` = 40 m) the car has driven through, for the map |
| `max_ring` | the furthest biome ring reached, a high-water mark (`reach_ring` returns true on a new one, which cues the region-name banner) |
| `drive_time` | seconds driven: the weather timeline (`BiomeDirector`) runs on it |
| `seen` | site ids (rest stops, loot slots, dead ends) the car has come within `GameConfig.minimap_seen_radius_m` of (`see`, `seen_sites`, `is_seen`; spawn 0 from the start). The minimap and the map show only these ([minimap.md](minimap.md)). A save without the key reads as `[0]` |
| `money` | coins picked up and not yet spent (`money` / `set_money`); dropped when the car gives up |
| `dropped` | the money left at the last wreck, `{pos: [x, y, z], money: n}`, or `{}` (`dropped` / `set_dropped`) |
| `collected`, `revealed` | coin spots taken, rings whose stock is on sale ([loot.md](loot.md)). Parts live on each owned car (`parts`, each switched on or off), not here |

- **New world** (`new_world`): the fixed island seed (`FreeRoamSettings.world_seed`) and a starter car. It replaces the old world **and the
  old owned cars**, because a world is the whole save.
- **JSON returns numbers as floats**, so readers normalise (`lit_sites` and `seen_sites` return ints).
- **Schema:** `Save.SCHEMA_VERSION` is 8. Every v7 (roguelike) profile is refused, not migrated,
  and the player starts fresh (decision 26).
- **Headless runs** can't write the real profile (Save's test sandbox), so a headless
  `--auto-drive` boot does not persist.

## Free roam and the session (`free_roam.gd`)

- `_enter_tree` sets the island seed from the session before the streamer builds its network.
- `_ready` makes a world if there is none (a dev boot straight into the scene), fields the
  session's active car through `apply_owned` (so tuning persists through `Save.set_tuning`),
  restores its damage, seeds `RestStops` from `lit` / `last_site`, and puts the car at its saved
  pose, re-seated on the built ground.
- While driving: driven cells, the ring reached and the sites seen (`MiniMap.mark_seen_near`) every 0.25 s; pose, condition, drive time
  and the distance odometer (`LifetimeStats.DISTANCE_DRIVEN_M`) every 5 s, and on Quit or scene
  exit (`tree_exiting`, window close request). The children leave the tree before the scene root's
  `tree_exiting` fires, so `save_world` can't read the car then: it uses the pose cached on every
  physics tick (damage and drive time stay readable). A travel from the rest-stop page's Map moves the car
  first and the page closes after, so the reload's save holds the destination. `RestStops.lit` / `respawn_point_changed`
  write straight through; a respawn bumps `TIMES_GAVE_UP`.

## Title screen (`TitleScreen`, decision 20)

The game boots straight into the world with the title menu over it. The main scene
(`project.godot → run/main_scene = res://title.tscn`) is just `title_boot.gd`: it sets
`WorldSession.title_pending` and loads free roam, whose `_ready` then calls `show_title()` — a
`TitleScreen` on a `CanvasLayer` (layer 10) over the paused world, with a light dim behind it. Behind the menu a `TitleOrbitCamera` circles
the car (`_start_title_orbit`: `GameConfig.start_orbit_radius` / `_height` / `_speed`, kept above the
ground, its tween running while paused); closing hands back to the chosen camera
(`CameraManager.activate_current`).
A first-time player (no world) gets one built at boot with the first starter car and `FreeRoamSettings.world_seed`,
marked `WorldSession.fresh` (in memory only), so it's already there behind the menu.
Card lists (`CardUI.card_page` / `card_list`, [card-carousel.md](card-carousel.md)) with `MenuNav`:
- **MAIN:** Continue (only with a world that isn't `fresh`) just closes the menu (`close`) and
  unpauses; New World; Settings.
- **STARTER:** New World first asks for a starter car. The choices are the cars in
  `CarLibrary` with `"ring": 0` (`starter_choices` → `LootRules.starter_cars`).
  Picking one makes the world (seed `FreeRoamSettings.world_seed`, so it matches tools/road_network_lab.html) and reloads free roam (`enter_world`; the host
  disconnects its exit save first, so the old car's pose isn't written into the new world). Over an
  existing world, a `ConfirmPopup` asks first. On a `fresh` world there's no confirm: picking the car
  already fielded just closes the menu, and another car keeps the same seed and reloads to field it.
- **SETTINGS:** the shared `SettingsMenu`, on a plain widened `MenuPage` (a form, not a list).

Free roam's pause menu quits to the title (`PauseMenu.quit_scene`), saving first — which reloads
the world with the menu over it. A rest-stop reload or `--auto-drive` boot shows no menu. The old
`HubShell` is unreachable from the game.

## World pages (`WorldPages`, decisions 21–22)

A `CanvasLayer` (layer 7, always processing) over the frozen game:
- **Map** (pause menu → Map, rest-stop page → Map, or the minimap: tap it, or **M** / gamepad
  Back — `toggle_map`, which also closes it): the coast, the ring borders crossed (drawn
  as average circles; the real border is noisy), the roads driven (segments whose midpoint
  cell is driven) over, in grey, the undriven road within `GameConfig.minimap_nearby_road_m` of
  a driven cell (`WorldPages.map_roads`), the rest stops come across (orange lit, grey not; `MiniMap.site_markers`, shared with the
  minimap) and the car. Opened
  from the minimap it pauses the game itself and closing it goes straight back to driving
  (`free_roam.gd → open_full_map`). The page body is transparent (`"alpha": 0.0`): only the
  drawn map is opaque, over the dim. It **frames what has been explored** (`explored_view` →
  `fit_view`: the driven roads, sites come across and the car, plus a margin, at least
  `GameConfig.map_min_view_m` across, never more than the island), so the start isn't a speck.
  **Wherever it's opened it is the quick-travel picker**: `<` / `>` (or a tap on a lit rest stop,
  `tap_map_at`) pick a lit stop — every lit stop when opened on the road, the others when opened at
  one — and Travel goes to the ringed one (`RestStops.travel_to`, which also repairs the car).
  After a travel the host goes straight back to driving: the minimap's map unpauses, and the pause
  menu's Map resumes instead of returning to the menu (`travelled`).
  Travelling while not at a checkpoint (map opened on the road, `travel_drops_money`) with money
  in hand first asks to confirm, then leaves the money where the car was (`LootDirector.drop_money`);
  checkpoint to checkpoint keeps it.
  The map is drawn as large as the frame allows (a plain `MenuPage` — a picture, not a list).
- **Stats:** a read-only card each for distance driven, rest stops lit, times the car gave up,
  and rings reached.

The pause menu hosts them through its generic extra cards (`PauseMenu.extra_rows`,
`extra_requested`, `return_from_extra`).
