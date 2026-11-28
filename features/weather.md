# Weather (dry / rain / sandstorm / fog / storm / snow / night)

On the Hafren level the weather drifts: `LevelWeather` cuts drive time into slots, draws a
condition for each from a weighted pool, and cross-fades fog, sky and brightness into it.
Every effect of a condition (grip, particles, crosswind, tree sway, headlights, wet-road
rules) is read out of one table, `WeatherLibrary`.

**Tests:** `tests/headless/test_weather_library.gd`, `tests/headless/test_level_weather.gd`,
`tests/headless/test_crosswind.gd`, `tests/headless/test_headlight_cone.gd`,
`tests/headless/test_wind_sway.gd`, `tests/headless/test_lighting_coverage.gd`

**Everything drawn must take the light:** `test_lighting_coverage.gd` fails on any 3D shader
that doesn't reach `headlight_cone.gdshaderinc` (which declares `world_light` and the cone),
any script building a plain material, and any `.tscn` / `.glb` mesh drawn by such a material,
unless it is in that test's `EXEMPT` list (with a reason) or `KNOWN_GAPS`.

## The weather table (`WeatherLibrary`)

`scripts/weather_library.gd` is the authored catalogue of conditions, behind the same
`Registry.Seam` as `CarLibrary` (`all()` / `override_for_test(...)` / `reset()`). **Every
consumer reads this table; none tests `== WEATHER_x`.**

An entry holds the condition's **shape**: which `GameConfig` fields it reads and which
features it has, never the numbers (those stay in `scripts/game_config.gd`). Every key but
`id` is optional, and an omitted key means "this condition does not have that feature":

| key | meaning | read by |
| --- | --- | --- |
| `id` | stable id; `WeatherLibrary.WEATHER_*`, `GameConfig.weather`, the ids in `level_weather_pool` | everything |
| `grip_mult` | field holding the global tyre μ multiplier. Omitted ⇒ exactly 1.0 | `WeatherLibrary.grip_mult` ← `Drivetrain.surface_tire_params` |
| `particles` | `WeatherField` kind (`"rain"` / `"sand"` / `"snow"`). Omitted ⇒ no particle field | `LevelView.apply_weather`, `LevelView._warm_up` |
| `particle_count` | field for the particle count | `LevelView.apply_weather` |
| `particle_speed` | field for particle speed (m/s). Omitted ⇒ the kind's own speed | `LevelView.apply_weather` |
| `wind_dir` | field for the particle and tree-lean heading in degrees (0 = +X, 90 = +Z) | `LevelView.apply_weather`, `WindSway.direction_deg` |
| `look` | maps each `LOOK_KEYS` entry to the field supplying it; all or none | `LevelWeather.target_look`, `LevelWeather._look_light` |
| `sky_panorama` | field holding a sky texture path the condition swaps in. Only `night` names one | `LevelWeather.target_look`, `LevelWeather._show` |
| `wind` | crosswind body force: `strength` / `gust` / `dir_deg` fields (`WIND_KEYS`) | `Crosswind.wind_params` ← `car.gd` → `_resolve_wind` ([car-physics.md](car-physics.md)) |
| `headlights` | field holding the headlight-cone strength (0..1). Omitted ⇒ lights off | `WeatherLibrary.headlight_amount` ← `HeadlightCone.amount` |
| `foliage_wind` | field holding tree-sway strength. Omitted ⇒ the shared `foliage_wind_strength` | `WindSway.strength` ([trees.md](trees.md)) |
| `road_tint` | `{"amount", "color"}` fields for darkening / tinting the road | **nothing** (see "Unread" below) |
| `lightning` | `flash` / `duration` / `interval_min` / `interval_max` fields (`LIGHTNING_KEYS`) | **nothing** |

`look`'s `LOOK_KEYS` are `background_color`, `sky_color`, `sun_energy_mult`,
`fog_density_mult`, `fog_sky_affect`. `sky_panorama` sits beside the `look` block rather
than in it so the other conditions don't have to author a sky they don't change.

**Dry is the absence of every feature**: its entry is `{"id": "dry"}`. Grip multiplies by
exactly 1.0, no particles are built and the look is the scene's own, so dry adds nothing per
frame.

API beyond the seam:

- `by_id(id)`: **an unknown id returns the dry entry**, so callers read it unguarded.
- `grip_mult(cfg, id)`, `headlight_amount(cfg, id)`: the named field's value, 1.0 / 0.0 when
  the entry names none.
- `is_wet(id)` / `wet_ids()`: see below.
- `config_fields(entry)`: every `GameConfig` field the entry names (used by tests).
- `tinted(col, amount, toward, blend)`: a road-tint colour helper with no live caller.

### Wetness: never compare against `"rain"`

`"storm"` is wetter than `"rain"`, so `weather == "rain"` is dead in a storm; that bug has
been written three times. Ask `WeatherLibrary.is_wet(id)` instead. It reads
`WeatherLibrary.WETNESS`, an id → bool table that must name every condition
(`test_weather_library.gd` → `test_every_condition_is_classified_wet_or_dry`). Wet means
liquid water on the road: snowfall is not wet, and sandstorm has a grip multiplier but is dry.

Live readers: `DustPuffs._emit_from_wheels` (no dust or tyre smoke on a wet road) and
`GameConfig.fill_tire_context` (`ctx["is_wet"]`, for tyre-compound rules).

### Adding a condition

