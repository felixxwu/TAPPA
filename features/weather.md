# Weather (dry / rain / sandstorm / fog / storm / snow / night)

Design doc: `docs/superpowers/specs/2026-08-02-weather-design.md` (anticipated a
string enum specifically so later conditions — "fog / snow / night" — would have
an obvious home; sandstorm is exactly that case). The feature is fully implemented:
authoring, config, the funnel into the live config, tyre grip, rival-time scaling,
cache keying, the overcast/dust look and the loading-screen tell. This file is the
hub; each half is documented in depth in its own feature file, linked below.

**Tests:** `tests/headless/test_weather_library.gd`, `tests/headless/test_crosswind.gd`, `tests/headless/test_headlight_cone.gd`, `tests/headless/test_loading_screen.gd`, `tests/headless/test_track_cache.gd`

Rain and sandstorm are each a **variety** lever, not a **difficulty** one — see
"Rival times". Sandstorm is authored only onto `region == "greece"` events — the arid
desert pins in the map's SW/S, which is where the look belongs; rain has no such
restriction.
Fog and storm (`docs/superpowers/specs/2026-08-02-fog-and-storm-weather-design.md`)
are the two later conditions; **fog is deliberately NOT variety-only** — see
"Rival times" for why that asymmetry is intended rather than a bug.
**Night** (`todo/night-weather-and-headlights.md`) is the seventh entry and the
odd one out: it re-lights the world instead of only recolouring it — see "Night"
below. Five stages author it, one per region, so every region's palette can be
seen after dark. The headlight cone it introduced is no longer night-only: storm
switches the lights on as well, at a much lower strength, via the same authored
`headlights` key — see "Headlights on more than night".

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
| `sky_panorama` | GameConfig field holding a **sky texture path** the condition swaps in, overriding whatever the region chose. Omitted ⇒ the region's sky is left alone. Only `night` names one |
| `headlights` | GameConfig field holding the **strength** (0..1) of the fake headlight cone this condition switches on. Omitted ⇒ the car's lights stay off and every cone uniform is a bit-for-bit no-op. Read by `HeadlightCone`; cosmetic, so it is **not** in `physics_fields` |

**`sky_panorama` is deliberately NOT a sixth `LOOK_KEYS` entry.** `LOOK_KEYS` is
all-or-nothing — an entry with a `look` block must name every one of the five
environment knobs — and rain, sandstorm, fog, storm and snowfall are all things
happening *under* the region's sky, not a different sky. Making it mandatory would
have forced five entries to author a field they don't want, so it sits beside the
`look` block as its own optional top-level key instead.

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

**Weather is now spread near-evenly across the whole roster.** As of 2026-08 there
are **108 authored events**, and only about 30 of them are dry — every other
condition sits in the 12-14 range. Weather reads as a property of the individual
stage rather than of a region or a difficulty band. One string field per event, so a
condition is never ambiguous.

The numbers below are a SNAPSHOT of authoring, not a contract: a designer moving,
adding or removing an event changes them, and no test asserts any of it (see "Tests"
below for why placement deliberately lives here rather than in a test). What IS
durable is the two region locks and the reasons behind each condition's placement.

| Condition | Events | Where it sits |
|---|---|---|
| dry | ~30 | everywhere |
| night | ~14 | every region |
| rain / fog / storm | ~13 each | the temperate pins (`home`, `home_coast`, a few `greece`) |
| sandstorm | ~13 | the desert only (`greece` / `greece_coast`) |
| snowfall | ~12 | the alpine NE only (`region == "snow"`) |

The 2026-08 geography pass (see [rally-roster.md](rally-roster.md)) re-tagged most of
the roster, so the guidance below is stated in terms of the TERRAIN A PIN SITS ON, not
a region name — most rallies now carry `region: "home"` regardless of what their id
says, and "the coastal regions" is no longer a useful way to pick out coastal stages.

**Two of these bullets used to name the specific events that carried each condition,
and every one of those lists had rotted.** Don't reintroduce them: an event list in a
doc is stale the first time someone retunes the roster. State the CONVENTION here and
read the current placement out of `RallyLibrary.RALLIES` (grep `"weather"`).

- **Fog** — suits the damp forest and foothill pins (`home` / `home_coast`) and a
  couple of the greener Greek ones. It is the roster's only pure difficulty lever
  (see "Rival times"), so it wants to stay a minority of the roster.
- **Storm** — the crosswind originally read as belonging to **exposed water**, and
  storm was authored only on a genuine sea pin. **The current roster does not follow
  that**: most storms now sit on inland `home` pins, so treat the old "sea only" rule
  as history rather than as the convention. A storm also switches the **headlights**
  on (see "Headlights on more than night"), which is why it is the only daytime
  condition carrying a `headlights` key.
