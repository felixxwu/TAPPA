# Rally Roster

`RallyLibrary` (`scripts/rally_library.gd`, `class_name RallyLibrary`) is the
finite, curated list of rallies — authored **content**, like `CarLibrary`. Since
the roguelike pivot (`todo/roguelike-pivot.md`) its live job has shrunk to one
thing: **`RALLIES[*].events` is the region stage pool.** `RegionStagePool`
(`scripts/region_stage_pool.gd`, see [region-runs.md](region-runs.md)) flattens
every rally tagged with a region into that region's pool of drawable stages, and
a run draws 8 of them. Everything else this file used to carry — the rival
field, the world map, categorical eligibility, prize rallies, the star curve —
is deleted or dead (see "Dead code awaiting demolition" below).

**Tests:** `tests/headless/test_rally_library.gd`, `tests/headless/test_catalogue_seam.gd`

## What a `RALLIES` entry still authors that matters

Each entry is a `{id, name, region, difficulty, events}` group (plus dead fields
covered below). What a **drawn stage** actually reads:

- `id` — a stable authoring key. No longer a save key for anything live
  (`Save.record_podium_rally` has no live caller any more — see below), but keep
  it stable anyway; `RegionStagePool` copies it onto each drawn stage as
  `rally_id` for debugging.
- `region` — which `RegionLibrary` entry's look, waterline and (for `snow`)
  handling this rally's stages use. `RegionStagePool.events_in` copies it onto
  every drawn stage — **load-bearing**, since `StageConfig.apply_event_config`
  resolves the per-region overrides off it. See [regions.md](regions.md).
- `difficulty` — a hidden authoring tier. `RegionStagePool.draw` sorts the drawn
  8 by it (easiest first, so stage 8 of a run is the hardest drawn), with the
  authored seed as a tie-break for determinism. No longer feeds a reward tier or
  a field-pace band — those were rival-field concepts and are gone.
- `events` — an array of `EventDef`s, each
  `{seed, turn_count, width?, forestiness?, surface_mix?, straightness?,
  cliffiness?, weather?, water_level?, terrain_layer1_amplitude?,
  target_ms_override?}`. **A rally is no longer a fixed "3 events" unit** — the
  three-event wrapper was a career-rally concept; `RegionStagePool` flattens
  every event in every rally's `events` array into one flat per-region pool, so
  a rally with 1 event contributes 1 stage and one with 3 contributes 3
  (`shakedown`, `hm_timber_trophy`, `hm_forest_gt` still carry 1 apiece — see
  [region-runs.md](region-runs.md) → "The stage draw"). Per-field authoring
  rules, still live because a stage is still generated from these fields via
  `TrackGenParams.for_event` / `StageConfig.apply_event_config`:
  - `seed`/`turn_count`/`width` feed `TrackGenerator.generate` unchanged.
    **Never nudge these on a shipped event** — every authored `(seed,
    turn_count)` pair is hand-verified to route and baked into
    `data/track_cache.json`; changing either misses the lockfile and hands the
    player a combination nothing has exercised.
  - `forestiness` (0–1, default 1.0) sets how wooded the stage reads — trees
    spawn only where forest noise clears `1 - forestiness`. See
    [trees.md](trees.md).
  - `straightness` (0–1, default 0.0) biases generation toward gentler corners
    and longer straights.
  - `cliffiness` (0–1, default 0.0) sets the cliff/drop height ceiling beside
    the road, without touching the lengthwise profile the car climbs — the
    lever to reach for when a region needs to read as dramatic without being
    unclimbable (see the Alps note below).
  - `weather` — a `WeatherLibrary` condition id via `event_weather`: `"dry"`
    (default), `"rain"`, `"sandstorm"`, `"fog"`, `"storm"`, `"snow"`, `"night"`.
    Authored per TERRAIN ZONE, not per region name — sandstorm only on desert
    events, storm on exposed coastal/northern events, fog in temperate forest,
    snow only in the Alps. `test_every_multi_stage_rally_mixes_weather` still
    enforces that a multi-event rally doesn't run one condition end to end. See
    [weather.md](weather.md).
  - `water_level` (authored on every event) — resolution is
    `event → region → GameConfig baseline` (`TrackGenParams.resolve_water_level`),
    so pin it even though the region supplies a baseline: it lets the waterline
    vary by what a particular event sits next to. A coastal waterline (-4/-5)
    must pair with `terrain_layer1_amplitude >= 16.0` or a high sea over low
    relief floods the track.
  - `terrain_layer1_amplitude` (authored on every event) — follows the terrain
    ZONE, not latitude: foothills hilliest (~34–44), forest/quarry country
    middle (~26–40), river plain/shore lower (~16–26), desert flats flattest
    (~12–19). **The Alps break this on purpose** (~14–18, the flattest band on
    the map, under the highest ground) because relief and grip multiply — a
    climb costs a fixed `G·sin(θ)` out of a drive budget the region's low snow
    grip has already shrunk, and the corner's original ~34–52 amplitude put
    pitches above what a 2WD car can climb at snow grip at all. Altitude there
    is carried by `cliffiness` instead. See
    [snow-region.md](snow-region.md) → "Relief: deliberately gentle".

