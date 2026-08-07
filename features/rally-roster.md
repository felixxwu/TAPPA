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
- `special` (bool) + `requires_completions` (int) — a **completion-gated special
  event**, replacing the old per-region "showdown" concept (`RallyLibrary.is_special`,
  `completions_required`, `completions_needed`). A special's map pin/entry unlocks once
  the player's roster-wide count of completed **ordinary** rallies
  (`_completed_count`) reaches `requires_completions` — a **global** gate
  with no relationship to region: a region may hold any number of specials,
  including none (see [regions.md](regions.md)). It gates on completions rather than
  on a star total because stars are now **spendable** currency
  ([star-economy.md](star-economy.md)) — a gate reading a spendable balance would
  revoke a special the player had already qualified for the moment they bought a car.
  Eight specials ship today, at
  rungs authored 2/4/6/8/10/12/14/16 (do not treat these numbers as a contract —
  they're tunable): `sp_woodland_trial` (`home`), `sp_dust_trial` (`greece`),
  `sp_lakeshore_trial` (`home_coast`), `sp_archipelago_trial` (`greece_coast`) are
  the four new lower rungs; `the_showdown` (`home`), `hc_showdown` "The Lakeland
  Crown" (`home_coast`), `gr_showdown` "The Aegean Crown" (`greece`), `gc_showdown`
  "The Island Crown" (`greece_coast`) are the four pre-existing showdowns, renamed
  in role only (still `special: true`, now with `requires_completions` instead of the
  retired `showdown: true`). All eight keep `"restriction": {}` (open-class) so the
  ladder can't deadlock — a special must never gate on a part it unlocks. Specials
  **do** award stars (they used to award none — safe now only because they no longer
  gate on the star balance), but they are still excluded from `_completed_count`, so a
  special never advances the gate governing its own ladder.
  `RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY`
  names `sp_woodland_trial` — the LOWEST rung — as the special whose completion flips
  `engine_swaps_unlocked`. The intent is a *capability* gate on engine swapping,
  separate from the swap-token currency (which keeps dropping unconditionally).
  Fully wired: `RewardSystem._box_gate_open`, the garage swap row and the
  car-park confirm popup all honour it. On the map a special stands a **trophy**
  rather than a flag (`RallyTrophy`, see [menus.md](menus.md)). See
  [engine-swap.md](engine-swap.md). Completing every special
  (`RallyLibrary.all_specials_completed` — whichever one is last, not a
  designated finale) fires the game's win/credits beat
  (`RallySession.game_won`, replacing the old `RegionLibrary.all_showdowns_completed`).
  The retired field is `showdown` (bool) and the retired invariant is "at most one
  showdown per region, exactly one wherever a region holds rallies" — regions no
  longer gate anything (see [regions.md](regions.md)).
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
  **Progression is primarily gated on power-to-weight as a BAND:** every non-special
  rally carries a `pw_min`..`pw_max` band, so a car must sit inside it — an over-powered
  car is **capped out** (it can duck under `pw_max` by detuning, see `qualifying_detune`)
  and an **under-powered** car is **ineligible outright** (the band floor IS the power
  floor — there is no separate soft "underpowered" warning; that was retired with the
  hard floor). **A band is never wider than 2:1** — `pw_min` must be at least half of
  `pw_max`, so an event stays a recognisable class instead of admitting wildly
  mismatched cars. This is a shipped-content invariant guarded by
  `test_no_shipped_rally_has_an_over_wide_power_band`; retune the edges freely, but
  keep the ratio. Narrow from whichever end preserves the guarantee that every rally
  still has an eligible car — raising a floor is what orphans a thin class (see
  `test_every_shipped_rally_has_at_least_one_car_that_can_enter_it`).
  **The floor is judged at a car's MAX potential:** callers pass a
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
  are the specials (see `special`/`requires_completions` above).

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
- `reveal_after` — an `int` (default 0): the **global reveal gate**. A non-special
  rally's map pin stays locked (grey, non-pickable — a "coming up" hint) until the player
  has completed that many non-special rallies **anywhere on the roster**, so the world
  map reveals a couple of fresh rallies at a time instead of dumping them all at once — and
  a win in one corner of the map can open a rally in another (see
  `RallyLibrary.rally_revealed` / `_completed_count`). The count is deliberately global,
  not per-region: every corner's pins share one world map, and a per-region count would
  draw from a much smaller pool now that the world is split into four corners. Wave-0 rallies (`reveal_after`
  omitted / 0) are visible from the start. Completed rallies stay farmable — this gates
  first *reveal* only, never re-entry.
  **`reveal_after` gates the PIN; the reveal SEQUENCE has a second gate on top of it.**
  When the map table opens, `hq_table.gd._pending_reveals()` picks out the rallies to
  announce to the player, and a rally qualifies only if `rally_revealed` is true AND the
  player owns a car that can actually enter it (`_has_eligible_car` → `_entry_plan`) AND
  it isn't already `Save.rally_revealed_seen`. So an unlocked rally the garage cannot
  field is *held back* and announced later — the day a bought / won / engine-swapped car
  qualifies for it. The queue is derived fresh on every map open from current state
  (never cached when a rally is completed), which is what makes it work for any unlock
  route. See [menus.md](menus.md) → "New-rally reveal".
- `events` — exactly **3** EventDefs, each `{ seed, turn_count, width?,
  forestiness?, surface_mix?, straightness?, cliffiness?, weather?, target_ms_override? }`. The
  `seed`/`turn_count`/`width` feed `TrackGenerator.generate` unchanged; specials'
  events are longer, and length ramps with the rung (the four new lower-rung
  specials run shorter than the four upper-rung ex-showdowns). `forestiness` (0–1, default 1.0 via
  `event_forestiness`) sets how wooded the stage is — trees only spawn where the
  forest noise clears `1 - forestiness`, so each event can read as dense forest or
  open clearings (bushes ignore it). See [trees.md](trees.md). `straightness` (0–1,
  default 0.0 via `event_straightness`) biases generation toward gentler corners +
  longer straights for an easier, less twisty stage — **earlier, lower-tier events
  run higher** so the start of the game is easier, while the hardest events
  (the upper-rung specials) sit at the bottom of the authored band. Authored values now span
  ~0.5–1.0 (a 2026-08 rescale mapped every authored value `v -> 0.5 + 0.5 * v`),
  so even the twistiest shipped stage carries a moderate gentle-corner bias.
  See [track.md](track.md). `cliffiness` (0–1, default 0.0 via
  `event_cliffiness`) sets how cliffy the stage is — 0 = flat, 1 = the tallest
  cliffs/deepest drops (`cliff_max_height_m`). It only scales the height ceiling
  (the noise wavelength is global); **earlier, lower-tier events run tamer**,
  coastal/mountain and the upper-rung specials crank it up. Written to `GameConfig.cliff_amount`
  by `RallySession`. Unlike `straightness`/`width`/`surface_mix`, it does **not**
  change the centerline or the flat lengthwise road profile, so it does **not** feed
  opponent target-time derivation. See [terrain.md](terrain.md) → *Cliffs & drops*.
- `weather` — `"dry"` (default, omittable) or `"rain"`, via `event_weather`. Authored,
  never random, so a wet stage is wet every attempt. No shipped rally is currently
  marked wet. See [weather.md](weather.md).
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
  **Each corner holds a SPREAD of difficulties** (roughly tiers 1→4 plus its two
  specials), not a difficulty band: the player hops between corners throughout the game and unlocks
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
  relief floods the track.
- `terrain_layer1_amplitude` (per event) — **authored on every event**, and it follows
  the map: **relief falls from north to south.** The far-north stages are the hilliest
  (~26) and the deep-south inland ones the flattest (~12), interpolated from the
  rally's `map_pos.y` (y=0 is north — `home`/"Rally Country" sits at y 0.16–0.45,
  Greece at y 0.50–0.98). Each rally staggers its 3 events by ±1 so a corner doesn't
  read as uniform.
  **The coastal pairing rule above wins over the gradient.** The coastal regions are
  also the southern ones, so the two pull against each other: every event at a
  waterline of -8 or higher is floored at 16.0 regardless of latitude. That flattens
  the gradient across `home_coast` and `greece_coast` — deliberate, because a flooded
  track is a broken stage and a slightly-too-hilly coast is not. Inland Greek stages
  (`gr_mountain_pass`, `gr_ancient_ruins`) keep the low end of the range.
  Amplitudes reach generation through `cfg`, not `TrackGenParams`, but
  `TrackCache.terrain_fingerprint` folds config-wide terrain settings into the cache
  key — so retuning them **changes track shapes and requires `./cache_all.sh`**.

