# Save / Persistence — implementation spec  ✅ DONE

> Status: **DONE (core, desktop).** The `Save` autoload
> (`scripts/save_manager.gd`), the CarLibrary metadata pass (`id` / `country` /
> `car_type` / `max_hp` / `reward_tier` + `index_of`/`by_id`/`power_to_weight`),
> the full mutator API, atomic writes + `.bak`/default fallback, versioning &
> migration scaffolding, and headless tests (`test_save_manager.gd`, plus
> additions to `test_car_library.gd` / `test_smoke.gd`) are in place and green.
> **Still open:** verifying the round-trip on an actual **web export**
> (IndexedDB flush — highest-risk, untested) — now split into its own
> `todo/web-save-persistence.md`; and wiring `_recompute_showdown()` once the
> rally roster lands. Doc: `features/save-persistence.md`.
>
> Implementation brief for the
> player-progress save system named first under `gameplay.md` › *Foundations
> this implies* — **"Nothing here works without it."** Follow the config-first
> convention (`CLAUDE.md`): authored *tuning baselines* stay in `GameConfig`
> (`scripts/game_config.gd` + `config/game_config.tres`); this spec adds a
> separate **player profile** (owned cars, HP, upgrades, inventory, rally
> completion). Keep them distinct — `GameConfig` is the authored car/world
> baseline, the profile is per-player mutable progress. Update the relevant
> `features/*.md` doc and add tests in the same piece of work.
>
> **The three big forks are decided** (with the user): **instance-based**
> ownership, **JSON at `user://`**, and a **single auto-saved profile**. They're
> baked into the model below; see *Decided (kept for trace)*.

## Goal

A single source of truth for everything the meta-game mutates, that survives a
restart on **both desktop and the web build** (`build_web.sh` → itch.io), loads
once at boot, and autosaves on every meaningful change — with a schema version
so the format can evolve without bricking existing saves.

## Current state (measured from the code)

- **No persistence of any kind.** The only autoload is `Config`
  (`project.godot:18-20`, `*res://scripts/config.gd`), and it holds **only** a
  fresh, in-memory working copy of the authored `GameConfig`
  (`Config.data`, `scripts/config.gd:6`), re-`duplicate(true)`-d from the
  pristine `.tres` on every `reset()` (`config.gd:18-25`). Nothing is written
  to `user://`; nothing reads player progress because there is none.
- **Cars are identified by array index, not a stable id.** `car.gd` tracks the
  active car as `_car_index` (`car.gd:16`), `apply_car(index)` (`car.gd:253`),
  `next_car_index()` wraps `(_car_index + 1) % CarLibrary.CARS.size()`
  (`car.gd:239-240`), and the only human key is `["name"]` (`car.gd:246`).
  `CarLibrary.CARS` (`car_library.gd:81+`) is a positional `Array[Dictionary]`.
  **Saving ownership by index is unsafe** — reordering or inserting a car
  silently rewrites which car every existing save "owns." The profile must key
  cars by a **stable string id** (see *Dependencies*).
- **Tuning knobs already exist as `GameConfig` fields** (the per-car tuning the
  profile must store as deltas): `wheel_friction_slip_front` (`game_config.gd:106`)
  / `wheel_friction_slip_rear` (`:107`), `downforce_front` (`:76`) /
  `downforce_rear` (`:80`), and `brake_torque` (`:66`, today a single per-axle
  value — a front/rear brake split is a **new** knob per `menus.md` and
  `gameplay.md`).
- **Web is a shipping target.** `build_web.sh` exports an HTML5 build with
  `thread_support=true` (SharedArrayBuffer). On web, `user://` is backed by the
  browser's **IndexedDB**, which has timing/flush implications (see *Web build*).

## What must persist (from `gameplay.md`)

Sourced from `gameplay.md` › *Foundations* + the damage/tuning/progression
sections:

1. **Owned cars** — each with its own **current HP**, **installed upgrades**,
   **per-car tuning**, and whether it's the **immortal starter**.
2. **Inventory** — uninstalled upgrade items + repair kits (counts per type).
3. **Rally completion** — which rallies are **top-3'd** (the single progress
   metric: drives reward-tier ceiling **and** showdown unlock), plus best
   combined time per rally (for display).
4. **First-run / starter state** — has the starter been picked, and which one.
5. **Showdown** — unlocked? completed? (the "win the game" beat).
6. *(Optional)* **Reward history** — what's been revealed, for the
   discovery/lootbox "window into what exists" framing.

