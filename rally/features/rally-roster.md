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
- `difficulty` — tier; drives reward tier (clamped by progress) and sort order.
- `showdown` — exactly one rally has this `true`: the locked finale.
- `restriction` — a `Dictionary`; **empty = open-class** (every car eligible).
  Otherwise every present field must match the car's CarLibrary metadata:
  `drive_mode`, `country`, `car_type`, `engine_min_l`/`engine_max_l` (vs
  `engine_displacement_l`), `pw_min`/`pw_max` (vs `CarLibrary.power_to_weight`).
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

## Key functions

- `index_of(id)` / `by_id(id)` / `event_width(event)` / `event_forestiness(event)` /
  `event_tarmac_fraction(event)` / `event_straightness(event)` — lookups.
- `is_eligible(rally, car_meta)` — restriction match (open-class → always true).
  `car_meta` is a CarLibrary entry, resolved by the owned car's stable
  `model_id`. The menus' field-a-car rig and map pins filter on this.
- `derive_target_ms(track_result, event)` — per-event target time from the baked
  centerline length + corner mix (a placeholder formula pending a calibration
  pass; `REF_SPEED_MPS` / `CORNER_PENALTY_S` move to `GameConfig` then). An
  `event.target_ms_override` wins when present.
- `generate_opponent_field(rally, event_target_ms)` — the fixed field:
  10–15 rivals, each clean event time in `[target × RIVAL_PACE_MIN, target ×
  (RIVAL_PACE_MIN + RIVAL_PACE_SPREAD)]` (the band sits above the target, so
  rivals always run slower than target pace — beatable by design), some **DNF**;
  a DNF in any event disqualifies the opponent (`combined_ms = -1`, doesn't rank).
  Each rival is also assigned a **car** (`car_id` / `car_name`) drawn from the
  rally's eligible roster (`_eligible_cars` filters by the restriction, so an
  RWD-only rally fields RWD rivals) using the same seeded RNG — so the line-up is
  stable across re-attempts and shows up on the start-line reveal + leaderboards.
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

The roster underwrites two guards (asserted by tests): an **open-class floor** —
at least one open-class rally at every difficulty tier the starter can reach (so
the immortal starter always has somewhere to race) — and the **reward-eligibility
query** above, so the reward system never grants a car stranded with no enterable
rally.

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
should call `RallyLibrary.showdown_unlocked(Save.profile)`. The target-time
formula weights and the opponent name pool are deferred (calibration / cosmetic).

## Tests

`tests/headless/test_rally_library.gd` — roster validity (unique ids, 3 events
each, single showdown, open-class floor per tier), eligibility (open + drive_mode
+ country filters), track-gen determinism, target-time positivity + override,
opponent-field shape/bounds/determinism + DNF semantics, placement/top-3,
progress count, and showdown unlock + the enterable query. An integration smoke
(write a rally seed into `Config.data` → `_generate_track`) lives in
`test_smoke.gd`.