- **Snowfall** — a REGION LOCK, and the one placement rule that has held: authored
  only onto `region == "snow"` events (the alpine NE), mixed with dry stages there.
  Unlike every other precipitation condition it authors **no `grip_mult`**: the snow
  REGION already owns grip for that whole corner, dry stages included, so weather must
  not stack a second lever on the same variable. It therefore names nothing in
  `physics_fields` and never re-keys the opponent cache. See
  [snow-region.md](snow-region.md).
- **Sandstorm** — the other REGION LOCK, also intact: desert-only, i.e. the arid
  `greece` / `greece_coast` palette and a pin in the SW/S sand. A sandstorm on a green
  forest stage would look wrong. Note the `RALLIES` header comment calls this
  "test-enforced" — **it is not**: no test in `tests/headless/` asserts it, so it is a
  placement convention like the rest.
- **Night** — no terrain or region restriction: night is a time of day, so any pin can
  run it, and it is authored across every region. It was once deliberately ONE PER
  REGION on a rally's first event, so each region's palette could be compared after
  dark without playing a whole championship; the roster has long since outgrown that,
  and the old five-row table it was documented with is gone. If you want that
  comparison now, pick one night event per region out of `RALLIES`. Note the snow ones
  are worth keeping: they are the only night stages running `ps1_terrain_snow`, so
  they exercise the terrain shader variant's copy of the headlight cone rather than
  only the base shader's.

**The visibility conditions are no longer kept off difficulty-1 rallies, and that is
worth a deliberate decision rather than drift.** Fog, night and storm all slow the
PLAYER without touching the rival field (see "Rival times" — the lap-time model has no
eyes, and no wind term either), so each of them silently raises the bar on the stage
it sits on. The old guidance was to keep all three off the easiest rallies so a new
player never met one first. Today `shitbox_cup` (difficulty 1) opens on a NIGHT stage
and carries fog on its second, and two difficulty-1 rallies carry a storm. Either the
roster wants re-authoring or the guidance wants dropping — but the two should not
disagree.

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
  - `storm_headlight_amount` — the headlight cone's strength on a storm stage,
    named by the entry's `headlights` key. Authored well BELOW night's, and that
    is the whole point of the field existing — see "Headlights on more than
    night" below.

- The night block, prefixed **`night_`** — a `look` block plus a road darken, and
  nothing else (it authors no `grip_mult`, no `wind`, no `particles`, no
  `lightning`):
  - `night_background_color`, `night_sky_color` — near-black, slightly blue-lifted.
    Not pure black on purpose: `night_sky_color` is the ambient floor everything
    OUTSIDE the headlight cone is lit by, so zeroing it turns unlit geometry into
    an unreadable silhouette, and a pure-black horizon reads as a hole in the frame.
  - `night_sun_energy_mult` — **the dominant knob**: this, and nothing in any
    shader, is what makes the world dark. Its `@export_range` starts at `0.0`
    (unlike the daytime conditions) because night lives at the bottom of it.
  - `night_fog_density_mult` — deliberately kept LOW. Fog is environment-side
    (`fog_light_color`), so the headlight cone cannot light it; thick haze at
    night gives a lit pool of ground under a flat grey sheet.
  - `night_fog_sky_affect` — high, so the panorama sinks into the dark.
  - `night_road_darken` — rain's shape (a straight albedo multiply, no target
    colour): a night road is unlit, not recoloured.
  - `night_sky_panorama` — the sky texture night swaps in
    (`textures/sky-night.jpg`, a Milky-Way night equirect — see
    [asset-pipeline.md](asset-pipeline.md)). Named by the entry's optional
    `sky_panorama` key, so "a condition wants its own sky" stays authored data
    rather than a branch in `world.gd`. An empty string keeps the region's sky.
  - `default_sky_panorama` — not a night field as such: the sky every stage falls
    back to when its REGION names none (`home` / `home_coast`). Lives in the night
    block because night is what exposed the need for it — see
    [regions.md](regions.md) → "The sky no longer leaks between stages".

  **Night was authored too dark at first and has been lifted.** The first pass
  rendered the terrain near-black: `night_sky_color` is the dominant lever, because
  terrain normals face mostly UP, so the hemisphere ambient
  (`mix(ground_color, sky_color, N.y·0.5+0.5)`, see [rendering.md](rendering.md))
  resolves almost entirely to `sky_color` — a near-zero value there leaves the
  ground with nothing but the headlight cone. The retune raised `night_sky_color`,
  `night_sun_energy_mult`, `night_road_darken` (i.e. darkened less) and
  `night_background_color`. The numbers themselves are inspector tuning and are not
  quoted here; the point to carry forward is *which knob to reach for* when night
  reads too dark or too washed out.