## LapTimeModel (`scripts/lap_time_model.gd`)

A pure-static quasi-steady-state (QSS) lap-time model — no scene nodes, no
randomness — computing a car's physics-optimal velocity profile over a track
centerline. **Still fully live**, but its one caller now is the run's clock,
not a rival field: `RegionRunMode.stage_target_ms` (see
[region-runs.md](region-runs.md) → "The timer") solves it against
`CarPerformance.REFERENCE_CAR`, once per stage, rather than once per rival.

- `optimum_profile(track_result, car_meta, event := {}) -> {s, v, t, total_ms}` —
  a three-pass velocity sweep: cornering ceiling (`v² = µg/(κ − µ·D/m)`,
  clamped at `V_CAP_MAX_MS`), a power/friction-circle/traction-limited forward
  pass, and a friction-circle-limited backward braking pass. The friction
  circle grows with speed under downforce (`µ(g + D·v²/m)`), applied
  identically in all three passes.
  - **Road gradient.** The model is a 2D point mass with no elevation of its
    own; a caller that wants hills seats a height sampler as `road_height`
    (`TerrainNoise.make_sampler`) on the track result. `world.gd` attaches it
    after generation, right before handing the track to `RunSession.set_stage_track`
    (see [region-runs.md](region-runs.md) → "Where the target is seated") — both
    the clock and the terrain the player drives have to agree, or the target and
    the road disagree. Without a sampler the term is an exact no-op.
  - Grip `µ` blends front/rear tyre grip via the event's surface mix
    (`GameConfig.gravel_grip`/`tarmac_grip`), scaled by `GameConfig.rain_grip_mult`
    when wet (`_surface_grip`), and — on a `snow`-region event —
    `RegionLibrary.surface_grip_of`'s per-surface overrides
    (see [snow-region.md](snow-region.md)).
  - **Still not modelled:** brake torque/bias, gearbox ratios, shift time,
    turbo lag, suspension, weight distribution, tyre width.
- `optimum_ms(track_result, car_meta, event) -> int` — convenience wrapper
  returning only `total_ms`. This is what `RegionRunMode.stage_target_ms` calls.
- `derive_target_ms`/`derive_turn_splits` also call into this model.
  `derive_turn_splits` is the per-turn cumulative split table (was used for the
  now-deleted in-run "vs P1" pace popup and rival ghost — see "Dead code"
  below); its own tests (`test_turn_splits_*`) still cover it as pure track math
  and remain valid regardless.

`RallyLibrary.GHOST_SOLVABLE_PACE` no longer exists — the rival ghost it bounded
is deleted. If you find a doc or comment still citing it (`region-runs.md`
does, at the time of writing), that citation is stale; it should read
`todo/roguelike-pivot.md`'s tuning note instead, which makes the same "the
optimum is a reference, not a bound" point without the dead symbol.

## Key functions still in active use

- `all()` / `override_for_test()` / `reset()` / `index_of(id)` / `by_id(id)` —
  the catalogue seam, same pattern as `CarLibrary`/`EngineLibrary`. Never pin
  the shipped roster's ids/values in a logic test — build a synthetic override.
- `event_width` / `event_forestiness` / `event_tarmac_fraction` /
  `event_straightness` / `event_cliffiness` / `event_weather` / `event_is_wet` —
  per-event field lookups with defaults, read by `TrackGenParams`/`StageConfig`/
  foliage/weather.
- `derive_turn_splits` / `_time_at_offset` — pure track-split math (see above).

## Dead code awaiting demolition

`todo/roguelike-pivot.md`'s "What gets deleted" list calls for removing the
rival field, the overworld map/reveal geometry, categorical eligibility, and
prize rallies. **The RALLIES-side rival machinery is gone** (`generate_opponent_field`,
`_eligible_combos`, `_draw_distinct_combos`, `swap_weight`, `RIVAL_NAMES`, the
`PACE_*`/`FIELD_*` consts, tyre mirroring, build levels — all deleted along
with the career session, `rival_pace.gd` and `ai_difficulty.gd`, per decision 5). But
a second cluster — the world **map**, and everything that reads restriction/
special/`map_pos` fields — is still physically present in this file and in the
roster's data, **unreachable from any live screen, and not yet deleted**. The
stage 2b commit (`633c244`) that removed prize rallies explains why it stopped
short: fully deleting `prize_car_id` "would have required gutting
`opening_rally_id_for`, `hq_map_pos`, `lit_sources` and `reveal_depths` —
map-reveal geometry belonging to a different deletion item." That item has not
landed as of this writing.

**What's dead, and how you can tell:** `hq_map_table.gd`, `hq_table.gd`,
`map_fog.gd`, `reward_system.gd`, `rally_trophy.gd`, `map_table.gd` and
`ai_difficulty.gd`/`rival_pace.gd` are already gone, so nothing calls into the
map/eligibility/prize/reward functions below for a real reason any more:

