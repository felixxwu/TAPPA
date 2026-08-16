# Weather (dry / rain / sandstorm / fog / storm)

Design doc: `docs/superpowers/specs/2026-08-02-weather-design.md` (anticipated a
string enum specifically so later conditions — "fog / snow / night" — would have
an obvious home; sandstorm is exactly that case). The feature is fully implemented:
authoring, config, the funnel into the live config, tyre grip, rival-time scaling,
cache keying, the overcast/dust look and the loading-screen tell. This file is the
hub; each half is documented in depth in its own feature file, linked below.

Rain and sandstorm are each a **variety** lever, not a **difficulty** one — see
"Rival times". Sandstorm is authored only onto `region == "greece"` events — the arid
desert pins in the map's SW/S, which is where the look belongs; rain has no such
restriction.
Fog and storm (`docs/superpowers/specs/2026-08-02-fog-and-storm-weather-design.md`)
are the two later conditions; **fog is deliberately NOT variety-only** — see
"Rival times" for why that asymmetry is intended rather than a bug.

## The weather table (`WeatherLibrary`) — the single source of truth

`scripts/weather_library.gd` (`class_name WeatherLibrary`) is the authored catalogue
of conditions, in the style of `CarLibrary.CARS` / `RallyLibrary.RALLIES` /
`RegionLibrary.REGIONS` (same `Registry.Seam` all/`override_for_test`/reset seam).
**Every consumer reads this table; none of them tests `== WEATHER_x`.** Before it,
the same "which condition is this?" rule was reimplemented as a parallel `if` chain
in five files that all had to be kept in sync.

An entry holds the condition's **shape** — WHICH GameConfig fields it reads and which
structural features it has — never the numbers (those stay in
`config/game_config.tres` per the project rule). Keys, all optional but `id`; an
omitted key means "this condition does not have that feature":

| key | meaning |
| --- | --- |
| `id` | stable id; matches the authored event string, `RallyLibrary.WEATHER_*` and `GameConfig.weather` |
| `grip_mult` | GameConfig field holding the global tyre μ multiplier. Omitted ⇒ **exactly 1.0** |
| `particles` | `WeatherField` particle kind (`"rain"` / `"sand"`). Omitted ⇒ no particle field is constructed |
| `particle_count` | GameConfig field for the quad count |
| `wind_dir` | GameConfig field for the particle wind heading in degrees |
| `look` | maps each `LOOK_KEYS` entry (`background_color`, `sky_color`, `sun_energy_mult`, `fog_density_mult`, `fog_sky_affect`) to the GameConfig field supplying it. Empty ⇒ the world look is not touched |
| `particle_speed` | GameConfig field for the particles' travel speed (m/s). Omitted ⇒ the particle kind's own built-in speed |
| `road_tint` | `{"amount": <field>, "color": <field>}`. `color` names the colour the albedo is **lerped toward**; **omitted ⇒ a plain darkening multiply**. Omitted entirely ⇒ road albedo untouched |
| `wind` | lateral **crosswind body force**: `strength` / `gust` / `dir_deg` → GameConfig fields (`WIND_KEYS`). Omitted ⇒ no wind force. Read by the crosswind force in `car.gd` — see [car-physics.md](car-physics.md) |
| `lightning` | cosmetic **flash**: `flash` / `duration` / `interval_min` / `interval_max` → GameConfig fields (`LIGHTNING_KEYS`). Omitted ⇒ no flashes. Read by `world.gd` → `_start_lightning` |

There is **no `"mode"` string and no colour literal in `world.gd`** — a condition that
tints the road toward something new (dust today, snow tomorrow) just names a colour
field. Same for particle speed: `WeatherField` reads no condition's config field
itself, so the "every consumer goes through the table" rule holds without exception.

**Two field sets, and the rule that separates them:**

- `config_fields(entry)` — every GameConfig field the entry names. Its full surface,
  used for validation and tests.