- The **headlight-cone block**, prefixed `headlight_`. These are the odd ones out
  in this file: they are **not named by the weather table at all** and are not
  `look` keys — they are pushed to the shaders as global shader parameters once
  per frame. See "Night" below. The one exception is the cone's STRENGTH, which
  IS per-condition and IS named by the table (the `headlights` key): night reads
  `night_headlight_amount`, storm reads `storm_headlight_amount`.
  - `night_headlight_amount` / `storm_headlight_amount` — strength of the cone on
    that condition, 0..1; at exactly 0 the lights are off and every cone uniform
    is a bit-for-bit no-op. Two fields rather than one because the cone is ADDED
    to a light term whose brightness differs per condition — see "Headlights on
    more than night" below.
  - `headlight_color` — the light the cone ADDS to the light term.
  - `headlight_range_m` — how far the cone reaches before attenuating to nothing.
    A genuine difficulty knob: it sets how far ahead the road can be read.
  - `headlight_inner_deg` / `headlight_outer_deg` — HALF-angles of the fully-lit
    core and of the faded edge, in degrees; converted to cosines before upload.
  - `headlight_offset_m` — offset from the car origin to the cone apex in the
    **car's own space** (x right, y up, z FORWARD), putting the apex on the
    bonnet line so the cone does not light the car's own nose.
  - `headlight_pitch_deg` — how far below horizontal the cone is aimed, and the
    knob that actually decides **where the lit pool starts**. A perfectly
    horizontal cone only reaches the ground where its OUTER edge descends to
    ground level — roughly `headlight_offset_m.y / tan(outer)` past an apex that
    is already pushed forward — so the light appears to begin several metres in
    front of the bumper. Real headlights are aimed down for the same reason.
    Raise it to pull the pool toward the car.
  - `headlight_separation_frac` — spacing of the TWO lamps, as a fraction of the
    fielded car's width rather than an absolute distance, so a wide GT throws a
    wider pair than a kei car. The driver reads the body width from `car.gd` →
    `half_width` (doubled) — the same dimension the replay wheel-cam rig measures
    its clearance from. **0 collapses to a single cone** and makes the shader skip
    the second evaluation, so this is the cost knob as well as the look knob.

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

## Night

The seventh condition, and **purely a look** — deliberately. Its entry authors a
`look` block, a `road_tint`, a `sky_panorama` and a `headlights` strength, and
nothing else: no `grip_mult` (μ is exactly 1.0, identical to dry), no `wind`, no
`particles`, no `lightning`. It therefore
names nothing in `physics_fields()`, so it changes no lap time, needs no
rebalancing and never re-keys the opponent cache. Design rationale and the four
other settled decisions are in `todo/night-weather-and-headlights.md`.

**The darkening is not done in a shader.** It comes for free from the existing
path every condition uses: the low `night_sun_energy_mult` scales
`TerrainManager.sun_color` in `world.gd::_apply_overcast_look`, and the terrain
bakes that dark light into its vertex colours at chunk generation. By the time
any shader runs, the world is already dark.

**The re-lighting is a fake headlight cone**, evaluated analytically in the
shaders from a handful of `global uniform`s — no light node is added, and none
could be: every material in this renderer is `unshaded`, so a `SpotLight3D`
would have zero effect. `scripts/headlight_cone.gd` (`class_name HeadlightCone`)
is the whole driver: `amount(cfg)` is the live condition's cone strength straight
out of the weather table and `has_headlights(cfg)` is that being above zero — the
gate is authored DATA, not a weather id, so the "no consumer tests `== WEATHER_x`"
rule holds here too; `params(cfg, xform)` turns the car pose plus the authored
knobs into a name→value dictionary, `push()` is pure
transport onto `RenderingServer.global_shader_parameter_set`, and `reset()`
zeroes it. `world.gd::_process` pushes once per frame and early-outs on a
condition that authors no cone; `world.gd::_exit_tree` calls `reset()` because
shader globals persist across scene changes and the podium and HQ draw with the
same shaders. The shader half — why additive, why fragment on terrain and vertex
elsewhere — is in [rendering.md](rendering.md) → "The fake headlight cone".

### Headlights on more than night

