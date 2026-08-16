# Rally Roster

`RallyLibrary` (`scripts/rally_library.gd`, `class_name RallyLibrary`) is the
finite, curated list of rallies — authored **content** (like `CarLibrary`), not
player state. It holds `const RALLIES: Array[Dictionary]` plus the pure functions
the rest of the game runs over it. Player completion lives in the save profile
(`Save`, `features/save-persistence.md`), keyed by the stable rally `id` here.

**`RALLIES` is not grouped by geography.** The array is in AUTHORING ORDER and its order
carries no meaning at all — it is not a progression order, and adjacent entries need not
share a region or a corner of the map (they frequently don't; see the `region`
distribution below). The only truth about where a rally is are its own `region` (its look
+ waterline) and its `map_pos` (its pin). Anything that wants "the rallies over there"
must ask those fields, never a slice of the array.

## What a rally is

Each `RALLIES` entry:

- `id` — stable key the save's `rallies` map keys on. **Ids are frozen: they are save
  keys, so renaming one silently orphans every existing profile's progress.** A 2026-08
  geography pass re-authored the roster's NAMES, `region` tags and per-event terrain to
  agree with where each pin actually sits on `textures/map_world.jpg` — and deliberately
  left the ids alone. Several therefore read oddly against their location now
  (`coastal_sprint` is "Pinewood Sprint", deep in the northern pines; `gc_island_hop` is
  the inland "Timberline Loop"; `gr_marble_quarry`/`gr_olive_coast`/`gc_salt_flats` all
  sit in `home`). **Read the id as an opaque key, never as a claim about where the rally
  is** — `region` + `map_pos` are the only truth about that. The code comments on each
  affected entry say so at the entry itself.
- `name` — display name (map-pin label). It must describe the terrain the pin actually
  sits on: see the "THE MAP'S GEOGRAPHY" header comment above `RALLIES`, which reads the
  map as NE snow massif (reserved, no pins) / N+centre pine forest / E forest climbing
  into foothills / centre-west open plain threaded with rivers and lakes / SW+S arid
  desert / SE sea with a bay, shoreline and islands. Names drift because
  `tools/fit_map_pins.py` slides pins around whenever the progression graph is re-fit —
  that is how a "Coastal Sprint" ended up in the northern woods. **When a pin moves,
  re-read its geography** and rename/re-tag/re-author terrain in the same pass.
- `difficulty` — a **hidden** tier; drives reward tier (clamped by progress) and
  sort order. It is **never shown to the player** (no "Difficulty: N" / "TIER N" in
  the detail panel, car-park banner, or finish arch) — the class restriction is the
  only visible requirement. Since the rework it no longer decides how fast the field's
  CARS are (they match the player); it decides how hard they are DRIVEN, via the pace
  band.
- `special` (bool) — a **part-unlock event**: the rally that opens one upgrade for the
  whole garage (`unlocked_by_rally`, see [upgrade-catalogue.md](upgrade-catalogue.md)).
  There is no completion counter — the retired `requires_completions` /
  `completions_required` gate went with the old global wave-counter system, and a special
  now unlocks the same geometric way as any other pin: it reveals once the player's lit
  map reaches its `map_pos` ([map-exploration.md](map-exploration.md)).
  It has no relationship to region: a region may hold any number of specials, including
  none (see [regions.md](regions.md)).

  **Seven ship today**: `sp_dust_trial` (Big Turbo), `sp_lakeshore_trial` (Drivetrain
  Conversion), `sp_archipelago_trial` (Supercharger), `the_showdown` (NOS),
  `hc_showdown` (Sequential Gearbox), `gr_showdown` (Race Tires) — and
  `sp_woodland_trial`, the one that gates a **capability** rather than a part
  (`ENGINE_SWAP_UNLOCK_RALLY`, below).

  Three of them are **region showdowns that have been a special twice**. `hc_showdown`,
  `gr_showdown` and `gc_showdown` each existed to gate one rung of the four-rung NOS
  ladder; when that collapsed to a single part ([nitrous.md](nitrous.md)) they gated
  nothing and were demoted to ordinary rallies, on the rule that *a special that awards
  no part is a special by label only* — it would still claim the trophy marker, the map's
  locked teaser and a place in the all-specials endgame while paying exactly what an
  ordinary rally pays. Two of the three were **promoted back** when the sequential gearbox
  and the race tyres needed part-unlock events: a long, hard, already open-class rally on
  a pin the solver has already placed is the shape a special takes, and promoting one beat
  authoring a new pin — which would have re-fitted the whole map
  (`tools/fit_map_pins.py`) and moved every other rally's neighbourhood with it. The
  promotion needs **no** re-fit either way: the solver's own `SPECIALS` set is
  `id.startswith("sp_") or id.endswith("showdown")`, so it has been placing these three as
  specials all along, and it reads the gate/prerequisite chain straight out of
  `UpgradeLibrary` rather than duplicating it. Their
  `id` / `difficulty` / `restriction` / `events` were left untouched: ids key saved
  progress, and the other three decide the opponent field. **`gc_showdown` stays
  ordinary** — the longest of the three,
  gating no part, so it remains the pure star-payer.

  Every special keeps `"restriction": {}` (open-class) so it can never lock itself out — **a
  special must never gate on a part it unlocks.** They award stars like any other rally.
  `RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY` names `sp_woodland_trial` as the special whose
  completion flips `engine_swaps_unlocked` — a *capability* gate on engine swapping,
  separate from the swap-token currency (which keeps dropping unconditionally), honoured by
  `RewardSystem._box_gate_open`, the garage swap row and the car-park confirm popup. On the
  map a special stands a **trophy** rather than a flag (`RallyTrophy`, see
  [menus.md](menus.md)). Completing every special
  (`RallyLibrary.all_specials_completed` — whichever one is last, not a designated finale)
  fires `RallySession.game_won`.
