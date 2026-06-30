# Save / Persistence

The **`Save` autoload** (`scripts/save_manager.gd`, registered in
`project.godot [autoload]` alongside `Config`) is the single source of truth for
everything the meta-game mutates: owned cars (each with its own HP, installed
upgrades and tuning), the uninstalled-item inventory, and rally completion. It
persists as JSON at `user://profile.json` so progress survives a restart on both
desktop and the web build.

It is deliberately **separate from `Config`**: `Config` holds the authored
car/world tuning baseline (a duplicate of `game_config.tres`); the profile is
per-player mutable progress. `Save` stores tuning *numbers* but never touches
`GameConfig` — the car-fielding code reads stored tuning and writes the live
`Config.data` (mirroring how `car.gd`'s `apply_car` reshapes it).

## Data model

The profile is a plain `Dictionary` mirroring the JSON shape (keeps load / save
/ migration as pure dict transforms with no engine-class coupling):

- `schema_version` — bumped on breaking shape changes; older files migrate
  forward on load, newer files are refused (not truncated).
- `starter_picked` / `starter_model_id` — first-run starter state. The starter is
  **chosen by the player**, not auto-granted: on a first run (no `starter_picked`)
  the HQ title's Start opens the car park's starter picker (MX-5 vs Focus, the two
  authored-body cars); picking one calls `grant_car(model_id, immortal=true)`, sets
  these fields + the selection, and enters the garage. See `features/menus.md`.
- `next_instance_id` — monotonic counter minting unique owned-car ids.
- `cars` — array of **instance-based** owned cars. Each is a unique instance
  (`instance_id`) referencing a `CarLibrary` model id (`model_id`), carrying its
  own `hp`, `immortal` flag, `installed_upgrades`, and `tuning` deltas. Two cars
  of the same model can diverge (the random-car reward can grant a model you
  already own).
- `selected_instance_id` — the owned car the player has **selected** (the one raised
  on the garage tuning lift; see `features/tuning.md`). Resolved lazily by
  `Save.selected_car()`, which self-heals to the first owned car when the stored id
  is unset (`-1`) or no longer owned (e.g. after a wreck).
- `inventory` — `{ item_id -> count }` for uninstalled upgrades + repair kits.
- `rallies` — `{ rally_id -> { completed, best_combined_ms, best_placed } }`, only
  completed rallies present. Completion count is the single progression metric;
  `best_placed` is the best (lowest) finishing position ever achieved there (drives
  the world-map star rating).
- `showdown_unlocked` / `showdown_completed` — the end-game beat.
- `reward_history` — model/item ids ever revealed (for the discovery framing).
- `settings` — a flat `{ key -> value }` bag of player/device preferences (e.g.
  `mobile_control_scheme`); read/written via `get_setting`/`set_setting`. Old
  profiles missing it are backfilled on load.

Max-HP is **CarLibrary metadata, not stored**; `OwnedCar.hp` is seeded from and
clamps to it. Opponent times, track geometry, etc. are derived from seeds, not
saved.

## CarLibrary metadata (prerequisite)

`scripts/car_library.gd` gained additive per-entry metadata that ownership keys
on: a stable string **`id`** (`mx5`, `rs3`, `porsche911`, `lfa`, `mustang`,
`aventador` — never reordered/reused, replaces array-index identity for
persistence), plus `country`, `car_type`, `max_hp`, and `reward_tier`. Helpers:
`CarLibrary.index_of(id)` / `by_id(id)` resolve a stored id to the current array
position, and `power_to_weight(entry)` is a derived (not stored) ranking
heuristic.

## API

`Save.profile` (the loaded dict), `load_or_new()`, `save()` (debounced ~1s),
`save_now()` (immediate atomic write), `reset_new_game()`, `has_save()`. Mutators
that mutate + autosave: `grant_car(model_id, immortal)`, `get_car(instance_id)`,
`apply_damage(instance_id, amount)`, `wreck_car(instance_id)` (leaves the car owned
at **0 HP** — not destroyed — too damaged to field until repaired),
`car_is_wrecked(car)` (the 0-HP, non-immortal predicate the menus gate on),
`scrap_car(instance_id)` (a deliberate player removal — erases the car, upgrades
**not** refunded, refuses the immortal starter; drives HQ's garage-overflow prompt),
`set_tuning(instance_id, tuning)`, `selected_car()` / `selected_instance_id()` /
`set_selected_car(instance_id)` (the lift's selected car, self-healing),
`get_setting(key, default)` / `set_setting(key, value)` (the preferences bag),
`add_item` / `consume_item`,
`install_upgrade` (enforces one-per-slot via `UpgradeLibrary`; fitting **fully
consumes** the part — a swap scraps the incumbent rather than refunding it, and a
wrecked car keeps its parts fitted; see `features/upgrade-catalogue.md`),
`use_repair_kit(instance_id)`
(spend a kit to **fully restore** health — revives a wrecked car),
`complete_rally(rally_id, combined_ms,
placed)` (idempotent; keeps the best time **and** best placement; does **not** grant
the car reward — re-wins are farmable). `rally_completed(id)` /
`completed_rally_count()` / `best_placement(id)` query progress.

## Durability & integrity

- **Atomic writes:** write to `profile.json.tmp`, then rename over the real file;
  the prior file is kept as `profile.json.bak` for one generation.
- **Load fallback chain:** primary → `.bak` → fresh default. A corrupt/garbage
  file is never silently overwritten (parsed via the `JSON` instance API so
  malformed input returns an error code rather than crashing).
- **Unknown `model_id`** (a car dropped from `CarLibrary`) is pruned on load with
  a warning, keeping old saves loadable as the roster evolves.
- **Migration** is keyed by version (`_MIGRATIONS`, currently empty) as pure
  `Dictionary -> Dictionary` transforms; a newer-than-known version refuses to
  load and runs in-memory rather than clobbering the file.
- **Web build:** on the HTML5 export `user://` is IndexedDB (async); `Save`
  forces a synchronous `save_now()` on `NOTIFICATION_WM_CLOSE_REQUEST` /
  `NOTIFICATION_APPLICATION_PAUSED` so a backgrounded tab persists. Round-trip on
  an actual web export is still the highest-risk area to verify.
- **Blocked storage** (private browsing / read-only fs): writes degrade to an
  in-memory-only profile (`save_disabled`) instead of crashing.

## Not yet wired

`complete_rally` calls `_recompute_showdown()`, currently a deliberate no-op —
the showdown-unlock threshold belongs to the rally roster
(`todo/rally-roster.md`), to be wired when that lands. `item_id`s come from the
upgrade catalogue (`todo/upgrade-catalogue.md`); `Save` only consumes them as
opaque strings.

## Tests

`tests/headless/test_save_manager.gd` — round-trip, default profile, instance-id
uniqueness, HP seeding, idempotent rally completion, wreck-returns-upgrades,
immortal-never-wrecks, inventory counts, migration refuse/backfill, corrupt-JSON
and `.bak` fallback, unknown-model pruning, new-game reset. Runs against a
throwaway `user://test_profile.json`. CarLibrary metadata + id helpers are
covered in `test_car_library.gd`; the autoload-registered smoke check is in
`test_smoke.gd`.