- **Map/reveal geometry**: `map_pos` (still authored per rally), `rally_revealed`,
  `position_revealed`, `position_lit_by`, `lit_sources`, `reveal_link_pairs`,
  `distance_beyond_frontier`, `reveal_depths`, `nearest_locked_special_id`,
  `suggest_map_pos`, `map_pos_is_free`, `hq_map_pos`, `reveal_radius_of`,
  `MIN_PIN_SEPARATION`. `save_manager.gd` still calls `RallyLibrary.rally_revealed`
  from `_backfill_rally_revealed_seen`-adjacent code (see its own comments around
  line 1187–1206) and `RegionLibrary`/`settings_menu.gd` still call
  `all_specials_completed`/`nearest_locked_special_id` for a credits trigger that
  decision 45 explicitly says must be *removed*, not left "on a predicate that
  can never be true." **`scripts/rally_detail.gd` (453 lines) is a whole
  screen-logic script for this dead map** — it still exists, is still tested
  (`tests/headless/test_rally_detail.gd`), and is not reachable from anywhere:
  no code creates a `rally_detail` node or scene any more (`hq_table.gd`, its
  only caller, is gone).
- **Categorical eligibility**: `restriction`, `is_eligible`,
  `ineligibility_reason`, `incomplete_rallies_enterable_by`,
  `eligible_car_indices`. **Effectively neutered rather than truly dead**:
  `start_line.gd` still calls `RallyLibrary.ineligibility_reason(_rally, meta)`,
  but `world.gd._build_start_line` only ever hands it a synthesized
  `{"name": ...}` dict with no `restriction` key (`RunSession` stage dicts carry
  no restriction — see [region-runs.md](region-runs.md)), so the call is a
  permanent no-op in the current build, not a load-bearing gate.
- **Prize rallies / rewards**: `prize_car_id` (stub, always returns `""` since
  no `RALLIES` entry authors a `prize_car` field any more — see above),
  `opening_rally_id_for` (always `""` in consequence), `podium_count`,
  `completed_count`, `rally_completed`. `Save.record_podium_rally` — the only
  writer of the per-rally completion bookkeeping these read — has **no live
  caller** any more (only a dev-cheat helper in `save_manager.gd`); it is dead
  weight kept alive by nothing but its own file.
- **The Alps/rally-detail sections and the "Early game: each starter opens in
  its own rally" content this file used to carry in detail** were about prize
  rallies and are removed from this doc rather than kept and marked stale —
  see [snow-region.md](snow-region.md) for the Alps' still-live content
  (grip, deep snow, frozen lakes) and `todo/roguelike-pivot.md` decision 28 for
  what replaced the starter-picker/opening-rally flow (a money-funded car shop,
  not yet built).

None of this is yours to fix if you're a docs-only pass — it's tracked in
`todo/roguelike-pivot.md`'s "What gets deleted" (the overworld map + prize
rallies items) and decision 45 (the credits-trigger removal). Report it, don't
patch around it, unless you're the agent whose scope is that demolition stage.

**A related, more urgent finding for whoever reads this next**: the between-stage
interstitial (`world.gd._present_standings_overlay`) loads a scene that no
longer exists on disk — a live crash risk on every non-headless stage clear.
Full detail in [rally-challenge.md](rally-challenge.md) → "Known bug: the
between-stage interstitial loads a deleted scene", since that's the doc whose
subject this is; flagged here too only because this pass found it while reading
the roster's consumers.

## Tests

`tests/headless/test_rally_library.gd` — roster validity (unique ids, every rally
has at least one event, a known `region`), per-event field defaults
(`event_forestiness`/`event_tarmac_fraction`/`event_straightness`/
`event_cliffiness`/`event_weather`/`event_is_wet`), the weather-mix guard
(`test_every_multi_stage_rally_mixes_weather`), track-gen determinism, and the
turn-split math (`test_turn_splits_*`) — all still exercising **live** code.

The same file also still runs a large block of tests against the **dead**
map/reveal/eligibility machinery documented above: the geometric reveal
predicate (`test_a_rally_inside_the_opening_rallys_circle_is_revealed_from_the_start`
and its siblings), `map_pos` well-formedness and `suggest_map_pos`/
`map_pos_is_free`, every categorical `restriction` case (`test_drive_mode_restriction_filters`,
`test_country_restriction_filters`, `test_doors_restriction_filters`, the
engine-derived-restriction cases), the anti-soft-lock/enterable-query tests, and
`test_podium_count_tracks_profile`. Per `CLAUDE.md` decision 38 ("Test triage:
delete dead, fix incidental. Tests whose subject is deleted … go"), these are
exactly the tests that should be deleted once the map/eligibility demolition
above actually lands — they are not wrong today (the code they pin still
compiles and behaves as asserted), they are testing a subsystem nothing live
calls any more. Left as-is here rather than trimmed by this docs-only pass,
per this task's own scope.

`tests/headless/test_catalogue_seam.gd` — the `override_for_test`/`reset` seam
for `CarLibrary`/`EngineLibrary`/`RallyLibrary` together; generic, not
roster-specific.

Per `CLAUDE.md`, the roster's authored numbers (turn counts, `difficulty`,
weather/terrain assignments) are tunable content, not test-pinned contracts.