- `physics_fields(entry)` — **only** `grip_mult` and the `wind` block, i.e. the values
  that can change *how fast the stage is driven*. This, and only this, is what
  `fingerprint()` hashes.

Everything else — particle counts, every colour and fog value in `look`, the road
tint, the lightning flash — is LOOK, and deliberately stays out of the physics
fingerprint. The safety net for a *new*
condition (or a new key) that does affect times is `fingerprint()`'s `str(all())`:
any structural edit to the table re-keys everything regardless. Both sets
de-duplicate — storm points both its particle `wind_dir` and its force's
`wind.dir_deg` at one heading, so the drops stream the way the car is pushed.

Public API (a contract — other conditions are added against it):

- `WeatherLibrary.all()` / `override_for_test(...)` / `reset()` — the standard seam.
- `by_id(id) -> Dictionary` — **an unknown id returns the DRY entry**, mirroring
  `RallyLibrary.event_weather`'s tolerance of a typo, so consumers read it unguarded.
- `grip_mult(cfg, id) -> float` — the μ multiplier from the named config field;
  dry (and therefore any unknown id) is exactly **1.0**.
- `config_fields(entry) -> Array` — every GameConfig field name the entry references.
- `physics_fields(entry) -> Array` — the subset that can change a lap time
  (`grip_mult` + the `wind` block). See the rule above.
- `fingerprint(cfg) -> String` — hash of the whole table plus every *time-affecting*
  config value it names.

**Dry is the absence of every feature** — its entry is literally `{"id": "dry"}`. That
is load-bearing, not tidiness: grip becomes an unconditional multiply by 1.0, and the
look/road/particle blocks are all skipped, so a dry stage constructs nothing and
writes nothing and keeps **exactly zero** added per-frame cost (a hard requirement on
the low-end phones this game targets).

### Adding a condition

1. Add its tuning fields to `scripts/game_config.gd` + `config/game_config.tres`.
2. Add one entry to `WeatherLibrary.CONDITIONS` naming those fields (and, if it wants
   a name in code, a `WEATHER_*` const in `rally_library.gd`).
3. Author `"weather": "<id>"` on the events that should run it.

No consumer changes. If the condition needs a genuinely new *kind* of feature (a wind
force, a lightning flash) add a new entry key plus the one consumer that reads it, and
list it in `config_fields` — then, **only if it can change a lap time**, in
`physics_fields` too, so it re-keys the opponent cache.

## Authored field

An EventDef (`RallyLibrary.RALLIES`, `ChallengeLibrary`, `BenchmarkMode`, free roam
via `hq.gd`) may carry an optional `"weather"` string, e.g.:

```gdscript
{"seed": 31001, "turn_count": 22, "forestiness": 0.7, "surface_mix": 0.6,
 "straightness": 0.8, "weather": "rain"},
```

Weather is **authored, never random** — a wet stage is wet on every attempt, so
its leaderboard (`RallyLibrary.stage_key`) compares like with like.

`RallyLibrary.event_weather(event) -> String` (`scripts/rally_library.gd`) resolves
it **through the table** — `WeatherLibrary.by_id(...)["id"]` — so any condition in
the table is authorable immediately, and an omitted key or any unrecognised string
(a typo) resolves to `RallyLibrary.WEATHER_DRY` via `by_id`'s dry fallback.
Mirrors the style of the sibling accessors `event_forestiness` / `event_tarmac_fraction`
/ `event_straightness` / `event_cliffiness` in the same file.

A string enum (not a `0..1` float) so `"fog"` / `"snow"` / `"night"` have an
obvious home later — each new condition brings its own config block, and the
funnel below does not change.

Roughly **38 of the 90 authored events are wet**, chosen at random with a fixed
seed and written into the table. They are spread across the roster rather than
clustered in one region, so weather reads as a property of the individual stage.
**4 events are sandstorm, 3 fog and 2 storm.** One string
field per event, so a condition is never ambiguous — the later conditions were only
authored onto events that had no `weather` key at all.