### Early game: one home rally per starter

The three starters sit at **Twingo 82 / Focus 114 / MX-5 159 hp/tonne** — a 1.94×
spread, which is almost exactly the widest a single band may be under the 2:1 rule
above. So **no shared opening rally can serve all three fairly**: rivals are drawn
*uniformly* from a rally's eligible pool (`generate_opponent_field` → `_eligible_cars`)
and each rival's time is `optimum_ms(their car) × pace`, so band width **is** the
outclassing risk. A wide opener puts a Twingo against MX-5-class cars.

Each starter therefore gets its own home rally, tuned so its rival pool contains only
that car — a one-make series, where the player cannot be outclassed by construction:

| Rally | Restriction | Starter | Rival pool |
|---|---|---|---|
| `shakedown` | roadster, 130–185 | MX-5 | MX-5 |
| `front_runners` | hatch + FWD, 95–140 | Focus | Focus |
| `hm_hatch_cup` | hatch, `doors_max` 3, 55–100 | Twingo | Twingo |
| `shitbox_cup` | open, 50–90 | shared (any car, via detune) | Acty, Twingo |

**Categories do the separating, not the band** — because `qualifying_detune` lets any
over-ceiling car detune INTO a lower rally (the floor is then re-checked against the
*detuned* figure), a `pw_max` can only block moving **up**, never down. So the Focus is
kept out of the Twingo's cup by `doors_max: 3` (Twingo 3 doors, Focus 5) rather than by
power, and the hatches are kept out of the MX-5's event by `car_type`. Anything
expressed purely as a ceiling is porous by design.