Explicitly **derived, not stored**: opponent times and who DNFs (fixed per rally
seed — `gameplay.md`, recompute from the seed); track geometry (regenerated from
`track_seed`); max-HP per car (a `CarLibrary` metadata value, not player state).

## Data model (proposed)

**Ownership is instance-based, not model-keyed** *(decided)*. Each owned car is
a unique **instance** that *references* a `CarLibrary` model id and carries its
own mutable state. Rationale: per-car HP + the fact that the random-car reward
can grant a model you already own (`gameplay.md` › *Progression*) means two cars
of the same model must be able to diverge in HP/upgrades/tuning. A flat
"set of owned model ids" can't represent that.

```
PlayerProfile
  schema_version: int                 # bump on any breaking shape change
  created_utc / updated_utc: String   # ISO-8601 stamps (passed in; see Notes)
  starter_picked: bool
  starter_model_id: String            # which of the 3 starters was chosen
  next_instance_id: int               # monotonic; mints unique owned-car ids
  cars: Array[OwnedCar]
  inventory: { item_id: String -> count: int }   # upgrades + repair kits
  rallies: { rally_id: String -> RallyRecord }    # only completed ones present
  showdown_unlocked: bool
  showdown_completed: bool
  reward_history: Array[String]       # optional; model/item ids revealed

OwnedCar
  instance_id: int                    # unique within the profile
  model_id: String                    # -> CarLibrary entry (stable id)
  hp: float                           # current; max comes from CarLibrary metadata
  immortal: bool                      # true only for the chosen starter
  installed_upgrades: Array[String]   # item ids currently fitted
  tuning: { grip_balance, brake_bias, aero_balance, ... }  # deltas vs baseline

RallyRecord
  completed: bool                     # top-3 achieved
  best_combined_ms: int               # best combined time across the 3 events
  best_placed: int                    # best (lowest) finishing position ever; drives the map stars
```

Notes:
- **Tuning is stored per owned car as deltas/targets**, then applied on top of
  the `CarLibrary` baseline when that car is fielded (the values map onto the
  `GameConfig` fields listed in *Current state*). It is never written back into
  the authored `.tres`.
- **A wrecked car** (HP→0) is removed from `cars`; its `installed_upgrades` are
  returned to `inventory` first (`gameplay.md` › *Damage*). The immortal starter
  is never wrecked, so it is never removed.
- **`item_id` / `model_id`** are the stable string ids defined by the
  CarLibrary-metadata and upgrade-catalogue todos — this spec only consumes them.

## Storage mechanism (decided)

- **Format: JSON at `user://profile.json`** *(decided)*. Inspectable, trivially
  versioned/migrated, and decoupled from engine class layout — unlike a Godot
  `Resource` (`.tres`), whose `ResourceSaver`/`load` path couples the save to
  script class names and breaks awkwardly when fields are renamed. `ConfigFile`
  is a fine alternative but is flatter than the nested model above. Serialize
  with `JSON.stringify` / parse with `JSON.parse_string`, via `FileAccess`.
- **A single auto-saved profile** *(decided)*, not named save slots. The game is
  one continuous progression (`gameplay.md`); "New game" overwrites after a
  `ConfirmModal`. Multiple slots can be layered on later by making the filename a
  parameter — note this so the API doesn't bake in the single-file assumption.
- **Atomic writes:** write to `user://profile.json.tmp`, then rename over the
  real file, so a crash mid-write can't corrupt the only profile. Keep the prior
  file as `profile.bak` for one generation.

## API surface (proposed)

A new autoload **`Save`** (`scripts/save_manager.gd`), registered in
`project.godot [autoload]` alongside `Config` (`project.godot:18-20`). Owns the
loaded `PlayerProfile` and all disk I/O; the rest of the game reads/mutates
through it and calls `save()` (or relies on the autosave hooks below).

```
Save.profile           -> PlayerProfile (loaded once at boot; default if absent)
Save.load_or_new()     -> populate from disk, or mint a fresh default profile
Save.save()            -> atomic write of the current profile (debounced)
Save.reset_new_game()  -> overwrite with a fresh profile (after ConfirmModal)
Save.has_save()        -> for Title's "Continue" vs "New" branch (menus.md)

# Convenience mutators that mutate + autosave (keep call sites honest):
Save.grant_car(model_id, immortal=false) -> OwnedCar
Save.wreck_car(instance_id)              # return upgrades to inventory, remove
Save.apply_damage(instance_id, amount)   # clamp at 0 -> wreck (unless immortal)
Save.add_item(item_id, n=1) / consume_item(item_id)
Save.install_upgrade(instance_id, item_id) / uninstall(...)
Save.set_tuning(instance_id, tuning)
Save.complete_rally(rally_id, combined_ms, placed)  # idempotent: sets completed once, updates best_combined_ms + best_placed; recomputes showdown_unlock. The CAR reward (RewardSystem.draw_car) fires per top-3 finish, NOT here — re-wins are farmable (reward-system.md). best_placement(id) reads back the best finish.
```