The 2026-08 geography pass (see [rally-roster.md](rally-roster.md)) re-tagged most of
the roster, so the guidance below is stated in terms of the TERRAIN A PIN SITS ON, not
a region name — most rallies now carry `region: "home"` regardless of what their id
says, and "the coastal regions" is no longer a useful way to pick out coastal stages.

- **Fog** — authoring guidance (a design convention, not an assertable invariant —
  a designer is free to move a fog event or add a fourth one; see
  "Tests" below for why this lives here rather than in a test): fog suits the damp
  forest and foothill pins (`region` `home` / `home_coast`), and is authored
  DELIBERATELY SPARINGLY — it's the roster's only difficulty lever (see "Rival
  times"), so keep it a minority of the roster and off any difficulty-1 rally so
  a new player never meets it first. Shipped today onto one stage each of The
  Foothills Trial, Pinewood Sprint and Ridgeline Dash — all difficulty 2/3, all in the
  northern pines or the eastern foothills.
- **Storm** — authoring guidance, same caveat as fog above: a storm's crosswind reads
  as belonging to **exposed water**, so it is authored ONLY on a pin actually on the
  sea. Shipped today on 12 Cylinder Promenade and Island GP — the roster's only two
  genuine sea pins. A river valley gets heavy rain instead: RWD Masters and the
  Drivetrain Conversion trial both carried a storm through an earlier pass and were
  re-authored to rain, since a crosswind inland is just weather with a costume on.
- **Sandstorm** — authoring guidance: desert-only, which today means
  `region == "greece"` (the arid look/palette) and a pin in the SW/S sand — Dust
  Devils, Ancient Ruins, The Hot Gates and the Greek Showdown. A sandstorm on a green
  forest stage would look wrong. Note the `RALLIES` header comment calls this
  "test-enforced" — **it is not**: no test in `tests/headless/` asserts it today, so
  treat it as a placement convention like fog and storm, not a logic contract.

## Config (`GameConfig`, `scripts/game_config.gd`)

- `weather: String` — the LIVE condition for the stage currently being played
  (`RallyLibrary.WEATHER_DRY` / `WEATHER_RAIN` / `WEATHER_SANDSTORM`). Seated only
  by `RallySession.apply_event_config` (see below) — never assigned anywhere else.
- The authored rain block, near `gravel_grip`/`tarmac_grip` and the fog/sky
  exports:
  - `rain_grip_mult` — global tyre μ multiplier applied when wet (a single
    multiplier regardless of surface — see the design doc's §2 trade-off note on
    why per-surface was deferred).
  - `rain_background_color`, `rain_sky_color` — flat overcast fog/horizon/sky and
    dimmer cooler ambient, replacing the region's clear-day palette on a wet stage.
  - `rain_sun_energy_mult` — knocks the sun back.
  - `rain_fog_density_mult`, `rain_fog_sky_affect` — thickens the haze and pushes
    it to tint the sky (inverting the normally-low `fog_sky_affect` so fog washes
    the panorama into a featureless overcast dome).
  - `rain_road_darken` — darkens the road/ground albedo.
  - `rain_particle_count` — rain quads alive at once in the camera-parented
    particle system; only instantiated on a wet stage.
- The parallel sandstorm block, same shape, tan/dust-toned:
  - `sand_grip_mult` — global tyre μ multiplier applied during a sandstorm, same
    mechanism as `rain_grip_mult` (both branches of `Drivetrain.surface_tire_params`
    plus `LapTimeModel._surface_grip`, so the AI field and the player agree).
  - `sand_background_color`, `sand_sky_color` — flat dusty-tan fog/horizon/sky and
    warm muted ambient.
  - `sand_sun_energy_mult`, `sand_fog_density_mult`, `sand_fog_sky_affect` — same
    roles as their rain counterparts.
  - `sand_road_tint` / `sand_road_tint_color` — unlike rain's straight darkening
    multiply, this *lerps* the road/ground albedo toward an authored dust colour
    (dust cakes on the surface rather than just wetting it). The colour is a config
    value named by the entry, not a literal in `world.gd`.
  - `sand_particle_count` — dust quads alive at once; only instantiated during a
    sandstorm.
  - `sand_wind_speed` — m/s the dust travels at.
  - `sand_wind_dir_deg` — a single fixed compass heading (0 = world +X, 90 = world
    +Z) the dust blows toward for the whole stage, regardless of which way the car
    or camera faces.

- The fog block, prefixed **`mist_`** rather than `fog_` purely to avoid colliding
  with the BASE environment knobs `fog_density` / `fog_sky_affect` every stage uses:
  - `mist_background_color`, `mist_sky_color` — a **pale, LUMINOUS** grey. Fog is
    *bright*; the common mistake is authoring it dark enough to read as dusk, so
    these are deliberately the lightest colours in the whole weather block.
  - `mist_sun_energy_mult` — near 1.0. Diffuse glare is what sells mist, so the sun
    is barely touched and the density does all the work.
  - `mist_fog_density_mult` — the **dominant** parameter; this is the whole effect.
  - `mist_fog_sky_affect` — high, like rain's, so the panorama washes out.
  - There is deliberately **no** `mist_grip_mult` and **no** `mist_road_darken`: fog
    authors no `grip_mult` (μ is exactly 1.0, identical to dry) and no `road_tint`
    (a foggy road is dry), and no `particles` at all.
- The storm block — rain's look and rain's particle *kind*, authored heavier:
  - `storm_grip_mult` — a storm is wetter than plain rain, so normally the lower of
    the two. Same mechanism as `rain_grip_mult`, so the AI field scales with it.
  - `storm_background_color`, `storm_sky_color`, `storm_sun_energy_mult`,
    `storm_fog_density_mult`, `storm_fog_sky_affect`, `storm_road_darken`,
    `storm_particle_count` — the rain fields' roles, darker/heavier.
  - `storm_wind_strength`, `storm_wind_gust` — the crosswind body force, an
    **absolute force in newtons** applied to the car body with no mass term. A
    heavier car is shoved less for free, because the same force is a smaller
    acceleration — not because the value is per-tonne.
  - `storm_wind_dir_deg` — one heading, shared by the force AND the rain particles'
    `wind_dir`, so the drops visibly stream the way the car is being pushed.
  - `storm_lightning_flash` / `_duration_s` / `_interval_min_s` / `_interval_max_s`
    — the cosmetic flash. Subtle and infrequent on purpose: a flash that blanks the
    screen mid-corner is a gameplay event, not an effect.

All authored in `config/game_config.tres`, per the project rule that tuning values
live in the resource, not script literals — the `@export` defaults in
`game_config.gd` are fallbacks only.

**Weather never reaches `TrackGenParams` or the track cache.** It is not a
track-shape determinant; routing it into generation would invalidate all baked
track-cache entries for no shape change. Nothing in this piece of work adds it
there — keep it that way.

## One funnel into the live config

`RallySession.apply_event_config(cfg: GameConfig, event: Dictionary)`
(`scripts/rally_session.gd`) seats `cfg.weather = RallyLibrary.event_weather(event)`
alongside `track_seed` / `track_turn_count` / `track_tarmac_fraction` / etc. This
function is the ONE place a stage's parameters reach the live config, pulled at
consume time by `world.gd._ready` via `DrivingContext.apply_stage_config` — so a
new scene-entry site cannot forget to seat a field. Weather has no side channel.

Because `apply_event_config` reloads the authored baseline (`load(Config.CONFIG_PATH)`)
and pins every omitted field to it rather than the current session config, a
session-less caller (free roam, benchmark, dev boot) that passes an event with no
`"weather"` key ends up dry automatically — same mechanism that already protects
`track_water_level_m` etc. from leaking one event's override into the next.

## Grip

`Drivetrain.surface_tire_params` scales `mu_mult` by
`WeatherLibrary.grip_mult(cfg, cfg.weather)` **unconditionally** — dry is exactly
1.0, so there is no `if weather == …` here at all — in **both** branches
(terrain-backed and the off-terrain flat-fixture fallback), so every condition
applies everywhere including in tests. This is the per-contact hot path (once per
wheel per physics tick) and must stay allocation-free, so the multiplier is
**memoised** on `_weather_mu` / `_weather_mu_id` / `_weather_mu_cfg` and re-resolved
only when the live condition string or the config resource changes (a stage
transition). The steady-state cost is the same one string compare plus one
multiply it was before, and the table lookup never runs per contact. `slip_peak` and
`slide_ratio` are deliberately untouched. `surface_grip()` is a thin wrapper over
the same `mu_mult`, so it inherits both for free. Details in
[drivetrain-and-tires.md](drivetrain-and-tires.md).


## Lightning

`world.gd` → `_start_lightning`, built only when the entry authors a `lightning`
block. Deliberately **not a new light node** — the renderer is unshaded with baked
vertex lighting and has no lights at all ([rendering.md](rendering.md)) — so the
flash is a short tween on values the weather look *already* drives: the
Environment's `fog_light_color` / `background_color` (fast rise, slower fall, the
shape of a real strike). One `Timer` re-arms itself at a random interval in
`[interval_min, interval_max]`.

