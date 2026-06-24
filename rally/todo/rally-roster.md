# Rally Roster — implementation spec

> Status: **planned, not yet implemented.** Implementation brief for the
> **finite, curated rally list** named under `gameplay.md` › *Foundations* and
> *World map & rallies*. Follow the config-first convention (`CLAUDE.md`):
> authored content (the roster, per-event tunables) lives in data, never
> hardcoded in flow logic. Update the relevant `features/*.md` doc and add tests
> in the same piece of work.
>
> **The two forks are decided** (with the user): the roster is a **`RallyLibrary`
> in code** and **each event stores its own explicit seed**. Baked into the
> sections below; see *Decided (kept for trace)*.

## Goal

A single, data-driven source of truth for **which rallies exist** — each a
fixed set of seeded tracks plus a car restriction and a difficulty tier — and
the pure functions over it that the rest of the game needs: *is this car
eligible?*, *what's the opponent field?*, *is the showdown unlocked?*, *which
incomplete rallies can this car still enter?* (the anti-soft-lock query). The
roster is **authored content** (like `CarLibrary`), not player state — player
completion lives in the save (`todo/save-persistence.md`).

## Current state (measured from the code)

- **Track generation is already seeded and deterministic.**
  `TrackGenerator.generate(start_pos, start_heading, seed_value, turn_count,
  width, clearance)` (`track_generator.gd:84`) is documented *"Deterministic for
  a given (start_pos, start_heading, seed, turn_count, width)"* (`:80`) — it
  seeds a `RandomNumberGenerator` from `seed_value` (`:89-90`). So an **event**
  is fully described by `(seed, turn_count, width)`; same inputs → same track,
  every time. This is what makes a curated roster + stable opponent fields
  possible.
- **Those inputs are single `GameConfig` fields today.** `track_seed := 1`
  (`game_config.gd:262`), `track_turn_count := 15` (`:264`), `track_width := 6.0`
  (`:255`), `track_clearance := 8.0` (`:260`). `world._generate_track(cfg)`
  (`world.gd:58`) reads them straight off `cfg` (`world.gd:64-66`). There is **one
  track at boot and no notion of multiple events or rallies.** Entering a rally
  event = writing that event's params into `Config.data` before generating
  (mirrors how `apply_car` already mutates `Config.data` at runtime).
- **No restriction / eligibility / opponent / completion logic exists** anywhere.
- **`CarLibrary` is the precedent for authored rosters** — a
  `const CARS: Array[Dictionary]` in `car_library.gd:81+`. The rally roster is
  directly analogous and can mirror its shape.

## What a rally is (data model, proposed)

```
RallyDef
  id: String              # stable key; save's `rallies` map keys on this
  name: String            # display name (map pin label)
  events: Array[EventDef] # exactly 3 (the showdown may use longer events)
  restriction: Restriction | null   # null / empty = open-class (always eligible)
  difficulty: int         # tier; drives reward tier (clamped by progress) + sort
  showdown: bool          # the final rally; locked until all others completed

EventDef
  seed: int               # -> TrackGenerator seed_value; explicit per event
                          #    (a base+index derive helper is authoring-only)
  turn_count: int         # -> track length (showdown events are longer)
  width: float            # optional; defaults to GameConfig.track_width
  target_ms_override: int # optional; else target is auto-derived (see below)

Restriction  (all fields optional; a car must satisfy every present field)
  drive_mode: int         # CarLibrary RWD/AWD/FWD (car_library.gd:65-67)
  country: String         # CarLibrary metadata tag
  car_type: String        # CarLibrary metadata tag
  engine_max_l / engine_min_l: float   # if engine_displacement_l is authored
  pw_min / pw_max: float  # power-to-weight band (derived from mass/torque/redline)
```

Each event is one seeded `TrackGenerator` track; a rally's result is the
**combined time across its 3 events** (`gameplay.md`). Open-class rallies
(`restriction == null`) are the anti-soft-lock floor the immortal starter always
qualifies for.

