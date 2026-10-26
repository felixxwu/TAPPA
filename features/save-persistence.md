# Save / Persistence

**Source:** `scripts/save_manager.gd` (`Save` autoload).

**Tests:** `tests/headless/test_save_manager.gd`, `tests/headless/test_save_web_lifecycle.gd`

The **`Save` autoload** (registered in `project.godot [autoload]` alongside `Config`) is the
single source of truth for everything the player's progress mutates: owned cars (each with
its own HP, tuning and fitted parts), lifetime stats, the persistent free-roam world and
settings. It persists as JSON at `user://profile.json` so progress survives a restart on both
desktop and the web build.

## Data model

The profile is a plain `Dictionary` mirroring the JSON shape (`_default_profile()` is the
whole schema):

- `schema_version` — currently **8**. Anything else, older or newer, is refused (see
  *Durability* below).
- `starter_picked` / `starter_model_id` — first-run starter state.
- `next_instance_id` — monotonic counter minting unique owned-car ids.
- `cars` (`Save.KEY_CARS`) — array of **instance-based** owned cars. Each references a
  `CarLibrary` model id (`model_id`) and carries its own `hp`, `tuning`, `wheel_toe`
  (per-wheel damage misalignment, ordered like `DamageModel.WHEEL_NAMES`) and `parts`
  (free-roam parts, [loot.md](loot.md)). Two cars of the same model can diverge. A car's
  `boosts` / `swapped_engine` / `drivetrain_override` are written onto a DUPLICATE at
  fielding time by `LootRules.fielded` and never reach the profile.
- `lifetime` (`Save.KEY_LIFETIME`) — `{stat_id: int}`, only ever grows
  ([lifetime-stats.md](lifetime-stats.md)).
- `world` (`Save.KEY_WORLD`) — the persistent free-roam world, `{}` until New World. Its only
  writer is `WorldSession` ([world-session.md](world-session.md)).
- `settings` — a flat `{ key -> value }` bag of player/device preferences, read/written via
  `get_setting` / `set_setting`.
- `cloud_revision` / `cloud_uid` / `unsynced` — the optional cloud-save
  bookkeeping ([cloud-save.md](cloud-save.md)). `unsynced` is PERSISTED deliberately:
  progress made offline must still read as unsynced after a relaunch.

**The named keys are on-disk strings.** Use `Save.KEY_CARS` / `KEY_LIFETIME` / `KEY_WORLD`
rather than the literal; the cloud-sync copy is why a missed rename would be a cross-device
DATA bug rather than a crash. **Declare every key you write in `_default_profile()`** — the
key backfill only knows that dict, and `Save` pushes an error naming any undeclared key it
sees written (`test_every_persisted_key_written_is_declared_in_the_default_profile`).

**Credentials are NOT stored here.** The profile is uploaded to Firestore, so auth tokens
live in a separate, never-synced `user://auth.json` (see [cloud-save.md](cloud-save.md) ›
"Credential storage").

Max-HP is **CarLibrary metadata, not stored**; `OwnedCar.hp` is seeded from it by
`grant_car`. The world's terrain, roads and sites are derived from its seed, not saved.

## API

- Load / save: `load_or_new()`, `save()` (debounced), `save_now()`, `flush_and_sync()`,
  `has_save()`, `reset_new_game()`.
- Cars: `grant_car(model_id)`, `owns_model(model_id)`, `get_car(instance_id)`,
  `set_tuning`, `set_wheel_toe`, `set_car_parts`.
- Lifetime stats: `lifetime_stat(id)`, `add_lifetime_stat(id, amount := 1)`.
- Settings: `get_setting(key, default)`, `set_setting(key, value)`.
- For the cloud layer only: the `profile_changed` / `flushed` signals, `has_unsynced()` /
  `mark_synced()`, `adopt_profile()` (runs a downloaded profile through the same migrate +
  sanitise path as a file on disk) and `write_conflict_backup()` (a `.conflict.bak` that
  outlives the rolling `.bak`). The dependency runs one way — `Cloud` knows about `Save`,
  never the reverse.

## Durability & integrity

- **Atomic writes:** write to `profile.json.tmp`, then rename over the real file;
  the prior file is kept as `profile.json.bak` for one generation.
- **Debounced:** `save()` arms a ~1 s one-shot timer (`SAVE_DEBOUNCE_SEC`) that keeps running
  while the tree is paused, so a burst of mutations is one write.
- **Load fallback chain:** primary → `.bak` → fresh default. A corrupt/garbage
  file is never silently overwritten (parsed via the `JSON` instance API so
  malformed input returns an error code rather than crashing).
- **Unknown `model_id`** (a car dropped from `CarLibrary`) is pruned on load by `_sanitise`
  with a warning, keeping old saves loadable as the roster evolves.
- **No migration.** `_migrate` refuses any profile whose `schema_version` is not exactly
  `SCHEMA_VERSION` and the loader runs on a fresh profile instead of guessing. What survives
  is a **key backfill** from `_default_profile()`, so a key added without a version bump
  appears on an existing profile. **The fresh profile is NOT `save_disabled`:** every
  returning player hits the refusal on their first launch after a bump, and blocking saves
  there once meant a whole session's progress never reached disk
  (`test_a_refused_pre_pivot_profile_can_still_save_new_progress`).
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

## Tests

`tests/headless/test_save_manager.gd` — round-trip, default profile, the paused-tree debounce,
instance-id uniqueness, HP seeding, `wheel_toe` persistence and backfill, migration
refuse/backfill (and that a refused profile can still save), settings round-trip, corrupt-JSON
and `.bak` fallback, unknown-model pruning, new-game reset, the cloud bookkeeping fields, and
the undeclared-key check. `tests/headless/test_save_web_lifecycle.gd` — the web lifecycle seam:
the shared `flush_and_sync()` entry point writes immediately (bypassing the debounce) and
round-trips, the desktop close notification reaches that same entry point, a disabled store
stays in-memory, and `install_web_lifecycle()` / `request_web_sync()` are inert off web. Both
run against a throwaway `user://test_profile.json`.
