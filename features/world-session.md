# World session and boot

**Source:** `scripts/world_session.gd` (the `WorldSession` autoload), `scripts/title_boot.gd`
(`title.tscn`, the game's main scene).

**Tests:** `tests/headless/test_world_session.gd`

## The world block (`Save.KEY_WORLD`)

`WorldSession` owns the block's shape and is its only writer. Since the island was deleted
(the November 2026 Hafren-only cleanup) it holds only:

| Key | What |
|---|---|
| `seed` | the world's seed; a profile has a world once this is set (`has_world`) |
| `car` | the starter owned car's instance id (`Save.KEY_CARS`, `active_car`) |

Keys an older save left there (`pose`, `lit`, `money`, `driven`, …) are ignored. The Hafren level
keeps its own progress in saved settings (`LevelView`: money, car, parts, pose; see
[level-editor.md](level-editor.md)).

- **New world** (`new_world(seed, model_id)`): replaces the world **and the old owned cars**, because
  a world is the whole save, and grants the starter car. `title_boot.gd` uses a random seed
  and the level's authored start car (`Config.authored_value("level_car_id", …)`).
- **The world generation.** `WorldSession.generation` moves on (`invalidate()`, which also emits
  `world_changed`) whenever the profile's world is replaced: `new_world`, or a whole-profile swap
  (`Save.replaced`: a cloud download, a wipe). `CarPreviewCache` drops its owned-car previews on it.
- **Schema:** `Save.SCHEMA_VERSION` is 8. Every v7 (roguelike) profile is refused, not migrated,
  and the player starts fresh.

## Boot

The main scene (`project.godot → run/main_scene = res://title.tscn`, `Scenes.TITLE`) is just
`title_boot.gd`: a first-time player (no world) gets one, then it enters `Scenes.WORLD`, the
Hafren level (`level_view.tscn`), which drives straight in. There is no title menu. The settings
page's Wipe goes back through `Scenes.TITLE`, so a wiped profile boots as a new player's would.