## Storage (decided)

**Mirror `CarLibrary`: a `RallyLibrary` (`scripts/rally_library.gd`,
`class_name RallyLibrary`) holding `const RALLIES: Array[Dictionary]`** *(decided)*.
Rationale: consistent with the existing authored car roster (`car_library.gd`),
easy to diff/review in code, and the nested events/restriction structure is
clumsy to author in a `.tres` inspector. Either way, **per-event tuning numbers
that aren't structural** (e.g. global target-time formula weights) still belong
in `GameConfig`.

## Restriction matching

A pure function `RallyLibrary.is_eligible(rally, car_meta) -> bool`:
- `restriction == null` → always `true` (open-class).
- Otherwise every present `Restriction` field must match the car's `CarLibrary`
  metadata (`drive_mode` already exists; `country` / `car_type` /
  `engine_displacement_l` come from the **CarLibrary-metadata prerequisite** in
  `todo/save-persistence.md`). `pw_min/max` compares against a derived
  power-to-weight (`CarLibrary.power_to_weight(entry)`).
- `car_meta` is looked up by the owned car's stable `model_id` (never array
  index — see the save spec's id-safety argument).

The **field-a-car** showroom rig in `todo/menus.md` filters owned cars by exactly
this predicate (*owned ∧ eligible*); the map pins use it to show
*locked / eligible* state.

## Target times & opponent field (derived, deterministic — not stored)

Per `gameplay.md` › *Events, target times & opponents*:
- **Target time per event** is an **auto-derived function of the seeded track**
  (length + corner-difficulty mix), calibrated by Felix once the formula exists.
  Home: `TargetTime.derive(track_result) -> float` reading the generated
  `centerline` length + the corner types `TrackGenerator.generate` returns
  (`pieces`). Curated events (and the showdown) may set `target_ms_override`.
  *The formula's difficulty weights are `GameConfig` tunables; exact values are a
  calibration pass, deferred.*