Note the floor is judged at `max_potential_meta`, but a **fresh** starter has no
upgrades installed, so its potential equals its stock figure — the "qualifies on
upgrades it hasn't bought" trap only appears once a car is modified.

`shitbox_cup` stays in wave 0 deliberately: it is the **anti-soft-lock cover**. Its
open 50–90 band takes any car — including one drawn from a Mystery Box after a wreck —
because any faster car can detune into it. Without an open-class rally revealed from
the start, a player could hold a car with nowhere to race; that is what
`test_incomplete_enterable_query_respects_eligibility_and_lock` guards, and the failure
is real rather than pedantic.

`incomplete_rallies_enterable_by` **counts a detune as enterable**, matching
`hq.gd._entry_plan` and the shipped-roster test — all three now share one definition of
"can enter". This does not weaken the guarantee: `qualifying_detune` only ever rescues a
car that is over the CEILING, whereas a genuine soft-lock is the opposite case, a car too
weak for everything left, which detuning cannot fix. Judging the query more strictly than
the screen that actually gates entry made the reward system see phantom soft-locks and
hand rescue cars to players who were never stuck.

The result is **2 clickable rallies for each of the three starters**.

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
  event's surface mix via `GameConfig.gravel_grip` / `tarmac_grip`, then further
  scaled by `GameConfig.rain_grip_mult` when `RallyLibrary.event_weather(event)`
  is `WEATHER_RAIN` (`_surface_grip`). Because every rival's time is a multiple of
  this same optimum (see `generate_opponent_field` below), scaling it for weather
  scales the **entire AI field** together with the player — a wet stage's podium
  cut moves with conditions instead of the stage becoming harder to podium; rain
  changes how the car must be driven, not how hard the field is to beat.
- `optimum_ms(track_result, car_meta, event) -> int` — convenience wrapper
  returning only `total_ms`.