Keep `Save` **free of `GameConfig` coupling**: it stores tuning numbers, but it
is the car-fielding code (`car.gd` / the Start-line flow) that reads them and
writes the live `Config.data` (mirroring how `apply_car` already reshapes
`Config.data`, per `config.gd:13-17`).

## Autosave triggers

Save-on-change (debounced ~1s to coalesce bursts), at every point that mutates
the profile — so a crash never costs more than the last action:
- Starter picked (first run).
- After **each event**: HP change from damage, the per-event upgrade drop.
- After a **rally completes** (top-3): car reward granted, completion recorded.
- Tuning changed; upgrade installed/uninstalled; repair kit used.
- A car wrecked (and its upgrades returned to inventory).

Because the profile is written **after** each reward resolves, reloading can't
re-roll a reward (no savescum) **without** needing seeded reward RNG — call this
out so the reward system doesn't separately try to solve it.

## Web build considerations

- On the HTML5 export, `user://` lives in **IndexedDB**, which is asynchronous.
  Godot flushes on `FileAccess` close, but the browser may not have committed to
  IDB by the time a tab is closed. Mitigation: flush on `save()` and also save on
  `NOTIFICATION_WM_CLOSE_REQUEST` / `notification(NOTIFICATION_APPLICATION_PAUSED)`
  so a backgrounded mobile tab persists. **Verify round-trip in an actual web
  export, not just desktop** — this is the highest-risk area.
- Private-browsing / blocked-storage: `FileAccess.open` can fail. Degrade
  gracefully to an in-memory profile + a visible "progress won't be saved"
  notice rather than crashing.

## Versioning & migration

- Every profile carries `schema_version`. On load, if the file's version is
  **older**, run ordered migration steps up to the current version; if
  **newer** (a downgrade), refuse to load and keep the file untouched rather than
  truncating it.
- Migrations are pure `Dictionary -> Dictionary` transforms keyed by version, so
  they're unit-testable without disk I/O.

## Integrity / failure handling