It touches **only** the Environment, never the `TerrainManager`'s baked sun/ambient
(changing those would need a chunk rebake, which is not a per-frame operation), and
it is **purely cosmetic** — it changes no physics and no time, so unlike the
crosswind it need not be deterministic and is free to use `randf()`. That is also
why its config fields stay out of `config_fields`/`fingerprint`.

## Rival times — why rain/sandstorm are variety, not difficulty (and fog is not)

`LapTimeModel._surface_grip` applies the same `WeatherLibrary.grip_mult`, also
unconditionally.
Every rival's time is a multiple of that car's physics optimum
(`RallyLibrary.PACE_FAST_BASE` 1.10× down to a tier-dependent slow end), so scaling
the optimum scales the **entire AI field**.

A wet or sandstorm stage is therefore no harder to podium than a dry one — it
changes *how the car must be driven*, not *how hard the stage is to win*. That is
a deliberate design decision, not a side effect. To make either condition
genuinely raise the bar, hold rival pace fixed while the player loses grip: a
one-line change here, but a real change in what the feature means.

### Fog is the exception — a DIFFICULTY lever, on purpose

**This asymmetry is intended. It is not a bug, and it must not be "fixed" by adding
a rival penalty without a deliberate design decision.**

Fog attacks **visibility**, and visibility is not in the lap-time model — nor can it
ever be. Every rival time is synthesised from that car's physics optimum; the AI has
no eyes and never drives the stage. Fog therefore slows only the **player** while the
podium cut stays exactly where it was on a dry run, which makes it the first and only
condition in the table that raises the bar rather than changing the flavour.

