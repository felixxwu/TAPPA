# Save / Persistence

The **`Save` autoload** (`scripts/save_manager.gd`, registered in
`project.godot [autoload]` alongside `Config`) is the single source of truth for
everything the meta-game mutates: owned cars (each with its own HP, installed
upgrades and tuning), the uninstalled-item inventory, and rally completion. It
persists as JSON at `user://profile.json` so progress survives a restart on both
desktop and the web build.

**Tests:** `tests/headless/test_save_manager.gd`, `tests/headless/test_save_web_lifecycle.gd`, `tests/headless/test_save_sandbox.gd`, `tests/headless/test_cloud_sync.gd`

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
- **The two most widely-read keys are NAMED on `SaveManager`:** `Save.KEY_CARS`
  (`"cars"`) and `Save.KEY_RALLIES` (`"rallies"`), used by every consumer
  (`reward_system.gd`, `rally_library.gd`, `upgrade_library.gd`, the HQ screens,
  `cloud/cloud_sync.gd`, …) instead of the bare literal — the cloud-sync copy is
  why a missed rename would be a cross-device DATA bug rather than a crash. Their
  VALUES are on-disk key strings: frozen unless a `SCHEMA_VERSION` bump and a
  `_migrate_step` come with the change. `car_library.gd` still spells `"cars"`
  literally in `wheel_catalogue`, deliberately: it is the one profile reader with
  no `Save` dependency at all, and naming the key is not worth adding one.
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
  upgrades (won but kept for later). Nothing shipped is a consumable any more, but
  the key is deliberately generic — `Save.add_item` / `Save.consume_item` work on
  any id — so it stays as the home for anything counted rather than slotted.
  Adding one is just a new key: no `SCHEMA_VERSION` bump, and an absent key reads
  as count 0.
- `rallies` — `{ rally_id -> { completed, best_combined_ms, best_placed, revealed } }`.
  Completion count is the single progression metric; `best_placed` is the best (lowest)
  finishing position ever achieved there (drives the world-map star rating).
  `revealed` is the **new-rally reveal acknowledgement** — whether the map-table reveal
  sequence has shown the player that this rally opened up (`Save.rally_revealed_seen` /
  `Save.mark_rally_revealed`; see [menus.md](menus.md) → "New-rally reveal"). It lives
  in the same per-rally record as `completed` so everything known about a rally is in one
  place and a rally id that stops existing takes its flag with it instead of orphaning an
  entry in a parallel list. Only the ACKNOWLEDGEMENT is stored, never the unlock — which
  rallies are open stays derived, exactly as the special-event gate is (below).
  A missing key reads `false` through the normal `.get` default, so no `SCHEMA_VERSION`
  bump was needed.
  **The backfill:** `false` is the wrong default for an EXISTING save — a career with a
  dozen open rallies would be met by a dozen-pin parade on next launch.
  `Save.needs_reveal_seeding()` reports "has career progress, yet not one rally carries a
  `revealed` flag" (a pre-feature save, or one just pulled down by a cloud restore).
  The seeding itself is `Save._seed_reveals_if_needed()`, called by `Save` ITSELF at the
  two points a profile actually becomes live — the tail of `load_or_new()` and the tail
  of `adopt_profile()` (the cloud-restore path) — rather than left as a call site a scene
  has to remember to make. (An earlier version had `hq.gd` call it from `_enter_table()`
  and separately from `_on_cloud_profile_replaced()`; that shape meant a THIRD future
  path reaching the map or replacing the profile could silently forget it, so it moved
  into `Save` where it seats itself automatically.) It marks everything already open
  (via `RallyLibrary.rally_revealed`) plus everything already completed — so the "no
  flags at all" state can't survive the pass — as seen, silently, with NO eligible-car
  check: seeding's job is "anything already open already reads as seen", not "anything
  the player can currently enter", and skipping that clause keeps `Save` independent of
  `hq.gd`'s `_entry_plan` (owned cars, tuning headroom, etc). The eligible-car hold is
  applied only by `hq_table.gd._pending_reveals()`, the query that decides what actually
  parades on a given map open.
