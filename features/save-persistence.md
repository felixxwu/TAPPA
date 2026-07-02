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
  the HQ title's Start opens the car park's starter picker (MX-5, Focus or Twingo, the three
  authored-body cars); picking one calls `grant_car(model_id)`, sets
  these fields + the selection, and enters the garage. See `features/menus.md`.
- `next_instance_id` — monotonic counter minting unique owned-car ids.
- `cars` — array of **instance-based** owned cars. Each is a unique instance
  (`instance_id`) referencing a `CarLibrary` model id (`model_id`), carrying its
  own `hp`, `installed_upgrades`, `disabled_upgrades` (applied parts toggled off
  in the upgrades menu — fitted but inert), and `tuning` deltas. Two cars of the
  same model can diverge (the random-car reward can grant a model you already
  own). Two further fields support [engine-swap.md](engine-swap.md), both
  defaulted on read so no `SCHEMA_VERSION` bump was needed for either:
  - **`swapped_engine`** (string, default `""`) — a non-stock `EngineLibrary` id
    currently fitted, written/cleared by `Save.swap_engines`; absent/empty means
    the car runs its own `CarLibrary` stock engine.
  - **`tuning.engine_detune`** (float, default `1.0`) — a `[0, 1]` torque scale
    living in the existing `tuning` bag, written by `Save.set_engine_detune`.
- `selected_instance_id` — the owned car the player has **selected** (the one raised
  on the garage tuning lift; see `features/tuning.md`). Resolved lazily by
  `Save.selected_car()`, which self-heals to the first owned car when the stored id
  is unset (`-1`) or no longer owned (e.g. after a wreck).
- `inventory` — `{ item_id -> count }`: the **unlocked pool** of not-yet-applied
  upgrades (won but kept for later) + repair kits.
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
that mutate + autosave: `grant_car(model_id)`, `get_car(instance_id)`,
`apply_damage(instance_id, amount)`, `wreck_car(instance_id)` (leaves the car owned
at **0 HP** — not destroyed — too damaged to field until repaired),
`car_is_wrecked(car)` (the 0-HP predicate the menus gate on),
`ensure_repair_safety_net()` (anti-soft-lock floor — if the player owns ≥1 car,
**every** owned car is wrecked, and **no** repair kits are held, grants ONE free
Repair Kit and returns true, else no-op/false; called at the end of `load_or_new`
and on every garage-lift refresh, `hq.gd:_refresh_lift_ui`),
`scrap_car(instance_id)` (a deliberate player removal — erases the car, upgrades
**not** refunded, refuses the player's **last** owned car so the "always own ≥1 car"
invariant holds and the safety net always has a car to revive; drives HQ's
garage-overflow prompt),
`set_tuning(instance_id, tuning)`,
`swap_engines(id_a, id_b)` (exchanges two owned cars' CURRENT engines; free,
unlimited, reversible, gated on both sitting at 100% HP via `EngineSwap.can_swap`
— see [engine-swap.md](engine-swap.md)),
`set_engine_detune(instance_id, frac)` (clamped `[0,1]` torque-scale tuning value),
`selected_car()` / `selected_instance_id()` /
`set_selected_car(instance_id)` (the lift's selected car, self-healing),
`get_setting(key, default)` / `set_setting(key, value)` (the preferences bag),
`add_item` / `consume_item`,
`install_upgrade` (consumes the part from the unlocked pool and fits it to the
car **for good** — applied parts accumulate on the car; at most one is ENABLED
per slot, so applying one disables a same-slot incumbent rather than scrapping
it, a duplicate of a part already on the car is rejected, and a wrecked car
keeps its parts fitted; see `features/upgrade-catalogue.md`),
`set_upgrade_enabled(instance_id, item_id, enabled)` (the upgrades-menu toggle —
free and reversible; enabling a part switches off its same-slot siblings),
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
the starter wrecking like any car, the `ensure_repair_safety_net` free-kit floor
(all cars wrecked + none held), scrap refusing the last owned car, inventory counts,
migration refuse/backfill, corrupt-JSON
and `.bak` fallback, unknown-model pruning, new-game reset. Runs against a
throwaway `user://test_profile.json`. CarLibrary metadata + id helpers are
covered in `test_car_library.gd`; the autoload-registered smoke check is in
`test_smoke.gd`.