The spec (`docs/superpowers/specs/2026-08-02-fog-and-storm-weather-design.md`) offered
three options — accept it, compensate with a rival pace penalty, or reserve fog for
step-up stages. **Option 1 was chosen: accept it.** A compensating penalty would be a
pure guess (there is no principled way to say how much a given fog density costs a
good player) and would erase the one difficulty texture the roster has that pure grip
changes cannot produce. What it costs instead is authoring discipline: fog is on
**few** events, none of them in a difficulty-1 rally, so the roster's early stages
are unaffected — see "Authored field" above.

Storm inherits a milder version of the same thing: its rain component *does* scale
the rival field through `storm_grip_mult`, but its **crosswind is a player-only
load** on top (no wind term exists in the lap-time model either). Storm is therefore
mostly variety with a small difficulty edge, and is likewise weighted toward the
higher-difficulty rallies pinned on open water.

## Caches and leaderboards

- **Track cache: unaffected.** Weather is not a shape determinant and never reaches
  `TrackGenParams`, so no track entry is invalidated by a wet event.
- **Opponent field: nothing to invalidate.** The rival grid is generated live in
  `RallySession.start_rally` (it is matched to the player's car rating, so it was
  never cacheable per rally), and a weather retune therefore lands on the next start
  with no bake step. `WeatherLibrary.fingerprint(cfg)` survives as the structural
  guard on the rule above — one hash of the whole weather table plus every
  **time-affecting** config value it names (`physics_fields`: `grip_mult` + `wind`),
  rather than a hand-written list of grip fields, so adding a condition or a key can
  never silently slip a lap-time change past review.