- **Region unlock is not stored here at all** — `RegionLibrary` no longer gates
  anything (it's look + waterline only, see [regions.md](regions.md)). (An
  earlier `showdown_unlocked`/`showdown_completed` pair of persisted, never-read
  flags was removed — see `todo/one-map-four-corners.md`, "Resolved: the last
  six decisions" item 7.)
- **The reveal gate rides entirely on the existing per-rally `completed`
  flag and each rally's authored `map_pos` — no new save state.**
  `RallyLibrary.rally_revealed` is a live, geometric comparison of a rally's
  `map_pos` against the lit circles of every completed rally in the profile
  (`lit_sources`) — nothing is precomputed or persisted for it, and it treats
  `special: true` rallies no differently from ordinary ones. Winning a
  gated upgrade part (`UpgradeDef.unlocked_by_rally`) reads the same
  `completed` flag on the naming special's rally record — again nothing new.
  See [rally-roster.md](rally-roster.md) for the ladder and
  [reward-system.md](reward-system.md) for where the gate is applied to the
  draw pool.
- `stars_earned` / `stars_spent` — the **star ledger**, and the one part of the star
  economy that IS persisted state. `Save.stars_available()` is the difference,
  `award_stars()` credits, `spend_stars()` debits (refusing an unaffordable debit
  rather than going negative). Two counters rather than one balance so the lifetime
  earned figure survives spending. A derived total was deliberately abandoned here:
  it could not see Rally Challenge income (an unrecoverable, non-rally source) and
  it would shrink whenever a rally was renamed or retired — dropping the balance
  below `stars_spent` and producing a negative. Missing keys read 0, so no
  `SCHEMA_VERSION` bump was needed. See [star-economy.md](star-economy.md).
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
heuristic. **`CarLibrary.for_owned(owned)`** is the one spelling of "the
catalogue entry this OWNED car row resolves to" (`by_id(String(owned.get(
"model_id", "")))`, previously repeated at ~30 call sites); it returns the same
empty Dictionary `by_id` does when the row's `model_id` is missing or names a
model the catalogue no longer carries, so callers keep using `is_empty()` as the
"this car is gone" test.

## API

`Save.profile` (the loaded dict), `load_or_new()`, `save()` (debounced ~1s),
`save_now()` (immediate atomic write), `reset_new_game()`, `has_save()`. Mutators
that mutate + autosave: `grant_car(model_id)`, `get_car(instance_id)`,
`apply_damage(instance_id, amount)`, `record_wreck(instance_id)` (hands the car back
at `GameConfig.wreck_recovery_hp_fraction` of max HP — battered, still drivable, never
written off; see [damage.md](damage.md)),
`car_needs_repair(instance_id)` / `repair_price(instance_id)` / `repair_car(instance_id)`
(the star-priced repair sink — "is this car less than pristine", which is ANY lost health
or bent alignment), `car_handles_badly(instance_id)` (the narrower question the car park's
red warning asks: is the damage below `damage_misfire_health_threshold`, i.e. actually
costing engine power),
`can_buy_part(instance_id, item_id)` / `part_price(item_id)` / `buy_part(instance_id, item_id)`
(buying a discovered upgrade for a car — see [star-economy.md](star-economy.md)),
`owns_model(model_id)`,
`rally_revealed_seen(rally_id)` / `mark_rally_revealed(rally_id)` (the map's
new-rally reveal acknowledgement — only the ACKNOWLEDGEMENT is persisted, never the
unlock, which stays derived; see [map-exploration.md](map-exploration.md)),
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
`apply_build_plan(instance_id, plan)` (writes an `UpgradeLibrary.auto_build_plan`
plan to a car in one go — buys + enables, enables, strips, an optional drivetrain
override, then the plan's absolute detune; a no-op returning `false` for a plan whose
`changed` is false or a car that isn't in the save),
`complete_rally(rally_id, combined_ms,
placed)` (idempotent; keeps the best time **and** best placement; grants no car — cars
are bought, see [star-economy.md](star-economy.md)). It **returns the star delta it
credited**: only the IMPROVEMENT over that rally's previous best, so a re-win at an
equal or worse placement pays nothing and the renewable-win loop can't be farmed.
The podium's stars beat needs that delta rather than the raw placement rating, since
turning a 2nd into a 1st is worth exactly 1 even though the two placements rate 2 and
3 stars. `award_stars` / `spend_stars` / `stars_available` are the non-rally ledger
API. `rally_completed(id)` /
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
- **Migration** is keyed by version (`_MIGRATABLE_FROM`, currently `[1, 2, 3, 4, 5]`) as
  pure `Dictionary -> Dictionary` transforms (`_migrate_step`); a newer-than-known
  version, or a version with no step in `_MIGRATABLE_FROM`, refuses to load and
  runs in-memory rather than clobbering the file. Current `SCHEMA_VERSION` is **6**,
  and the five authored steps are:
  - **1 → 2**, alongside upgrades becoming CAR-BOUND: the old shared `inventory` pool of
    slottable parts is gone (parts now live on the `OwnedCar` they were won for), so the
    step strips **every** entry from `inventory` — those unbound parts were never applied
    and have no car to belong to.
  - **2 → 3**, after rally entry stopped gating on power-to-weight: a saved
    `tuning.engine_detune` set purely to duck under a ceiling had nothing left to duck
    under and no player-reachable way to restore it, so every car is reset to full power.
  - **3 → 4**, adaptive difficulty's offset + streak counters, all zero — which IS the
    pre-adaptive "matched field" behaviour, so a migrated career resumes at parity. See
    [adaptive-difficulty.md](adaptive-difficulty.md).
  - **4 → 5**, two part unlocks moving into the Alps (Race Tires `gr_showdown` →
    `sn_showdown`, Sequential Gearbox `hc_showdown` → `sp_summit_trial`). A player who
    already won the old rally keeps the part, granted directly via
    `KEY_LEGACY_PART_UNLOCKS` — an early-out in `UpgradeLibrary.rally_gate_met`. It is
    deliberately NOT done by marking the new rally completed, which would also light its
    map-reveal circle and pay its placement stars, handing over progress and currency
    never earned. `MOVED_PART_UNLOCKS` is the data it reads, so a future move is one row
    plus one arm. See [snow-region.md](snow-region.md).
  - **5 → 6**, the engine-swap CAPABILITY moving (`sp_woodland_trial` → `front_runners`,
    the difficulty-1 pin beside HQ) so the old rally could carry Snow Tires instead. Same
    shape one level up: a player who already won the old rally keeps the capability,
    granted directly via `KEY_LEGACY_ENGINE_SWAP` (a bool), which
    `RallyLibrary.engine_swaps_unlocked` checks BEFORE the rally record — again not by
    marking the new rally completed, which would light its reveal circle and pay stars
    never earned. See [engine-swap.md](engine-swap.md).

  **Retired items are NOT a migration.** `SaveManager._sanitise` erases every id in
  `SaveManager.RETIRED_ITEM_IDS` (the repair kit, the mystery box, the engine swap
  token) from `inventory` on load, and no `SCHEMA_VERSION` bump goes with it. The
  reasoning is the same each time an item is deleted: the stale key is already inert
  once nothing reads it, whereas a version bump makes older builds refuse the profile
  outright — a real cost when cloud save moves one profile between devices running
  different builds. Deleting an item is therefore a one-row change to that list, not
  a new migration arm. The `inventory` key itself always survives; only the dead ids
  inside it go.
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

The special-event gate and the per-rally reveal gate are the one predicate, derived
LIVE from the profile's completion records and every rally's authored `map_pos` by
`RallyLibrary` (`rally_revealed()` over `lit_sources()`, see `map-exploration.md`),
rather than being precomputed and stored on the save — `save_manager.gd` recomputes no
unlock state on `complete_rally`; the only thing it writes beyond the rally record
itself is the star delta onto `stars_earned` (see the ledger above).
`item_id`s come from the upgrade catalogue
(`upgrade-catalogue.md`); `Save` only consumes them as opaque strings.

## Tests

`tests/headless/test_save_manager.gd` — round-trip, default profile, instance-id
uniqueness, HP seeding, idempotent rally completion, wreck-returns-upgrades,
the starter wrecking like any car, the repair sink (price / spend / restore) and the
narrower `car_handles_badly` warning predicate, inventory counts,
migration refuse/backfill, corrupt-JSON
and `.bak` fallback, unknown-model + retired-part pruning, the legacy-NOS revival
(a nitrous part left parked by the retired ladder comes back ENABLED), new-game reset.
`tests/headless/test_save_web_lifecycle.gd` — the web lifecycle seam: the shared
`flush_and_sync()` entry point writes immediately (bypassing the debounce) and
round-trips, the desktop close notification reaches that same entry point, a
disabled store stays in-memory, and `install_web_lifecycle()`/`request_web_sync()`
are inert off web (a browser event can't be fired headlessly, so the tests assert
either side of it). Both run against a
throwaway `user://test_profile.json`. CarLibrary metadata + id helpers are
covered in `test_car_library.gd`; the autoload-registered smoke check is in
`test_smoke.gd`.
