# Rally Session (event-flow orchestrator)

**Source:** `scripts/rally_session.gd` — the `RallySession` autoload (registered in
`project.godot` alongside `Config`/`Save`; no `class_name`, reached by the global
`RallySession`).

The rally-level coordinator: it turns "the player picked rally R with owned car C"
into the full loop — field the car, run 3 events, accumulate times, place against
the fixed opponent field, grant rewards, finish. It sits **one level above** the
per-stage `StageManager` ([stage.md](stage.md)): `StageManager` owns one event's
countdown→run→complete; `RallySession` owns the rally and survives the per-event
scene reloads. It **calls** the systems that already exist
([rally-roster.md](rally-roster.md), [reward-system.md](reward-system.md),
[save-persistence.md](save-persistence.md), [damage.md](damage.md)) rather than
re-implementing them.

## State machine

`Phase { IDLE, PRESENCE, RUNNING, STANDINGS, RESULTS, PODIUM }`. Idle until
`start_rally`; each `report_*` advances it; `_resolve_results` returns it to IDLE.

| Field | Meaning |
|-------|---------|
| `_rally` | the RallyDef being run (`{}` when IDLE) |
| `_car_instance_id` | the fielded OwnedCar instance |
| `_event_index` | 0..2 |
| `_event_times_ms` | accumulated event times, one per completed event |
| `_opponent_field` | fixed per rally seed (`RallyLibrary.generate_opponent_field`) |
| `_dnf` | set on a wreck |

## API