- **Global leaderboards:** `RallyLibrary.stage_key` hashes the whole authored event
  dict, so the 28 wet events and 7 sandstorm events each got new boards; every
  other stage kept its own. No `TrackCache.BOARD_EPOCH` bump — this is not a
  global engine change.

## Look

The overcast/dust look is done entirely with **fog, not a second sky**:
`fog_sky_affect` is normally kept low (~0.15) so the panorama reads clearly above
the haze; a wet or sandstorm stage inverts that to its own `*_fog_sky_affect`
(~0.9) and colours the fog flat (grey for rain, dusty tan for sandstorm), washing
the *existing* panorama into a featureless dome. No extra texture in the Android
bundle and no extra draw call — so the environment half of any condition is free.
It is **not** cheaper than a dry stage, though: the denser fog shortens the *visible*
distance but not the *drawn* one, because the terrain chunk ring and the shared
tree/prop render distance are fixed radii that read no fog value at all. See
[rendering.md](rendering.md) → "Fog does not shorten the cull" — that unclaimed
performance win matters most for fog, whose density multiplier is the largest in the
table.

`world.gd._apply_weather_look` looks the condition up in `WeatherLibrary` once and
applies whatever its entry authors — nothing more.

**The road tint is idempotent, and that is load-bearing.** `_tint_road` does a
read-modify-write on the floor `ShaderMaterial`, which is a **shared sub-resource of
`main.tscn`** (no `resource_local_to_scene`), so it survives every scene
instantiation in the process. `world.gd._ready` therefore RE-SEEDS both parameters it
touches from the authored baseline before `_apply_weather_look` runs — `tarmac_color`
from the config/region look, and `albedo_color` from `GameConfig.terrain_tint` (a
region may override it with a `terrain_tint` look key). Without that re-seed a
three-event rally with two wet stages left the ground at `rain_road_darken²`, and
every later DRY stage stayed darkened; sandstorm was worse, converging toward solid
tan. Guarded by `test_render_smoke.gd` →
`test_stage_boot_re_seeds_the_ground_albedo_from_the_authored_baseline` and
`test_road_tint_applies_once_per_stage_and_never_compounds`.

Dry authors no `look`, no
`road_tint` and no `particles`, so all three blocks are skipped: a dry stage
constructs nothing and carries **exactly zero** added per-frame cost. Every
condition shares the same override mechanism (`_apply_overcast_look` for the
sky/fog/terrain-light, `_tint_road` for the ground) fed the field names from its
entry, rather than a copy-pasted path each. Note it is called after `apply_terrain_light`, not right after
`_apply_region_look` — the lines between clobber `tarmac_color` and the terrain's
sun/ambient, so calling it earlier would let the clear-day values win. The
darkened/tinted sun/ambient is written onto the `TerrainManager`, never onto the
shared `GameConfig`, so a later dry stage in the same process is not left
dimmed/tinted.