`derive_target_ms` and `derive_turn_splits` both call into this model; the opponent
generator also uses it per-rival.

## Key functions

- `index_of(id)` / `by_id(id)` / `event_width(event)` / `event_forestiness(event)` /
  `event_tarmac_fraction(event)` / `event_straightness(event)` /
  `event_cliffiness(event)` / `event_weather(event)` — lookups.
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
- **Progression check**: `tools/sim_career.gd`/`.tscn` + `./sim_career.sh` (repo root)
  simulates 100 whole careers as pure computation — no track generation, no physics, no
  `main.tscn` — by walking the real predicates (`rally_revealed` / `is_eligible` /
  `incomplete_rallies_enterable_by`, `RewardSystem.draw_car`) over a synthetic profile
  dict. Where `report_eligibility.sh` answers the STATIC question (which cars can enter
  which rallies), this answers the DYNAMIC one that static analysis can't: reveal gating
  depends on progress (both `reveal_after` and the special ladder count completions), so you
  only learn whether the drip-feed sustains a career by walking one. Reports, per rally
  index, mean cars owned / **revealed**-unfinished / **enterable**-unfinished / stars, and
  the **soft-lock rate** (rallies left but no owned car in band) with the rallies most often
  stranded. It also prints the authored reveal schedule (the `reveal_after` buckets and the
  cumulative curve) up front, because that curve is the ceiling on how much choice the
  player can ever have. The `revealed` vs `eligible` gap is the diagnostic that separates
  the two gates governing breadth: reveal gating vs restriction bands. When the two columns
  are equal, restrictions have stopped filtering anything and reveal is the only live gate.
  Models
  stock cars only, so eligible counts are a lower bound and the soft-lock rate an upper
  bound. Report signal, not a gate — always exits 0. Design:
  `docs/superpowers/specs/2026-08-05-career-sim-design.md`.
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
  in-run "vs P1" pace popup (see [stage.md](stage.md)) — and, for the leading rival,
  the on-track ghost car the player races against ([rival-ghost.md](rival-ghost.md)):
  the drawn time is re-solved into a driving envelope, so a pace factor is now
  something you can SEE rather than only a number on the standings screen.
- `generate_opponent_field(rally, event)` — the fixed field: `FIELD_MIN`–`FIELD_MAX`
  rivals (both 9 today, so every field is the same size), each
  rival's time = physics floor of **their own assigned car+engine build** (from `LapTimeModel`)
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
  rival is also assigned a **car+engine build** (`car_id` / `engine_id` / `car_name`)
  — see *Rival builds* below. Each rival also draws a **name** from the
  fixed 20-name pool `RIVAL_NAMES` (`_draw_rival_names` — a Fisher-Yates shuffle on
  the same rally-seeded RNG, taken **without replacement** so no two rivals in a
  field share a name; the pool of 20 always covers a field of `FIELD_MAX`). Because the
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
- `completed_count(profile)` — count of every completed rally in the profile
  (includes specials); the single progression metric feeding reward tier.
- `_completed_count(profile)` — count of completed **non-special** rallies
  roster-wide; the wave metric `reveal_after` compares against. Deliberately
  global, not per-region (see `reveal_after` above).
- `stars_for_placement(placed)` — the per-rally scoring curve (1st = the most,
  via `MAX_STARS_PER_RALLY`). THE one definition: `Save.complete_rally`'s ledger
  delta, the Rally Challenge payout and `hq._stars_for` all delegate to it, so the
  medals drawn on a pin cannot disagree with what the ledger was paid.
  There is **no** `total_stars` / `max_total_stars` any more — the balance is a
  persisted ledger on the profile, not a roster sum (see
  [star-economy.md](star-economy.md)).
- `is_special(rally)` — `bool(rally.get("special", false))`.
- `completions_required(rally)` — the one accessor for "how many ordinary rallies
  must be done first": `requires_completions` for a special, `reveal_after` for an
  ordinary rally. Two authored field names for one mechanism because they read
  differently to the player (a drip-feed vs. a quoted requirement); the UI reads
  through this so a quoted requirement can't drift from the gate that enforces it.