- `restriction` — a `Dictionary`; **empty = open-class** (every car eligible).
  Otherwise every present field must match the car's CarLibrary metadata:
  `drive_mode`, `country`, `car_type`, `doors_min`/`doors_max` (vs the car's `doors`),
  `engine_min_l`/`engine_max_l` and `cylinders_min`/`cylinders_max` (both **resolved
  through the car's CURRENT engine** — see "Engine-derived restrictions" below), and
  `drive_mode`.

  **Entry requirements are PURELY CATEGORICAL — performance is not one of them.**
  There is no `pw_min`/`pw_max` band, no ceiling and no floor. A restriction's job is
  to make the player experience DIFFERENT CARS ("Japanese only", "hatchbacks only",
  "ten cylinders or more"), never to police how fast they are. There is consequently
  nothing to upgrade *into* and nothing to detune back *out of*: fit whatever parts
  you like and your eligibility does not move.

  How fast a car is instead shapes the **opponent field**, which is matched to the
  player's `CarPerformance` rating — see
  [car-performance.md](car-performance.md) and `generate_opponent_field` below. So a
  quicker car earns you quicker rivals rather than access to different events, and a
  rally's `difficulty` sets how hard the field is DRIVEN rather than what it drives.

  Most non-special rallies carry a categorical restriction; a handful are deliberately
  open (the specials, which must never gate on a part they unlock, and the opening
  rally, which must admit every starter car).

  **The CLASS FIELD is the whole restriction.** Each restricted rally names one or two
  categorical fields — `car_type` (Ridgeline Dash, The Hot Gates), `country` (American
  Muscle, Lakeside Cup, the British hill climb), `doors_min`/`doors_max` (Proving
  Ground, Long Meadow, the two-door sprint), `cylinders_min`/`cylinders_max` (Slate
  Quarry, Twelve-Cylinder Promenade, Timber Trophy, Grand Tour),
  `engine_min_l`/`engine_max_l` (Dust Devils, Fernway Dash, Sh*tbox Cup, Heavy Hitters)
  or `drive_mode` (RWD Masters). A class picked this way reads as a real category and
  survives retuning — which is exactly why the old power band was a poor fit for the
  job: a band picks 2-3 cars arbitrarily and silently re-picks them the moment a car is
  retuned.

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
- `map_pos` is what gates the pin now — **there is no `reveal_after` field any more**. A
  rally's map pin stays locked (grey, non-pickable — a "coming up" hint) until its
  `map_pos` falls inside a circle lit by a completed rally (or by the player's opening
  rally): `RallyLibrary.rally_revealed` / `lit_sources`, the single geometric predicate
  detailed in [map-exploration.md](map-exploration.md), which is the canonical description
  of this mechanism. The retired `reveal_after` (an `int`, default 0, compared against a
  global non-special completion count) and its special-side sibling
  `requires_completions` are **deleted** — see the "What the retired mechanism was"
  section of that doc. Completed rallies stay farmable — reveal gates first *entry* only,
  never re-entry.
  **Reveal gates the PIN; the reveal SEQUENCE has a second gate on top of it.**
  When the map table opens, `hq_table.gd._pending_reveals()` picks out the rallies to
  announce to the player, and a rally qualifies only if `rally_revealed` is true AND the
  player owns a car that can actually enter it (`hq.gd._has_eligible_car` → `_entry_plan`)
  AND it isn't already `Save.rally_revealed_seen`. So a revealed rally the garage cannot
  field is *held back* and announced later — the day a bought / won / engine-swapped car
  qualifies for it. The queue is derived fresh on every map open from current state
  (never cached when a rally is completed), which is what makes it work for any unlock
  route. See [menus.md](menus.md) → "New-rally reveal".
- `events` — exactly **3** EventDefs, each `{ seed, turn_count, width?,
  forestiness?, surface_mix?, straightness?, cliffiness?, weather?, target_ms_override? }`. The
  `seed`/`turn_count`/`width` feed `TrackGenerator.generate` unchanged; specials'
  events are longer, and length varies by which kind of special it is: the purpose-built
  `sp_*` part-unlock trials run shorter than the ex-showdown specials
  (`the_showdown`/`hc_showdown`/`gr_showdown` — see the `special` field above for the
  showdown-to-special history). `forestiness` (0–1, default 1.0 via
  `event_forestiness`) sets how wooded the stage is — trees only spawn where the
  forest noise clears `1 - forestiness`, so each event can read as dense forest or
  open clearings (bushes ignore it). See [trees.md](trees.md). `straightness` (0–1,
  default 0.0 via `event_straightness`) biases generation toward gentler corners +
  longer straights for an easier, less twisty stage — **earlier, lower-tier events
  run higher** so the start of the game is easier, while the hardest events
  (the ex-showdown specials) sit at the bottom of the authored band. Authored values now span
  ~0.5–1.0 (a 2026-08 rescale mapped every authored value `v -> 0.5 + 0.5 * v`),
  so even the twistiest shipped stage carries a moderate gentle-corner bias. It is not
  the only thing shaping the corner mix: `TrackGenerator.CORNER_WEIGHTS` keeps the
  sharpest authored shapes (`1`, `Square`, `Hairpin`) rarer than the rest on every
  stage, at any `straightness` including 0. See [track.md](track.md). `cliffiness` (0–1, default 0.0 via
  `event_cliffiness`) sets how cliffy the stage is — 0 = flat, 1 = the tallest
  cliffs/deepest drops (`cliff_max_height_m`). It only scales the height ceiling
  (the noise wavelength is global); **earlier, lower-tier events run tamer**,
  coastal/mountain and the ex-showdown specials crank it up. Written to `GameConfig.cliff_amount`
  by `RallySession`. Unlike `straightness`/`width`/`surface_mix`, it does **not**
  change the centerline or the flat lengthwise road profile, so it does **not** feed
  opponent target-time derivation. See [terrain.md](terrain.md) → *Cliffs & drops*.
- `weather` — a `WeatherLibrary` condition id resolved via `event_weather`: `"dry"`
  (default, omittable), `"rain"`, `"sandstorm"`, `"fog"` or `"storm"`. Authored, never
  random, so a wet stage is wet every attempt. It is authored **per zone, not per
  region-name**: sandstorm only on desert pins, storm on the exposed water pins, fog on
  the damp forest/foothill ones. See [weather.md](weather.md).
- `map_pos` — a normalised `Vector2` (0..1) placing the rally's pin on the HQ
  world map (`hq.gd`). `(0,0)` is the map image's top-left, `(1,1)` its bottom-right
  (`hq.gd._make_pin` maps `x`→world X and `y`→world Z across the centred map plane).
  **NO LONGER pure UI data — `map_pos` IS the progression graph.** Reveal is geometric:
  a rally opens when the player has lit the map out to its pin, so a pin's position
  decides what it opens and what opens it (see
  [map-exploration.md](map-exploration.md)). Nudging a pin for visual spacing can
  disconnect a branch of the map or reorder the upgrade chain — re-run
  `tools/fit_map_pins.py` and the map tests after moving one. **The solver owns the
  positions; the geography follows them, not the other way round.** `fit_map_pins.py`
  optimises the progression graph, so a re-fit slides pins across terrain zones — after
  every re-fit, walk the moved pins and bring their `name`, `region` and per-event
  terrain back into agreement with the pixels underneath (that is exactly the drift the
  2026-08 pass cleaned up). Placement rules, all verified against the actual
  `textures/map_world.jpg` pixels rather than guessed: a pin must sit **on land**, on a
  palette its `region` can honestly claim (green forest/plain for `home`/`home_coast`,
  tan desert for `greece`/`greece_coast`, and the NE snow massif deliberately holds no
  pins), and no closer than ~0.05 to another pin (the test floor is 0.03; the
  authored roster keeps a wider budget). Keep pins inside roughly **[0.045, 0.955]**
  on both axes — the map plane is only 4.2 m across, so a pin at 0.99 sits centimetres
  from the table rim and its label can overhang the plane. A pin claiming a **coastal**
  waterline must actually sit on the SE **bay** (the big SE water body) — its shore,
  peninsula or islands — not on a green strip that merely touches a sliver of sea; only
  `hc_v12_promenade` and `gc_island_gp` qualify today. A **riverine** waterline belongs
  to a pin on the centre-west plain's rivers and lakes (`hc_lakeside_kei`,
  `rwd_masters`, `gr_mountain_pass`). Water-adjacent pins are deliberately at **varied**
  distances from the waterline — islands and headlands on the water, others set back
  to differing depths — so a shoreline reads as a place, not a line of pins
  tracing it. Re-generating the map texture from a new seed moves the terrain
  and invalidates every pin: re-verify them all (sample the image, classify sea /
  sandy / green / snow / rock from the palette constants at the top of
  `tools/gen_map_texture.py`) rather than nudging a few by eye.
- `region` — the `RegionLibrary` region id this rally belongs to: `home` (the green
  forest/plain look), `home_coast` (that look with the water raised), `greece` (the arid
  look) or `greece_coast` (the arid look with the water raised). A region is a **look +
  a waterline**, NOT a quadrant of the map — after the geography pass the tags follow
  the terrain under each pin, so the distribution is lopsided: **19 `home`, 8 `greece`,
  4 `home_coast`, 1 `greece_coast`**. The tag must match how the stage should look — a
  forest rally cannot carry the arid look — and is explicit, never derived from
  `map_pos`, which would couple look selection to pin geometry. Only the five pins on
  real water carry a raised waterline (`hc_v12_promenade` + `gc_island_gp` on the SE
  sea; `hc_lakeside_kei`, `rwd_masters`, `gr_mountain_pass` on the central rivers);
  everything else is inland and tagged accordingly, whatever its id suggests.
  **Difficulties are spread across the map, not banded by area**: the player hops around
  throughout the game and unlocks across it, so a uniformly-early or uniformly-late
  patch would re-create the sequential progression the one-map change removed. See
  [regions.md](regions.md).
- `water_level` (per event) — **authored on every event**, even though the region now
  supplies one. Resolution is `event → region → GameConfig baseline`
  (`TrackGenParams.resolve_water_level`), so pinning it per event keeps a corner's
  authored waterline from silently reshaping a shipped track, and lets the waterline
  vary **by what the pin is standing next to** rather than by region alone. The authored
  ladder is: **-4 on the sea, -7 on the central rivers, -11/-12 inland, -13 up in the
  foothills** — water falls away as you climb from the shore. Author the value; never
  derive it from `map_pos`. **Pairing constraint:** an event at a coastal waterline must
  pair it with `terrain_layer1_amplitude >= 16.0` (see `challenge_library.gd`) or a high
  sea over low relief floods the track.
- `terrain_layer1_amplitude` (per event) — **authored on every event**, and it follows
  the TERRAIN ZONE the pin sits in, not latitude: the **eastern foothills** are the
  hilliest (`hc_headland_dash` / `sp_woodland_trial`, ~34–44), the pine forest and the
  quarry country behind it sit in the middle (~26–40), the river plain and the sea
  shore lower (~16–26), and the **southern desert flats** are the flattest (~12–19).
  Each rally staggers its 3 events so a zone doesn't read as uniform — usually a ramp
  down (or up, where a stage climbs into the hills), occasionally flat where the
  ground genuinely is.
  **The coastal pairing rule above wins over the zone value**, so the two sea rallies
  are floored at 16.0 however low their surroundings would suggest — deliberate,
  because a flooded track is a broken stage and a slightly-too-hilly coast is not.
  Amplitudes reach generation through `cfg`, not `TrackGenParams`, but
  `TrackCache.terrain_fingerprint` folds config-wide terrain settings into the cache
  key — so retuning them **changes track shapes and requires `./cache_all.sh`**.

### Early game: each starter opens in its own rally

The three starters sit at **Twingo 111 / Focus 114 / MX-5 159 hp/tonne**. The Twingo
reaches that on a **stock small turbo** (`renault_12_i4`) — naturally aspirated it made 82,
which left whoever picked it simply holding the slow car. Boosted, the starter choice is
one of CHARACTER (light FWD hatch / heavier FWD hatch / RWD roadster) rather than of how
hard the early game will be.

Even so, **no shared opening rally can serve all three fairly**: rivals are drawn
*uniformly* from a rally's eligible pool (`generate_opponent_field` → `_eligible_cars`)
and each rival's time is `optimum_ms(their car) × pace`, so band width **is** the
outclassing risk. A wide opener puts a Twingo against MX-5-class cars.

The roster no longer tries. Each starter is dropped straight into **the rally that awards
that car** — its own event, with the band ceilinged just above it, so the player is at the
top of the field rather than the bottom of someone else's
([opening-rally](../todo/opening-rally.md), [prize-rallies](prize-rallies.md)):

| Starter | Opens in | Restriction |
|---|---|---|
| MX-5 | `shakedown` | open class, 85–165 |
| Focus | `hm_timber_trophy` | `cylinders_max` 4, 60–120 |
| Twingo | `hm_forest_gt` | `doors_max` 3, 58–115 |

Each of the three runs a **single stage**. The player is dropped into it before they have
seen the map, the garage or a menu, and a three-stage rally is a lot to ask of someone who
has not driven the game once — it also delays the thing the run exists to deliver, which is
arriving at the map with a rally already won. Every other rally keeps its full stage count,
so `RallySession.EVENTS_PER_RALLY` is the DEFAULT rather than the rule: ask
`RallySession.stage_count()` for the active rally's real figure.

This is why `front_runners` no longer has to admit everybody. It was widened to a
class-free 60–200 purely so all three starters could enter the one rally a fresh profile
could reach; nothing depends on that now, and it is back to an ordinary width.

**A class field on a prize rally is dangerous.** It can make the prize its own
prerequisite: `shakedown` was roadster-only, and since the catalogue's only other roadster
is the late-prize Viper, a Focus or Twingo player could not enter the rally standing next
to them and had to cross the map before the MX-5 was winnable at all. Prize rallies are
now separated by their **ceiling** — which is what puts the prize car on top of its own
field anyway — and carry a class field only where it cannot strand anyone.

The Twingo's event is the exception that shows the rule. With the Twingo at 111 and the
Focus at 114, a ceiling is far too fine an instrument to separate them: it would sit one
retune away from admitting a car that out-guns the prize. So that one cuts on **doors**
(Twingo three, Focus five), which is a fact about the cars rather than a number a balance
pass moves.

`shitbox_cup`'s pin is deliberately close enough to every starter's opening rally to be
revealed from the very start (see [map-exploration.md](map-exploration.md) — the opening
rally lights its circle before it's even completed): it is the **anti-soft-lock cover**.
Its restriction is deliberately permissive, so it takes almost any car — including one
drawn from a Mystery Box after a wreck. Without a widely-admitting rally revealed
from the start, a player could hold a car with nowhere to race; that is what
`test_incomplete_enterable_query_respects_eligibility_and_lock` guards, and the failure
is real rather than pedantic.

`incomplete_rallies_enterable_by` is a plain categorical eligibility check now: with no
performance ceiling there is nothing to duck under, so "can enter" means exactly what the
screen that gates entry means.

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
  1. **Cornering ceiling** — `v² = µg/(κ − µ·D/m)` at each sample (curvature `κ`,
     combined grip `µ`, total downforce coefficient `D`). With no downforce this
     is the classic `v = sqrt(µg/κ)`. The form is *linear in v²* and singular as
     `µ·D/m` approaches `κ`, so it is clamped at `V_CAP_MAX_MS`.
  2. **Forward accel pass** — power-limited `F = P_peak / v` (from `peak_torque ×
     redline`), friction-circle limited, drag `= drag·v²`, rolling resistance ≈ 0.2 g,
     and gated by a per-drive-mode **traction factor** (`GameConfig.traction_factor_rwd
     / _awd / _fwd`) standing in for the real drivetrain's per-patch slip behaviour.
     Forward pass only — braking is not a drivetrain function.
  3. **Backward braking pass** — friction-circle limited.

  The friction circle **grows with speed** when the car makes downforce: the
  envelope is `µ(g + D·v²/m)` (`_grip_long`), applied identically in all three
  passes. Applying it to the ceiling alone would let a car sit at a speed where
  its longitudinal grip had collapsed to zero.

  **Exact no-ops at their defaults.** Traction factors ship at 1.0 and no
  catalogue car has downforce, so times are byte-identical to before these terms
  existed (`test_defaults_are_an_exact_no_op`). Moving either off its default
  *does* move every rival time (fields are generated live, so it takes effect at once).

  **Still not modelled**: brake torque/bias, gearbox ratios, shift time, turbo
  lag, suspension, weight distribution, tyre width. Braking is one
  friction-circle term, so two cars alike but for their brakes time identically.
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
- `is_eligible(rally, car_meta)` / `ineligibility_reason(rally, car_meta)` —
  categorical restriction match (open-class → always true); the reason form returns a
  player-facing string, empty when eligible. `car_meta` is a CarLibrary entry, resolved
  by the owned car's stable `model_id`; pass `UpgradeLibrary.effective_meta` for an
  owned car so an engine swap or drivetrain conversion moves the categorical fields
  with it. There is no `floor_meta` and no performance term — see `restriction` above.
  The menus' field-a-car rig and map pins filter on this.
- **Authoring check**: `tools/report_eligibility.gd`/`.tscn` + `./report_eligibility.sh`
  (repo root, follows the `verify_track_cache` pattern) reports, for
  every rally x every `CarLibrary.CARS` entry, whether it's eligible — always via the
  real `is_eligible` / `ineligibility_reason`, never a re-implementation. Eligibility is
  categorical and upgrade-independent now, so there is only one answer per pairing
  rather than a stock-vs-fully-tuned pair. Flags rallies with < 2 or > 4 stock-
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
  depends on progress (which rallies the player has already completed, which lights their
  pins' circles on the geometric map — see [map-exploration.md](map-exploration.md)), so
  you only learn whether the drip-feed sustains a career by walking one. Reports, per rally
  index, mean cars owned / **revealed**-unfinished / **enterable**-unfinished / stars, and
  the **soft-lock rate** (rallies left but no owned car in band) with the rallies most often
  stranded. The `revealed` vs `eligible` gap is the diagnostic that separates the two gates
  governing breadth: reveal gating vs restriction bands. When the two columns are equal,
  restrictions have stopped filtering anything and reveal is the only live gate.
  It also prints a `reveal_after` bucket table up front, but this is now **vestigial**:
  no shipped rally authors a `reveal_after` field any more (the geometric reveal replaced
  it), so `tools/sim_career.gd`'s `reveal.get("reveal_after", 0)` always reads the 0
  default and every rally lands in the same bucket — worth knowing before reading that
  section of the output, not worth relying on for reveal-pacing signal. Models
  stock cars only, so eligible counts are a lower bound and the soft-lock rate an upper
  bound. Report signal, not a gate — always exits 0. Design:
  `docs/superpowers/specs/2026-08-05-career-sim-design.md`.
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
  around that base. `PACE_MIN_FLOOR` is now only a **sanity guard** (0.5×, far below
  anything the band can draw): its old value of 1.1× and its old rationale ("rivals
  never beat their car's physics optimum") both went with adaptive difficulty — the
  optimum is a point-mass centreline *reference*, not a limit. The real bound is
  `GHOST_SOLVABLE_PACE` (0.976×), applied after the residual difficulty trim, and it is
  set by what `RivalPace` can solve rather than by physics
  ([rival-ghost.md](rival-ghost.md)). In the `[pace_fast, pace_slow]`
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
  (includes specials); the single progression metric feeding reward tier. The retired
  `_completed_count` (a non-special-only count the old `reveal_after` gate compared
  against) is **deleted** along with that gate — reveal no longer counts completions at
  all, see `rally_revealed` below.
- `stars_for_placement(placed)` — the per-rally scoring curve: a podium place
  (1st–`PODIUM_PLACES`) pays `STARS_FOR_PODIUM`, any other finish pays
  `STARS_FOR_FINISH`, not finishing pays 0. Flat within each tier — no 1st/2nd/3rd
  gradient. THE one definition: `Save.complete_rally`'s credit, the Rally Challenge
  payout and `hq._stars_for` all delegate to it, so the medals drawn on a pin cannot
  disagree with what the ledger was paid. `MAX_STARS_PER_RALLY` (the star rows'
  denominator) is a SEPARATE constant from `PODIUM_PLACES` — see
  [star-economy.md](star-economy.md).
  There is **no** `total_stars` / `max_total_stars` any more — the balance is a
  persisted ledger on the profile, not a roster sum (see
  [star-economy.md](star-economy.md)).
- `is_special(rally)` — `bool(rally.get("special", false))`.
- `nearest_locked_special_id(profile)` — the locked special with the smallest
  `distance_beyond_frontier`, i.e. the one the player's lit map comes closest to reaching
  ("" once every special is open). The map teases **only** this special; every other locked
  special hangs no readout box at all, just its trophy (see [menus.md](menus.md)) — one the
  player cannot work toward yet is not worth a menu. The map table is now the **only**
  surface that names it: the garage's permanent next-carrot line quoted the same id and has
  been deleted. It replaced the retired `next_locked_special_id`, which walked an
  authored ladder of rungs; the retired `completions_required` / `completions_needed` /
  `engine_swap_completion_requirement` went with that ladder — see
  [map-exploration.md](map-exploration.md) for the geometric replacement
  (`distance_beyond_frontier`).
- `engine_swaps_unlocked(profile)` — whether `ENGINE_SWAP_UNLOCK_RALLY`
  (`sp_woodland_trial`, the special the reachability walk in
  [map-exploration.md](map-exploration.md) reaches earliest) is recorded completed — the
  engine-swap *capability* gate (tokens themselves always drop; see
  `features/engine-swap.md`).
- `all_specials_completed(profile)` — true once every special on the roster is
  completed; a roster with no specials reads as completed. Replaces the old
  `RegionLibrary.all_showdowns_completed` as the credits/win-beat gate.
- `rally_revealed(rally, profile)` — the single reveal predicate shared by the map
  pins, the enterable query, and the reward-draw walk. It is **geometric, not a
  counter**: `rally_revealed` delegates to `position_revealed(map_pos_of(rally),
  profile)`, which checks whether the pin falls inside any circle in `lit_sources(profile)`
  — one circle per completed rally (plus the player's opening rally, lit from the start)
  — so it no longer branches on `is_special` at all. See
  [map-exploration.md](map-exploration.md) for the full rule.
- `incomplete_rallies_enterable_by(car_meta, profile)` — the
  anti-soft-lock query the reward system uses (incomplete ∧ revealed ∧ eligible in-band).

### Rival builds — car + engine combos

**Carrying a rival onwards.** `RallyLibrary.RIVAL_IDENTITY_KEYS`
(`["name", "car_id", "engine_id", "car_name", "upgrades"]`) + `identity_of(opp)` are the contract for
every hop that passes a rival to another surface — the start-line leaders
(`RallySession.current_event_leaders`), the wreck record (`event_wreck`) and the standings
rows (`build_standings`). Each used to re-list fields by hand, and dropping `engine_id` is
what staged rivals on their cars' STOCK engines: the receiving end re-resolves the car from
`car_id` alone, which can only ever find the catalogue stock engine. Use `identity_of`
rather than a fresh dict literal, and add new per-rival attributes to the const —
`test_rally_library.gd::test_no_hop_drops_a_rival_identity_key` walks it and fails until
every hop carries them.

`upgrades` is the list of parts a rival's BUILD LEVEL fits (below). It is identity, not
decoration: the rival's time was drawn off a meta that includes those parts, so anything
re-deriving the meta from `car_id` + `engine_id` alone — `RallySession._effective_meta_for`,
which feeds the ghost's pace solve, most of all — would be looking at a slower car than
the one that set the time. It is the one identity key that is a LIST rather than a string,
hence `RIVAL_IDENTITY_LIST_KEYS`.

Rivals get an engine swap **and a build level**. The draw pool is therefore not the car
roster but every **(car, engine, build level)** combination the rally admits.

### Build levels

`_build_levels()` derives a small set of builds from the upgrade catalogue — never
hardcoded ids, so it follows a retune, a new part or a test fixture roster — and each one
enters the pool as its own combo with its own rating:

| Level | Fits | Why |
|---|---|---|
| stock | nothing | today's combos, unchanged |
| ballasted | the heaviest mass-ADDING part alone | headroom at the EASY end (ballast makes a car slower) |
| lightly built | the most modest *improving* part in each slot | a real but small step up |
| fully built | the best part in each slot | the top of the range |

"Best" / "most modest" are scored ONCE against `CarPerformance`'s synthetic reference car
(`_part_ranking`), not per car+engine: ranking every part against every combo would
multiply the benchmark sims by the catalogue size for an ordering that barely moves.
A part the rating cannot see at all (the sequential gearbox's shift time, the drivetrain
kit's flag — neither reaches `LapTimeModel`) is left off every level rather than dressing
a rival in hardware that does nothing.

Rules a level obeys: at most one part per `UpgradeLibrary.SLOTS` entry (the same
exclusivity `Save._enable_exclusive` enforces on the player's cars), no consumables, no
ballast in a *built* level, and **never nitrous** — `CarPerformance` deliberately excludes
nitrous from the rating, so a rival carrying it would be quicker than the rating the field
was matched on claims. Star gates are deliberately NOT consulted: rivals may run parts the
player has not unlocked, exactly as the engine-swap pool already ignores unlock state
([adaptive-difficulty.md](adaptive-difficulty.md), design D2).

**Why they exist:** with an engine swap as the only lever, the shipped pool ran
`min 207 / p50 475 / max 536` over 99 combos and had almost nothing above 510 — while an
upgraded player climbs well past it. Build levels take that to **396 combos,
`min 141 / p25 453 / p50 503 / p75 598 / p90 646 / max 706`**, which is what gives adaptive
difficulty room at the top, where a dominating player sits. Cost is ~300 ms to build the
pool cold and ~35 ms warm (`CarPerformance` memoises per input), once per field draw.

- **Pool** — `_eligible_combos(rally)` walks `CarLibrary.all()` ×
  `EngineLibrary.all()` × `_build_levels()`, builds each pairing's effective meta
  (`UpgradeLibrary.effective_meta({"swapped_engine": eid}, entry)`, or `{}` when
  `eid` is the car's stock engine) and keeps it if `is_eligible(rally, meta)`
  passes. Because `effective_meta` re-points `meta["engine"]` at the fitted engine
  and runs the engine-swap mass model, displacement / cylinder-count /
  post-swap-power-to-weight restrictions all apply to the swap with **no new
  authored data** — and a heavy engine in a light car correctly *lowers* the
  combo's p/w rather than only raising its power. If a restriction admits nothing
  the fallback mirrors `_eligible_cars`: every car's **stock** combo, never the
  unfiltered cross product.
  **A special has `"restriction": {}`**, and `ineligibility_reason` returns "" on an
  empty restriction before it looks at anything else — so a special's pool is the
  WHOLE cross product (every car × every engine), with no p/w band trimming it. That
  is the only way a special's field differs from an ordinary rally's: there is no
  `is_special` branch anywhere in `generate_opponent_field`. The consequence is a
  deliberately open grid — a special can field a build far above (or below) whatever
  the player brought — and it is the same openness that lets the player enter in
  anything (see *Anti-soft-lock guarantees*).
- **Distinct draw** — `_draw_distinct_combos(rng, pool, count)` samples the pool
  **without replacement, weighted by `swap_weight(pw_delta)`** with the rally-seeded
  rng, so every rival is a *different* build and modest engine swaps are picked ahead
  of wild ones (`pw_delta` is |combo p/w − the car's STOCK p/w| in hp/tonne; the
  weight is `exp(-pw_delta / OPPONENT_SWAP_PW_SPREAD)`, a bias and never a filter, so
  a wild swap stays reachable). `pw_delta` measures the **engine only** — folding a build
  level's parts into it would make `swap_weight` read a fully-built rival as a wild engine
  swap and all but exclude it, which is precisely the top-end headroom the levels add. Sampling without replacement replaced an independent
  per-rival draw **with replacement**: with 10 cars and 9 rivals, all-distinct
  happened ~0.4% of the time, so fields were routinely several copies of the same
  car. When the pool is smaller than the field it **cycles** the pool (a 3-combo
  rally fields 3+3+3) instead of drawing random repeats, so even the degenerate case
  is as varied as the pool allows.
- **Pace** — the per-rival pace math is unchanged, but `car_meta` is now the
  combo's `CarPerformance.merged_meta` (not `effective_meta`: a build level can fit tyres
  and a wing, and those reach the rating and the lap-time model only through the grip
  fields `effective_meta` withholds — for a stock combo the two are identical), so the
  swap and the build both feed `LapTimeModel.optimum_ms`. An engine carries its
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
  stock boost changes its rating no longer sits at the wrong pace in fields it used
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
duck-under-the-cap / already-eligible / unfixable cases), the **geometric reveal** gate
on a synthetic roster (`test_a_rally_inside_the_opening_rallys_circle_is_revealed_from_the_start`,
`test_a_profile_with_no_starter_sees_a_wholly_dark_map`,
`test_completing_a_rally_lights_the_map_around_that_rally`,
`test_an_incomplete_rally_lights_nothing`,
`test_a_rally_beyond_every_circle_stays_dark`,
`test_distance_beyond_frontier_is_zero_once_revealed_and_shrinks_as_you_approach`,
`test_spending_stars_cannot_close_a_reveal_gate` — see
[map-exploration.md](map-exploration.md) → "Testing" for the fixture pattern), the
**engine-derived restrictions** (displacement / cylinders resolved through the fitted
engine, so an engine swap flips eligibility; an unresolvable engine is rejected) and
`doors_min`/`doors_max`, plus a guard that **every shipped rally has at least one
eligible car**, a check that the roster's `map_pos` values are well formed, track-gen
determinism, target-time positivity + override, opponent-field
shape/bounds/determinism + DNF semantics + names drawn uniquely from the pool,
placement/top-3, progress count, and the specials-completion gate
(`test_all_specials_completed_needs_every_rung`) + the enterable query
(`test_incomplete_enterable_query_respects_eligibility_and_reveal`).
There is **no** test asserting sandstorm sits only on `greece` events (the `RALLIES`
header comment claims one exists; it does not) — the terrain/weather-per-zone rules are
authoring conventions, checked by reading the map, not by the suite. The
start-line queue cars being eligible for the rally is asserted in
`test_start_line.gd`. An integration smoke (write a rally seed into `Config.data`
→ `_generate_track`) lives in `test_smoke.gd`.

Per `CLAUDE.md`, the roster's authored numbers (`map_pos`, `reveal_radius`, turn
counts, `difficulty`) are tunable content, not test-pinned contracts — tests cover the
logic (the star curve's shape, the geometric reveal predicate, the closure guards), never
the specific authored positions or radii. (The retired `requires_completions` rungs this
line used to reference no longer exist — see the `special` field entry above.)