| Call | Effect |
|------|--------|
| `start_rally(rally, owned_car, event_targets_ms := [])` | seed state, build the opponent field, kick event 0. Targets are derived from each event's track when omitted; tests pass them in to skip generation. |
| `report_event_result(elapsed_ms, hp_lost)` | accumulate the time, persist chip damage (`Save.apply_damage`), draw **one upgrade for a non-final event** (events before the last, via `RewardSystem.draw_upgrade(Save.profile, rng, owned_car)` — note there is no `rally_difficulty` param any more). The draw may return `RewardSystem.NO_REWARD` (`""`) — a maxed-out car can legitimately win nothing. On a real id: a consumable goes to inventory, everything else is `Save.install_upgrade`'d **disabled** — except the `UpgradeLibrary.HIDDEN_SLOTS` (`"nitrous"`) slot, installed **enabled** because it has no garage row to switch on (see [nitrous.md](nitrous.md)) — appends to `_upgrades_won`, and emits `upgrade_revealed`. On `NO_REWARD` nothing installs, nothing is recorded, and no reveal fires — the flow runs straight on. Either way the rally then always **enters `STANDINGS`** and emits `standings_ready` — every event pauses on the interstitial, including the last. "Every event always awards something" no longer holds. |
| `current_event_upgrade()` | the upgrade id won for the just-completed non-final event (`""` after the final event / before any draw). Read by the standings reveal (`features/reward-system.md`). |
| `continue_to_next_event()` | resume from the between-event standings interstitial: enters the next event, or — once `_event_index >= stage_count()` (the final event — the rally's OWN authored event count, which is 1 for an opening rally; `EVENTS_PER_RALLY` is only the fallback) — calls `_resolve_results()` (→ podium) instead. |
| `current_standings()` | the leaderboard AS OF the events completed so far (each rival's + the player's cumulative time **and the car each drove**, ranked via `build_standings`); read by the standings scene's OVERALL section. `events_completed()` gives the count for its header. |
| `current_event_standings()` | the leaderboard for the **JUST-COMPLETED event alone**: each racer's time for that one event, fastest first (a rival who DNF'd that event sinks to the bottom). The row's `combined_ms` field carries the single-event time, not a cumulative sum. Empty before any event completes. Read by the standings scene's STAGE n RESULT section, AND by `GlobalStandings.for_current_stage()` — the player's row here already carries the corrected car name/id (next row), so the local and [global](global-leaderboards.md) boards can never disagree about what the player was driving. |
| `_player_car_name()` (private) | the player's own row's `car_name` in both boards above — `EngineSwap.display_name(CarLibrary.by_id(_car_model_id), Save.get_car(_car_instance_id))`, i.e. the car's catalogue name **prefixed with its current engine swap** if it isn't running its stock engine (see [engine-swap.md](engine-swap.md)'s `display_name`). Previously read the bare model name with no swap prefix; corrected as part of the global-leaderboards work since the same string now also gets posted to the world leaderboard. `""` when no car is fielded or the model id resolves to nothing (e.g. headless tests). |
| `current_event_leaders(n := 3)` | the top `n` rivals for the CURRENT event — each rival's time for this event, fastest first, with the car they drove (`{name, car_id, car_name, time_ms}`); DNF-this-event omitted. Drives the [start-line](start-line.md) reveal: the top three line up on the grid in their **actual cars** (spawned from `car_id`), each shown by name with its time to beat. |
| `report_wreck()` | DNF: wreck the instance (`Save.wreck_car` — leaves it owned at 0 HP, repairable, **not** destroyed), skip remaining events, resolve. Any per-event upgrades already earned this rally are **kept**; a DNF earns **no stars** (the star credit only fires on a top-3 finish). Only valid while `RUNNING` (you can't wreck on the standings screen). In real play the run scene shows a **wreck menu** first (`scripts/wreck_screen.gd`) and calls this on *Return to HQ*. |
| `abandon()` | end back at HQ, rally incomplete, no reward (Pause overlay; no retry). |
| `dev_complete_rally()` | **DEV shortcut** (settings dev page, surfaced only while active): credit every event a perfect **0 ms** time, force `_event_index = stage_count()`, and `_resolve_results()` straight to the podium. A 0 ms combined out-runs the field → **P1** (top-3), so the finish records completion and credits its stars. No-op when `IDLE`. The settings host unfreezes the tree before calling it (the page is reached from the paused in-run overlay). |

Signals: `rally_finished(result)`, `phase_changed(phase)`, `event_started(i,
event)`, `standings_ready(i)`, `upgrade_revealed(item_id)`,
`car_rewarded(model_id)`, `game_won()`.

`last_result()` (the podium reads it) returns the finish dict — the base
`{placed, completed, combined_ms, dnf}` plus, for the reveal/standings:
`rally_id`, `rally_name`, `standings` (the full ranked field +
player via `RallyLibrary.build_standings`, each entry carrying `car_id` so the
podium can spawn the top-3 cars), `upgrades` (the per-event ids won this rally —
recorded here, but revealed earlier on the standings screens, not the podium),
`star_rating` (int 0–3 — what this rally is worth at the player's BEST-ever
placement, i.e. how many of the podium's three stars light up) and
`stars_gained` (int — what the ledger actually moved by, `0` on a re-win that
didn't beat the previous best; the two are deliberately separate numbers, see
below), `car_reward` (model id — the car a PRIZE RALLY just handed over, `""` for every
other rally and for a re-win) with `car_reward_is_new`, and `game_won` (bool —
renamed from `showdown_won`). The `car_rewarded(model_id)` signal fires with it.

### One-shot navigation flags

Three, all set by the finish and all read + cleared by HQ on its next `_ready`
(none is part of the result dict). HQ resolves them in this priority:

1. `pending_car_reveal_instance_id` (int, `-1` when none) — a car was WON, so HQ
   opens on the **present box** and holds the player there until they open it
   (`hq.gd::_enter_present_box`). The car is granted *before* this is set, so
   quitting mid-reveal costs only the animation.
2. `return_to_map` (bool) — the finished rally was the player's OPENING rally, so
   HQ opens on the **map table** with the reveal parade armed. That arrival is the
   whole point of the opening run (see [map-exploration.md](map-exploration.md)).
3. `return_to_garage` (bool) — the podium's final Continue: boot to the **garage**
   rather than the exterior title.

## Results & rewards

On resolve: `combined = sum(event_times)`, `placed =
RallyLibrary.placement(field, combined)`. A **top-3, non-DNF** finish records
completion + best placement — as does the player's **opening rally on its first
attempt**, whatever the result, DNF included (the one place `completed` diverges
from "podiumed"; placement still decides the stars, and the carve-out lives at
the call site rather than as a flag on `complete_rally`. See
[../todo/opening-rally.md](../todo/opening-rally.md)) (`Save.complete_rally(id, combined, placed)` —
idempotent for the `completed` flag, and its RETURN VALUE is the number of stars
it credited to the persisted ledger, see [star-economy.md](star-economy.md)).
That credit is only the **improvement** over the rally's previous best, so a
re-win at an equal or worse placement pays nothing and an easy rally can't be
farmed for stars. `star_rating` is then read back from
`RallyLibrary.stars_for_placement(Save.best_placement(id))` — still the single
definition of what a placement is worth — and both numbers ride out on the result
for the podium's stars beat.

**No car is drawn here, for any rally.** Winning pays STARS, and cars are BOUGHT
with them at the HQ present box (`RewardSystem.purchase_car`). The old guaranteed
car per top-3 (and it fired on re-wins too) filled the garage with something for
every class within a handful of rallies, after which the per-rally `restriction`
bands stopped excluding the player from anything; the only free car left is the
wreck safety net (`Save.ensure_wreck_safety_net` → `Save.open_mystery_box`),
which must stay free because it's the anti-soft-lock path.

A top-3 also fires, where applicable: the **special-unlock** reveal on a
special's FIRST win (`UpgradeLibrary.unlocked_by`, handed to the driven car via
`RewardSystem.grant_special_unlock`; the engine-swap rung gates a capability
rather than a catalogue part, so it announces that plus one swap token), and the
**win beat** (`game_won`) once THIS finish makes
`RallyLibrary.is_special(_rally) and RallyLibrary.all_specials_completed(Save.profile)`
true — i.e. every special event is now won, checked after this rally's completion
is recorded so the last special to fall counts itself. There is no designated
final region any more (`RegionLibrary.all_showdowns_completed` is gone). Specials
DO now award stars, where they used to award none: that exclusion only existed
because specials once *gated* on a star total, and paying them out would have fed
their own gate. They gate on completed ORDINARY rallies now
(`RallyLibrary.completions_required` / `completions_needed`), so the exclusion is
no longer needed — see [rally-roster.md](rally-roster.md) for the special ladder
and [regions.md](regions.md) for the region look, which no longer gates anything.
Non-top-3 / DNF credits **no stars**
and leaves the rally incomplete (**no retry** — re-enter from the map later;
damage and the opponent field persist). Upgrades are **not** granted here —
they're awarded per non-final event in `report_event_result` (above) and kept
regardless of the final result.

## Scene transitions

In real play (`auto_load_scenes = true`) each event writes its
`(seed, turn_count, width, water_level, …)` into `Config.data` and reloads
`main.tscn`. After EVERY event — including the last — `report_event_result` emits
`standings_ready` and waits at `Phase.STANDINGS`.

**Between-event pit repairs.** `_enter_event()` runs at the start of every event
(via `start_rally` for the first, `continue_to_next_event` for the rest). For every
event AFTER the first (`_event_index >= 1`) with a fielded car, it calls
`Save.field_repair(instance_id, field_repair_hp_fraction, field_repair_toe_fraction)`
BEFORE the scene reload — restoring a slice of the lost HP and bending the bent wheels
part-way back toward straight (see [damage.md](damage.md) → *Between-event pit
repairs*). Because the OwnedCar is mutated before the reload, `world.gd` fields the
already-repaired car. The repair summary is stashed on the session and read once via
`take_pending_repair()` (cleared on read + on `start_rally`, so a pause→reset can't
replay it); `world.gd` renders it as a `RepairReveal` popup before the start line.
Both `_enter_event()` and `_resolve_results()` apply the repair through the same
private `_apply_field_repair()` helper, so the two call sites can't drift on which
fractions they use.

**Final-event repair.** The between-event repair above only ever fires going INTO
an event, so damage from the LAST event of a rally previously got no repair at all —
`_resolve_results()` (reached from `continue_to_next_event()` after the final event,
`report_wreck()`, or `dev_complete_rally()`) now also calls `_apply_field_repair()`
for the just-raced car, with the same `field_repair_hp_fraction`/
`field_repair_toe_fraction` fractions. Unlike the between-event case, this repair is
applied silently — its summary is discarded rather than stashed for
`take_pending_repair()`, so it doesn't compete with the podium/reward-reveal flow's
own UI.

The config write is `apply_event_config(cfg, event)` — a static, scene-free seam
(extracted from `_load_event_scene` so its fallback semantics are directly
testable). **Every field an event may omit resolves to the AUTHORED baseline**
(the pristine cached `.tres`; `Config.data` is a duplicate of it), *not* the
current `cfg` value. This matters because `Config.data` is a persistent session
working copy that is never reset between events — a cfg-value fallback would let
one event's override (`water_level`, a `terrain_layer*` key, …) leak into a later
event that omits the key. Overridable per-event keys include `water_enabled`,
`water_level`, and the 6 hill-shape keys `terrain_layer{1,2,3}_{wavelength,amplitude}`
(see [terrain.md](terrain.md)). It also seats `cfg.weather` from
`RallyLibrary.event_weather(event)` — **the one funnel** by which a stage's condition
reaches the live config, and the same baseline-fallback rule is what leaves a
session-less caller (free roam, benchmark, dev boot) dry automatically rather than
inheriting the last event's weather (see [weather.md](weather.md)).

**Target-time derivation and lakes.** `_generate_event_tracks` derives rival times
by generating each event's track via `TrackGenParams.for_event(event, cfg)` — the
same factory `world.gd` uses for the real run. This matters because water avoidance
makes the shape depend on the world origin, so both sites must share the factory or
opponent times desync (see [lakes.md](lakes.md) → *shape-determinism invariant*).
`_load_event_scene` also copies the event's `water_enabled` / `water_level` into
`Config.data` for the run scene.

**Standings presentation is now an in-world overlay, not a scene swap.**
`world.gd` connects `standings_ready` to `_present_standings_overlay`, which — for a
real (non-headless) run — keeps the just-finished run scene alive, drops in a
cinematic replay of the event just driven, and shows `standings.tscn` as a transparent
`CanvasLayer` overlay on top of it (`standings.gd`'s `overlay_mode = true`). See
[event-replay.md](event-replay.md) for the recorder/camera/playback mechanics. To make
room for this, `world.gd` sets `RallySession.standings_overlay_host = true` on setup
(false under headless), and `_load_standings_scene()` — the method that would otherwise
`change_scene_to_file("res://standings.tscn")` — becomes a **no-op** whenever that flag
is set, since the host already owns showing the panel. Headless tests never set the
flag, so `_load_standings_scene()` behaves exactly as before there (in practice it never
fires anyway — `auto_load_scenes` is false and tests call `continue_to_next_event()`
directly).

Every event — **including the final one** — shows the standings screen, which stacks
BOTH leaderboards on one page (the just-finished stage's times, then the cumulative
standings) before anything else happens; the final event's page still carries the same
single Continue button, but pressing it resolves the rally instead. Continue calls
`continue_to_next_event()`: for a non-final event this loads the next event; for
the final event it instead resolves the rally (`_resolve_results` → `PODIUM`) and
emits `rally_finished`. In overlay mode the **live host** (`world.gd`) owns the
`rally_finished` → podium transition (the run scene is still alive); in the older flat
mode the standings scene itself connects `rally_finished` and changes to `podium.tscn`
on that signal, since the run scene is already gone by then. Headless
tests set `auto_load_scenes = false`, drive `report_*` directly, and call
`continue_to_next_event()` to step past the standings pause (no scenes load).

### Leaderboard reveal

Both leaderboard displays — the between-event standings interstitial (`standings.gd`
`_build_ui`) and the post-rally podium RESULTS stage (`podium.gd`
`_show_leaderboard`) — fill in **one name at a time from P1 downward**. Rows are
built up front but hidden, then a `_reveal_standings()` coroutine unhides them P1,
P2, P3… one every `REVEAL_STEP` seconds, so the list starts empty and reveals
dramatically. The standings screen reveals its section HEADINGS in the same
sequence, so its two stacked leaderboards fill top-to-bottom as one run; it uses a
shorter step than the podium because it has roughly twice as many lines. A
`_reveal_gen` counter guards each run: leaving the podium stage or rebuilding the
standings UI (the overlay's show/hide toggle) mid-reveal abandons the stale
coroutine without touching freed rows. The podium gates its **Next** button (`_reveal_done`)
until the reveal completes. Under headless (`Platform.is_headless()`) the animation
is skipped — every row shows immediately — so tests see the fully-populated list.

The podium's **stars beat** (`Stage.STARS`, straight after LEADERBOARD) animates
the same way and under the same `_reveal_gen` guard: `podium.gd` `_reveal_stars`
fills a big `StarRow` gold one star per `REVEAL_STEP` up to `star_rating`, with
`_stars_caption` showing the ledger delta (`stars_gained`) plus the spendable
balance from `Save.stars_available()` underneath — no "x of N" denominator, since
the total is a wallet now, not a completion score. The beat ALWAYS runs, including
on a DNF or a non-podium finish: three dim stars is honest feedback about the miss,
whereas skipping the stage would make a zero-star result look like a bug.

## Run-scene wiring

The **run-scene fielding + signal wiring** is in place ([menus.md](menus.md)):
`world.gd` configures the car from the fielded OwnedCar via the
upgrade/tuning/damage pipeline and routes `StageManager.stage_completed` to
`report_event_result`; a car `wrecked` builds the **`WreckScreen`** whose *Return to
HQ* button calls `report_wreck` (headless skips the cinematic and reports at once).
The placeholder HQ calls
`start_rally`, so the loop runs end-to-end. The **diegetic presentation** around
it (standings / podium / reward-reveal staging, `standings_ready` etc.) is the
deferred full menus build — RallySession already emits the signals it hooks.

## Opponent target times (turn cache)

`_generate_event_tracks` derives each event's opponent times from its generated
track. It now resolves params through `RallySession.canonical_event_config(event)`
(a fresh authored-base config with the event's overrides applied) and generates via
`TrackGenerator.generate_cached`, so the times come from the committed turn lockfile
(`data/track_cache.json`) instead of running the DFS 3× per rally. Using
`canonical_event_config` also fixes a prior desync: the old code read the shared
`Config.data` *without* the per-event terrain overrides, so terrain-override events
could derive times against a different shape than the run scene generated. See
[track.md](track.md) → *Turn cache* and
`docs/superpowers/specs/2026-07-21-track-turn-cache-design.md`.

## Opponent field cache

The whole opponent field (`generate_opponent_field` — names, cars, per-event times,
wrecks, DNF) is deterministic (rally-seeded RNG + `LapTimeModel.optimum_ms` over the
cached tracks, no player input), so it is **precomputed and committed** to
`data/opponent_cache.json` (`scripts/opponent_cache.gd` → `OpponentCache`). `start_rally`
now does `OpponentCache.lookup(rally)` and only falls back to live
`generate_opponent_field` on a miss (editor warns / export errors, never crashes) —
removing ~30–45 lap-time sims from every `start_rally`.

- **Key:** `rally_id | rally_content_fingerprint | global_fingerprint`.
  `rally_content_fingerprint` = `str(rally).sha256` (captures `difficulty` → pace band,
  `restriction` → eligible pool, per-event `surface_mix` → grip — none of which are
  track-*shape* determinants). `global_fingerprint` folds the track lockfile's
  committed `source_hash`, the car/engine catalogue (incl. `CarLibrary.TORQUE_POWER_FALLOFF`),
  the authored-base grip (`gravel_grip`/`tarmac_grip` from `Config.CONFIG_PATH`), the
  field-gen constants + `RIVAL_NAMES`, and `OpponentCache.CACHE_VERSION` (bump only for
  `LapTimeModel` physics / field-assembly algorithm changes).
- **Field entry shape** (one dict per rival, as `generate_opponent_field` produces and
  `deserialize_field` restores): `name`, `car_id`, `engine_id`, `car_name`,
  `event_times_ms`, `dnf`, `combined_ms`, `wreck_event`, `wreck_progress`,
  `wreck_side`. `engine_id` + the layout-prefixed `car_name` come from the rival engine
  swaps (see [rally-roster.md](rally-roster.md) → *Rival builds*).
- **`deserialize_field` is a WHITELIST.** It rebuilds each rival field-by-field (to
  restore int/bool types JSON flattens to floats), so **any field not listed there is
  silently dropped on the way out of the cache** and silently defaults downstream —
  with a live-generation fallback masking it in the editor. Adding a field to a rival
  means adding it to `deserialize_field` in the same change.
- **`CACHE_VERSION` is `"2"`** — bumped from `"1"` for the rival engine swaps. The
  auto-folded fingerprint covers `EngineLibrary.ENGINES` *data* but not generator
  *logic*, and here both the entry shape (a new `engine_id`) and the **rng draw order**
  changed, so identical inputs now yield a different field. Hence the manual bump: it
  re-keys and therefore re-rolls **every** rally's field.
- **Depends on the track cache** — regenerate tracks first. `./cache_all.sh` runs
  `cache_tracks.sh` then `cache_opponents.sh` in order; `./cache_opponents.sh` alone
  regenerates just this file. A car/rally/grip/physics retune requires a regen — as
  does a `CACHE_VERSION` bump, so the rival-engine-swap change requires re-baking
  `data/opponent_cache.json` via `./cache_opponents.sh` or CI fails the freshness
  check.
- **Validation:** `tools/verify_opponent_cache.tscn` (a `source_hash` over the sorted
  per-rally keys) gates CI alongside the track verifier; `test_opponent_cache.gd`
  runs the same freshness check locally.


**Fingerprint memoisation.** `OpponentCache.global_fingerprint()` used to re-parse the
full 248 KB `data/track_cache.json`, `load()` the config resource and SHA-256 the whole
car + engine catalogue on **every** `lookup()` — i.e. once per rally start, likely
50-150 ms of a menu transition on wasm. It is now memoised, keyed on the modified-times
of the lockfile and the config resource, so an in-process rewrite invalidates it
automatically. `OpponentCache.reset_cache()` / `TrackCache.reset_source_hash_cache()` are
the explicit invalidation seams (both are called from the existing `reset()` paths).

## Tests

`tests/headless/test_rally_session.gd` — happy path + placement, the per-rally
per-event upgrade grants (one per non-final event, fitted disabled, no slottable
duplicate; `current_event_upgrade`; the final event awards none), wreck DNF (the
earned upgrade is kept, instance wrecked), no-retry re-entry (state reset, field
fixed), the `game_won` beat, farming re-win, the between-event pit repair (fires
entering every event after the first, never the first, summary consumed once),
idle-at-rest. The `RepairReveal` popup wiring is covered by
`tests/headless/test_repair_reveal.gd`.