- `completions_needed(rally, profile)` — completions still outstanding, 0 once open;
  drives the locked special pin's **"N/M rallies"** readout (it counts completed
  *rallies* — an `event` is one stage inside a rally, so that is the accurate noun).
- `next_locked_special_id(profile)` — the id of the lowest rung of the specials ladder
  still shut ("" once all are open; roster order breaks a tie). The map teases **only**
  this special: the ladder is strictly ordered, so a requirement further up is not yet
  actionable, and every locked special above this one hangs no readout box at all — just
  its trophy (see [menus.md](menus.md)). It is also what the HQ's permanent **next-carrot
  line** names ("2 more rallies → The Woodland Trial (unlocks engine swaps)",
  `hq._carrot_line`) — the same rung, quoted on the garage station instead of on the map.
- `engine_swap_completion_requirement()` — `completions_required` of
  `ENGINE_SWAP_UNLOCK_RALLY`, the figure the garage swap row and the car-park
  confirm popup quote (also worded "N rallies").
- `engine_swaps_unlocked(profile)` — whether `ENGINE_SWAP_UNLOCK_RALLY`
  (`sp_woodland_trial`, the lowest rung) is recorded completed — the engine-swap *capability*
  gate (tokens themselves always drop; see `features/engine-swap.md`).
- `all_specials_completed(profile)` — true once every special on the roster is
  completed; a roster with no specials reads as completed. Replaces the old
  `RegionLibrary.all_showdowns_completed` as the credits/win-beat gate.
- `rally_revealed(rally, profile)` — the single reveal predicate shared by the map
  pins, the enterable query, and the reward-draw walk. It no longer branches on
  `is_special` at all: EVERY rally reveals once
  `_completed_count(profile) >= completions_required(rally)` (no region coupling
  anywhere), which is what collapsed the old two-predicate shape into one.