- **Opponent field is recomputed from the rally seed, never saved** (matches the
  save spec's "opponent times derived, not stored"). `OpponentField.generate(rally,
  event_targets) -> Array[Opponent]`, seeded by the rally id/seed so the field is
  **identical across retries**:
  - **10–15 opponents** (`gameplay.md`).
  - Per event, each opponent gets a time in **[target, 2 × target]**.
  - **Some opponents DNF** an event; a DNF in any event disqualifies them from the
    rally (their combined time doesn't rank).
  - Combined time = sum of their 3 event times; the player places against the
    non-DNF field on combined time.

Because the seed is fixed, the leaderboard is stable — the player chases a fixed
field across retries (damage sticks, opponents don't re-roll).

## Completion, progress & showdown unlock

- A rally is **completed** when the player finishes **top-3 on combined time**
  among the non-DNF field (`gameplay.md`). The save records it in
  `rallies[rally_id]` (`completed`, `best_combined_ms` — already in the save
  spec's `RallyRecord`).
- **Progress = count of completed rallies** — the single metric (`gameplay.md`):
  it caps reward tier *and* gates the showdown. `RallyLibrary.completed_count(profile)`.
- **Showdown unlock:** the `showdown` rally is enterable only when **every
  non-showdown rally is completed**. `RallyLibrary.showdown_unlocked(profile)`.
  The map's *rallies completed / total* meter (`todo/menus.md` rig 3) reads this.

## Anti-soft-lock guarantees (`gameplay.md` — "both")

The roster underwrites two of the soft-lock guards:
1. **Open-class floor:** the roster must always contain open-class rallies (no
   restriction) the immortal starter qualifies for, spread across difficulty so
   there's always somewhere to race. A roster **validity check** (in tests)
   asserts ≥1 open-class rally exists at each difficulty tier the starter can
   reach.
2. **Reward-eligibility query:** the reward system (separate todo) must only grant
   cars that stay eligible for ≥1 still-incomplete rally. The roster exposes the
   query it needs: `RallyLibrary.incomplete_rallies_enterable_by(car_meta,
   profile) -> Array[RallyDef]`. The reward logic owns the *policy*; the roster
   owns the *query*.

## Entering a rally (integration)

Selecting a rally event (from the map → Start line, `todo/menus.md`):
1. Write the event's `(seed, turn_count, width)` into `Config.data`
   (`track_seed` / `track_turn_count` / `track_width`) before generation —
   the same `Config.data` mutation pattern `apply_car` already uses.
2. `world._generate_track(cfg)` (`world.gd:58`) builds that exact track.
3. The per-event timer (`todo/stage-start-and-end.md`) produces the event time;
   the three event times sum into the rally's combined time.
4. After event 3, compare combined time against `OpponentField` → placement →
   `Save.complete_rally(id, combined_ms)` if top-3.

## Dependencies

- **CarLibrary metadata** (`todo/save-persistence.md` › *Prerequisite*) — the
  restriction tags (`country` / `car_type` / `engine_displacement_l`) + stable
  `id` + a `power_to_weight` helper. **Restriction matching needs these.** Do it
  first.
- **Save / persistence** (`todo/save-persistence.md`) — owns the `rallies`
  completion map this roster's progress/unlock functions read. This spec
  **defines the `rally_id` space** that the save spec's `rallies` keys on (the
  save spec already flags this dependency).
- **Track generator** (`track_generator.gd`) — already exists; events reuse
  `generate()` unchanged.
- **Relates to** `todo/stage-start-and-end.md` (per-event timer → combined time)
  and `todo/track-progress-and-reset.md` (in-run progress/reset).
- **Consumed by** `todo/menus.md` — map pins (one per rally; locked/eligible/
  completed), the showdown progress meter, and field-a-car eligibility filtering.

## Testing

Headless GUT tests (`tests/headless/`, mirroring `test_car_library.gd`):
- **Determinism:** the same event `(seed, turn_count, width)` yields an identical
  track and an identical opponent field across repeated generation.
- **Eligibility:** open-class matches every car; each restriction field filters
  correctly; the starter qualifies for the open-class floor.
- **Opponent field:** size in 10–15; every time in `[target, 2×target]`; DNFs
  present; field is byte-identical across two generations with the same seed.
- **Progress/unlock:** `completed_count` tracks the profile; `showdown_unlocked`
  flips only when all non-showdown rallies are completed.
- **Roster validity (anti-soft-lock):** ≥1 open-class rally per reachable tier;
  every rally has exactly 3 events; all `id`s unique; the showdown is flagged and
  is the only `showdown` rally.
- **Integration smoke:** writing an event's seed into `Config.data` and running
  `world._generate_track` builds without error (extend `test_smoke.gd`).

## Out of scope / open questions

- **Roster size** — how many rallies make "complete them all" a satisfying but
  reachable goal (`gameplay.md` open question). Decide via playtest; the data
  model doesn't care.
- **Target-time formula** — the actual length/corner-mix → seconds function and
  its difficulty weights; a dedicated calibration session (`gameplay.md`).
- **Opponent names/flavour** — a name pool for the leaderboard; cosmetic, defer.
- **Restriction richness** — whether `car_type`/`country`/engine-size are all
  needed at launch or a subset; depends on how varied the curated rallies want to
  be.

### Decided (kept for trace)

- **Storage form:** a **`RallyLibrary` in code** (`const RALLIES: Array[Dictionary]`),
  mirroring `CarLibrary` — consistent with the codebase, clean for nested data.
- **Event seeds:** **explicit per event** (each `EventDef` stores its own seed),
  so authors curate good-looking tracks and can swap one event without shifting
  the others; a `base + index` derive helper is authoring-only convenience.