1. Add its tuning fields to `scripts/game_config.gd`.
2. Add one entry to `WeatherLibrary.CONDITIONS` naming them.
3. Add its `WETNESS` row (the guard test fails without it).
4. Add `id:weight` to `GameConfig.level_weather_pool` if the level should draw it.

No consumer changes unless the condition needs a new kind of feature; then add a key, the one
consumer that reads it, and list it in `config_fields`.

## On the level: `LevelWeather` (`scripts/level_weather.gd`)

`LevelView._add_effects` calls `LevelWeather.attach`, which adds one `LevelWeather` node
beside the view and starts it.

- **Drift.** Drive time is cut into `level_weather_hold_s` slots. Slot 0 is `level_weather`;
  each later slot is a seeded weighted pick from `level_weather_pool` (`LevelWeather.draw`,
  parsed by `LevelWeather.parse_pool`, which drops unknown ids) that never repeats the slot
  before. The clock, seed and Dev override are static vars, so they survive the level's
  reloads (buying parts, changing cars). The default pool has no `sandstorm`; it is only
  shown if the pool is edited.
- **Rain is snow in the snow biome.** `LevelWeather.resolve` swaps `rain` for `snow` while
  `LevelStreamer.snow_at` under the car is above `SNOW_AT`.
- **Showing a condition** (`LevelWeather._show`) calls `LevelView.apply_weather`, which seats
  `GameConfig.weather`, pushes `WindSway`, and rebuilds the camera's particle field from the
  entry's `particles` / `particle_count` / `wind_dir` / `particle_speed`
  (`WeatherField.spawn`, `scripts/rain_field.gd`). `LevelView.set_weather_ratio` scales the
  particle amount (graphics setting).
- **Fade.** `LevelWeather.target_look` builds the target from the scene's own environment
  plus the entry's `look` (background and fog colour, fog sky affect, `sun_energy_mult`) and
  `sky_panorama`; `_step` lerps to it over `level_weather_fade_s`, swapping the panorama
  halfway behind a swell of fog. Nothing is written between fades. `look.sky_color` is not
  used.
- **Fog thickness is the fog's far end, not its density.** The level uses depth fog, which
  ignores `fog_density`, so `fog_depth_end = level_fog_end_m × base density / target density`
  is what fades. Photo mode (`LevelView._render_off`) restores `LevelWeather.fog_end()`, and
  only pushes the fog out for dry weather.
- **Brightness is the `world_light` global shader uniform** (vec3, default 1), faded to the
  look's `sun_energy_mult`. Every lit level shader multiplies its light term by it; the
  headlight cone and exhaust flash (`flash_lit`) are added on top, unscaled. Buildings,
  fences, hedges and teleport obelisks share `shaders/level_prop.gdshader`. Left bright on
  purpose (EXEMPT in `test_lighting_coverage`): the route arrow, car shadow, tree id pass,
  lamp flares. `LevelWeather.reset()` (from `LevelView._exit_tree`) puts it back to 1.
- **`GameConfig.weather_lit` is not the level's darkening path.** It scales by
  `GameConfig.weather_sun_mult`, which nothing on the level sets, so it stays a no-op (still
  called by `apply_car_light`, `WheelParticles` and `EngineSmoke`).
- **The driver reacts late.** Headlights follow `GameConfig.lights_weather` when it is set;
  `LevelWeather._switch_lights` moves it to the new condition `LIGHTS_AT` of the way through a
  fade. `LevelView._timed_process` pushes the cone each frame while `HeadlightCone.has_headlights`.
- **Dev button.** Settings → Dev → Weather cycles `LevelWeather.forced_weather` through Auto
  and each pool id (`settings_menu.gd` → `_cycle_dev_weather`).
- `LevelView._warm_up` spawns one field of every particle kind in the table once, so their
  shaders compile behind the loading screen.
- `LevelView._exit_tree` resets the cone, `LevelWeather`, `WindSway` and sets
  `GameConfig.weather` back to dry.

## Grip

`Drivetrain.surface_tire_params` multiplies μ by `WeatherLibrary.grip_mult(cfg, cfg.weather)`
with no per-condition branch, memoised on `_weather_mu` / `_weather_mu_id` and re-resolved
only when the condition or config changes (this is the per-wheel hot path). Snowfall
deliberately authors no `grip_mult`: on the level the snow biome already sets grip through
`LevelView.set_snow` ([snow-region.md](snow-region.md)). Details in
[drivetrain-and-tires.md](drivetrain-and-tires.md).

## Headlights

The cone is a fake light computed in the shaders from global uniforms
(`scripts/headlight_cone.gd`, `shaders/headlight_cone.gdshaderinc`); the renderer is unshaded,
so a real light node would do nothing. Its shape (`headlight_*` fields) is shared; only its
**strength** is per condition, through the `headlights` key, because the cone is added to the
light term and a storm's dimmed day is far brighter than night. `night` and `storm` author one.
`CarLamps` reads the same `HeadlightCone.amount` for the lamp glow. Shader side:
[rendering.md](rendering.md) → "The fake headlight cone".

## Unread table entries

These are authored but no live code reads them (they were consumed by the deleted
`world.gd`):

- `road_tint` on every entry that has one, the `ROAD_TINT_KEYS` const and `tinted()`.
- `lightning` on `storm`, and its `storm_lightning_*` `GameConfig` fields.
- `look.sky_color` on every entry (the `*_sky_color` fields).
- `sandstorm` as a whole is reachable only by adding it to `level_weather_pool`.