Particles (`scripts/rain_field.gd`, class `WeatherField`) are camera-parented and
constructed only when the entry names a particle **kind**: `world.gd` calls
`WeatherField.spawn(camera, kind, count, wind_deg)`, which dispatches to `spawn_rain`
/ `spawn_sandstorm`; an empty kind builds nothing (how a future no-particle condition
gets that behaviour for free). Both simulate in **world space** (`local_coords = false`): a
particle's motion, once spawned, is independent of the camera's own movement, so
driving forward genuinely carries the car through standing rain/dust — correct
parallax and streaking-past-the-windscreen emerge from the simulation itself,
automatically faster at higher speed, with no per-frame script cost. Sandstorm
adds a single fixed **world-space wind direction** (`sand_wind_dir_deg`) that a
world-space field can express directly — this would have been awkward under
local-space simulation, where a "fixed" direction actually rotates with the
camera. See [rendering.md](rendering.md) for the full mechanism and why an
earlier local-space + per-frame-speed-tilt version was replaced.

**The loading screen no longer names the condition.** That line now counts stages
("Loading stage 2 of 3…"), and the two cannot share it — mixing them meant the stage
number could only ever appear on dry stages. The `loading_tell` field the tell was read
from has been removed with it, rather than left as data nothing consumes. Weather still
announces itself in the world the moment the stage loads. See [loading.md](loading.md).

## Tests

- `tests/headless/test_weather_library.gd` — the table itself: `by_id` falls back to
  the dry entry for an unknown/empty id; dry's `grip_mult` is exactly 1.0 and dry
  constructs nothing (both structural identities, not tuned values); `grip_mult`
  reads the config field the entry names; `config_fields` reports every referenced
  field while `physics_fields` reports only the time-affecting subset, and a purely
  cosmetic retune leaves `fingerprint` unchanged where a grip retune re-keys it; `fingerprint` changes when the table changes or a referenced value is
  retuned, and is stable otherwise. All against a synthetic table via
  `override_for_test`, never the shipped conditions' numbers. Also: a
  **visibility-only** shape (fog's — a `look` block alone) has grip exactly 1.0, no
  particle kind and no road tint, where a precipitation sibling in the same synthetic
  table has all three; `config_fields` folds in a `wind` block but not a `lightning`
  one, and reports a field shared by two keys once; and every `wind`/`lightning`
  field the SHIPPED table names is a real `GameConfig` property (the table iterated
  as opaque input, no entry named).
- `tests/headless/test_render_smoke.gd` →
  `test_a_condition_without_a_particle_kind_constructs_no_field` — driven through the
  same `WeatherField.spawn` seam `world.gd` uses: an entry naming no particle kind
  builds nothing and adds nothing to the scene; one naming a kind builds exactly one.
  `test_lightning_spikes_the_environment_colour_and_restores_it` — the flash
  brightens the environment colour, returns EXACTLY to the stage's own colour (a leak
  would leave the stage permanently mis-lit) and re-arms its timer, driven with a
  synthetic lightning block so no authored brightness or interval is pinned.
- `tests/headless/test_rally_library.gd` → `test_event_weather_defaults_to_dry` —
  dry for an omitted key, dry for an unrecognised string, and every other condition
  in `WeatherLibrary.all()` (opaque, no id named) resolves to itself. Region/count
  placement for fog, storm and sandstorm is intentionally NOT asserted — it's
  authoring policy a designer can retune freely (moving a fog event, adding a
  fifth one), so pinning it as a test would fail on a legitimate content change
  with no bug present; see "Authored field" above for the guidance instead.
- `tests/headless/test_rally_session.gd` →
  `test_apply_event_config_carries_weather_and_defaults_to_dry` — an event's
  weather lands on the config; an event with no weather key leaves it dry.
- `tests/headless/test_drivetrain.gd` — a wet contact yields strictly less μ than
  the identical dry one, in both branches.
- `tests/headless/test_lap_time_model.gd` — a wet event's optimum is strictly
  longer than the same event dry.
- `tests/headless/test_render_smoke.gd` — no rain field exists on a dry stage.
- `tests/headless/test_loading_screen.gd` — the wet tell changes the headline.

Every one asserts a **relation or structure**, never a tuned value — retuning
`rain_grip_mult` or any rain colour in the inspector must not break a test.