**Storm switches the headlights on too, at a much lower strength — and the low
strength is the load-bearing part, not an afterthought.** The cone is ADDED to
the light term (`ALBEDO = surface * (light + hl_color * headlight_lit(...))`),
and that light term is not the same brightness on the two conditions: night's
bake is near-black, while a storm's is a *dimmed day* (`storm_sun_energy_mult` is
a fraction, not near-zero). Running night's full-strength cone on top of a
storm's bake sums past 1 and clips the lit pool to white — the combined value is
simply too bright. So the strength, alone among the cone's knobs, is
**per-condition**: the table's `headlights` key names each condition's own
GameConfig field, and everything else about the cone (colour, range, angles,
offset, pitch, lamp separation) stays shared.

Consequences worth knowing:

- **A third condition wanting headlights is pure authoring** — add a strength
  field and name it from the entry. No change to `HeadlightCone`, `world.gd`, the
  shaders or the include.
- **It costs a storm stage the per-frame push it did not pay before**: `_process`
  now writes the cone uniforms every frame on a storm as well as a night stage.
  That is nine global uniform writes, no geometry and no draw calls (the
  fragment-side cone on terrain was already compiled into the shader on every
  stage) — but a storm stage is no longer bit-for-bit identical to a dry one.
- **It changes no lap time.** `headlights` is cosmetic, so it stays out of
  `physics_fields()` and re-keys nothing; storm's rival field is unchanged.

### Unshaded means nothing dims for free — `weather_lit` is the rule

This is a **bug class**, not a list of unrelated fixes. Every material in this
renderer is `unshaded`, so **no material dims because the world got darker** —
each one has to be *told*, and each one that isn't told keeps rendering full
daylight while everything around it goes dark. That glows: a bright object
against a dimmed world reads as lit from a sun that isn't there. It bit four
separate surfaces before the rule was consolidated (car, trees, lakes, signs),
and it will bite the next fake-lit material added unless that material is routed
through the one place that knows the rule.

**The rule lives in `GameConfig.weather_lit(col)`** (`scripts/game_config.gd`) —
multiply the RGB of an authored colour by the runtime `weather_sun_mult` and
**leave alpha alone**. Alpha carries meaning (the water colours use it), so
scaling it would make a dim lake *transparent* rather than *dark*. Anything that
hands an authored colour straight to a shader goes through it.

**The multiplier**: `GameConfig.weather_sun_mult` is **not exported and not
authored** — a runtime value on the shared `Config.data`.
`world.gd::_apply_overcast_look` seeds it from the condition's `sun_energy_mult`
(the same number it bakes into `TerrainManager.sun_color`), and
`_apply_weather_look` re-seeds it to **1.0 every stage boot**, for the same
reason the road tint is re-seeded: a condition with no `look` block must leave a
clean 1.0 behind, or a dry stage would inherit the previous stage's dimming. It
defaults to 1.0 so a session-less boot is unaffected.

**Every surface, and how the weather reaches it:**

| Surface | Route |
|---|---|
| Terrain / road | the bake — `TerrainManager.sun_color`/`sky_color` are scaled directly and baked into vertex colours at chunk generation (never via `weather_lit`) |
| Car (chassis, cabin, wheels, swapped-in body models) | `GameConfig.apply_car_light` → `weather_lit(sun_color)` / `weather_lit(sky_color)` |
| Foliage billboards (trees) | `GameConfig.apply_foliage_light` → same two colours, `billboard_opaque.gdshader` |
| Water / ice (`scripts/lake_field.gd` → `build`) | `weather_lit` on the water + shore colours, and `sparkle_strength` scaled by `weather_sun_mult` (the sparkle is a sun glint) |
| Roadside signs (`scripts/sign_field.gd` → `_material_for`) | `weather_lit` on `albedo_color` |

**The other way out of this bug class: don't author a colour at all.** Tire marks hit
exactly the same problem — a constant grey rut stayed as bright at night and on snow as
on a sunlit road, reading as paint laid over the world — but they are *not* on the
`weather_lit` list, because they were fixed from the other side. Both mark colours are
**pure black with the intensity in the alpha**, so a mark darkens whatever ground is
under it and tracks the environment for free, in every condition and region, with no
per-weather plumbing to forget. Where a surface can express itself as opacity over the
world rather than as a lit colour, prefer that — there is nothing left to re-seed. See
[tire-marks.md](tire-marks.md) → *Colour*.

`ground_color` — the bounce off the surface below — is deliberately **not**
dimmed in either `apply_car_light` or `apply_foliage_light`: it is dominated by
the ground's own albedo, not by the sun.

**Why signs need `albedo_color` specifically**: unlike the terrain, signs carry
**no baked vertex light** (their `COLOR` is the default white), so `albedo_color`
is the *only* channel the weather has into them.

