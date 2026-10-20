# World session, title screen and world pages

**Source:** `scripts/world_session.gd` (the `WorldSession` autoload), `scripts/title_screen.gd`
(`TitleScreen`, `title.tscn`, the game's main scene), `scripts/free_roam/world_pages.gd`
(`WorldPages`: the map and stats pages), and the session glue in `scripts/free_roam/free_roam.gd`.

**Tests:** `tests/headless/test_world_session.gd`, `tests/headless/test_title_screen.gd`

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
| `max_ring` | the furthest biome ring reached, a high-water mark |
| `drive_time` | seconds driven: the weather timeline (`BiomeDirector`) runs on it |
| `carried`, `stash`, `dropped`, `collected`, `revealed` | loot (stage 7) |

- **New world** (`new_world`): a fresh seed and a starter car. It replaces the old world **and the
  old owned cars**, because a world is the whole save.
- **JSON returns numbers as floats**, so readers normalise (`lit_sites` returns ints).
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
- While driving: driven cells and the ring reached every 0.25 s; pose, condition, drive time
  and the distance odometer (`LifetimeStats.DISTANCE_DRIVEN_M`) every 5 s, and on Quit or scene
  exit (`tree_exiting`, while the car is still readable). `RestStops.lit` / `respawn_point_changed`
  write straight through; a respawn bumps `TIMES_GAVE_UP`.

## Title screen (`TitleScreen`, decision 20)

The main scene (`project.godot → run/main_scene = res://title.tscn`). Flat `MenuPage`s with
`MenuNav`:
- **MAIN:** Continue (only with a world), New World, Settings.
- **STARTER:** New World first asks for a starter car. The choices are the `STARTER_COUNT`
  cheapest cars by `cost` (`starter_choices`), so the rule works whatever the roster becomes.
  Picking one makes the world (a random seed) and drives in. Over an existing world, a
  `ConfirmPopup` asks first.
- **SETTINGS:** the shared `SettingsMenu`.

Free roam's pause menu quits to the title (`PauseMenu.quit_scene`), saving first. The old
`HubShell` is unreachable from the game.

## World pages (`WorldPages`, decisions 21–22)

A `CanvasLayer` (layer 7, always processing) over the frozen game:
- **Map** (pause menu → Map, or rest-stop page → Map): the coast, the ring borders crossed (drawn
  as average circles; the real border is noisy), the roads driven (segments whose midpoint
  cell is driven), lit rest stops and the car. **From a rest stop it is the travel picker**:
  `<` / `>` step through the other lit rest stops, and Travel goes to the ringed one.
- **Stats:** distance driven, rest stops lit, times the car gave up, and rings reached.

The pause menu hosts them through its generic extra rows (`PauseMenu.extra_rows`,
`extra_requested`, `return_from_extra`).