- `incomplete_rallies_enterable_by(car_meta, profile, floor_meta := {})` — the
  anti-soft-lock query the reward system uses (incomplete ∧ revealed ∧ eligible in-band).
  `floor_meta` (the owned car's max potential) judges the floor at max, as in `is_eligible`.

### Rival builds — car + engine combos

**Carrying a rival onwards.** `RallyLibrary.RIVAL_IDENTITY_KEYS`
(`["name", "car_id", "engine_id", "car_name"]`) + `identity_of(opp)` are the contract for
every hop that passes a rival to another surface — the start-line leaders
(`RallySession.current_event_leaders`), the wreck record (`event_wreck`) and the standings
rows (`build_standings`). Each used to re-list fields by hand, and dropping `engine_id` is
what staged rivals on their cars' STOCK engines: the receiving end re-resolves the car from
`car_id` alone, which can only ever find the catalogue stock engine. Use `identity_of`
rather than a fresh dict literal, and add new per-rival attributes to the const —
`test_rally_library.gd::test_no_hop_drops_a_rival_identity_key` walks it and fails until
every hop carries them.

Rivals get exactly **one** upgrade: the engine swap. The draw pool is therefore not the car roster
but every **(car, engine) pairing** the rally admits.

- **Pool** — `_eligible_combos(rally)` walks `CarLibrary.all()` ×
  `EngineLibrary.all()`, builds each pairing's effective meta
  (`UpgradeLibrary.effective_meta({"swapped_engine": eid}, entry)`, or `{}` when
  `eid` is the car's stock engine) and keeps it if `is_eligible(rally, meta)`
  passes. Because `effective_meta` re-points `meta["engine"]` at the fitted engine
  and runs the engine-swap mass model, displacement / cylinder-count /
  post-swap-power-to-weight restrictions all apply to the swap with **no new
  authored data** — and a heavy engine in a light car correctly *lowers* the
  combo's p/w rather than only raising its power. If a restriction admits nothing
  the fallback mirrors `_eligible_cars`: every car's **stock** combo, never the
  unfiltered cross product.
- **Distinct draw** — `_draw_distinct_combos(rng, pool, count)` Fisher-Yates
  shuffles the pool with the rally-seeded rng and takes a prefix, so every rival is
  a *different* build. This replaced an independent per-rival draw **with
  replacement**: with 10 cars and 9 rivals, all-distinct happened ~0.4% of the
  time, so fields were routinely several copies of the same car. When the pool is
  smaller than the field it **cycles** the pool (a 3-combo rally fields 3+3+3)
  instead of drawing random repeats, so even the degenerate case is as varied as
  the pool allows.
- **Pace** — the per-rival pace math is unchanged, but `car_meta` is now the
  combo's meta, so the swap feeds `LapTimeModel.optimum_ms`. An engine carries its
  whole **transmission** (`gear_ratios`, `final_drive`, `shift_time`), so a swap
  moves gearing as well as power.
- **Naming** — the entry carries `engine_id`, and `car_name` is
  `EngineSwap.display_name(car, {"swapped_engine": engine_id})`: layout-prefixed
  ("V12 Rondel Twist") when non-stock, the plain name when stock — the same
  convention the garage and leaderboards use for the player's own car. It flows
  unchanged through `rally_session.gd` into `UITheme.standings_row` and
  `start_line.gd`'s reveal card. `world.gd::_spawn_opponent_wreck` keys the wreck
  model off `car_id`, so wrecks are unaffected by the engine.
- **Eligibility judged on effective meta** — `_eligible_cars` now filters on
  `UpgradeLibrary.effective_meta({}, entry)` rather than the raw `CarLibrary`
  entry. A raw entry's power-to-weight falls back to the engine's *unboosted*
  `peak_torque`, so stock-turbo cars were admitted on understated power and then
  raced on their real, boosted power (the pace model has always used
  `effective_meta`). Both halves now agree, and it matches the player's own
  eligibility path (`hq_carpark.gd::_entry_plan`). **Consequence:** a car whose
  stock boost lifts it over a band's `pw_max` no longer appears in fields it used
  to.
- `eligible_car_indices` still deals in **cars only** — the start-line queue props
  are cosmetic scenery and an engine doesn't change a body.

## Anti-soft-lock guarantees

The roster underwrites two guards (asserted by tests): a **starter floor** — the
weakest car by power-to-weight always has at least one non-special rally whose band
it fits (the bottom band, Sh*tbox Cup, has a low floor for exactly this), and every
special stays open-class so it can be won even by a car that never earns another
upgrade — and the **reward-eligibility query** above, so the reward system never grants a
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

## Tests

`tests/headless/test_rally_library.gd` — roster validity (unique ids, 3 events
each, the **starter floor**), eligibility (open-class + drive_mode +
country + power-to-weight **band** filters — floor + ceiling + ceiling-only + floor-only,
the floor judged at a supplied `floor_meta` (max potential), and `qualifying_detune`'s
duck-under-the-cap / already-eligible / unfixable cases), the **reveal-order** gate
(`reveal_after` on GLOBAL non-special completion — a completion in another region
counts; the enterable query excludes unrevealed), the **engine-derived restrictions**
(displacement / cylinders resolved through the fitted engine, so an engine swap flips
eligibility; an unresolvable engine is rejected) and `doors_min`/`doors_max`, plus a
guard that **every shipped rally has at least one eligible car**,
a check that the roster's `map_pos` values are well formed, track-gen
determinism, target-time positivity + override, opponent-field
shape/bounds/determinism + DNF semantics + names drawn uniquely from the pool,
placement/top-3, progress count, and the special-event completion gate
(`completions_required`/`completions_needed`/`rally_revealed`) + the enterable query. The
`sandstorm`-only-on-`greece` weather test also covers the new specials. The
start-line queue cars being eligible for the rally is asserted in
`test_start_line.gd`. An integration smoke (write a rally seed into `Config.data`
→ `_generate_track`) lives in `test_smoke.gd`.

Per `CLAUDE.md`, the ladder's authored numbers (`requires_completions` rungs, turn
counts, `difficulty`, `map_pos`) are tunable content, not test-pinned contracts —
tests cover the logic (the star curve's shape, the gate predicate, the single
reveal rule), never the specific rung values.