**Why foliage needed its own helper**: `scripts/billboard_field.gd` used to push
five raw `Config.data` values at the billboard shader inline. The directional
term there is `sun_color * ndl`, so a raw `sun_color` left every tree lit on its
sunward side at night — where there is no sun. `apply_foliage_light` mirrors
`apply_car_light` exactly, so trees, car and ground now agree on the light by
construction rather than by three copies staying in sync.

**The reset**: `world.gd::_exit_tree` sets `Config.data.weather_sun_mult = 1.0`
alongside the existing `HeadlightCone.reset()`. `weather_sun_mult` is a runtime
value on the **shared** `Config.data` and nothing anywhere calls
`Config.reset()`, so without this a night stage would leave the HQ and the podium
dimmed — both spawn trees through `Foliage.spawn_trees`, which now reads it via
`apply_foliage_light`. `_exit_tree` covers every exit path regardless of
destination, and runs before the incoming scene's `_ready`.

**This visibly changes rain and storm** as well as night, which is intended:
their cars, trees, lakes and signs are now dimmer than before, matching the
ground they sit on.

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
  dict, so **authoring a condition onto an event gives that event a new board** and
  leaves every other stage's alone. That is per-event and automatic, not a one-off:
  each later weather pass re-boarded whatever it re-authored. No
  `TrackCache.BOARD_EPOCH` bump is needed — this is not a global engine change.

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

**Night is the one condition that does swap the sky.** If the entry names a
`sky_panorama` field, `_apply_weather_look` loads the path that field holds onto the
`PanoramaSkyMaterial`, **after** `_apply_region_look` has run — so a condition that
names a sky wins over the region's choice, and the five that don't leave the region's
sky exactly as the region look seeded it. That ordering is only safe because the
region look now assigns the sky **unconditionally** (falling back to
`GameConfig.default_sky_panorama`) instead of only when the region authors one;
without that re-seed the night sky would survive into the next stage, since the sky
material is a shared `main.tscn` sub-resource just like the floor material below. See
[regions.md](regions.md) → "The sky no longer leaks between stages".

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
shared `GameConfig`'s authored colours, so a later dry stage in the same process
is not left dimmed/tinted. The one runtime value it does write back to the config
is `weather_sun_mult` (so the car dims with the ground) — and that is explicitly
re-seeded to 1.0 at the top of `_apply_weather_look` for exactly the same
leak reason. See "Cars now dim with the world" above.

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
- `tests/headless/test_headlight_cone.gd` — the night condition and the cone,
  behaviour only: the gate is the weather table's `headlights` key, driven through
  a synthetic table so no test depends on WHICH conditions light up — a condition
  naming a strength field arms the cone and one naming none does not, a condition
  authored at exactly 0 is off, two lit conditions each push their OWN strength
  rather than one shared constant, and a null config is not a crash; every
  `headlights` field the SHIPPED table names (iterated opaquely) is a real
  `GameConfig` float in 0..1, and none of them reaches `physics_fields`; the two
  dark conditions (night, storm) do arm the cone, with no assertion about how
  brightly either burns; `params` is empty on a condition with no cone; the cone points and its apex offset
  rotates with the car; the outer edge is always wider than the inner one and
  the range is never zero however the two are authored; strength clamps to
  0..1; the night entry authors every `LOOK_KEYS` field and touches no physics
  field; `apply_car_light` scales with `weather_sun_mult` and defaults to no
  dimming; `weather_lit` dims RGB and leaves **alpha untouched** (a scaled alpha
  would make a dim lake transparent instead of dark);
  `apply_foliage_light` dims the trees' sun with the weather (strictly darker,
  proportionally); and trees and car take the **same** sun colour on every
  channel, so the two helpers can't drift apart; every night-lit shader `#include`s the cone and ADDS it to the light
  term rather than multiplying; and `ps1_models` still has no vertex stage. No
  authored angle, range, colour or strength is pinned. Plus the sky override:
  `test_night_names_a_sky_and_no_other_condition_does` — night's `sky_panorama`
  key names a real `GameConfig` string field holding a non-empty path, and every
  OTHER entry in `WeatherLibrary.all()` (iterated opaquely, no id named) has no
  `sky_panorama` at all, pinning that the mechanism stays opt-in rather than
  drifting into a sixth mandatory look key. `test_there_is_a_default_sky_for_regions_that_name_none`
  — `default_sky_panorama` is non-empty and `ResourceLoader.exists` on it (and on
  `night_sky_panorama`); an empty default would silently reintroduce the
  cross-stage sky leak, since the region look falls back to it. Neither test names
  a texture path.
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
