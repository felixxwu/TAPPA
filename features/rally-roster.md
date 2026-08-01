# Rally Roster

`RallyLibrary` (`scripts/rally_library.gd`, `class_name RallyLibrary`) is the
finite, curated list of rallies — authored **content** (like `CarLibrary`), not
player state. It holds `const RALLIES: Array[Dictionary]` plus the pure functions
the rest of the game runs over it. Player completion lives in the save profile
(`Save`, `features/save-persistence.md`), keyed by the stable rally `id` here.

## What a rally is

Each `RALLIES` entry:

- `id` — stable key the save's `rallies` map keys on.
- `name` — display name (map-pin label).
- `difficulty` — a **hidden** tier; drives reward tier (clamped by progress) and
  sort order. It is **never shown to the player** (no "Difficulty: N" / "TIER N" in
  the detail panel, car-park banner, or finish arch) — the power-to-weight gate is
  the only visible requirement.
- `showdown` — the region's locked finale. **At most one per region**, and exactly
  one in any region that holds rallies at all; a region authored with no rallies (the
  snow corner ships as terrain with no pins) has none, which
  `RegionLibrary.showdown_unlocked` explicitly supports via its empty-corner guard.
- `restriction` — a `Dictionary`; **empty = open-class** (every car eligible).
  Otherwise every present field must match the car's CarLibrary metadata:
  `drive_mode`, `country`, `car_type`, `doors_min`/`doors_max` (vs the car's `doors`),
  `engine_min_l`/`engine_max_l` and `cylinders_min`/`cylinders_max` (both **resolved
  through the car's CURRENT engine** — see "Engine-derived restrictions" below), and a
  **power-to-weight band** `pw_min`..`pw_max` (vs
  `CarLibrary.power_to_weight`, derived from the referenced `EngineLibrary` engine's
  torque + redline (× the global `TORQUE_POWER_FALLOFF` calibration, boosted torque
  for turbos via `effective_meta`), so the gate compares against the same hp/tonne
  shown on the stats panels — within ~±8% of the cars' real published figures —
  see [engine-and-transmission.md](engine-and-transmission.md)). Both band edges are
  **authored in hp/tonne** — the same unit shown on every player-facing p/w readout —
  so a designer tunes them in the numbers on screen; `is_eligible` converts a car's
  `power_to_weight` (kW/kg) to hp/tonne via `RallyLibrary.KW_KG_TO_HP_TONNE` before comparing.
  **Progression is primarily gated on power-to-weight as a BAND:** every non-showdown
  rally carries a `pw_min`..`pw_max` band, so a car must sit inside it — an over-powered
  car is **capped out** (it can duck under `pw_max` by detuning, see `qualifying_detune`)
  and an **under-powered** car is **ineligible outright** (the band floor IS the power
  floor — there is no separate soft "underpowered" warning; that was retired with the
  hard floor). **The floor is judged at a car's MAX potential:** callers pass a
  `floor_meta` (the car's `UpgradeLibrary.max_potential_meta` — full engine tune, every
  installed kit enabled, ballast removed) so a car detuned or ballasted to fit a *lower*
  rally isn't ruled too weak for a *higher* one it could reach by tuning up (the player
  always can, for free — the mirror of ducking the ceiling). `floor_meta` defaults to the
  passed meta (a plain point check) for stock catalogue cars / rivals / synthetic tests.
  **The band is usually WIDE, and the CLASS FIELD is what defines the rally.** Most
  rallies pair a wide band with a class field — `car_type` (Hatchback Cup, Forest GT,
  Headland Dash, The Hot Gates), `country` (American Muscle, Lakeside Cup, Island Grand
  Prix), `doors_max` (Olive Coast), `cylinders_min`/`cylinders_max` (Marble Quarry,
  Twelve-Cylinder Promenade, Timber Trophy), `engine_min_l`/`engine_max_l` (Dust Devils,
  Salt Flats, Island Hop) or `drive_mode` (Front Runners, RWD Masters) — with the band
  only trimming the extremes. A *narrow* band picks 2-3 cars arbitrarily and silently
  re-picks them the moment a car is retuned; "four-cylinder, two-door" or "British cars"
  picks a group that reads as a real class and survives retuning. The open-class rallies
  are the showdowns.

  > **Standing rule — author the data, don't approximate it.** When a rally wants to
  > group cars by a property the catalogue does not record, ADD that property to the
  > car/engine definitions (a body property on `CARS`, an engine property on `ENGINES`,
  > or derive it where it's already implied — cylinders come from `layout`). Never
  > approximate it with a proxy field that happens to correlate: a proxy stops meaning
  > what it meant the moment someone retunes a car or adds a roster entry, and the rally
  > it gates quietly changes who can enter without anyone editing the rally. Each new
  > field needs BOTH an `ineligibility_reason` branch and an `hq.gd._restriction_text`
  > entry, or it is silently absent from the rally's description.

  `./report_eligibility.sh` (`tools/report_eligibility.gd`) reports, for every rally,
  which cars can enter stock and at max potential, using the real `is_eligible`
  predicate — run it after touching any restriction. The target is 2-3 eligible cars
  per rally (~2 is fine on today's nine-car roster and widens on its own as cars are
  added); the hard floor is **≥1**, since an unenterable rally is a logic bug.
- `reveal_after` — an `int` (default 0): the **global reveal gate**. A non-showdown
  rally's map pin stays locked (grey, non-pickable — a "coming up" hint) until the player
  has completed that many non-showdown rallies **anywhere on the roster**, so the world
  map reveals a couple of fresh rallies at a time instead of dumping them all at once — and
  a win in one corner of the map can open a rally in another (see
  `RallyLibrary.rally_revealed` / `_completed_count`). The count is deliberately global,
  not per-region: every corner's pins share one world map, and a per-region count would
  draw from a much smaller pool now that the world is split into four corners. Wave-0 rallies (`reveal_after`
  omitted / 0) are visible from the start. Completed rallies stay farmable — this gates
  first *reveal* only, never re-entry.
- `events` — exactly **3** EventDefs, each `{ seed, turn_count, width?,
  forestiness?, surface_mix?, straightness?, cliffiness?, target_ms_override? }`. The
  `seed`/`turn_count`/`width` feed `TrackGenerator.generate` unchanged; the
  showdown's events are longer. `forestiness` (0–1, default 1.0 via
  `event_forestiness`) sets how wooded the stage is — trees only spawn where the
  forest noise clears `1 - forestiness`, so each event can read as dense forest or
  open clearings (bushes ignore it). See [trees.md](trees.md). `straightness` (0–1,
  default 0.0 via `event_straightness`) biases generation toward gentler corners +
  longer straights for an easier, less twisty stage — **earlier, lower-tier events
  run higher** so the start of the game is easier, the showdown stays unbiased
  (twistiest). See [track.md](track.md). `cliffiness` (0–1, default 0.0 via
  `event_cliffiness`) sets how cliffy the stage is — 0 = flat, 1 = the tallest
  cliffs/deepest drops (`cliff_max_height_m`). It only scales the height ceiling
  (the noise wavelength is global); **earlier, lower-tier events run tamer**,
  coastal/mountain and the showdown crank it up. Written to `GameConfig.cliff_amount`
  by `RallySession`. Unlike `straightness`/`width`/`surface_mix`, it does **not**
  change the centerline or the flat lengthwise road profile, so it does **not** feed
  opponent target-time derivation. See [terrain.md](terrain.md) → *Cliffs & drops*.
- `map_pos` — a normalised `Vector2` (0..1) placing the rally's pin on the HQ
  world map (`hq.gd`). `(0,0)` is the map image's top-left, `(1,1)` its bottom-right
  (`hq.gd._make_pin` maps `x`→world X and `y`→world Z across the centred map plane).
  Pure UI data; no effect on the sim. Placement rules, all verified against the actual
  `textures/map_world.jpg` pixels rather than guessed: a pin must sit **on land**, on
  the **palette that matches its region** (green for `home`/`home_coast`, tan for
  `greece`/`greece_coast`, and the NE snow corner deliberately holds no pins), inside
  its corner, and no closer than ~0.05 to another pin (the test floor is 0.03; the
  authored roster keeps a wider budget). Keep pins inside roughly **[0.045, 0.955]**
  on both axes — the map plane is only 4.2 m across, so a pin at 0.99 sits centimetres
  from the table rim and its label can overhang the plane. A `home_coast` pin must sit
  on the green ground around the **bay** (the big SE water body, roughly x 0.60–0.95 /
  y 0.58–1.0) — its northern/north-eastern shore, peninsula and islands — not on the
  green strip at the map's right rim, which touches only a sliver of sea and so does
  not read as coastal at all. Coastal pins are deliberately at **varied**
  distances from the waterline — islands and headlands on the water, others set back
  to differing depths — so a coastal corner reads as a region, not a line of pins
  tracing the shore. Re-generating the map texture from a new seed moves the terrain
  and invalidates every pin: re-verify them all (sample the image, classify sea /
  sandy / green / snow / rock from the palette constants at the top of
  `tools/gen_map_texture.py`) rather than nudging a few by eye.
- `region` — the `RegionLibrary` region id this rally belongs to: one of the four
  corners of the single world map, `home` (NW forest inland), `home_coast` (SE green
  shore / peninsula), `greece` (SW arid inland) or `greece_coast` (SE sandy shore).
  The corner owns the LOOK and the WATERLINE, so a rally's corner must match how its
  stages look — a forest rally cannot sit in the arid corner. The tag is explicit and
  is never derived from `map_pos`, which would couple look selection to pin geometry.
  **Each corner holds a SPREAD of difficulties** (roughly tiers 1→4 plus its showdown),
  not a difficulty band: the player hops between corners throughout the game and unlocks
  across them, so a uniformly-early or uniformly-late corner would re-create the
  sequential progression the one-map change removed. See [regions.md](regions.md).
- `water_level` (per event) — **authored on every event**, even though the region now
  supplies one. Resolution is `event → region → GameConfig baseline`
  (`TrackGenParams.resolve_water_level`), so pinning it per event keeps a corner's
  authored waterline from silently reshaping a shipped track, and lets the waterline
  vary WITHIN a corner **by distance from the shore** — nearer the coast sits higher,
  further inland lower. Author the value; never derive it from `map_pos`. **Pairing
  constraint:** an event at a coastal waterline (-5) must pair it with
  `terrain_layer1_amplitude >= 16.0` (see `challenge_library.gd`) or a high sea over low
  relief floods the track. An event authoring no amplitude runs the `GameConfig`
  baseline, which clears that bar comfortably.

A rally's result is the **combined time across its 3 events**.

## Determinism

`TrackGenerator.generate` is deterministic for a given `(seed, turn_count,
width)`, so each event is a fixed track. The **opponent field is reseeded from
the rally id** (`_rally_seed` folds the id hash with the first event seed), so
re-attempting a rally chases the *same* leaderboard — damage sticks, opponents
never re-roll. Nothing about opponents or target times is stored; it's all
recomputed.

## Lap-time model (`LapTimeModel`)

`scripts/lap_time_model.gd` (`class_name LapTimeModel`) is a pure-static
quasi-steady-state (QSS) lap-time model — no scene nodes, no randomness. It
computes a car's **physics-optimal velocity profile** over a track centerline:

- `optimum_profile(track_result, car_meta, event := {}) -> { s, v, t, total_ms }` —
  three-pass velocity sweep over the sampled centerline:
  1. **Cornering ceiling** — `v = sqrt(µg/κ)` at each sample (curvature `κ`,
     combined grip `µ`).
  2. **Forward accel pass** — power-limited `F = P_peak / v` (from `peak_torque ×
     redline`), friction-circle limited, drag `= drag·v²`, rolling resistance ≈ 0.2 g.
  3. **Backward braking pass** — friction-circle limited.
  Grip `µ` is the average of front + rear tyre grip coefficients, blended by the
  event's surface mix via `GameConfig.gravel_grip` / `tarmac_grip`.
- `optimum_ms(track_result, car_meta, event) -> int` — convenience wrapper
  returning only `total_ms`.

`derive_target_ms` and `derive_turn_splits` both call into this model; the opponent
generator also uses it per-rival.

## Key functions

- `index_of(id)` / `by_id(id)` / `event_width(event)` / `event_forestiness(event)` /
  `event_tarmac_fraction(event)` / `event_straightness(event)` /
  `event_cliffiness(event)` — lookups.
- `is_eligible(rally, car_meta, floor_meta := {})` — restriction match (open-class →
  always true). `car_meta` is a CarLibrary entry, resolved by the owned car's stable
  `model_id`. The optional `floor_meta` judges the `pw_min` floor at a different meta
  (the car's `UpgradeLibrary.max_potential_meta`) so an owned car's floor is checked at
  its max potential, not its current detuned/ballasted tune (defaults to `car_meta`). The
  menus' field-a-car rig and map pins filter on this.
- **Authoring check**: `tools/report_eligibility.gd`/`.tscn` + `./report_eligibility.sh`
  (repo root, follows the `verify_track_cache`/`cache_opponents.sh` pattern) reports, for
  every rally x every `CarLibrary.CARS` entry, whether it's eligible stock (raw `CARS`
  entry, no `floor_meta`) and whether it could enter fully tuned (`floor_meta` from
  `UpgradeLibrary.max_potential_meta`) — always via the real `is_eligible` /
  `ineligibility_reason`, never a re-implementation. Flags rallies with < 2 or > 4 stock-
  eligible cars and cars that can enter almost nothing (report signal, not a gate — the
  authoring target is 2-3 per rally); exits non-zero only if a rally has zero eligible
  cars even at max potential (genuinely unenterable). See
  `todo/one-map-four-corners.md` > "New task: an eligibility-report tool".
- `qualifying_detune(rally, full_meta)` — the largest whole-percent
  `engine_detune` fraction at which a car passes the restriction: `1.0` when it's
  already eligible at full tune, `-1.0` when no detune can qualify it (a non-power
  field fails, or the band floor is unreachable). `full_meta` is the car's
  effective stats at FULL tune (`effective_meta` with detune 1.0), so the result
  is an absolute detune-slider setting; it's floored to the slider's whole-percent
  steps and verified back through `is_eligible`. It's now used only to CLASSIFY a
  car for the car park's **over-limit prompt** — a result in `(0, 1)` marks the car
  as over-cap-but-fixable, so it parks looking eligible and pressing Start pops the
  prompt (the frac value itself is no longer shown to the player). The prompt's
  **Change Upgrades** option opens the gated upgrades menu where the player sheds
  power for themselves (detune slider, ballast, or stripping parts) as a
  **permanent** garage edit, then re-presses Start (see
  [menus.md](menus.md) → CARPARK). There is no longer a one-press "agree to the
  tune" button that applies it temporarily.
- `derive_target_ms(track_result, car_meta, event)` — per-event PAR time: physics
  floor of the **best eligible car** (see `LapTimeModel` below) × `GameConfig.driver_factor`
  (default 1.08, the driver-imperfection multiplier that turns the physics floor into a
  beatable human PAR). An `event.target_ms_override` wins when present.
- `derive_turn_splits(track_result, car_meta, event)` — per-turn cumulative split
  table derived from that car's `LapTimeModel.optimum_profile`; used for the
  in-run "vs P1" pace popup (see [stage.md](stage.md)).
- `generate_opponent_field(rally, event)` — the fixed field: 10–15 rivals, each
  rival's time = physics floor of **their own assigned car** (from `LapTimeModel`)
  × a pace factor. Each rival draws a **persistent skill** ONCE (not per event):
  skill 0 = ace, skill 1 = backmarker, giving a base pace `lerp(pace_fast,
  pace_slow, skill)` held across all 3 events — so a fast rival stays fast and the
  field spreads into a ranked ladder instead of everyone's per-event draws
  averaging to mid-pack. Each event adds a small ±`PACE_EVENT_NOISE` (±5%) jitter
  around that base, clamped by `PACE_MIN_FLOOR` (1.0×) so no rival ever beats their
  car's physics optimum — always beatable by design. In the `[pace_fast, pace_slow]`
  band the **fast end is a constant 1.1×** (the fastest rival runs just off their
  car's physics optimum at every tier); only the **slow end scales with the rally's
  hidden `difficulty` tier (1–4)** via `_pace_band`, tightening toward the fast end as
  the tier rises (tier 1 `[1.1, 2.0]` → tier 4 `[1.1, 1.5]`), so higher-tier rallies
  field a more uniformly quick pack.
  Some **crash out (DNF)**; a DNF in
  any event disqualifies the opponent (`combined_ms = -1`, doesn't rank). Wrecks are
  rare and **capped at one per event** — a wreck pass rolls `OPPONENT_WRECK_CHANCE`
  (0.5) per event to crash out exactly one not-yet-wrecked rival, so on average about
  one rival wrecks every two events. A wrecked rival carries the seeded roadside
  placement (`wreck_event` / `wreck_progress` / `wreck_side`) the run scene reads via
  `event_wreck(field, event_index)` to stage the wreck (see
  [opponent-wrecks.md](opponent-wrecks.md)). Each
  rival is also assigned a **car** (`car_id` / `car_name`) drawn from the rally's
  eligible roster (`_eligible_cars` filters by the restriction, so a p/w-banded
  rally fields cars inside that band and an RWD-only rally fields RWD rivals) using
  the same seeded RNG — so the line-up is stable across re-attempts and shows up on
  the start-line reveal + leaderboards. Each rival also draws a **name** from the
  fixed 20-name pool `RIVAL_NAMES` (`_draw_rival_names` — a Fisher-Yates shuffle on
  the same rally-seeded RNG, taken **without replacement** so no two rivals in a
  field share a name; the pool of 20 always covers a field of ≤15). Because the
  field is generated **once per rally** (in `RallySession`) and reused for all 3
  events, a rival carries the **same name across every event** and across
  re-attempts — it's the entrant's stable identity on the start-line reveal and the
  leaderboards. Overflow past the pool size falls back to a numbered `Rival N`.
- `eligible_car_indices(rally)` — the `CarLibrary.CARS` **indices** the restriction
  admits (vs `_eligible_cars`, which returns entries). The start-line queue props
  (`start_line.gd`) draw the leader/trailer cars from this so the cars lining up
  ahead of and behind the player are always eligible for the rally — never an
  over-powered car in a low-tier event. Falls back to every index if a restriction
  somehow admits none (open-class admits all).
- `build_standings(field, player_combined_ms, player_dnf, player_name, player_car_name)`
  — the ranked table (field + player, DNFs sink). Each entry carries the
  `car_name` that entrant drove (empty when unknown) so the leaderboards can show it.
- `placement(field, player_combined_ms)` / `is_top3(...)` — the player's 1-based
  placement among the non-DNF field on combined time.
- `completed_count(profile)` — the single progression metric (caps reward tier +
  gates the showdown).
- `showdown_unlocked(profile)` — true only when every non-showdown rally is
  completed. Superseded for region-scoped gating by
  `RegionLibrary.showdown_unlocked(region_id, profile)` (per-region form used
  by `hq.gd` and `reward_system.gd`); see [regions.md](regions.md).
- `rally_revealed(rally, profile)` / `_completed_count(profile)` — the global reveal gate
  (`reveal_after` met against the roster-wide completed non-showdown count, and for a
  showdown its own region's showdown gate — that one stays per-corner).
  Shared by the map pins, the enterable query, and the reward-draw walk.
- `incomplete_rallies_enterable_by(car_meta, profile, floor_meta := {})` — the
  anti-soft-lock query the reward system uses (incomplete ∧ revealed ∧ eligible in-band).
  `floor_meta` (the owned car's max potential) judges the floor at max, as in `is_eligible`.

## Anti-soft-lock guarantees

The roster underwrites two guards (asserted by tests): a **starter floor** — the
weakest car by power-to-weight always has at least one non-showdown rally whose band
it fits (the bottom band, Sh*tbox Cup, has a low floor for exactly this), and the
showdown stays open-class so it can finish the game even if it never earns another
car — and the **reward-eligibility query** above, so the reward system never grants a
car stranded with no enterable rally. (Before the p/w gating this floor was an
open-class rally at every reachable tier; with the power ladder it's the
weakest-car-enterable guarantee instead.)

## Entering a rally (integration)

Selecting an event writes its `(seed, turn_count, straightness, width,
forestiness, surface_mix)` into `Config.data` (`track_seed` / `track_turn_count` /
`track_straightness` / `track_width` / `track_forestiness` /
`track_tarmac_fraction`) — the same `Config.data` mutation pattern `apply_car`
uses — then `world._generate_track(cfg)` builds that exact track. After event 3, the combined time is compared against the opponent
field → placement → `Save.complete_rally(id, combined_ms)` if top-3 (which is
idempotent for the progress flag; the *car reward* fires on every top-3 finish,
so beaten rallies stay farmable).

## Not yet wired

`Save._recompute_showdown()` is still a no-op — once a menu/flow layer exists it
should call `RallyLibrary.showdown_unlocked(Save.profile)`.

## Tests

`tests/headless/test_rally_library.gd` — roster validity (unique ids, 3 events
each, at-most-one showdown per region — exactly one wherever a region holds rallies,
since an empty corner legitimately has none — the **starter floor**), eligibility (open-class + drive_mode +
country + power-to-weight **band** filters — floor + ceiling + ceiling-only + floor-only,
the floor judged at a supplied `floor_meta` (max potential), and `qualifying_detune`'s
duck-under-the-cap / already-eligible / unfixable cases), the **reveal-order** gate
(`reveal_after` on GLOBAL completion — a completion in another region counts; the
enterable query excludes unrevealed), the **engine-derived restrictions**
(displacement / cylinders resolved through the fitted engine, so an engine swap flips
eligibility; an unresolvable engine is rejected) and `doors_min`/`doors_max`, plus a
guard that **every shipped rally has at least one eligible car**,
a check that the roster's `map_pos` values are well formed, track-gen
determinism, target-time positivity + override, opponent-field
shape/bounds/determinism + DNF semantics + names drawn uniquely from the pool,
placement/top-3, progress count, and
showdown unlock + the enterable query. The start-line queue cars being eligible for
the rally is asserted in `test_start_line.gd`. An integration smoke (write a rally
seed into `Config.data` → `_generate_track`) lives in `test_smoke.gd`.
