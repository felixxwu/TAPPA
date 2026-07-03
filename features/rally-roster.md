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
- `showdown` — exactly one rally has this `true`: the locked finale.
- `restriction` — a `Dictionary`; **empty = open-class** (every car eligible).
  Otherwise every present field must match the car's CarLibrary metadata:
  `drive_mode`, `country`, `car_type`, `engine_min_l`/`engine_max_l` (vs
  `engine_displacement_l`), `pw_min`/`pw_max` (vs `CarLibrary.power_to_weight`,
  which resolves torque/redline from the car's referenced `EngineLibrary` engine —
  see [engine-and-transmission.md](engine-and-transmission.md)). The `pw_min`/`pw_max`
  bands are **authored in HP per kg** — the same unit shown on every player-facing p/w
  readout — so a designer tunes them in the numbers on screen; `is_eligible` converts a
  car's `power_to_weight` (kW/kg) to HP/kg via `RallyLibrary.KW_TO_HP` before comparing.
  **Progression is primarily gated on power-to-weight:** the earliest rallies are
  gated only from above (a `pw_max` ceiling and no floor, so the low-power
  starter qualifies), and the harder rallies tighten to a **band** (`pw_min` +
  `pw_max`) so an over-powered car can't walk them either. A rally may layer a
  secondary theme on top of its band (e.g. RWD Masters also wants `drive_mode` RWD,
  and **Front Runners** — the home of the FWD starters (Focus, Twingo) — wants
  `drive_mode` FWD under a `pw_max` ceiling, an intro-tier FWD rally parallel to the
  Shakedown for the MX-5), and **American Muscle** wants `country` US +
  `car_type` muscle on top of its band — the Charger's home turf.
  **Sh*tbox Cup** sits below even Shakedown: a `pw_max` 0.13 HP/kg ceiling with no
  floor, catering to the sub-0.13 HP/kg shitboxes (Twingo, Acty) that no other
  rally's band admits. The single open-class rally is the showdown.
- `events` — exactly **3** EventDefs, each `{ seed, turn_count, width?,
  forestiness?, surface_mix?, straightness?, target_ms_override? }`. The
  `seed`/`turn_count`/`width` feed `TrackGenerator.generate` unchanged; the
  showdown's events are longer. `forestiness` (0–1, default 1.0 via
  `event_forestiness`) sets how wooded the stage is — trees only spawn where the
  forest noise clears `1 - forestiness`, so each event can read as dense forest or
  open clearings (bushes ignore it). See [trees.md](trees.md). `straightness` (0–1,
  default 0.0 via `event_straightness`) biases generation toward gentler corners +
  longer straights for an easier, less twisty stage — **earlier, lower-tier events
  run higher** so the start of the game is easier, the showdown stays unbiased
  (twistiest). See [track.md](track.md).
- `map_pos` — a normalised `Vector2` (0..1) placing the rally's pin on the HQ
  world map (`hq.gd`). Pure UI data; no effect on the sim.

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
  `event_tarmac_fraction(event)` / `event_straightness(event)` — lookups.
- `is_eligible(rally, car_meta)` — restriction match (open-class → always true).
  `car_meta` is a CarLibrary entry, resolved by the owned car's stable
  `model_id`. The menus' field-a-car rig and map pins filter on this.
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
  Some **DNF**; a DNF in
  any event disqualifies the opponent (`combined_ms = -1`, doesn't rank). Each
  rival is also assigned a **car** (`car_id` / `car_name`) drawn from the rally's
  eligible roster (`_eligible_cars` filters by the restriction, so a p/w-banded
  rally fields cars inside that band and an RWD-only rally fields RWD rivals) using
  the same seeded RNG — so the line-up is stable across re-attempts and shows up on
  the start-line reveal + leaderboards.
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
  completed.
- `incomplete_rallies_enterable_by(car_meta, profile)` — the anti-soft-lock
  query the reward system uses (incomplete ∧ eligible ∧ showdown-only-if-unlocked).

## Anti-soft-lock guarantees

The roster underwrites two guards (asserted by tests): a **starter floor** — the
starter (`mx5`, the lowest-power car) always has at least one non-showdown
rally inside its power band to race, and the showdown stays open-class so it can
finish the game even if it never earns another car — and the **reward-eligibility
query** above, so the reward system never grants a car stranded with no enterable
rally. (Before the p/w gating this floor was an open-class rally at every reachable
tier; with the power ladder it's the starter-enterable guarantee instead.)

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
should call `RallyLibrary.showdown_unlocked(Save.profile)`. The opponent name pool
is deferred (cosmetic).

## Tests

`tests/headless/test_rally_library.gd` — roster validity (unique ids, 3 events
each, single showdown, the **starter floor**, and the **p/w gating** shape: every
non-showdown rally caps p/w, tier-1 has no floor, tier-3+ uses a band), eligibility
(open-class + drive_mode + country + power-to-weight filters), track-gen
determinism, target-time positivity + override, opponent-field
shape/bounds/determinism + DNF semantics, placement/top-3, progress count, and
showdown unlock + the enterable query. The start-line queue cars being eligible for
the rally is asserted in `test_start_line.gd`. An integration smoke (write a rally
seed into `Config.data` → `_generate_track`) lives in `test_smoke.gd`.
