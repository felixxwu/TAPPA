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
  - **`wheel_toe`** (`Array` of 4 floats, default `[0.0, 0.0, 0.0, 0.0]`,
    ordered like `DamageModel.WHEEL_NAMES`) — per-wheel damage misalignment in
    radians, written by `Save.set_wheel_toe` and defaulted on read for old
    saves; see `features/damage.md`.
  - **`drivetrain_override`** (int, default `-1`, meaning "no override — use the
    car's stock drive mode") — written by `Save.set_drivetrain_override`.
  - **`wheels`** (string, default absent — absence means "stock wheels") — a
    non-stock wheel cosmetic id fitted to the car, written/erased by
    `Save.set_wheels`; purely visual, see `features/wheel-customization.md`.
- `selected_instance_id` — the owned car the player has **selected** (the one raised
  on the garage tuning lift; see `features/tuning.md`). Resolved lazily by
  `Save.selected_car()`, which self-heals to the first owned car when the stored id
  is unset (`-1`) or no longer owned (e.g. after a wreck). Selecting a car also
  **promotes it to the front of `cars`** (`set_selected_car` moves the matching
  entry to index 0, shifting the rest down) — so the car park shows the
  most-recently-selected car first, and that order persists across relaunches
  (car park lineups iterate `cars`).
- `inventory` — `{ item_id -> count }`: the **unlocked pool** of not-yet-applied
  upgrades (won but kept for later) + the consumables (repair kits + engine swap
  tokens). Adding a new consumable is just a new key — no `SCHEMA_VERSION` bump,
  and an absent key reads as count 0.
- `rallies` — `{ rally_id -> { completed, best_combined_ms, best_placed } }`, only
  completed rallies present. Completion count is the single progression metric;
  `best_placed` is the best (lowest) finishing position ever achieved there (drives
  the world-map star rating).
- `showdown_unlocked` / `showdown_completed` — the end-game beat.
  **Region unlock is not stored here or anywhere else** — `RegionLibrary.unlocked`
  (see [regions.md](regions.md)) derives it on every call from the previous
  region's showdown-rally `completed` flag in `rallies`, so no new profile
  field/schema bump was needed for the region system.
- `reward_history` — model/item ids ever revealed (for the discovery framing).
- `settings` — a flat `{ key -> value }` bag of player/device preferences (e.g.
  `mobile_control_scheme`); read/written via `get_setting`/`set_setting`. Old
  profiles missing it are backfilled on load.
- `cloud_revision` (int, default 0) / `unsynced` (bool, default false) — the
  optional cloud-save bookkeeping, described in [cloud-save.md](cloud-save.md).
  Both arrive via `_migrate`'s key backfill, so neither needed a
  `SCHEMA_VERSION` bump. `unsynced` is PERSISTED deliberately: progress made
  offline must still read as unsynced after a relaunch.

**Credentials are NOT stored here.** `settings` lives inside the blob uploaded
to Firestore, so auth tokens would be published to the database if they were
kept in the profile. They live in a separate, never-synced `user://auth.json`
(see [cloud-save.md](cloud-save.md) › "Credential storage").

`Save` also exposes, for that layer only: the `profile_changed` / `flushed`
signals, `has_unsynced()` / `mark_synced()`, `adopt_profile()` (runs a
downloaded profile through the same migrate + sanitise path as a file on disk)
and `write_conflict_backup()` (a `.conflict.bak` that outlives the rolling
`.bak`). The dependency runs one way — `Cloud` knows about `Save`, never the
reverse.

Max-HP is **CarLibrary metadata, not stored**; `OwnedCar.hp` is seeded from and
clamps to it. Opponent times, track geometry, etc. are derived from seeds, not
saved.

## CarLibrary metadata (prerequisite)

`scripts/car_library.gd` gained additive per-entry metadata that ownership keys
on: a stable string **`id`** (`mx5`, `focus`, `porsche911`, `viper`, `charger`,
`xjs` — never reordered/reused, replaces array-index identity for
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
  a warning, keeping old saves loadable as the roster evolves. The same pass
  (`_prune_unknown_upgrades`) drops fitted / toggled-off part ids that no longer
  resolve against `UpgradeLibrary`, so a part retired from the catalogue can't
  linger in a car's `installed_upgrades` and occupy a phantom slot in the menu.
- **Migration** is keyed by version (`_MIGRATABLE_FROM`, currently `[1]`) as pure
  `Dictionary -> Dictionary` transforms (`_migrate_step`); a newer-than-known
  version, or a version with no step in `_MIGRATABLE_FROM`, refuses to load and
  runs in-memory rather than clobbering the file. Current `SCHEMA_VERSION` is
  `2`; the one authored step is **1 → 2**, added alongside upgrades becoming
  CAR-BOUND: the old shared `inventory` pool of slottable parts is gone (parts
  now live on the `OwnedCar` they were won for), so the step strips every
  non-repair-kit entry from `inventory` — those unbound parts were never
  applied and have no car to belong to — while leaving repair kits (the one
  remaining pooled consumable) untouched.
- **Web build:** on the HTML5 export `user://` is IndexedDB (Emscripten IDBFS) —
  `FileAccess` writes land in an in-memory FS that is pushed to IndexedDB
  *asynchronously*, so a write that hasn't synced when the page goes away is
  lost. Both platforms funnel through one entry point, `Save.flush_and_sync()`
  (immediate `save_now()` + `request_web_sync()`):
  - **Desktop/native** reaches it from `_notification` on
    `NOTIFICATION_WM_CLOSE_REQUEST` / `NOTIFICATION_APPLICATION_PAUSED`.
  - **Web** never gets those (a browser sends no window-manager close), so
    `install_web_lifecycle()` — called from `_ready`, a no-op off web, idempotent —
    registers JS listeners via `JavaScriptBridge` on the two signals mobile
    browsers actually fire when a page goes away: `visibilitychange`→`hidden` and
    `pagehide`. They call back into `flush_and_sync()` through a
    `JavaScriptBridge.create_callback` handle parked on `window.rallySaveFlush`
    (the handle is held in a member var — dropping it detaches the listeners).
  - `request_web_sync()` then asks the Emscripten FS for an explicit
    `FS.syncfs(false, …)`, defensively (FS may not be exposed on the JS globals;
    failure falls back to the engine's own async sync and never takes the game down).
  The web export is **single-threaded** (`variant/thread_support=false` in
  `export_presets.cfg`), so the write itself is cheap and synchronous on the main
  loop — the risk being mitigated is the async IDB sync not landing, not write
  cost, which is why the ~1s debounce is left alone. **Still unverified:** the
  manual round-trip on a real web build (mutate progress → close the tab →
  reopen → confirm it survived), on desktop *and* mobile browsers. There is no
  automated web harness, so that manual pass is the acceptance check.
  Player settings ride the same path — they live in `profile["settings"]` via
  `get_setting`/`set_setting`, **not** in a separate `ConfigFile`, so there is
  only one store to make durable.
- **Blocked storage** (private browsing / read-only fs): writes degrade to an
  in-memory-only profile (`save_disabled`) instead of crashing.

## Not yet wired

`complete_rally` calls `_recompute_showdown()`, a deliberate no-op: the
showdown unlock and per-region reveal gates are derived LIVE from the profile's
completion records by `RallyLibrary` (`showdown_unlocked()` / `rally_revealed()`,
see `rally-roster.md`), rather than being precomputed and stored on the save, so
there is nothing to recompute here. `item_id`s come from the upgrade catalogue
(`upgrade-catalogue.md`); `Save` only consumes them as opaque strings.

## Tests

`tests/headless/test_save_manager.gd` — round-trip, default profile, instance-id
uniqueness, HP seeding, idempotent rally completion, wreck-returns-upgrades,
the starter wrecking like any car, the `ensure_repair_safety_net` free-kit floor
(all cars wrecked + none held), inventory counts,
migration refuse/backfill, corrupt-JSON
and `.bak` fallback, unknown-model + retired-part pruning, new-game reset.
`tests/headless/test_save_web_lifecycle.gd` — the web lifecycle seam: the shared
`flush_and_sync()` entry point writes immediately (bypassing the debounce) and
round-trips, the desktop close notification reaches that same entry point, a
disabled store stays in-memory, and `install_web_lifecycle()`/`request_web_sync()`
are inert off web (a browser event can't be fired headlessly, so the tests assert
either side of it). Both run against a
throwaway `user://test_profile.json`. CarLibrary metadata + id helpers are
covered in `test_car_library.gd`; the autoload-registered smoke check is in
`test_smoke.gd`.