- **Corrupt / unparseable JSON:** fall back to `profile.bak`; if that also
  fails, start a fresh profile and surface a non-destructive warning (never
  silently overwrite a file we couldn't read — the user may want to recover it).
- **Unknown `model_id` / `item_id`** (e.g. a car removed from `CarLibrary`):
  drop the orphaned entry on load and log it, rather than hard-failing — keeps
  old saves loadable as the roster evolves.

## Prerequisite: extend `CarLibrary` with metadata

The library **already exists** (`CarLibrary.CARS`, `car_library.gd:81+` — the 6
cars). This is an **additive metadata pass on the existing entries**, not a new
system, and it's the hard blocker for saving (the id) and for rally restrictions
+ damage. Do it first.

**Already present — reuse as-is (no new field):**
- `engine_type` (`car_library.gd:86` etc — index into `ENGINE_PRESETS`: i4/i5/i6/
  v6/v8/v10/v12) and `drive_mode` (`RWD`/`AWD`/`FWD`, `car_library.gd:65-67`) →
  two restriction tags come for free.
- `mass`, `peak_torque`, `redline` → **power-to-weight is derived, not stored**
  (a `CarLibrary.power_to_weight(entry)` helper; exact formula is a tuning
  detail — rough peak power ≈ f(`peak_torque`, `redline`), ÷ `mass`).

**New fields to add per entry:**
- **`id`** *(string, required)* — a stable key, e.g. `"mx5"`, `"rs3"`,
  `"porsche911"`, `"lfa"`, `"mustang"`, `"aventador"`. **Never reordered or
  reused.** Replaces array-index identity (`car.gd:16,253`) everywhere ownership
  is persisted.
- **`country`** *(string)* — e.g. `JP` (MX-5, LFA), `DE` (RS3, 911), `US`
  (Mustang), `IT` (Aventador). A restriction tag.
- **`car_type`** *(string)* — e.g. roadster / hatch / coupe / saloon. A
  restriction tag; values authored per car.
- **`max_hp`** *(float)* — per-car durability the damage model needs; the saved
  `OwnedCar.hp` clamps to it. Loosely keyed to `mass` (`gameplay.md` › *Damage*):
  default from a `mass`-based formula, override per car. Exact numbers are
  damage-tuning, deferred to playtesting.
- **`engine_displacement_l`** *(float, optional)* — only if rallies restrict by
  engine *size* as well as cylinder layout (MX-5 2.0, RS3 2.5, 911 3.0, LFA 4.8,
  Mustang 5.0, Aventador 6.5). Skip until a rally needs it.
- **`reward_tier`** *(int)* — the car's reward tier, used by the reward system
  (`todo/reward-system.md`) to match a draw's clamped tier. Default from a
  power-to-weight heuristic, overridable per car.

**New lookup helper:** `CarLibrary.index_of(id) -> int` (and/or `by_id(id) ->
Dictionary`), so save/load and `apply_car` resolve a stable id to the current
array position. `apply_car(index)` (`car.gd:253`) can stay index-based
internally; only the *persisted* identity becomes the id.

**Not a library field:** the **immortal** flag is per *owned instance*
(`OwnedCar.immortal`), set when a car is granted as the chosen starter — the
library only supplies `max_hp`. Which cars are the 3 starters is a roster/design
call, not metadata schema.

*Consumed by:* this save spec (id + max_hp), `todo/menus.md` (the stats panel
shows engine/drivetrain/country/type/p-w + an HP bar), the rally roster
(restriction matching), and the damage model (`max_hp`).

## Dependencies

- **CarLibrary metadata** — see *Prerequisite* above (folded into this spec):
  a stable `id` per entry is required before ownership can be saved safely. *Do
  this first.* Upgrade items likewise need stable `item_id`s (upgrade-catalogue
  todo).
- **Rally roster** (`todo/rally-roster.md`) — defines the `rally_id` space that
  `rallies` keys on, and the completion/unlock functions that read it.
- **Consumed by `todo/menus.md`** — Title's Continue/New branch (`Save.has_save()`),
  the car park (owned cars), the inventory overlay (inventory), tuning lift
  (per-car tuning + upgrade install), map (rally completion + showdown meter),
  reward reveal (grant_car / add_item). The menus spec already lists this as a
  hard dependency.
- **Relates to the damage model** (`todo/damage-model.md`) — `apply_damage` /
  `wreck_car` are where HP changes get persisted; the upgrade catalogue
  (`todo/upgrade-catalogue.md`) defines the `item_id`s inventory/installs key on.

## Testing

Headless GUT tests (`tests/headless/`, per `CLAUDE.md`):
- **Round-trip:** mint a profile, mutate via the API, `save()`, reload, assert
  deep equality.
- **Default profile:** `load_or_new()` with no file yields a valid empty profile
  (`has_save()` false).
- **Migration:** a hand-written old-version dict migrates to current shape;
  a newer-version file is refused without mutation.
- **Integrity:** truncated/garbage JSON falls back to `.bak` then to default;
  an unknown `model_id` is dropped, not fatal.
- **Wreck semantics:** wrecking returns installed upgrades to inventory and
  removes the car; the immortal starter never wrecks.
- Run against `user://` redirected to a temp dir so tests don't touch a real
  save. Add a smoke check that the `Save` autoload registers
  (`tests/headless/test_smoke.gd`).

## Out of scope / open questions

- **Encryption / tamper-resistance** — `FileAccess.open_encrypted_with_pass`
  exists, but for a single-player time-attack game plaintext JSON is probably
  fine. Decide if leaderboard integrity ever matters.
- **Timestamps:** scripts can't call `Time.get_*`/`Date.now()` in some contexts;
  decide whether `created/updated_utc` are set by the caller or dropped — they're
  cosmetic, not load-bearing.
- **Settings vs progress:** **decided — separate `settings.cfg`** (different
  lifecycle: survives "New game", device-local). Audio/graphics/control settings
  are owned by `todo/settings.md`, not this profile. Resolved.

### Decided (kept for trace)

- **Ownership model:** **instance-based** — each owned car is a unique instance
  referencing a `CarLibrary` model id, with its own HP/upgrades/tuning (supports
  duplicate models from the random-car reward).
- **File format:** **JSON at `user://profile.json`** (inspectable, migratable,
  decoupled from engine class layout).
- **Profiles:** a **single auto-saved profile**; "New game" overwrites after a
  `ConfirmModal`. Filename stays a parameter so named slots can be added later
  without reworking the API.
